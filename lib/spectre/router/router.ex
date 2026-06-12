defmodule Spectre.Router do
  @moduledoc """
  Routes inbound input to a compiled Spectre rule.
  """

  alias Spectre.{Input, Route, Rule, State}
  alias Spectre.Router.Context

  @doc """
  Routes input to the best matching compiled agent rule.
  """
  @spec route(Input.t(), Spectre.Context.t()) :: {:ok, Route.t()} | {:error, term()}
  def route(%Input{} = input, %{agent: agent, state: %State{} = state, opts: opts} = ctx) do
    rules = candidate_rules(agent, state)
    labels = Enum.map(rules, & &1.label)

    router_opts =
      agent.__spectre_router__()
      |> Keyword.merge(opts)
      |> Keyword.put_new(:labels, labels)

    context = %Context{
      input: input,
      host_context: Map.from_struct(ctx),
      opts: router_opts,
      labels: labels,
      rules: rules
    }

    context
    |> route_with_pipeline(pipeline(router_opts))
    |> route_result(input, rules)
  end

  @doc """
  Returns interrupt, current-flow, and fallback rules in evaluation order.
  """
  @spec candidate_rules(module(), State.t()) :: [Rule.t()]
  def candidate_rules(agent, %State{current_flow: current_flow}) do
    rules = Enum.map(agent.__spectre_rules__(), &Rule.new/1)

    {interrupts, normal} = Enum.split_with(rules, & &1.global?)

    current =
      if current_flow do
        Enum.filter(normal, &(&1.flow == current_flow))
      else
        []
      end

    rest = Enum.reject(normal, &(&1.flow == current_flow))
    interrupts ++ current ++ rest
  end

  @spec route_with_pipeline(Context.t(), module() | [Spectre.Pipeline.plug_spec()] | nil) ::
          {:ok, Context.t()} | {:error, term()}
  defp route_with_pipeline(%Context{} = context, nil), do: {:ok, context}

  defp route_with_pipeline(%Context{} = context, pipeline) when is_atom(pipeline) do
    pipeline.call(context)
  end

  defp route_with_pipeline(%Context{} = context, pipeline) when is_list(pipeline) do
    with {:ok, specs} <- Spectre.Pipeline.init_specs(pipeline) do
      Spectre.Pipeline.run(context, specs)
    end
  end

  @spec pipeline(keyword()) :: module() | [Spectre.Pipeline.plug_spec()]
  defp pipeline(opts) do
    case Keyword.get(opts, :pipeline) do
      nil -> pipeline_from_via(Keyword.get(opts, :via, [:regex]))
      pipeline -> pipeline
    end
  end

  @spec pipeline_from_via([atom()] | atom()) :: [module()]
  defp pipeline_from_via(via) do
    via
    |> List.wrap()
    |> Enum.flat_map(&pipeline_step/1)
    |> append_terminalize()
  end

  @spec pipeline_step(atom()) :: [module()]
  defp pipeline_step(:regex), do: [Spectre.Router.Plugs.Regex]

  defp pipeline_step(:semantic_cache),
    do: [Spectre.Router.Plugs.SemanticCacheExact, Spectre.Router.Plugs.SemanticCacheSearch]

  defp pipeline_step(:classifier), do: [Spectre.Router.Plugs.LocalClassifier]
  defp pipeline_step(:llm), do: [Spectre.Router.Plugs.LLMFallback]
  defp pipeline_step(:terminalize), do: [Spectre.Router.Plugs.Terminalize]
  defp pipeline_step(_unknown), do: []

  @spec append_terminalize([module()]) :: [module()]
  defp append_terminalize(pipeline) do
    if Spectre.Router.Plugs.Terminalize in pipeline do
      pipeline
    else
      pipeline ++ [Spectre.Router.Plugs.Terminalize]
    end
  end

  @spec route_result({:ok, Context.t()} | {:error, term()}, Input.t(), [Rule.t()]) ::
          {:ok, Route.t()} | {:error, term()}
  defp route_result({:error, reason}, _input, _rules), do: {:error, reason}
  defp route_result({:ok, %Context{route: %Route{} = route}}, _input, _rules), do: {:ok, route}

  defp route_result({:ok, %Context{}}, %Input{text: text}, rules) do
    case Enum.find(rules, &Rule.match?(&1, text)) do
      %Rule{} = rule ->
        {:ok, Route.from_rule(rule, :regex, text)}

      nil ->
        {:ok,
         Route.new(%{
           label: :unknown,
           strategy: :unknown,
           accepted?: false,
           raw: text,
           labels: Enum.map(rules, & &1.label)
         })}
    end
  end
end
