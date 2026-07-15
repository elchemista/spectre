defmodule Spectre.ActionConfig do
  @moduledoc """
  Reads action-related configuration from an agent module.

  This module is intentionally small: it is the boundary between declarative
  agent metadata and runtime action planning/execution.
  """

  @type action_config :: {module(), keyword()} | nil

  @doc """
  Returns the configured action module and options for an agent.

      {MyApp.Actions, opts} = Spectre.ActionConfig.actions(MyApp.Agent)
  """
  @spec actions(module()) :: action_config()
  def actions(agent) when is_atom(agent) and not is_nil(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0) do
      case Keyword.get(agent.__spectre_config__(), :actions) do
        {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
        module when is_atom(module) and not is_nil(module) -> {module, []}
        _other -> nil
      end
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  def actions(_agent), do: nil

  @doc """
  Merges runtime options with action planner options.

      opts = Spectre.ActionConfig.planner_opts(ctx, al_parser: MyParser)
  """
  @spec planner_opts(Spectre.Context.t() | map(), keyword()) :: keyword()
  def planner_opts(%{agent: agent}, opts) when is_list(opts) do
    case actions(agent) do
      {module, action_opts} ->
        opts
        |> Keyword.merge(action_opts)
        |> Keyword.put_new(:actions_module, module)

      nil ->
        opts
    end
  end

  @doc """
  Verifies that a dynamically selected tool belongs to the action module
  configured by the agent and, when available, to that module's Kinetic
  registry.
  """
  @spec authorize_tool(module(), module(), atom(), non_neg_integer()) ::
          :ok | {:error, term()}
  def authorize_tool(agent, module, function, arity)
      when is_atom(agent) and not is_nil(agent) and is_atom(module) and
             is_atom(function) and is_integer(arity) do
    case actions(agent) do
      nil ->
        {:error, :missing_actions_module}

      {^module, _opts} ->
        with true <- Code.ensure_loaded?(module),
             true <- function_exported?(module, function, arity),
             :ok <- authorize_registered_tool(module, function, arity) do
          :ok
        else
          false -> {:error, {:undefined_action, module, function, arity}}
          {:error, reason} -> {:error, reason}
        end

      {authorized_module, _opts} ->
        {:error, {:unauthorized_action_module, module, authorized_module}}
    end
  end

  @spec authorize_registered_tool(module(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  defp authorize_registered_tool(module, function, arity) do
    if function_exported?(module, :__spectre_tools__, 0) do
      module
      |> registered_tools()
      |> authorize_registered_tool_result(module, function, arity)
    else
      # A configured plain Elixir action module is itself the explicit registry.
      :ok
    end
  end

  @spec authorize_registered_tool_result(
          {:ok, [map()]} | {:error, term()},
          module(),
          atom(),
          non_neg_integer()
        ) :: :ok | {:error, term()}
  defp authorize_registered_tool_result({:ok, tools}, module, function, arity) do
    case Enum.any?(tools, &registered_tool?(&1, function, arity)) do
      true -> :ok
      false -> {:error, {:unregistered_action_tool, module, function, arity}}
    end
  end

  defp authorize_registered_tool_result({:error, reason}, _module, _function, _arity),
    do: {:error, reason}

  @spec registered_tools(module()) :: {:ok, [map()]} | {:error, term()}
  defp registered_tools(module) do
    case module.__spectre_tools__() do
      tools when is_list(tools) -> {:ok, tools}
      other -> {:error, {:invalid_action_registry, module, other}}
    end
  rescue
    exception ->
      {:error, {:action_registry_exception, module, exception}}
  catch
    kind, reason ->
      {:error, {:action_registry_failure, module, kind, reason}}
  end

  @spec registered_tool?(map(), atom(), non_neg_integer()) :: boolean()
  defp registered_tool?(tool, function, arity) when is_map(tool) do
    tool_function = Map.get(tool, :function) || Map.get(tool, "function")
    tool_arity = Map.get(tool, :arity) || Map.get(tool, "arity")

    tool_function in [function, Atom.to_string(function)] and
      tool_arity in [arity, Integer.to_string(arity)]
  end

  defp registered_tool?(_tool, _function, _arity), do: false
end
