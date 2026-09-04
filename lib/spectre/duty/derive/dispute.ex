defmodule Spectre.Duty.Derive.Dispute do
  @moduledoc """
  Composes Duties caused by later Evidence disputing an admitted Act.

  Each causal lane rebuilds its own historical prefix: Mandate-condition
  recognition, Presentation approval, or executor Outcome attestation. This
  module owns only deterministic lane order and cross-lane deduplication.
  """

  alias Spectre.Duty.Derive.{Cause, Facts}

  alias Spectre.Duty.Derive.Dispute.{
    MandateCondition,
    OutcomeAttestation,
    PresentationApproval
  }

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time)
      when is_map(constitution) and is_integer(time) do
    (MandateCondition.causes(facts, constitution, time) ++
       PresentationApproval.causes(facts, constitution, time) ++
       OutcomeAttestation.causes(facts, constitution, time))
    |> deduplicate()
  end

  defp deduplicate(causes) do
    causes
    |> Enum.sort_by(fn cause ->
      {
        lane_rank(cause.cause_key),
        Cause.stable_sort_key(cause.cause_key),
        Cause.stable_sort_key(cause.causal_refs)
      }
    end)
    |> Enum.reduce(%{}, fn cause, unique ->
      identity = {cause.causal_refs["act_ref"], cause.causal_refs["evidence_ref"]}

      Map.update(unique, identity, cause, fn existing ->
        Map.update!(existing, :known_evidence_refs, fn refs ->
          Cause.normalize_refs(refs ++ cause.known_evidence_refs)
        end)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&Cause.stable_sort_key(&1.cause_key))
  end

  defp lane_rank({:disputed_evidence, _act_ref, {:presentation, _ref}, _evidence_ref}), do: 1
  defp lane_rank({:disputed_evidence, _act_ref, {:outcome, _ref}, _evidence_ref}), do: 2
  defp lane_rank(_mandate_condition), do: 0
end
