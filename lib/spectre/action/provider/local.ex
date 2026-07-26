defmodule Spectre.Action.Provider.Local do
  @moduledoc """
  Built-in provider for ordinary Elixir action modules.

  The legacy `actions MyApp.Actions` DSL is normalized to this provider under
  the `:local` identifier.
  """

  @behaviour Spectre.Action.Provider

  alias Spectre.Action
  alias Spectre.Action.Spec

  @impl true
  def actions(opts) do
    case action_module(opts) do
      {:ok, module} -> registered_actions(module, Keyword.get(opts, :provider_id, :local))
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def execute(%Action{name: name, args: args} = action, ctx, opts) do
    with {:ok, module} <- action_module(opts),
         {:ok, function} <- existing_function(name),
         {:ok, arity} <- execution_arity(action, module, function, opts) do
      case arity do
        2 -> apply(module, function, [args, ctx])
        1 -> apply(module, function, [args])
      end
    end
  end

  @spec put_provider(Spec.t() | map(), Spectre.Action.provider_ref()) ::
          Spec.t() | map()
  defp put_provider(%Spec{via: via} = spec, via), do: spec

  defp put_provider(%Spec{} = spec, via) do
    spec
    |> Map.from_struct()
    |> Map.put(:via, via)
    |> Map.put(:schema_hash, nil)
  end

  defp put_provider(spec, via) when is_map(spec), do: Map.put(spec, :via, via)

  @spec registered_actions(module(), Spectre.Action.provider_ref()) ::
          [Spec.t() | map()] | {:error, term()}
  defp registered_actions(module, provider_id) do
    if function_exported?(module, :__spectre_actions__, 0) do
      normalize_registry(module.__spectre_actions__(), module, provider_id)
    else
      []
    end
  end

  @spec normalize_registry(term(), module(), Spectre.Action.provider_ref()) ::
          [Spec.t() | map()] | {:error, term()}
  defp normalize_registry(specs, _module, provider_id) when is_list(specs),
    do: Enum.map(specs, &put_provider(&1, provider_id))

  defp normalize_registry(other, module, _provider_id),
    do: {:error, {:invalid_action_registry, module, other}}

  @spec action_module(keyword()) :: {:ok, module()} | {:error, term()}
  defp action_module(opts) do
    case Keyword.get(opts, :module) do
      module when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module),
          do: {:ok, module},
          else: {:error, {:unknown_action_module, module}}

      other ->
        {:error, {:invalid_local_action_module, other}}
    end
  end

  @spec existing_function(Action.name()) :: {:ok, atom()} | {:error, term()}
  defp existing_function(function) when is_atom(function) and not is_nil(function),
    do: {:ok, function}

  defp existing_function(function) when is_binary(function) do
    {:ok, String.to_existing_atom(function)}
  rescue
    ArgumentError -> {:error, {:unknown_action_name, function}}
  end

  defp existing_function(function), do: {:error, {:invalid_action_name, function}}

  @spec execution_arity(Action.t(), module(), atom(), keyword()) ::
          {:ok, 1 | 2} | {:error, term()}
  defp execution_arity(%Action{schema_hash: hash}, module, function, opts)
       when is_binary(hash) do
    case action_arity_for_hash(actions(opts), hash) do
      arity when arity in [1, 2] ->
        if function_exported?(module, function, arity),
          do: {:ok, arity},
          else: {:error, {:undefined_action, module, function, arity}}

      nil ->
        {:error, {:unknown_action_schema, module, function, hash}}

      arity ->
        {:error, {:unsupported_action_arity, module, function, arity}}
    end
  end

  defp execution_arity(%Action{}, module, function, _opts) do
    cond do
      function_exported?(module, function, 2) -> {:ok, 2}
      function_exported?(module, function, 1) -> {:ok, 1}
      true -> {:error, {:undefined_action, module, function}}
    end
  end

  @spec action_arity_for_hash(term(), String.t()) :: non_neg_integer() | nil
  defp action_arity_for_hash(specs, hash) when is_list(specs) do
    Enum.find_value(specs, fn spec ->
      spec = normalize_spec(spec)

      if spec.schema_hash == hash do
        schema_value(spec.schema, :arity) || schema_value(spec.metadata, :arity)
      end
    end)
  end

  defp action_arity_for_hash(_specs, _hash), do: nil

  @spec normalize_spec(Spec.t() | map()) :: Spec.t()
  defp normalize_spec(%Spec{} = spec), do: spec
  defp normalize_spec(spec) when is_map(spec), do: Spec.new(spec)

  @spec schema_value(term(), atom()) :: term()
  defp schema_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp schema_value(_other, _key), do: nil
end
