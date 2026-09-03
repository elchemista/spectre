defmodule Spectre.Kernel.Observation do
  @moduledoc """
  Purely plans the durable world-side half of an Attempt.

  It never calls an executor and never appends. Given a current projection and
  a validated Outcome, it produces one atomic payload set containing the
  observation, the conservative Meter transition and any Duty whose cause is
  already known. A late definitive Outcome may resolve a suspended quantity,
  but it never silently disposes the historical Duty.
  """

  alias Spectre.Domain.{Event, Projection}
  alias Spectre.Duty.Derive
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Meter
  alias Spectre.Outcome.Attestation
  alias Spectre.{Act, Attempt, Duty, Evidence, Outcome}

  @type result :: {:ok, [map()]} | {:error, term()}

  @spec payloads(Projection.t(), Outcome.t() | map() | keyword(), integer(), map()) :: result()
  def payloads(projection, outcome, time, constitution \\ %{})

  def payloads(%State{} = projection, outcome, time, constitution)
      when is_integer(time) and is_map(constitution) do
    with {:ok, outcome} <- Outcome.new(outcome),
         :ok <- outcome_not_future(outcome, time),
         :ok <- unique_outcome(projection, outcome),
         {:ok, attempt, act} <- causal_records(projection, outcome),
         :ok <- validate_outcome_transition(projection, outcome),
         :ok <- validate_erasure_outcome(act, outcome),
         :ok <-
           ErasureAnalysis.validate_evidence_available(projection, outcome.evidence_refs),
         :ok <- validate_outcome_evidence(projection, outcome, attempt, act),
         {:ok, outcome_event} <- Event.record(:outcome, outcome),
         {:ok, meter_events} <- meter_events(projection, act, outcome),
         {:ok, duty_events} <- duty_events(projection, act, attempt, outcome, time, constitution) do
      {:ok, [outcome_event] ++ meter_events ++ duty_events}
    end
  end

  def payloads(%State{}, _outcome, time, _constitution),
    do: {:error, {:invalid_trusted_time, time}}

  def payloads(_projection, _outcome, _time, _constitution),
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

  defp validate_erasure_outcome(%Act{class: "data.erase"}, %Outcome{status: :failed}),
    do: {:error, :erasure_failure_must_be_definitive_or_ambiguous}

  defp validate_erasure_outcome(_act, _outcome), do: :ok

  defp validate_outcome_transition(projection, outcome) do
    prior =
      projection.outcomes
      |> Map.values()
      |> Enum.filter(&(&1.attempt_ref == outcome.attempt_ref))

    if Outcome.correction?(outcome) do
      validate_correction(prior, outcome)
    else
      case Enum.find(prior, &(&1.status != :ambiguous)) do
        nil ->
          :ok

        terminal ->
          {:error, {:attempt_already_has_definitive_outcome, outcome.attempt_ref, terminal.ref}}
      end
    end
  end

  defp validate_correction(prior, outcome) do
    target = Enum.find(prior, &(&1.ref == outcome.contradicts_outcome_ref))
    existing = Enum.find(prior, &(&1.contradicts_outcome_ref == outcome.contradicts_outcome_ref))

    cond do
      is_nil(target) ->
        {:error, {:corrected_outcome_not_found, outcome.contradicts_outcome_ref}}

      target.status != :definitive_no_effect ->
        {:error, {:corrected_outcome_not_no_effect, target.ref}}

      target.act_ref != outcome.act_ref or target.attempt_ref != outcome.attempt_ref ->
        {:error, {:outcome_correction_cause_mismatch, outcome.ref, target.ref}}

      outcome.observed_at < target.observed_at ->
        {:error, {:outcome_correction_precedes_target, outcome.ref, target.ref}}

      not is_nil(existing) ->
        {:error, {:outcome_already_corrected, target.ref, existing.ref}}

      true ->
        :ok
    end
  end

  defp meter_events(_projection, %Act{reservations: reservations}, _outcome)
       when map_size(reservations) == 0,
       do: {:ok, []}

  defp meter_events(projection, act, outcome) do
    state = Map.get(projection.reservation_states, act.ref)

    operation =
      case {Outcome.correction?(outcome), outcome.status, state} do
        {true, _status, :released} ->
          :recontain

        {true, _status, _other} ->
          :invalid_correction_state

        {false, status, current}
        when status in [:succeeded, :failed] and current in [:reserved, :suspended] ->
          :settle

        {false, :definitive_no_effect, current} when current in [:reserved, :suspended] ->
          :release

        {false, :ambiguous, :reserved} ->
          :suspend

        {false, :ambiguous, :suspended} ->
          nil

        {false, _status, nil} ->
          :missing

        {false, _status, _terminal} ->
          nil
      end

    case operation do
      nil -> {:ok, []}
      :missing -> {:error, {:reservation_state_missing, act.ref}}
      :invalid_correction_state -> {:error, {:invalid_correction_meter_state, act.ref, state}}
      :recontain -> recontainment_event(projection, act, outcome)
      operation -> with {:ok, event} <- Event.meter(operation, act), do: {:ok, [event]}
    end
  end

  defp recontainment_event(projection, act, outcome) do
    with {:ok, binding} <- Map.fetch(projection.reservation_bindings, act.ref),
         true <- binding.mandate_ref == act.mandate_ref,
         {:ok, accounts} <- Projection.meter_accounts(projection, act.mandate_ref),
         {:ok, _accounts, recontained, deficits} <-
           Meter.recontain_many(binding.amounts, accounts),
         {:ok, event} <- Event.meter_recontained(act, outcome, recontained, deficits) do
      {:ok, [event]}
    else
      false -> {:error, {:recontainment_mandate_mismatch, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_outcome_evidence(projection, outcome, attempt, act) do
    Enum.reduce_while(outcome.evidence_refs, :ok, fn ref, :ok ->
      case Map.fetch(projection.evidence, ref) do
        {:ok, %Evidence{} = evidence} ->
          case Attestation.validate(evidence, outcome, attempt, act) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:halt, {:error, {:outcome_evidence_not_found, ref}}}

        {:ok, _invalid} ->
          {:halt, {:error, {:invalid_outcome_evidence, ref}}}
      end
    end)
  end

  defp duty_events(projection, act, attempt, outcome, time, constitution) do
    if outcome.status == :ambiguous or Outcome.correction?(outcome) do
      with {:ok, cause} <- Derive.outcome_cause(act, attempt, outcome, constitution, time) do
        if Map.has_key?(projection.duties, cause.cause_key) do
          {:ok, []}
        else
          with attrs <- Derive.materialization_attrs(cause, time),
               {:ok, duty} <- Duty.new(attrs),
               {:ok, event} <- Event.record(:duty, duty) do
            {:ok, [event]}
          end
        end
      end
    else
      {:ok, []}
    end
  end
end
