defmodule Spectre.Declassification do
  @moduledoc """
  Portable proof that an authorized Act removed information labels.

  The output `Evidence` remains content-addressed independently of the Act.
  This record is materialized only after admission and forms the acyclic link
  from the governing Act to that immutable Evidence.  Label ownership is
  represented by stable content references so Mandates can constrain each
  label without imposing a universal label taxonomy on applications.
  """

  alias Spectre.{Evidence, Label, Portable}

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :source_act_ref,
    :evidence_ref,
    :parent_refs,
    :removed_labels,
    :removed_label_refs,
    :removed_owner_refs,
    :recorded_at
  ]
  @draft_fields [
    :schema_version,
    :evidence,
    :removed_labels,
    :removed_label_refs,
    :removed_owner_refs
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :source_act_ref,
    :evidence_ref,
    :parent_refs,
    :removed_labels,
    :removed_label_refs,
    :removed_owner_refs,
    :recorded_at
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            source_act_ref: nil,
            evidence_ref: nil,
            parent_refs: [],
            removed_labels: [],
            removed_label_refs: [],
            removed_owner_refs: [],
            recorded_at: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          source_act_ref: String.t(),
          evidence_ref: String.t(),
          parent_refs: [String.t()],
          removed_labels: [Label.t()],
          removed_label_refs: [String.t()],
          removed_owner_refs: [String.t()],
          recorded_at: integer()
        }

  @typedoc false
  @type decoded_draft :: %{
          required(:canonical) => map(),
          required(:evidence) => Evidence.t(),
          required(:removed_labels) => [Label.t()],
          required(:removed_label_refs) => [String.t()],
          required(:removed_owner_refs) => [String.t()]
        }

  @doc "Builds and validates a declassification record tied to its governing Act."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = declassification),
    do: declassification |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :declassification),
         attrs <- Map.put_new(attrs, :schema_version, @schema_version),
         {:ok, parent_refs} <-
           Portable.normalize_refs(Map.get(attrs, :parent_refs, []), :parent_refs),
         {:ok, removed_labels} <- normalize_labels(Map.get(attrs, :removed_labels, [])),
         {:ok, removed_label_refs} <-
           Portable.normalize_refs(
             Map.get(attrs, :removed_label_refs, []),
             :removed_label_refs
           ),
         {:ok, removed_owner_refs} <-
           Portable.normalize_refs(
             Map.get(attrs, :removed_owner_refs, []),
             :removed_owner_refs
           ),
         attrs =
           attrs
           |> Map.put(:parent_refs, parent_refs)
           |> Map.put(:removed_labels, removed_labels)
           |> Map.put(:removed_label_refs, removed_label_refs)
           |> Map.put(:removed_owner_refs, removed_owner_refs),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         record = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(record),
         :ok <- Portable.validate(canonical(record)) do
      {:ok, record}
    end
  end

  @doc "Returns the exact pre-Act material carried by a `data.declassify` Candidate."
  @spec draft(Evidence.t() | map() | keyword(), [Label.t() | map() | keyword()]) ::
          {:ok, map()} | {:error, term()}
  def draft(evidence, removed_labels) do
    with {:ok, evidence} <- Evidence.new(evidence),
         :ok <- declassifiable_provenance(evidence),
         {:ok, removed_labels} <- normalize_labels(removed_labels),
         :ok <- non_empty_labels(removed_labels),
         :ok <- labels_absent_from_output(removed_labels, evidence),
         {:ok, removed_label_refs} <- refs_for_labels(removed_labels),
         {:ok, removed_owner_refs} <- owner_refs(removed_labels) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "evidence" => Evidence.canonical(evidence),
         "removed_labels" => Enum.map(removed_labels, &Label.canonical/1),
         "removed_label_refs" => removed_label_refs,
         "removed_owner_refs" => removed_owner_refs
       }}
    end
  end

  @doc "Decodes and canonicalizes Candidate declassification material."
  @spec decode_draft(map() | keyword()) :: {:ok, decoded_draft()} | {:error, term()}
  def decode_draft(attrs) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(attrs, @draft_fields, :evidence_declassification),
         :ok <- draft_schema(Map.get(attrs, :schema_version)),
         {:ok, evidence} <- Evidence.from_canonical(Map.get(attrs, :evidence)),
         {:ok, canonical} <- draft(evidence, Map.get(attrs, :removed_labels)),
         {:ok, supplied_refs} <-
           Portable.normalize_refs(
             Map.get(attrs, :removed_label_refs),
             :removed_label_refs
           ),
         :ok <- exact_label_refs(supplied_refs, canonical["removed_label_refs"]),
         {:ok, supplied_owner_refs} <-
           Portable.normalize_refs(
             Map.get(attrs, :removed_owner_refs),
             :removed_owner_refs
           ),
         :ok <- exact_owner_refs(supplied_owner_refs, canonical["removed_owner_refs"]),
         {:ok, removed_labels} <- normalize_labels(canonical["removed_labels"]) do
      {:ok,
       %{
         canonical: canonical,
         evidence: evidence,
         removed_labels: removed_labels,
         removed_label_refs: canonical["removed_label_refs"],
         removed_owner_refs: canonical["removed_owner_refs"]
       }}
    end
  end

  @doc "Materializes the post-admission record without adding an Act reference to Evidence."
  @spec from_draft(map(), String.t(), integer()) :: {:ok, t()} | {:error, term()}
  def from_draft(draft, source_act_ref, recorded_at)
      when is_map(draft) and not is_struct(draft) and is_binary(source_act_ref) and
             source_act_ref != "" and is_integer(recorded_at) do
    with {:ok, decoded} <- decode_draft(draft) do
      new(%{
        source_act_ref: source_act_ref,
        evidence_ref: decoded.evidence.ref,
        parent_refs: decoded.evidence.parent_refs,
        removed_labels: decoded.removed_labels,
        removed_label_refs: decoded.removed_label_refs,
        removed_owner_refs: decoded.removed_owner_refs,
        recorded_at: recorded_at
      })
    end
  end

  def from_draft(_draft, _source_act_ref, _recorded_at),
    do: {:error, :invalid_declassification_draft}

  @doc "Returns every target that a declassification Mandate must cover."
  @spec required_target_refs(Evidence.t(), [Label.t() | map() | keyword()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def required_target_refs(%Evidence{} = evidence, removed_labels) do
    with {:ok, evidence} <- Evidence.new(evidence),
         {:ok, label_refs} <- label_refs(removed_labels),
         {:ok, owner_refs} <- owner_refs(removed_labels) do
      Portable.normalize_refs(
        evidence.parent_refs ++ [evidence.ref] ++ label_refs ++ owner_refs,
        :declassification_target_refs
      )
    end
  end

  def required_target_refs(_evidence, _removed_labels),
    do: {:error, :invalid_declassification_targets}

  @doc "Returns the stable references of canonical labels."
  @spec label_refs([Label.t() | map() | keyword()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def label_refs(labels) do
    with {:ok, labels} <- normalize_labels(labels), do: refs_for_labels(labels)
  end

  @doc "Returns the principals which own the removed constraints."
  @spec owner_refs([Label.t() | map() | keyword()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def owner_refs(labels) do
    with {:ok, labels} <- normalize_labels(labels) do
      labels
      |> Enum.map(& &1.owner_ref)
      |> Portable.normalize_refs(:declassification_owner_refs)
    end
  end

  @doc "Checks the exact, conservative label delta proven by this record."
  @spec validate_transition(t(), Evidence.t(), [Evidence.t()]) :: :ok | {:error, term()}
  def validate_transition(%__MODULE__{} = record, %Evidence{} = evidence, parents)
      when is_list(parents) do
    with {:ok, record} <- new(record),
         {:ok, evidence} <- Evidence.new(evidence),
         {:ok, parents} <- normalize_evidence(parents),
         :ok <- declassifiable_provenance(evidence),
         :ok <- transition_identity(record, evidence, parents),
         :ok <- transition_time(record, evidence, parents),
         {:ok, inherited} <- inherited_labels(parents) do
      validate_label_delta(record, evidence, inherited)
    end
  end

  def validate_transition(_record, _evidence, _parents),
    do: {:error, :invalid_declassification_transition}

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = record) do
    %{
      "schema_version" => record.schema_version,
      "ref" => record.ref,
      "source_act_ref" => record.source_act_ref,
      "evidence_ref" => record.evidence_ref,
      "parent_refs" => record.parent_refs,
      "removed_labels" => Enum.map(record.removed_labels, &Label.canonical/1),
      "removed_label_refs" => record.removed_label_refs,
      "removed_owner_refs" => record.removed_owner_refs,
      "recorded_at" => record.recorded_at
    }
  end

  @doc "Restores a declassification record and verifies its content reference."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :declassification)

  @doc "Returns the stable digest of the complete declassification record."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = record), do: record |> canonical() |> Portable.digest!()

  @doc "Returns the reference derived from immutable declassification content."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = record),
    do: Portable.content_ref!(:declassification, content(record))

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:declassification, ref, content(attrs))

  defp content(%__MODULE__{} = record), do: record |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "source_act_ref" => Map.get(attrs, :source_act_ref),
      "evidence_ref" => Map.get(attrs, :evidence_ref),
      "parent_refs" => Map.get(attrs, :parent_refs, []),
      "removed_labels" => Enum.map(Map.get(attrs, :removed_labels, []), &Label.canonical/1),
      "removed_label_refs" => Map.get(attrs, :removed_label_refs, []),
      "removed_owner_refs" => Map.get(attrs, :removed_owner_refs, []),
      "recorded_at" => Map.get(attrs, :recorded_at)
    }
  end

  defp validate_record(%__MODULE__{} = record) do
    with :ok <- schema(record),
         :ok <- non_empty_labels(record.removed_labels),
         {:ok, expected_label_refs} <- refs_for_labels(record.removed_labels),
         :ok <- exact_label_refs(record.removed_label_refs, expected_label_refs),
         {:ok, expected_owner_refs} <- owner_refs(record.removed_labels),
         :ok <- exact_owner_refs(record.removed_owner_refs, expected_owner_refs),
         :ok <- Portable.validate_ref(record.ref, :ref),
         :ok <- Portable.validate_ref(record.source_act_ref, :source_act_ref),
         :ok <- Portable.validate_ref(record.evidence_ref, :evidence_ref),
         :ok <- Portable.validate_refs(record.parent_refs, :parent_refs) do
      if is_integer(record.recorded_at),
        do: :ok,
        else: {:error, {:invalid_declassification_recorded_at, record.recorded_at}}
    end
  end

  defp schema(%{schema_version: @schema_version}), do: :ok

  defp schema(%{schema_version: version}),
    do: {:error, {:unsupported_declassification_schema_version, version}}

  defp draft_schema(@schema_version), do: :ok

  defp draft_schema(version),
    do: {:error, {:unsupported_declassification_draft_schema_version, version}}

  defp declassifiable_provenance(%Evidence{provenance: provenance})
       when provenance in [:derived, :generated],
       do: :ok

  defp declassifiable_provenance(%Evidence{provenance: provenance}),
    do: {:error, {:invalid_declassification_provenance, provenance}}

  defp non_empty_labels([_label | _rest]), do: :ok
  defp non_empty_labels(_labels), do: {:error, :declassification_labels_required}

  defp normalize_labels(labels) do
    case Label.normalize_many(labels) do
      {:ok, labels} -> {:ok, labels}
      {:error, reason} -> {:error, {:invalid_declassification_labels, reason}}
    end
  end

  defp refs_for_labels(labels) do
    {:ok, labels |> Enum.map(& &1.ref) |> Enum.uniq() |> Enum.sort()}
  end

  defp exact_label_refs(actual, actual), do: :ok

  defp exact_label_refs(actual, expected),
    do: {:error, {:declassification_label_refs_mismatch, actual, expected}}

  defp exact_owner_refs(actual, actual), do: :ok

  defp exact_owner_refs(actual, expected),
    do: {:error, {:declassification_owner_refs_mismatch, actual, expected}}

  defp labels_absent_from_output(removed, evidence) do
    removed_keys = label_keys(removed)
    output_keys = label_keys(evidence.labels)

    if MapSet.disjoint?(removed_keys, output_keys),
      do: :ok,
      else: {:error, {:removed_label_still_present, evidence.ref}}
  end

  defp normalize_evidence(evidence) do
    Enum.reduce_while(evidence, {:ok, []}, fn parent, {:ok, parents} ->
      case Evidence.new(parent) do
        {:ok, parent} -> {:cont, {:ok, [parent | parents]}}
        {:error, reason} -> {:halt, {:error, {:invalid_declassification_parent, reason}}}
      end
    end)
    |> case do
      {:ok, parents} -> {:ok, Enum.reverse(parents)}
      {:error, _reason} = error -> error
    end
  end

  defp transition_identity(record, evidence, parents) do
    parent_refs = parents |> Enum.map(& &1.ref) |> Enum.uniq() |> Enum.sort()

    cond do
      record.evidence_ref != evidence.ref ->
        {:error, {:declassification_evidence_mismatch, record.ref, evidence.ref}}

      record.parent_refs != evidence.parent_refs or record.parent_refs != parent_refs ->
        {:error, {:declassification_parent_mismatch, record.ref}}

      true ->
        :ok
    end
  end

  defp transition_time(record, evidence, parents) do
    cond do
      evidence.observed_at > record.recorded_at ->
        {:error, {:declassified_evidence_from_future, evidence.ref}}

      parent = Enum.find(parents, &(&1.observed_at > evidence.observed_at)) ->
        {:error, {:evidence_parent_from_future, evidence.ref, parent.ref}}

      true ->
        :ok
    end
  end

  defp inherited_labels(parents) do
    parents
    |> Enum.flat_map(& &1.labels)
    |> normalize_labels()
  end

  defp validate_label_delta(record, evidence, inherited) do
    inherited_keys = label_keys(inherited)
    removed_keys = label_keys(record.removed_labels)
    output_keys = label_keys(evidence.labels)
    retained_keys = MapSet.difference(inherited_keys, removed_keys)

    cond do
      not MapSet.subset?(removed_keys, inherited_keys) ->
        {:error, {:declassification_removes_uninherited_label, record.ref}}

      not MapSet.disjoint?(removed_keys, output_keys) ->
        {:error, {:removed_label_still_present, evidence.ref}}

      not MapSet.subset?(retained_keys, output_keys) ->
        {:error, {:declassification_drops_undeclared_label, record.ref}}

      true ->
        :ok
    end
  end

  defp label_keys(labels), do: MapSet.new(labels, & &1.ref)
end
