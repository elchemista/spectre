defmodule Spectre.Run.Value do
  @moduledoc """
  Portable value codec for run state.

  Values that cross a run boundary must survive serialization and restarts,
  so they cannot contain PIDs, ports, references or functions. This module
  validates that constraint, encodes values into JSON-safe tagged maps
  (atoms, tuples, structs and non-string-keyed maps get a `"$spectre"` tag),
  decodes them back, and derives deterministic identifiers from them.
  """

  @tag "$spectre"

  @doc """
  Checks that `value` is portable run data.

  Returns `{:error, {:nonportable_run_value, path, kind}}` when the value —
  at any depth — contains a PID, port, reference, function or improper list.
  """
  @spec validate(term(), [term()]) :: :ok | {:error, term()}
  def validate(value, path \\ [])

  def validate(value, path)
      when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
      do: {:error, {:nonportable_run_value, Enum.reverse(path), kind(value)}}

  def validate(value, path) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, item}, :ok ->
      key_path = [{:key, path_label(key)} | path]

      with :ok <- validate(key, key_path),
           :ok <- validate(item, [path_label(key) | path]) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def validate(value, path) when is_list(value) do
    validate_list(value, path, 0)
  end

  def validate(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> validate(path)
  end

  def validate(_value, _path), do: :ok

  @doc """
  Encodes a portable value into its JSON-safe representation.

  Primitives pass through unchanged; atoms, tuples, structs and maps with
  non-string keys become tagged maps that `decode/1` can reverse.
  """
  @spec encode(term()) :: {:ok, term()} | {:error, term()}
  def encode(value)

  def encode(value) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      {:ok, %{@tag => "binary", "value" => Base.encode64(value)}}
    end
  end

  def encode(value)
      when is_nil(value) or is_boolean(value) or is_number(value),
      do: {:ok, value}

  def encode(value) when is_atom(value) do
    atom = Atom.to_string(value)

    if jsonb_string?(atom) do
      {:ok, %{@tag => "atom", "value" => atom}}
    else
      {:ok, %{@tag => "atom_binary", "value" => Base.encode64(atom)}}
    end
  end

  def encode(%{__struct__: module} = value) do
    with {:ok, fields} <- value |> Map.from_struct() |> encode() do
      {:ok,
       %{
         @tag => "struct",
         "module" => Atom.to_string(module),
         "fields" => fields
       }}
    end
  end

  def encode(value) when is_tuple(value) do
    with {:ok, values} <- value |> Tuple.to_list() |> encode_list(&encode/1) do
      {:ok, %{@tag => "tuple", "values" => values}}
    end
  end

  def encode(value) when is_list(value), do: encode_list(value, &encode/1)

  def encode(value) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn {key, entry}, {:ok, entries} ->
      with {:ok, encoded_key} <- encode(key),
           {:ok, encoded_entry} <- encode(entry) do
        {:cont, {:ok, [[encoded_key, encoded_entry] | entries]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        {:ok, %{@tag => "map", "entries" => canonical_map_entries(entries)}}

      {:error, _reason} = error ->
        error
    end
  end

  def encode(value), do: {:error, {:unsupported_run_value, shape(value)}}

  @doc """
  Preloads the modules referenced by an encoded value before decoding.

  Struct tags require their module to exist and load; module-shaped atom tags
  are loaded opportunistically so `decode/1` can resolve them as existing
  atoms.
  """
  @spec prepare(term()) :: :ok | {:error, term()}
  def prepare(value)

  def prepare(%{@tag => "struct", "module" => module_name, "fields" => fields})
      when is_binary(module_name) do
    with {:ok, _module} <- load_module(module_name), do: prepare(fields)
  end

  def prepare(%{@tag => "atom", "value" => "Elixir." <> _rest = module_name}) do
    case load_module(module_name) do
      {:ok, _module} -> :ok
      {:error, _reason} -> :ok
    end
  end

  def prepare(value) when is_map(value) do
    value
    |> Map.values()
    |> prepare_list()
  end

  def prepare(value) when is_list(value), do: prepare_list(value)
  def prepare(_value), do: :ok

  @doc """
  Decodes a value produced by `encode/1` back into its original shape.

  Atoms and struct modules are resolved with `String.to_existing_atom/1`
  only — unknown names return an error instead of creating atoms.
  """
  @spec decode(term()) :: {:ok, term()} | {:error, term()}
  def decode(value)

  def decode(value)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: {:ok, value}

  def decode(%{@tag => "atom", "value" => value}) when is_binary(value) do
    existing_atom(value)
  end

  def decode(%{@tag => "atom_binary", "value" => value}) when is_binary(value) do
    with {:ok, atom} <- decode_base64(value, :invalid_encoded_run_atom),
         do: existing_atom(atom)
  end

  def decode(%{@tag => "binary", "value" => value}) when is_binary(value) do
    decode_base64(value, :invalid_encoded_run_binary)
  end

  def decode(%{@tag => "tuple", "values" => values}) when is_list(values) do
    with {:ok, decoded} <- decode_list(values, &decode/1), do: {:ok, List.to_tuple(decoded)}
  end

  def decode(%{@tag => "map", "entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      [key, value], {:ok, decoded} ->
        with {:ok, key} <- decode(key),
             {:ok, value} <- decode(value) do
          {:cont, {:ok, Map.put(decoded, key, value)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_encoded_run_map_entry}}
    end)
  end

  def decode(%{@tag => "struct", "module" => module_name, "fields" => encoded_fields})
      when is_binary(module_name) do
    with {:ok, module} <- load_module(module_name),
         {:ok, fields} <- decode(encoded_fields),
         true <- is_map(fields) do
      {:ok, struct(module, fields)}
    else
      false -> {:error, {:invalid_run_struct_fields, module_name}}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:invalid_run_struct, module_name, exception.__struct__}}
  end

  def decode(%{@tag => tag}), do: {:error, {:unknown_run_value_tag, tag}}
  def decode(values) when is_list(values), do: decode_list(values, &decode/1)
  def decode(value) when is_map(value), do: decode_plain_map(value)
  def decode(value), do: {:error, {:invalid_encoded_run_value, shape(value)}}

  @doc """
  Derives a stable identifier from `value`, or `nil` when it cannot.

  Non-empty strings are used as-is; any other portable value is hashed via
  `token/2`. Non-portable values yield `nil` rather than an error.
  """
  @spec logical_id(term(), String.t()) :: String.t() | nil
  def logical_id(value, prefix \\ "logical")
  def logical_id(nil, _prefix), do: nil
  def logical_id(value, _prefix) when is_binary(value) and value != "", do: value

  def logical_id(value, prefix) when is_binary(prefix) do
    case validate(value) do
      :ok -> token(prefix, value)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Derives a stable identifier from `value`, keeping validation errors.

  Unlike `logical_id/2`, a non-portable value returns the underlying
  `{:error, reason}` so callers can surface it.
  """
  @spec opaque_id(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def opaque_id(value, prefix \\ "subject")
  def opaque_id(nil, _prefix), do: {:ok, nil}

  def opaque_id(value, prefix) when is_binary(prefix) do
    case validate(value) do
      :ok -> {:ok, token(prefix, value)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds a `"prefix:hash"` token from a deterministic digest of `value`.

  The same value always produces the same token, so tokens are safe to use
  as cross-restart identifiers.
  """
  @spec token(String.t(), term()) :: String.t()
  def token(prefix, value) when is_binary(prefix) do
    digest =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    prefix <> ":" <> binary_part(digest, 0, 32)
  end

  @spec prepare_list([term()]) :: :ok | {:error, term()}
  defp prepare_list(values) do
    prepare_list(values, 0)
  end

  @spec encode_list([term()], (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  defp encode_list(values, encoder) do
    encode_list(values, encoder, [])
  end

  @spec validate_list(term(), [term()], non_neg_integer()) :: :ok | {:error, term()}
  defp validate_list([], _path, _index), do: :ok

  defp validate_list([item | tail], path, index) do
    with :ok <- validate(item, [index | path]) do
      validate_list(tail, path, index + 1)
    end
  end

  defp validate_list(_improper_tail, path, index) do
    {:error,
     {:nonportable_run_value, Enum.reverse([{:improper_tail, index} | path]), :improper_list}}
  end

  @spec prepare_list(term(), non_neg_integer()) :: :ok | {:error, term()}
  defp prepare_list([], _index), do: :ok

  defp prepare_list([value | tail], index) do
    with :ok <- prepare(value), do: prepare_list(tail, index + 1)
  end

  defp prepare_list(_improper_tail, index),
    do: {:error, {:invalid_encoded_run_list, {:improper_tail, index}}}

  @spec encode_list(term(), (term() -> {:ok, term()} | {:error, term()}), [term()]) ::
          {:ok, [term()]} | {:error, term()}
  defp encode_list([], _encoder, encoded), do: {:ok, Enum.reverse(encoded)}

  defp encode_list([value | tail], encoder, encoded) do
    case encoder.(value) do
      {:ok, value} -> encode_list(tail, encoder, [value | encoded])
      {:error, _reason} = error -> error
    end
  end

  defp encode_list(_improper_tail, _encoder, _encoded),
    do: {:error, :improper_run_list}

  @spec decode_list(term(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  defp decode_list(values, decoder), do: encode_list(values, decoder)

  @spec decode_plain_map(map()) :: {:ok, map()} | {:error, term()}
  defp decode_plain_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, entry}, {:ok, decoded} ->
      case decode(entry) do
        {:ok, entry} -> {:cont, {:ok, Map.put(decoded, key, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Map enumeration follows the VM's internal term order. In particular, atom
  # indices depend on which modules were loaded first, so preserving that order
  # would make otherwise identical portable values encode differently across
  # BEAM instances. Encoded keys contain data only; deterministic external-term
  # bytes provide a total ordering independent from VM atom/module load order
  # without creating atoms.
  @spec canonical_map_entries([[term()]]) :: [[term()]]
  defp canonical_map_entries(entries) do
    Enum.sort_by(entries, fn [encoded_key, _encoded_value] ->
      :erlang.term_to_binary(encoded_key, [:deterministic])
    end)
  end

  @spec existing_atom(String.t()) :: {:ok, atom()} | {:error, {:unknown_run_atom, String.t()}}
  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_run_atom, value}}
  end

  defp decode_base64(value, error) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {error, value}}
    end
  end

  defp jsonb_string?(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  @spec load_module(String.t()) ::
          {:ok, module()} | {:error, {:unknown_run_module, String.t()}}
  defp load_module(module_name) do
    with {:ok, module} <- existing_atom(module_name),
         true <- :erlang.module_loaded(module) or available_module?(module_name),
         true <- Code.ensure_loaded?(module) do
      {:ok, module}
    else
      _unknown -> {:error, {:unknown_run_module, module_name}}
    end
  end

  # Scanning every code path costs milliseconds, so it runs only for modules
  # that are not already loaded.
  @spec available_module?(String.t()) :: boolean()
  defp available_module?(module_name) do
    module_chars = String.to_charlist(module_name)

    Enum.any?(:code.all_available(), fn {available, _path, _loaded?} ->
      available == module_chars
    end)
  end

  @spec kind(term()) :: :pid | :port | :reference | :function
  defp kind(value) when is_pid(value), do: :pid
  defp kind(value) when is_port(value), do: :port
  defp kind(value) when is_reference(value), do: :reference
  defp kind(value) when is_function(value), do: :function

  @spec path_label(term()) :: term()
  defp path_label(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: :nonportable_key

  defp path_label(value) when is_atom(value) or is_binary(value) or is_integer(value), do: value
  defp path_label(_value), do: :key

  @spec shape(term()) :: :pid | :port | :reference | :function | :other
  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_port(value), do: :port
  defp shape(value) when is_reference(value), do: :reference
  defp shape(value) when is_function(value), do: :function
  defp shape(_value), do: :other
end
