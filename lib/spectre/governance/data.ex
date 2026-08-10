defmodule Spectre.Governance.Data do
  @moduledoc false

  alias Spectre.Canonical.Value

  @max_depth 64
  @max_bytes 1_048_576
  @max_collection_size 10_000

  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  def normalize(value) do
    size = :erlang.external_size(value)

    if size <= @max_bytes do
      with {:ok, normalized} <- normalize_value(value, [], 0),
           :ok <-
             Value.validate(normalized,
               max_depth: @max_depth,
               max_bytes: @max_bytes,
               max_collection_size: @max_collection_size
             ) do
        {:ok, normalized}
      end
    else
      {:error, {:governance_data_too_large, size, @max_bytes}}
    end
  end

  @spec normalize_map(term()) :: {:ok, map()} | {:error, term()}
  def normalize_map(value) when is_map(value) and not is_struct(value) do
    case normalize(value) do
      {:ok, normalized} when is_map(normalized) -> {:ok, normalized}
      {:error, _reason} = error -> error
    end
  end

  def normalize_map(value), do: {:error, {:governance_data_map_required, shape(value)}}

  @doc false
  @spec quote(term()) :: {:ok, term()} | {:error, term()}
  def quote(value) do
    with :ok <- Value.validate(value), do: {:ok, quote_value(value)}
  end

  @spec alias_collisions(map(), [atom()]) :: [atom()]
  def alias_collisions(attrs, fields) when is_map(attrs) and is_list(fields) do
    Enum.filter(fields, fn field ->
      Map.has_key?(attrs, field) and Map.has_key?(attrs, Atom.to_string(field))
    end)
  end

  defp normalize_value(_value, path, depth) when depth > @max_depth,
    do: {:error, {:governance_data_depth_exceeded, Enum.reverse(path), @max_depth}}

  defp normalize_value(value, _path, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: {:ok, value}

  defp normalize_value(value, path, _depth) when is_binary(value) do
    if byte_size(value) <= @max_bytes,
      do: {:ok, value},
      else: {:error, {:governance_data_binary_too_large, Enum.reverse(path), byte_size(value)}}
  end

  defp normalize_value(value, path, depth) when is_atom(value) and not is_nil(value) do
    name = Atom.to_string(value)

    if String.starts_with?(name, "Elixir."),
      do: {:error, {:governance_data_code_reference, Enum.reverse(path)}},
      else: normalize_value(name, path, depth)
  end

  defp normalize_value(values, path, depth) when is_list(values) do
    if length(values) <= @max_collection_size do
      normalize_list(values, path, depth)
    else
      {:error, {:governance_data_collection_too_large, Enum.reverse(path), length(values)}}
    end
  end

  defp normalize_value(value, path, depth) when is_map(value) and not is_struct(value) do
    with true <- map_size(value) <= @max_collection_size,
         :ok <- reject_code_reference(value, path) do
      normalize_map_entries(value, path, depth)
    else
      false ->
        {:error, {:governance_data_collection_too_large, Enum.reverse(path), map_size(value)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_value(value, path, _depth),
    do: {:error, {:nonportable_governance_data, Enum.reverse(path), shape(value)}}

  defp normalize_list(values, path, depth) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &normalize_list_item(&1, &2, path, depth))
    |> reverse_result()
  end

  defp normalize_list_item({value, index}, {:ok, normalized}, path, depth) do
    case normalize_value(value, [index | path], depth + 1) do
      {:ok, item} -> {:cont, {:ok, [item | normalized]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp normalize_map_entries(value, path, depth) do
    Enum.reduce_while(
      value,
      {:ok, %{}},
      &normalize_map_entry(&1, &2, path, depth)
    )
  end

  defp normalize_map_entry({key, item}, {:ok, normalized}, path, depth) do
    with {:ok, normalized_key} <- normalize_key(key, path),
         false <- Map.has_key?(normalized, normalized_key),
         {:ok, normalized_item} <- normalize_value(item, [normalized_key | path], depth + 1) do
      {:cont, {:ok, Map.put(normalized, normalized_key, normalized_item)}}
    else
      true -> {:halt, {:error, {:duplicate_governance_data_key, normalized_key(key)}}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp normalize_key(key, _path) when is_binary(key) and key != "", do: {:ok, key}

  defp normalize_key(key, path) when is_atom(key) and not is_nil(key) do
    name = Atom.to_string(key)

    if String.starts_with?(name, "Elixir."),
      do: {:error, {:governance_data_code_reference, Enum.reverse(path)}},
      else: normalize_key(name, path)
  end

  defp normalize_key(key, path),
    do: {:error, {:invalid_governance_data_key, Enum.reverse(path), key}}

  defp reject_code_reference(value, path) do
    type = Map.get(value, "$spectre_type", Map.get(value, :"$spectre_type"))

    if type in ["code_ref", :code_ref],
      do: {:error, {:governance_data_code_reference, Enum.reverse(path)}},
      else: :ok
  end

  defp reverse_result({:ok, normalized}), do: {:ok, Enum.reverse(normalized)}
  defp reverse_result({:error, _reason} = error), do: error

  defp normalized_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalized_key(key), do: key

  defp quote_value(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value

  defp quote_value(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: %{"$spectre_value" => "bytes", "base64" => Base.encode64(value)}
  end

  defp quote_value(value) when is_atom(value),
    do: %{"$spectre_value" => "atom", "value" => Atom.to_string(value)}

  defp quote_value(values) when is_list(values), do: Enum.map(values, &quote_value/1)

  defp quote_value(value) when is_tuple(value) do
    %{"$spectre_value" => "tuple", "items" => value |> Tuple.to_list() |> quote_value()}
  end

  defp quote_value(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _item} -> Value.encode!(key) end)
      |> Enum.map(fn {key, item} ->
        %{"key" => quote_value(key), "value" => quote_value(item)}
      end)

    %{"$spectre_value" => "map", "entries" => entries}
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_function(value), do: :function
  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_reference(value), do: :reference
  defp shape(_value), do: :other
end
