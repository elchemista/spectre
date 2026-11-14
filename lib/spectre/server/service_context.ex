defmodule Spectre.Server.ServiceContext do
  @moduledoc false
  def legacy(context, input, opts, assigns) do
    options =
      context.agent.__spectre_config__()
      |> Keyword.merge(context.options)
      |> Keyword.merge(opts)
      |> Keyword.put(:server_prompt_root, Keyword.get(context.options, :prompt_root))
      |> Keyword.put(:server_prompt_scope, Keyword.get(context.options, :runtime_scope, :agent))
      |> Keyword.put(:instance_run_lifecycle?, false)
      |> Keyword.put(:streaming?, false)
      |> Keyword.put(:plan_actions?, false)

    %Spectre.Context{
      agent: context.agent,
      input: Spectre.Input.new(input || ""),
      state: %Spectre.State{},
      route: Map.get(context.routing, :route),
      memory: Map.get(context, :memory),
      assigns: Map.merge(context.assigns, assigns),
      opts: options
    }
  end
end
