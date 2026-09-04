defmodule Spectre.Evidence do
  @moduledoc """
  Portable Evidence about a proposition, kept separate from authority.

  Its explicit stance distinguishes support from contradiction. Evidence is
  also scoped by source, provenance, time, bindings and assumptions.
  `:generated` and provisional evidence remain visibly so; this record never
  promotes them to observed facts.
  """

  alias Spectre.{Label, Portable}

  @schema_version 1
  @provenance [:observed, :derived, :generated]
  @stances [:supports, :contradicts]
  @fields [
    :schema_version,
    :ref,
    :proposition,
    :stance,
    :issuer_ref,
    :source_ref,
    :provenance,
    :parent_refs,
    :observed_at,
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

  @enforce_keys [
    :schema_version,
    :ref,
    :proposition,
    :issuer_ref,
    :source_ref,
    :provenance,
    :parent_refs,
    :observed_at,
    :bindings,
    :assumptions,
    :labels,
    :provisional
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            proposition: nil,
            stance: :supports,
            issuer_ref: nil,
            source_ref: nil,
            provenance: nil,
            parent_refs: [],
            observed_at: nil,
            valid_from: nil,
            valid_until: nil,
            freshness_ms: nil,
            bindings: %{},
            assumptions: [],
            labels: [],
            payload: nil,
            payload_ref: nil,
            provisional: false

  @type stance :: :supports | :contradicts
  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          proposition: term(),
          stance: stance(),
          issuer_ref: String.t(),
          source_ref: String.t(),
          provenance: :observed | :derived | :generated,
          parent_refs: [String.t()],
          observed_at: integer(),
          valid_from: integer() | nil,
          valid_until: integer() | nil,
          freshness_ms: non_neg_integer() | nil,
          bindings: map(),
          assumptions: [term()],
          labels: [Label.t()],
          payload: term(),
          payload_ref: String.t() | nil,
          provisional: boolean()
        }

  @doc "Builds and validates evidence."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = evidence), do: evidence |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :evidence),
         attrs <- defaults(attrs),
         {:ok, parent_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :parent_refs), :parent_refs),
         {:ok, labels} <- normalize_labels(Map.fetch!(attrs, :labels)),
         attrs = attrs |> Map.put(:parent_refs, parent_refs) |> Map.put(:labels, labels),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         evidence = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(evidence),
         :ok <- Portable.validate(canonical(evidence)) do
      {:ok, evidence}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = evidence), do: canonical_fields(evidence, @fields)

  @doc "Restores evidence from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :evidence)

  @doc "Returns the stable digest of the complete evidence record."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = evidence), do: evidence |> canonical() |> Portable.digest!()

  @doc "Returns whether two records assert opposite stances for the same proposition."
  @spec opposes?(t(), t()) :: boolean()
  def opposes?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.proposition == right.proposition and
      {left.stance, right.stance} in [
        {:supports, :contradicts},
        {:contradicts, :supports}
      ]
  end

  def opposes?(_left, _right), do: false

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = evidence),
    do: Portable.content_ref!(:evidence, content(evidence))

  @doc "Returns canonical labels de-duplicated and ordered by stable reference."
  @spec normalize_labels(term()) :: {:ok, [Label.t()]} | {:error, term()}
  def normalize_labels(labels) do
    case Label.normalize_many(labels) do
      {:ok, labels} -> {:ok, labels}
      {:error, reason} -> {:error, {:invalid_evidence_labels, reason}}
    end
  end

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:stance, :supports)
    |> Map.put_new(:parent_refs, [])
    |> Map.put_new(:valid_from, nil)
    |> Map.put_new(:valid_until, nil)
    |> Map.put_new(:freshness_ms, nil)
    |> Map.put_new(:bindings, %{})
    |> Map.put_new(:assumptions, [])
    |> Map.put_new(:labels, [])
    |> Map.put_new(:payload, nil)
    |> Map.put_new(:payload_ref, nil)
    |> Map.put_new(:provisional, false)
  end

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:evidence, ref, content(attrs))

  defp content(%__MODULE__{} = evidence), do: evidence |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    canonical_fields(attrs, @fields -- [:ref])
  end

  defp canonical_fields(source, fields) do
    source
    |> Portable.canonical_fields(fields)
    |> Map.update!("labels", &Enum.map(&1, fn label -> Label.canonical(label) end))
  end

  defp validate_record(%__MODULE__{} = evidence) do
    with :ok <- validate_schema(evidence),
         :ok <- validate_claim(evidence),
         :ok <- validate_timing(evidence),
         :ok <- validate_body(evidence) do
      validate_refs(evidence)
    end
  end

  defp validate_schema(evidence) do
    if evidence.schema_version == @schema_version,
      do: :ok,
      else: {:error, {:unsupported_evidence_schema_version, evidence.schema_version}}
  end

  defp validate_claim(evidence) do
    cond do
      is_nil(evidence.proposition) ->
        {:error, :missing_evidence_proposition}

      evidence.stance not in @stances ->
        {:error, {:invalid_evidence_stance, evidence.stance}}

      evidence.provenance not in @provenance ->
        {:error, {:invalid_evidence_provenance, evidence.provenance}}

      evidence.provenance == :observed and evidence.parent_refs != [] ->
        {:error, {:observed_evidence_has_parents, evidence.ref}}

      evidence.provenance in [:derived, :generated] and evidence.parent_refs == [] ->
        {:error, {:evidence_lineage_required, evidence.ref, evidence.provenance}}

      true ->
        :ok
    end
  end

  defp validate_timing(evidence) do
    cond do
      not is_integer(evidence.observed_at) ->
        {:error, {:invalid_evidence_observed_at, evidence.observed_at}}

      not valid_time_range?(
        evidence.observed_at,
        evidence.valid_from,
        evidence.valid_until
      ) ->
        {:error, {:invalid_evidence_time_window, evidence.valid_from, evidence.valid_until}}

      not (is_nil(evidence.freshness_ms) or
               (is_integer(evidence.freshness_ms) and evidence.freshness_ms >= 0)) ->
        {:error, {:invalid_evidence_freshness_ms, evidence.freshness_ms}}

      evidence.provisional and is_nil(evidence.valid_until) and
          is_nil(evidence.freshness_ms) ->
        {:error, :provisional_evidence_requires_finite_lifetime}

      true ->
        :ok
    end
  end

  defp validate_body(evidence) do
    cond do
      not is_map(evidence.bindings) or is_struct(evidence.bindings) ->
        {:error, {:invalid_evidence_bindings, Portable.shape(evidence.bindings)}}

      not is_list(evidence.assumptions) ->
        {:error, {:invalid_evidence_assumptions, Portable.shape(evidence.assumptions)}}

      not is_list(evidence.labels) ->
        {:error, {:invalid_evidence_labels, Portable.shape(evidence.labels)}}

      is_nil(evidence.payload) and is_nil(evidence.payload_ref) ->
        {:error, :missing_evidence_payload_or_ref}

      not is_nil(evidence.payload) and not is_nil(evidence.payload_ref) ->
        {:error, :evidence_payload_and_ref_are_mutually_exclusive}

      not is_boolean(evidence.provisional) ->
        {:error, {:invalid_evidence_provisional, evidence.provisional}}

      true ->
        :ok
    end
  end

  defp validate_refs(evidence) do
    with :ok <- Portable.validate_ref(evidence.ref, :ref),
         :ok <- Portable.validate_ref(evidence.issuer_ref, :issuer_ref),
         :ok <- Portable.validate_ref(evidence.source_ref, :source_ref),
         :ok <- Portable.validate_refs(evidence.parent_refs, :parent_refs) do
      validate_optional_payload_ref(evidence.payload_ref)
    end
  end

  defp valid_time_range?(_observed_at, nil, nil), do: true
  defp valid_time_range?(_observed_at, from, nil), do: is_integer(from)

  defp valid_time_range?(observed_at, nil, until),
    do: is_integer(until) and until > observed_at

  defp valid_time_range?(observed_at, from, until),
    do:
      is_integer(from) and is_integer(until) and until > observed_at and
        from < until

  defp validate_optional_payload_ref(nil), do: :ok

  defp validate_optional_payload_ref(value),
    do: Portable.validate_content_ref(value, :payload, :payload_ref)
end
