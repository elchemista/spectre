defmodule Spectre.Kernel.Observation do
  @moduledoc """
  Purely plans the durable world-side half of an Attempt.

  It never calls an executor and never appends. Given a current projection and
  a validated Outcome, it produces one atomic payload set containing the
  observation, the conservative Meter transition and any Duty whose cause is
  already known. A late definitive Outcome may resolve a suspended quantity,
  but it never silently disposes the historical Duty.
  """

  alias Spectre.{Act, Attempt, Duty, Outcome}
  alias Spectre.Domain.{Event, Projection}
  alias Spectre.Duty.Derive
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.{MeterState, State}
  alias Spectre.GovernedAct.Transition.Outcome, as: OutcomeTransition
  alias Spectre.Kernel.Meter

  @correction_statuses Outcome.correction_statuses()

  @type result :: {:ok, [map()]} | {:error, term()}

  @spec payloads(Projection.t(), Outcome.t() | map() | keyword(), integer()) :: result()
  def payloads(%State{} = projection, outcome, time) when is_integer(time) do
    with {:ok, outcome} <- Outcome.new(outcome),
         :ok <- outcome_not_future(outcome, time),
         :ok <- unique_outcome(projection, outcome),
         {:ok, attempt, act} <- causal_records(projection, outcome),
         :ok <- OutcomeTransition.validate_state_history(projection, outcome),
         :ok <- OutcomeTransition.validate_for_act(act, outcome),
         :ok <-
           ErasureAnalysis.validate_evidence_available(projection, outcome.evidence_refs),
         :ok <- OutcomeTransition.validate_evidence(projection.evidence, outcome, attempt, act),
         {:ok, outcome_event} <- Event.record(:outcome, outcome),
         {:ok, meter_events} <- meter_events(projection, act, outcome),
         {:ok, duty_events} <- duty_events(projection, act, attempt, outcome, time) do
      {:ok, [outcome_event] ++ meter_events ++ duty_events}
    end
  end

  def payloads(%State{}, _outcome, time),
    do: {:error, {:invalid_trusted_time, time}}

  def payloads(_projection, _outcome, _time),
    do: {:error, :invalid_observation_input}

  defp unique_outcome(projection, outcome) do
    if Map.has_key?(projection.outcomes, outcome.ref),
      do: {:error, {:duplicate_outcome, outcome.ref}},
      else: :ok
  end

  defp outcome_not_future(%Outcome{observed_at: observed_at}, time)
       when observed_at <= time,
       do: :ok

  defp outcome_not_future(%Outcome{} = outcome, _time),
    do: {:error, {:outcome_from_future, outcome.ref, outcome.observed_at}}

  defp causal_records(projection, outcome) do
    with {:ok, %Attempt{} = attempt} <- Map.fetch(projection.attempts, outcome.attempt_ref),
         {:ok, %Act{} = act} <- Map.fetch(projection.acts, outcome.act_ref),
         true <- attempt.act_ref == act.ref,
         true <- outcome.act_ref == act.ref do
      {:ok, attempt, act}
    else
      :error -> {:error, :observation_cause_not_found}
      false -> {:error, :observation_cause_mismatch}
      _invalid -> {:error, :invalid_observation_cause}
    end
  end

  defp meter_events(_projection, %Act{reservations: reservations}, _outcome)
       when map_size(reservations) == 0,
       do: {:ok, []}

  defp meter_events(projection, act, outcome) do
    state = MeterState.reservation_status(projection, act.ref)

    case meter_operation(outcome, state) do
      nil -> {:ok, []}
      :missing -> {:error, {:reservation_state_missing, act.ref}}
      :invalid_correction_state -> {:error, {:invalid_correction_meter_state, act.ref, state}}
      :recontain -> recontainment_event(projection, act, outcome)
      operation -> with {:ok, event} <- Event.meter(operation, act), do: {:ok, [event]}
    end
  end

  defp meter_operation(outcome, state) do
    case {Outcome.correction?(outcome), outcome.status, state} do
      {true, _status, :released} ->
        :recontain

      {true, _status, _other} ->
        :invalid_correction_state

      {false, status, current}
      when status in @correction_statuses and current in [:reserved, :suspended] ->
        :settle

      {false, :definitive_no_effect, current} when current in [:reserved, :suspended] ->
        :release

      {false, :ambiguous, :reserved} ->
        :suspend

      {false, _status, nil} ->
        :missing

      {false, _status, _terminal} ->
        nil
    end
  end

  defp recontainment_event(projection, act, outcome) do
    with {:ok, reservation} <- MeterState.reservation(projection, act.ref),
         true <- reservation.mandate_ref == act.mandate_ref,
         {:ok, accounts} <- Projection.meter_accounts(projection, act.mandate_ref),
         {:ok, _accounts, recontained, deficits} <-
           Meter.recontain_many(reservation.amounts, accounts),
         {:ok, event} <- Event.meter_recontained(act, outcome, recontained, deficits) do
      {:ok, [event]}
    else
      false -> {:error, {:recontainment_mandate_mismatch, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp duty_events(projection, act, attempt, outcome, time) do
    if outcome.status == :ambiguous or Outcome.correction?(outcome) do
      with {:ok, cause} <-
             Derive.outcome_cause(
               act,
               attempt,
               outcome,
               projection.constitution,
               time
             ) do
        materialize_new_duty(projection, cause, time)
      end
    else
      {:ok, []}
    end
  end

  defp materialize_new_duty(projection, cause, time) do
    if Map.has_key?(projection.duties, cause.cause_key) do
      {:ok, []}
    else
      with {:ok, duty} <- Duty.new(Derive.materialization_attrs(cause, time)),
           {:ok, event} <- Event.record(:duty, duty) do
        {:ok, [event]}
      end
    end
  end
end
