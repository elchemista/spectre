defmodule Spectre.ActionExecutor do
  @moduledoc """
  Executes approved pending actions.

  This is the only module that calls action functions. Planning and policy gates
  can stage actions, but execution stays behind this boundary.
  """

  alias Spectre.ActionConfig
  alias Spectre.Input
  alias Spectre.PendingAction
  alias Spectre.Result
  alias Spectre.State

  @type action_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Executes the pending action currently stored in state.

      {:ok, result} = Spectre.ActionExecutor.execute_pending(state, ctx)

  A state with no pending action returns an `:no_pending_action` event instead
  of failing. This makes policy approval paths idempotent at the host boundary.
  """
  @spec execute_pending(State.t(), Spectre.Context.t() | map(), keyword()) :: action_result()
  def execute_pending(%State{pending_action: nil} = state, ctx, _opts) do
    {:ok,
     %Result{
       state: state,
       input: Map.get(ctx, :input),
       events: [%{type: :no_pending_action}]
     }}
  end

  def execute_pending(%State{pending_action: %PendingAction{} = action} = state, ctx, opts) do
    ctx = normalize_ctx(ctx, Map.get(ctx, :input, Input.new("")), opts)

    with {:ok, result} <- call_action(action, ctx) do
      state =
        state
        |> State.clear_pending()
        |> State.trace(%{type: :action_executed, action: action.name, at: DateTime.utc_now()})

      # The executed pending action is included in the event so after-action
      # hooks can still inspect policy, AL, args, and selected tool metadata
      # after state has been cleared.
      {:ok,
       %Result{
         input: ctx.input,
         state: state,
         actions: [action],
         reply_text: format_action_result(result),
         events: [
           %{type: :action_executed, action: action.name, pending_action: action, result: result}
         ]
       }}
    end
  end

  @spec call_action(PendingAction.t(), Spectre.Context.t()) :: {:ok, term()} | {:error, term()}
  defp call_action(%PendingAction{selected_tool: tool} = action, ctx) when is_binary(tool) do
    case parse_tool(tool) do
      {:ok, module, function, 2} ->
        {:ok, apply(module, function, [action.args, ctx])}

      {:ok, module, function, 1} ->
        {:ok, apply(module, function, [action.args])}

      {:ok, module, function, arity} ->
        {:error, {:unsupported_action_arity, module, function, arity}}

      {:error, _reason} ->
        # Invalid tool metadata falls back to the configured action module. This
        # keeps AL/tool extraction errors from bypassing the explicit action
        # adapter boundary.
        call_action_module(action, ctx)
    end
  end

  defp call_action(%PendingAction{} = action, ctx), do: call_action_module(action, ctx)

  @spec call_action_module(PendingAction.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_action_module(%PendingAction{name: name} = action, ctx) when is_atom(name) do
    case ActionConfig.actions(ctx.agent) do
      {module, _opts} -> call_module_action(module, name, action, ctx)
      nil -> {:error, :missing_actions_module}
    end
  end

  defp call_action_module(_action, _ctx), do: {:error, :unknown_action_name}

  @spec call_module_action(module(), atom(), PendingAction.t(), Spectre.Context.t()) ::
          {:ok, term()} | {:error, term()}
  defp call_module_action(module, name, action, ctx) do
    cond do
      function_exported?(module, name, 2) -> {:ok, apply(module, name, [action.args, ctx])}
      function_exported?(module, name, 1) -> {:ok, apply(module, name, [action.args])}
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
