defmodule Spectre.Server.PreRoute do
  @moduledoc false

  def interrupt(agent, input, context) do
    rules =
      if function_exported?(agent, :__spectre_rules__, 0),
        do: Spectre.Definition.rules(agent),
        else: []

    if Enum.any?(rules, &Map.get(&1, :global?, false)) do
      opts = options(agent, context) |> Keyword.put(:policy_interrupt_only?, true)

      case Spectre.Server.Router.route(agent, input, opts) do
        {:ok, route, metadata} -> {:interrupt, route, metadata}
        {:unmatched, _} -> :cont
        {:error, _} = error -> error
      end
    else
      :cont
    end
  end

  def handle(agent, input, context) do
    opts = options(agent, context)

    if Keyword.get(opts, :turn_handlers, []) in [nil, false, []] do
      :cont
    else
      state = %Spectre.State{
        current_flow: context.current_flow,
        current_scope: context.current_scope,
        data: %{chat_history: context.history}
      }

      ctx = %Spectre.Context{
        agent: agent,
        input: input,
        state: state,
        memory: context.memory,
        assigns: context.assigns,
        opts: opts
      }

      case Spectre.Turn.Handlers.dispatch(ctx) do
        {:reply, %Spectre.Result{} = result} -> {:handled, result.reply_text}
        other -> other
      end
    end
  end

  defp options(agent, context) do
    agent.__spectre_config__()
    |> Keyword.merge(context.options)
    |> Keyword.put(:assigns, context.assigns)
    |> Keyword.put(:current_flow, context.current_flow)
    |> Keyword.put(:current_scope, context.current_scope)
    |> Keyword.put(:history, context.history)
    |> Keyword.put(:instance_run_lifecycle?, false)
  end
end
