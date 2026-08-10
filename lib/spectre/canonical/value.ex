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
    with {:ok, context} <- context(opts),
         {:ok, payload} <- encode_term(value, context, [], 0),
         encoded = @magic <> <<@version>> <> payload,
         :ok <- encoded_size(encoded, context) do
      {:ok, encoded}
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
         {:ok, value, ""} <- decode_term(payload, context, [], 0) do
      {:ok, value}
    else
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
    case encode(value, opts) do
      {:ok, _encoded} -> :ok
      {:error, _reason} = error -> error
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
    if Enum.all?(modules, &(is_atom(&1) and not is_nil(&1))) do
      {:ok, Map.new(modules, &{Atom.to_string(&1), &1})}
    else
      {:error, {:invalid_allowed_structs, modules}}
    end
  end

  defp allowed_structs(modules), do: {:error, {:invalid_allowed_structs, modules}}

  @spec encoded_size(binary(), map()) :: :ok | {:error, reason()}
  defp encoded_size(encoded, %{max_bytes: max_bytes}) do
    if byte_size(encoded) <= max_bytes,
      do: :ok,
      else: {:error, {:canonical_value_too_large, byte_size(encoded), max_bytes}}
  end

  @spec header(binary()) :: {:ok, binary()} | {:error, reason()}
  defp header(<<@magic, @version, payload::binary>>), do: {:ok, payload}

  defp header(<<@magic, version, _payload::binary>>),
    do: {:error, {:unsupported_canonical_version, version}}

  defp header(_encoded), do: {:error, :invalid_canonical_header}

  @spec encode_term(term(), map(), [term()], non_neg_integer()) ::
          {:ok, binary()} | {:error, reason()}
  defp encode_term(_value, %{max_depth: max_depth}, path, depth) when depth > max_depth,
    do: {:error, {:canonical_depth_exceeded, Enum.reverse(path), max_depth}}

  defp encode_term(nil, _context, _path, _depth), do: {:ok, <<@tag_nil>>}
  defp encode_term(false, _context, _path, _depth), do: {:ok, <<@tag_false>>}
  defp encode_term(true, _context, _path, _depth), do: {:ok, <<@tag_true>>}

  defp encode_term(value, _context, _path, _depth) when is_integer(value) do
    encoded = Integer.to_string(value)
    {:ok, <<@tag_integer, byte_size(encoded)::unsigned-big-32, encoded::binary>>}
  end

  defp encode_term(value, _context, path, _depth) when is_float(value) do
    if finite_float?(value),
      do: {:ok, <<@tag_float, value::float-big-64>>},
      else: {:error, {:nonfinite_canonical_float, Enum.reverse(path)}}
  end

  defp encode_term(value, _context, _path, _depth) when is_binary(value),
    do: {:ok, sized(@tag_binary, value)}

  defp encode_term(value, _context, _path, _depth) when is_atom(value),
    do: {:ok, sized(@tag_atom, Atom.to_string(value))}

  defp encode_term(value, context, path, depth) when is_struct(value) do
    module = value.__struct__
    module_name = Atom.to_string(module)

    if Map.get(context.allowed_structs, module_name) == module do
      with {:ok, fields} <-
             encode_term(Map.from_struct(value), context, [:fields | path], depth + 1) do
        {:ok,
         <<@tag_struct, byte_size(module_name)::unsigned-big-32, module_name::binary,
           fields::binary>>}
      end
    else
      {:error, {:disallowed_canonical_struct, Enum.reverse(path), module}}
    end
  end

  defp encode_term([], _context, _path, _depth), do: {:ok, <<@tag_list, 0::unsigned-big-32>>}

  defp encode_term([_head | _tail] = value, context, path, depth) do
    with {:ok, items} <- encode_list(value, context, path, depth + 1, 0, []) do
      {:ok, <<@tag_list, length(items)::unsigned-big-32, IO.iodata_to_binary(items)::binary>>}
    end
  end

  defp encode_term(value, context, path, depth) when is_tuple(value) do
    values = Tuple.to_list(value)

    with :ok <- collection_size(length(values), context, path),
         {:ok, items} <- encode_sequence(values, context, path, depth + 1, 0, []) do
      {:ok, <<@tag_tuple, length(items)::unsigned-big-32, IO.iodata_to_binary(items)::binary>>}
    end
  end

  defp encode_term(value, context, path, depth) when is_map(value) do
    with :ok <- collection_size(map_size(value), context, path),
         {:ok, entries} <- encode_map(value, context, path, depth + 1) do
      body = Enum.map_join(entries, fn {key, item} -> key <> item end)
      {:ok, <<@tag_map, length(entries)::unsigned-big-32, body::binary>>}
    end
  end

  defp encode_term(value, _context, path, _depth) do
    {:error, {:unsupported_canonical_value, Enum.reverse(path), kind(value)}}
  end

  @spec encode_list(term(), map(), [term()], non_neg_integer(), non_neg_integer(), [binary()]) ::
          {:ok, [binary()]} | {:error, reason()}
  defp encode_list([], context, path, _depth, count, encoded) do
    with :ok <- collection_size(count, context, path), do: {:ok, Enum.reverse(encoded)}
  end

  defp encode_list([head | tail], context, path, depth, index, encoded) do
    with :ok <- collection_size(index + 1, context, path),
         {:ok, item} <- encode_term(head, context, [index | path], depth) do
      encode_list(tail, context, path, depth, index + 1, [item | encoded])
    end
  end

  defp encode_list(_improper_tail, _context, path, _depth, index, _encoded),
    do: {:error, {:improper_canonical_list, Enum.reverse([{:tail, index} | path])}}

  @spec encode_sequence([term()], map(), [term()], non_neg_integer(), non_neg_integer(), [
          binary()
        ]) ::
          {:ok, [binary()]} | {:error, reason()}
  defp encode_sequence([], _context, _path, _depth, _index, encoded),
    do: {:ok, Enum.reverse(encoded)}

  defp encode_sequence([value | rest], context, path, depth, index, encoded) do
    with {:ok, item} <- encode_term(value, context, [index | path], depth) do
      encode_sequence(rest, context, path, depth, index + 1, [item | encoded])
    end
  end

  @spec encode_map(map(), map(), [term()], non_neg_integer()) ::
          {:ok, [{binary(), binary()}]} | {:error, reason()}
  defp encode_map(value, context, path, depth) do
    value
    |> Map.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{key, item}, index}, {:ok, entries} ->
      with {:ok, encoded_key} <- encode_term(key, context, [{:key, index} | path], depth),
           {:ok, encoded_item} <- encode_term(item, context, [{:value, index} | path], depth) do
        {:cont, {:ok, [{encoded_key, encoded_item} | entries]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      {:error, _reason} = error -> error
    end
  end

  @spec collection_size(non_neg_integer(), map(), [term()]) :: :ok | {:error, reason()}
  defp collection_size(size, %{max_collection_size: max}, path) do
    if size <= max,
      do: :ok,
      else: {:error, {:canonical_collection_too_large, Enum.reverse(path), size, max}}
  end

  @spec sized(byte(), binary()) :: binary()
  defp sized(tag, value), do: <<tag, byte_size(value)::unsigned-big-32, value::binary>>

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
         {value, ""} <- Integer.parse(encoded) do
      {:ok, value, rest}
    else
      {:error, _reason} = error -> error
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
    {:ok, struct(module, fields), rest}
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
