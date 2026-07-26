defmodule Spectre.ActionDispatcher do
  @moduledoc """
  Capability boundary for invoking one provider-neutral action effect.

  The dispatcher resolves only providers registered by the compiled Agent. It
  does not interpret planner-specific tool IDs and it never mutates lifecycle
  state or persists results.
  """

  alias Spectre.Action
  alias Spectre.Action.Provider
  alias Spectre.ActionConfig
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @doc """
  Invokes the registered provider with bounded payloads and an idempotency key
  in the action context.
  """
  @spec dispatch(Effect.t(), Spectre.Context.t() | map(), keyword()) :: dispatch_result()
  def dispatch(effect, ctx, opts \\ [])

  def dispatch(%Effect{kind: :action} = effect, ctx, opts) do
    opts = effect_execution_opts(effect, opts)
    ctx = normalize_ctx(ctx, Map.get(ctx, :input, Input.new("")), opts)
    bounded_action_call(effect, ctx)
  end

  def dispatch(%Effect{} = effect, _ctx, _opts),
    do: {:error, {:unsupported_effect_kind, effect.kind}}

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
           fn -> call_provider(effect, ctx) end,
           Keyword.put(ctx.opts, :purpose, :action_execute)
         ) do
      {:error, %Failure{kind: kind} = failure}
      when kind in [:timeout, :exception, :exit, :throw, :crash] ->
        {:error, {:action_outcome_ambiguous, failure}}

      result ->
        result
    end
  end

  @spec call_provider(Effect.t(), Spectre.Context.t()) :: dispatch_result()
  defp call_provider(%Effect{} = effect, ctx) do
    action = Action.from_effect(effect)

    with {:ok, mount} <- ActionConfig.provider(ctx.agent, action.via) do
      Provider.execute(mount, action, ctx)
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

  @spec effect_execution_opts(Effect.t(), keyword()) :: keyword()
  defp effect_execution_opts(%Effect{} = effect, opts) do
    opts
    |> Keyword.put(:effect_id, effect.id)
    |> Keyword.put(:idempotency_key, Effect.idempotency_key(effect))
    |> Keyword.put(:effect_owner, effect.owner)
    |> Keyword.put(:effect_scope, effect.scope)
    |> Keyword.put(:action_provider, Effect.via(effect))
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
