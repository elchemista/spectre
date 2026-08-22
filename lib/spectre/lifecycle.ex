defmodule Spectre.Lifecycle do
  @moduledoc """
  Pure lifecycle state machine for effects and policy awaitables.

  Every operation validates its source state and returns an immutable
  `Spectre.Transition`. Capability execution remains outside this module.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Result
  alias Spectre.State
  alias Spectre.Transition

  @history_limit 512
  @awaitable_history_limit 512
  @trace_limit 256

  @type result :: {:ok, Transition.t()} | {:error, term()}

  @type command ::
          {:stage_effect, Effect.t(), term()}
          | {:approve_effect, term()}
          | {:complete_effect, term(), term()}
          | {:fail_effect, term(), term()}
          | {:cancel_pending, term()}
          | {:cancel_pending, term(), String.t()}
          | {:resolve_policy, :accept | :reject, atom()}
          | {:resolve_policy, term(), :accept | :reject, atom()}
          | {:policy_attempt, term()}
          | {:expire_policy, term()}
          | {:replay_effect, term()}
          | {:replace_awaitable, Awaitable.t()}
          | :clear_open_awaitables
          | :clear_pending

  @doc """
  Applies one canonical lifecycle command.

  The named functions below remain available for compatibility, while this
  entry point gives policy, runner, execution, and hosts one command surface.
  """
  @spec apply(State.t(), command()) :: result()
  def apply(%State{} = state, {:stage_effect, %Effect{} = effect, policy}),
    do: stage(state, effect, policy)

  def apply(%State{} = state, {:approve_effect, effect_id}),
    do: approve_effect(state, effect_id)

  def apply(%State{} = state, {:complete_effect, effect_id, result}),
    do: complete_effect(state, effect_id, result)

  def apply(%State{} = state, {:fail_effect, effect_id, reason}),
    do: fail_effect(state, effect_id, reason)

  def apply(%State{} = state, {:cancel_pending, reason}), do: cancel_pending(state, reason)

  def apply(%State{} = state, {:cancel_pending, reason, run_id}) when is_binary(run_id),
    do: cancel_pending(state, reason, run_id)

  def apply(%State{} = state, {:resolve_policy, kind, label}),
    do: resolve_policy(state, kind, label)

  def apply(%State{} = state, {:resolve_policy, awaitable_id, kind, label}),
    do: resolve_policy(state, awaitable_id, kind, label)

  def apply(%State{} = state, {:policy_attempt, awaitable_id}),
    do: policy_attempt(state, awaitable_id)

  def apply(%State{} = state, {:expire_policy, awaitable_id}),
    do: expire_policy(state, awaitable_id)

  def apply(%State{} = state, {:replay_effect, effect_id}),
    do: replay_effect(state, effect_id)

  def apply(%State{} = state, {:replace_awaitable, %Awaitable{} = awaitable}),
    do: replace_awaitable_transition(state, awaitable)

  def apply(%State{} = state, :clear_open_awaitables), do: clear_open_awaitables(state)
  def apply(%State{} = state, :clear_pending), do: clear_pending(state)
  def apply(%State{}, command), do: {:error, {:unknown_lifecycle_command, command}}

  @doc """
  Projects a result to the single next host decision.
  """
  @spec next(Result.t()) :: Spectre.Turn.decision()
  def next(%Result{} = result) do
    cond do
      awaitable = Result.boundary_awaitable(result) -> {:awaiting, awaitable, result}
      effect = Result.executable_effect(result) -> {:needs, effect, result}
      completion = Result.latest_completion(result) -> {:completed, completion, result}
      Result.visible_reply?(result) -> {:reply, result}
      true -> {:no_response, result}
    end
  end

  @doc """
  Returns the canonical lifecycle projection used by results and turns.
  """
  @spec projection(Result.t()) :: map()
  def projection(%Result{} = result) do
    %{
      open_awaitable: Result.open_awaitable(result),
      pending_effect: Result.pending_effect(result),
      completions: Result.completions(result),
      latest_completion: Result.latest_completion(result),
      action_outcome: Result.action_outcome(result),
      visible_reply?: Result.visible_reply?(result)
    }
  end

  @doc """
  Stages one effect and optionally opens its policy awaitable.
  """
  @spec stage(State.t(), Effect.t(), term()) :: result()
  def stage(%State{} = state, %Effect{} = effect, policy \\ nil) do
    {policy, resolver} = policy_gate(policy)
    external = if is_nil(policy), do: nil, else: external_policy_awaitable(state)

    cond do
      resolver not in [:conversation, :external] ->
        {:error, {:invalid_policy_resolver, resolver}}

      current = pending_effect_for_run(state, effect.run_id) ->
        {:error, {:pending_effect_not_resolved, current.id, current.status}}

      external ->
        {:error, {:approval_pending, external.id}}

      effect.status != :pending ->
        {:error, {:invalid_effect_transition, effect.id, effect.status, :staged}}

      is_nil(policy) ->
        staged = %{effect | status: :pending}

        to = %{
          state
          | pending_effects: append_pending(state.pending_effects, staged),
            planned_effects: append_history(state.planned_effects, staged)
        }

        {:ok, Transition.new(:effect_staged, state, to, effect: staged, entity_id: staged.id)}

      true ->
        staged = Effect.waiting_policy(effect, policy)
        awaitable = Awaitable.open_policy(policy, staged, resolver: resolver)

        to = %{
          state
          | pending_effects: append_pending(state.pending_effects, staged),
            planned_effects: append_history(state.planned_effects, staged),
            awaitables: append_awaitable(state.awaitables, awaitable)
        }

        {:ok,
         Transition.new(:policy_opened, state, to,
           effect: staged,
           awaitable: awaitable,
           entity_id: staged.id,
           metadata: %{resolver: resolver}
         )}
    end
  end

  @spec policy_gate(term()) :: {term(), Awaitable.resolver()}
  defp policy_gate(nil), do: {nil, :conversation}

  defp policy_gate(%{policy: policy} = gate),
    do: {policy, Map.get(gate, :resolver, :conversation)}

  defp policy_gate(policy), do: {policy, :conversation}

  @spec external_policy_awaitable(State.t()) :: Awaitable.t() | nil
  defp external_policy_awaitable(%State{} = state) do
    Enum.find(
      state.awaitables,
      &(&1.kind == :policy and &1.status == :open and &1.resolver == :external)
    )
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
  Cancels pending lifecycle work owned by one Run.
  """
  @spec cancel_pending(State.t(), term(), String.t()) :: result()
  def cancel_pending(%State{} = state, reason, run_id)
      when is_binary(run_id) and run_id != "" do
    cancelled =
      state.pending_effects
      |> Enum.filter(&(&1.run_id == run_id))
      |> Enum.map(&Effect.cancel(&1, reason))

    awaitables =
      Enum.map(state.awaitables, fn
        %Awaitable{run_id: ^run_id, status: :open} = awaitable ->
          Awaitable.cancel(awaitable)

        awaitable ->
          awaitable
      end)

    to =
      %{
        state
        | pending_effects: Enum.reject(state.pending_effects, &(&1.run_id == run_id)),
          awaitables: awaitables,
          planned_effects: Enum.reduce(cancelled, state.planned_effects, &append_history(&2, &1))
      }
      |> put_trace(%{
        type: :cancel_pending,
        reason: reason,
        run_id: run_id,
        at: DateTime.utc_now()
      })

    {:ok,
     Transition.new(:pending_cancelled, state, to,
       effect: List.first(cancelled),
       awaitable: Enum.find(awaitables, &(&1.run_id == run_id and &1.status == :cancelled)),
       entity_id: List.first(cancelled) && List.first(cancelled).id,
       metadata: %{count: length(cancelled), reason: reason, run_id: run_id}
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

  @doc """
  Resolves one explicitly identified policy awaitable.
  """
  @spec resolve_policy(State.t(), term(), :accept | :reject, atom()) :: result()
  def resolve_policy(%State{} = state, awaitable_id, kind, label)
      when kind in [:accept, :reject] and is_atom(label) do
    case Enum.find(
           state.awaitables,
           &(&1.id == awaitable_id and &1.kind == :policy and &1.status == :open)
         ) do
      %Awaitable{} = awaitable ->
        resolve_policy_awaitable(state, awaitable, kind, label)

      nil ->
        {:error, :no_open_policy}
    end
  end

  def resolve_policy(%State{}, awaitable_id, kind, label),
    do: {:error, {:invalid_policy_resolution, awaitable_id, kind, label}}

  @doc """
  Records one unmatched policy response without resolving the policy.
  """
  @spec policy_attempt(State.t(), term()) :: result()
  def policy_attempt(%State{} = state, awaitable_id) do
    case Enum.find(state.awaitables, &(&1.id == awaitable_id)) do
      %Awaitable{kind: :policy, status: :open} = awaitable ->
        attempted = Awaitable.increment(awaitable)

        to =
          state
          |> Map.put(:awaitables, replace_awaitable(state.awaitables, attempted))
          |> put_trace(%{
            type: :policy_attempted,
            name: attempted.name,
            subject_id: attempted.subject_id,
            attempts: attempted.attempts,
            at: DateTime.utc_now()
          })

        {:ok,
         Transition.new(:policy_attempted, state, to,
           awaitable: attempted,
           entity_id: attempted.id,
           metadata: %{attempts: attempted.attempts}
         )}

      %Awaitable{} = awaitable ->
        {:error, {:invalid_awaitable_transition, awaitable.id, awaitable.status, :attempted}}

      nil ->
        {:error, :awaitable_not_found}
    end
  end

  @doc """
  Expires an open policy and cancels its gated work atomically.
  """
  @spec expire_policy(State.t(), term()) :: result()
  def expire_policy(%State{} = state, awaitable_id) do
    case Enum.find(state.awaitables, &(&1.id == awaitable_id)) do
      %Awaitable{kind: :policy, status: :open} = awaitable ->
        expired = Awaitable.expire(awaitable)

        cancelled =
          state.pending_effects
          |> Enum.find(&(&1.id == awaitable.subject_id))
          |> case do
            %Effect{} = effect -> Effect.cancel(effect, :policy_expired)
            nil -> nil
          end

        history =
          if cancelled,
            do: append_history(state.planned_effects, cancelled),
            else: state.planned_effects

        to =
          %{
            state
            | pending_effects:
                Enum.reject(state.pending_effects, &(&1.id == awaitable.subject_id)),
              planned_effects: history,
              awaitables: replace_awaitable(state.awaitables, expired)
          }
          |> put_trace(%{
            type: :awaitable_expired,
            kind: :policy,
            name: awaitable.name,
            subject_id: awaitable.subject_id,
            at: DateTime.utc_now()
          })

        {:ok,
         Transition.new(:policy_expired, state, to,
           effect: cancelled,
           awaitable: expired,
           entity_id: awaitable.id
         )}

      %Awaitable{} = awaitable ->
        {:error, {:invalid_awaitable_transition, awaitable.id, awaitable.status, :expired}}

      nil ->
        {:error, :awaitable_not_found}
    end
  end

  @doc """
  Removes a stale pending copy when the same effect already has a terminal
  history entry. No capability is invoked and the stored outcome is replayed.
  """
  @spec replay_effect(State.t(), term()) :: result()
  def replay_effect(%State{} = state, effect_id) do
    case terminal_effect(state, effect_id) do
      %Effect{} = effect ->
        to = %{state | pending_effects: Enum.reject(state.pending_effects, &(&1.id == effect_id))}

        {:ok,
         Transition.new(:effect_replayed, state, to,
           effect: effect,
           entity_id: effect.id,
           replayed?: true
         )}

      nil ->
        {:error, :resolved_effect_not_found}
    end
  end

  @doc false
  @spec clear_open_awaitables(State.t()) :: result()
  def clear_open_awaitables(%State{} = state) do
    to = %{state | awaitables: Enum.reject(state.awaitables, &(&1.status == :open))}
    {:ok, Transition.new(:open_awaitables_cleared, state, to)}
  end

  @doc false
  @spec clear_pending(State.t()) :: result()
  def clear_pending(%State{} = state) do
    {:ok, cleared} = clear_open_awaitables(state)
    to = %{cleared.to | pending_effects: []}
    {:ok, Transition.new(:pending_cleared, state, to)}
  end

  @doc false
  @spec replace_awaitable_transition(State.t(), Awaitable.t()) :: result()
  def replace_awaitable_transition(%State{} = state, %Awaitable{} = awaitable) do
    if Enum.any?(state.awaitables, &(&1.id == awaitable.id)) do
      to = %{state | awaitables: replace_awaitable(state.awaitables, awaitable)}

      {:ok,
       Transition.new(:awaitable_replaced, state, to,
         awaitable: awaitable,
         entity_id: awaitable.id
       )}
    else
      {:error, :awaitable_not_found}
    end
  end

  @spec resolve_policy_awaitable(State.t(), Awaitable.t(), :accept | :reject, atom()) :: result()
  defp resolve_policy_awaitable(state, awaitable, :accept, label) do
    with %Effect{} = effect <- pending_effect(state, awaitable.subject_id),
         :ok <- validate_policy_lifecycle_owner(effect, awaitable),
         true <- effect.status == :waiting_policy do
      approved = Effect.approve(effect)
      resolved = Awaitable.accept(awaitable, label)

      to =
        %{
          state
          | pending_effects: replace_effect(state.pending_effects, approved),
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
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_effect_transition, awaitable.subject_id, :unknown, :approved}}
    end
  end

  defp resolve_policy_awaitable(state, awaitable, :reject, label) do
    with %Effect{} = effect <- pending_effect(state, awaitable.subject_id),
         :ok <- validate_policy_lifecycle_owner(effect, awaitable),
         true <- effect.status == :waiting_policy do
      cancelled = Effect.cancel(effect, {:policy_rejected, label})
      resolved = Awaitable.reject(awaitable, label)

      to =
        %{
          state
          | pending_effects: Enum.reject(state.pending_effects, &(&1.id == awaitable.subject_id)),
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
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_effect_transition, awaitable.subject_id, :unknown, :cancelled}}
    end
  end

  defp validate_policy_lifecycle_owner(
         %Effect{run_id: run_id},
         %Awaitable{run_id: run_id}
       ),
       do: :ok

  defp validate_policy_lifecycle_owner(%Effect{}, %Awaitable{} = awaitable),
    do: {:error, {:policy_lifecycle_run_mismatch, awaitable.id, awaitable.run_id}}

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

  @spec append_pending([Effect.t()], Effect.t()) :: [Effect.t()]
  defp append_pending(_effects, %Effect{run_id: nil} = effect), do: [effect]
  defp append_pending(effects, %Effect{} = effect), do: effects ++ [effect]

  @spec append_awaitable([Awaitable.t()], Awaitable.t()) :: [Awaitable.t()]
  defp append_awaitable(_awaitables, %Awaitable{run_id: nil} = awaitable), do: [awaitable]

  defp append_awaitable(awaitables, %Awaitable{} = awaitable) do
    {open, terminal} = Enum.split_with(awaitables, &(&1.status == :open))
    terminal_limit = max(@awaitable_history_limit - length(open) - 1, 0)
    Enum.take(terminal, -terminal_limit) ++ open ++ [awaitable]
  end

  @spec pending_effect_for_run(State.t(), String.t() | nil) :: Effect.t() | nil
  defp pending_effect_for_run(state, nil), do: State.pending_effect(state)
  defp pending_effect_for_run(state, run_id), do: State.pending_effect(state, run_id)

  @spec replace_effect([Effect.t()], Effect.t()) :: [Effect.t()]
  defp replace_effect(effects, replacement) do
    Enum.map(effects, fn effect ->
      if effect.id == replacement.id, do: replacement, else: effect
    end)
  end

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
