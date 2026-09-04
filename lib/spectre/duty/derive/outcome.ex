defmodule Spectre.Duty.Derive.Outcome do
  @moduledoc """
  Derives containment Duties for ambiguous attempts and contradicted Outcomes.
  """

  alias Spectre.{Act, Attempt}
  alias Spectre.Duty.Derive.{Cause, Facts}
  alias Spectre.Outcome, as: OutcomeRecord

  @definitive_outcomes OutcomeRecord.definitive_statuses()

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    outcomes_by_attempt =
      Enum.group_by(facts.outcomes, fn {_ref, outcome} -> outcome.attempt_ref end, &elem(&1, 1))

    ambiguous_attempt_causes(facts, outcomes_by_attempt, constitution, time) ++
      contradicted_outcome_causes(facts, constitution, time)
  end

  @doc false
  @spec cause(Act.t(), Attempt.t(), OutcomeRecord.t(), map(), integer()) ::
          {:ok, map()} | {:error, term()}
  def cause(
        %Act{} = act,
        %Attempt{} = attempt,
        %OutcomeRecord{} = outcome,
        constitution,
        recorded_at
      )
      when is_map(constitution) and is_integer(recorded_at) do
    correction? = present?(outcome.contradicts_outcome_ref)

    with true <- outcome.status == :ambiguous or correction?,
         true <- attempt.act_ref == act.ref,
         true <- outcome.act_ref == act.ref,
         true <- outcome.attempt_ref == attempt.ref do
      kind = if correction?, do: :correction, else: :ambiguous
      build_cause(kind, act, attempt, outcome, constitution, recorded_at)
    else
      false -> {:error, :invalid_duty_outcome_cause}
    end
  end

  def cause(_act, _attempt, _outcome, _constitution, _recorded_at),
    do: {:error, :invalid_duty_outcome_cause}

  defp build_cause(:ambiguous, act, attempt, outcome, constitution, observed_at) do
    case observation_deadline(attempt, act) do
      {:ok, deadline} when observed_at > deadline ->
        {:ok, ambiguous_timeout_cause(act, attempt, [], deadline, constitution)}

      _before_or_without_deadline ->
        {:ok, outcome_duty_cause(:ambiguous, act, attempt, outcome, constitution, observed_at)}
    end
  end

  defp build_cause(:correction, act, attempt, outcome, constitution, observed_at) do
    {:ok, outcome_duty_cause(:correction, act, attempt, outcome, constitution, observed_at)}
  end

  defp ambiguous_attempt_causes(facts, outcomes_by_attempt, constitution, time) do
    Enum.flat_map(facts.attempts, fn {_attempt_ref, %Attempt{} = attempt} ->
      act = Map.get(facts.acts, attempt.act_ref)
      outcomes = Map.get(outcomes_by_attempt, attempt.ref, [])

      with %Act{} = act <- act,
           {:ok, deadline} <- observation_deadline(attempt, act),
           ambiguous_outcome = first_outcome(facts, outcomes, :ambiguous, min(time, deadline)),
           ambiguous_at = outcome_time_value(facts, ambiguous_outcome),
           {:ok, required_at} <- ambiguity_required_at(ambiguous_at, deadline, time),
           false <- is_nil(ambiguous_at) and definitive_outcome_by?(facts, outcomes, deadline) do
        case ambiguous_outcome do
          nil ->
            timely_outcomes = Enum.filter(outcomes, &observed_by?(facts, &1, deadline))

            [ambiguous_timeout_cause(act, attempt, timely_outcomes, required_at, constitution)]

          outcome ->
            case Facts.metadata(facts, outcome.ref) do
              {:ok, metadata} ->
                case cause(act, attempt, outcome, constitution, metadata.recorded_at) do
                  {:ok, cause} -> [Map.put(cause, :required_at, required_at)]
                  {:error, _reason} -> []
                end

              {:error, :missing_event_metadata} ->
                []
            end
        end
      else
        _other -> []
      end
    end)
  end

  defp contradicted_outcome_causes(facts, constitution, time) do
    Enum.flat_map(facts.outcomes, fn {_outcome_ref, %OutcomeRecord{} = outcome} ->
      with true <- present?(outcome.contradicts_outcome_ref),
           true <- observed_by?(facts, outcome, time),
           %Act{} = act <- Map.get(facts.acts, outcome.act_ref),
           %Attempt{} = attempt <- Map.get(facts.attempts, outcome.attempt_ref),
           {:ok, metadata} <- Facts.metadata(facts, outcome.ref),
           {:ok, cause} <- cause(act, attempt, outcome, constitution, metadata.recorded_at) do
        [cause]
      else
        _missing_or_invalid -> []
      end
    end)
  end

  defp outcome_duty_cause(
         :ambiguous,
         %Act{} = act,
         %Attempt{} = attempt,
         %OutcomeRecord{} = outcome,
         constitution,
         required_at
       ) do
    Cause.build(
      :ambiguous_outcome,
      {:ambiguous_outcome, act.ref, attempt.ref},
      %{"act_ref" => act.ref, "attempt_ref" => attempt.ref, "outcome_ref" => outcome.ref},
      constitution,
      %{
        act: act,
        known_evidence_refs: outcome.evidence_refs,
        missing_evidence: [:definitive_outcome],
        closing_conditions:
          Cause.closing_conditions(constitution, :ambiguous_outcome, [
            %{"kind" => :definitive_outcome, "attempt_ref" => attempt.ref}
          ]),
        required_at: required_at
      }
    )
  end

  defp outcome_duty_cause(
         :correction,
         %Act{} = act,
         %Attempt{} = attempt,
         %OutcomeRecord{} = outcome,
         constitution,
         required_at
       ) do
    Cause.build(
      :contradicted_outcome,
      {:contradicted_outcome, act.ref, attempt.ref, outcome.ref},
      %{
        "act_ref" => act.ref,
        "attempt_ref" => attempt.ref,
        "outcome_ref" => outcome.ref,
        "corrected_outcome_ref" => outcome.contradicts_outcome_ref
      },
      constitution,
      %{
        act: act,
        known_evidence_refs: outcome.evidence_refs,
        missing_evidence: [:reconciliation],
        closing_conditions: Cause.closing_conditions(constitution, :contradicted_outcome, []),
        required_at: required_at
      }
    )
  end

  defp ambiguous_timeout_cause(
         %Act{} = act,
         %Attempt{} = attempt,
         outcomes,
         required_at,
         constitution
       ) do
    Cause.build(
      :ambiguous_outcome,
      {:ambiguous_outcome, act.ref, attempt.ref},
      %{"act_ref" => act.ref, "attempt_ref" => attempt.ref},
      constitution,
      %{
        act: act,
        known_evidence_refs: outcome_evidence_refs(outcomes),
        missing_evidence: [:definitive_outcome],
        closing_conditions:
          Cause.closing_conditions(constitution, :ambiguous_outcome, [
            %{"kind" => :definitive_outcome, "attempt_ref" => attempt.ref}
          ]),
        required_at: required_at
      }
    )
  end

  defp observation_deadline(%Attempt{} = attempt, %Act{} = act),
    do: {:ok, attempt.started_at + act.observation_window_ms}

  defp definitive_outcome_by?(facts, outcomes, deadline) do
    Enum.any?(outcomes, &(definitive_outcome?(&1) and observed_by?(facts, &1, deadline)))
  end

  defp first_outcome(facts, outcomes, status, time) do
    outcomes
    |> Enum.filter(&(&1.status == status and observed_by?(facts, &1, time)))
    |> Enum.min_by(
      fn outcome -> {outcome_time_value(facts, outcome), outcome.ref} end,
      fn -> nil end
    )
  end

  defp ambiguity_required_at(ambiguous_at, deadline, _time) when is_integer(ambiguous_at),
    do: {:ok, min(ambiguous_at, deadline)}

  defp ambiguity_required_at(nil, deadline, time) do
    if is_integer(time) and is_integer(deadline) and time >= deadline,
      do: {:ok, deadline},
      else: :not_required
  end

  defp definitive_outcome?(%OutcomeRecord{status: status}), do: status in @definitive_outcomes

  defp observed_by?(facts, %OutcomeRecord{} = outcome, deadline),
    do: Facts.available_at?(facts, outcome.ref, deadline)

  defp outcome_time_value(facts, %OutcomeRecord{} = outcome) do
    case Facts.metadata(facts, outcome.ref) do
      {:ok, metadata} -> metadata.recorded_at
      {:error, :missing_event_metadata} -> nil
    end
  end

  defp outcome_time_value(_facts, nil), do: nil

  defp outcome_evidence_refs(outcomes) do
    outcomes
    |> Enum.flat_map(& &1.evidence_refs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
