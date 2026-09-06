defmodule Spectre.Duty.Derive.Dispute.OutcomeAttestation do
  @moduledoc """
  Detects a later trusted executor attestation that reverses a definitive Outcome.
  """

  alias Spectre.Duty.Derive.{Cause, Facts}
  alias Spectre.{Evidence, Outcome}
  alias Spectre.Outcome.Attestation

  @definitive_outcomes Outcome.definitive_statuses()

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    Enum.flat_map(Facts.sources(facts, :outcomes), fn {_outcome_ref, %Outcome{} = outcome} ->
      with true <- outcome.status in @definitive_outcomes,
           {:ok, outcome_metadata} <- Facts.metadata(facts, outcome.ref),
           true <- outcome_metadata.recorded_at <= time,
           {:ok, act} <- Map.fetch(facts.acts, outcome.act_ref),
           {:ok, attempt} <- Map.fetch(facts.attempts, outcome.attempt_ref),
           true <- attempt.act_ref == act.ref,
           true <- outcome.evidence_refs != [],
           used_evidence when used_evidence != [] <-
             trusted_evidence(
               facts,
               outcome.evidence_refs,
               outcome,
               act,
               attempt,
               outcome_metadata.revision
             ) do
        counter_causes(
          facts,
          used_evidence,
          outcome,
          act,
          attempt,
          constitution,
          outcome_metadata.revision,
          time
        )
      else
        _not_applicable -> []
      end
    end)
  end

  defp counter_causes(
         facts,
         used_evidence,
         outcome,
         act,
         attempt,
         constitution,
         outcome_revision,
         time
       ) do
    recognized = MapSet.new(outcome.evidence_refs)

    Enum.flat_map(Facts.sources(facts, :counter_evidence), fn {_evidence_ref, evidence} ->
      with {:ok, metadata} <- Facts.later_evidence(facts, evidence, outcome_revision, time),
           false <- MapSet.member?(recognized, evidence.ref),
           true <- trusted_counter?(evidence, used_evidence, act, attempt, metadata.recorded_at) do
        [
          cause(
            act,
            attempt,
            outcome,
            evidence.ref,
            outcome.evidence_refs,
            constitution,
            metadata.recorded_at
          )
        ]
      else
        _not_a_dispute -> []
      end
    end)
  end

  defp trusted_evidence(facts, evidence_refs, outcome, act, attempt, outcome_revision) do
    expected = MapSet.new(evidence_refs)

    trusted =
      facts
      |> Facts.evidence_through(outcome_revision)
      |> Enum.filter(fn evidence ->
        MapSet.member?(expected, evidence.ref) and
          trusted_attestation?(evidence, outcome.status, act, attempt, outcome.observed_at)
      end)

    if Cause.normalize_refs(Enum.map(trusted, & &1.ref)) == Cause.normalize_refs(evidence_refs),
      do: trusted,
      else: []
  end

  defp trusted_counter?(evidence, used_evidence, act, attempt, recorded_at) do
    Attestation.causal?(evidence, act, attempt, recorded_at) and
      Enum.any?(used_evidence, &Evidence.opposes?(&1, evidence))
  end

  defp trusted_attestation?(evidence, status, act, attempt, observed_at) do
    if status == :ambiguous,
      do: Attestation.causal?(evidence, act, attempt, observed_at),
      else: Attestation.supports?(evidence, status, act, attempt, observed_at)
  end

  defp cause(
         act,
         attempt,
         outcome,
         evidence_ref,
         outcome_evidence_refs,
         constitution,
         required_at
       ) do
    Cause.build(
      :disputed_evidence,
      {:disputed_evidence, act.ref, {:outcome, outcome.ref}, evidence_ref},
      %{
        "act_ref" => act.ref,
        "attempt_ref" => attempt.ref,
        "outcome_ref" => outcome.ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        known_evidence_refs:
          Cause.normalize_refs(
            act.recognition_evidence_refs ++ outcome_evidence_refs ++ [evidence_ref]
          ),
        missing_evidence: [:independent_resolution],
        closing_conditions: Cause.closing_conditions(constitution, :disputed_evidence, []),
        required_at: required_at
      }
    )
  end
end
