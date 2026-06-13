defmodule Spectre.Router.Plugs.Regex do
  @moduledoc """
  Deterministic regex evidence provider for the router pipeline.

  Regex rules are treated as hard evidence because they are explicit agent
  declarations. The plug records a candidate instead of immediately returning a
  route so the arbitrator can still compare regex evidence with global
  interrupts, semantic cache hits, classifier results, or custom providers.

  Example DSL:

      flow :support do
        on :cancel, regex: ~r/^cancel$/i do
          run :cancel_current
        end
      end
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.Support
  alias Spectre.Rule

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
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
