defmodule Spectre.Server.Router do
  @moduledoc """
  Routing bridge for `Spectre.Server`.

  The existing evidence pipeline still owns strategy execution, thresholds,
  visibility and arbitration. The bridge converts its result into a Server
  dispatch key while retaining the complete routing explanation. Call it from
  a worker: classifiers and embedding adapters may perform I/O.
  """

  alias Spectre.Context
  alias Spectre.Flow.Port
  alias Spectre.Input
  alias Spectre.Input.Pipeline, as: InputPipeline
  alias Spectre.Route
  alias Spectre.Router
  alias Spectre.Router.Context, as: RoutingContext
  alias Spectre.State

  @normal_skips [
    :miss,
    :not_found,
    :empty_learned_semantic_cache,
    :below_threshold,
    :semantic_cache_not_accepted,
    :semantic_cache_disabled,
    :semantic_cache_embeddings_not_loaded,
    :intent_exact_disabled,
    :hard_candidate,
    :exact_cache_hit,
    :no_visible_rules,
    :no_llm_visible_rules,
    :label_not_routeable
  ]

  @type result ::
          {:ok, {term(), atom()}, map()} | {:unmatched, map()} | {:error, term()}

  @doc "Runs the Agent's input pipeline once, before pending or routing dispatch."
  @spec prepare_input(module(), term(), keyword()) :: {:ok, Input.t()} | {:error, term()}
  def prepare_input(agent, input, opts \\ []) do
    input = Input.new(input)
    opts = Keyword.merge(agent.__spectre_config__(), opts)

    with :ok <- Input.validate(input) do
      InputPipeline.run(
        input,
        %{agent: agent, opts: opts},
        Keyword.get(opts, :input_pipeline, [])
      )
    end
  end

  @doc "Routes a prepared input without running the input pipeline a second time."
  @spec route(module(), Input.t() | String.t() | map(), keyword()) :: result()
  def route(agent, input, opts \\ []) when is_atom(agent) and is_list(opts) do
    input = Input.new(input)

    # The Server owns the lifecycle. Running the cognitive pipeline in its worker
    # uses the synchronous legacy boundary rather than starting a second owner.
    opts =
      agent.__spectre_config__()
      |> Keyword.merge(opts)
      |> Keyword.put(:instance_run_lifecycle?, false)
      |> Keyword.put_new(
        :regex_strength,
        Keyword.get(agent.__spectre_router__(), :regex_strength, :hard)
      )

    state = %State{
      current_flow: Keyword.get(opts, :current_flow),
      current_scope: Keyword.get(opts, :current_scope),
      data: Keyword.get(opts, :state_data, %{})
    }

    context = %Context{
      agent: agent,
      input: input,
      state: state,
      assigns: Keyword.get(opts, :assigns, %{}),
      opts: opts
    }

    with :ok <- Input.validate(input),
         {:ok, %RoutingContext{} = routing} <- Router.route_context(input, context),
         {:ok, %Route{} = route} <- Router.route_from_context(routing) do
      metadata = metadata(route, routing)

      if route.handler do
        {:ok, dispatch_key(route), metadata}
      else
        {:unmatched, Map.put(metadata, :reason, unmatched_reason(route, routing))}
      end
    end
  end

  @doc "Converts a route to a callback key without dropping nested or Skill scope."
  @spec dispatch_key(Route.t()) :: {term(), atom()}
  def dispatch_key(%Route{rule: rule, flow: flow, scope: scope, label: label}) do
    path = if rule, do: rule.flow_path, else: List.wrap(flow)

    flow =
      case path do
        [name] -> name
        [] -> nil
        nested -> nested
      end

    case scope do
      :agent -> {flow, label}
      nil -> {flow, label}
      mounted -> {{mounted, flow}, label}
    end
  end

  defp metadata(route, routing) do
    metadata = %{
      reason: nil,
      route: route,
      input: routing.input,
      scope: route.scope,
      protected: route.rule != nil and Keyword.get(route.rule.opts, :protected, false),
      arbitration: routing.arbitration,
      candidates: Enum.reverse(routing.candidates),
      traces: Enum.reverse(routing.traces),
      errors: Enum.reverse(routing.errors)
    }

    if Port.owner(route),
      do: Map.put(metadata, :params, params(route, routing.input)),
      else: metadata
  end

  defp params(%Route{strategy: :regex, rule: %{regex: regexes}}, %Input{text: text}) do
    Enum.find_value(regexes, %{}, &Regex.named_captures(&1, text))
  end

  defp params(_route, _input), do: %{}

  defp unmatched_reason(route, routing) do
    if classification_completed?(routing.traces) do
      fallback_reason(routing)
    else
      case recognition_error(route, routing) do
        nil -> fallback_reason(routing)
        error -> {:classifier_error, error}
      end
    end
  end

  defp classification_completed?(traces) do
    Enum.any?(traces, fn
      {kind, _}
      when kind in [:llm_arbitrated, :llm_rearbitration_clarified, :llm_rearbitration_unresolved] ->
        true

      _ ->
        false
    end)
  end

  defp recognition_error(%Route{fallback_error: error}, _routing) when not is_nil(error),
    do: error

  defp recognition_error(_route, routing) do
    Enum.find_value(routing.errors, &declared_error/1) || trace_error(routing.traces)
  end

  defp declared_error({:error, reason}), do: reason
  defp declared_error(%Spectre.Provider.Failure{} = error), do: error
  defp declared_error(%{status: :error, reason: reason}), do: reason
  defp declared_error(_), do: nil

  defp trace_error(traces) do
    Enum.find_value(traces, fn
      {kind, error} when kind in [:local_error, :llm_arbitration_failed] ->
        error

      {kind, reason} when kind in [:embedding_skip, :cache_skip, :semantic_skip] ->
        skip_error(reason)

      _ ->
        nil
    end)
  end

  defp skip_error(reason) when reason in @normal_skips, do: nil
  defp skip_error({:ambiguous_scoped_labels, _, _}), do: nil
  defp skip_error({:error, reason}), do: reason
  defp skip_error(reason), do: reason

  defp fallback_reason(routing) do
    scoped_ambiguity? =
      Enum.any?(routing.traces, &match?({:ambiguous_scoped_labels, _, [_ | _]}, &1))

    if scoped_ambiguity? or ambiguous?(routing), do: :ambiguous, else: :no_match
  end

  defp ambiguous?(%RoutingContext{route: %Route{strategy: :clarify}, candidates: [_ | _]}),
    do: true

  defp ambiguous?(%RoutingContext{candidates: candidates}) do
    candidates
    |> Enum.filter(&(&1.accepted? == true))
    |> Enum.map(&{&1.scope, &1.label})
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end
end
