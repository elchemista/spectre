defmodule Spectre.ActionHooks do
  @moduledoc """
  Runs lifecycle hooks for executed actions.

  Hooks are intentionally post-execution. They are useful for audit records,
  delivery acknowledgements, integration events, or cleanup that should happen
  after the user-facing action result exists.
  """

  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Result

  @type hook_event :: :delivered
  @type hook :: %{
          action: atom() | String.t(),
          on: hook_event() | atom(),
          run: {module(), atom()} | function(),
          opts: keyword()
        }

  @doc """
  Runs hooks configured for an executed action lifecycle event.

      :ok = Spectre.ActionHooks.run(MyAgent, :delivered, result, ctx)

  Both agent-level hooks and hooks attached to a completed action effect are considered.
  Errors are accumulated so one failing hook does not hide another.
  """
  @spec run(module(), hook_event() | atom(), Result.t(), Context.t() | map(), keyword()) ::
          :ok | {:error, [term()]}
  def run(agent, event, %Result{} = result, ctx, opts \\ []) when is_atom(agent) do
    ctx = normalize_ctx(agent, result, ctx, opts)

    errors =
      result
      |> executed_actions()
      |> Enum.flat_map(&matching_hooks(agent, &1, event))
      |> Enum.reduce([], fn {hook, action_result}, errors ->
        case run_hook(hook, action_result, ctx) do
          :ok -> errors
          {:error, reason} -> [reason | errors]
        end
      end)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  @spec executed_actions(Result.t()) :: [map()]
  defp executed_actions(%Result{effects: effects}) do
    Enum.flat_map(effects, fn
      %Effect{kind: :action, status: :completed, result: {:ok, result}} = effect ->
        [%{action: effect.name, effect: effect, result: result}]

      %Effect{kind: :action, status: :completed, result: result} = effect ->
        [%{action: effect.name, effect: effect, result: result}]

      _effect ->
        []
    end)
  end

  @spec matching_hooks(module(), map(), atom()) :: [{hook(), term()}]
  defp matching_hooks(agent, executed, event) do
    action = executed.action
    scope = Effect.scope(executed.effect)
    action_hooks = executed.effect |> effect_hooks() |> hooks_for(action, event)
    agent_hooks = agent |> agent_hooks() |> hooks_for(action, event, scope)

    Enum.map(action_hooks ++ agent_hooks, &{&1, executed.result})
  end

  @spec effect_hooks(Effect.t()) :: [hook()]
  defp effect_hooks(%Effect{} = effect), do: Effect.hooks(effect)

  @spec agent_hooks(module()) :: [hook()]
  defp agent_hooks(agent), do: Spectre.Definition.after_actions(agent)

  @spec hooks_for([hook()], atom() | String.t() | nil, atom()) :: [hook()]
  defp hooks_for(hooks, action, event) do
    Enum.filter(hooks, fn hook ->
      hook.on == event and action_matches?(hook.action, action)
    end)
  end

  @spec hooks_for([hook()], atom() | String.t() | nil, atom(), Spectre.Definition.scope() | nil) ::
          [hook()]
  defp hooks_for(hooks, action, event, scope) do
    Enum.filter(hooks, fn hook ->
      hook.on == event and action_matches?(hook.action, action) and
        hook_scope_matches?(hook, scope)
    end)
  end

  @spec hook_scope_matches?(map(), Spectre.Definition.scope() | nil) :: boolean()
  defp hook_scope_matches?(%{scope: :agent}, _scope), do: true
  defp hook_scope_matches?(%{scope: nil}, _scope), do: true
  defp hook_scope_matches?(%{scope: scope}, scope), do: true
  defp hook_scope_matches?(_hook, _scope), do: false

  @spec action_matches?(term(), term()) :: boolean()
  defp action_matches?(left, right), do: normalize_action(left) == normalize_action(right)

  @spec normalize_action(term()) :: term()
  defp normalize_action(action) when is_atom(action), do: action

  defp normalize_action(action) when is_binary(action) do
    String.to_existing_atom(action)
  rescue
    ArgumentError -> action
  end

  defp normalize_action(action), do: action

  @spec run_hook(hook(), term(), Context.t()) :: :ok | {:error, term()}
  defp run_hook(%{run: {module, function}} = hook, action_result, %Context{} = ctx)
       when is_atom(module) and is_atom(function) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, function, 3) ->
        normalize_hook_result(apply(module, function, [action_result, ctx, hook]))

      function_exported?(module, function, 2) ->
        normalize_hook_result(apply(module, function, [action_result, ctx]))

      function_exported?(module, function, 1) ->
        normalize_hook_result(apply(module, function, [action_result]))

      function_exported?(module, function, 0) ->
        normalize_hook_result(apply(module, function, []))

      true ->
        {:error, {:undefined_after_action_hook, module, function}}
    end
  rescue
    exception ->
      {:error, {:after_action_hook_exception, module, function, exception}}
  end

  defp run_hook(%{run: function}, action_result, %Context{} = ctx) when is_function(function, 3),
    do: normalize_hook_result(function.(action_result, ctx, %{}))

  defp run_hook(%{run: function}, action_result, %Context{} = ctx) when is_function(function, 2),
    do: normalize_hook_result(function.(action_result, ctx))

  defp run_hook(%{run: function}, action_result, %Context{}) when is_function(function, 1),
    do: normalize_hook_result(function.(action_result))

  defp run_hook(%{run: function}, _action_result, %Context{}) when is_function(function, 0),
    do: normalize_hook_result(function.())

  defp run_hook(%{run: run}, _action_result, %Context{}),
    do: {:error, {:invalid_after_action_hook, run}}

  @spec normalize_hook_result(term()) :: :ok | {:error, term()}
  defp normalize_hook_result(:ok), do: :ok
  defp normalize_hook_result({:ok, _result}), do: :ok
  defp normalize_hook_result({:error, reason}), do: {:error, reason}
  defp normalize_hook_result(other), do: {:error, {:invalid_after_action_result, other}}

  @spec normalize_ctx(module(), Result.t(), Context.t() | map(), keyword()) :: Context.t()
  defp normalize_ctx(agent, %Result{} = result, %Context{} = ctx, opts) do
    %{
      ctx
      | agent: ctx.agent || agent,
        input: ctx.input || result.input,
        opts: Keyword.merge(ctx.opts, opts)
    }
  end

  defp normalize_ctx(agent, %Result{} = result, ctx, opts) when is_map(ctx) do
    attrs =
      ctx
      |> Map.merge(%{
        agent: Map.get(ctx, :agent, agent),
        input: Map.get(ctx, :input, result.input),
        state: Map.get(ctx, :state, result.state),
        opts: Keyword.merge(Map.get(ctx, :opts, []), opts)
      })

    struct(Context, attrs)
  end
end
