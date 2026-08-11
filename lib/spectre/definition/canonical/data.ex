defmodule Spectre.Definition.Canonical.Data do
  @moduledoc false

  alias Spectre.Canonical.Value
  alias Spectre.SensitiveData

  @doc false
  @spec lower(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def lower(value, opts \\ []) when is_list(opts) do
    lower_value(value, Keyword.get(opts, :owner), Keyword.get(opts, :path, []), 0)
  end

  @doc false
  @spec structural(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def structural(value, opts \\ []) do
    with {:ok, lowered} <- lower(value, opts),
         false <- code_reference?(lowered) do
      {:ok, lowered}
    else
      true -> {:error, {:executable_structural_value, Keyword.get(opts, :path, [])}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec module_ref(module()) :: map()
  def module_ref(module) when is_atom(module) and not is_nil(module) do
    %{
      "$spectre_type" => "code_ref",
      "kind" => "module",
      "module" => Atom.to_string(module),
      "mode" => "compiled_only"
    }
  end

  @doc false
  @spec callback_ref(module(), atom(), [non_neg_integer()] | non_neg_integer()) :: map()
  def callback_ref(module, function, arities)
      when is_atom(module) and not is_nil(module) and is_atom(function) and
             not is_nil(function) do
    %{
      "$spectre_type" => "code_ref",
      "kind" => "callback",
      "module" => Atom.to_string(module),
      "function" => Atom.to_string(function),
      "arities" => List.wrap(arities),
      "mode" => "compiled_only"
    }
  end

  @spec lower_value(term(), module() | nil, [term()], non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  defp lower_value(_value, _owner, path, depth) when depth > 128,
    do: {:error, {:compiled_definition_depth_exceeded, Enum.reverse(path)}}

  defp lower_value(value, _owner, _path, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value),
       do: {:ok, value}

  defp lower_value(value, _owner, _path, _depth) when is_atom(value) do
    if module_atom?(value), do: {:ok, module_ref(value)}, else: {:ok, value}
  end

  defp lower_value(%Regex{} = regex, _owner, _path, _depth) do
    {:ok,
     %{
       "$spectre_type" => "regex",
       "source" => Regex.source(regex),
       "options" => Regex.opts(regex)
     }}
  end

  defp lower_value(value, owner, path, depth) when is_function(value) do
    info = Map.new(Function.info(value))

    with {:ok, environment} <-
           lower_value(Map.get(info, :env, []), owner, [:closure_environment | path], depth + 1) do
      {:ok,
       %{
         "$spectre_type" => "code_ref",
         "kind" => "function",
         "module" => info |> Map.fetch!(:module) |> Atom.to_string(),
         "function" => info |> Map.fetch!(:name) |> Atom.to_string(),
         "arity" => Map.fetch!(info, :arity),
         "closure_environment" => environment,
         "mode" => "compiled_only"
       }}
    end
  end

  defp lower_value(%{__struct__: module} = value, owner, path, depth) when is_atom(module) do
    with {:ok, fields} <-
           lower_value(Map.from_struct(value), owner, [:fields | path], depth + 1) do
      {:ok,
       %{
         "$spectre_type" => "struct",
         "module_ref" => module_ref(module),
         "fields" => fields
       }}
    end
  end

  defp lower_value([], _owner, _path, _depth), do: {:ok, []}

  defp lower_value([head | tail], owner, path, depth) do
    with {:ok, head} <- lower_value(head, owner, [0 | path], depth + 1),
         {:ok, tail} <- lower_list_tail(tail, owner, path, depth + 1, 1, []) do
      {:ok, [head | tail]}
    end
  end

  defp lower_value({key, value} = tuple, owner, path, depth)
       when is_atom(key) or is_binary(key) do
    cond do
      sensitive_key?(key) ->
        {:error, {:secret_compiled_definition_value, Enum.reverse([key | path])}}

      is_atom(key) and is_atom(value) and module_atom?(key) ->
        {:ok, callback_ref(key, value, [])}

      true ->
        lower_tuple(tuple, owner, path, depth)
    end
  end

  defp lower_value({module, function, arguments}, owner, path, depth)
       when is_atom(module) and is_atom(function) do
    if module_atom?(module) do
      with {:ok, arguments} <-
             lower_value(arguments, owner, [:arguments | path], depth + 1) do
        {:ok, Map.put(callback_ref(module, function, []), "arguments", arguments)}
      end
    else
      lower_tuple({module, function, arguments}, owner, path, depth)
    end
  end

  defp lower_value(value, owner, path, depth) when is_tuple(value),
    do: lower_tuple(value, owner, path, depth)

  defp lower_value(value, owner, path, depth) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, %{}},
      &lower_map_entry(&1, &2, owner, path, depth)
    )
  end

  defp lower_value(value, _owner, path, _depth) do
    {:error,
     {:nonportable_compiled_definition_value, Enum.reverse(path), unsupported_kind(value)}}
  end

  @spec lower_map_entry(
          {{term(), term()}, non_neg_integer()},
          {:ok, map()},
          module() | nil,
          [term()],
          non_neg_integer()
        ) :: {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp lower_map_entry({{key, _item}, _index} = entry, acc, owner, path, depth)
       when is_atom(key) or is_binary(key) do
    if sensitive_key?(key) do
      {:halt, {:error, {:secret_compiled_definition_value, Enum.reverse([key | path])}}}
    else
      lower_map_entry_value(entry, acc, owner, path, depth)
    end
  end

  defp lower_map_entry(entry, acc, owner, path, depth) do
    lower_map_entry_value(entry, acc, owner, path, depth)
  end

  @spec lower_map_entry_value(
          {{term(), term()}, non_neg_integer()},
          {:ok, map()},
          module() | nil,
          [term()],
          non_neg_integer()
        ) :: {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp lower_map_entry_value({{key, item}, index}, {:ok, lowered}, owner, path, depth) do
    with {:ok, key} <- lower_value(key, owner, [{:key, index} | path], depth + 1),
         {:ok, item} <- lower_value(item, owner, [{:value, index} | path], depth + 1) do
      {:cont, {:ok, Map.put(lowered, key, item)}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @spec lower_list_tail(term(), module() | nil, [term()], non_neg_integer(), non_neg_integer(), [
          term()
        ]) ::
          {:ok, [term()]} | {:error, term()}
  defp lower_list_tail([], _owner, _path, _depth, _index, lowered),
    do: {:ok, Enum.reverse(lowered)}

  defp lower_list_tail([head | tail], owner, path, depth, index, lowered) do
    with {:ok, head} <- lower_value(head, owner, [index | path], depth + 1) do
      lower_list_tail(tail, owner, path, depth, index + 1, [head | lowered])
    end
  end

  defp lower_list_tail(_tail, _owner, path, _depth, index, _lowered),
    do: {:error, {:improper_compiled_definition_list, Enum.reverse([{:tail, index} | path])}}

  @spec lower_tuple(tuple(), module() | nil, [term()], non_neg_integer()) ::
          {:ok, tuple()} | {:error, term()}
  defp lower_tuple(value, owner, path, depth) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, lowered} ->
      case lower_value(item, owner, [index | path], depth + 1) do
        {:ok, item} -> {:cont, {:ok, [item | lowered]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lowered} -> {:ok, lowered |> Enum.reverse() |> List.to_tuple()}
      {:error, _reason} = error -> error
    end
  end

  @spec code_reference?(term()) :: boolean()
  defp code_reference?(%{"$spectre_type" => "code_ref"}), do: true
  defp code_reference?(value) when is_map(value), do: Enum.any?(value, &code_reference?/1)
  defp code_reference?({key, value}), do: code_reference?(key) or code_reference?(value)
  defp code_reference?(value) when is_list(value), do: Enum.any?(value, &code_reference?/1)

  defp code_reference?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&code_reference?/1)

  defp code_reference?(_value), do: false

  @spec module_atom?(atom()) :: boolean()
  defp module_atom?(module), do: module |> Atom.to_string() |> String.starts_with?("Elixir.")

  @spec sensitive_key?(atom() | String.t()) :: boolean()
  defp sensitive_key?(key), do: SensitiveData.sensitive_key?(key)

  @spec unsupported_kind(term()) :: atom()
  defp unsupported_kind(value) when is_pid(value), do: :pid
  defp unsupported_kind(value) when is_port(value), do: :port
  defp unsupported_kind(value) when is_reference(value), do: :reference
  defp unsupported_kind(value) when is_bitstring(value), do: :bitstring

  defp unsupported_kind(value) do
    case Value.validate(value) do
      {:error, {:unsupported_canonical_value, _path, kind}} -> kind
      {:error, _reason} -> :nonportable
      :ok -> :unsupported
    end
  end
end
