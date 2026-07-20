defmodule Spectre.Execution do
  @moduledoc """
  Pure-lifecycle execution workflow around `Spectre.ActionDispatcher`.

  Runtime owns the durable commits before and after this workflow; this module
  validates the effect, invokes the capability once, and applies exactly one
  terminal lifecycle command.
  """

  alias Spectre.ActionDispatcher
  alias Spectre.Effect
  alias Spectre.Lifecycle
  alias Spectre.Result
  alias Spectre.State

  @type result :: {:ok, Result.t()} | {:error, term()}

  @spec execute_pending(State.t(), Spectre.Context.t() | map(), keyword()) :: result()
  def execute_pending(%State{} = state, ctx, opts \\ []) do
    case State.pending_effect(state) do
      nil -> no_pending_effect(state, ctx)
      %Effect{} = effect -> execute_effect(state, effect, ctx, opts)
    end
  end

  @spec execute_effect(State.t(), Effect.t(), Spectre.Context.t() | map(), keyword()) :: result()
  defp execute_effect(state, effect, ctx, opts) do
    with :ok <- validate_effect_origin(effect, ctx) do
      dispatch_by_status(state, effect, ctx, opts)
    end
  end

  defp dispatch_by_status(
         _state,
         %Effect{kind: :action, status: :waiting_policy} = effect,
         _ctx,
         _opts
       ),
       do: {:error, {:effect_not_approved, effect.id}}

  defp dispatch_by_status(state, %Effect{kind: :action, status: status} = effect, ctx, opts)
       when status in [:pending, :approved],
       do: execute_or_replay(state, effect, ctx, opts)

  defp dispatch_by_status(_state, %Effect{kind: :action} = effect, _ctx, _opts),
    do: {:error, {:effect_not_executable, effect.id, effect.status}}

  defp dispatch_by_status(_state, %Effect{} = effect, _ctx, _opts),
    do: {:error, {:unsupported_effect_kind, effect.kind}}

  @spec validate_effect_origin(Effect.t(), Spectre.Context.t() | map()) :: :ok | {:error, term()}
  defp validate_effect_origin(%Effect{scope: nil} = effect, _ctx),
    do: {:error, {:effect_scope_missing, effect.id}}

  defp validate_effect_origin(%Effect{} = effect, %{agent: agent})
       when is_atom(agent) and not is_nil(agent) do
    case Spectre.Definition.for_scope(agent, effect.scope) do
      {:ok, definition} ->
        validate_effect_owner(effect, definition.owner)

      {:error, reason} ->
        {:error, {:effect_scope_unresolvable, effect.id, effect.scope, reason}}
    end
  end

  defp validate_effect_origin(%Effect{} = effect, _ctx),
    do: {:error, {:effect_agent_missing, effect.id}}

  defp validate_effect_owner(%Effect{owner: nil}, _expected_owner), do: :ok
  defp validate_effect_owner(%Effect{owner: owner}, owner), do: :ok

  defp validate_effect_owner(%Effect{} = effect, expected_owner),
    do: {:error, {:effect_owner_mismatch, effect.id, effect.owner, expected_owner}}

  defp no_pending_effect(%State{} = state, ctx) do
    {:ok,
     %Result{
       state: state,
       input: Map.get(ctx, :input),
       events: [%{type: :effect_missing}]
     }}
  end

  defp execute_or_replay(%State{} = state, %Effect{} = effect, ctx, opts) do
    case State.resolved_effect(state, effect.id) do
      nil -> dispatch(state, effect, ctx, opts)
      %Effect{} -> replay(state, effect, ctx)
    end
  end

  defp replay(state, effect, ctx) do
    with {:ok, transition} <- Lifecycle.apply(state, {:replay_effect, effect.id}) do
      resolved = transition.effect

      {:ok,
       %Result{
         state: transition.to,
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

  defp dispatch(state, effect, ctx, opts) do
    started_at = System.monotonic_time()
    outcome = ActionDispatcher.dispatch(effect, ctx, opts)

    duration =
      started_at
      |> then(&(System.monotonic_time() - &1))
      |> System.convert_time_unit(:native, :microsecond)

    Spectre.Telemetry.emit(
      [:execution, :stop],
      %{duration_us: max(duration, 0)},
      %{
        effect_id: effect.id,
        kind: effect.kind,
        name: effect.name,
        outcome: if(match?({:ok, _}, outcome), do: :ok, else: :error)
      },
      Map.get(ctx, :opts, [])
    )

    case outcome do
      {:ok, value} -> finish(state, effect, ctx, {:complete_effect, effect.id, value})
      {:error, reason} -> finish(state, effect, ctx, {:fail_effect, effect.id, reason})
    end
  end

  defp finish(state, effect, ctx, command) do
    with {:ok, transition} <- Lifecycle.apply(state, command) do
      terminal = transition.effect
      completed? = terminal.status == :completed

      event = %{
        type: if(completed?, do: :effect_completed, else: :effect_failed),
        kind: :action,
        name: effect.name,
        owner: effect.owner,
        scope: effect.scope,
        effect_id: effect.id,
        idempotency_key: Effect.idempotency_key(effect),
        effect: terminal
      }

      event =
        if completed?,
          do: Map.put(event, :result, terminal.result),
          else: Map.put(event, :error, terminal.error)

      {:ok,
       %Result{
         input: Map.get(ctx, :input),
         state: transition.to,
         effects: [terminal],
         reply_text: if(completed?, do: format_action_result(terminal.result), else: ""),
         events: [event],
         metadata: %{execution_transition: transition}
       }}
    end
  end

  defp format_action_result({:ok, value}), do: format_action_result(value)
  defp format_action_result(value) when is_binary(value), do: value
  defp format_action_result(value), do: inspect(value, limit: 8, printable_limit: 600)
end
