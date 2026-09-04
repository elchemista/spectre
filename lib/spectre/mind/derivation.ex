defmodule Spectre.Mind.Derivation do
  @moduledoc """
  Pure construction and binding rules for Evidence derived by a Mind.

  A derivation is tied to the exact Turn that supplied its parents: the Mind is
  both source and issuer, all visible Evidence remains in its lineage, and the
  sanitized SubmissionContext remains in its bindings. The live Domain may
  additionally supply a trusted upper time bound before recording it.

  Keeping these rules beside the Turn lets the application-facing builder and
  the authoritative recording boundary validate the same value without making
  Mind state, options or callbacks part of governed state.
  """

  alias Spectre.{Evidence, Portable, SubmissionContext}
  alias Spectre.Evidence.Derivation, as: EvidenceDerivation
  alias Spectre.Mind.Turn

  @evidence_fields [
    :ref,
    :proposition,
    :stance,
    :provenance,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :bindings,
    :assumptions,
    :labels,
    :payload,
    :payload_ref,
    :provisional
  ]

  @doc false
  @spec build(Turn.t(), integer(), map() | keyword()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def build(%Turn{} = turn, observed_at, attrs) when is_integer(observed_at) do
    with {:ok, context} <- Turn.context(turn),
         {:ok, attrs} <- Portable.normalize_attrs(attrs, @evidence_fields, :mind_evidence),
         provenance = Map.get(attrs, :provenance, :generated),
         :ok <- valid_provenance(provenance),
         {:ok, labels} <-
           EvidenceDerivation.conservative_labels(turn.evidence, Map.get(attrs, :labels, [])),
         {:ok, bindings} <-
           SubmissionContext.merge_evidence_bindings(context, Map.get(attrs, :bindings, %{})),
         {:ok, evidence} <-
           attrs
           |> Map.put(:issuer_ref, turn.mind_ref)
           |> Map.put(:source_ref, turn.mind_ref)
           |> Map.put(:provenance, provenance)
           |> Map.put(:parent_refs, Turn.evidence_refs(turn))
           |> Map.put(:observed_at, observed_at)
           |> Map.put(:bindings, bindings)
           |> Map.put(:labels, labels)
           |> Evidence.new(),
         :ok <- validate_record(evidence, turn, context, turn.evidence, nil) do
      {:ok, evidence}
    end
  end

  def build(_turn, _observed_at, _attrs), do: {:error, :invalid_mind_evidence}

  @doc false
  @spec normalize(Turn.t(), Evidence.t() | [Evidence.t()]) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def normalize(%Turn{}, []), do: {:ok, []}
  def normalize(%Turn{} = turn, %Evidence{} = evidence), do: normalize(turn, [evidence])

  def normalize(%Turn{} = turn, derivations) when is_list(derivations) do
    with {:ok, context} <- Turn.context(turn) do
      derivations
      |> Enum.reduce_while({:ok, [], MapSet.new(Turn.evidence_refs(turn))}, fn value,
                                                                               {:ok, records,
                                                                                refs} ->
        with {:ok, evidence} <- Evidence.new(value),
             false <- MapSet.member?(refs, evidence.ref),
             :ok <- validate_record(evidence, turn, context, turn.evidence, nil) do
          {:cont, {:ok, [evidence | records], MapSet.put(refs, evidence.ref)}}
        else
          true -> {:halt, {:error, :duplicate_mind_derivation}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, records, _refs} -> {:ok, Enum.reverse(records)}
        {:error, _reason} = error -> error
      end
    end
  end

  def normalize(_turn, _derivations), do: {:error, :invalid_mind_derivations}

  @doc false
  @spec validate(Evidence.t(), Turn.t(), [Evidence.t()], non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def validate(evidence, turn, parents, observed_through \\ nil)

  def validate(%Evidence{} = evidence, %Turn{} = turn, parents, observed_through)
      when is_list(parents) and
             (is_nil(observed_through) or
                (is_integer(observed_through) and observed_through >= 0)) do
    with {:ok, context} <- Turn.context(turn) do
      validate_record(evidence, turn, context, parents, observed_through)
    end
  end

  def validate(_evidence, _turn, _parents, _observed_through),
    do: {:error, :invalid_mind_derivation}

  defp validate_record(evidence, turn, context, parents, observed_through) do
    with :ok <- valid_provenance(evidence.provenance),
         :ok <- exact_mind(evidence, turn),
         :ok <- valid_time(evidence, turn, observed_through),
         :ok <- SubmissionContext.validate_evidence_bindings(context, evidence.bindings) do
      EvidenceDerivation.validate(evidence, parents)
    end
  end

  defp valid_provenance(provenance) when provenance in [:derived, :generated], do: :ok

  defp valid_provenance(provenance),
    do: {:error, {:invalid_mind_evidence_provenance, provenance}}

  defp exact_mind(%Evidence{} = evidence, %Turn{} = turn) do
    cond do
      evidence.source_ref != turn.mind_ref ->
        {:error, {:mind_derivation_source_mismatch, evidence.ref}}

      evidence.issuer_ref != turn.mind_ref ->
        {:error, {:mind_derivation_issuer_mismatch, evidence.ref}}

      true ->
        :ok
    end
  end

  defp valid_time(%Evidence{} = evidence, %Turn{} = turn, observed_through) do
    cond do
      evidence.observed_at < turn.opened_at ->
        {:error, {:mind_derivation_precedes_turn, evidence.ref}}

      is_integer(observed_through) and evidence.observed_at > observed_through ->
        {:error, {:mind_derivation_from_future, evidence.ref}}

      true ->
        :ok
    end
  end
end
