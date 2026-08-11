defmodule Spectre.Morph.GovernancePipeline do
  @moduledoc """
  Executes the durable governance commits behind the `Spectre.Morph` facade.

  A Morph change remains transient until this module composes a Candidate.
  Evaluation, approval, and activation are deliberately separate commits: the
  convenience API never turns an Agent-authored proposal into authority.
  """

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

  @evaluate_options [
    :cases,
    :now,
    :receipts,
    :delta,
    :checker_versions,
    :prompt_token_ceiling
  ]
  @approve_options [:by, :mode, :now, :policy, :expires_at]
  @reject_options [:by, :reason, :now]
  @activate_options [:now, :checker_versions]

  @doc false
  @spec evaluate(Change.t(), term()) :: Change.t()
  def evaluate(%Change{error: error} = change, _opts) when not is_nil(error), do: change

  def evaluate(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, @evaluate_options),
         :ok <- require_state(change, :draft),
         false <- change.operations == [],
         :ok <- prompt_ceiling(Keyword.get(opts, :prompt_token_ceiling)),
         {:ok, surface} <- canonical_surface(change),
         change = %{change | surface: surface},
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
      true -> Change.fail(change, :morph_has_no_changes)
      {:error, reason} -> Change.fail(change, reason)
      _invalid -> Change.fail(change, :candidate_is_not_governed)
    end
  end

  def evaluate(%Change{} = change, opts),
    do: Change.fail(change, {:invalid_morph_options, opts})

  @doc false
  @spec approve(Change.t(), term()) :: Change.t()
  def approve(%Change{error: error} = change, _opts) when not is_nil(error), do: change

  def approve(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, @approve_options),
         :ok <- require_state(change, :evaluated),
         {:ok, surface} <- canonical_surface(change),
         {:ok, approval_opts} <- approval_opts(surface, opts),
         {:ok, approved_ref} <- Approval.approve(change.store, change.ref, approval_opts) do
      %{change | state: :approved, ref: approved_ref}
    else
      {:error, reason} -> Change.fail(change, reason)
    end
  end

  def approve(%Change{} = change, opts),
    do: Change.fail(change, {:invalid_morph_options, opts})

  @doc false
  @spec reject(Change.t(), term()) :: Change.t()
  def reject(%Change{error: error} = change, _opts) when not is_nil(error), do: change

  def reject(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, @reject_options),
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
      {:error, reason} -> Change.fail(change, reason)
    end
  end

  def reject(%Change{} = change, opts),
    do: Change.fail(change, {:invalid_morph_options, opts})

  @doc false
  @spec activate(Change.t(), term()) :: {:ok, Activation.t()} | {:error, term()}
  def activate(%Change{error: error}, _opts) when not is_nil(error), do: {:error, error}

  def activate(%Change{} = change, opts) when is_list(opts) do
    with :ok <- keyword_options(opts, @activate_options),
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

  @spec change_set(Change.t(), term()) :: {:ok, ChangeSet.t()} | {:error, term()}
  defp change_set(change, now) do
    with {:ok, evidence_digest} <- evidence_digest(change) do
      ChangeSet.new(%{
        base_activation_receipt: change.activation.activation_receipt,
        base_candidate_ref: change.activation.candidate_ref,
        observed_definition_ref: change.activation.definition_ref,
        observed_authority_epoch: change.activation.authority_epoch,
        observed_evidence_digest: evidence_digest,
        operations: change.operations,
        author_ref: change.actor_ref,
        provenance: %{
          "origin" => "spectre.morph",
          "change_surface_digest" => Surface.digest(change.surface)
        },
        reason: change.reason,
        created_at: now
      })
    end
  end

  @spec evidence_digest(Change.t()) :: {:ok, String.t()} | {:error, :invalid_morph_evidence}
  defp evidence_digest(change) do
    {:ok, ChangeSet.evidence_digest(change.activation, change.evidence)}
  rescue
    ArgumentError -> {:error, :invalid_morph_evidence}
  end

  @spec compose(Change.t(), ChangeSet.t(), term(), keyword()) ::
          {:ok, Spectre.Definition.Candidate.Ref.t()} | {:error, term()}
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

  @spec gate(Change.t(), Spectre.Definition.Candidate.t(), keyword(), term()) ::
          {:ok, Spectre.Governance.EvaluationDelta.t(), [Spectre.Gate.Receipt.t()]}
          | {:error, term()}
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

  @spec approval_opts(Surface.t(), keyword()) :: {:ok, keyword()} | {:error, term()}
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

      {:ok, maybe_put_mode(approval_opts, mode)}
    end
  end

  @spec maybe_put_mode(keyword(), :automatic | :human | nil) :: keyword()
  defp maybe_put_mode(opts, nil), do: opts
  defp maybe_put_mode(opts, mode), do: Keyword.put(opts, :mode, mode)

  @spec effective_approval_mode(Surface.t(), term()) :: :automatic | :human | nil | term()
  defp effective_approval_mode(%Surface{approval_requirement: :human}, nil), do: :human
  defp effective_approval_mode(_surface, mode), do: mode

  @spec approval_actor(Surface.t(), term()) :: :ok | {:error, term()}
  defp approval_actor(%Surface{approval_requirement: :human}, actor), do: nonempty(actor, :by)
  defp approval_actor(_surface, actor), do: optional_nonempty(actor, :by)

  @spec approval_requirement(Surface.t(), term()) :: :ok | {:error, term()}
  defp approval_requirement(%Surface{approval_requirement: :human}, :human), do: :ok

  defp approval_requirement(%Surface{approval_requirement: :human}, mode),
    do: {:error, {:morph_requires_human_approval, mode}}

  defp approval_requirement(%Surface{approval_requirement: :host_policy}, mode)
       when mode in [nil, :human, :automatic],
       do: :ok

  defp approval_requirement(_surface, mode),
    do: {:error, {:invalid_governance_approval_mode, mode}}

  @spec canonical_surface(Change.t()) :: {:ok, Surface.t()} | {:error, term()}
  defp canonical_surface(change) do
    with {:ok, resolution} <- Resolver.resolve(change.store, change.activation.definition_ref) do
      Surface.from_canonical(resolution.definition)
    end
  end

  @spec require_state(Change.t(), Change.state()) :: :ok | {:error, term()}
  defp require_state(%Change{state: state}, state), do: :ok

  defp require_state(%Change{state: actual}, expected),
    do: {:error, {:morph_state, expected, actual}}

  @spec nonempty(term(), atom()) :: :ok | {:error, term()}
  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(value, field), do: {:error, {:morph_requires, field, value}}

  @spec optional_nonempty(term(), atom()) :: :ok | {:error, term()}
  defp optional_nonempty(nil, _field), do: :ok
  defp optional_nonempty(value, field), do: nonempty(value, field)

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

  @spec min_ceiling(term(), number()) :: number()
  defp min_ceiling(requested, declared) when is_number(requested) and requested >= 0,
    do: min(requested, declared)

  defp min_ceiling(_requested, declared), do: declared

  @spec prompt_ceiling(term()) :: :ok | {:error, term()}
  defp prompt_ceiling(nil), do: :ok
  defp prompt_ceiling(value) when is_number(value) and value >= 0, do: :ok
  defp prompt_ceiling(value), do: {:error, {:invalid_morph_prompt_ceiling, value}}

  @spec checker_versions(keyword()) :: term()
  defp checker_versions(opts),
    do: Keyword.get(opts, :checker_versions, Declarative.checker_versions())

  @spec timestamp(keyword()) :: term()
  defp timestamp(opts),
    do: Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)
end
