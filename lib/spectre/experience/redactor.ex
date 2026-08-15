defmodule Spectre.Experience.Redactor do
  @moduledoc """
  Mechanical redaction boundary for opt-in Experience evidence.

  Redaction is key based and deterministic. It is deliberately not an LLM and
  never attempts to infer hidden meaning from values. Hosts may add keys to the
  fixed constitutional denylist, but cannot remove the built-in entries.
  """

  alias Spectre.Governance.Data
  alias Spectre.SensitiveData

  @max_depth 64
  @redacted "[REDACTED]"
  @type path :: [String.t() | non_neg_integer()]

  @doc "Redacts sensitive fields and returns normalized facts plus exact paths."
  @spec redact(map(), keyword()) :: {:ok, map(), [path()]} | {:error, term()}
  def redact(value, opts \\ [])

  def redact(value, opts) when is_map(value) and not is_struct(value) and is_list(opts) do
    with {:ok, extra} <- extra_keys(Keyword.get(opts, :keys, [])),
         {:ok, redacted, paths} <-
           redact_value(value, [], 0, extra),
         {:ok, normalized} <- Data.normalize_map(redacted) do
      {:ok, normalized, Enum.sort_by(paths, &path_key/1)}
    end
  end

  def redact(value, opts),
    do: {:error, {:invalid_experience_redaction_input, shape(value), shape(opts)}}

  @doc false
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key), do: SensitiveData.sensitive_key?(key)

  @doc false
  @spec redact_portable(term(), keyword()) :: {:ok, term(), [path()]} | {:error, term()}
  def redact_portable(value, opts \\ [])

  def redact_portable(value, opts) when is_list(opts) do
    with {:ok, extra} <- extra_keys(Keyword.get(opts, :keys, [])),
         {:ok, redacted, paths} <- redact_portable_value(value, [], 0, extra) do
      {:ok, redacted, Enum.sort_by(paths, &path_key/1)}
    end
  end

  def redact_portable(_value, opts),
    do: {:error, {:invalid_portable_redaction_options, shape(opts)}}

  defp redact_value(_value, path, depth, _keys) when depth > @max_depth,
    do: {:error, {:experience_redaction_depth_exceeded, Enum.reverse(path), @max_depth}}

  defp redact_value(value, _path, _depth, _keys)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value, []}

  defp redact_value(value, path, depth, keys) when is_atom(value) and not is_nil(value),
    do: redact_value(Atom.to_string(value), path, depth, keys)

  defp redact_value(values, path, depth, keys) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {value, index}, {:ok, items, paths} ->
      case redact_value(value, [index | path], depth + 1, keys) do
        {:ok, item, item_paths} -> {:cont, {:ok, [item | items], item_paths ++ paths}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, paths} -> {:ok, Enum.reverse(items), paths}
      {:error, _reason} = error -> error
    end
  end

  defp redact_value(value, path, depth, keys) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}, []}, fn {raw_key, item}, {:ok, result, paths} ->
      redact_entry(raw_key, item, path, depth, keys, result, paths)
    end)
  end

  defp redact_value(value, path, _depth, _keys),
    do: {:error, {:nonportable_experience_value, Enum.reverse(path), shape(value)}}

  defp redact_portable_value(_value, path, depth, _keys) when depth > @max_depth,
    do: {:error, {:portable_redaction_depth_exceeded, Enum.reverse(path), @max_depth}}

  defp redact_portable_value(value, _path, _depth, _keys)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or
              is_atom(value),
       do: {:ok, value, []}

  defp redact_portable_value(%{__struct__: module} = value, path, depth, keys) do
    with {:ok, fields, paths} <-
           value |> Map.from_struct() |> redact_portable_value(path, depth, keys) do
      {:ok, struct(module, fields), paths}
    end
  rescue
    exception ->
      {:error, {:invalid_portable_redaction_struct, module, exception.__struct__}}
  end

  defp redact_portable_value(value, path, depth, keys) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}, []}, fn {key, item}, {:ok, result, paths} ->
      redact_portable_entry(key, item, path, depth, keys, result, paths)
    end)
  end

  defp redact_portable_value(values, path, depth, keys) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {value, index}, {:ok, items, paths} ->
      case redact_portable_value(value, [index | path], depth + 1, keys) do
        {:ok, item, item_paths} -> {:cont, {:ok, [item | items], item_paths ++ paths}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, paths} -> {:ok, Enum.reverse(items), paths}
      {:error, _reason} = error -> error
    end
  end

  defp redact_portable_value({key, item}, path, depth, keys)
       when is_atom(key) or is_binary(key) do
    if sensitive?(key, keys) do
      {:ok, {key, @redacted}, [Enum.reverse([key_label(key) | path])]}
    else
      redact_portable_tuple({key, item}, path, depth, keys)
    end
  end

  defp redact_portable_value(value, path, depth, keys) when is_tuple(value),
    do: redact_portable_tuple(value, path, depth, keys)

  defp redact_portable_value(value, path, _depth, _keys),
    do: {:error, {:nonportable_redaction_value, Enum.reverse(path), shape(value)}}

  defp redact_portable_entry(key, item, path, depth, keys, result, paths) do
    if sensitive?(key, keys),
      do: redact_sensitive_portable_entry(key, path, result, paths),
      else: redact_safe_portable_entry(key, item, path, depth, keys, result, paths)
  end

  defp redact_sensitive_portable_entry(key, path, result, paths) do
    redacted_path = Enum.reverse([key_label(key) | path])
    {:cont, {:ok, Map.put(result, key, @redacted), [redacted_path | paths]}}
  end

  defp redact_safe_portable_entry(key, item, path, depth, keys, result, paths) do
    case redact_portable_value(item, [key_label(key) | path], depth + 1, keys) do
      {:ok, redacted, item_paths} ->
        {:cont, {:ok, Map.put(result, key, redacted), item_paths ++ paths}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp redact_portable_tuple(value, path, depth, keys) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {item, index}, {:ok, items, paths} ->
      case redact_portable_value(item, [index | path], depth + 1, keys) do
        {:ok, redacted, item_paths} ->
          {:cont, {:ok, [redacted | items], item_paths ++ paths}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, items, paths} -> {:ok, items |> Enum.reverse() |> List.to_tuple(), paths}
      {:error, _reason} = error -> error
    end
  end

  defp redact_entry(raw_key, item, path, depth, keys, result, paths) do
    case key(raw_key, path) do
      {:ok, key} -> redact_entry_value(key, item, path, depth, keys, result, paths)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp redact_entry_value(key, item, path, depth, keys, result, paths) do
    cond do
      Map.has_key?(result, key) ->
        {:halt, {:error, {:ambiguous_experience_key, Enum.reverse([key | path])}}}

      SensitiveData.sensitive_key?(key) or MapSet.member?(keys, SensitiveData.normalize_key(key)) ->
        redacted_path = Enum.reverse([key | path])
        {:cont, {:ok, Map.put(result, key, @redacted), [redacted_path | paths]}}

      true ->
        continue_entry(key, item, path, depth, keys, result, paths)
    end
  end

  defp continue_entry(key, item, path, depth, keys, result, paths) do
    case redact_value(item, [key | path], depth + 1, keys) do
      {:ok, redacted, item_paths} ->
        {:cont, {:ok, Map.put(result, key, redacted), item_paths ++ paths}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp extra_keys(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      value, {:ok, keys} when is_atom(value) and not is_nil(value) ->
        {:cont, {:ok, MapSet.put(keys, SensitiveData.normalize_key(value))}}

      value, {:ok, keys} when is_binary(value) and value != "" ->
        {:cont, {:ok, MapSet.put(keys, SensitiveData.normalize_key(value))}}

      value, _acc ->
        {:halt, {:error, {:invalid_experience_redaction_key, value}}}
    end)
  end

  defp extra_keys(value), do: {:error, {:invalid_experience_redaction_keys, value}}

  defp key(key, _path) when is_binary(key) and key != "", do: {:ok, key}
  defp key(key, path) when is_atom(key) and not is_nil(key), do: key(Atom.to_string(key), path)
  defp key(key, path), do: {:error, {:invalid_experience_key, Enum.reverse(path), key}}

  defp path_key(path), do: Enum.map_join(path, "/", &to_string/1)

  defp sensitive?(key, keys),
    do:
      SensitiveData.sensitive_key?(key) or MapSet.member?(keys, SensitiveData.normalize_key(key))

  defp key_label(key) when is_atom(key) or is_binary(key) or is_integer(key), do: key
  defp key_label(_key), do: :key

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_function(value), do: :function
  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_reference(value), do: :reference
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
