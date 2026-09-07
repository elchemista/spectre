defmodule Spectre.Duty.Derive do
  @moduledoc """
  Pure composition of normative Duty causes from canonical governed facts.

  A Duty does not depend on a best-effort opening append having succeeded.
  Each cause family recomputes stable causes from the replayed ledger, allowing
  recovery to retain containment and retry materialization idempotently.

  This module is the public facade: dedicated modules derive Outcome,
  disputed-Evidence, Scope-promise, erasure-verifiability, and application
  marker causes. `Spectre.Duty.Derive.Facts` supplies their shared typed
  prefix view; this module deduplicates causes and converts them into Duty
  attributes.
  """

  alias Spectre.{Act, Attempt, Evidence, Outcome}

  alias Spectre.Duty.Derive.{
    Cause,
    Dispute,
    ErasureVerifiability,
    EvidenceMarker,
    Facts,
    ScopePromise
  }

  alias Spectre.Duty.Derive.Outcome, as: OutcomeCause
  alias Spectre.GovernedAct.{ReadIndex, State}

  @type cause :: %{
          required(:cause_key) => term(),
          required(:cause_class) => atom() | String.t(),
          required(:causal_refs) => map(),
          optional(atom()) => term()
        }

  @doc """
  Returns every distinct Duty cause implied by replayed `state` at trusted
  `time`. Existing Duty records do not erase their cause, so the result remains
  useful to an auditor. Use `missing_openings/2` for recovery materialization.
  """
  @spec required_duties(State.t(), integer()) :: [cause()]
  def required_duties(%State{} = state, time) when is_integer(time),
    do: required_duties(state, state.constitution, time)

  def required_duties(_state, _time), do: []

  @doc false
  @spec required_duties(State.t(), map(), integer()) :: [cause()]
  def required_duties(%State{} = state, constitution, time)
      when is_map(constitution) and not is_struct(constitution) and is_integer(time) do
    state
    |> Facts.from_state()
    |> derive_required_duties(constitution, time)
  end

  def required_duties(_state, _constitution, _time), do: []

  @doc """
  Rechecks one cause against the complete verified prefix.

  Only the causal sources are selected; proof, counterproof and historical
  dependencies remain available to the same constructors used by the exhaustive
  derivation. Existing Duties and the pending frontier are not proof of a cause.
  In particular, dispute lanes must run together: they merge evidence and choose
  one canonical cause per Act and counterproof.
  """
  @spec required_cause(State.t(), term(), integer()) :: cause() | nil
  def required_cause(%State{} = state, key, time),
    do: required_cause(state, state.constitution, key, time)

  def required_cause(_state, _key, _time), do: nil

  @doc false
  @spec required_cause(State.t(), map(), term(), integer()) :: cause() | nil
  def required_cause(%State{} = state, constitution, key, time)
      when is_map(constitution) and not is_struct(constitution) and is_integer(time) do
    {family, sources} = cause_sources(state, key)

    state
    |> Facts.from_state()
    |> Facts.select(sources)
    |> selected_causes(family, constitution, time)
    |> Enum.find(&(&1.cause_key === key))
  end

  def required_cause(_state, _constitution, _key, _time), do: nil

  @doc """
  Returns derived causes which have no durable Duty record yet.

  Both open and disposed records count as materialized. If an opening append was
  lost or ambiguous, its key is absent and the same cause is returned again.
  """
  @spec missing_openings(State.t(), integer()) :: [cause()]
  def missing_openings(%State{} = state, time) when is_integer(time) do
    facts = Facts.from_state(state)
    existing = facts.duties |> Map.keys() |> MapSet.new()

    facts
    |> derive_required_duties(state.constitution, time)
    |> Enum.reject(&MapSet.member?(existing, &1.cause_key))
  end

  def missing_openings(_state, _time), do: []

  @doc "Returns the stable identity of a derived cause."
  @spec cause_key(cause() | map()) :: term()
  def cause_key(cause) when is_map(cause), do: Map.get(cause, :cause_key)
  def cause_key(_cause), do: nil

  @doc false
  @spec available_evidence_at(State.t(), integer()) :: [Evidence.t()]
  def available_evidence_at(%State{} = state, time) when is_integer(time) do
    state |> Facts.from_state() |> Facts.available_evidence(time)
  end

  def available_evidence_at(_state, _time), do: []

  @doc """
  Converts a cause into the exact attributes accepted by `Spectre.Duty.new/1`.

  The cause's `:required_at` becomes `:opened_at`; the explicit time is only a
  fallback for an external cause without a canonical timestamp. A delayed
  append therefore cannot pretend that the historical gap started later.
  """
  @spec materialization_attrs(cause(), integer()) :: map()
  def materialization_attrs(cause, fallback_opened_at)
      when is_map(cause) and is_integer(fallback_opened_at) do
    causal_refs = Map.get(cause, :causal_refs, %{})
    opened_at = required_at(cause, fallback_opened_at)
    accountable = Map.get(cause, :accountable_ref)

    %{
      cause_key: Map.get(cause, :cause_key),
      class: Map.get(cause, :cause_class),
      act_ref: Map.get(causal_refs, "act_ref"),
      attempt_ref: Map.get(causal_refs, "attempt_ref"),
      mandate_ref: Map.get(cause, :mandate_ref),
      subjects: Map.get(cause, :subject_refs, []),
      accountable: accountable,
      evidence_refs: Map.get(cause, :known_evidence_refs, []),
      missing: Map.get(cause, :missing_evidence, []),
      containment: Map.get(cause, :containment, %{}),
      closing_conditions: Map.get(cause, :closing_conditions, []),
      disposition_authority_refs:
        cause |> Map.get(:disposition_authority) |> Cause.authority_refs(),
      conflict_refs: Map.get(cause, :conflict_refs, conflict_refs(accountable, [], nil)),
      opened_at: opened_at,
      status: :open,
      disposition_act_ref: nil
    }
  end

  @doc """
  Derives the canonical built-in Duty cause for an ambiguous or contradicted Outcome.

  Both live observation and ledger recovery use this constructor. The cause time
  is the Outcome's trusted observation time, so delayed materialization cannot
  rewrite when the Duty became required.
  """
  @spec outcome_cause(Act.t(), Attempt.t(), Outcome.t(), map(), integer()) ::
          {:ok, cause()} | {:error, term()}
  defdelegate outcome_cause(act, attempt, outcome, constitution, recorded_at),
    to: OutcomeCause,
    as: :cause

  @doc false
  @spec conflict_refs(String.t() | nil, term(), Act.t() | nil) :: [String.t()]
  defdelegate conflict_refs(accountable_ref, configured_refs, act), to: Cause

  defp cause_sources(state, {:ambiguous_outcome, _act, attempt}) do
    {OutcomeCause, %{attempts: [attempt], outcomes: outcome_refs(state, :attempt, attempt)}}
  end

  defp cause_sources(_state, {:contradicted_outcome, _act, _attempt, outcome}),
    do: {OutcomeCause, %{attempts: [], outcomes: [outcome]}}

  defp cause_sources(state, {:disputed_evidence, act, _lane, evidence}) do
    {Dispute,
     %{acts: [act], outcomes: outcome_refs(state, :act, act), counter_evidence: [evidence]}}
  end

  defp cause_sources(_state, {:scope_promise_overdue, scope}),
    do: {ScopePromise, %{scopes: [scope]}}

  defp cause_sources(
         _state,
         {:erasure_reduces_verifiability, erasure, _act, _attempt, _outcome}
       ),
       do: {ErasureVerifiability, %{erasures: [erasure]}}

  defp cause_sources(_state, {:evidence_gap, _class, evidence}),
    do: {EvidenceMarker, %{evidence: [evidence]}}

  defp cause_sources(_state, _key), do: {nil, %{}}

  defp outcome_refs(state, kind, ref) do
    field = if kind == :act, do: :act_ref, else: :attempt_ref

    # Pure callers may supply a State without derived indexes. The fallback
    # still selects every related Outcome, never only the one named by a claim.
    state
    |> ReadIndex.outcomes_for(kind, ref)
    |> Enum.reduce([], fn {outcome_ref, outcome}, refs ->
      if Map.fetch!(outcome, field) === ref, do: [outcome_ref | refs], else: refs
    end)
  end

  defp selected_causes(_facts, nil, _constitution, _time), do: []

  defp selected_causes(facts, family, constitution, time),
    do: family.causes(facts, constitution, time)

  defp derive_required_duties(%Facts{} = facts, constitution, time) do
    (OutcomeCause.causes(facts, constitution, time) ++
       Dispute.causes(facts, constitution, time) ++
       ScopePromise.causes(facts, constitution, time) ++
       ErasureVerifiability.causes(facts, constitution, time) ++
       EvidenceMarker.causes(facts, constitution, time))
    |> Enum.reduce(%{}, fn cause, unique -> Map.put_new(unique, cause.cause_key, cause) end)
    |> Map.values()
    |> Enum.sort_by(&Cause.stable_sort_key(&1.cause_key))
  end

  defp required_at(cause, fallback) do
    case Map.get(cause, :required_at) do
      value when is_integer(value) -> value
      _missing -> fallback
    end
  end
end
