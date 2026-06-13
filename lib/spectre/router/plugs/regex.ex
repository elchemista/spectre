defmodule Spectre.Router.Plugs.Regex do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.{Candidate, Context}
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
    visible_rules = Support.rules_for(rules, :regex, context.input)

    case Enum.find(visible_rules, &Rule.match?(&1, text)) do
      %Rule{} = rule ->
        route = Support.route_from_rule(rule, :regex, text, labels)
        Support.log_route(:info, "regex_accept", route, context.opts)

        {:cont,
         context
         |> Context.add_candidate(Candidate.from_rule(rule, :regex, text))
         |> Context.put_trace({:regex_accept, route})}

      nil ->
        {:cont, Context.put_trace(context, :regex_skip)}
    end
  end
end
