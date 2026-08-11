defmodule Spectre.Morph do
  @moduledoc """
  Host-facing facade for governed, declarative Agent evolution.

  Morph translates a small reply-only API into the existing immutable
  ChangeSet, review, approval, and activation pipeline. It does not create a
  second governance engine and cannot widen the canonical Surface declared by
  the Agent.

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

  Every stage returns an inspectable `Spectre.Morph.Change`. Approval remains
  an explicit host commit, activation remains generation-CAS fenced, and each
  runtime Skill is reloaded from the exact Definition pinned to its Run.
  """

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Instance
  alias Spectre.Instance.Activation
  alias Spectre.Morph.Change
  alias Spectre.Morph.GovernancePipeline
  alias Spectre.Morph.SkillProposal
  alias Spectre.Morph.Surface

  @change_options [:by, :reason, :evidence]

  @doc """
  Opens a draft against the Instance's exact active Definition.

  Required options are `:by` and `:reason`; `:evidence` accepts a plain map
  that is digest-bound to the ChangeSet. The canonical Surface is always read
  from the Definition Store, never from transient caller data.
  """
  @spec change(GenServer.server()) :: Change.t()
  @spec change(GenServer.server(), keyword()) :: Change.t()
  def change(instance, opts \\ [])

  def change(instance, opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: do_change(instance, opts), else: invalid_change(instance, opts)
  end

  def change(instance, opts), do: invalid_change(instance, opts)

  @doc """
  Adds one reply-only runtime Skill proposal to a draft.

  `:match` must be an exact non-empty string (or `{:exact, string}`), and
  `:reply` may contain only the `{{input.text}}` placeholder. Optional keys are
  `:never`, `:version`, `:token_cap`, and `:scopes`. With a multi-scope Surface,
  `:scopes` is required and must be a non-empty subset of the ceiling.
  """
  @spec mount_skill(Change.t(), String.t()) :: Change.t()
  @spec mount_skill(Change.t(), String.t(), keyword()) :: Change.t()
  def mount_skill(change, mount_id, opts \\ []),
    do: SkillProposal.put(change, :mount_skill, mount_id, opts)

  @doc """
  Replaces one runtime-origin Skill while preserving anti-hijack obligations.

  The options have the same form as `mount_skill/3`. Compiled Skills are
  immutable through this API and are rejected again from the durable
  parent-to-candidate diff at governance commit time.
  """
  @spec replace_skill(Change.t(), String.t()) :: Change.t()
  @spec replace_skill(Change.t(), String.t(), keyword()) :: Change.t()
  def replace_skill(change, mount_id, opts \\ []),
    do: SkillProposal.put(change, :replace_skill, mount_id, opts)

  @doc """
  Proposes disabling a runtime-origin Skill.

  Morph derives negative replay cases only for the scopes and positive inputs
  owned by that Skill; unrelated behavior in sibling scopes remains protected.
  """
  @spec disable_skill(Change.t(), String.t()) :: Change.t()
  def disable_skill(change, mount_id), do: SkillProposal.disable(change, mount_id)

  @doc """
  Composes and deterministically evaluates a draft Candidate.

  `:cases` supplies the protected corpus. Tests may supply an inseparable
  `:receipts` plus `:delta` pair for exact external replay. Optional controls
  are `:now`, `:checker_versions`, and a narrowing `:prompt_token_ceiling`.
  This stage never approves or activates the Candidate.
  """
  @spec evaluate(Change.t()) :: Change.t()
  @spec evaluate(Change.t(), keyword()) :: Change.t()
  def evaluate(change, opts \\ []), do: GovernancePipeline.evaluate(change, opts)

  @doc """
  Records the separate host approval commit.

  Options are `:by`, `:mode`, `:policy`, `:expires_at`, and `:now`. A Surface
  requiring human approval defaults the mode to `:human` and requires an
  actor; host policy remains subordinate to the independent risk policy.
  """
  @spec approve(Change.t()) :: Change.t()
  @spec approve(Change.t(), keyword()) :: Change.t()
  def approve(change, opts \\ []), do: GovernancePipeline.approve(change, opts)

  @doc """
  Records an explicit host rejection of an evaluated Candidate.

  Both `:by` and `:reason` are required; `:now` controls the deterministic
  commit timestamp in tests or host-managed clocks.
  """
  @spec reject(Change.t()) :: Change.t()
  @spec reject(Change.t(), keyword()) :: Change.t()
  def reject(change, opts \\ []), do: GovernancePipeline.reject(change, opts)

  @doc """
  Activates an approved Candidate through the Instance generation CAS.

  `:now` and `:checker_versions` may be supplied. Activation re-reads all
  durable artifacts and re-applies constitutional verification at commit.
  """
  @spec activate(Change.t()) :: {:ok, Activation.t()} | {:error, term()}
  @spec activate(Change.t(), keyword()) :: {:ok, Activation.t()} | {:error, term()}
  def activate(change, opts \\ []), do: GovernancePipeline.activate(change, opts)

  @doc """
  Rebases a draft's typed operations onto the current active Definition.

  Optional `:by`, `:reason`, and `:evidence` replace the original values.
  Every operation is revalidated against the new canonical Surface before any
  operation is copied into the rebased draft.
  """
  @spec rebase(Change.t()) :: Change.t()
  @spec rebase(Change.t(), keyword()) :: Change.t()
  def rebase(change, opts \\ [])

  def rebase(%Change{} = change, opts) when is_list(opts) do
    case keyword_options(opts, @change_options) do
      :ok -> rebase_operations(change, opts)
      {:error, reason} -> Change.fail(change, reason)
    end
  end

  def rebase(%Change{} = change, opts),
    do: Change.fail(change, {:invalid_morph_options, opts})

  @doc """
  Restores a durable governed Candidate view by Ref.

  The Ref may be a `CandidateRef` or its canonical string form. Optional
  `:by`, `:reason`, and `:evidence` establish the host context used by a later
  approval or activation; no transient proposal data is trusted.
  """
  @spec resume(GenServer.server(), CandidateRef.t() | String.t()) :: Change.t()
  @spec resume(GenServer.server(), CandidateRef.t() | String.t(), keyword()) :: Change.t()
  def resume(instance, candidate_ref, opts \\ []) do
    if Keyword.keyword?(opts),
      do: do_resume(instance, candidate_ref, opts),
      else: invalid_change(instance, opts)
  end

  @doc "Returns a compact, data-only status projection suitable for UI or logs."
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

  @doc "Returns the deterministic human report produced by evaluation."
  @spec explain(Change.t()) :: {:ok, map()} | {:error, term()}
  def explain(%Change{error: error}) when not is_nil(error), do: {:error, error}
  def explain(%Change{report: nil}), do: {:error, :morph_not_evaluated}

  def explain(%Change{report: report}),
    do: {:ok, Spectre.Projection.HumanReport.to_data(report)}

  @spec do_change(GenServer.server(), keyword()) :: Change.t()
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

    with :ok <- keyword_options(opts, @change_options),
         :ok <- nonempty(actor_ref, :by),
         :ok <- nonempty(reason, :reason),
         :ok <- plain_map(evidence, :evidence),
         true <- not is_nil(store),
         %Activation{} <- activation,
         {:ok, resolution} <- Resolver.resolve(store, activation.definition_ref),
         {:ok, surface} <- Surface.from_canonical(resolution.definition) do
      %{base | surface: surface}
    else
      false ->
        Change.fail(base, :morph_requires_definition_store)

      nil ->
        Change.fail(base, :morph_requires_activation)

      {:error, :morph_surface_not_declared} ->
        Change.fail(base, {:agent_declares_no_morph, agent})

      {:error, reason} ->
        Change.fail(base, reason)

      _value ->
        Change.fail(base, :morph_requires_activation)
    end
  end

  @spec invalid_change(GenServer.server(), term()) :: Change.t()
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

  @spec rebase_operations(Change.t(), keyword()) :: Change.t()
  defp rebase_operations(change, opts) do
    rebased =
      change(change.instance,
        by: Keyword.get(opts, :by, change.actor_ref),
        reason: Keyword.get(opts, :reason, change.reason),
        evidence: Keyword.get(opts, :evidence, change.evidence)
      )

    with nil <- rebased.error,
         {:ok, operations} <- revalidated_operations(change.operations, rebased.surface) do
      Change.append_operations(rebased, operations)
    else
      {:error, reason} -> Change.fail(rebased, reason)
      _invalid_base -> rebased
    end
  end

  @spec revalidated_operations([map()], Surface.t()) :: {:ok, [map()]} | {:error, term()}
  defp revalidated_operations(operations, surface) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, accepted} ->
      case revalidate_operation(operation, surface) do
        :ok -> {:cont, {:ok, [operation | accepted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
      {:error, _reason} = error -> error
    end)
  end

  @spec revalidate_operation(map(), Surface.t()) :: :ok | {:error, term()}
  defp revalidate_operation(operation, surface) do
    operation_name = Map.get(operation, "type")

    if Surface.allows?(surface, operation_name) or SkillProposal.internal_eval_case?(operation),
      do: :ok,
      else: {:error, {:morph_not_permitted, operation_name}}
  end

  @spec do_resume(GenServer.server(), CandidateRef.t() | String.t(), keyword()) :: Change.t()
  defp do_resume(instance, candidate_ref, opts) do
    base = resumed_change(instance, opts)

    if base.error do
      base
    else
      resume_candidate(base, candidate_ref)
    end
  end

  @spec resumed_change(GenServer.server(), keyword()) :: Change.t()
  defp resumed_change(instance, opts) do
    case keyword_options(opts, @change_options) do
      :ok ->
        change(instance,
          by: Keyword.get(opts, :by, "actor:resumed"),
          reason: Keyword.get(opts, :reason, "resume governed Candidate"),
          evidence: Keyword.get(opts, :evidence, %{})
        )

      {:error, reason} ->
        instance |> invalid_change(opts) |> Change.fail(reason)
    end
  end

  @spec resume_candidate(Change.t(), CandidateRef.t() | String.t()) :: Change.t()
  defp resume_candidate(base, candidate_ref) do
    case Store.fetch_candidate(base.store, candidate_ref) do
      {:ok, %{governance: governance} = candidate} when not is_nil(governance) ->
        %{
          base
          | ref: Spectre.Definition.Candidate.ref(candidate),
            state: normalize_state(governance.state),
            report: governance.report
        }

      {:ok, _candidate} ->
        Change.fail(base, :candidate_is_not_governed)

      :not_found ->
        Change.fail(base, :governance_candidate_not_found)

      {:error, reason} ->
        Change.fail(base, reason)
    end
  end

  @spec nonempty(term(), atom()) :: :ok | {:error, term()}
  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(value, field), do: {:error, {:morph_requires, field, value}}

  @spec plain_map(term(), atom()) :: :ok | {:error, term()}
  defp plain_map(value, _field) when is_map(value) and not is_struct(value), do: :ok
  defp plain_map(value, field), do: {:error, {:invalid_morph_field, field, value}}

  @spec keyword_options(term(), [atom()]) :: :ok | {:error, term()}
  defp keyword_options(opts, allowed) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_morph_options, opts}}

      duplicate_keyword?(opts) ->
        {:error, :duplicate_morph_options}

      true ->
        reject_unknown_options(opts, allowed)
    end
  end

  @spec reject_unknown_options(keyword(), [atom()]) :: :ok | {:error, term()}
  defp reject_unknown_options(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_morph_options, unknown}}
    end
  end

  @spec duplicate_keyword?(keyword()) :: boolean()
  defp duplicate_keyword?(opts) do
    keys = Keyword.keys(opts)
    MapSet.size(MapSet.new(keys)) != length(keys)
  end

  @spec normalize_state(:composed | :evaluated | :approved | :rejected) :: Change.state()
  defp normalize_state(:composed), do: :draft
  defp normalize_state(:evaluated), do: :evaluated
  defp normalize_state(:approved), do: :approved
  defp normalize_state(:rejected), do: :rejected

  @spec placeholder_surface() :: Surface.t()
  defp placeholder_surface do
    Surface.new!(%{
      operation_types: ["mount_skill"],
      scope_ceiling: ["agent"],
      prompt_token_ceiling: 1,
      approval_requirement: "host_policy"
    })
  end
end
