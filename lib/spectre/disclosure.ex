defmodule Spectre.Disclosure do
  @moduledoc """
  Closed description of information crossing a Domain boundary.

  The descriptor names destinations and the durable Evidence that may have
  influenced the output. Labels are derived from those Evidence records by the
  kernel; callers cannot use this value to assert weaker labels.
  """

  alias Spectre.{Evidence, Label, Portable, Row}
  alias Spectre.Evidence.Derivation

  @schema_version 1
  @fields [:schema_version, :destination_refs, :source_evidence_refs, :labels]
  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            destination_refs: [],
            source_evidence_refs: [],
            labels: []

  @type t :: %__MODULE__{
          schema_version: 1,
          destination_refs: [String.t()],
          source_evidence_refs: [String.t()],
          labels: [Label.t()]
        }

  @doc "Builds the canonical disclosure descriptor."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = disclosure), do: disclosure |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :disclosure),
         attrs = Map.put_new(attrs, :schema_version, @schema_version),
         {:ok, destinations} <-
           Portable.normalize_refs(Map.get(attrs, :destination_refs, []), :destination_refs),
         {:ok, sources} <-
           Portable.normalize_refs(
             Map.get(attrs, :source_evidence_refs, []),
             :source_evidence_refs
           ),
         {:ok, labels} <- Evidence.normalize_labels(Map.get(attrs, :labels, [])),
         disclosure = %__MODULE__{
           schema_version: Map.fetch!(attrs, :schema_version),
           destination_refs: destinations,
           source_evidence_refs: sources,
           labels: labels
         },
         :ok <- validate(disclosure),
         :ok <- Portable.validate(canonical(disclosure)) do
      {:ok, disclosure}
    end
  end

  @doc "Returns the plain ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = disclosure) do
    %{
      "schema_version" => disclosure.schema_version,
      "destination_refs" => disclosure.destination_refs,
      "source_evidence_refs" => disclosure.source_evidence_refs,
      "labels" => Enum.map(disclosure.labels, &Label.canonical/1)
    }
  end

  @doc "Restores a descriptor from its canonical representation."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value), do: new(value)

  @doc "Validates how the descriptor relates to one Candidate or Act."
  @spec validate_boundary(Row.t(), t() | nil, [String.t()], [String.t()]) ::
          :ok | {:error, term()}
  def validate_boundary(%Row{disclose: false}, nil, _target_refs, _evidence_refs), do: :ok

  def validate_boundary(%Row{disclose: false}, %__MODULE__{}, _target_refs, _evidence_refs),
    do: {:error, :disclosure_not_declared_in_row}

  def validate_boundary(
        %Row{disclose: true},
        %__MODULE__{} = disclosure,
        target_refs,
        evidence_refs
      ) do
    cond do
      not Enum.all?(disclosure.destination_refs, &(&1 in target_refs)) ->
        {:error, :disclosure_destination_outside_targets}

      not Enum.all?(disclosure.source_evidence_refs, &(&1 in evidence_refs)) ->
        {:error, :disclosure_source_outside_evidence}

      true ->
        :ok
    end
  end

  def validate_boundary(%Row{disclose: true}, nil, _target_refs, _evidence_refs),
    do: {:error, :disclosure_descriptor_required}

  @doc "Checks that every source exists and that its conservative label union is exact."
  @spec verify_sources(t(), %{optional(String.t()) => Evidence.t()}) ::
          :ok | {:error, term()}
  def verify_sources(%__MODULE__{} = disclosure, evidence_index) when is_map(evidence_index) do
    with {:ok, evidence} <- fetch_sources(disclosure.source_evidence_refs, evidence_index),
         {:ok, expected_labels} <- Derivation.inherited_labels(evidence),
         true <- expected_labels == disclosure.labels do
      :ok
    else
      false -> {:error, :disclosure_labels_not_derived_from_sources}
      {:error, _reason} = error -> error
    end
  end

  def verify_sources(_disclosure, _evidence_index), do: {:error, :invalid_disclosure_sources}

  @doc "Returns true when every disclosed label is explicitly covered by a Mandate."
  @spec labels_covered?(t(), [Label.t()]) :: boolean()
  def labels_covered?(%__MODULE__{} = disclosure, allowed_labels) when is_list(allowed_labels) do
    with {:ok, allowed_labels} <- Label.normalize_many(allowed_labels) do
      allowed = MapSet.new(allowed_labels, & &1.ref)
      Enum.all?(disclosure.labels, &MapSet.member?(allowed, &1.ref))
    else
      {:error, _reason} -> false
    end
  end

  def labels_covered?(_disclosure, _allowed_labels), do: false

  defp validate(%__MODULE__{} = disclosure) do
    cond do
      disclosure.schema_version != @schema_version ->
        {:error, {:unsupported_disclosure_schema_version, disclosure.schema_version}}

      disclosure.destination_refs == [] ->
        {:error, :disclosure_destinations_required}

      true ->
        :ok
    end
  end

  defp fetch_sources(refs, evidence_index) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, evidence} ->
      case Map.fetch(evidence_index, ref) do
        {:ok, %Evidence{} = item} -> {:cont, {:ok, [item | evidence]}}
        {:ok, _invalid} -> {:halt, {:error, {:invalid_disclosure_evidence, ref}}}
        :error -> {:halt, {:error, {:disclosure_evidence_not_found, ref}}}
      end
    end)
    |> case do
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      {:error, _reason} = error -> error
    end
  end
end
