defmodule Spectre.Agent.Classification do
  @moduledoc """
  Router bridge for a classification already observed through governed execution.

  An ordinary input has no classification: evaluate/2 returns :skip. Only
  route_result/2 binds a confirmed, correlated result into a temporary matcher.
  No model call, download, retry or provider selection occurs in this module.
  """
  use Spectre.Router.Adapter
  alias Spectre.Agent.Turn
  alias Spectre.Router

  @impl true
  def evaluate(request, opts) do
    case Keyword.fetch(opts, :observed) do
      :error -> :skip
      {:ok, labels} -> nominations(labels, Enum.map(request.rules, & &1.ref))
    end
  end

  @doc false
  @spec prepare(map(), Turn.t(), atom(), term()) :: {:ok, map()} | {:error, term()}
  def prepare(
        owner,
        %Turn{routing: %{declaration: %{binding: %{classifier: name}}}} = turn,
        name,
        input
      ) do
    configuration = Map.get(owner.plan.settings, "classifier/" <> to_string(name), %{})

    {:ok,
     %{
       "input" => input,
       "labels" => turn.routing |> rules() |> Map.keys() |> Enum.sort(),
       "configuration" => Map.drop(configuration, [:class]),
       "turn_ref" => turn.ref,
       "definition_ref" => turn.definition_ref
     }}
  end

  def prepare(_owner, _turn, _name, _input), do: {:error, :classifier_flow_binding_mismatch}

  @doc "Returns a message only for allowed labels of this exact completed classifier request."
  def route_result(turn, result) do
    with {:ok, selection} <- select(turn, result) do
      flow = turn.routing.declaration
      {:ok, {flow.local, flow.routes[selection.candidate].local, selection.matched || %{}}}
    end
  end

  @doc false
  def select(
        %Turn{routing: %{declaration: flow}} = turn,
        %{status: :done, turn_ref: ref, operation: {:classify, _}, data: %{"labels" => labels}} =
          result
      )
      when ref === turn.ref and result === turn.result do
    config = flow.routing || %{"accept" => 0.85, "margin" => 0.0}

    with {:ok, router} <-
           Router.new(rules(turn.routing),
             via: [:llm_classifier],
             accept: config["accept"],
             margin: config["margin"],
             adapters: [llm_classifier: {__MODULE__, observed: labels}]
           ) do
      Router.route(router, nil)
    end
  end

  def select(_turn, _result), do: {:error, :classifier_result_binding_mismatch}

  # The request's allowed labels and the observed result use the same subset.
  # Preparing a request cannot quietly admit a route excluded during routing.
  defp rules(%{name: flow_name, declaration: flow}) do
    for {name, route} <- flow.routes,
        route.rule["match"]["llm_classifier"] === true,
        into: %{},
        do:
          {Spectre.Agent.Publication.rule_ref(flow_name, name),
           %{to: name, match: %{llm_classifier: true}}}
  end

  defp nominations(labels, allowed) when is_list(labels) and length(labels) <= 32 do
    Enum.reduce_while(labels, {:ok, [], MapSet.new()}, fn value, {:ok, found, seen} ->
      with %{"label" => label, "score" => score} when map_size(value) == 2 <- value,
           true <- label in allowed and is_number(score) and score >= 0 and score <= 1,
           false <- MapSet.member?(seen, label) do
        {:cont, {:ok, [result(label, score) | found], MapSet.put(seen, label)}}
      else
        _invalid -> {:halt, {:error, :invalid_classifier_nomination}}
      end
    end)
    |> case do
      {:ok, found, _seen} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  defp nominations(_labels, _allowed), do: {:error, :invalid_classifier_nominations}
end
