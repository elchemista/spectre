defmodule Spectre.Agent.Wiring do
  @moduledoc false

  alias Spectre.{Adapter, Portable}
  alias Spectre.Agent.{Classification, Flow, Publication}
  alias Spectre.Input.Pipeline
  alias Spectre.Router.Rule
  alias Spectre.Router.SemanticCache

  @groups [:router, :pipelines, :history, :memory, :semantic_cache, :classifier, :request]

  @doc "Resolves the single port manifest; never starts resources or calls providers."
  @spec resolve(module(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def resolve(module, adapters) do
    declared = Publication.ports(module)
    groups = Enum.uniq(@groups ++ Enum.map(declared, fn {_name, port} -> port.kind end))

    with {:ok, supplied} <- Portable.normalize_attrs(adapters, groups, :agent_adapters),
         {:ok, supplied} <- flatten(supplied),
         {:ok, ports} <- resolve_ports(declared, supplied) do
      {:ok, %{ports: ports}}
    end
  end

  @doc false
  def flow(entry, definition_ref, name, wiring, prefix) do
    with {:ok, adapters} <- flow_adapters(entry, definition_ref, name, wiring, prefix) do
      data = Publication.flow_body(entry, name)

      pipelines =
        Map.new(entry.pipelines, &{&1, Map.fetch!(wiring.ports, prefix <> "pipelines/" <> &1)})

      Flow.new(definition_ref, name, data, pipelines: pipelines, adapters: adapters)
    end
  end

  @doc false
  def fetch(wiring, prefix, kind, name),
    do: Map.fetch(wiring.ports, prefix <> Atom.to_string(kind) <> "/" <> to_string(name))

  defp flow_adapters(entry, definition_ref, name, wiring, prefix) do
    via = if entry.routing, do: entry.routing["via"], else: []

    adapters =
      for method <- via,
          {:ok, adapter} <- [fetch(wiring, prefix, :router, method)],
          into: %{},
          do: {method, adapter}

    Enum.reduce_while(entry.binding, {:ok, adapters}, fn {kind, local}, {:ok, adapters} ->
      case flow_adapter(kind, local, definition_ref, name, wiring, prefix, via) do
        {:ok, method, adapter} -> {:cont, {:ok, Map.put_new(adapters, method, adapter)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  def cache(name, definition_ref, flow, wiring, prefix) do
    with {:ok, {module, opts}} <- fetch(wiring, prefix, :semantic_cache, name),
         {binding, opts} = Keyword.split(opts, [:namespace, :profile_ref]),
         binding = Map.new(binding) |> Map.merge(%{definition_ref: definition_ref, flow: flow}),
         {:ok, cache} <- SemanticCache.bind({module, opts}, binding) do
      {:ok, cache}
    else
      :error -> {:error, {:unwired_semantic_cache, name}}
      error -> error
    end
  end

  defp flow_adapter(:cache, name, definition_ref, flow, wiring, prefix, _via) do
    with {:ok, cache} <- cache(name, definition_ref, flow, wiring, prefix),
         do: {:ok, "semantic_cache", {SemanticCache.RouterAdapter, [cache: cache]}}
  end

  defp flow_adapter(:classifier, name, _definition, _flow, wiring, prefix, via) do
    case fetch(wiring, prefix, :classifier, name) do
      {:ok, {module, opts}} -> classifier_adapter(module, opts, via)
      :error -> {:error, {:unwired_classifier, name}}
      error -> error
    end
  end

  defp classifier_adapter(module, opts, via) do
    cond do
      "local_classifier" in via and "llm_classifier" in via ->
        {:error, :one_classifier_mode_per_flow}

      "local_classifier" in via ->
        with :ok <- Adapter.validate(module, evaluate: 2),
             do: {:ok, "local_classifier", {module, opts}}

      "llm_classifier" in via ->
        with :ok <- Adapter.validate(module, prepare: 4),
             do: {:ok, "llm_classifier", Classification}

      true ->
        {:error, :classifier_method_required}
    end
  end

  defp resolve_ports(declared, supplied) do
    extras = Map.keys(supplied) -- Map.keys(declared)

    if extras == [] do
      {aliases, concrete} =
        Enum.split_with(declared, fn {_name, port} -> Map.has_key?(port, :via) end)

      Enum.reduce_while(concrete, {:ok, %{}}, &resolve_port(&1, &2, supplied))
      |> resolve_aliases(aliases, supplied)
    else
      {:error, {:undeclared_ports, Enum.sort(extras)}}
    end
  end

  defp resolve_port({name, port}, {:ok, ports}, supplied) do
    with {:ok, value} <- supplied_binding(supplied, name, port),
         {:ok, configured} <- configure(port, value) do
      {:cont, {:ok, Map.put(ports, name, configured)}}
    else
      :error ->
        if Map.get(port, :optional, false),
          do: {:cont, {:ok, ports}},
          else: {:halt, {:error, {:unwired_port, name, port.origin}}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_port, name, reason}}}
    end
  end

  # A complete static adapter declaration is already wiring. Runtime values
  # only supply resources such as a supervised server or tenant binding.
  defp supplied_binding(supplied, name, port) do
    case Map.fetch(supplied, name) do
      :error when not is_nil(port.module) -> {:ok, []}
      result -> result
    end
  end

  defp resolve_aliases({:error, _} = error, _aliases, _supplied), do: error

  defp resolve_aliases({:ok, ports}, aliases, supplied) do
    # One explicit link to a request adapter, never recursive dependency
    # resolution. Inline and Stack declarations use exactly this same path.
    Enum.reduce_while(aliases, {:ok, ports}, fn {name, port}, {:ok, resolved} ->
      with false <- Map.has_key?(supplied, name),
           {:ok, adapter} <- Map.fetch(ports, port.via) do
        {:cont, {:ok, Map.put(resolved, name, adapter)}}
      else
        true -> {:halt, {:error, {:aliased_port_override, name}}}
        :error -> {:halt, {:error, {:unwired_port, port.via, port.origin}}}
      end
    end)
  end

  defp configure(%{kind: :pipelines}, value), do: Pipeline.fetch(value)

  defp configure(%{module: declared} = port, {module, opts})
       when is_nil(declared) or module == declared,
       do: configure(%{port | module: module}, opts)

  defp configure(_port, {_module, _opts}), do: {:error, :declared_adapter_mismatch}

  defp configure(%{module: nil} = port, module) when is_atom(module) and not is_nil(module),
    do: configure(%{port | module: module}, [])

  defp configure(%{module: module} = port, module) when not is_nil(module),
    do: configure(port, [])

  defp configure(%{module: nil}, _opts), do: {:error, :adapter_module_required}

  defp configure(port, opts) when is_list(opts) do
    if Portable.keyword?(opts) do
      collisions =
        Enum.filter(port.options, fn {key, value} ->
          Keyword.has_key?(opts, key) and Keyword.fetch!(opts, key) !== value
        end)

      with [] <- collisions,
           :ok <- reserved_options(port, opts),
           :ok <-
             Adapter.validate(
               port.module,
               callbacks(port) ++ Map.get(port, :required_callbacks, [])
             ) do
        {:ok, {port.module, Keyword.merge(port.options, opts)}}
      else
        [_ | _] -> {:error, :semantic_port_options_overridden}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_port_options}
    end
  end

  defp configure(_port, _value), do: {:error, :invalid_port_binding}

  defp reserved_options(port, opts) do
    opts = port.options ++ opts

    cond do
      Keyword.has_key?(opts, :declaration) ->
        {:error, {:reserved_adapter_option, :declaration}}

      port.kind == :semantic_cache and Keyword.has_key?(opts, :embed) ->
        {:error, :cache_embedding_callback_not_supported}

      true ->
        :ok
    end
  end

  defp callbacks(%{kind: :semantic_cache}), do: [lookup: 3, info: 1]
  defp callbacks(%{kind: :classifier, mode: :governed}), do: [prepare: 4]
  defp callbacks(%{kind: kind}) when kind in [:classifier, :router], do: [evaluate: 2]
  defp callbacks(%{kind: :history}), do: [load: 3, append: 3, record_delivery: 3]
  defp callbacks(%{kind: :memory}), do: [retrieve: 3]
  defp callbacks(%{kind: :request}), do: [prepare: 4]
  defp callbacks(%{kind: :observer}), do: [handle_event: 4]
  defp callbacks(_port), do: []

  defp flatten(groups) do
    Enum.reduce_while(groups, {:ok, %{}}, fn {kind, values}, {:ok, result} ->
      case registry(values) do
        {:ok, values} ->
          entries =
            Map.new(values, &qualified_binding(&1, kind))

          {:cont, {:ok, Map.merge(result, entries)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp qualified_binding({name, value}, kind) do
    {prefix, [local]} = name |> String.split("/") |> Enum.split(-1)
    {Enum.join(prefix ++ [Atom.to_string(kind), local], "/"), value}
  end

  @doc false
  def registry(values) when is_map(values) and not is_struct(values), do: normalize_keys(values)

  def registry(values) when is_list(values) do
    if Portable.keyword?(values),
      do: normalize_keys(values),
      else: {:error, :invalid_adapter_registry}
  end

  def registry(_values), do: {:error, :invalid_adapter_registry}

  defp normalize_keys(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn
      {key, value}, {:ok, found} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        with :ok <- Rule.path(key),
             false <- Map.has_key?(found, key) do
          {:cont, {:ok, Map.put(found, key, value)}}
        else
          true -> {:halt, {:error, {:duplicate_adapter_key, key}}}
          error -> {:halt, error}
        end

      _invalid, _found ->
        {:halt, {:error, :invalid_adapter_key}}
    end)
  end
end
