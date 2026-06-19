defmodule Spectre.ActionExecutor do
  @moduledoc """
  Executes approved pending action effects.

  This is the only module that calls action functions. Planning and policy gates
  can stage effects, but execution stays behind this boundary.
  """

  alias Spectre.ActionConfig
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.State

  @type action_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Executes the pending action effect currently stored in state.

      {:ok, result} = Spectre.ActionExecutor.execute_pending(state, ctx)

  A state with no pending effect returns an `:effect_missing` event instead of
  failing. This makes policy approval paths idempotent at the host boundary.
  """
  @spec execute_pending(State.t(), Spectre.Context.t() | map(), keyword()) :: action_result()
  def execute_pending(%State{} = state, ctx, opts \\ []) do
    case State.pending_effect(state) do
      nil -> no_pending_effect(state, ctx)
      %Effect{kind: :action} = effect -> execute_action_effect(state, effect, ctx, opts)
      %Effect{} = effect -> {:error, {:unsupported_effect_kind, effect.kind}}
    end
  end

  @spec no_pending_effect(State.t(), Spectre.Context.t() | map()) :: {:ok, Result.t()}
  defp no_pending_effect(%State{} = state, ctx) do
    {:ok,
     %Result{
       state: state,
       input: Map.get(ctx, :input),
       events: [%{type: :effect_missing}]
     }}
  end

  @spec execute_action_effect(State.t(), Effect.t(), Spectre.Context.t() | map(), keyword()) ::
          action_result()
  defp execute_action_effect(%State{} = state, %Effect{} = effect, ctx, opts) do
    ctx = normalize_ctx(ctx, Map.get(ctx, :input, Input.new("")), opts)

    case call_action(effect, ctx) do
      {:ok, result} ->
        {state, completed} =
          state
          |> State.complete_pending_effect(result)
          |> trace_completed(effect)

        {:ok,
         %Result{
           input: ctx.input,
           state: state,
           effects: List.wrap(completed),
           reply_text: format_action_result(result),
           events: [
             %{
               type: :effect_completed,
               kind: :action,
               name: effect.name,
               effect: completed,
               result: result
             }
           ]
         }}

      {:error, reason} ->
        failed = Effect.fail(effect, reason)

        state = %{
          state
          | pending_effects: [],
            planned_effects: Enum.take(state.planned_effects, -31) ++ [failed]
        }

        {:ok,
         %Result{
           input: ctx.input,
           state: state,
           effects: [failed],
           events: [
             %{
               type: :effect_failed,
               kind: :action,
               name: effect.name,
               effect: failed,
               error: reason
             }
           ]
         }}
    end
  end

  @spec trace_completed({State.t(), Effect.t() | nil}, Effect.t()) ::
          {State.t(), Effect.t() | nil}
  defp trace_completed({%State{} = state, completed}, %Effect{} = original) do
    state =
      State.trace(state, %{
        type: :effect_completed,
        kind: :action,
        name: original.name,
        at: DateTime.utc_now()
      })

    {state, completed}
  end

  @spec call_action(Effect.t(), Spectre.Context.t()) :: {:ok, term()} | {:error, term()}
  defp call_action(%Effect{} = effect, ctx) do
    case Effect.selected_tool(effect) do
      tool when is_binary(tool) ->
        case parse_tool(tool) do
          {:ok, module, function, 2} ->
            {:ok, apply(module, function, [effect.args, ctx])}

          {:ok, module, function, 1} ->
            {:ok, apply(module, function, [effect.args])}

          {:ok, module, function, arity} ->
            {:error, {:unsupported_action_arity, module, function, arity}}

          {:error, _reason} ->
            call_action_module(effect, ctx)
        end

      _other ->
        call_action_module(effect, ctx)
    end
  end

  @spec call_action_module(Effect.t(), Spectre.Context.t()) :: {:ok, term()} | {:error, term()}
  defp call_action_module(%Effect{name: name} = effect, ctx) when is_atom(name) do
    case ActionConfig.actions(ctx.agent) do
      {module, _opts} -> call_module_action(module, name, effect, ctx)
      nil -> {:error, :missing_actions_module}
    end
  end

  defp call_action_module(_effect, _ctx), do: {:error, :unknown_action_name}

  @spec call_module_action(module(), atom(), Effect.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_module_action(module, name, effect, ctx) do
    cond do
      function_exported?(module, name, 2) -> {:ok, apply(module, name, [effect.args, ctx])}
      function_exported?(module, name, 1) -> {:ok, apply(module, name, [effect.args])}
      true -> {:error, {:undefined_action, module, name}}
    end
  end

  @spec parse_tool(String.t()) ::
          {:ok, module(), atom(), non_neg_integer()}
          | {:error, :invalid_tool | :unknown_tool_function}
  defp parse_tool("Elixir." <> rest) do
    case Regex.run(~r/^(.+)\.([^\.\/]+)\/(\d+)$/, rest) do
      [_all, module_text, function, arity] ->
        {:ok, Module.concat([module_text]), String.to_existing_atom(function),
         String.to_integer(arity)}

      _other ->
        {:error, :invalid_tool}
    end
  rescue
    ArgumentError -> {:error, :unknown_tool_function}
  end

  defp parse_tool(_tool), do: {:error, :invalid_tool}

  @spec normalize_ctx(Spectre.Context.t() | map(), Input.t(), keyword()) :: Spectre.Context.t()
  defp normalize_ctx(%Spectre.Context{} = ctx, _input, opts),
    do: %{ctx | opts: Keyword.merge(ctx.opts, opts)}

  defp normalize_ctx(ctx, input, opts) when is_map(ctx) do
    struct(
      Spectre.Context,
      Map.merge(ctx, %{input: input, opts: Keyword.merge(Map.get(ctx, :opts, []), opts)})
    )
  end

  @spec format_action_result(term()) :: String.t()
  defp format_action_result({:ok, result}), do: format_action_result(result)
  defp format_action_result(result) when is_binary(result), do: result
  defp format_action_result(result), do: inspect(result, limit: 8, printable_limit: 600)
end
