defmodule Spectre.Duty.Derive.Dispute.MandateCondition do
  @moduledoc """
  Detects later Evidence that reverses a Mandate-condition basis frozen by an Act.
  """

  alias Spectre.{Act, Condition, Evidence}
  alias Spectre.Duty.Derive.{Cause, Facts}
  alias Spectre.Kernel.Recognition

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    Enum.flat_map(facts.acts, fn {_act_ref, %Act{} = act} ->
      with {:ok, mandate} <- Map.fetch(facts.mandates, act.mandate_ref),
           {:ok, act_metadata} <- Facts.metadata(facts, act.ref),
           true <- act.recognition_evidence_refs != [] do
        historical = Facts.evidence_through(facts, act_metadata.revision)

        Enum.flat_map(mandate.conditions, fn condition ->
          condition_disputes(
            condition,
            act,
            act.recognition_evidence_refs,
            historical,
            facts,
            constitution,
            act.committed_at,
            act_metadata.revision,
            time
          )
        end)
      else
        _not_applicable -> []
      end
    end)
  end

  defp condition_disputes(
         %Condition{} = condition,
         act,
         recognition_evidence_refs,
         historical,
         facts,
         constitution,
         committed_at,
         act_revision,
         time
       ) do
    case Recognition.check_with_basis([condition], historical, committed_at) do
      {:satisfied, basis_refs} ->
        recognized = MapSet.new(recognition_evidence_refs)
        basis = MapSet.new(basis_refs)

        used =
          Enum.filter(historical, fn evidence ->
            MapSet.member?(basis, evidence.ref) and MapSet.member?(recognized, evidence.ref)
          end)

        Enum.flat_map(facts.evidence, fn {_evidence_ref, evidence} ->
          if evidence_dispute?(
               evidence,
               used,
               recognized,
               condition,
               facts,
               act_revision,
               time
             ) do
            [
              condition_cause(
                act,
                condition,
                recognition_evidence_refs,
                evidence,
                facts,
                constitution
              )
            ]
          else
            []
          end
        end)

      _not_satisfied ->
        []
    end
  end

  defp evidence_dispute?(
         evidence,
         used,
         recognized,
         condition,
         facts,
         act_revision,
         time
       ) do
    with false <- MapSet.member?(recognized, evidence.ref),
         {:ok, metadata} <- Facts.later_evidence(facts, evidence, act_revision, time),
         true <- Enum.any?(used, &Evidence.opposes?(&1, evidence)) do
      Recognition.qualified?(
        evidence,
        condition,
        Facts.evidence_through(facts, metadata.revision),
        metadata.recorded_at
      )
    else
      _not_a_dispute -> false
    end
  end

  defp condition_cause(
         act,
         condition,
         recognition_evidence_refs,
         evidence,
         facts,
         constitution
       ) do
    {:ok, metadata} = Facts.metadata(facts, evidence.ref)
    contemporaneous = Facts.evidence_through(facts, metadata.revision)

    {_result, current_basis_refs} =
      Recognition.check_with_basis([condition], contemporaneous, metadata.recorded_at)

    known_evidence_refs =
      Cause.normalize_refs(recognition_evidence_refs ++ current_basis_refs ++ [evidence.ref])

    Cause.build(
      :disputed_evidence,
      {:disputed_evidence, act.ref, condition.ref, evidence.ref},
      %{
        "act_ref" => act.ref,
        "mandate_ref" => act.mandate_ref,
        "condition_ref" => condition.ref,
        "evidence_ref" => evidence.ref
      },
      constitution,
      %{
        act: act,
        known_evidence_refs: known_evidence_refs,
        missing_evidence: [:independent_resolution],
        closing_conditions: Cause.closing_conditions(constitution, :disputed_evidence, []),
        required_at: metadata.recorded_at
      }
    )
  end
end
