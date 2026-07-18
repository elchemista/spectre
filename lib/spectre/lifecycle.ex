defmodule Spectre.Lifecycle do
  @moduledoc """
  Pure lifecycle state machine for effects and policy awaitables.

  Every operation validates its source state and returns an immutable
  `Spectre.Transition`. Capability execution remains outside this module.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.State
  alias Spectre.Transition

  @history_limit 32
  @trace_limit 256

  @type result :: {:ok, Transition.t()} | {:error, term()}

  @doc """
  Stages one effect and optionally opens its policy awaitable.
  """
  @spec stage(State.t(), Effect.t(), term()) :: result()
  def stage(%State{} = state, %Effect{} = effect, policy \\ nil) do
    cond do
      State.pending_effect(state) ->
        current = State.pending_effect(state)
        {:error, {:pending_effect_not_resolved, current.id, current.status}}

      effect.status != :pending ->
        {:error, {:invalid_effect_transition, effect.id, effect.status, :staged}}

      is_nil(policy) ->
        staged = %{effect | status: :pending}

        to = %{
          state
          | pending_effects: [staged],
            planned_effects: append_history(state.planned_effects, staged)
        }

        {:ok, Transition.new(:effect_staged, state, to, effect: staged, entity_id: staged.id)}

      true ->
        staged = Effect.waiting_policy(effect, policy)
        awaitable = Awaitable.open_policy(policy, staged)

        to = %{
          state
          | pending_effects: [staged],
            planned_effects: append_history(state.planned_effects, staged),
            awaitables: [awaitable]
        }

        {:ok,
         Transition.new(:policy_opened, state, to,
           effect: staged,
           awaitable: awaitable,
           entity_id: staged.id
         )}
    end
  end

  @doc """
  Moves a waiting effect to approved. The separate awaitable resolution is
  retained for compatibility with callers that attach their own policy label.
  """
  @spec approve_effect(State.t(), term()) :: result()
  def approve_effect(%State{} = state, effect_id) do
    case pending_index(state, effect_id) do
      nil ->
        replay_or_missing(state, effect_id, :effect_approved)

      index ->
        effect = Enum.at(state.pending_effects, index)

        if effect.status == :waiting_policy do
          approved = Effect.approve(effect)

          to =
            %{
              state
              | pending_effects: List.replace_at(state.pending_effects, index, approved),
                planned_effects: append_history(state.planned_effects, approved)
            }
            |> put_trace(%{
              type: :effect_approved,
              kind: approved.kind,
              name: approved.name,
              owner: approved.owner,
              scope: approved.scope,
              effect_id: approved.id,
              at: DateTime.utc_now()
            })

          {:ok,
           Transition.new(:effect_approved, state, to,
             effect: approved,
             entity_id: approved.id
           )}
        else
          {:error, {:invalid_effect_transition, effect.id, effect.status, :approved}}
        end
    end
  end

  @doc """
  Completes an executable pending effect, or returns its stored terminal
  transition when completion is repeated.
  """
  @spec complete_effect(State.t(), term(), term()) :: result()
  def complete_effect(%State{} = state, effect_id, result) do
    case pending_effect(state, effect_id) do
      nil ->
        replay_or_missing(state, effect_id, :effect_completed)

      %Effect{status: status} = effect when status in [:pending, :approved] ->
        completed = Effect.complete(effect, result)

        to =
          %{
            state
            | pending_effects: Enum.reject(state.pending_effects, &(&1.id == effect_id)),
              planned_effects: append_history(state.planned_effects, completed)
          }
          |> put_trace(%{
            type: :effect_completed,
            kind: completed.kind,
            name: completed.name,
            owner: completed.owner,
            scope: completed.scope,
            effect_id: completed.id,
            at: DateTime.utc_now()
          })

        {:ok,
         Transition.new(:effect_completed, state, to,
           effect: completed,
           entity_id: completed.id
         )}

      %Effect{} = effect ->
        {:error, {:invalid_effect_transition, effect.id, effect.status, :completed}}
    end
  end

  @doc """
  Fails an executable pending effect, with repeat-safe terminal replay.
  """
  @spec fail_effect(State.t(), term(), term()) :: result()
  def fail_effect(%State{} = state, effect_id, reason) do
    case pending_effect(state, effect_id) do
      nil ->
        replay_or_missing(state, effect_id, :effect_failed)

      %Effect{status: status} = effect when status in [:pending, :approved] ->
        failed = Effect.fail(effect, reason)

        to =
          %{
            state
            | pending_effects: Enum.reject(state.pending_effects, &(&1.id == effect_id)),
              planned_effects: append_history(state.planned_effects, failed)
          }
          |> put_trace(%{
            type: :effect_failed,
            kind: failed.kind,
            name: failed.name,
            owner: failed.owner,
            scope: failed.scope,
            effect_id: failed.id,
            at: DateTime.utc_now()
          })

        {:ok, Transition.new(:effect_failed, state, to, effect: failed, entity_id: failed.id)}

      %Effect{} = effect ->
        {:error, {:invalid_effect_transition, effect.id, effect.status, :failed}}
    end
  end

  @doc """
  Cancels all non-terminal pending effects and open awaitables.
  """
  @spec cancel_pending(State.t(), term()) :: result()
  def cancel_pending(%State{} = state, reason \\ :cancel_pending) do
    cancelled = Enum.map(state.pending_effects, &Effect.cancel(&1, reason))

    awaitables =
      Enum.map(state.awaitables, fn
        %Awaitable{status: :open} = awaitable -> Awaitable.cancel(awaitable)
        awaitable -> awaitable
      end)

    to =
      %{
        state
        | pending_effects: [],
          awaitables: awaitables,
          planned_effects: Enum.reduce(cancelled, state.planned_effects, &append_history(&2, &1))
      }
      |> put_trace(%{type: :cancel_pending, reason: reason, at: DateTime.utc_now()})

    {:ok,
     Transition.new(:pending_cancelled, state, to,
       effect: List.first(cancelled),
       awaitable: Enum.find(awaitables, &(&1.status == :cancelled)),
       entity_id: List.first(cancelled) && List.first(cancelled).id,
       metadata: %{count: length(cancelled), reason: reason}
     )}
  end

  @doc """
  Resolves the active policy and its gated effect atomically.
  """
  @spec resolve_policy(State.t(), :accept | :reject, atom()) :: result()
  def resolve_policy(%State{} = state, kind, label)
      when kind in [:accept, :reject] and is_atom(label) do
    case Enum.find(state.awaitables, &(&1.kind == :policy and &1.status == :open)) do
      nil ->
        {:error, :no_open_policy}

      %Awaitable{} = awaitable ->
        resolve_policy_awaitable(state, awaitable, kind, label)
    end
  end

  def resolve_policy(%State{}, kind, label),
    do: {:error, {:invalid_policy_resolution, kind, label}}

  @spec resolve_policy_awaitable(State.t(), Awaitable.t(), :accept | :reject, atom()) :: result()
  defp resolve_policy_awaitable(state, awaitable, :accept, label) do
    with %Effect{} = effect <- pending_effect(state, awaitable.subject_id),
         true <- effect.status == :waiting_policy do
      approved = Effect.approve(effect)
      resolved = Awaitable.accept(awaitable, label)

      to =
        %{
          state
          | pending_effects: [approved],
            planned_effects: append_history(state.planned_effects, approved),
            awaitables: replace_awaitable(state.awaitables, resolved)
        }
        |> put_trace(%{
          type: :awaitable_accepted,
          kind: :policy,
          name: awaitable.name,
          label: label,
          subject_id: awaitable.subject_id,
          at: DateTime.utc_now()
        })

      {:ok,
       Transition.new(:policy_accepted, state, to,
         effect: approved,
         awaitable: resolved,
         entity_id: approved.id
       )}
    else
      nil -> {:error, :pending_effect_not_found}
      false -> {:error, {:invalid_effect_transition, awaitable.subject_id, :unknown, :approved}}
    end
  end

  defp resolve_policy_awaitable(state, awaitable, :reject, label) do
    with %Effect{} = effect <- pending_effect(state, awaitable.subject_id),
         true <- effect.status == :waiting_policy do
      cancelled = Effect.cancel(effect, {:policy_rejected, label})
      resolved = Awaitable.reject(awaitable, label)

      to =
        %{
          state
          | pending_effects: [],
            planned_effects: append_history(state.planned_effects, cancelled),
            awaitables: replace_awaitable(state.awaitables, resolved)
        }
        |> put_trace(%{
          type: :awaitable_rejected,
          kind: :policy,
          name: awaitable.name,
          label: label,
          subject_id: awaitable.subject_id,
          at: DateTime.utc_now()
        })

      {:ok,
       Transition.new(:policy_rejected, state, to,
         effect: cancelled,
         awaitable: resolved,
         entity_id: cancelled.id
       )}
    else
      nil -> {:error, :pending_effect_not_found}
      false -> {:error, {:invalid_effect_transition, awaitable.subject_id, :unknown, :cancelled}}
    end
  end

  @spec replay_or_missing(State.t(), term(), atom()) :: result()
  defp replay_or_missing(%State{} = state, effect_id, event) do
    case terminal_effect(state, effect_id) do
      %Effect{} = effect ->
        {:ok,
         Transition.new(event, state, state,
           effect: effect,
           entity_id: effect.id,
           replayed?: true
         )}

      nil ->
        {:error, :pending_effect_not_found}
    end
  end

  @spec pending_index(State.t(), term()) :: non_neg_integer() | nil
  defp pending_index(state, effect_id),
    do: Enum.find_index(state.pending_effects, &(&1.id == effect_id))

  @spec pending_effect(State.t(), term()) :: Effect.t() | nil
  defp pending_effect(state, effect_id),
    do: Enum.find(state.pending_effects, &(&1.id == effect_id))

  @spec terminal_effect(State.t(), term()) :: Effect.t() | nil
  defp terminal_effect(state, effect_id) do
    state.planned_effects
    |> Enum.reverse()
    |> Enum.find(&(&1.id == effect_id and Effect.terminal?(&1)))
  end

  @spec append_history([Effect.t()], Effect.t()) :: [Effect.t()]
  defp append_history(effects, effect), do: Enum.take(effects, -(@history_limit - 1)) ++ [effect]

  @spec replace_awaitable([Awaitable.t()], Awaitable.t()) :: [Awaitable.t()]
  defp replace_awaitable(awaitables, replacement) do
    Enum.map(awaitables, fn awaitable ->
      if awaitable.id == replacement.id, do: replacement, else: awaitable
    end)
  end

  @spec put_trace(State.t(), term()) :: State.t()
  defp put_trace(state, event),
    do: %{state | trace: Enum.take([event | state.trace], @trace_limit)}
end
