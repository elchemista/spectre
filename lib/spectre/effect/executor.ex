defmodule Spectre.Effect.Executor do
  @moduledoc """
  Safe capability port for extension-owned, non-action effects.

  Executors perform external work and return an outcome. They never mutate
  `Spectre.State`; `Spectre.Execution` remains the sole owner of policy,
  durable replay, and terminal lifecycle transitions.
  """

  alias Spectre.Effect
  alias Spectre.Effect.Executor.Mount
  alias Spectre.EffectConfig
  alias Spectre.Input
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @type result :: {:ok, term()} | {:error, term()}

  @callback execute(Effect.t(), Spectre.Context.t(), keyword()) :: result() | term()

  @doc "Dispatches one non-action effect through its Agent extension."
  @spec dispatch(Effect.t(), Spectre.Context.t() | map(), keyword()) :: result()
  def dispatch(effect, ctx, opts \\ [])

  def dispatch(%Effect{kind: kind} = effect, %{agent: agent} = ctx, opts)
      when is_atom(agent) and not is_nil(agent) do
    with :ok <-
           validate_size(
             effect.payload,
             :payload,
             opts,
             :effect_payload_max_bytes
           ),
         {:ok, %Mount{} = mount} <- EffectConfig.executor(agent, kind),
         {:ok, value} <- invoke(mount, effect, ctx, opts),
         :ok <-
           validate_size(
             value,
             :result,
             opts,
             :effect_result_max_bytes
           ) do
      {:ok, value}
    end
  end

  def dispatch(%Effect{} = effect, _ctx, _opts),
    do: {:error, {:effect_agent_missing, effect.id}}

  @spec invoke(Mount.t(), Effect.t(), Spectre.Context.t() | map(), keyword()) :: result()
  defp invoke(%Mount{} = mount, %Effect{} = effect, ctx, opts) do
    callback_opts =
      mount.opts
      |> Keyword.merge(opts)
      |> Keyword.put(:effect_id, effect.id)
      |> Keyword.put(:idempotency_key, Effect.idempotency_key(effect))
      |> Keyword.put(:effect_owner, effect.owner)
      |> Keyword.put(:effect_scope, effect.scope)
      |> Keyword.put(:effect_kind, effect.kind)

    context = normalize_ctx(ctx, callback_opts)

    result =
      Call.run(
        :effect,
        fn -> call_executor(mount, effect, context, callback_opts) end,
        callback_opts
        |> Call.adapter_opts()
        |> Keyword.put(:purpose, :effect_execute)
      )

    case result do
      {:error, %Failure{kind: kind} = failure}
      when kind in [:timeout, :exception, :exit, :throw, :crash] ->
        {:error, {:effect_outcome_ambiguous, effect.kind, failure}}

      other ->
        other
    end
  end

  @spec call_executor(Mount.t(), Effect.t(), Spectre.Context.t(), keyword()) :: result()
  defp call_executor(%Mount{} = mount, effect, context, opts) do
    if Code.ensure_loaded?(mount.module) and function_exported?(mount.module, :execute, 3) do
      module = mount.module

      case module.execute(effect, context, opts) do
        {:ok, _value} = result -> result
        {:error, _reason} = result -> result
        value -> {:ok, value}
      end
    else
      {:error, {:invalid_effect_executor, mount.kind, mount.module}}
    end
  end

  @spec normalize_ctx(Spectre.Context.t() | map(), keyword()) :: Spectre.Context.t()
  defp normalize_ctx(%Spectre.Context{} = ctx, opts),
    do: %{ctx | opts: Keyword.merge(ctx.opts, opts)}

  defp normalize_ctx(ctx, opts) when is_map(ctx) do
    input = Map.get(ctx, :input, Input.new(""))
    attrs = Map.merge(ctx, %{input: input, opts: Keyword.merge(Map.get(ctx, :opts, []), opts)})
    struct(Spectre.Context, attrs)
  end

  @spec validate_size(term(), atom(), keyword(), atom()) :: :ok | {:error, term()}
  defp validate_size(value, boundary, opts, key) do
    max_bytes = Keyword.get(opts, key, 1_000_000)
    bytes = :erlang.external_size(value)

    if is_integer(max_bytes) and max_bytes > 0 and bytes <= max_bytes,
      do: :ok,
      else: {:error, {:effect_payload_too_large, boundary, bytes, max_bytes}}
  rescue
    exception -> {:error, {:effect_payload_size_failed, boundary, exception.__struct__}}
  end
end
