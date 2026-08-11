defmodule Spectre.Execution.Expression do
  @moduledoc """
  Closed expression language used by data-driven execution programs.

  Expressions can read the immutable Work input, current state, or last
  operation result; embed a portable literal; and assemble maps or lists.
  They never contain callbacks, modules, quoted code, or arbitrary MFAs.
  """

  alias Spectre.Canonical.Value

  @sources [:input, :state, :last_result]
  @kinds [:source, :fixed, :object, :list]
  @maximum_depth 48

  @type t :: map()

  @doc "Normalizes one authored expression into its canonical closed form."
  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(value), do: normalize(value, 0)

  defp normalize(_value, depth) when depth > @maximum_depth,
    do: {:error, {:execution_expression_depth_exceeded, @maximum_depth}}

  defp normalize(value, _depth) when value in @sources,
    do: {:ok, %{kind: :source, source: value, path: []}}

  defp normalize(value, _depth)
       when is_binary(value) and value in ~w(input state last_result) do
    {:ok, %{kind: :source, source: String.to_existing_atom(value), path: []}}
  end

  defp normalize({:fixed, value}, _depth), do: fixed(value)

  defp normalize({:path, source, path}, _depth) do
    with {:ok, source} <- source(source),
         {:ok, path} <- path(path, allow_empty?: true) do
      {:ok, %{kind: :source, source: source, path: path}}
    end
  end

  defp normalize(value, depth) when is_map(value) and not is_struct(value) do
    fields = [:kind, :source, :path, :value, :fields, :items]

    with :ok <- reject_ambiguous_keys(value, fields) do
      value = atomize_known_keys(value, fields)

      case enum(Map.get(value, :kind), @kinds) do
        {:ok, :source} -> normalize_source(value)
        {:ok, :fixed} -> normalize_fixed(value)
        {:ok, :object} -> normalize_object(value, depth)
        {:ok, :list} -> normalize_list(value, depth)
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize(value, _depth), do: {:error, {:invalid_execution_expression, shape(value)}}

  @doc "Evaluates a normalized expression against a reduced data environment."
  @spec evaluate(t(), map()) :: {:ok, term()} | {:error, term()}
  def evaluate(%{kind: :source, source: source, path: path}, env) when is_map(env) do
    with {:ok, value} <- fetch_source(env, source), do: fetch_path(value, path)
  end

  def evaluate(%{kind: :fixed, value: value}, _env), do: {:ok, value}

  def evaluate(%{kind: :object, fields: fields}, env) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn %{key: key, value: expression}, {:ok, acc} ->
      case evaluate(expression, env) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def evaluate(%{kind: :list, items: items}, env) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn expression, {:ok, acc} ->
      case evaluate(expression, env) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  def evaluate(value, _env), do: {:error, {:invalid_execution_expression, shape(value)}}

  @doc "Writes a value at a closed map/list path without creating atoms."
  @spec put(term(), [String.t() | non_neg_integer()], term()) :: {:ok, term()} | {:error, term()}
  def put(value, path, replacement) when is_list(path) and path != [] do
    case path(path, allow_empty?: false) do
      {:ok, normalized} -> do_put(value, normalized, replacement)
      {:error, _reason} -> {:error, {:invalid_execution_write_path, path}}
    end
  end

  def put(_value, path, _replacement), do: {:error, {:invalid_execution_write_path, path}}

  @doc "Normalizes a non-empty state path."
  @spec state_path(term()) :: {:ok, [String.t() | non_neg_integer()]} | {:error, term()}
  def state_path(value), do: path(value, allow_empty?: false)

  @spec normalize_source(map()) :: {:ok, t()} | {:error, term()}
  defp normalize_source(value) do
    with :ok <- exact_keys(value, [:kind, :source, :path]),
         {:ok, source} <- source(Map.get(value, :source)),
         {:ok, path} <- path(Map.get(value, :path, []), allow_empty?: true) do
      {:ok, %{kind: :source, source: source, path: path}}
    end
  end

  @spec normalize_fixed(map()) :: {:ok, t()} | {:error, term()}
  defp normalize_fixed(value) do
    with :ok <- exact_keys(value, [:kind, :value]),
         true <- Map.has_key?(value, :value) do
      fixed(Map.fetch!(value, :value))
    else
      false -> {:error, :execution_fixed_expression_requires_value}
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_object(map(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  defp normalize_object(value, depth) do
    with :ok <- exact_keys(value, [:kind, :fields]),
         fields when is_map(fields) or is_list(fields) <- Map.get(value, :fields),
         {:ok, fields} <- normalize_fields(fields, depth + 1) do
      {:ok, %{kind: :object, fields: fields}}
    else
      {:error, _reason} = error -> error
      fields -> {:error, {:invalid_execution_object_fields, shape(fields)}}
    end
  end

  @spec normalize_list(map(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  defp normalize_list(value, depth) do
    with :ok <- exact_keys(value, [:kind, :items]),
         items when is_list(items) <- Map.get(value, :items),
         {:ok, items} <- normalize_items(items, depth + 1) do
      {:ok, %{kind: :list, items: items}}
    else
      {:error, _reason} = error -> error
      items -> {:error, {:invalid_execution_list_items, shape(items)}}
    end
  end

  @spec fixed(term()) :: {:ok, t()} | {:error, term()}
  defp fixed(value) do
    with :ok <- reject_executable_value(value) do
      case Value.validate(value) do
        :ok -> {:ok, %{kind: :fixed, value: value}}
        {:error, reason} -> {:error, {:nonportable_execution_literal, reason}}
      end
    end
  end

  @doc false
  @spec normalize_program(term()) :: {:ok, t()} | {:error, term()}
  def normalize_program(value) do
    with {:ok, expression} <- normalize(value), do: normalize_program_literals(expression)
  end

  @doc false
  @spec normalize_literal(term()) :: {:ok, term()} | {:error, term()}
  def normalize_literal(value) do
    with :ok <- reject_executable_value(value),
         {:ok, value} <- normalize_json_value(value, []) do
      case Value.validate(value) do
        :ok -> {:ok, value}
        {:error, reason} -> {:error, {:nonportable_execution_literal, reason}}
      end
    end
  end

  @spec normalize_program_literals(t()) :: {:ok, t()} | {:error, term()}
  defp normalize_program_literals(%{kind: :fixed, value: value} = expression) do
    with {:ok, value} <- normalize_literal(value), do: {:ok, %{expression | value: value}}
  end

  defp normalize_program_literals(%{kind: :object, fields: fields} = expression) do
    fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, normalized} ->
      case normalize_program_literals(field.value) do
        {:ok, value} -> {:cont, {:ok, [%{field | value: value} | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, %{expression | fields: Enum.reverse(fields)}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_program_literals(%{kind: :list, items: items} = expression) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, normalized} ->
      case normalize_program_literals(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, %{expression | items: Enum.reverse(items)}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_program_literals(expression), do: {:ok, expression}

  @spec normalize_fields(map() | [map()], non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  defp normalize_fields(fields, depth) when is_map(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn {key, expression}, {:ok, acc} ->
      with {:ok, key} <- field_key(key),
           {:ok, expression} <- normalize(expression, depth) do
        {:cont, {:ok, [%{key: key, value: expression} | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> finalize_fields()
  end

  defp normalize_fields(fields, depth) when is_list(fields) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {field, index}, {:ok, acc} when is_map(field) and not is_struct(field) ->
        with :ok <- reject_ambiguous_keys(field, [:key, :value]),
             field <- atomize_known_keys(field, [:key, :value]),
             :ok <- exact_keys(field, [:key, :value]),
             true <- Map.has_key?(field, :value),
             {:ok, key} <- field_key(Map.get(field, :key)),
             {:ok, expression} <- normalize(Map.fetch!(field, :value), depth) do
          {:cont, {:ok, [%{key: key, value: expression} | acc]}}
        else
          false ->
            {:halt, {:error, {:execution_object_field_requires_value, index}}}

          {:error, {:execution_expression_depth_exceeded, _maximum}} = error ->
            {:halt, error}

          {:error, reason} ->
            {:halt, {:error, {:invalid_execution_object_field, index, reason}}}
        end

      {_field, index}, _acc ->
        {:halt, {:error, {:invalid_execution_object_field, index, :not_a_map}}}
    end)
    |> finalize_fields()
  end

  @spec finalize_fields({:ok, [map()]} | {:error, term()}) ::
          {:ok, [map()]} | {:error, term()}
  defp finalize_fields({:ok, normalized}) do
    normalized = Enum.sort_by(normalized, &Value.encode!(&1.key))
    keys = Enum.map(normalized, & &1.key)

    if Enum.uniq(keys) == keys,
      do: {:ok, normalized},
      else: {:error, :duplicate_execution_object_key}
  end

  defp finalize_fields({:error, _reason} = error) do
    error
  end

  @spec normalize_items([term()], non_neg_integer()) :: {:ok, [t()]} | {:error, term()}
  defp normalize_items(items, depth) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case normalize(item, depth) do
        {:ok, expression} ->
          {:cont, {:ok, [expression | acc]}}

        {:error, {:execution_expression_depth_exceeded, _maximum}} = error ->
          {:halt, error}

        {:error, reason} ->
          {:halt, {:error, {:invalid_execution_list_item, index, reason}}}
      end
    end)
    |> reverse_result()
  end

  @spec source(term()) :: {:ok, atom()} | {:error, term()}
  defp source(value) when value in @sources, do: {:ok, value}

  defp source(value) when is_binary(value) do
    case Enum.find(@sources, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_execution_expression_source, value}}
      source -> {:ok, source}
    end
  end

  defp source(value), do: {:error, {:invalid_execution_expression_source, value}}

  @spec path(term(), keyword()) ::
          {:ok, [String.t() | non_neg_integer()]} | {:error, term()}
  defp path(value, opts) when is_list(value) do
    allow_empty? = Keyword.fetch!(opts, :allow_empty?)

    cond do
      value == [] and not allow_empty? ->
        {:error, :execution_path_cannot_be_empty}

      Enum.all?(value, &valid_path_segment?/1) ->
        {:ok, Enum.map(value, &normalize_path_segment/1)}

      true ->
        {:error, {:invalid_execution_path, value}}
    end
  end

  defp path(value, _opts), do: {:error, {:invalid_execution_path, value}}

  @spec fetch_source(map(), atom()) :: {:ok, term()} | {:error, term()}
  defp fetch_source(env, source) do
    case Map.fetch(env, source) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_execution_expression_source, source}}
    end
  end

  @spec fetch_path(term(), [String.t() | non_neg_integer()]) ::
          {:ok, term()} | {:error, term()}
  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [segment | rest]) when is_map(value) and is_binary(segment) do
    case map_key(value, segment) do
      {:ok, key} -> fetch_path(Map.fetch!(value, key), rest)
      :error -> {:error, {:execution_expression_path_not_found, segment}}
    end
  end

  defp fetch_path(value, [index | rest])
       when is_list(value) and is_integer(index) and index >= 0 do
    case Enum.fetch(value, index) do
      {:ok, item} -> fetch_path(item, rest)
      :error -> {:error, {:execution_expression_path_not_found, index}}
    end
  end

  defp fetch_path(_value, [segment | _rest]),
    do: {:error, {:execution_expression_path_not_traversable, segment}}

  @spec do_put(term(), [String.t() | non_neg_integer()], term()) ::
          {:ok, term()} | {:error, term()}
  defp do_put(value, [segment], replacement) when is_map(value) and is_binary(segment) do
    key =
      case map_key(value, segment) do
        {:ok, existing} -> existing
        :error -> segment
      end

    {:ok, Map.put(value, key, replacement)}
  end

  defp do_put(value, [segment | rest], replacement)
       when is_map(value) and is_binary(segment) do
    key =
      case map_key(value, segment) do
        {:ok, existing} -> existing
        :error -> segment
      end

    child = Map.get(value, key, %{})

    with {:ok, child} <- do_put(child, rest, replacement) do
      {:ok, Map.put(value, key, child)}
    end
  end

  defp do_put(value, [index], replacement)
       when is_list(value) and is_integer(index) and index >= 0 do
    if index < length(value),
      do: {:ok, List.replace_at(value, index, replacement)},
      else: {:error, {:execution_write_index_out_of_bounds, index}}
  end

  defp do_put(value, [index | rest], replacement)
       when is_list(value) and is_integer(index) and index >= 0 do
    with {:ok, child} <- Enum.fetch(value, index),
         {:ok, child} <- do_put(child, rest, replacement) do
      {:ok, List.replace_at(value, index, child)}
    else
      :error -> {:error, {:execution_write_index_out_of_bounds, index}}
      {:error, _reason} = error -> error
    end
  end

  defp do_put(_value, [segment | _rest], _replacement),
    do: {:error, {:execution_write_path_not_traversable, segment}}

  @spec map_key(map(), String.t()) :: {:ok, term()} | :error
  defp map_key(map, segment) do
    if Map.has_key?(map, segment) do
      {:ok, segment}
    else
      case Enum.find(Map.keys(map), &(is_atom(&1) and Atom.to_string(&1) == segment)) do
        nil -> :error
        key -> {:ok, key}
      end
    end
  end

  @spec reject_executable_value(term(), [term()], non_neg_integer()) ::
          :ok | {:error, term()}
  defp reject_executable_value(value, path \\ [], depth \\ 0)

  defp reject_executable_value(_value, _path, depth) when depth > @maximum_depth,
    do: {:error, {:execution_expression_depth_exceeded, @maximum_depth}}

  defp reject_executable_value({module, function}, path, _depth)
       when is_atom(module) and is_atom(function) do
    {:error, {:executable_execution_literal, Enum.reverse(path)}}
  end

  defp reject_executable_value(value, path, _depth) when is_atom(value) do
    if module_atom?(value),
      do: {:error, {:module_execution_literal, Enum.reverse(path)}},
      else: :ok
  end

  defp reject_executable_value(value, path, depth) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      with :ok <- reject_executable_value(key, [{:key, key} | path], depth + 1),
           :ok <- reject_executable_value(item, [key | path], depth + 1) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_executable_value(value, path, depth) when is_list(value),
    do: reject_list(value, path, depth + 1, 0)

  defp reject_executable_value(value, path, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> reject_children(path, depth + 1)

  defp reject_executable_value(_value, _path, _depth), do: :ok

  @spec reject_children([term()], [term()], non_neg_integer()) :: :ok | {:error, term()}
  defp reject_children(values, path, depth) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case reject_executable_value(value, [index | path], depth) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec reject_list(term(), [term()], non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp reject_list([], _path, _depth, _index), do: :ok

  defp reject_list([item | rest], path, depth, index) do
    with :ok <- reject_executable_value(item, [index | path], depth) do
      reject_list(rest, path, depth, index + 1)
    end
  end

  defp reject_list(_improper, path, _depth, index),
    do: {:error, {:nonportable_execution_literal, {:improper_list, Enum.reverse(path), index}}}

  @spec normalize_json_value(term(), [term()]) :: {:ok, term()} | {:error, term()}
  defp normalize_json_value(value, _path)
       when is_nil(value) or is_boolean(value) or is_integer(value),
       do: {:ok, value}

  defp normalize_json_value(value, _path) when is_float(value), do: {:ok, value}

  defp normalize_json_value(value, path) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, {:nonportable_execution_literal, {:invalid_utf8, Enum.reverse(path)}}}
  end

  defp normalize_json_value(value, _path) when is_atom(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_json_value(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, normalized} ->
      case normalize_json_value(item, [index | path]) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp normalize_json_value(value, path) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_json_key(key, path),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize_json_value(item, [key | path]) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        true ->
          {:halt, {:error, {:nonportable_execution_literal, {:duplicate_json_key, key}}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize_json_value(value, path),
    do:
      {:error,
       {:nonportable_execution_literal,
        {:unsupported_json_value, Enum.reverse(path), shape(value)}}}

  @spec normalize_json_key(term(), [term()]) :: {:ok, String.t()} | {:error, term()}
  defp normalize_json_key(value, _path) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_json_key(value, _path) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, {:nonportable_execution_literal, :invalid_utf8_map_key}}
  end

  defp normalize_json_key(value, path),
    do:
      {:error,
       {:nonportable_execution_literal,
        {:unsupported_json_map_key, Enum.reverse(path), shape(value)}}}

  @spec field_key(term()) :: {:ok, String.t()} | {:error, term()}
  defp field_key(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp field_key(value) when is_binary(value) and value != "", do: {:ok, value}
  defp field_key(value), do: {:error, {:invalid_execution_object_key, value}}

  @spec exact_keys(map(), [atom()]) :: :ok | {:error, term()}
  defp exact_keys(value, allowed) do
    case Map.keys(value) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_execution_expression_fields, Enum.sort(unknown)}}
    end
  end

  @spec enum(term(), [atom()]) :: {:ok, atom()} | {:error, term()}
  defp enum(value, allowed) when is_atom(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_execution_expression_kind, value}}
  end

  defp enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_execution_expression_kind, value}}
      kind -> {:ok, kind}
    end
  end

  defp enum(value, _allowed), do: {:error, {:invalid_execution_expression_kind, value}}

  @spec valid_path_segment?(term()) :: boolean()
  defp valid_path_segment?(value) when is_atom(value), do: not is_nil(value)
  defp valid_path_segment?(value) when is_binary(value), do: value != ""
  defp valid_path_segment?(value) when is_integer(value), do: value >= 0
  defp valid_path_segment?(_value), do: false

  @spec normalize_path_segment(atom() | String.t() | non_neg_integer()) ::
          String.t() | non_neg_integer()
  defp normalize_path_segment(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_path_segment(value), do: value

  @spec atomize_known_keys(map(), [atom()]) :: map()
  defp atomize_known_keys(value, fields) do
    Enum.reduce(fields, value, fn field, acc ->
      string = Atom.to_string(field)

      case Map.fetch(acc, string) do
        {:ok, item} -> acc |> Map.delete(string) |> Map.put_new(field, item)
        :error -> acc
      end
    end)
  end

  @spec reject_ambiguous_keys(map(), [atom()]) :: :ok | {:error, term()}
  defp reject_ambiguous_keys(value, fields) do
    case Enum.find(fields, fn field ->
           Map.has_key?(value, field) and Map.has_key?(value, Atom.to_string(field))
         end) do
      nil -> :ok
      field -> {:error, {:ambiguous_execution_expression_field, field}}
    end
  end

  @spec module_atom?(atom()) :: boolean()
  defp module_atom?(value), do: String.starts_with?(Atom.to_string(value), "Elixir.")

  @spec reverse_result({:ok, [term()]} | {:error, term()}) ::
          {:ok, [term()]} | {:error, term()}
  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
