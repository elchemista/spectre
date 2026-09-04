defmodule Spectre.Portable do
  @moduledoc """
  Portable value boundary for the governed-act record layer.

  Durable records are reduced to plain maps and values before they enter the
  ledger.  This module rejects runtime-local capabilities (`PID`, port,
  reference and function values), improper lists, structs, non-byte-aligned
  bitstrings and non-finite floats.  Accepted values are encoded through the
  versioned `Spectre.Canonical.Value` codec, so map iteration order never
  affects a digest.

  Content references have the form `"prefix:sha256"`.  They are identifiers
  for immutable content, not proof that the content is authoritative.
  """

  import Bitwise

  alias Spectre.Canonical.Value

  @float_exponent_mask 0x7FF0000000000000

  @type path :: [term()]
  @type reason :: term()

  @doc "Validates a plain value suitable for durable governed-act records."
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(value), do: validate_value(value, [])

  @doc "Returns the deterministic, versioned canonical bytes for a portable value."
  @spec canonical_value(term()) :: {:ok, binary()} | {:error, reason()}
  def canonical_value(value) do
    with :ok <- validate(value), do: Value.encode(value)
  end

  @doc "Alias for `canonical_value/1`, useful at generic record boundaries."
  @spec canonical(term()) :: {:ok, binary()} | {:error, reason()}
  def canonical(value), do: canonical_value(value)

  @doc "Returns canonical bytes or raises when `value` is not portable."
  @spec canonical_value!(term()) :: binary()
  def canonical_value!(value) do
    case canonical_value(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, "non-portable value: #{inspect(reason)}"
    end
  end

  @doc "Validates and returns a plain canonical map."
  @spec canonical_map(map()) :: {:ok, map()} | {:error, reason()}
  def canonical_map(value) when is_map(value) and not is_struct(value) do
    with :ok <- validate(value), do: {:ok, value}
  end

  def canonical_map(value), do: {:error, {:invalid_canonical_map, shape(value)}}

  @doc """
  Restores a record only from the exact plain representation emitted by it.

  Record constructors may accept atom-keyed maps, keyword lists and omitted
  defaults for ergonomic in-memory construction. Durable decoding must be
  stricter: accepting those alternate shapes would give one semantic record
  more than one canonical byte representation and digest.
  """
  @spec restore_canonical(
          term(),
          (term() -> {:ok, term()} | {:error, reason()}),
          (term() -> map()),
          atom()
        ) :: {:ok, term()} | {:error, reason()}
  def restore_canonical(value, builder, canonicalizer, record_name)
      when is_map(value) and not is_struct(value) and is_function(builder, 1) and
             is_function(canonicalizer, 1) and is_atom(record_name) do
    with {:ok, record} <- builder.(value),
         canonical when is_map(canonical) and not is_struct(canonical) <- canonicalizer.(record),
         true <- canonical == value do
      {:ok, record}
    else
      false -> {:error, {:noncanonical_record, record_name}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_canonical_record, record_name}}
    end
  end

  def restore_canonical(_value, _builder, _canonicalizer, record_name),
    do: {:error, {:invalid_canonical_record, record_name}}

  @doc "Returns the lowercase SHA-256 digest of a portable value."
  @spec digest(term()) :: {:ok, String.t()} | {:error, reason()}
  def digest(value) do
    with :ok <- validate(value), do: Value.digest(value)
  end

  @doc "Returns a digest or raises when `value` is not portable."
  @spec digest!(term()) :: String.t()
  def digest!(value) do
    case digest(value) do
      {:ok, digest} -> digest
      {:error, reason} -> raise ArgumentError, "non-portable value: #{inspect(reason)}"
    end
  end

  @doc "Builds a stable `prefix:digest` reference for portable content."
  @spec content_ref(String.t() | atom(), term()) :: {:ok, String.t()} | {:error, reason()}
  def content_ref(prefix, value) do
    with {:ok, prefix} <- normalize_prefix(prefix),
         {:ok, digest} <- digest(value) do
      {:ok, prefix <> ":" <> digest}
    end
  end

  @doc "Short alias for `content_ref/2`."
  @spec ref(String.t() | atom(), term()) :: {:ok, String.t()} | {:error, reason()}
  def ref(prefix, value), do: content_ref(prefix, value)

  @doc "Builds a stable content reference or raises."
  @spec content_ref!(String.t() | atom(), term()) :: String.t()
  def content_ref!(prefix, value) do
    case content_ref(prefix, value) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid content reference: #{inspect(reason)}"
    end
  end

  @doc "Computes a content reference and rejects a supplied reference that does not match it."
  @spec resolve_content_ref(String.t() | atom(), nil | String.t(), term()) ::
          {:ok, String.t()} | {:error, reason()}
  def resolve_content_ref(prefix, supplied, value) do
    with {:ok, expected} <- content_ref(prefix, value) do
      case supplied do
        nil -> {:ok, expected}
        ^expected -> {:ok, expected}
        value when is_binary(value) -> {:error, {:content_ref_mismatch, value, expected}}
        value -> {:error, {:invalid_content_ref, shape(value)}}
      end
    end
  end

  @doc "Checks an opaque record reference. References are non-empty binaries."
  @spec validate_ref(term(), atom()) :: :ok | {:error, reason()}
  def validate_ref(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  def validate_ref(value, field), do: {:error, {:invalid_ref, field, shape(value)}}

  @doc "Checks an optional opaque record reference."
  @spec validate_optional_ref(term(), atom()) :: :ok | {:error, reason()}
  def validate_optional_ref(nil, _field), do: :ok
  def validate_optional_ref(value, field), do: validate_ref(value, field)

  @doc "Checks a `prefix:<lowercase sha256>` content-addressed reference."
  @spec validate_content_ref(term(), String.t() | atom(), atom()) ::
          :ok | {:error, reason()}
  def validate_content_ref(value, prefix, field) do
    with {:ok, prefix} <- normalize_prefix(prefix),
         true <- content_ref_shape?(value, prefix) do
      :ok
    else
      false -> {:error, {:invalid_content_addressed_ref, field, shape(value)}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec sha256_digest?(term()) :: boolean()
  def sha256_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    lowercase_hex?(digest)
  end

  def sha256_digest?(_digest), do: false

  @doc "Checks a list of opaque record references."
  @spec validate_refs(term(), atom()) :: :ok | {:error, reason()}
  def validate_refs(values, field), do: validate_ref_list(values, field, 0)

  @doc "Validates, de-duplicates and sorts a reference list."
  @spec normalize_refs(term(), atom()) :: {:ok, [String.t()]} | {:error, reason()}
  def normalize_refs(values, field) do
    with :ok <- validate_refs(values, field), do: {:ok, values |> Enum.uniq() |> Enum.sort()}
  end

  @doc """
  Recursively converts atom map keys to strings without changing atom values.

  This is intended for portable, host-authored semantic maps whose ergonomic
  atom and transport string spellings mean the same thing. It rejects a map
  containing both spellings instead of silently choosing one. Other portable
  key types are preserved.
  """
  @spec stringify_atom_keys(term()) :: {:ok, term()} | {:error, reason()}
  def stringify_atom_keys(value), do: stringify_atom_keys(value, [])

  @doc "Checks a required non-empty binary field."
  @spec validate_non_empty_binary(term(), atom()) :: :ok | {:error, reason()}
  def validate_non_empty_binary(value, _field)
      when is_binary(value) and byte_size(value) > 0,
      do: :ok

  def validate_non_empty_binary(value, field),
    do: {:error, {:invalid_non_empty_binary, field, shape(value)}}

  @doc "Normalizes map or keyword attributes and rejects unknown/duplicate keys."
  @spec normalize_attrs(term(), [atom()], atom()) :: {:ok, map()} | {:error, reason()}
  def normalize_attrs(attrs, fields, record_name)
      when is_list(fields) and is_atom(record_name) do
    with {:ok, entries} <- attribute_entries(attrs, record_name),
         {:ok, normalized} <- normalize_entries(entries, fields, record_name) do
      {:ok, normalized}
    end
  end

  @doc "Projects known atom fields into the strict string-keyed record representation."
  @spec canonical_fields(map(), [atom()]) :: map()
  def canonical_fields(source, fields) when is_map(source) and is_list(fields) do
    Map.new(fields, fn field -> {Atom.to_string(field), Map.get(source, field)} end)
  end

  @doc false
  @spec shape(term()) :: atom()
  def shape(value) when is_struct(value), do: :struct
  def shape(value) when is_map(value), do: :map
  def shape(value) when is_list(value), do: :list
  def shape(value) when is_tuple(value), do: :tuple
  def shape(value) when is_binary(value), do: :binary
  def shape(value) when is_atom(value), do: :atom
  def shape(value) when is_integer(value), do: :integer
  def shape(value) when is_float(value), do: :float
  def shape(value) when is_pid(value), do: :pid
  def shape(value) when is_port(value), do: :port
  def shape(value) when is_reference(value), do: :reference
  def shape(value) when is_function(value), do: :function
  def shape(value) when is_bitstring(value), do: :bitstring

  defp validate_value(value, path)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value) do
    {:error, {:nonportable_value, Enum.reverse(path), shape(value)}}
  end

  defp validate_value(%{__struct__: module}, path) do
    {:error, {:nonportable_value, Enum.reverse(path), {:struct, module}}}
  end

  defp validate_value(value, path) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{key, item}, index}, :ok ->
      with :ok <- validate_value(key, [{:map_key, index} | path]),
           :ok <- validate_value(item, [{:map_value, key_label(key)} | path]) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_value([], _path), do: :ok

  defp validate_value([head | tail], path) do
    validate_list(head, tail, path, 0)
  end

  defp validate_value(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case validate_value(item, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_value(value, path) when is_float(value) do
    <<bits::unsigned-big-64>> = <<value::float-big-64>>

    if (bits &&& @float_exponent_mask) == @float_exponent_mask,
      do: {:error, {:nonportable_value, Enum.reverse(path), :nonfinite_float}},
      else: :ok
  end

  defp validate_value(value, path) when is_bitstring(value) and not is_binary(value),
    do: {:error, {:nonportable_value, Enum.reverse(path), :bitstring}}

  defp validate_value(value, _path)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_binary(value) or
              is_atom(value),
       do: :ok

  defp validate_value(value, path),
    do: {:error, {:nonportable_value, Enum.reverse(path), shape(value)}}

  defp stringify_atom_keys(value, path) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {raw_key, item}, {:ok, normalized} ->
      key = if is_atom(raw_key), do: Atom.to_string(raw_key), else: raw_key

      if Map.has_key?(normalized, key) do
        {:halt, {:error, {:equivalent_map_keys, Enum.reverse([key | path])}}}
      else
        case stringify_atom_keys(item, [key | path]) do
          {:ok, item} -> {:cont, {:ok, Map.put(normalized, key, item)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
  end

  defp stringify_atom_keys(value, path) when is_list(value),
    do: stringify_atom_key_list(value, path, 0, [])

  defp stringify_atom_keys(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, normalized} ->
      case stringify_atom_keys(item, [index | path]) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> List.to_tuple()}
      {:error, _reason} = error -> error
    end
  end

  defp stringify_atom_keys(value, _path), do: {:ok, value}

  defp stringify_atom_key_list([], _path, _index, normalized),
    do: {:ok, Enum.reverse(normalized)}

  defp stringify_atom_key_list([head | tail], path, index, normalized) do
    with {:ok, head} <- stringify_atom_keys(head, [index | path]) do
      stringify_atom_key_list(tail, path, index + 1, [head | normalized])
    end
  end

  defp stringify_atom_key_list(tail, path, index, normalized) do
    with {:ok, tail} <- stringify_atom_keys(tail, [{:tail, index} | path]) do
      {:ok, Enum.reverse(normalized, tail)}
    end
  end

  defp validate_list(head, tail, path, index) do
    with :ok <- validate_value(head, [index | path]) do
      case tail do
        [] ->
          :ok

        [next | rest] ->
          validate_list(next, rest, path, index + 1)

        _improper ->
          {:error,
           {:nonportable_value, Enum.reverse([{:tail, index + 1} | path]), :improper_list}}
      end
    end
  end

  defp attribute_entries(attrs, _record_name) when is_map(attrs) and not is_struct(attrs),
    do: {:ok, Map.to_list(attrs)}

  defp attribute_entries(attrs, record_name) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: {:ok, attrs},
      else: {:error, {:invalid_attributes, record_name, :not_keyword}}
  end

  defp attribute_entries(attrs, record_name),
    do: {:error, {:invalid_attributes, record_name, shape(attrs)}}

  defp normalize_entries(entries, fields, record_name) do
    names = Map.new(fields, &{Atom.to_string(&1), &1})

    Enum.reduce_while(entries, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      case normalize_key(raw_key, fields, names) do
        {:ok, key} ->
          if Map.has_key?(normalized, key) do
            {:halt, {:error, {:duplicate_attribute, record_name, key}}}
          else
            {:cont, {:ok, Map.put(normalized, key, value)}}
          end

        :error ->
          {:halt, {:error, {:unknown_attribute, record_name, raw_key}}}
      end
    end)
  end

  defp normalize_key(key, fields, _names) when is_atom(key) do
    if key in fields, do: {:ok, key}, else: :error
  end

  defp normalize_key(key, _fields, names) when is_binary(key) do
    case Map.fetch(names, key) do
      {:ok, field} -> {:ok, field}
      :error -> :error
    end
  end

  defp normalize_key(_key, _fields, _names), do: :error

  defp normalize_prefix(prefix) when is_atom(prefix), do: normalize_prefix(Atom.to_string(prefix))

  defp normalize_prefix(prefix) when is_binary(prefix) and byte_size(prefix) > 0 do
    if String.match?(prefix, ~r/^[a-z][a-z0-9_-]*$/),
      do: {:ok, prefix},
      else: {:error, {:invalid_content_ref_prefix, prefix}}
  end

  defp normalize_prefix(prefix), do: {:error, {:invalid_content_ref_prefix, shape(prefix)}}

  defp content_ref_shape?(value, prefix) when is_binary(value) do
    marker = prefix <> ":"

    if byte_size(value) == byte_size(marker) + 64 and String.starts_with?(value, marker) do
      digest = binary_part(value, byte_size(marker), 64)
      sha256_digest?(digest)
    else
      false
    end
  end

  defp content_ref_shape?(_value, _prefix), do: false

  defp lowercase_hex?(<<>>), do: true

  defp lowercase_hex?(<<byte, rest::binary>>) when byte in ?0..?9 or byte in ?a..?f,
    do: lowercase_hex?(rest)

  defp lowercase_hex?(_digest), do: false

  defp validate_ref_list([], _field, _index), do: :ok

  defp validate_ref_list([value | rest], field, index) do
    case validate_ref(value, field) do
      :ok -> validate_ref_list(rest, field, index + 1)
      {:error, _reason} -> {:error, {:invalid_ref, field, index, shape(value)}}
    end
  end

  defp validate_ref_list(value, field, _index),
    do: {:error, {:invalid_ref_list, field, shape(value)}}

  defp key_label(key) when is_atom(key) or is_binary(key) or is_integer(key), do: key
  defp key_label(_key), do: :complex_key
end
