defmodule Spectre.Duty.Derive.EvidenceMarker do
  @moduledoc """
  Derives application-declared Duty causes from Constitution-authorized Evidence markers.
  """

  alias Spectre.Duty.Derive.{Cause, Facts}
  alias Spectre.Duty.EvidenceCause
  alias Spectre.Evidence

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    Enum.flat_map(Facts.sources(facts, :evidence), fn {_evidence_ref, %Evidence{} = evidence} ->
      with {:ok, metadata} <- Facts.metadata(facts, evidence.ref),
           true <- known_by?(metadata.recorded_at, evidence, time),
           {:ok, marker} <- EvidenceCause.extract(evidence, constitution) do
        [
          Cause.build(
            marker.class,
            EvidenceCause.cause_key(evidence, marker),
            %{"evidence_ref" => evidence.ref},
            constitution,
            %{
              mandate_ref: marker.mandate_ref,
              subject_refs: marker.subject_refs,
              accountable_ref: marker.accountable_ref,
              known_evidence_refs:
                Cause.normalize_refs([evidence.ref | marker.related_evidence_refs]),
              missing_evidence: marker.missing,
              required_at: metadata.recorded_at
            }
          )
        ]
      else
        _not_a_cause_or_not_yet_known -> []
      end
    end)
  end

  defp known_by?(recorded_at, %Evidence{} = evidence, time) do
    recorded_at <= time and evidence.observed_at <= time
  end
end
