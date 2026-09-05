defmodule Spectre.GovernedAct.Transition.Execution do
  @moduledoc """
  Replays the world-side transitions of an admitted governed Act.

  `dispatch_ready` is the last ledger-side state before capability use.
  `attempt_started` consumes the grant nonce and rechecks authority at the
  actual start time. `outcome_recorded` then binds observation to that exact
  Attempt and validates its attested Evidence.

  This module is deliberately pure: executors and other I/O live outside the
  governed-act fold.
  """

  alias Spectre.Act
  alias Spectre.Attempt.Binding
  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.{AuthorityChange, DispatchState, Index, MeterState, State, View}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.Transition.Outcome, as: OutcomeTransition
  alias Spectre.Kernel.Authority

  @spec apply(State.t(), Event.t(), non_neg_integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def apply(%State{} = state, %Event{type: "dispatch_ready", data: data}, _revision) do
    act_ref = data["act_ref"]

    with {:ok, act} <- Index.fetch_act(state, act_ref),
         :ok <- validate_dispatch(state, act, data) do
      {:ok, DispatchState.mark_pending(state, act_ref)}
    end
  end

  def apply(
        %State{} = state,
        %Event{type: "dispatch_cancelled", identity: identity, data: data},
        _revision
      ) do
    act_ref = data["act_ref"]

    with :ok <- exact_prefixed_identity(identity, "dispatch_cancelled", act_ref),
         {:ok, act} <- Index.fetch_act(state, act_ref),
         :ok <- validate_dispatch_cancellation(state, act, data) do
      cancellation = %{
        cause_ref: data["cause_ref"],
        reason: data["reason"],
        cancelled_at: data["cancelled_at"]
      }

      {:ok, DispatchState.mark_cancelled(state, act.ref, cancellation)}
    end
  end

  def apply(
        %State{} = state,
        %Event{type: "attempt_started", identity: identity, data: data},
        _revision
      ) do
    with {:ok, attempt} <-
           Index.restore_unique(state.attempts, Spectre.Attempt, identity, data, :attempt),
         {:ok, act} <- Index.fetch_act(state, attempt.act_ref),
         :ok <- attempt_available(state, attempt, act),
         :ok <- nonce_available(state, attempt.grant_nonce_digest),
         :ok <- match_attempt_to_act(attempt, act),
         :ok <- validate_attempt_authority(state, attempt, act) do
      act_ref = attempt.act_ref

      state = %{state | attempts: Map.put(state.attempts, identity, attempt)}
      state = DispatchState.mark_attempted(state, act_ref, identity)

      {:ok,
       %{state | consumed_nonces: MapSet.put(state.consumed_nonces, attempt.grant_nonce_digest)}}
    end
  end

  def apply(
        %State{} = state,
        %Event{type: "outcome_recorded", identity: identity, data: data},
        _revision
      ) do
    with {:ok, outcome} <-
           Index.restore_unique(state.outcomes, Spectre.Outcome, identity, data, :outcome),
         {:ok, attempt} <- Index.fetch_attempt(state, outcome.attempt_ref),
         {:ok, act} <- Index.fetch_act(state, outcome.act_ref),
         :ok <- match_outcome_to_attempt(state, outcome, attempt),
         :ok <- OutcomeTransition.validate_for_act(act, outcome),
         :ok <- validate_outcome_time(outcome, attempt),
         :ok <- OutcomeTransition.validate_history(state.outcomes, outcome),
         :ok <- ErasureAnalysis.validate_evidence_available(state, outcome.evidence_refs),
         :ok <- OutcomeTransition.validate_evidence(state.evidence, outcome, attempt, act) do
      {:ok, %{state | outcomes: Map.put(state.outcomes, identity, outcome)}}
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_execution_event, type}}

  defp exact_prefixed_identity(identity, prefix, ref) when is_binary(ref) and ref != "",
    do: Record.match_identity(identity, prefix <> ":" <> ref)

  defp exact_prefixed_identity(_identity, _prefix, _ref),
    do: {:error, :invalid_domain_event_identity_binding}

  defp attempt_available(state, attempt, act) do
    cond do
      not GovernedExecution.executor_mediated?(act) ->
        {:error, {:act_not_executor_mediated, act.ref}}

      DispatchState.attempted?(state, act.ref) ->
        {:error,
         {:act_already_attempted, attempt.act_ref, DispatchState.attempt_ref(state, act.ref)}}

      not DispatchState.pending?(state, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      Act.reservations?(act) and MeterState.reservation_status(state, act.ref) != :reserved ->
        {:error, {:act_reservation_not_attemptable, act.ref}}

      true ->
        :ok
    end
  end

  defp nonce_available(state, nonce_digest) do
    if MapSet.member?(state.consumed_nonces, nonce_digest),
      do: {:error, {:grant_nonce_already_consumed, nonce_digest}},
      else: :ok
  end

  defp match_attempt_to_act(attempt, act) do
    case Binding.mismatch(attempt, act) do
      {:act_ref, _expected, _actual} ->
        {:error, {:attempt_act_mismatch, attempt.ref, act.ref}}

      {:executor_ref, _expected, _actual} ->
        {:error, {:attempt_executor_mismatch, attempt.ref, act.ref}}

      {:material_digest, _expected, _actual} ->
        {:error, {:attempt_material_mismatch, attempt.ref, act.ref}}

      nil ->
        if attempt.started_at < act.committed_at,
          do: {:error, {:attempt_precedes_act, attempt.ref, act.ref}},
          else: :ok
    end
  end

  defp match_outcome_to_attempt(state, outcome, attempt) do
    cond do
      outcome.act_ref != attempt.act_ref ->
        {:error, {:outcome_act_mismatch, outcome.ref, attempt.ref}}

      DispatchState.attempt_ref(state, outcome.act_ref) != attempt.ref ->
        {:error, {:outcome_attempt_index_mismatch, outcome.ref, attempt.ref}}

      true ->
        :ok
    end
  end

  defp validate_outcome_time(outcome, attempt) do
    if outcome.observed_at >= attempt.started_at,
      do: :ok,
      else: {:error, {:outcome_precedes_attempt, outcome.ref, attempt.ref}}
  end

  defp validate_attempt_authority(state, attempt, act) do
    with {:ok, mandate} <- Index.fetch_mandate(state, act.mandate_ref),
         :ok <- Authority.dispatchable?(act, mandate, View.authority(state), attempt.started_at) do
      :ok
    else
      {:error, reason} -> {:error, {:act_without_current_authority, act.ref, reason}}
    end
  end

  defp validate_dispatch(state, act, data) do
    cond do
      not GovernedExecution.executor_mediated?(act) ->
        {:error, {:act_not_executor_mediated, act.ref}}

      data["executor_ref"] != act.executor_ref ->
        {:error, {:dispatch_executor_mismatch, act.ref}}

      data["executor_contract_ref"] != act.executor_contract_ref ->
        {:error, {:dispatch_contract_mismatch, act.ref}}

      true ->
        validate_dispatch_state(state, act)
    end
  end

  defp validate_dispatch_state(state, act) do
    cond do
      DispatchState.pending?(state, act.ref) ->
        {:error, {:duplicate_dispatch_ready, act.ref}}

      DispatchState.cancelled?(state, act.ref) ->
        {:error, {:dispatch_already_cancelled, act.ref}}

      DispatchState.attempted?(state, act.ref) ->
        {:error, {:act_already_attempted, act.ref}}

      open_disputed_duty_for_act?(state, act.ref) ->
        {:error, {:act_dispatch_blocked_by_disputed_evidence, act.ref}}

      Act.reservations?(act) and MeterState.reservation_status(state, act.ref) != :reserved ->
        {:error, {:act_reservation_not_ready, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_dispatch_cancellation(state, act, data) do
    cond do
      not GovernedExecution.executor_mediated?(act) ->
        {:error, {:dispatch_cancellation_act_not_executor_mediated, act.ref}}

      DispatchState.attempted?(state, act.ref) ->
        {:error, {:dispatch_cancellation_after_attempt, act.ref}}

      DispatchState.cancelled?(state, act.ref) ->
        {:error, {:duplicate_dispatch_cancellation, act.ref}}

      not DispatchState.pending?(state, act.ref) ->
        {:error, {:dispatch_cancellation_not_pending, act.ref}}

      data["mandate_ref"] != act.mandate_ref ->
        {:error, {:dispatch_cancellation_mandate_mismatch, act.ref}}

      Act.reservations?(act) and MeterState.reservation_status(state, act.ref) != :reserved ->
        {:error, {:dispatch_cancellation_reservation_not_pending, act.ref}}

      true ->
        validate_dispatch_cancellation_cause(state, act, data)
    end
  end

  defp validate_dispatch_cancellation_cause(state, act, data) do
    case data["reason"] do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        with {:ok, cause_act} <- Index.fetch_act(state, data["cause_ref"]),
             :ok <- validate_governance_cancellation_time(act, cause_act, data),
             {:ok, target_mandate_ref, cascade?} <-
               AuthorityChange.resolve(state, cause_act, reason),
             {:ok, true} <-
               AuthorityChange.affects?(
                 state,
                 act.mandate_ref,
                 target_mandate_ref,
                 cascade?
               ) do
          :ok
        else
          {:ok, false} -> {:error, {:dispatch_cancellation_mandate_not_affected, act.ref}}
          {:error, _reason} = error -> error
        end

      :disputed_evidence ->
        with {:ok, duty} <- Index.fetch_duty_by_ref(state, data["cause_ref"]),
             true <- duty.class == :disputed_evidence,
             true <- duty.status == :open,
             true <- duty.act_ref == act.ref,
             true <- is_nil(duty.attempt_ref),
             true <- duty.mandate_ref == act.mandate_ref,
             true <- data["cancelled_at"] == duty.opened_at,
             true <- act.committed_at <= duty.opened_at do
          :ok
        else
          false -> {:error, {:invalid_disputed_dispatch_cancellation, act.ref}}
          {:error, _reason} = error -> error
        end

      :mandate_expired ->
        with {:ok, mandate} <- Index.fetch_mandate(state, act.mandate_ref),
             true <- data["cause_ref"] == mandate.ref,
             true <- act.mandate_revision == mandate.revision,
             true <- data["cancelled_at"] == mandate.expires_at do
          :ok
        else
          false -> {:error, {:invalid_dispatch_expiration, act.ref}}
          {:error, _reason} = error -> error
        end

      reason ->
        {:error, {:invalid_dispatch_cancellation_reason, act.ref, reason}}
    end
  end

  defp validate_governance_cancellation_time(act, cause_act, data) do
    cond do
      data["cause_ref"] != cause_act.ref ->
        {:error, {:dispatch_cancellation_cause_mismatch, act.ref}}

      data["cancelled_at"] != cause_act.committed_at ->
        {:error, {:dispatch_cancellation_time_mismatch, act.ref}}

      act.committed_at > cause_act.committed_at ->
        {:error, {:dispatch_cancellation_precedes_act, act.ref}}

      true ->
        :ok
    end
  end

  defp open_disputed_duty_for_act?(state, act_ref) do
    Enum.any?(state.duties, fn {_cause_key, duty} ->
      duty.class == :disputed_evidence and duty.status == :open and duty.act_ref == act_ref and
        is_nil(duty.attempt_ref)
    end)
  end
end
