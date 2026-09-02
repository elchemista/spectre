defmodule Spectre.Evidence.Derivation do
  @moduledoc """
  Conservative lineage rules for derived or generated Evidence.

  Spectre cannot know which individual source influenced an output.  A value
  produced from a context therefore inherits the union of every label in that
  context.  This module only computes and verifies that lower bound; removing
  a label remains a separately governed declassification Act.
  """

  alias Spectre.{Evidence, Label}

  @doc "Returns the stable union of labels carried by all supplied Evidence."
  @spec inherited_labels([Evidence.t()]) :: {:ok, [Label.t()]} | {:error, term()}
  def inherited_labels(evidence) when is_list(evidence) do
    with {:ok, evidence} <- normalize_evidence(evidence),
         {:ok, labels} <- normalize_labels(Enum.flat_map(evidence, & &1.labels)) do
      {:ok, labels}
    end
  end

  def inherited_labels(_evidence), do: {:error, :invalid_derivation_evidence}

  @doc "Adds optional stricter labels without permitting inherited labels to disappear."
  @spec conservative_labels([Evidence.t()], [Label.t() | map() | keyword()]) ::
          {:ok, [Label.t()]} | {:error, term()}
  def conservative_labels(evidence, additional_labels \\ [])

  def conservative_labels(evidence, additional_labels) when is_list(additional_labels) do
    with {:ok, inherited} <- inherited_labels(evidence),
         {:ok, labels} <- normalize_labels(inherited ++ additional_labels) do
      {:ok, labels}
    end
  end

  def conservative_labels(_evidence, _labels), do: {:error, :invalid_derivation_labels}

  @doc "Verifies exact parents and conservative labels for a derived/generated record."
  @spec validate(Evidence.t(), [Evidence.t()]) :: :ok | {:error, term()}
  def validate(%Evidence{} = derived, parents) when is_list(parents) do
    with {:ok, derived} <- Evidence.new(derived),
         {:ok, parents} <- normalize_evidence(parents),
         :ok <- derived_provenance(derived),
         :ok <- exact_parents(derived, parents),
         {:ok, inherited} <- inherited_labels(parents) do
      labels_cover?(derived.labels, inherited, derived.ref)
    end
  end

  def validate(_derived, _parents), do: {:error, :invalid_evidence_derivation}

  defp normalize_evidence(evidence) do
    Enum.reduce_while(evidence, {:ok, []}, fn value, {:ok, normalized} ->
      case Evidence.new(value) do
        {:ok, record} -> {:cont, {:ok, [record | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_derivation_parent, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_labels(labels) do
    Evidence.normalize_labels(labels)
  end

  defp derived_provenance(%Evidence{provenance: provenance})
       when provenance in [:derived, :generated],
       do: :ok

  defp derived_provenance(%Evidence{provenance: provenance}),
    do: {:error, {:invalid_derivation_provenance, provenance}}

  defp exact_parents(derived, parents) do
    expected = parents |> Enum.map(& &1.ref) |> Enum.uniq() |> Enum.sort()

    if derived.parent_refs == expected,
      do: :ok,
      else: {:error, {:evidence_parent_mismatch, derived.ref, derived.parent_refs, expected}}
  end

  defp labels_cover?(actual, required, evidence_ref) do
    actual_keys = MapSet.new(actual, & &1.ref)
    required_keys = MapSet.new(required, & &1.ref)

    if MapSet.subset?(required_keys, actual_keys),
      do: :ok,
      else: {:error, {:evidence_labels_not_conservative, evidence_ref}}
  end
end
