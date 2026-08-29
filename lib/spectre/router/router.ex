defmodule Spectre.Router do
  @moduledoc """
  Routes inbound input to a compiled Spectre rule.

  Routing is evidence-first. Each configured strategy can add candidates to a
  `%Spectre.Router.Context{}`; arbitration later decides which candidate becomes
  the route. This keeps deterministic matches, trained classifiers, semantic
  cache hits, and LLM fallback from overwriting each other prematurely.
  """

  alias Spectre.Flow.Constraint
  alias Spectre.Input
  alias Spectre.Journal.Recorder
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Route
  alias Spectre.Router.Adapter
  alias Spectre.Router.Adapter.Compiler, as: AdapterCompiler
  alias Spectre.Router.Adapter.Plan, as: AdapterPlan
  alias Spectre.Router.Context
  alias Spectre.Router.Evaluator
  alias Spectre.Router.Receipt
  alias Spectre.Router.Support
  alias Spectre.Rule
  alias Spectre.State

  @doc """
  Evaluates routing without executing a handler, action, or state adapter.

  Evaluation runs the real input and router pipelines but disables journal
  delivery and online semantic learning. The returned receipt contains no raw
  input, prompt, model output, matches, or handlers.

      {:ok, receipt} = Spectre.Router.evaluate(MyAgent, "help")
  """
  @spec evaluate(module(), Input.t() | String.t() | map(), keyword()) :: {:ok, Receipt.t()}
  def evaluate(agent, input, opts \\ []), do: Evaluator.evaluate(agent, input, opts)

  @doc """
  Routes input to the best matching compiled agent rule.

      {:ok, route} = Spectre.Router.route(input, ctx)
  """
  @spec route(Input.t(), Spectre.Context.t()) :: {:ok, Route.t()} | {:error, term()}
  def route(%Input{} = input, %{agent: _agent, state: %State{}} = ctx) do
    with {:ok, %Context{} = context} <- route_context(input, ctx) do
      route_from_context(context)
    end
  end

  @doc """
  Runs the router pipeline and returns the full routing context.

  This is useful for runtimes that need enriched input fields produced by
  router plugs.

      {:ok, router_context} = Spectre.Router.route_context(input, ctx)
  """
  @spec route_context(Input.t(), Spectre.Context.t()) ::
          {:ok, Context.t()}
          | {:inference, Spectre.Inference.Prepared.t()}
          | {:error, term()}
  def route_context(%Input{} = input, %{agent: agent, state: %State{} = state, opts: opts} = ctx) do
    rules =
      agent
      |> candidate_rules(state)
      |> maybe_interrupt_rules(opts)
      |> Constraint.filter_and_order(input)

    labels = Enum.map(rules, & &1.label)

    compiled_router = agent.__spectre_router__()
    compiled_adapters = AdapterCompiler.compiled_adapters(compiled_router)

    merged_opts =
      compiled_router
      |> Keyword.merge(opts)
      |> Keyword.put_new(:arbitrator, {Spectre.Router.Arbitrators.Default, []})
      |> Keyword.put_new(:labels, labels)
      |> Keyword.put_new(:spectre_agent, agent)
      |> Keyword.put_new(:spectre_rules, rules)

    with {:ok, router_opts, diagnostics} <-
           put_adapter_plan(merged_opts, compiled_adapters) do
      context = %Context{
        input: input,
        host_context: Map.from_struct(ctx),
        opts: router_opts,
        labels: labels,
        rules: rules,
        traces: Enum.reverse(diagnostics),
        errors: diagnostics
      }

      case route_with_pipeline(context, pipeline(router_opts, rules)) do
        {:ok, %Context{} = context} -> Recorder.record_routing(context)
        {:inference, %Spectre.Inference.Prepared{} = prepared} -> {:inference, prepared}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec put_adapter_plan(keyword(), map()) :: {:ok, keyword(), [term()]} | {:error, term()}
  defp put_adapter_plan(opts, compiled_adapters) when map_size(compiled_adapters) == 0,
    do: {:ok, Keyword.delete(opts, AdapterCompiler.compiled_key()), []}

  defp put_adapter_plan(opts, compiled_adapters) do
    with {:ok, plan} <- AdapterPlan.build(compiled_adapters, opts) do
      {:ok, Keyword.put(opts, AdapterCompiler.compiled_key(), plan),
       AdapterPlan.diagnostics(plan)}
    end
  end

  defp maybe_interrupt_rules(rules, opts) do
    if Keyword.get(opts, :policy_interrupt_only?, false) do
      Enum.filter(rules, & &1.global?)
    else
      rules
    end
  end

  @doc """
  Converts a completed router context into the selected route.

      {:ok, route} = Spectre.Router.route_from_context(router_context)
  """
  @spec route_from_context(Context.t()) :: {:ok, Route.t()} | {:error, term()}
  def route_from_context(%Context{} = context) do
    route_result({:ok, context}, context.input, context.rules)
  end

  @doc """
  Returns interrupt, current-flow, and fallback rules in evaluation order.

  Interrupts are first so global commands like cancel/help remain responsive.
  Current-flow rules come next to make multi-turn flows stable. Remaining rules
  are kept as fallback candidates so users can still change topic.

  Flows nest, so `current_flow` matches any rule whose `flow_path` contains the
  flow name: setting `current_flow: :checkout` prioritizes rules declared in
  `:checkout` and in every flow nested below it.
  """
  @spec candidate_rules(module(), State.t()) :: [Rule.t()]
  def candidate_rules(agent, %State{current_flow: current_flow, current_scope: current_scope}) do
    rules = agent |> Spectre.Definition.rules() |> Enum.map(&Rule.new/1)

    {interrupts, normal} = Enum.split_with(rules, & &1.global?)

    current =
      if current_flow do
        Enum.filter(normal, fn rule ->
          current_flow in rule.flow_path and
            (is_nil(current_scope) or rule.scope == current_scope)
        end)
      else
        []
      end

    current_ids = MapSet.new(current, &{&1.scope, &1.flow, &1.label})
    rest = Enum.reject(normal, &MapSet.member?(current_ids, {&1.scope, &1.flow, &1.label}))
    interrupts ++ current ++ rest
  end

  @spec route_with_pipeline(Context.t(), module() | [Spectre.Pipeline.plug_spec()] | nil) ::
          {:ok, Context.t()}
          | {:inference, Spectre.Inference.Prepared.t()}
          | {:error, term()}
  defp route_with_pipeline(%Context{} = context, nil), do: {:ok, context}

  defp route_with_pipeline(%Context{} = context, {:mixed, steps}) when is_list(steps) do
    protected_pipeline(context, fn -> run_mixed_pipeline(context, steps) end)
  end

  defp route_with_pipeline(%Context{} = context, pipeline) when is_atom(pipeline) do
    protected_pipeline(context, fn -> pipeline.call(context) end)
  end

  defp route_with_pipeline(%Context{} = context, pipeline) when is_list(pipeline) do
    protected_pipeline(context, fn ->
      with {:ok, specs} <- Spectre.Pipeline.init_specs(pipeline) do
        Spectre.Pipeline.run(context, specs)
      end
    end)
  end

  @spec run_mixed_pipeline(Context.t(), [term()]) ::
          {:ok, Context.t()}
          | {:inference, Spectre.Inference.Prepared.t()}
          | {:error, term()}
  defp run_mixed_pipeline(%Context{} = context, steps) do
    Enum.reduce_while(steps, {:ok, context}, fn step, {:ok, context} ->
      step
      |> run_mixed_step(context)
      |> reduce_mixed_reply()
    end)
  end

  @spec run_mixed_step(term(), Context.t()) ::
          {:ok, Context.t()}
          | {:inference, Spectre.Inference.Prepared.t()}
          | {:error, term()}
  defp run_mixed_step({:plug, spec}, context), do: Spectre.Pipeline.run(context, [spec])

  defp run_mixed_step({:adapter, adapter_id}, context) do
    case Adapter.run(context, adapter_id) do
      {:cont, %Context{} = context} -> {:ok, context}
      {:error, _reason} = error -> error
    end
  end

  @spec reduce_mixed_reply(term()) :: {:cont, term()} | {:halt, term()}
  defp reduce_mixed_reply({:ok, %Context{halted?: true}} = result), do: {:halt, result}
  defp reduce_mixed_reply({:ok, %Context{}} = result), do: {:cont, result}

  defp reduce_mixed_reply({:inference, %Spectre.Inference.Prepared{}} = result),
    do: {:halt, result}

  defp reduce_mixed_reply({:error, _reason} = error), do: {:halt, error}

  @spec protected_pipeline(Context.t(), (-> term())) ::
          {:ok, Context.t()}
          | {:inference, Spectre.Inference.Prepared.t()}
          | {:error, term()}
  defp protected_pipeline(%Context{} = context, callback) do
    result =
      Call.run(
        :router,
        fn -> callback.() |> normalize_pipeline_reply() end,
        context.opts |> Call.adapter_opts() |> Keyword.put(:purpose, :router_pipeline)
      )

    case result do
      {:ok, {:inference, %Spectre.Inference.Prepared{} = prepared}} ->
        {:inference, prepared}

      other ->
        other
    end
  end

  @spec normalize_pipeline_reply(term()) :: {:ok, Context.t()} | {:error, term()}
  defp normalize_pipeline_reply({:ok, %Context{}} = result), do: result

  defp normalize_pipeline_reply({:inference, %Spectre.Inference.Prepared{} = prepared}),
    do: {:ok, {:inference, prepared}}

  defp normalize_pipeline_reply({:error, _reason} = error), do: error

  defp normalize_pipeline_reply(other),
    do: {:error, Failure.invalid_reply(:router, other)}

  @spec pipeline(keyword(), [Rule.t()]) ::
          module() | [Spectre.Pipeline.plug_spec()] | {:mixed, [term()]}
  defp pipeline(opts, rules) do
    case Keyword.get(opts, :pipeline) do
      nil -> generated_pipeline(default_via(opts, rules), opts)
      pipeline -> pipeline
    end
  end

  @spec generated_pipeline([atom()], keyword()) ::
          [Spectre.Pipeline.plug_spec()] | {:mixed, [term()]}
  defp generated_pipeline(via, opts) do
    plan = Keyword.get(opts, AdapterCompiler.compiled_key())

    if AdapterPlan.adapter_plan?(plan) and
         Enum.any?(via, &match?({:ok, _}, AdapterPlan.fetch(plan, &1))) do
      {:mixed, mixed_pipeline_from_via(via, plan)}
    else
      pipeline_from_via(via)
    end
  end

  @spec default_via(keyword(), [Rule.t()]) :: [atom()]
  defp default_via(opts, rules) do
    via = Keyword.get(opts, :via, [:regex])

    if cacheable_rules?(rules) and Keyword.get(opts, :semantic_cache?, true) do
      via |> List.wrap() |> Kernel.++([:semantic_cache]) |> Enum.uniq()
    else
      List.wrap(via)
    end
  end

  @spec cacheable_rules?([Rule.t()]) :: boolean()
  defp cacheable_rules?(rules), do: Enum.any?(rules, & &1.cache)

  @spec pipeline_from_via([atom()] | atom()) :: [module()]
  defp pipeline_from_via(via) do
    via
    |> List.wrap()
    |> Enum.flat_map(&pipeline_step/1)
    |> append_terminalize()
  end

  @spec mixed_pipeline_from_via([atom()], AdapterPlan.t()) :: [term()]
  defp mixed_pipeline_from_via(via, plan) do
    via
    |> Enum.flat_map(fn step ->
      case AdapterPlan.fetch(plan, step) do
        {:ok, _entry} -> [{:adapter, step}]
        :error -> Enum.map(pipeline_step(step), &{:plug, &1})
      end
    end)
    |> append_mixed_terminalize()
  end

  @spec append_mixed_terminalize([term()]) :: [term()]
  defp append_mixed_terminalize(steps) do
    steps = append_mixed_plug(steps, Spectre.Router.Plugs.Arbitrate)
    append_mixed_plug(steps, Spectre.Router.Plugs.Terminalize)
  end

  @spec append_mixed_plug([term()], module()) :: [term()]
  defp append_mixed_plug(steps, plug) do
    if {:plug, plug} in steps, do: steps, else: steps ++ [{:plug, plug}]
  end

  @spec pipeline_step(atom()) :: [module()]
  defp pipeline_step(:regex), do: [Spectre.Router.Plugs.Regex]
  defp pipeline_step(:bag), do: [Spectre.Router.Plugs.BagDistance]
  defp pipeline_step(:jaro), do: [Spectre.Router.Plugs.JaroDistance]
  defp pipeline_step(:embedding), do: [Spectre.Router.Plugs.EmbeddingSimilarity]

  defp pipeline_step(:semantic_cache),
    do: [Spectre.Router.Plugs.SemanticCacheExact, Spectre.Router.Plugs.SemanticCacheSearch]

  defp pipeline_step(:classifier), do: [Spectre.Router.Plugs.LocalClassifier]
  defp pipeline_step(:llm), do: []
  defp pipeline_step(:llm_classifier), do: []
  defp pipeline_step(:arbitrate), do: [Spectre.Router.Plugs.Arbitrate]
  defp pipeline_step(:terminalize), do: [Spectre.Router.Plugs.Terminalize]
  defp pipeline_step(_unknown), do: []

  @spec append_terminalize([module()]) :: [module()]
  defp append_terminalize(pipeline) do
    pipeline = append_arbitrate(pipeline)

    if Spectre.Router.Plugs.Terminalize in pipeline do
      pipeline
    else
      pipeline ++ [Spectre.Router.Plugs.Terminalize]
    end
  end

  defp append_arbitrate(pipeline) do
    if Spectre.Router.Plugs.Arbitrate in pipeline do
      pipeline
    else
      pipeline ++ [Spectre.Router.Plugs.Arbitrate]
    end
  end

  @spec route_result({:ok, Context.t()} | {:error, term()}, Input.t(), [Rule.t()]) ::
          {:ok, Route.t()} | {:error, term()}
  defp route_result({:ok, %Context{route: %Route{} = route}}, _input, _rules), do: {:ok, route}

  defp route_result({:ok, %Context{}}, %Input{text: text} = input, rules) do
    regex_rules = Support.rules_for(rules, :regex, input)

    case Enum.find(regex_rules, &Rule.match?(&1, text)) do
      %Rule{} = rule ->
        {:ok, Route.from_rule(rule, :regex, text)}

      nil ->
        # Returning an explicit unknown route keeps callers on the normal
        # `{:ok, route}` path while preserving the full label set for
        # clarification prompts and telemetry.
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
