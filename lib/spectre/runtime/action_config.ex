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
  def actions(agent) when is_atom(agent) do
    case Keyword.get(agent.__spectre_config__(), :actions) do
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) and not is_nil(module) -> {module, []}
      _other -> nil
    end
  end

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
end
