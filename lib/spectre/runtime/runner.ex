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
    ctx = %{ctx | route: route, opts: Keyword.merge(ctx.opts, handler_opts)}
    reply(prompt, ctx.input, ctx, handler_opts)
  end

  def run(%Route{handler: {:action, action, handler_opts}} = route, ctx) do
    ctx = %{ctx | route: route, opts: Keyword.merge(ctx.opts, handler_opts)}
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
    ctx = normalize_ctx(ctx, input, opts)

    prompt_opts = Keyword.merge(ctx.opts, opts)

    with {:ok, rendered} <- Prompt.render(ctx.agent, prompt, ctx, prompt_opts),
         {:ok, reply} <- Spectre.LLM.complete(rendered, prompt_opts) do
      if Keyword.get(opts, :policy_prompt?) do
        {:ok,
         %Result{
           input: input,
           route: ctx.route,
           state: ctx.state,
           reply_text: ActionPlanner.clean_reply(reply)
         }}
      else
        plan_reply(reply, input, ctx, prompt_opts)
      end
    end
  end

  @doc """
  Calls an agent-local function declared through a `run` handler.

      {:ok, result} = Spectre.Runner.run_function(:prepare_case, input, ctx)
  """
  @spec run_function(atom(), Input.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_function(function, %Input{} = input, ctx) when is_atom(function) do
    ctx = normalize_ctx(ctx, input, [])
    agent = ctx.agent

    cond do
      function_exported?(agent, function, 2) ->
        normalize_function_result(apply(agent, function, [input, ctx]), input, ctx)

      function_exported?(agent, function, 1) ->
        normalize_function_result(apply(agent, function, [input]), input, ctx)

      true ->
        {:error, {:undefined_run_function, agent, function}}
    end
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
    ctx = normalize_ctx(ctx, input, opts)

    with {:ok, text} <- render_reply(prompt, input, ctx, opts) do
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
    ctx = normalize_ctx(ctx, input, opts)

    effect =
      Effect.stage(%{
        name: action,
        args: Keyword.get(opts, :args, %{}),
        status: Keyword.get(opts, :status, :ok),
        payload: %{
          al: Keyword.get(opts, :al),
          hooks: Keyword.get(opts, :hooks, []),
          source: :dsl
        }
      })

    with :ok <- ensure_no_pending_effect(ctx.state) do
      policy = Keyword.get(opts, :policy) || ActionProtection.protected_by(ctx.agent, effect)
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
    with :ok <- ensure_no_pending_effect(ctx.state) do
      policy = ActionProtection.protected_by(ctx.agent, effect)
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
        Prompt.render(ctx.agent, prompt, ctx, opts)

      {module, function} when is_atom(module) and is_atom(function) ->
        call_reply_renderer(module, function, prompt, input, ctx, opts)

      function when is_function(function, 3) ->
        normalize_reply_text(function.(prompt, input, ctx))

      function when is_function(function, 2) ->
        normalize_reply_text(function.(prompt, reply_assigns(ctx, opts)))

      function when is_function(function, 1) ->
        normalize_reply_text(function.(reply_assigns(ctx, opts)))

      other ->
        {:error, {:invalid_reply_renderer, other}}
    end
  end

  @spec call_reply_renderer(module(), atom(), term(), Input.t(), Spectre.Context.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp call_reply_renderer(module, function, prompt, input, ctx, opts) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, function, 3) ->
        normalize_reply_text(apply(module, function, [prompt, input, ctx]))

      function_exported?(module, function, 2) ->
        normalize_reply_text(apply(module, function, [prompt, reply_assigns(ctx, opts)]))

      function_exported?(module, function, 1) ->
        normalize_reply_text(apply(module, function, [reply_assigns(ctx, opts)]))

      true ->
        {:error, {:undefined_reply_renderer, module, function}}
    end
  rescue
    exception ->
      {:error, {:reply_renderer_exception, module, function, exception}}
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
  defp normalize_reply_text(other), do: {:error, {:invalid_reply_text, other}}

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
          atom(),
          String.t(),
          [Effect.t()],
          Input.t(),
          Spectre.Context.t(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp request_policy(policy_name, reply_text, effects, input, ctx, opts) do
    case Map.get(ctx.agent.__spectre_policies__(), policy_name) do
      nil ->
        {:error, {:unknown_policy, policy_name}}

      %{request: request_prompt} = policy ->
        with {:ok, %Result{} = request} <-
               ask(
                 request_prompt,
                 input,
                 ctx,
                 Keyword.merge(opts, policy_prompt?: true, policy: policy.name)
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
  defp normalize_function_result({:ok, %Result{} = result}, _input, _ctx), do: {:ok, result}
  defp normalize_function_result(%Result{} = result, _input, _ctx), do: {:ok, result}

  defp normalize_function_result({:ok, reply}, input, ctx),
    do: {:ok, %Result{input: input, state: ctx.state, reply_text: to_string(reply)}}

  defp normalize_function_result({:error, reason}, _input, _ctx), do: {:error, reason}

  defp normalize_function_result(reply, input, ctx),
    do: {:ok, %Result{input: input, state: ctx.state, reply_text: to_string(reply)}}

  @spec normalize_ctx(Spectre.Context.t() | map(), Input.t(), keyword()) :: Spectre.Context.t()
  defp normalize_ctx(%Spectre.Context{} = ctx, _input, opts),
    do: %{ctx | opts: Keyword.merge(ctx.opts, opts)}

  defp normalize_ctx(ctx, input, opts) when is_map(ctx) do
    attrs = Map.merge(ctx, %{input: input, opts: Keyword.merge(Map.get(ctx, :opts, []), opts)})
    struct(Spectre.Context, attrs)
  end

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
