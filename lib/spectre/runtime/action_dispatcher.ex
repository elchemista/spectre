defmodule Spectre.ActionDispatcher do
  @moduledoc """
  Capability boundary for invoking one already-validated action effect.

  This module does not mutate lifecycle state or persist results. Callers must
  pass the effect through `Spectre.Execution` for the complete workflow.
  """

  alias Spectre.ActionConfig
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @doc """
  Invokes the action capability with bounded payloads and an idempotency key in
  the action context options.
  """
  @spec dispatch(Effect.t(), Spectre.Context.t() | map(), keyword()) :: dispatch_result()
  def dispatch(%Effect{} = effect, ctx, opts \\ []) do
    opts = effect_execution_opts(effect, opts)
    ctx = normalize_ctx(ctx, Map.get(ctx, :input, Input.new("")), opts)
    bounded_action_call(effect, ctx)
  end

  @spec bounded_action_call(Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp bounded_action_call(%Effect{} = effect, ctx) do
    with :ok <- validate_action_payload(effect.args, :arguments, ctx.opts, :action_max_bytes),
         {:ok, result} <- isolated_action_call(effect, ctx),
         :ok <- validate_action_payload(result, :result, ctx.opts, :action_result_max_bytes) do
      {:ok, result}
    end
  end

  @spec isolated_action_call(Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp isolated_action_call(%Effect{} = effect, ctx) do
    case Call.run(
           :action,
           fn -> call_action(effect, ctx) end,
           Keyword.put(ctx.opts, :purpose, :action_execute)
         ) do
      {:error, %Failure{kind: kind} = failure} when kind in [:timeout, :exit, :crash] ->
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

  @spec call_action(Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp call_action(%Effect{} = effect, ctx) do
    case Effect.selected_tool(effect) do
      tool when is_binary(tool) -> call_selected_tool(tool, effect, ctx)
      _other -> call_action_module(effect, ctx)
    end
  end

  @spec call_selected_tool(String.t(), Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp call_selected_tool(tool, effect, ctx) do
    with {:ok, module, function, arity} <- parse_tool(tool),
         :ok <- ActionConfig.authorize_tool(ctx.agent, module, function, arity) do
      call_selected_arity(module, function, arity, effect, ctx)
    end
  end

  @spec call_selected_arity(module(), atom(), non_neg_integer(), Effect.t(), Spectre.Context.t()) ::
          dispatch_result()
  defp call_selected_arity(module, function, 2, effect, ctx),
    do: invoke_action(module, function, [effect.args, ctx])

  defp call_selected_arity(module, function, 1, effect, _ctx),
    do: invoke_action(module, function, [effect.args])

  defp call_selected_arity(module, function, arity, _effect, _ctx),
    do: {:error, {:unsupported_action_arity, module, function, arity}}

  @spec call_action_module(Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp call_action_module(%Effect{name: name} = effect, ctx) when is_atom(name) do
    case ActionConfig.actions(ctx.agent) do
      {module, _opts} -> call_module_action(module, name, effect, ctx)
      nil -> {:error, :missing_actions_module}
    end
  end

  defp call_action_module(_effect, _ctx), do: {:error, :unknown_action_name}

  @spec call_module_action(module(), atom(), Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp call_module_action(module, name, effect, ctx) do
    cond do
      function_exported?(module, name, 2) -> invoke_action(module, name, [effect.args, ctx])
      function_exported?(module, name, 1) -> invoke_action(module, name, [effect.args])
      true -> {:error, {:undefined_action, module, name}}
    end
  end

  @spec invoke_action(module(), atom(), list()) :: dispatch_result()
  defp invoke_action(module, function, args) do
    module
    |> apply(function, args)
    |> normalize_action_reply()
  end

  @spec normalize_action_reply(term()) :: dispatch_result()
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
    |> Keyword.put(:effect_owner, effect.owner)
    |> Keyword.put(:effect_scope, effect.scope)
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
end
