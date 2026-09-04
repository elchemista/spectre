defmodule Spectre.Duty.Derive.Dispute.PresentationApproval do
  @moduledoc """
  Detects later Evidence that reverses a Presentation approval or its factual basis.
  """

  alias Spectre.{Act, Evidence, Presentation}
  alias Spectre.Duty.Derive.{Cause, Facts}

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    Enum.flat_map(facts.acts, fn {_act_ref, %Act{} = act} ->
      with presentation_ref when is_binary(presentation_ref) <- act.presentation_ref,
           true <- act.recognition_evidence_refs != [],
           {:ok, act_metadata} <- Facts.metadata(facts, act.ref),
           {:ok, presentation} <- Map.fetch(facts.presentations, presentation_ref),
           true <-
             Facts.recorded_through?(
               facts,
               presentation.ref,
               act_metadata.revision
             ) do
        historical_evidence =
          Facts.records_through(facts, facts.evidence, act_metadata.revision)

        historical_outcomes =
          Facts.records_through(facts, facts.outcomes, act_metadata.revision)

        facts
        |> approval_contexts(
          presentation,
          act.recognition_evidence_refs,
          historical_evidence,
          historical_outcomes,
          act.committed_at,
          act_metadata.revision
        )
        |> Enum.flat_map(
          &context_disputes(
            &1,
            act,
            act.recognition_evidence_refs,
            facts,
            constitution,
            act_metadata.revision,
            time
          )
        )
      else
        _not_applicable -> []
      end
    end)
  end

  defp approval_contexts(
         facts,
         presentation,
         recognition_evidence_refs,
         historical_evidence,
         historical_outcomes,
         committed_at,
         act_revision
       ) do
    recognized = MapSet.new(recognition_evidence_refs)

    historical_evidence
    |> Enum.filter(&MapSet.member?(recognized, &1.ref))
    |> Enum.sort_by(& &1.ref)
    |> Enum.flat_map(fn approval ->
      with {:ok, approved_presentation_ref, show_act_ref} <-
             Presentation.approval_refs(approval),
           true <- approved_presentation_ref == presentation.ref,
           {:ok, show_act} <- Map.fetch(facts.acts, show_act_ref),
           true <- Facts.recorded_through?(facts, show_act.ref, act_revision),
           {:ok, basis_refs} <-
             Presentation.validate_approval_with_basis(
               approval,
               presentation,
               show_act,
               historical_outcomes,
               historical_evidence,
               committed_at
             ),
           true <- Enum.all?(basis_refs, &MapSet.member?(recognized, &1)) do
        basis = MapSet.new(basis_refs)

        [
          %{
            approval: approval,
            basis_evidence: Enum.filter(historical_evidence, &MapSet.member?(basis, &1.ref)),
            basis_refs: basis_refs,
            presentation: presentation,
            show_act: show_act
          }
        ]
      else
        _not_approval_or_invalid -> []
      end
    end)
  end

  defp context_disputes(
         context,
         act,
         recognition_evidence_refs,
         facts,
         constitution,
         act_revision,
         time
       ) do
    ordered_basis =
      Enum.sort_by(context.basis_evidence, fn item ->
        {if(item.ref == context.approval.ref, do: 0, else: 1), item.ref}
      end)

    recognized = MapSet.new(recognition_evidence_refs)

    Enum.flat_map(facts.evidence, fn {_evidence_ref, %Evidence{} = evidence} ->
      with {:ok, metadata} <- Facts.later_evidence(facts, evidence, act_revision, time),
           false <- MapSet.member?(recognized, evidence.ref),
           %Evidence{} = prior <- Enum.find(ordered_basis, &Evidence.opposes?(&1, evidence)),
           prefix_evidence <-
             Facts.records_through(facts, facts.evidence, metadata.revision),
           prefix_outcomes <-
             Facts.records_through(facts, facts.outcomes, metadata.revision),
           {:ok, counter_basis_refs} <-
             validate_counter(
               evidence,
               prior,
               context,
               prefix_evidence,
               prefix_outcomes,
               metadata.recorded_at
             ) do
        [
          cause(
            act,
            context,
            prior.ref,
            evidence.ref,
            recognition_evidence_refs ++ counter_basis_refs,
            constitution,
            metadata.recorded_at
          )
        ]
      else
        _not_a_dispute -> []
      end
    end)
  end

  defp validate_counter(
         evidence,
         %Evidence{ref: approval_ref},
         %{approval: %Evidence{ref: approval_ref}} = context,
         prefix_evidence,
         prefix_outcomes,
         recorded_at
       ) do
    Presentation.validate_approval_contradiction_with_basis(
      evidence,
      context.presentation,
      context.show_act,
      prefix_outcomes,
      prefix_evidence,
      recorded_at
    )
  end

  defp validate_counter(
         evidence,
         _prior,
         context,
         prefix_evidence,
         _prefix_outcomes,
         recorded_at
       ) do
    Presentation.validate_assumption_contradiction_with_basis(
      evidence,
      context.approval,
      context.presentation,
      prefix_evidence,
      recorded_at
    )
  end

  defp cause(
         act,
         context,
         prior_evidence_ref,
         evidence_ref,
         known_evidence_refs,
         constitution,
         required_at
       ) do
    presentation_ref = context.presentation.ref

    Cause.build(
      :disputed_evidence,
      {:disputed_evidence, act.ref, {:presentation, presentation_ref}, evidence_ref},
      %{
        "act_ref" => act.ref,
        "mandate_ref" => act.mandate_ref,
        "presentation_ref" => presentation_ref,
        "approval_evidence_ref" => context.approval.ref,
        "disputed_evidence_ref" => prior_evidence_ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        known_evidence_refs:
          Cause.normalize_refs(context.basis_refs ++ known_evidence_refs ++ [evidence_ref]),
        missing_evidence: [:independent_resolution],
        closing_conditions: Cause.closing_conditions(constitution, :disputed_evidence, []),
        required_at: required_at
      }
    )
  end
end
