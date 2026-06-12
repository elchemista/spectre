defmodule Spectre.Runner do
  @moduledoc """
  Executes routed handlers without crossing action boundaries accidentally.
  """

  alias Spectre.{ActionConfig, ActionPlanner, ActionProtection, Input, Prompt, Result, Route}

  @doc """
  Runs the handler selected by a route.
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

  @spec plan_reply(String.t(), Input.t(), Spectre.Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  defp plan_reply(reply, input, ctx, opts) do
    with {:ok, %{reply_text: reply_text, actions: actions}} <-
           ActionPlanner.plan_response(reply, ActionConfig.planner_opts(ctx, opts)) do
      stage_actions(reply_text, actions, input, ctx, opts)
    end
  end

  @spec stage_actions(
          String.t(),
          [Spectre.PendingAction.t()],
          Input.t(),
          Spectre.Context.t(),
          keyword()
        ) ::
          {:ok, Result.t()} | {:error, term()}
  defp stage_actions(reply_text, [], input, ctx, _opts) do
    {:ok, %Result{input: input, route: ctx.route, state: ctx.state, reply_text: reply_text}}
  end

  defp stage_actions(reply_text, [action | _rest] = actions, input, ctx, opts) do
    policy = ActionProtection.protected_by(ctx.agent, action)
    state = Spectre.State.put_pending(ctx.state, action, policy)
    ctx = %{ctx | state: state}

    if policy do
      request_policy(policy, reply_text, actions, input, ctx, opts)
    else
      {:ok,
       %Result{
         input: input,
         route: ctx.route,
         state: state,
         reply_text: reply_text,
         actions: actions,
         events: [%{type: :action_staged, action: action.name}]
       }}
    end
  end

  @spec request_policy(
          atom(),
          String.t(),
          [Spectre.PendingAction.t()],
          Input.t(),
          Spectre.Context.t(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp request_policy(policy_name, reply_text, actions, input, ctx, opts) do
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
               actions: actions,
               events: [%{type: :policy_requested, policy: policy_name} | request.events]
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

  @spec join_reply(String.t(), String.t()) :: String.t()
  defp join_reply("", right), do: right
  defp join_reply(left, ""), do: left
  defp join_reply(left, right), do: left <> "\n\n" <> right
end
