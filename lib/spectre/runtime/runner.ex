defmodule Spectre.Runner do
  @moduledoc """
  Executes routed handlers without crossing action boundaries accidentally.

  The runner translates a selected route into a result, but protected side
  effects remain staged until a policy approves them. This is the main safety
  boundary in Spectre: prompts may propose actions, and deterministic DSL routes
  may stage actions, but execution is separate.
  """

  alias Spectre.ActionConfig
  alias Spectre.ActionPlanner
  alias Spectre.ActionProtection
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Prompt
  alias Spectre.Prompt.Plan
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.Route

  @doc """
  Runs the handler selected by a route.

      {:ok, result} = Spectre.Runner.run(route, ctx)
  """
  @spec run(Route.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%Route{handler: {:ask, prompt, handler_opts}} = route, ctx) do
    ctx = %{ctx | route: route}
    ask(prompt, ctx.input, ctx, handler_opts)
  end

  def run(%Route{handler: {:run, function, handler_opts}} = route, ctx) do
    ctx = %{ctx | route: route, opts: Keyword.merge(ctx.opts, handler_opts)}
    run_function(function, ctx.input, ctx)
  end

  def run(%Route{handler: {:reply, prompt, handler_opts}} = route, ctx) do
    ctx = %{ctx | route: route}
    reply(prompt, ctx.input, ctx, handler_opts)
  end

  def run(%Route{handler: {:action, action, handler_opts}} = route, ctx) do
    ctx = %{ctx | route: route}
    action(action, ctx.input, ctx, handler_opts)
  end

  def run(%Route{} = route, ctx) do
    {:ok,
     %Result{
       input: ctx.input,
       route: route,
       state: ctx.state,
       events: [%{type: :unhandled_route}]
     }}
  end

  @doc """
  Renders a prompt, calls the LLM, cleans visible replies, and stages AL actions.

      {:ok, result} = Spectre.Runner.ask(:support_answer, input, ctx)

  Policy prompts use the same rendering/LLM path but skip action planning so a
  confirmation question cannot accidentally stage another action.
  """
  @spec ask(atom() | String.t(), Input.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def ask(prompt, %Input{} = input, ctx, opts \\ []) do
    ctx = normalize_ctx(ctx, input, [])
    prompt_opts = merge_prompt_opts(ctx.opts, opts)
    ctx = %{ctx | opts: prompt_opts}

    with {:ok, %Plan{} = plan} <-
           Prompt.build(ctx.agent, prompt, ctx, prompt_opts),
         {:ok, reply} <- Spectre.LLM.complete(plan, prompt_opts),
         :ok <- validate_model_reply_size(reply, prompt_opts),
         {:ok, %Result{} = result} <-
           ask_result(reply, input, ctx, prompt_opts, Keyword.get(opts, :policy_prompt?)) do
      {:ok, put_prompt_metadata(result, plan)}
    end
  end

  @spec ask_result(String.t(), Input.t(), Spectre.Context.t(), keyword(), boolean() | nil) ::
          {:ok, Result.t()} | {:error, term()}
  defp ask_result(reply, input, ctx, _opts, true) do
    {:ok,
     %Result{
       input: input,
       route: ctx.route,
       state: ctx.state,
       reply_text: ActionPlanner.clean_reply(reply)
     }}
  end

  defp ask_result(reply, input, ctx, opts, _policy_prompt?),
    do: plan_reply(reply, input, ctx, opts)

  @spec put_prompt_metadata(Result.t(), Plan.t()) :: Result.t()
  defp put_prompt_metadata(%Result{} = result, %Plan{} = plan) do
    metadata = Map.put(result.metadata, :prompt_plan, Plan.metadata(plan))
    %{result | metadata: metadata}
  end

  @doc """
  Calls an agent-local function declared through a `run` handler.

      {:ok, result} = Spectre.Runner.run_function(:prepare_case, input, ctx)
  """
  @spec run_function(atom(), Input.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_function(function, %Input{} = input, ctx) when is_atom(function) do
    ctx = normalize_ctx(ctx, input, [])

    owner =
      Keyword.get(ctx.opts, :handler_owner) ||
        (match?(%Route{}, ctx.route) && ctx.route.owner) || ctx.agent

    call_run_function(owner, function, input, ctx)
  end

  @spec call_run_function(module(), atom(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp call_run_function(owner, function, input, ctx) do
    cond do
      function_exported?(owner, function, 2) ->
        protected_run(fn -> apply(owner, function, [input, ctx]) end, input, ctx)

      function_exported?(owner, function, 1) ->
        protected_run(fn -> apply(owner, function, [input]) end, input, ctx)

      true ->
        {:error, {:undefined_run_function, owner, function}}
    end
  end

  @spec protected_run((-> term()), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp protected_run(callback, input, ctx) do
    Call.run(
      :run,
      fn -> callback.() |> normalize_function_result(input, ctx) end,
      ctx.opts |> Call.adapter_opts() |> Keyword.put(:purpose, :run_handler)
    )
  end

  @doc """
  Renders a no-LLM reply handler.

  By default `reply :some_prompt` renders a prompt file under the agent prompt
  root. A host application may instead pass `renderer: {Module, :function}`.
  Renderer callbacks can use arity 3 (`prompt, input, ctx`), arity 2
  (`prompt, assigns`), or arity 1 (`assigns`).

      reply :fallback, renderer: {MyApp.Replies, :render}
  """
  @spec reply(atom() | String.t(), Input.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def reply(prompt, %Input{} = input, ctx, opts \\ []) do
    ctx = normalize_ctx(ctx, input, [])
    prompt_opts = merge_prompt_opts(ctx.opts, opts)
    ctx = %{ctx | opts: prompt_opts}

    with {:ok, text} <- render_reply(prompt, input, ctx, prompt_opts) do
      {:ok, %Result{input: input, route: ctx.route, state: ctx.state, reply_text: text}}
    end
  end

  @doc """
  Handles a deterministic action without calling the LLM.

  If the action is protected, Spectre stores it as a pending action effect and
  opens the configured policy awaitable. Pass `reply:` plus normal `reply` renderer options to
  use a no-LLM confirmation message; otherwise Spectre renders the policy
  request prompt through the normal `ask` path.

      {:ok, result} = Spectre.Runner.action(:delete_account, input, ctx)
  """
  @spec action(atom(), Input.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def action(action, %Input{} = input, ctx, opts \\ []) when is_atom(action) do
    ctx = normalize_ctx(ctx, input, [])
    ctx = %{ctx | opts: merge_prompt_opts(ctx.opts, opts)}

    effect =
      Effect.stage(%{
        name: action,
        args: Keyword.get(opts, :args, %{}),
        mode: Keyword.get(opts, :mode),
        status: Keyword.get(opts, :status, :pending),
        payload: %{
          al: Keyword.get(opts, :al),
          hooks: Keyword.get(opts, :hooks, []),
          source: :dsl,
          scope: route_scope(ctx)
        }
      })

    with :ok <- ensure_no_pending_effect(ctx.state) do
      policy =
        Keyword.get(opts, :policy) ||
          ActionProtection.protected_by(ctx.agent, effect, route_scope(ctx))

      state = Spectre.State.put_pending_effect(ctx.state, effect, policy)
      ctx = %{ctx | state: state}
      # Read the effect back from state so policy metadata/status added by
      # `State.put_pending_effect/3` is reflected in the result effects list.
      effects = [pending_effect(state)]

      cond do
        policy && Keyword.has_key?(opts, :reply) ->
          reply_staged_policy(policy, effects, input, ctx, opts)

        policy ->
          request_policy(policy, "", effects, input, ctx, opts)

        true ->
          {:ok,
           %Result{
             input: input,
             route: ctx.route,
             state: state,
             effects: effects,
             events: [%{type: :effect_staged, kind: :action, name: effect.name}]
           }}
      end
    end
  end

  @spec plan_reply(String.t(), Input.t(), Spectre.Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  defp plan_reply(reply, input, ctx, opts) do
    with {:ok, %{reply_text: reply_text, effects: effects}} <-
           ActionPlanner.plan_response(reply, ActionConfig.planner_opts(ctx, opts)) do
      stage_effects(reply_text, effects, input, ctx, opts)
    end
  end

  @spec stage_effects(
          String.t(),
          [Effect.t()],
          Input.t(),
          Spectre.Context.t(),
          keyword()
        ) ::
          {:ok, Result.t()} | {:error, term()}
  defp stage_effects(reply_text, [], input, ctx, _opts) do
    {:ok, %Result{input: input, route: ctx.route, state: ctx.state, reply_text: reply_text}}
  end

  defp stage_effects(reply_text, [effect], input, ctx, opts) do
    effect = put_effect_scope(effect, route_scope(ctx))

    with :ok <- ensure_no_pending_effect(ctx.state) do
      policy = ActionProtection.protected_by(ctx.agent, effect, route_scope(ctx))
      state = Spectre.State.put_pending_effect(ctx.state, effect, policy)
      ctx = %{ctx | state: state}
      staged_effect = pending_effect(state)

      if policy do
        # Protected AL actions immediately switch into the policy request flow.
        # The visible LLM reply is preserved and joined with the policy prompt.
        request_policy(policy, reply_text, [staged_effect], input, ctx, opts)
      else
        {:ok,
         %Result{
           input: input,
           route: ctx.route,
           state: state,
           reply_text: reply_text,
           effects: [staged_effect],
           events: [%{type: :effect_staged, kind: :action, name: effect.name}]
         }}
      end
    end
  end

  defp stage_effects(_reply_text, effects, _input, _ctx, _opts) when length(effects) > 1 do
    identities =
      Enum.map(effects, fn effect ->
        %{id: effect.id, kind: effect.kind, name: effect.name}
      end)

    {:error, {:multiple_action_effects_not_supported, identities}}
  end

  @spec render_reply(atom() | String.t(), Input.t(), Spectre.Context.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp render_reply(prompt, input, ctx, opts) do
    case Keyword.get(opts, :renderer) do
      nil ->
        protected_renderer(fn -> Prompt.render_asset(ctx.agent, prompt, ctx, opts) end, opts)

      {module, function} when is_atom(module) and is_atom(function) ->
        protected_renderer(
          fn -> call_reply_renderer(module, function, prompt, input, ctx, opts) end,
          opts
        )

      function when is_function(function, 3) ->
        protected_renderer(fn -> function.(prompt, input, ctx) end, opts)

      function when is_function(function, 2) ->
        protected_renderer(fn -> function.(prompt, reply_assigns(ctx, opts)) end, opts)

      function when is_function(function, 1) ->
        protected_renderer(fn -> function.(reply_assigns(ctx, opts)) end, opts)

      other ->
        {:error, {:invalid_reply_renderer, reply_shape(other)}}
    end
  end

  @spec protected_renderer((-> term()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp protected_renderer(callback, opts) do
    Call.run(
      :renderer,
      fn -> callback.() |> normalize_reply_text() end,
      opts |> Call.adapter_opts() |> Keyword.put(:purpose, :reply_renderer)
    )
  end

  @spec call_reply_renderer(module(), atom(), term(), Input.t(), Spectre.Context.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp call_reply_renderer(module, function, prompt, input, ctx, opts) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, function, 3) ->
        apply(module, function, [prompt, input, ctx])

      function_exported?(module, function, 2) ->
        apply(module, function, [prompt, reply_assigns(ctx, opts)])

      function_exported?(module, function, 1) ->
        apply(module, function, [reply_assigns(ctx, opts)])

      true ->
        {:error, {:undefined_reply_renderer, module, function}}
    end
  end

  @spec reply_assigns(Spectre.Context.t(), keyword()) :: map()
  defp reply_assigns(ctx, opts) do
    ctx
    |> Map.get(:assigns, %{})
    |> Map.merge(%{
      input: ctx.input,
      state: ctx.state,
      route: ctx.route,
      ctx: ctx,
      key: Keyword.get(opts, :key)
    })
    |> Map.merge(Map.new(Keyword.get(opts, :assigns, [])))
  end

  @spec normalize_reply_text(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_reply_text({:ok, text}) when is_binary(text), do: {:ok, text}
  defp normalize_reply_text(text) when is_binary(text), do: {:ok, text}
  defp normalize_reply_text({:error, reason}), do: {:error, reason}
  defp normalize_reply_text(other), do: {:error, Failure.invalid_reply(:renderer, other)}

  @spec reply_staged_policy(
          atom(),
          [Effect.t()],
          Input.t(),
          Spectre.Context.t(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp reply_staged_policy(policy_name, effects, input, ctx, opts) do
    with {:ok, text} <- render_reply(Keyword.fetch!(opts, :reply), input, ctx, opts) do
      {:ok,
       %Result{
         input: input,
         route: ctx.route,
         state: ctx.state,
         effects: effects,
         awaitables: ctx.state.awaitables,
         reply_text: text,
         events: [
           %{type: :awaitable_opened, kind: :policy, name: policy_name},
           %{
             type: :effect_staged,
             kind: :action,
             name: List.first(effects) && List.first(effects).name
           }
         ]
       }}
    end
  end

  @spec request_policy(
          term(),
          String.t(),
          [Effect.t()],
          Input.t(),
          Spectre.Context.t(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp request_policy(policy_name, reply_text, effects, input, ctx, opts) do
    case Spectre.Definition.policy(ctx.agent, policy_name) do
      {:error, _reason} ->
        {:error, {:unknown_policy, policy_name}}

      {:ok, %{request: request_prompt}, scope} ->
        definition = Spectre.Definition.for_scope!(ctx.agent, scope)

        with {:ok, %Result{} = request} <-
               ask(
                 request_prompt,
                 input,
                 ctx,
                 Keyword.merge(opts,
                   policy_prompt?: true,
                   policy: policy_name,
                   prompt_scope: scope,
                   prompt_owner: definition.owner
                 )
               ) do
          {:ok,
           %{
             request
             | reply_text: join_reply(reply_text, request.reply_text),
               effects: effects,
               awaitables: ctx.state.awaitables,
               events: [
                 %{type: :awaitable_opened, kind: :policy, name: policy_name},
                 %{
                   type: :effect_staged,
                   kind: :action,
                   name: List.first(effects) && List.first(effects).name
                 }
                 | request.events
               ]
           }}
        end
    end
  end

  @spec normalize_function_result(term(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp normalize_function_result({:ok, %Result{} = result}, input, ctx),
    do: {:ok, put_run_result_defaults(result, input, ctx)}

  defp normalize_function_result(%Result{} = result, input, ctx),
    do: {:ok, put_run_result_defaults(result, input, ctx)}

  defp normalize_function_result({:ok, reply}, input, ctx),
    do: normalize_run_reply(reply, input, ctx)

  defp normalize_function_result({:error, reason}, _input, _ctx), do: {:error, reason}

  defp normalize_function_result(reply, input, ctx), do: normalize_run_reply(reply, input, ctx)

  @spec normalize_run_reply(term(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, Failure.t()}
  defp normalize_run_reply(reply, input, ctx) do
    case String.Chars.impl_for(reply) do
      nil ->
        {:error, Failure.invalid_reply(:run, reply)}

      _implementation ->
        {:ok,
         %Result{input: input, route: ctx.route, state: ctx.state, reply_text: to_string(reply)}}
    end
  end

  @spec reply_shape(term()) :: term()
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_binary(value), do: :binary
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(value) when is_function(value), do: :function
  defp reply_shape(_value), do: :other

  @spec put_run_result_defaults(Result.t(), Input.t(), Spectre.Context.t()) :: Result.t()
  defp put_run_result_defaults(%Result{} = result, input, ctx) do
    %{
      result
      | input: result.input || input,
        route: result.route || ctx.route,
        state: result.state || ctx.state
    }
  end

  @spec put_effect_scope(Effect.t(), Spectre.Definition.scope()) :: Effect.t()
  defp put_effect_scope(%Effect{} = effect, scope) do
    %{effect | payload: Map.put(effect.payload, :scope, scope)}
  end

  @spec route_scope(Spectre.Context.t() | map()) :: Spectre.Definition.scope()
  defp route_scope(%{route: %Route{scope: scope}}), do: scope
  defp route_scope(_ctx), do: :agent

  @spec normalize_ctx(Spectre.Context.t() | map(), Input.t(), keyword()) :: Spectre.Context.t()
  defp normalize_ctx(%Spectre.Context{} = ctx, _input, opts),
    do: %{ctx | opts: Keyword.merge(ctx.opts, opts)}

  defp normalize_ctx(ctx, input, opts) when is_map(ctx) do
    attrs = Map.merge(ctx, %{input: input, opts: Keyword.merge(Map.get(ctx, :opts, []), opts)})
    struct(Spectre.Context, attrs)
  end

  @spec validate_model_reply_size(String.t(), keyword()) :: :ok | {:error, term()}
  defp validate_model_reply_size(reply, opts) when is_binary(reply) do
    max_bytes = Keyword.get(opts, :model_reply_max_bytes, 1_000_000)

    if is_integer(max_bytes) and max_bytes > 0 and byte_size(reply) <= max_bytes do
      :ok
    else
      {:error, {:model_reply_too_large, byte_size(reply), max_bytes}}
    end
  end

  @spec merge_prompt_opts(keyword(), keyword()) :: keyword()
  defp merge_prompt_opts(base, override) do
    base_inject = Keyword.get(base, :runtime_inject, Keyword.get(base, :inject))
    handler_inject = Keyword.get(override, :handler_inject, Keyword.get(override, :inject))

    base
    |> Keyword.delete(:inject)
    |> Keyword.merge(Keyword.delete(override, :inject))
    |> maybe_put_prompt_inject(:runtime_inject, base_inject)
    |> maybe_put_prompt_inject(:handler_inject, handler_inject)
  end

  @spec maybe_put_prompt_inject(keyword(), atom(), term()) :: keyword()
  defp maybe_put_prompt_inject(opts, _key, nil), do: opts
  defp maybe_put_prompt_inject(opts, key, inject), do: Keyword.put(opts, key, inject)

  @spec ensure_no_pending_effect(Spectre.State.t()) :: :ok | {:error, term()}
  defp ensure_no_pending_effect(%Spectre.State{} = state) do
    case Spectre.State.pending_effect(state) do
      nil ->
        :ok

      %Effect{} = effect ->
        {:error, {:pending_effect_not_resolved, effect.id, effect.status}}
    end
  end

  @spec pending_effect(Spectre.State.t()) :: Effect.t()
  defp pending_effect(%Spectre.State{} = state), do: Spectre.State.pending_effect(state)

  @spec join_reply(String.t(), String.t()) :: String.t()
  defp join_reply("", right), do: right
  defp join_reply(left, ""), do: left
  defp join_reply(left, right), do: left <> "\n\n" <> right
end
