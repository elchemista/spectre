defmodule Spectre.Router.Plugs.Regex do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.Support
  alias Spectre.Rule

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    if Context.halted?(context) do
      {:cont, context}
    else
      match_regex(context)
    end
  end

  @spec match_regex(Context.t()) :: {:cont, Context.t()}
  defp match_regex(%Context{input: %{text: text}, labels: labels, rules: rules} = context) do
    case Enum.find(rules, &Rule.match?(&1, text)) do
      %Rule{} = rule ->
        route = Support.route_from_rule(rule, :regex, text, labels)
        Support.log_route(:info, "regex_accept", route, context.opts)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:regex_accept, route})
         |> Context.halt()}

      nil ->
        {:cont, Context.put_trace(context, :regex_skip)}
    end
  end
end
