defmodule Spectre.ActionExecutor do
  @moduledoc """
  Executes pending action effects at the explicit host boundary.

  Planning and policy gates only stage or approve effects. This module is the
  only place that calls action functions, and it refuses policy-gated effects
  until their approved state has been persisted.
  """

  alias Spectre.ActionConfig
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.State

  @type action_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Executes the single pending action effect stored in state.

  Unprotected effects are executable in `:pending` state. Protected effects
  must first transition from `:waiting_policy` to `:approved`.
  """
  @spec execute_pending(State.t(), Spectre.Context.t() | map(), keyword()) :: action_result()
  def execute_pending(%State{} = state, ctx, opts \\ []) do
    case State.pending_effect(state) do
      nil ->
        no_pending_effect(state, ctx)

      %Effect{kind: :action, status: :waiting_policy} = effect ->
        {:error, {:effect_not_approved, effect.id}}

      %Effect{kind: :action, status: status} = effect when status in [:pending, :approved] ->
        execute_or_replay(state, effect, ctx, opts)

      %Effect{kind: :action} = effect ->
        {:error, {:effect_not_executable, effect.id, effect.status}}

      %Effect{} = effect ->
        {:error, {:unsupported_effect_kind, effect.kind}}
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

  @spec execute_or_replay(State.t(), Effect.t(), Spectre.Context.t() | map(), keyword()) ::
          action_result()
  defp execute_or_replay(%State{} = state, %Effect{} = effect, ctx, opts) do
    case State.resolved_effect(state, effect.id) do
      nil ->
        execute_action_effect(state, effect, ctx, opts)

      %Effect{} = resolved ->
        state = %{state | pending_effects: []}

        {:ok,
         %Result{
           state: state,
           input: Map.get(ctx, :input),
           effects: [resolved],
           reply_text: format_action_result(resolved.result),
           events: [
             %{
               type: :effect_already_resolved,
               kind: resolved.kind,
               name: resolved.name,
               effect_id: resolved.id,
               effect: resolved
             }
           ]
         }}
    end
  end

  @spec execute_action_effect(State.t(), Effect.t(), Spectre.Context.t() | map(), keyword()) ::
          action_result()
  defp execute_action_effect(%State{} = state, %Effect{} = effect, ctx, opts) do
    opts = effect_execution_opts(effect, opts)
    ctx = normalize_ctx(ctx, Map.get(ctx, :input, Input.new("")), opts)

    case bounded_action_call(effect, ctx) do
      {:ok, result} ->
        {state, completed} = State.complete_pending_effect(state, result)

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
               effect_id: effect.id,
               idempotency_key: Effect.idempotency_key(effect),
               effect: completed,
               result: result
             }
           ]
         }}

      {:error, reason} ->
        {state, failed} = State.fail_pending_effect(state, reason)

        {:ok,
         %Result{
           input: ctx.input,
           state: state,
           effects: List.wrap(failed),
           events: [
             %{
               type: :effect_failed,
               kind: :action,
               name: effect.name,
               effect_id: effect.id,
               idempotency_key: Effect.idempotency_key(effect),
               effect: failed,
               error: reason
             }
           ]
         }}
    end
  end

  @spec bounded_action_call(Effect.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp bounded_action_call(%Effect{} = effect, ctx) do
    with :ok <- validate_action_payload(effect.args, :arguments, ctx.opts, :action_max_bytes),
         {:ok, result} <- isolated_action_call(effect, ctx),
         :ok <- validate_action_payload(result, :result, ctx.opts, :action_result_max_bytes) do
      {:ok, result}
    end
  end

  @spec isolated_action_call(Effect.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp isolated_action_call(%Effect{} = effect, ctx) do
    case Call.run(
           :action,
           fn -> call_action(effect, ctx) end,
           Keyword.put(ctx.opts, :purpose, :action_execute)
         ) do
      {:error, %Failure{kind: kind} = failure}
      when kind in [:timeout, :exit, :crash] ->
        {:error, {:action_outcome_ambiguous, failure}}

      result ->
        result
    end
  end

  @spec validate_action_payload(term(), atom(), keyword(), atom()) :: :ok | {:error, term()}
  defp validate_action_payload(value, kind, opts, key) do
    max_bytes = Keyword.get(opts, key, 1_000_000)
    bytes = :erlang.external_size(value)

    if is_integer(max_bytes) and max_bytes > 0 and bytes <= max_bytes do
      :ok
    else
      {:error, {:action_payload_too_large, kind, bytes, max_bytes}}
    end
  rescue
    exception -> {:error, {:action_payload_size_failed, kind, exception.__struct__}}
  end

  @spec call_action(Effect.t(), Spectre.Context.t()) :: {:ok, term()} | {:error, term()}
  defp call_action(%Effect{} = effect, ctx) do
    case Effect.selected_tool(effect) do
      tool when is_binary(tool) -> call_selected_tool(tool, effect, ctx)
      _other -> call_action_module(effect, ctx)
    end
  end

  @spec call_selected_tool(String.t(), Effect.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_selected_tool(tool, effect, ctx) do
    with {:ok, module, function, arity} <- parse_tool(tool),
         :ok <- ActionConfig.authorize_tool(ctx.agent, module, function, arity) do
      call_selected_arity(module, function, arity, effect, ctx)
    end
  end

  @spec call_selected_arity(module(), atom(), non_neg_integer(), Effect.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_selected_arity(module, function, 2, effect, ctx),
    do: invoke_action(module, function, [effect.args, ctx])

  defp call_selected_arity(module, function, 1, effect, _ctx),
    do: invoke_action(module, function, [effect.args])

  defp call_selected_arity(module, function, arity, _effect, _ctx),
    do: {:error, {:unsupported_action_arity, module, function, arity}}

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
      function_exported?(module, name, 2) ->
        invoke_action(module, name, [effect.args, ctx])

      function_exported?(module, name, 1) ->
        invoke_action(module, name, [effect.args])

      true ->
        {:error, {:undefined_action, module, name}}
    end
  end

  @spec invoke_action(module(), atom(), list()) :: {:ok, term()} | {:error, term()}
  defp invoke_action(module, function, args) do
    module
    |> apply(function, args)
    |> normalize_action_reply()
  rescue
    exception ->
      {:error, {:action_exception, module, function, exception}}
  catch
    kind, reason ->
      {:error, {:action_failure, module, function, kind, reason}}
  end

  @spec normalize_action_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_action_reply({:ok, result}), do: {:ok, result}
  defp normalize_action_reply({:error, reason}), do: {:error, reason}
  defp normalize_action_reply(result), do: {:ok, result}

  @spec parse_tool(String.t()) ::
          {:ok, module(), atom(), non_neg_integer()}
          | {:error, :invalid_tool | :unknown_tool_module | :unknown_tool_function}
  defp parse_tool("Elixir." <> rest) do
    case Regex.run(~r/^(.+)\.([^\.\/]+)\/(\d+)$/, rest) do
      [_all, module_text, function, arity] ->
        with {:ok, module} <- existing_module(module_text),
             {:ok, function} <- existing_function(function) do
          {:ok, module, function, String.to_integer(arity)}
        end

      _other ->
        {:error, :invalid_tool}
    end
  end

  defp parse_tool(_tool), do: {:error, :invalid_tool}

  @spec existing_module(String.t()) :: {:ok, module()} | {:error, :unknown_tool_module}
  defp existing_module(module_text) do
    {:ok, String.to_existing_atom("Elixir." <> module_text)}
  rescue
    ArgumentError -> {:error, :unknown_tool_module}
  end

  @spec existing_function(String.t()) :: {:ok, atom()} | {:error, :unknown_tool_function}
  defp existing_function(function) do
    {:ok, String.to_existing_atom(function)}
  rescue
    ArgumentError -> {:error, :unknown_tool_function}
  end

  @spec effect_execution_opts(Effect.t(), keyword()) :: keyword()
  defp effect_execution_opts(%Effect{} = effect, opts) do
    opts
    |> Keyword.put(:effect_id, effect.id)
    |> Keyword.put(:idempotency_key, Effect.idempotency_key(effect))
  end

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
