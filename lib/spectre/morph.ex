defmodule Spectre.Morph do
  @moduledoc """
  Small host-facing façade for governed, declarative Agent changes.

      {:ok, activation} =
        instance
        |> Spectre.Morph.change(by: "actor:admin", reason: "Serve refunds")
        |> Spectre.Morph.mount_skill("refunds",
          match: {:exact, "refund"},
          reply: "Refund policy applies to: {{input.text}}",
          scopes: [:support]
        )
        |> Spectre.Morph.evaluate(cases: protected_cases)
        |> Spectre.Morph.approve(by: "actor:reviewer")
        |> Spectre.Morph.activate()

  Morph does not add a second governance engine. It derives a ChangeSet,
  delegates composition/review/approval/activation to the existing core, and
  always reads the immutable change surface from the active canonical
  Definition. Approval remains a separate host commit and activation remains
  generation-CAS fenced.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Governance.Approval
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Governance.Composer
  alias Spectre.Governance.Review
  alias Spectre.Instance
  alias Spectre.Instance.Activation
  alias Spectre.Morph.Change
  alias Spectre.Morph.Surface
  alias Spectre.Skill.Definition, as: SkillDefinition

  @doc "Opens a change against the exact active Definition."
  @spec change(GenServer.server(), keyword()) :: Change.t()
  def change(instance, opts \\ [])

  def change(instance, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      do_change(instance, opts)
    else
      invalid_change(instance, opts)
    end
  end

  def change(instance, opts), do: invalid_change(instance, opts)

  defp do_change(instance, opts) do
    agent = Instance.agent(instance)
    store = Instance.definition_store(instance)
    activation = Instance.activation(instance)
    actor_ref = Keyword.get(opts, :by)
    reason = Keyword.get(opts, :reason)
    evidence = Keyword.get(opts, :evidence, %{})

    base = %Change{
      instance: instance,
      store: store,
      agent: agent,
      activation: activation,
      surface: placeholder_surface(),
      actor_ref: actor_ref,
      reason: reason,
      evidence: evidence
    }

    with :ok <- keyword_options(opts, [:by, :reason, :evidence]),
         :ok <- nonempty(actor_ref, :by),
         :ok <- nonempty(reason, :reason),
         :ok <- plain_map(evidence, :evidence),
         true <- not is_nil(store),
         %Activation{} <- activation,
         {:ok, resolution} <- Resolver.resolve(store, activation.definition_ref),
         {:ok, surface} <- Surface.from_canonical(resolution.definition) do
      %{base | surface: surface}
    else
      false -> fail(base, :morph_requires_definition_store)
      nil -> fail(base, :morph_requires_activation)
      {:error, :morph_surface_not_declared} -> fail(base, {:agent_declares_no_morph, agent})
      {:error, reason} -> fail(base, reason)
      _value -> fail(base, :morph_requires_activation)
    end
  end

  defp invalid_change(instance, opts) do
    %Change{
      instance: instance,
      store: nil,
      agent: nil,
      activation: nil,
      surface: placeholder_surface(),
      actor_ref: nil,
      reason: nil,
      error: {:invalid_morph_options, opts}
    }
  end

  @doc "Proposes mounting one reply-only runtime Skill."
  @spec mount_skill(Change.t(), String.t(), keyword()) :: Change.t()
  def mount_skill(change, mount_id, opts \\ []),
    do: put_skill_operation(change, "mount_skill", mount_id, opts)

  @doc "Proposes replacing one runtime Skill while preserving its anti-hijack corpus."
  @spec replace_skill(Change.t(), String.t(), keyword()) :: Change.t()
  def replace_skill(change, mount_id, opts \\ []),
    do: put_skill_operation(change, "replace_skill", mount_id, opts)

  @doc "Proposes disabling a mounted Skill."
  @spec disable_skill(Change.t(), String.t()) :: Change.t()
  def disable_skill(%Change{error: error} = change, _mount_id) when not is_nil(error), do: change

  def disable_skill(%Change{} = change, mount_id) do
    with :ok <- draft_state(change),
         :ok <- permitted(change, "disable_skill"),
         :ok <- stable_id(mount_id),
         {:ok, skill} <- runtime_target(change, mount_id) do
      change
      |> append_operation(%{
        "type" => "disable_skill",
        "payload" => %{"mount_id" => mount_id}
      })
      |> append_disable_cases(mount_id, skill)
    else
      {:error, reason} -> fail(change, reason)
    end
  end

  @doc "Composes the Candidate and records deterministic replay/regression evidence."
  @spec evaluate(Change.t(), keyword()) :: Change.t()
  def evaluate(change, opts \\ [])

  def evaluate(%Change{error: error} = change, _opts) when not is_nil(error), do: change

  def evaluate(%Change{} = change, opts) when is_list(opts) do
    with :ok <-
           keyword_options(opts, [
             :cases,
             :now,
             :receipts,
             :delta,
             :checker_versions,
             :prompt_token_ceiling
           ]),
         :ok <- draft_state(change),
         false <- change.operations == [],
         :ok <- prompt_ceiling(Keyword.get(opts, :prompt_token_ceiling)),
         now = timestamp(opts),
         {:ok, change_set} <- change_set(change, now),
         {:ok, composed_ref} <- compose(change, change_set, now, opts),
         {:ok, candidate} <- Store.fetch_candidate(change.store, composed_ref),
         {:ok, delta, receipts} <- gate(change, candidate, opts, now),
         {:ok, evaluated_ref, report} <-
           Review.evaluate(change.store, composed_ref, delta, receipts,
             reviewed_at: now,
             now: now,
             checker_versions: checker_versions(opts)
           ),
         {:ok, reviewed} <- Store.fetch_candidate(change.store, evaluated_ref),
         governance when not is_nil(governance) <- reviewed.governance do
      %{change | state: governance.state, ref: evaluated_ref, report: report, delta: delta}
    else
      true -> fail(change, :morph_has_no_changes)
      {:error, reason} -> fail(change, reason)
      _invalid -> fail(change, :candidate_is_not_governed)
    end
  end

  def evaluate(%Change{} = change, opts), do: fail(change, {:invalid_morph_options, opts})

  @doc "Records the separate host approval commit; it never activates."
  @spec approve(Change.t(), keyword()) :: Change.t()
  def approve(change, opts \\ [])

  def approve(%Change{error: error} = change, _opts) when not is_nil(error), do: change

  def approve(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, [:by, :mode, :now, :policy, :expires_at]),
         :ok <- require_state(change, :evaluated),
         {:ok, surface} <- canonical_surface(change),
         {:ok, approval_opts} <- approval_opts(surface, opts),
         {:ok, approved_ref} <- Approval.approve(change.store, change.ref, approval_opts) do
      %{change | state: :approved, ref: approved_ref}
    else
      {:error, reason} -> fail(change, reason)
    end
  end

  def approve(%Change{} = change, opts), do: fail(change, {:invalid_morph_options, opts})

  @doc "Records an explicit host rejection of an evaluated Candidate."
  @spec reject(Change.t(), keyword()) :: Change.t()
  def reject(change, opts \\ [])

  def reject(%Change{error: error} = change, _opts) when not is_nil(error), do: change

  def reject(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, [:by, :reason, :now]),
         :ok <- require_state(change, :evaluated),
         :ok <- nonempty(Keyword.get(opts, :by), :by),
         :ok <- nonempty(Keyword.get(opts, :reason), :reason),
         {:ok, rejected_ref} <-
           Approval.reject(change.store, change.ref,
             actor_ref: Keyword.get(opts, :by),
             reason: Keyword.get(opts, :reason),
             rejected_at: timestamp(opts)
           ) do
      %{change | state: :rejected, ref: rejected_ref}
    else
      {:error, reason} -> fail(change, reason)
    end
  end

  def reject(%Change{} = change, opts), do: fail(change, {:invalid_morph_options, opts})

  @doc "Activates an approved Candidate through the Instance generation CAS."
  @spec activate(Change.t(), keyword()) :: {:ok, Activation.t()} | {:error, term()}
  def activate(change, opts \\ [])

  def activate(%Change{error: error}, _opts) when not is_nil(error), do: {:error, error}

  def activate(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, [:now, :checker_versions]),
         :ok <- require_state(change, :approved) do
      Spectre.activate(change.instance, change.ref,
        expected_generation: change.activation.generation,
        evidence: change.evidence,
        now: timestamp(opts),
        checker_versions: checker_versions(opts)
      )
    end
  end

  def activate(%Change{}, opts), do: {:error, {:invalid_morph_options, opts}}

  @doc "Explicitly rebases the draft operations onto the Instance's current Activation."
  @spec rebase(Change.t(), keyword()) :: Change.t()
  def rebase(change, opts \\ [])

  def rebase(%Change{} = change, opts) when is_list(opts) do
    case keyword_options(opts, [:by, :reason, :evidence]) do
      :ok ->
        rebase_operations(change, opts)

      {:error, reason} ->
        fail(change, reason)
    end
  end

  def rebase(%Change{} = change, opts), do: fail(change, {:invalid_morph_options, opts})

  @doc "Restores a durable Candidate view using only its Ref and running Instance."
  @spec resume(GenServer.server(), term(), keyword()) :: Change.t()
  def resume(instance, candidate_ref, opts \\ []) do
    if Keyword.keyword?(opts),
      do: do_resume(instance, candidate_ref, opts),
      else: invalid_change(instance, opts)
  end

  defp rebase_operations(change, opts) do
    rebased =
      change(change.instance,
        by: Keyword.get(opts, :by, change.actor_ref),
        reason: Keyword.get(opts, :reason, change.reason),
        evidence: Keyword.get(opts, :evidence, change.evidence)
      )

    Enum.reduce(change.operations, rebased, &rebase_operation/2)
  end

  defp rebase_operation(_operation, %Change{error: error} = current) when not is_nil(error),
    do: current

  defp rebase_operation(operation, current) do
    operation_name = Map.get(operation, "type")

    if Surface.allows?(current.surface, operation_name) or internal_eval_case?(operation),
      do: append_operation(current, operation),
      else: fail(current, {:morph_not_permitted, operation_name})
  end

  defp do_resume(instance, candidate_ref, opts) do
    base =
      case keyword_options(opts, [:by, :reason, :evidence]) do
        :ok ->
          change(instance,
            by: Keyword.get(opts, :by, "actor:resumed"),
            reason: Keyword.get(opts, :reason, "resume governed Candidate"),
            evidence: Keyword.get(opts, :evidence, %{})
          )

        {:error, reason} ->
          invalid_change(instance, opts) |> fail(reason)
      end

    if base.error do
      base
    else
      case Store.fetch_candidate(base.store, candidate_ref) do
        {:ok, %{governance: governance} = candidate} when not is_nil(governance) ->
          %{
            base
            | ref: Spectre.Definition.Candidate.ref(candidate),
              state: normalize_state(governance.state),
              report: governance.report
          }

        {:ok, _candidate} ->
          fail(base, :candidate_is_not_governed)

        :not_found ->
          fail(base, :governance_candidate_not_found)

        {:error, reason} ->
          fail(base, reason)
      end
    end
  end

  @doc "Returns a compact status projection for UI or logs."
  @spec status(Change.t()) :: map()
  def status(%Change{} = change) do
    %{
      state: change.state,
      candidate_ref: change.ref && to_string(change.ref),
      error: change.error,
      activation_generation: change.activation && change.activation.generation,
      operation_count: length(change.operations)
    }
  end

  @doc "Returns the deterministic human report after evaluation."
  @spec explain(Change.t()) :: {:ok, map()} | {:error, term()}
  def explain(%Change{error: error}) when not is_nil(error), do: {:error, error}
  def explain(%Change{report: nil}), do: {:error, :morph_not_evaluated}

  def explain(%Change{report: report}),
    do: {:ok, Spectre.Projection.HumanReport.to_data(report)}

  defp put_skill_operation(%Change{error: error} = change, _type, _id, _opts)
       when not is_nil(error),
       do: change

  defp put_skill_operation(%Change{} = change, type, mount_id, opts)
       when is_list(opts) do
    with :ok <-
           keyword_options(opts, [:match, :reply, :never, :version, :token_cap, :scopes]),
         :ok <- draft_state(change),
         :ok <- permitted(change, type),
         :ok <- stable_id(mount_id),
         :ok <- maybe_runtime_target(change, type, mount_id),
         {:ok, definition, scopes} <- skill_definition(change, mount_id, opts) do
      change
      |> append_operation(%{
        "type" => type,
        "payload" => %{
          "mount_id" => mount_id,
          "definition" => definition,
          "bindings" => %{},
          "opts" => %{}
        }
      })
      |> append_reply_cases(
        mount_id,
        elem(exact_match(Keyword.get(opts, :match)), 1),
        expected_reply(
          Keyword.get(opts, :reply),
          elem(exact_match(Keyword.get(opts, :match)), 1)
        ),
        scopes
      )
    else
      {:error, reason} -> fail(change, reason)
    end
  end

  defp put_skill_operation(%Change{} = change, _type, _mount_id, opts),
    do: fail(change, {:invalid_morph_options, opts})

  defp skill_definition(change, mount_id, opts) do
    with {:ok, trigger} <- exact_match(Keyword.get(opts, :match)),
         :ok <- nonempty(Keyword.get(opts, :reply), :reply),
         :ok <- reply_template(Keyword.get(opts, :reply)),
         {:ok, negative} <- examples(Keyword.get(opts, :never, [])),
         {:ok, scopes} <- skill_scopes(change.surface, Keyword.get(opts, :scopes)),
         {:ok, token_cap} <- token_cap(change.surface, Keyword.get(opts, :token_cap)) do
      fragment_id = mount_id <> ":reply"

      attrs = %{
        "id" => mount_id,
        "declared_version" => Keyword.get(opts, :version, 1),
        "publisher_ref" => "spectre.morph",
        "applicability" => %{
          "scopes" => scopes,
          "positive" => [trigger],
          "negative" => negative
        },
        "prompt_budget" => token_cap,
        "prompt_fragments" => [
          %{
            "id" => fragment_id,
            "content" => Keyword.get(opts, :reply),
            "token_cap" => token_cap,
            "budget_class" => "small"
          }
        ],
        "flows" => [
          %{
            "id" => List.first(scopes),
            "routes" => [
              %{
                "label" => route_label(mount_id),
                "match" => %{"kind" => "exact", "value" => trigger},
                "handler" => %{"kind" => "reply", "prompt" => fragment_id}
              }
            ]
          }
        ]
      }

      with {:ok, _skill} <- SkillDefinition.new(attrs), do: {:ok, attrs, scopes}
    end
  end

  defp exact_match({:exact, value}), do: exact_match(value)
  defp exact_match(value) when is_binary(value) and value != "", do: {:ok, value}
  defp exact_match(value), do: {:error, {:morph_requires_exact_match, value}}

  defp expected_reply(template, input),
    do: String.replace(template, "{{input.text}}", input)

  defp examples(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(values)},
      else: {:error, {:invalid_morph_negative_examples, values}}
  end

  defp examples(value), do: {:error, {:invalid_morph_negative_examples, value}}

  defp reply_template(template) when is_binary(template) do
    placeholders =
      Regex.scan(~r/{{[^}]*}}/u, template)
      |> List.flatten()
      |> Enum.uniq()

    remainder = Regex.replace(~r/{{[^}]*}}/u, template, "")

    placeholder_names =
      Enum.map(placeholders, &binary_part(&1, 2, byte_size(&1) - 4))

    if Enum.all?(placeholders, &(&1 == "{{input.text}}")) and
         not String.contains?(remainder, ["{{", "}}"]),
       do: :ok,
       else: {:error, {:unsupported_morph_reply_placeholder, placeholder_names}}
  end

  defp skill_scopes(%Surface{scope_ceiling: [scope]}, nil), do: {:ok, [scope]}

  defp skill_scopes(%Surface{scope_ceiling: scopes}, nil),
    do: {:error, {:morph_skill_scopes_required, scopes}}

  defp skill_scopes(%Surface{scope_ceiling: ceiling}, values)
       when is_list(values) and values != [] do
    normalized = Enum.map(values, &canonical_scope/1)

    cond do
      Enum.any?(normalized, &is_nil/1) ->
        {:error, {:invalid_morph_skill_scopes, values}}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {:error, {:duplicate_morph_skill_scopes, values}}

      Enum.any?(normalized, &(&1 not in ceiling)) ->
        {:error, {:morph_skill_scopes_exceed_surface, normalized, ceiling}}

      true ->
        {:ok, Enum.sort(normalized)}
    end
  end

  defp skill_scopes(_surface, values), do: {:error, {:invalid_morph_skill_scopes, values}}

  defp canonical_scope(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp canonical_scope(value) when is_binary(value) and value != "", do: value
  defp canonical_scope(_value), do: nil

  defp token_cap(surface, nil), do: {:ok, min(128, surface.prompt_token_ceiling)}

  defp token_cap(surface, value)
       when is_integer(value) and value > 0 and value <= surface.prompt_token_ceiling,
       do: {:ok, value}

  defp token_cap(surface, value),
    do: {:error, {:morph_prompt_cap_exceeded, value, surface.prompt_token_ceiling}}

  defp change_set(change, now) do
    ChangeSet.new(%{
      base_activation_receipt: change.activation.activation_receipt,
      base_candidate_ref: change.activation.candidate_ref,
      observed_definition_ref: change.activation.definition_ref,
      observed_authority_epoch: change.activation.authority_epoch,
      observed_evidence_digest: ChangeSet.evidence_digest(change.activation, change.evidence),
      operations: change.operations,
      author_ref: change.actor_ref,
      provenance: %{
        "origin" => "spectre.morph",
        "change_surface_digest" => Surface.digest(change.surface)
      },
      reason: change.reason,
      created_at: now
    })
  rescue
    ArgumentError -> {:error, :invalid_morph_evidence}
  end

  defp compose(change, change_set, now, opts) do
    requested = Keyword.get(opts, :prompt_token_ceiling, change.surface.prompt_token_ceiling)
    ceiling = min_ceiling(requested, change.surface.prompt_token_ceiling)

    Composer.compose(change.store, change_set,
      activation: change.activation,
      evidence: change.evidence,
      created_at: now,
      applicability_ceilings: Surface.applicability_ceilings(change.surface, change.mount_ids),
      prompt_token_ceiling: ceiling
    )
  end

  defp gate(change, candidate, opts, now) do
    cases = Keyword.get(opts, :cases, [])
    agent = Instance.agent(change.instance)

    case {Keyword.get(opts, :receipts), Keyword.get(opts, :delta)} do
      {nil, nil} ->
        Declarative.run(change.store, candidate, cases,
          agent: agent,
          issued_at: now
        )

      {receipts, delta} when is_list(receipts) and not is_nil(delta) ->
        {:ok, delta, receipts}

      _partial ->
        {:error, :morph_requires_both_receipts_and_delta}
    end
  end

  defp approval_opts(surface, opts) do
    actor = Keyword.get(opts, :by)
    mode = effective_approval_mode(surface, Keyword.get(opts, :mode))

    with :ok <- approval_requirement(surface, mode),
         :ok <- approval_actor(surface, actor) do
      approval_opts = [
        actor_ref: actor,
        approved_at: timestamp(opts),
        policy: Keyword.get(opts, :policy),
        expires_at: Keyword.get(opts, :expires_at)
      ]

      approval_opts =
        if is_nil(mode), do: approval_opts, else: Keyword.put(approval_opts, :mode, mode)

      {:ok, approval_opts}
    end
  end

  defp effective_approval_mode(%Surface{approval_requirement: :human}, nil), do: :human
  defp effective_approval_mode(_surface, mode), do: mode

  defp approval_actor(%Surface{approval_requirement: :human}, actor), do: nonempty(actor, :by)
  defp approval_actor(_surface, actor), do: optional_nonempty(actor, :by)

  defp approval_requirement(%Surface{approval_requirement: :human}, nil), do: :ok
  defp approval_requirement(%Surface{approval_requirement: :human}, :human), do: :ok

  defp approval_requirement(%Surface{approval_requirement: :human}, mode),
    do: {:error, {:morph_requires_human_approval, mode}}

  defp approval_requirement(%Surface{approval_requirement: :host_policy}, mode)
       when mode in [nil, :human, :automatic],
       do: :ok

  defp approval_requirement(_surface, mode),
    do: {:error, {:invalid_governance_approval_mode, mode}}

  defp canonical_surface(change) do
    with {:ok, resolution} <- Resolver.resolve(change.store, change.activation.definition_ref) do
      Surface.from_canonical(resolution.definition)
    end
  end

  defp append_operation(change, operation) do
    mount_id = get_in(operation, ["payload", "mount_id"])

    %{
      change
      | operations: change.operations ++ [operation],
        mount_ids: Enum.uniq(change.mount_ids ++ List.wrap(mount_id))
    }
  end

  defp internal_eval_case?(%{
         "type" => "add_eval_case",
         "payload" => %{"case" => evaluation_case}
       }) do
    match?({:ok, _case}, Spectre.Eval.Case.new(evaluation_case))
  end

  defp internal_eval_case?(_operation), do: false

  defp permitted(change, operation) do
    if Surface.allows?(change.surface, operation),
      do: :ok,
      else: {:error, {:morph_not_permitted, operation}}
  end

  defp draft_state(%Change{state: :draft}), do: :ok
  defp draft_state(%Change{state: state}), do: {:error, {:morph_not_draft, state}}

  defp require_state(%Change{state: state}, state), do: :ok

  defp require_state(%Change{state: actual}, expected),
    do: {:error, {:morph_state, expected, actual}}

  defp stable_id(value) when is_binary(value) and value != "" do
    if String.starts_with?(value, "Elixir."),
      do: {:error, {:morph_code_reference_forbidden, value}},
      else: :ok
  end

  defp stable_id(value), do: {:error, {:invalid_morph_skill_id, value}}

  defp maybe_runtime_target(_change, "mount_skill", _mount_id), do: :ok

  defp maybe_runtime_target(change, _operation, mount_id) do
    with {:ok, _skill} <- runtime_target(change, mount_id), do: :ok
  end

  defp runtime_target(change, mount_id) do
    with {:ok, resolution} <- Resolver.resolve(change.store, change.activation.definition_ref),
         {:ok, component} <- Canonical.fetch_component(resolution.definition, :skills),
         mounts when is_list(mounts) <- value(component.payload, :mounts, []),
         mount when is_map(mount) <-
           Enum.find(mounts, &same_name?(value(&1, :id), mount_id)),
         definition when is_map(definition) <- value(mount, :definition),
         {:ok, canonical} <- Canonical.from_data(definition),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical),
         :runtime <- SkillDefinition.origin(skill) do
      {:ok, skill}
    else
      nil -> {:error, {:morph_runtime_skill_not_found, mount_id}}
      :compiled -> {:error, {:morph_compiled_skill_is_immutable, mount_id}}
      {:error, _reason} = error -> error
      _value -> {:error, {:morph_runtime_skill_not_found, mount_id}}
    end
  end

  defp append_reply_cases(change, mount_id, input, output, scopes) do
    Enum.reduce(scopes, change, fn scope, current ->
      append_eval_case(current, %{
        "id" => candidate_case_id(mount_id, scope, "reply"),
        "input" => input,
        "expected_outcome" => "route",
        "expected_route" => route_label(mount_id),
        "expected_output" => output,
        "context" => %{"scope" => scope},
        "llm" => "forbidden"
      })
    end)
  end

  defp append_disable_cases(change, mount_id, skill) do
    inputs = SkillDefinition.applicability(skill).positive

    Enum.reduce(change.surface.scope_ceiling, change, fn scope, scoped ->
      Enum.reduce(inputs, scoped, fn input, current ->
        append_eval_case(current, %{
          "id" => candidate_case_id(mount_id, scope, "disabled:" <> input),
          "input" => input,
          "expected_outcome" => "clarify",
          "context" => %{"scope" => scope},
          "llm" => "forbidden"
        })
      end)
    end)
  end

  defp append_eval_case(change, evaluation_case) do
    append_operation(change, %{
      "type" => "add_eval_case",
      "payload" => %{"case" => evaluation_case}
    })
  end

  defp candidate_case_id(mount_id, scope, purpose) do
    Surface.evaluation_case_id(mount_id, scope, purpose)
  end

  defp route_label(mount_id),
    do:
      mount_id |> String.upcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "_") |> String.trim("_")

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(value, field), do: {:error, {:morph_requires, field, value}}

  defp optional_nonempty(nil, _field), do: :ok
  defp optional_nonempty(value, field), do: nonempty(value, field)

  defp plain_map(value, _field) when is_map(value) and not is_struct(value), do: :ok
  defp plain_map(value, field), do: {:error, {:invalid_morph_field, field, value}}

  defp keyword_options(opts, allowed) do
    unknown = if Keyword.keyword?(opts), do: Keyword.keys(opts) -- allowed, else: []

    cond do
      not Keyword.keyword?(opts) -> {:error, {:invalid_morph_options, opts}}
      duplicate_keyword?(opts) -> {:error, :duplicate_morph_options}
      unknown != [] -> {:error, {:unknown_morph_options, unknown}}
      true -> :ok
    end
  end

  defp duplicate_keyword?(opts),
    do: opts |> Keyword.keys() |> Enum.uniq() |> length() != length(opts)

  defp min_ceiling(requested, declared) when is_number(requested) and requested >= 0,
    do: min(requested, declared)

  defp min_ceiling(_requested, declared), do: declared

  defp prompt_ceiling(nil), do: :ok
  defp prompt_ceiling(value) when is_number(value) and value >= 0, do: :ok
  defp prompt_ceiling(value), do: {:error, {:invalid_morph_prompt_ceiling, value}}

  defp checker_versions(opts),
    do: Keyword.get(opts, :checker_versions, Declarative.checker_versions())

  defp timestamp(opts),
    do: Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)

  defp normalize_state(:composed), do: :draft
  defp normalize_state(:evaluated), do: :evaluated
  defp normalize_state(:approved), do: :approved
  defp normalize_state(:rejected), do: :rejected

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp same_name?(left, right), do: to_string(left) == to_string(right)

  defp placeholder_surface do
    Surface.new!(%{
      operation_types: ["mount_skill"],
      scope_ceiling: ["agent"],
      prompt_token_ceiling: 1,
      approval_requirement: "host_policy"
    })
  end

  defp fail(%Change{} = change, reason), do: %{change | error: reason}
end
