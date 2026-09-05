defmodule Spectre.Canonical.Value do
  @moduledoc """
  Portable, deterministic value codec used by content-addressed Spectre data.

  The format is independent from Erlang external-term encoding. Every value
  carries an explicit tag, map entries are ordered by the canonical bytes of
  their keys, and atoms are restored with `String.to_existing_atom/1` only.
  Structs are rejected unless the caller supplies an explicit
  `:allowed_structs` list.

  PIDs, ports, references, functions, improper lists, non-byte-aligned
  bitstrings, and non-finite floats are never encodable.
  """

  @magic "SPCV"
  @version 1
  @digest_algorithm :sha256

  @tag_nil 0x00
  @tag_false 0x01
  @tag_true 0x02
  @tag_integer 0x10
  @tag_float 0x11
  @tag_binary 0x12
  @tag_atom 0x13
  @tag_list 0x20
  @tag_tuple 0x21
  @tag_map 0x22
  @tag_struct 0x23

  @default_max_bytes 16 * 1_024 * 1_024
  @default_max_depth 128
  @default_max_collection_size 1_000_000
  @float_exponent_mask 0x7FF0000000000000

  @type reason :: term()

  @doc "Returns the canonicalization format version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the digest algorithm used by `digest/2`."
  @spec digest_algorithm() :: :sha256
  def digest_algorithm, do: @digest_algorithm

  @doc """
  Encodes a value into the versioned canonical binary format.

  Options:

    * `:allowed_structs` - modules whose structs may be encoded and decoded;
    * `:max_bytes` - maximum encoded size, including the format header;
    * `:max_depth` - maximum nesting depth;
    * `:max_collection_size` - maximum entries in one collection.
  """
  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, reason()}
  def encode(value, opts \\ []) do
    with {:ok, payload} <- encoded_payload(value, opts) do
      {:ok, IO.iodata_to_binary([@magic, <<@version>>, payload])}
    end
  end

  @doc "Encodes a value or raises `ArgumentError` with the stable failure reason."
  @spec encode!(term(), keyword()) :: binary()
  def encode!(value, opts \\ []) do
    case encode(value, opts) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, "non-canonical Spectre value: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes a canonical value without creating atoms.

  The decoder rejects trailing data, non-canonical map order, unknown tags,
  unknown atoms, and structs outside the explicit `:allowed_structs` list.
  """
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, reason()}
  def decode(encoded, opts \\ [])

  def decode(encoded, opts) when is_binary(encoded) do
    with {:ok, context} <- context(opts),
         :ok <- encoded_size(encoded, context),
         {:ok, payload} <- header(encoded),
         {:ok, value, ""} <- decode_term(payload, context, [], 0),
         {:ok, canonical} <- encode(value, opts),
         true <- canonical == encoded do
      {:ok, value}
    else
      false -> {:error, :noncanonical_value_encoding}
      {:ok, _value, trailing} -> {:error, {:trailing_canonical_bytes, byte_size(trailing)}}
      {:error, _reason} = error -> error
    end
  end

  def decode(value, _opts), do: {:error, {:invalid_canonical_binary, shape(value)}}

  @doc "Returns the lowercase SHA-256 digest of a canonical value."
  @spec digest(term(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def digest(value, opts \\ []) do
    with {:ok, encoded} <- encode(value, opts) do
      {:ok,
       encoded
       |> then(&:crypto.hash(@digest_algorithm, &1))
       |> Base.encode16(case: :lower)}
    end
  end

  @doc "Returns the digest or raises `ArgumentError` for a non-canonical value."
  @spec digest!(term(), keyword()) :: String.t()
  def digest!(value, opts \\ []) do
    case digest(value, opts) do
      {:ok, digest} -> digest
      {:error, reason} -> raise ArgumentError, "non-canonical Spectre value: #{inspect(reason)}"
    end
  end

  @doc "Checks whether a value can be represented by this codec."
  @spec validate(term(), keyword()) :: :ok | {:error, reason()}
  def validate(value, opts \\ []) do
    case encoded_payload(value, opts) do
      {:ok, _payload} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Validation shares the exact wire budget without allocating the final binary.
  defp encoded_payload(value, opts) do
    with {:ok, context} <- context(opts),
         {:ok, context} <- charge(context, 5),
         {:ok, payload, _context} <- encode_term(value, context, [], 0) do
      {:ok, payload}
    end
  end

  @spec context(keyword()) :: {:ok, map()} | {:error, reason()}
  defp context(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, max_bytes} <- positive_option(opts, :max_bytes, @default_max_bytes),
         {:ok, max_depth} <- non_negative_option(opts, :max_depth, @default_max_depth),
         {:ok, max_collection_size} <-
           non_negative_option(opts, :max_collection_size, @default_max_collection_size),
         {:ok, allowed_structs} <- allowed_structs(Keyword.get(opts, :allowed_structs, [])) do
      {:ok,
       %{
         allowed_structs: allowed_structs,
         max_bytes: max_bytes,
         used_bytes: 0,
         max_collection_size: max_collection_size,
         max_depth: max_depth
       }}
    else
      false -> {:error, :invalid_canonical_options}
      {:error, _reason} = error -> error
    end
  end

  defp context(_opts), do: {:error, :invalid_canonical_options}

  @spec positive_option(keyword(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, reason()}
  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_canonical_option, key, value}}
    end
  end

  @spec non_negative_option(keyword(), atom(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_canonical_option, key, value}}
    end
  end

  @spec allowed_structs(term()) :: {:ok, map()} | {:error, reason()}
  defp allowed_structs(modules) when is_list(modules) do
    if module_list?(modules) do
      {:ok, Map.new(modules, &{Atom.to_string(&1), &1})}
    else
      {:error, {:invalid_allowed_structs, modules}}
    end
  end

  defp allowed_structs(modules), do: {:error, {:invalid_allowed_structs, modules}}

  defp module_list?([]), do: true

  defp module_list?([module | rest]) when is_atom(module) and not is_nil(module),
    do: module_list?(rest)

  defp module_list?(_invalid), do: false

  @spec encoded_size(binary(), map()) :: :ok | {:error, reason()}
  defp encoded_size(encoded, %{max_bytes: max_bytes}) do
    if byte_size(encoded) <= max_bytes,
      do: :ok,
      else: {:error, {:canonical_value_too_large, byte_size(encoded), max_bytes}}
  end

  # Charge before allocating output. On rejection the reported size is the
  # prefix size that exceeds the budget, not an expensive full-size estimate.
  # Successful encodings keep exactly the same canonical bytes and digests.
  defp charge(context, size) do
    used = context.used_bytes + size

    if used <= context.max_bytes,
      do: {:ok, %{context | used_bytes: used}},
      else: {:error, {:canonical_value_too_large, used, context.max_bytes}}
  end

  defp scalar(encoded, context) do
    with {:ok, context} <- charge(context, byte_size(encoded)),
         do: {:ok, encoded, context}
  end

  defp sized_scalar(tag, value, context) do
    with {:ok, context} <- charge(context, 5 + byte_size(value)),
         do: {:ok, [<<tag, byte_size(value)::unsigned-big-32>>, value], context}
  end

  @spec header(binary()) :: {:ok, binary()} | {:error, reason()}
  defp header(<<@magic, @version, payload::binary>>), do: {:ok, payload}

  defp header(<<@magic, version, _payload::binary>>),
    do: {:error, {:unsupported_canonical_version, version}}

  defp header(_encoded), do: {:error, :invalid_canonical_header}

  @spec encode_term(term(), map(), [term()], non_neg_integer()) ::
          {:ok, iodata(), map()} | {:error, reason()}
  defp encode_term(_value, %{max_depth: max_depth}, path, depth) when depth > max_depth,
    do: {:error, {:canonical_depth_exceeded, Enum.reverse(path), max_depth}}

  defp encode_term(nil, context, _path, _depth), do: scalar(<<@tag_nil>>, context)
  defp encode_term(false, context, _path, _depth), do: scalar(<<@tag_false>>, context)
  defp encode_term(true, context, _path, _depth), do: scalar(<<@tag_true>>, context)

  defp encode_term(value, context, _path, _depth) when is_integer(value) do
    encoded = Integer.to_string(value)
    sized_scalar(@tag_integer, encoded, context)
  end

  defp encode_term(value, context, path, _depth) when is_float(value) do
    if finite_float?(value),
      do: scalar(<<@tag_float, value::float-big-64>>, context),
      else: {:error, {:nonfinite_canonical_float, Enum.reverse(path)}}
  end

  defp encode_term(value, context, _path, _depth) when is_binary(value),
    do: sized_scalar(@tag_binary, value, context)

  defp encode_term(value, context, _path, _depth) when is_atom(value),
    do: sized_scalar(@tag_atom, Atom.to_string(value), context)

  defp encode_term(value, context, path, depth) when is_struct(value) do
    module = value.__struct__
    module_name = Atom.to_string(module)

    if Map.get(context.allowed_structs, module_name) == module do
      fields = Map.from_struct(value)

      with :ok <- validate_struct_fields(module, fields, path),
           {:ok, prefix, context} <- sized_scalar(@tag_struct, module_name, context),
           {:ok, fields, context} <-
             encode_term(fields, context, [:fields | path], depth + 1) do
        {:ok, [prefix, fields], context}
      end
    else
      {:error, {:disallowed_canonical_struct, Enum.reverse(path), module}}
    end
  end

  defp encode_term([], context, _path, _depth),
    do: scalar(<<@tag_list, 0::unsigned-big-32>>, context)

  defp encode_term([_head | _tail] = value, context, path, depth) do
    with {:ok, context} <- charge(context, 5),
         {:ok, items, context} <- encode_list(value, context, path, depth + 1, 0, []) do
      {:ok, [<<@tag_list, length(items)::unsigned-big-32>>, items], context}
    end
  end

  defp encode_term(value, context, path, depth) when is_tuple(value) do
    with :ok <- collection_size(tuple_size(value), context, path),
         {:ok, context} <- charge(context, 5),
         {:ok, items, context} <- encode_sequence(value, context, path, depth + 1, 0, []) do
      {:ok, [<<@tag_tuple, tuple_size(value)::unsigned-big-32>>, items], context}
    end
  end

  defp encode_term(value, context, path, depth) when is_map(value) do
    with :ok <- collection_size(map_size(value), context, path),
         {:ok, context} <- charge(context, 5),
         {:ok, entries, context} <- encode_map(value, context, path, depth + 1) do
      body = Enum.map(entries, fn {key, item} -> [key, item] end)
      {:ok, [<<@tag_map, map_size(value)::unsigned-big-32>>, body], context}
    end
  end

  defp encode_term(value, _context, path, _depth) do
    {:error, {:unsupported_canonical_value, Enum.reverse(path), kind(value)}}
  end

  @spec encode_list(term(), map(), [term()], non_neg_integer(), non_neg_integer(), [iodata()]) ::
          {:ok, [iodata()], map()} | {:error, reason()}
  defp encode_list([], context, path, _depth, count, encoded) do
    with :ok <- collection_size(count, context, path), do: {:ok, Enum.reverse(encoded), context}
  end

  defp encode_list([head | tail], context, path, depth, index, encoded) do
    with :ok <- collection_size(index + 1, context, path),
         {:ok, item, context} <- encode_term(head, context, [index | path], depth) do
      encode_list(tail, context, path, depth, index + 1, [item | encoded])
    end
  end

  defp encode_list(_improper_tail, _context, path, _depth, index, _encoded),
    do: {:error, {:improper_canonical_list, Enum.reverse([{:tail, index} | path])}}

  @spec encode_sequence(tuple(), map(), [term()], non_neg_integer(), non_neg_integer(), [iodata()]) ::
          {:ok, [iodata()], map()} | {:error, reason()}
  defp encode_sequence(values, context, _path, _depth, index, encoded)
       when index == tuple_size(values),
       do: {:ok, Enum.reverse(encoded), context}

  defp encode_sequence(values, context, path, depth, index, encoded) do
    with {:ok, item, context} <- encode_term(elem(values, index), context, [index | path], depth) do
      encode_sequence(values, context, path, depth, index + 1, [item | encoded])
    end
  end

  @spec encode_map(map(), map(), [term()], non_neg_integer()) ::
          {:ok, [{binary(), iodata()}], map()} | {:error, reason()}
  defp encode_map(value, context, path, depth) do
    value
    |> Enum.reduce_while({:ok, [], context, 0}, fn {key, item}, {:ok, entries, context, index} ->
      with {:ok, encoded_key, context} <- encode_term(key, context, [{:key, index} | path], depth),
           {:ok, encoded_item, context} <-
             encode_term(item, context, [{:value, index} | path], depth) do
        entry = {IO.iodata_to_binary(encoded_key), encoded_item}
        {:cont, {:ok, [entry | entries], context, index + 1}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, context, _index} -> {:ok, Enum.sort_by(entries, &elem(&1, 0)), context}
      {:error, _reason} = error -> error
    end
  end

  @spec collection_size(non_neg_integer(), map(), [term()]) :: :ok | {:error, reason()}
  defp collection_size(size, %{max_collection_size: max}, path) do
    if size <= max,
      do: :ok,
      else: {:error, {:canonical_collection_too_large, Enum.reverse(path), size, max}}
  end

  @spec decode_term(binary(), map(), [term()], non_neg_integer()) ::
          {:ok, term(), binary()} | {:error, reason()}
  defp decode_term(_encoded, %{max_depth: max_depth}, path, depth) when depth > max_depth,
    do: {:error, {:canonical_depth_exceeded, Enum.reverse(path), max_depth}}

  defp decode_term(<<@tag_nil, rest::binary>>, _context, _path, _depth),
    do: {:ok, nil, rest}

  defp decode_term(<<@tag_false, rest::binary>>, _context, _path, _depth),
    do: {:ok, false, rest}

  defp decode_term(<<@tag_true, rest::binary>>, _context, _path, _depth),
    do: {:ok, true, rest}

  defp decode_term(<<@tag_integer, rest::binary>>, _context, path, _depth) do
    with {:ok, encoded, rest} <- take_sized(rest, :integer),
         {value, ""} <- Integer.parse(encoded),
         true <- Integer.to_string(value) == encoded do
      {:ok, value, rest}
    else
      {:error, _reason} = error -> error
      false -> {:error, {:noncanonical_integer, Enum.reverse(path)}}
      :error -> {:error, {:invalid_canonical_integer, Enum.reverse(path)}}
      {_value, _trailing} -> {:error, {:invalid_canonical_integer, Enum.reverse(path)}}
    end
  end

  defp decode_term(<<@tag_float, value::float-big-64, rest::binary>>, _context, path, _depth) do
    if finite_float?(value),
      do: {:ok, value, rest},
      else: {:error, {:nonfinite_canonical_float, Enum.reverse(path)}}
  end

  defp decode_term(<<@tag_binary, rest::binary>>, _context, _path, _depth) do
    take_sized(rest, :binary)
  end

  defp decode_term(<<@tag_atom, rest::binary>>, _context, path, _depth) do
    with {:ok, value, rest} <- take_sized(rest, :atom),
         {:ok, atom} <- existing_atom(value, path) do
      {:ok, atom, rest}
    end
  end

  defp decode_term(<<@tag_list, count::unsigned-big-32, rest::binary>>, context, path, depth) do
    with :ok <- collection_size(count, context, path),
         do: decode_sequence(rest, count, context, path, depth + 1, 0, [])
  end

  defp decode_term(<<@tag_tuple, count::unsigned-big-32, rest::binary>>, context, path, depth) do
    with :ok <- collection_size(count, context, path),
         {:ok, values, rest} <-
           decode_sequence(rest, count, context, path, depth + 1, 0, []) do
      {:ok, List.to_tuple(values), rest}
    end
  end

  defp decode_term(<<@tag_map, count::unsigned-big-32, rest::binary>>, context, path, depth) do
    with :ok <- collection_size(count, context, path),
         do: decode_map(rest, count, context, path, depth + 1, 0, nil, %{})
  end

  defp decode_term(<<@tag_struct, rest::binary>>, context, path, depth) do
    with {:ok, module_name, rest} <- take_sized(rest, :struct_module),
         {:ok, module} <- allowed_struct(context, module_name, path),
         {:ok, fields, rest} <- decode_term(rest, context, [:fields | path], depth + 1),
         true <- is_map(fields) do
      build_struct(module, fields, rest, path)
    else
      false -> {:error, {:invalid_canonical_struct_fields, Enum.reverse(path)}}
      {:error, _reason} = error -> error
    end
  end

  defp decode_term(<<tag, _rest::binary>>, _context, path, _depth),
    do: {:error, {:unknown_canonical_tag, Enum.reverse(path), tag}}

  defp decode_term(<<>>, _context, path, _depth),
    do: {:error, {:truncated_canonical_value, Enum.reverse(path)}}

  @spec decode_sequence(
          binary(),
          non_neg_integer(),
          map(),
          [term()],
          non_neg_integer(),
          non_neg_integer(),
          [term()]
        ) :: {:ok, [term()], binary()} | {:error, reason()}
  defp decode_sequence(rest, count, _context, _path, _depth, count, values),
    do: {:ok, Enum.reverse(values), rest}

  defp decode_sequence(rest, count, context, path, depth, index, values) do
    with {:ok, value, rest} <- decode_term(rest, context, [index | path], depth) do
      decode_sequence(rest, count, context, path, depth, index + 1, [value | values])
    end
  end

  @spec decode_map(
          binary(),
          non_neg_integer(),
          map(),
          [term()],
          non_neg_integer(),
          non_neg_integer(),
          binary() | nil,
          map()
        ) :: {:ok, map(), binary()} | {:error, reason()}
  defp decode_map(rest, count, _context, _path, _depth, count, _previous, decoded),
    do: {:ok, decoded, rest}

  defp decode_map(rest, count, context, path, depth, index, previous, decoded) do
    key_input = rest

    with {:ok, key, after_key} <- decode_term(rest, context, [{:key, index} | path], depth),
         key_size = byte_size(key_input) - byte_size(after_key),
         key_bytes = binary_part(key_input, 0, key_size),
         :ok <- canonical_key_order(previous, key_bytes, path),
         false <- Map.has_key?(decoded, key),
         {:ok, value, rest} <-
           decode_term(after_key, context, [{:value, index} | path], depth) do
      decode_map(
        rest,
        count,
        context,
        path,
        depth,
        index + 1,
        key_bytes,
        Map.put(decoded, key, value)
      )
    else
      true -> {:error, {:duplicate_canonical_map_key, Enum.reverse(path)}}
      {:error, _reason} = error -> error
    end
  end

  @spec canonical_key_order(binary() | nil, binary(), [term()]) :: :ok | {:error, reason()}
  defp canonical_key_order(nil, _current, _path), do: :ok

  defp canonical_key_order(previous, current, path) do
    if previous < current,
      do: :ok,
      else: {:error, {:noncanonical_map_order, Enum.reverse(path)}}
  end

  @spec take_sized(binary(), atom()) :: {:ok, binary(), binary()} | {:error, reason()}
  defp take_sized(<<size::unsigned-big-32, rest::binary>>, kind) do
    if byte_size(rest) >= size do
      <<value::binary-size(^size), rest::binary>> = rest
      {:ok, value, rest}
    else
      {:error, {:truncated_canonical_value, kind}}
    end
  end

  defp take_sized(_rest, kind), do: {:error, {:truncated_canonical_value, kind}}

  @spec existing_atom(binary(), [term()]) :: {:ok, atom()} | {:error, reason()}
  defp existing_atom(value, path) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_canonical_atom, Enum.reverse(path), value}}
  end

  @spec allowed_struct(map(), binary(), [term()]) :: {:ok, module()} | {:error, reason()}
  defp allowed_struct(context, module_name, path) do
    case Map.fetch(context.allowed_structs, module_name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:disallowed_canonical_struct, Enum.reverse(path), module_name}}
    end
  end

  @spec build_struct(module(), map(), binary(), [term()]) ::
          {:ok, struct(), binary()} | {:error, reason()}
  defp build_struct(module, fields, rest, path) do
    with :ok <- validate_struct_fields(module, fields, path),
         do: {:ok, struct!(module, fields), rest}
  end

  defp validate_struct_fields(module, fields, path) do
    expected = module.__struct__() |> Map.keys() |> List.delete(:__struct__) |> MapSet.new()
    actual = fields |> Map.keys() |> MapSet.new()

    if actual == expected do
      :ok
    else
      {:error,
       {:invalid_canonical_struct_fields, Enum.reverse(path), module, MapSet.to_list(actual),
        MapSet.to_list(expected)}}
    end
  rescue
    exception ->
      {:error, {:invalid_canonical_struct, Enum.reverse(path), module, exception.__struct__}}
  end

  @spec finite_float?(float()) :: boolean()
  defp finite_float?(value) do
    <<bits::unsigned-big-64>> = <<value::float-big-64>>
    :erlang.band(bits, @float_exponent_mask) != @float_exponent_mask
  end

  @spec kind(term()) :: atom()
  defp kind(value) when is_pid(value), do: :pid
  defp kind(value) when is_port(value), do: :port
  defp kind(value) when is_reference(value), do: :reference
  defp kind(value) when is_function(value), do: :function
  defp kind(value) when is_bitstring(value), do: :bitstring
  defp kind(_value), do: :other

  @spec shape(term()) :: atom()
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
