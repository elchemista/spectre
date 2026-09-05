defmodule Spectre.Consequence.Contract do
  @moduledoc """
  Portable, closed schema for one governed consequence class.

  A contract is deliberately small. Maps name every allowed key, `$list`
  describes a homogeneous list, `$optional` and `$nullable` are explicit, and
  `$const` fixes a literal value. Scalar leaves use one of the documented type
  names; `portable` accepts any canonical portable value so application tools
  can carry their own nested arguments. The four binding leaves (`subject_ref`,
  `subject_refs`, `target_ref`
  and `target_refs`) derive the exact Candidate endpoints. `destination_ref(s)`
  additionally bind the disclosure destination, while `meter_requests` binds
  the exact quantitative request. A proposer therefore cannot validate
  authority against different endpoints or cost than the consequence carries.

  The schema is data stored in the Surface. It contains no callback or module
  reference and is therefore independently replayable.
  """

  require Spectre.Portable

  alias Spectre.Portable

  @schema_version 1
  @fields [:schema_version, :ref, :shape]
  @scalar_types ~w(
    binary string ref refs integer non_negative_integer positive_integer
    float number boolean atom nil portable portable_scalar
    subject_ref subject_refs target_ref target_refs destination_ref destination_refs
    meter_requests
  )
  @wrappers ~w($list $optional $nullable $const)

  @enforce_keys [:schema_version, :ref, :shape]
  defstruct schema_version: @schema_version, ref: nil, shape: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          shape: term()
        }

  @doc "Builds and validates a content-addressed consequence contract."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = contract), do: contract |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :consequence_contract),
         attrs <- Map.put_new(attrs, :schema_version, @schema_version),
         :ok <- validate_shape(Map.get(attrs, :shape), []),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         contract = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(contract),
         :ok <- Portable.validate(canonical(contract)) do
      {:ok, contract}
    end
  end

  @doc "Validates the consequence and its exact declared boundary bindings."
  @spec validate(t(), term(), map()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = contract, consequence, boundary) when is_map(boundary) do
    with {:ok, contract} <- new(contract),
         {:ok, bindings} <- validate_value(contract.shape, consequence, [], empty_bindings()),
         {:ok, declared_subjects} <-
           Portable.normalize_refs(Map.get(boundary, :subject_refs, []), :subject_refs),
         {:ok, declared_targets} <-
           Portable.normalize_refs(Map.get(boundary, :target_refs, []), :target_refs),
         {:ok, declared_destinations} <-
           Portable.normalize_refs(
             Map.get(boundary, :destination_refs, []),
             :destination_refs
           ),
         {:ok, bound_subjects} <-
           Portable.normalize_refs(bindings.subject_refs, :bound_subject_refs),
         {:ok, bound_targets} <- Portable.normalize_refs(bindings.target_refs, :bound_target_refs),
         {:ok, bound_destinations} <-
           Portable.normalize_refs(bindings.destination_refs, :bound_destination_refs),
         :ok <- exact_bindings(:subject, bound_subjects, declared_subjects),
         :ok <- exact_bindings(:target, bound_targets, declared_targets),
         :ok <- exact_bindings(:destination, bound_destinations, declared_destinations) do
      exact_meter_requests(bindings.meter_requests, boundary)
    end
  end

  def validate(_contract, _consequence, _boundary),
    do: {:error, :invalid_consequence_contract}

  @doc "Returns the semantic boundary kinds explicitly bound by the schema."
  @spec binding_kinds(t()) :: MapSet.t(atom())
  def binding_kinds(%__MODULE__{} = contract) do
    contract.shape
    |> collect_binding_kinds(MapSet.new())
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = contract), do: Portable.canonical_fields(contract, @fields)

  @doc "Restores a consequence contract and verifies its content reference."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :consequence_contract)

  @doc "Returns the reference derived from the immutable contract content."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = contract),
    do: Portable.content_ref!(:consequence_contract, content(contract))

  defp validate_shape(type, _path) when type in @scalar_types, do: :ok

  defp validate_shape(spec, path) when Portable.is_plain_map(spec) do
    case wrapper(spec) do
      {:ok, "$const", value} ->
        Portable.validate(value)

      {:ok, _wrapper, nested} ->
        validate_shape(nested, path)

      :object ->
        validate_object_shape(spec, path)

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_shape(spec, path),
    do: {:error, {:invalid_consequence_shape, Enum.reverse(path), Portable.shape(spec)}}

  defp validate_object_shape(spec, path) do
    Enum.reduce_while(spec, :ok, fn {key, nested}, :ok ->
      cond do
        not Portable.is_non_empty_binary(key) ->
          {:halt, {:error, {:invalid_consequence_shape_key, Enum.reverse(path), key}}}

        key in @wrappers ->
          {:halt, {:error, {:reserved_consequence_shape_key, Enum.reverse([key | path])}}}

        true ->
          nested |> validate_shape([key | path]) |> continue_validation()
      end
    end)
  end

  defp wrapper(spec) when map_size(spec) == 1 do
    [{key, value}] = Map.to_list(spec)

    if key in @wrappers, do: {:ok, key, value}, else: :object
  end

  defp wrapper(spec) do
    case Enum.find(Map.keys(spec), &(&1 in @wrappers)) do
      nil -> :object
      key -> {:error, {:invalid_consequence_shape_wrapper, key}}
    end
  end

  defp validate_value("subject_ref", value, path, bindings),
    do: bind_one(:subject_refs, value, path, bindings)

  defp validate_value("target_ref", value, path, bindings),
    do: bind_one(:target_refs, value, path, bindings)

  defp validate_value("subject_refs", value, path, bindings),
    do: bind_many(:subject_refs, value, path, bindings)

  defp validate_value("target_refs", value, path, bindings),
    do: bind_many(:target_refs, value, path, bindings)

  defp validate_value("destination_ref", value, path, bindings),
    do: bind_destination(:one, value, path, bindings)

  defp validate_value("destination_refs", value, path, bindings),
    do: bind_destination(:many, value, path, bindings)

  defp validate_value("meter_requests", value, path, bindings),
    do: bind_meter_requests(value, path, bindings)

  defp validate_value("ref", value, path, bindings),
    do: validate_ref(value, path, bindings)

  defp validate_value("refs", value, path, bindings),
    do: validate_refs(value, path, bindings)

  defp validate_value("portable", value, path, bindings) do
    case Portable.validate(value) do
      :ok -> {:ok, bindings}
      {:error, _reason} -> shape_error(path, "portable", value)
    end
  end

  defp validate_value(type, value, path, bindings) when type in @scalar_types do
    if scalar?(type, value) do
      {:ok, bindings}
    else
      shape_error(path, type, value)
    end
  end

  defp validate_value(spec, value, path, bindings)
       when Portable.is_plain_map(spec) do
    case wrapper(spec) do
      {:ok, "$const", expected} ->
        if value == expected, do: {:ok, bindings}, else: shape_error(path, spec, value)

      {:ok, "$nullable", nested} ->
        if is_nil(value), do: {:ok, bindings}, else: validate_value(nested, value, path, bindings)

      {:ok, "$optional", nested} ->
        validate_value(nested, value, path, bindings)

      {:ok, "$list", nested} ->
        validate_list(nested, value, path, bindings)

      :object ->
        validate_object(spec, value, path, bindings)

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_value(spec, value, path, _bindings), do: shape_error(path, spec, value)

  defp validate_object(spec, value, path, bindings)
       when Portable.is_plain_map(value) do
    required_keys =
      spec
      |> Enum.reject(fn {_key, nested} -> optional?(nested) end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    allowed_keys = MapSet.new(Map.keys(spec))
    actual_keys = MapSet.new(Map.keys(value))

    cond do
      not MapSet.subset?(required_keys, actual_keys) ->
        missing =
          required_keys |> MapSet.difference(actual_keys) |> MapSet.to_list() |> Enum.sort()

        {:error, {:consequence_shape_missing_keys, Enum.reverse(path), missing}}

      not MapSet.subset?(actual_keys, allowed_keys) ->
        unknown =
          actual_keys |> MapSet.difference(allowed_keys) |> MapSet.to_list() |> Enum.sort()

        {:error, {:consequence_shape_unknown_keys, Enum.reverse(path), unknown}}

      true ->
        validate_object_fields(spec, value, path, bindings)
    end
  end

  defp validate_object(spec, value, path, _bindings), do: shape_error(path, spec, value)

  defp validate_object_fields(spec, value, path, bindings) do
    Enum.reduce_while(spec, {:ok, bindings}, fn {key, nested}, {:ok, current} ->
      case Map.fetch(value, key) do
        {:ok, item} ->
          nested
          |> unwrap_optional()
          |> validate_value(item, [key | path], current)
          |> continue_validation()

        :error ->
          {:cont, {:ok, current}}
      end
    end)
  end

  defp continue_validation(:ok), do: {:cont, :ok}
  defp continue_validation({:ok, _value} = result), do: {:cont, result}
  defp continue_validation({:error, _reason} = error), do: {:halt, error}

  defp validate_list(nested, value, path, bindings) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, bindings}, fn {item, index}, {:ok, current} ->
      case validate_value(nested, item, [index | path], current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_list(nested, value, path, _bindings),
    do: shape_error(path, %{"$list" => nested}, value)

  defp bind_one(field, value, path, bindings) do
    case Portable.validate_ref(value, field) do
      :ok -> {:ok, Map.update!(bindings, field, &[value | &1])}
      {:error, _reason} -> shape_error(path, Atom.to_string(field), value)
    end
  end

  defp bind_many(field, value, path, bindings) do
    case Portable.normalize_refs(value, field) do
      {:ok, refs} -> {:ok, Map.update!(bindings, field, &(refs ++ &1))}
      {:error, _reason} -> shape_error(path, Atom.to_string(field), value)
    end
  end

  defp bind_destination(cardinality, value, path, bindings) do
    result =
      case cardinality do
        :one ->
          case Portable.validate_ref(value, :destination_refs) do
            :ok -> {:ok, [value]}
            {:error, _reason} -> :error
          end

        :many ->
          case Portable.normalize_refs(value, :destination_refs) do
            {:ok, refs} -> {:ok, refs}
            {:error, _reason} -> :error
          end
      end

    case result do
      {:ok, refs} ->
        {:ok,
         bindings
         |> Map.update!(:destination_refs, &(refs ++ &1))
         |> Map.update!(:target_refs, &(refs ++ &1))}

      :error ->
        shape_error(path, "destination_#{cardinality}", value)
    end
  end

  defp bind_meter_requests(value, path, %{meter_requests: nil} = bindings) do
    if valid_meter_requests?(value) do
      {:ok, %{bindings | meter_requests: value}}
    else
      shape_error(path, "meter_requests", value)
    end
  end

  defp bind_meter_requests(_value, path, _bindings),
    do: {:error, {:duplicate_consequence_meter_binding, Enum.reverse(path)}}

  defp validate_ref(value, path, bindings) do
    case Portable.validate_ref(value, :consequence_ref) do
      :ok -> {:ok, bindings}
      {:error, _reason} -> shape_error(path, "ref", value)
    end
  end

  defp validate_refs(value, path, bindings) do
    case Portable.validate_refs(value, :consequence_refs) do
      :ok -> {:ok, bindings}
      {:error, _reason} -> shape_error(path, "refs", value)
    end
  end

  defp scalar?("binary", value), do: is_binary(value)
  defp scalar?("string", value), do: is_binary(value)
  defp scalar?("integer", value), do: is_integer(value)
  defp scalar?("non_negative_integer", value), do: Portable.is_non_negative_integer(value)
  defp scalar?("positive_integer", value), do: Portable.is_positive_integer(value)
  defp scalar?("float", value), do: is_float(value)
  defp scalar?("number", value), do: is_integer(value) or is_float(value)
  defp scalar?("boolean", value), do: is_boolean(value)
  defp scalar?("atom", value), do: is_atom(value)
  defp scalar?("nil", value), do: is_nil(value)

  defp scalar?("portable_scalar", value),
    do:
      is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
        is_binary(value) or is_atom(value)

  defp scalar?(_type, _value), do: false

  defp valid_meter_requests?(value) when Portable.is_plain_map(value) do
    Enum.all?(value, fn {ref, quantity} ->
      Portable.is_non_empty_binary(ref) and Portable.is_positive_integer(quantity)
    end)
  end

  defp valid_meter_requests?(_value), do: false

  defp optional?(%{"$optional" => _nested} = wrapper), do: map_size(wrapper) == 1
  defp optional?(_spec), do: false

  defp unwrap_optional(%{"$optional" => nested} = wrapper) when map_size(wrapper) == 1,
    do: nested

  defp unwrap_optional(spec), do: spec

  defp exact_bindings(_kind, refs, refs), do: :ok

  defp exact_bindings(kind, bound, declared),
    do: {:error, {:consequence_binding_mismatch, kind, bound, declared}}

  defp exact_meter_requests(nil, boundary) do
    exact_meter_requests(%{}, boundary)
  end

  defp exact_meter_requests(bound, boundary) do
    declared = Map.get(boundary, :meter_requests, %{})

    if bound == declared,
      do: :ok,
      else: {:error, {:consequence_meter_binding_mismatch, bound, declared}}
  end

  defp shape_error(path, expected, actual),
    do:
      {:error,
       {:consequence_shape_mismatch, Enum.reverse(path), expected, Portable.shape(actual)}}

  defp empty_bindings,
    do: %{subject_refs: [], target_refs: [], destination_refs: [], meter_requests: nil}

  defp collect_binding_kinds(type, kinds) when is_binary(type) do
    case type do
      type when type in ["subject_ref", "subject_refs"] ->
        MapSet.put(kinds, :subject)

      type when type in ["target_ref", "target_refs"] ->
        MapSet.put(kinds, :target)

      type when type in ["destination_ref", "destination_refs"] ->
        kinds |> MapSet.put(:target) |> MapSet.put(:destination)

      "meter_requests" ->
        MapSet.put(kinds, :meter)

      _scalar ->
        kinds
    end
  end

  defp collect_binding_kinds(spec, kinds) when is_map(spec) do
    case wrapper(spec) do
      {:ok, "$const", _value} ->
        kinds

      {:ok, _wrapper, nested} ->
        collect_binding_kinds(nested, kinds)

      :object ->
        Enum.reduce(spec, kinds, fn {_key, nested}, current ->
          collect_binding_kinds(nested, current)
        end)

      {:error, _reason} ->
        kinds
    end
  end

  defp collect_binding_kinds(_spec, kinds), do: kinds

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:consequence_contract, ref, content(attrs))

  defp content(%__MODULE__{} = contract), do: contract |> canonical() |> Map.delete("ref")

  defp content(attrs), do: Portable.canonical_fields(attrs, @fields -- [:ref])

  defp validate_record(%__MODULE__{} = contract) do
    if contract.schema_version !== @schema_version do
      {:error, {:unsupported_consequence_contract_schema_version, contract.schema_version}}
    else
      Portable.validate_content_ref(contract.ref, :consequence_contract, :ref)
    end
  end
end
