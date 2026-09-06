defmodule Spectre.Duty.Frontier do
  @moduledoc """
  Incremental, disposable work remaining at a governed ledger prefix.

  Only cause selection lives here. The same pure cause constructors used by
  `Duty.Derive` still decide what is required. Indexes contain references, not
  duplicate records; they are rebuilt by the fold and never persisted as
  authority. Timers discover obligations, never dispose of them.

  A receipt acquired after a deadline cannot remove its pending timeout cause.
  Evidence acquired exactly at that deadline is still timely, matching the
  exhaustive derivation. Neither case can dispose an already materialized Duty.
  """

  alias Spectre.Duty.Derive.{
    Cause,
    Dispute,
    ErasureVerifiability,
    EvidenceMarker,
    Facts,
    ScopePromise
  }

  alias Spectre.Duty.Derive.Outcome, as: OutcomeCause

  defstruct by_ref: %{},
            pending: %{},
            deadlines: :gb_trees.empty(),
            subscriptions: %{},
            scopes_by_deadline: %{},
            outcomes_by_attempt: %{},
            outcomes_by_act: %{},
            erasures_by_act: %{},
            duties_by_act: %{}

  @type t :: %__MODULE__{}

  @doc false
  def record(state, %{type: "act_committed", identity: ref}) do
    act = Map.fetch!(state.acts, ref)
    subscribe(state, ref, act.recognition_evidence_refs)
  end

  def record(state, %{type: "attempt_started", identity: ref}) do
    attempt = Map.fetch!(state.attempts, ref)
    act = Map.fetch!(state.acts, attempt.act_ref)
    schedule(state, attempt.started_at + act.observation_window_ms, :attempt, ref)
  end

  def record(state, %{type: "outcome_recorded", identity: ref}) do
    outcome = Map.fetch!(state.outcomes, ref)
    frontier = state.read_index.duties

    frontier = %{
      frontier
      | outcomes_by_attempt: put_ref(frontier.outcomes_by_attempt, outcome.attempt_ref, ref),
        outcomes_by_act: put_ref(frontier.outcomes_by_act, outcome.act_ref, ref)
    }

    state = put(state, frontier)
    state = subscribe(state, outcome.act_ref, outcome.evidence_refs)
    state = derive_attempt(state, outcome.attempt_ref, state.recorded_at)

    erasures =
      Map.get(frontier.erasures_by_act, outcome.act_ref, MapSet.new()) |> MapSet.to_list()

    facts = Facts.from_state(state) |> Facts.select(%{erasures: erasures, outcomes: [ref]})
    add(state, ErasureVerifiability.causes(facts, state.constitution, state.recorded_at))
  end

  def record(state, %{type: "evidence_recorded", identity: ref}) do
    evidence = Map.fetch!(state.evidence, ref)

    if evidence.observed_at > state.recorded_at do
      schedule(state, evidence.observed_at, :evidence, ref)
    else
      state |> derive_evidence(ref, state.recorded_at) |> derive_scope_boundary()
    end
  end

  def record(state, %{type: "erasure_requested", identity: ref}) do
    erasure = Map.fetch!(state.erasures, ref)
    frontier = state.read_index.duties

    frontier = %{
      frontier
      | erasures_by_act: put_ref(frontier.erasures_by_act, erasure.source_act_ref, ref)
    }

    put(state, frontier)
  end

  def record(state, %{type: "scope_opened", identity: ref}) do
    case Map.fetch!(state.catalog.scopes, ref) do
      %{kind: kind, due_at: time} when kind in [:work, :vigil] and is_integer(time) ->
        frontier = state.read_index.duties

        frontier = %{
          frontier
          | scopes_by_deadline: put_ref(frontier.scopes_by_deadline, time, ref)
        }

        schedule(put(state, frontier), time, :scope, ref)

      _session ->
        state
    end
  end

  def record(state, %{type: "duty_opened", identity: ref}) do
    key = Map.fetch!(state.read_index.duties.by_ref, ref)
    duty = Map.fetch!(state.duties, key)
    frontier = state.read_index.duties

    frontier = %{
      frontier
      | pending: Map.delete(frontier.pending, key),
        duties_by_act: put_ref(frontier.duties_by_act, duty.act_ref, key)
    }

    put(state, frontier)
  end

  def record(state, _event), do: state

  @doc "Advances only deadlines reached at this trusted time; no I/O or authority is produced."
  def advance(state, time) when is_integer(time) do
    case next_deadline(state) do
      due when is_integer(due) and due <= time ->
        {{_due, kind, ref}, _value, rest} =
          :gb_trees.take_smallest(state.read_index.duties.deadlines)

        frontier = %{state.read_index.duties | deadlines: rest}

        put(state, frontier)
        |> derive_deadline(kind, ref, time)
        |> advance(time)

      _future_or_empty ->
        state
    end
  end

  @doc false
  def missing(state, time) do
    state = advance(state, time)

    state.read_index.duties.pending
    |> Map.values()
    |> Enum.sort_by(&Cause.stable_sort_key(&1.cause_key))
  end

  @doc false
  def next_deadline(state) do
    case :gb_trees.is_empty(state.read_index.duties.deadlines) do
      true ->
        nil

      false ->
        {{time, _kind, _ref}, _} = :gb_trees.smallest(state.read_index.duties.deadlines)
        time
    end
  end

  defp derive_deadline(state, :attempt, ref, time), do: derive_attempt(state, ref, time)
  defp derive_deadline(state, :evidence, ref, time), do: derive_evidence(state, ref, time)

  defp derive_deadline(state, :scope, ref, time) do
    facts = Facts.from_state(state) |> Facts.select(%{scopes: [ref]})

    state
    |> forget_pending({:scope_promise_overdue, ref})
    |> add(ScopePromise.causes(facts, state.constitution, time))
  end

  defp derive_scope_boundary(state) do
    state.read_index.duties.scopes_by_deadline
    |> Map.get(state.recorded_at, MapSet.new())
    |> Enum.reduce(state, &derive_deadline(&2, :scope, &1, state.recorded_at))
  end

  defp derive_attempt(state, ref, time) do
    refs =
      state.read_index.duties.outcomes_by_attempt
      |> Map.get(ref, MapSet.new())
      |> MapSet.to_list()

    facts = Facts.from_state(state) |> Facts.select(%{attempts: [ref], outcomes: refs})
    attempt = Map.fetch!(state.attempts, ref)
    act = Map.fetch!(state.acts, attempt.act_ref)

    state =
      state
      |> forget_pending({:ambiguous_outcome, act.ref, ref})
      |> add(OutcomeCause.causes(facts, state.constitution, time))

    deadline = attempt.started_at + act.observation_window_ms

    timely_terminal? =
      Enum.any?(refs, fn outcome_ref ->
        outcome = Map.fetch!(state.outcomes, outcome_ref)

        outcome.status in Spectre.Outcome.definitive_statuses() and
          Facts.available_at?(facts, outcome_ref, deadline)
      end)

    if timely_terminal?, do: unschedule(state, deadline, :attempt, ref), else: state
  end

  defp derive_evidence(state, ref, time) do
    evidence = Map.fetch!(state.evidence, ref)

    acts =
      state.read_index.duties.subscriptions
      |> Map.get(evidence.proposition, MapSet.new())
      |> MapSet.to_list()

    outcomes =
      Enum.flat_map(acts, fn act_ref ->
        state.read_index.duties.outcomes_by_act
        |> Map.get(act_ref, MapSet.new())
        |> MapSet.to_list()
      end)

    facts =
      Facts.from_state(state)
      |> Facts.select(%{acts: acts, outcomes: outcomes, counter_evidence: [ref], evidence: [ref]})

    add(
      state,
      Dispute.causes(facts, state.constitution, time) ++
        EvidenceMarker.causes(facts, state.constitution, time)
    )
  end

  defp subscribe(state, act_ref, evidence_refs) do
    subscriptions =
      Enum.reduce(evidence_refs, state.read_index.duties.subscriptions, fn ref, index ->
        case Map.fetch(state.evidence, ref) do
          {:ok, evidence} -> put_ref(index, evidence.proposition, act_ref)
          :error -> index
        end
      end)

    put(state, %{state.read_index.duties | subscriptions: subscriptions})
  end

  defp add(state, causes) do
    pending =
      Enum.reduce(causes, state.read_index.duties.pending, fn cause, pending ->
        if Map.has_key?(state.duties, cause.cause_key),
          do: pending,
          else: Map.put(pending, cause.cause_key, cause)
      end)

    put(state, %{state.read_index.duties | pending: pending})
  end

  defp forget_pending(state, key),
    do:
      put(state, %{
        state.read_index.duties
        | pending: Map.delete(state.read_index.duties.pending, key)
      })

  defp schedule(state, time, kind, ref) do
    deadlines = :gb_trees.enter({time, kind, ref}, true, state.read_index.duties.deadlines)
    put(state, %{state.read_index.duties | deadlines: deadlines})
  end

  defp unschedule(state, time, kind, ref) do
    deadlines = :gb_trees.delete_any({time, kind, ref}, state.read_index.duties.deadlines)
    put(state, %{state.read_index.duties | deadlines: deadlines})
  end

  defp put_ref(index, key, ref),
    do: Map.update(index, key, MapSet.new([ref]), &MapSet.put(&1, ref))

  defp put(state, frontier), do: %{state | read_index: %{state.read_index | duties: frontier}}
end
