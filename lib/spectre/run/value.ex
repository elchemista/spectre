defmodule Spectre.Run.Value do
  @moduledoc false

  @tag "$spectre"

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

  @spec encode(term()) :: {:ok, term()} | {:error, term()}
  def encode(value)

  def encode(value)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: {:ok, value}

  def encode(value) when is_atom(value) do
    {:ok, %{@tag => "atom", "value" => Atom.to_string(value)}}
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
      {:ok, entries} -> {:ok, %{@tag => "map", "entries" => Enum.reverse(entries)}}
      {:error, _reason} = error -> error
    end
  end

  def encode(value), do: {:error, {:unsupported_run_value, shape(value)}}

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

  @spec decode(term()) :: {:ok, term()} | {:error, term()}
  def decode(value)

  def decode(value)
      when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
      do: {:ok, value}

  def decode(%{@tag => "atom", "value" => value}) when is_binary(value) do
    existing_atom(value)
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

  @spec opaque_id(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def opaque_id(value, prefix \\ "subject")
  def opaque_id(nil, _prefix), do: {:ok, nil}

  def opaque_id(value, prefix) when is_binary(prefix) do
    case validate(value) do
      :ok -> {:ok, token(prefix, value)}
      {:error, _reason} = error -> error
    end
  end

  @spec token(String.t(), term()) :: String.t()
  def token(prefix, value) when is_binary(prefix) do
    digest =
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    prefix <> ":" <> binary_part(digest, 0, 32)
  end

  defp prepare_list(values) do
    prepare_list(values, 0)
  end

  defp encode_list(values, encoder) do
    encode_list(values, encoder, [])
  end

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

  defp prepare_list([], _index), do: :ok

  defp prepare_list([value | tail], index) do
    with :ok <- prepare(value), do: prepare_list(tail, index + 1)
  end

  defp prepare_list(_improper_tail, index),
    do: {:error, {:invalid_encoded_run_list, {:improper_tail, index}}}

  defp encode_list([], _encoder, encoded), do: {:ok, Enum.reverse(encoded)}

  defp encode_list([value | tail], encoder, encoded) do
    case encoder.(value) do
      {:ok, value} -> encode_list(tail, encoder, [value | encoded])
      {:error, _reason} = error -> error
    end
  end

  defp encode_list(_improper_tail, _encoder, _encoded),
    do: {:error, :improper_run_list}

  defp decode_list(values, decoder), do: encode_list(values, decoder)

  defp decode_plain_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, entry}, {:ok, decoded} ->
      case decode(entry) do
        {:ok, entry} -> {:cont, {:ok, Map.put(decoded, key, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_run_atom, value}}
  end

  defp load_module(module_name) do
    module_chars = String.to_charlist(module_name)

    with {:ok, module} <- existing_atom(module_name),
         true <-
           Enum.any?(:code.all_available(), fn {available, _path, _loaded?} ->
             available == module_chars
           end),
         true <- Code.ensure_loaded?(module) do
      {:ok, module}
    else
      _unknown -> {:error, {:unknown_run_module, module_name}}
    end
  end

  defp kind(value) when is_pid(value), do: :pid
  defp kind(value) when is_port(value), do: :port
  defp kind(value) when is_reference(value), do: :reference
  defp kind(value) when is_function(value), do: :function

  defp path_label(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: :nonportable_key

  defp path_label(value) when is_atom(value) or is_binary(value) or is_integer(value), do: value
  defp path_label(_value), do: :key

  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_port(value), do: :port
  defp shape(value) when is_reference(value), do: :reference
  defp shape(value) when is_function(value), do: :function
  defp shape(_value), do: :other
end
