defmodule Spectre.Server.Catalog do
  @moduledoc false
  alias Spectre.Action.Provider
  alias Spectre.Action.Provider.Mount
  alias Spectre.ActionConfig

  def planner_options(ctx) do
    opts = ActionConfig.planner_opts(ctx, ctx.opts)
    owner = if ctx.route, do: ctx.route.owner || ctx.agent, else: ctx.agent
    scope = if ctx.route, do: ctx.route.scope || :agent, else: :agent

    opts
    |> Keyword.put(:action_providers, mounts(ctx.agent, ctx.opts))
    |> Keyword.put(:effect_owner, owner)
    |> Keyword.put(:effect_scope, scope)
  end

  defp mounts(agent, opts) do
    providers = ActionConfig.providers(agent)

    case Keyword.get(opts, :actions) do
      nil ->
        providers

      module ->
        [
          Mount.new(:local, Provider.Local, module: module)
          | Enum.reject(providers, &(&1.id == :local))
        ]
    end
  end

  def operation(action, scope) when scope in [:agent, nil] do
    if action.via == :local, do: action.name, else: Spectre.Action.ref(action)
  end

  def operation(action, scope), do: {scope, action.via, action.name}

  def validate(_operation, metadata, _binding, _context) when map_size(metadata) == 0, do: :ok

  def validate(operation, metadata, binding, context) do
    with :ok <- scoped_operation(operation, metadata[:scope]),
         :ok <- origin(metadata, context) do
      schema(operation, metadata, binding, context)
    end
  end

  defp scoped_operation(_operation, scope) when scope in [:agent, nil], do: :ok
  defp scoped_operation({scope, _provider, _name}, scope), do: :ok
  defp scoped_operation(_, _), do: {:error, :proposal_scope_binding_required}

  defp origin(metadata, context) do
    route = Map.get(context.routing, :route)
    owner = if route, do: route.owner || context.agent, else: context.agent
    scope = if route, do: route.scope || :agent, else: :agent

    if metadata[:owner] == owner and metadata[:scope] == scope,
      do: :ok,
      else: {:error, :proposal_origin_mismatch}
  end

  defp schema(operation, %{schema_hash: hash}, binding, context) when is_binary(hash) do
    case binding[:schema_hash] do
      nil -> registered_schema(operation, hash, context)
      ^hash -> :ok
      _ -> {:error, :proposal_schema_mismatch}
    end
  end

  defp schema(_, _, _, _), do: {:error, :proposal_schema_required}

  defp registered_schema(operation, hash, context) do
    {provider, name} = action_ref(operation)

    case Enum.find(mounts(context.agent, context.options), &(&1.id == provider)) do
      nil ->
        {:error, :proposal_provider_unavailable}

      mount ->
        with {:ok, specs} <- Provider.actions(mount, :planner) do
          match_schema(specs, name, hash)
        end
    end
  end

  defp match_schema(specs, name, hash) do
    if Enum.any?(specs, &(&1.name == name and &1.schema_hash == hash)),
      do: :ok,
      else: {:error, :proposal_schema_mismatch}
  end

  defp action_ref({_scope, provider, name}), do: {provider, name}
  defp action_ref({provider, name}), do: {provider, name}
  defp action_ref(name), do: {:local, name}
end
