defmodule Spectre.Projection.HumanReport do
  @moduledoc """
  Mechanical human-review projection for one governed Definition change.

  The report combines an exact structural/textual diff with an already
  verified evaluation delta. It never invokes a model and never labels a
  Candidate as semantically "better"; it exposes measured evidence and limits.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Governance.Data
  alias Spectre.Governance.EvaluationDelta

  @generator_id "spectre.projection.human-report"
  @generator_version 1
  @max_changes 4_096
  @fields [
    "generator_id",
    "generator_version",
    "parent_definition_ref",
    "candidate_definition_ref",
    "input_evidence_digest",
    "structural_changes",
    "textual_changes",
    "evaluation_delta",
    "lineage_refs",
    "gate_receipt_refs",
    "digest"
  ]

  @enforce_keys [
    :generator_id,
    :generator_version,
    :parent_definition_ref,
    :candidate_definition_ref,
    :input_evidence_digest,
    :structural_changes,
    :textual_changes,
    :evaluation_delta,
    :lineage_refs,
    :gate_receipt_refs,
    :digest
  ]
  defstruct generator_id: @generator_id,
            generator_version: @generator_version,
            parent_definition_ref: nil,
            candidate_definition_ref: nil,
            input_evidence_digest: nil,
            structural_changes: [],
            textual_changes: [],
            evaluation_delta: nil,
            lineage_refs: [],
            gate_receipt_refs: [],
            digest: nil

  @type t :: %__MODULE__{
          generator_id: String.t(),
          generator_version: pos_integer(),
          parent_definition_ref: String.t(),
          candidate_definition_ref: String.t(),
          input_evidence_digest: String.t(),
          structural_changes: [map()],
          textual_changes: [map()],
          evaluation_delta: map(),
          lineage_refs: [String.t()],
          gate_receipt_refs: [String.t()],
          digest: String.t()
        }

  @doc "Returns the fixed generator id."
  def id, do: @generator_id

  @doc "Returns the fixed generator version."
  def version, do: @generator_version

  @doc "Projects a deterministic report from two canonical Definitions."
  @spec project(Canonical.t(), Canonical.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def project(parent, candidate, opts \\ [])

  def project(%Canonical{} = parent, %Canonical{} = candidate, opts)
      when is_list(opts) do
    with %EvaluationDelta{} = supplied_delta <- Keyword.get(opts, :evaluation_delta),
         {:ok, delta} <-
           supplied_delta |> EvaluationDelta.to_data() |> EvaluationDelta.from_data(),
         {:ok, lineage_refs} <- refs(Keyword.get(opts, :lineage_refs, []), "candidate:sha256:"),
         {:ok, receipt_refs} <- refs(Keyword.get(opts, :gate_receipt_refs, []), "gate:sha256:"),
         {:ok, structural} <-
           structural_diff(Canonical.to_data(parent), Canonical.to_data(candidate)) do
      textual =
        structural
        |> Enum.filter(fn change ->
          is_binary(Map.get(change, "before")) or is_binary(Map.get(change, "after"))
        end)
        |> Enum.map(&Map.take(&1, ["path", "change", "before", "after"]))

      delta_data = EvaluationDelta.to_data(delta)

      evidence_digest =
        Value.digest!(%{
          "lineage_refs" => lineage_refs,
          "gate_receipt_refs" => receipt_refs,
          "evaluation_delta_digest" => EvaluationDelta.digest(delta)
        })

      base = %{
        generator_id: @generator_id,
        generator_version: @generator_version,
        parent_definition_ref: parent |> Canonical.ref() |> Ref.to_string(),
        candidate_definition_ref: candidate |> Canonical.ref() |> Ref.to_string(),
        input_evidence_digest: evidence_digest,
        structural_changes: structural,
        textual_changes: textual,
        evaluation_delta: delta_data,
        lineage_refs: lineage_refs,
        gate_receipt_refs: receipt_refs
      }

      case digest_data(base) do
        {:ok, digest} -> {:ok, struct!(__MODULE__, Map.put(base, :digest, digest))}
        {:error, reason} -> {:error, {:invalid_human_report, reason}}
      end
    else
      nil -> {:error, :human_report_requires_evaluation_delta}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_human_report_input, shape(value)}}
    end
  end

  def project(parent, candidate, _opts),
    do: {:error, {:invalid_human_report_definitions, shape(parent), shape(candidate)}}

  @doc "Returns JSON-shaped report data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = report) do
    %{
      "generator_id" => report.generator_id,
      "generator_version" => report.generator_version,
      "parent_definition_ref" => report.parent_definition_ref,
      "candidate_definition_ref" => report.candidate_definition_ref,
      "input_evidence_digest" => report.input_evidence_digest,
      "structural_changes" => report.structural_changes,
      "textual_changes" => report.textual_changes,
      "evaluation_delta" => report.evaluation_delta,
      "lineage_refs" => report.lineage_refs,
      "gate_receipt_refs" => report.gate_receipt_refs,
      "digest" => report.digest
    }
  end

  @doc "Restores and verifies a report from portable data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) when is_map(data) and not is_struct(data) do
    with [] <- Map.keys(data) -- @fields,
         [] <- @fields -- Map.keys(data),
         @generator_id <- Map.get(data, "generator_id"),
         @generator_version <- Map.get(data, "generator_version"),
         true <- valid_ref?(Map.get(data, "parent_definition_ref"), "sha256:"),
         true <- valid_ref?(Map.get(data, "candidate_definition_ref"), "sha256:"),
         :ok <- digest(Map.get(data, "input_evidence_digest")),
         {:ok, structural} <- changes(Map.get(data, "structural_changes"), :structural),
         {:ok, textual} <- changes(Map.get(data, "textual_changes"), :textual),
         :ok <- textual_consistency(structural, textual),
         {:ok, delta} <- EvaluationDelta.from_data(Map.get(data, "evaluation_delta")),
         {:ok, lineage} <- refs(Map.get(data, "lineage_refs"), "candidate:sha256:"),
         {:ok, receipts} <- refs(Map.get(data, "gate_receipt_refs"), "gate:sha256:"),
         :ok <- digest(Map.get(data, "digest")),
         :ok <- evidence_digest(Map.get(data, "input_evidence_digest"), lineage, receipts, delta) do
      report = %__MODULE__{
        generator_id: @generator_id,
        generator_version: @generator_version,
        parent_definition_ref: Map.get(data, "parent_definition_ref"),
        candidate_definition_ref: Map.get(data, "candidate_definition_ref"),
        input_evidence_digest: Map.get(data, "input_evidence_digest"),
        structural_changes: structural,
        textual_changes: textual,
        evaluation_delta: EvaluationDelta.to_data(delta),
        lineage_refs: lineage,
        gate_receipt_refs: receipts,
        digest: Map.get(data, "digest")
      }

      with :ok <- verify_digest(report),
           true <- to_data(report) == data do
        {:ok, report}
      else
        false -> {:error, :human_report_integrity_mismatch}
        {:error, _reason} = error -> error
      end
    else
      [_first | _rest] = fields -> {:error, {:invalid_human_report_fields, fields}}
      false -> {:error, :invalid_human_report_reference}
      value when is_binary(value) -> {:error, {:unsupported_human_report_generator, value}}
      value when is_integer(value) -> {:error, {:unsupported_human_report_version, value}}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_human_report_data}
    end
  end

  def from_data(value), do: {:error, {:invalid_human_report_data, shape(value)}}

  @doc "Encodes a report with the production canonical codec."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = report), do: report |> to_data() |> Value.encode()

  @doc "Decodes and verifies a canonical report."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_human_report_binary, shape(value)}}

  @doc "Verifies that report contents still match its digest."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = report) do
    case from_data(to_data(report)) do
      {:ok, ^report} ->
        :ok

      {:ok, _restored} ->
        {:error, :human_report_integrity_mismatch}

      {:error, {:human_report_digest_mismatch, _supplied, _expected} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:invalid_human_report, reason}}
    end
  rescue
    exception -> {:error, {:invalid_human_report, exception.__struct__}}
  end

  defp verify_digest(report) do
    base = report |> Map.from_struct() |> Map.delete(:digest)

    case digest_data(base) do
      {:ok, expected}
      when report.generator_id == @generator_id and
             report.generator_version == @generator_version and report.digest == expected ->
        :ok

      {:ok, expected} ->
        {:error, {:human_report_digest_mismatch, report.digest, expected}}

      {:error, reason} ->
        {:error, {:invalid_human_report, reason}}
    end
  end

  @spec structural_diff(term(), term()) :: {:ok, [map()]} | {:error, term()}
  defp structural_diff(parent, candidate) do
    case diff(parent, candidate, [], [], 0) do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      {:error, _reason} = error -> error
    end
  end

  defp diff(left, right, _path, changes, _count) when left === right, do: {:ok, changes}

  defp diff(left, right, path, changes, count)
       when is_map(left) and is_map(right) and not is_struct(left) and not is_struct(right) do
    keys =
      (Map.keys(left) ++ Map.keys(right))
      |> Enum.uniq_by(&Value.encode!/1)
      |> Enum.sort_by(&Value.encode!/1)

    Enum.reduce_while(keys, {:ok, changes, count}, fn key, {:ok, current, current_count} ->
      result =
        case {Map.fetch(left, key), Map.fetch(right, key)} do
          {{:ok, left_value}, {:ok, right_value}} ->
            diff(left_value, right_value, path ++ [path_key(key)], current, current_count)

          {{:ok, left_value}, :error} ->
            change("removed", path ++ [path_key(key)], left_value, current, current_count)

          {:error, {:ok, right_value}} ->
            change("added", path ++ [path_key(key)], right_value, current, current_count)
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next, length(next)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, result, _count} -> {:ok, result}
      {:error, _reason} = error -> error
    end)
  end

  defp diff(left, right, path, changes, count) when is_list(left) and is_list(right) do
    max_length = max(length(left), length(right))

    if max_length == 0 do
      {:ok, changes}
    else
      diff_list(left, right, path, changes, count, max_length)
    end
  end

  defp diff(left, right, path, changes, count) do
    change("changed", path, {left, right}, changes, count)
  end

  defp diff_list(left, right, path, changes, count, max_length) do
    0..(max_length - 1)
    |> Enum.reduce_while(
      {:ok, changes, count},
      &diff_list_item(&1, &2, left, right, path)
    )
    |> finish_diff()
  end

  defp diff_list_item(index, {:ok, current, current_count}, left, right, path) do
    result =
      case {Enum.fetch(left, index), Enum.fetch(right, index)} do
        {{:ok, left_value}, {:ok, right_value}} ->
          diff(left_value, right_value, path ++ [index], current, current_count)

        {{:ok, left_value}, :error} ->
          change("removed", path ++ [index], left_value, current, current_count)

        {:error, {:ok, right_value}} ->
          change("added", path ++ [index], right_value, current, current_count)
      end

    continue_diff(result)
  end

  defp continue_diff({:ok, next}), do: {:cont, {:ok, next, length(next)}}
  defp continue_diff({:error, _reason} = error), do: {:halt, error}

  defp finish_diff({:ok, result, _count}), do: {:ok, result}
  defp finish_diff({:error, _reason} = error), do: error

  defp change(_kind, _path, _value, _changes, count) when count >= @max_changes,
    do: {:error, {:human_report_change_limit_exceeded, @max_changes}}

  defp change("added", path, value, changes, _count),
    do: quoted_change("added", path, nil, value, changes)

  defp change("removed", path, value, changes, _count),
    do: quoted_change("removed", path, value, nil, changes)

  defp change("changed", path, {left, right}, changes, _count) do
    quoted_change("changed", path, left, right, changes)
  end

  defp quoted_change("added", path, _left, right, changes) do
    with {:ok, right} <- Data.quote(right) do
      {:ok, [%{"path" => path, "change" => "added", "after" => right} | changes]}
    end
  end

  defp quoted_change("removed", path, left, _right, changes) do
    with {:ok, left} <- Data.quote(left) do
      {:ok, [%{"path" => path, "change" => "removed", "before" => left} | changes]}
    end
  end

  defp quoted_change("changed", path, left, right, changes) do
    with {:ok, left} <- Data.quote(left),
         {:ok, right} <- Data.quote(right) do
      {:ok,
       [
         %{"path" => path, "change" => "changed", "before" => left, "after" => right}
         | changes
       ]}
    end
  end

  defp changes(values, kind) when is_list(values) and length(values) <= @max_changes do
    with {:ok, ^values} <- Data.normalize(values),
         true <- Enum.all?(values, &valid_change?(&1, kind)),
         paths = Enum.map(values, &Map.fetch!(&1, "path")),
         true <- length(paths) == length(Enum.uniq_by(paths, &Value.encode!/1)) do
      {:ok, values}
    else
      {:ok, _normalized} -> {:error, :human_report_changes_not_json_shaped}
      false -> {:error, {:invalid_human_report_change_shape, kind}}
      {:error, reason} -> {:error, {:invalid_human_report_changes, reason}}
    end
  end

  defp changes(values, _kind) when is_list(values),
    do: {:error, {:human_report_change_limit_exceeded, @max_changes}}

  defp changes(value, _kind), do: {:error, {:invalid_human_report_changes, shape(value)}}

  defp valid_change?(%{"path" => path, "change" => "added", "after" => _after} = change, kind) do
    Map.keys(change) |> Enum.sort() == ~w(after change path) and valid_path?(path) and
      valid_textual_change?(change, kind)
  end

  defp valid_change?(%{"path" => path, "change" => "removed", "before" => _before} = change, kind) do
    Map.keys(change) |> Enum.sort() == ~w(before change path) and valid_path?(path) and
      valid_textual_change?(change, kind)
  end

  defp valid_change?(
         %{"path" => path, "change" => "changed", "before" => _before, "after" => _after} =
           change,
         kind
       ) do
    Map.keys(change) |> Enum.sort() == ~w(after before change path) and valid_path?(path) and
      valid_textual_change?(change, kind)
  end

  defp valid_change?(_change, _kind), do: false

  defp valid_path?(path) when is_list(path),
    do: Enum.all?(path, &(is_binary(&1) or is_integer(&1) or is_map(&1)))

  defp valid_path?(_path), do: false

  defp valid_textual_change?(_change, :structural), do: true

  defp valid_textual_change?(change, :textual),
    do: is_binary(Map.get(change, "before")) or is_binary(Map.get(change, "after"))

  defp textual_consistency(structural, textual) do
    expected =
      structural
      |> Enum.filter(fn change ->
        is_binary(Map.get(change, "before")) or is_binary(Map.get(change, "after"))
      end)
      |> Enum.map(&Map.take(&1, ["path", "change", "before", "after"]))

    if textual == expected,
      do: :ok,
      else: {:error, :human_report_textual_diff_mismatch}
  end

  defp evidence_digest(expected, lineage, receipts, delta) do
    actual =
      Value.digest!(%{
        "lineage_refs" => lineage,
        "gate_receipt_refs" => receipts,
        "evaluation_delta_digest" => EvaluationDelta.digest(delta)
      })

    if expected == actual,
      do: :ok,
      else: {:error, {:human_report_evidence_digest_mismatch, expected, actual}}
  end

  defp digest(value) when is_binary(value) and byte_size(value) == 64 do
    if match?({:ok, <<_::256>>}, Base.decode16(value, case: :mixed)),
      do: :ok,
      else: {:error, {:invalid_human_report_digest, value}}
  end

  defp digest(value), do: {:error, {:invalid_human_report_digest, value}}

  defp refs(values, prefix) when is_list(values) do
    if Enum.all?(values, &valid_ref?(&1, prefix)),
      do: {:ok, values |> Enum.uniq() |> Enum.sort()},
      else: {:error, {:invalid_human_report_refs, prefix}}
  end

  defp refs(value, _prefix), do: {:error, {:invalid_human_report_refs, shape(value)}}

  defp valid_ref?(value, prefix) when is_binary(value) do
    case String.split_at(value, byte_size(prefix)) do
      {^prefix, digest} -> match?({:ok, <<_::256>>}, Base.decode16(digest, case: :mixed))
      _other -> false
    end
  end

  defp valid_ref?(_value, _prefix), do: false

  defp path_key(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: %{"canonical_key" => Base.encode64(Value.encode!(value))}
  end

  defp path_key(value) when is_integer(value), do: value

  defp path_key(value) do
    case Data.quote(value) do
      {:ok, quoted} -> quoted
      {:error, _reason} -> %{"canonical_key" => Base.encode64(Value.encode!(value))}
    end
  end

  defp digest_data(base) do
    base
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Value.digest()
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
