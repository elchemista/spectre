defmodule Spectre.State do
  @moduledoc """
  Conversation state owned by Spectre.

  State is the authoritative machine state for routing and effect safety. It
  tracks the current flow, pending effects, active awaitables, compact chat
  history, and trace events.
  """

  @state_version 4
  @max_trace_entries 256

  defstruct state_version: @state_version,
            revision: 0,
            conversation_id: nil,
            current_flow: nil,
            current_scope: nil,
            pending_effects: [],
            planned_effects: [],
            awaitables: [],
            memory_refs: [],
            data: %{},
            trace: []

  @type t :: %__MODULE__{
          state_version: pos_integer(),
          revision: non_neg_integer(),
          conversation_id: term(),
          current_flow: atom() | nil,
          current_scope: Spectre.Definition.scope() | nil,
          pending_effects: [Spectre.Effect.t()],
          planned_effects: [Spectre.Effect.t()],
          awaitables: [Spectre.Awaitable.t()],
          memory_refs: [term()],
          data: map(),
          trace: [term()]
        }

  @doc """
  Normalizes map, keyword, or nil input into a state struct.
  """
  @spec new(t() | map() | keyword() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = state), do: state
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs
    |> normalize_map()
    |> normalize_known_keys()
    |> migrate()
    |> Map.take(fields())
    |> then(&struct(__MODULE__, &1))
  end

  @doc """
  Returns true when the state is waiting for an active policy response.
  """
  @spec awaiting_policy?(t()) :: boolean()
  def awaiting_policy?(%__MODULE__{} = state), do: not is_nil(open_policy_awaitable(state))

  @doc """
  Stores a pending effect and optionally starts a policy gate for it.
  """
  @spec put_pending_effect(t(), Spectre.Effect.t(), term()) :: t()
  def put_pending_effect(%__MODULE__{} = state, %Spectre.Effect{} = effect, policy) do
    case Spectre.Lifecycle.stage(state, effect, policy) do
      {:ok, transition} ->
        transition.to

      {:error, reason} ->
        raise ArgumentError, "invalid Spectre lifecycle transition: #{inspect(reason)}"
    end
  end

  @doc """
  Clears open awaitables without removing pending effects.
  """
  @spec clear_open_awaitables(t()) :: t()
  def clear_open_awaitables(%__MODULE__{} = state) do
    {:ok, transition} = Spectre.Lifecycle.apply(state, :clear_open_awaitables)
    transition.to
  end

  @doc """
  Clears pending effects and open awaitables.
  """
  @spec clear_pending(t()) :: t()
  def clear_pending(%__MODULE__{} = state) do
    {:ok, transition} = Spectre.Lifecycle.apply(state, :clear_pending)
    transition.to
  end

  @doc """
  Cancels pending effects and appends a trace event.
  """
  @spec cancel_pending(t()) :: t()
  def cancel_pending(%__MODULE__{} = state) do
    {:ok, transition} = Spectre.Lifecycle.cancel_pending(state)
    transition.to
  end

  @doc """
  Returns the next effect in the execution queue, or `nil` when it is empty.

  Hosts normally use `Spectre.Result.pending_effect/1` on the value returned by
  `Spectre.ask/3` or `Spectre.turn/3`. This state-level helper is useful for
  adapters restoring persisted state.
  """
  @spec pending_effect(t()) :: Spectre.Effect.t() | nil
  def pending_effect(%__MODULE__{pending_effects: [effect | _]}), do: effect
  def pending_effect(%__MODULE__{}), do: nil

  @doc """
  Returns the currently open policy awaitable, if one exists.

  Closed, expired, and non-policy awaitables are ignored. Spectre enforces at
  most one active policy boundary during normal lifecycle transitions.
  """
  @spec open_policy_awaitable(t()) :: Spectre.Awaitable.t() | nil
  def open_policy_awaitable(%__MODULE__{} = state) do
    Enum.find(state.awaitables, &(&1.kind == :policy and &1.status == :open))
  end

  @doc """
  Replaces an awaitable through the validated lifecycle transition.

  Matching is performed by awaitable identifier. The function raises if the
  replacement would violate lifecycle invariants; application code should
  prefer the higher-level `Spectre.Lifecycle` operations unless implementing a
  state adapter or compatibility layer.
  """
  @spec replace_awaitable(t(), Spectre.Awaitable.t()) :: t()
  def replace_awaitable(%__MODULE__{} = state, %Spectre.Awaitable{} = awaitable) do
    {:ok, transition} = Spectre.Lifecycle.apply(state, {:replace_awaitable, awaitable})
    transition.to
  end

  @doc """
  Marks the policy-gated effect identified by an awaitable as approved.

  The effect remains pending so execution can happen at the explicit host
  boundary after this state transition has been persisted.
  """
  @spec approve_pending_effect(t(), term()) ::
          {:ok, t(), Spectre.Effect.t()}
          | {:error, :pending_effect_not_found | {:effect_not_waiting_policy, term(), atom()}}
  def approve_pending_effect(%__MODULE__{} = state, subject_id) do
    case Spectre.Lifecycle.approve_effect(state, subject_id) do
      {:ok, transition} ->
        {:ok, transition.to, transition.effect}

      {:error, {:invalid_effect_transition, id, status, :approved}} ->
        {:error, {:effect_not_waiting_policy, id, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Completes the next pending effect and returns `{state, completed_effect}`.

  If the queue is empty, the effect is `nil`. If the lifecycle rejects the
  transition, the original state and `nil` are returned. Runtime integrations
  should normally call `Spectre.execute/3`, which also enforces authorization,
  persistence, idempotency, and action execution boundaries.
  """
  @spec complete_pending_effect(t(), term()) :: {t(), Spectre.Effect.t() | nil}
  def complete_pending_effect(%__MODULE__{} = state, result) do
    case pending_effect(state) do
      nil ->
        {%{state | pending_effects: []}, nil}

      effect ->
        case Spectre.Lifecycle.complete_effect(state, effect.id, result) do
          {:ok, transition} -> {transition.to, transition.effect}
          {:error, _reason} -> {state, nil}
        end
    end
  end

  @doc """
  Marks the current pending effect as failed and clears it from the execution
  queue while preserving the failed transition in history.
  """
  @spec fail_pending_effect(t(), term()) :: {t(), Spectre.Effect.t() | nil}
  def fail_pending_effect(%__MODULE__{} = state, reason) do
    case pending_effect(state) do
      nil ->
        {%{state | pending_effects: []}, nil}

      effect ->
        case Spectre.Lifecycle.fail_effect(state, effect.id, reason) do
          {:ok, transition} -> {transition.to, transition.effect}
          {:error, _reason} -> {state, nil}
        end
    end
  end

  @doc """
  Finds a terminal transition for an effect identifier.

  This is used as a local idempotency guard when a restored state accidentally
  contains both a pending copy and an already resolved copy of the same effect.
  """
  @spec resolved_effect(t(), term()) :: Spectre.Effect.t() | nil
  def resolved_effect(%__MODULE__{} = state, effect_id) do
    state.planned_effects
    |> Enum.reverse()
    |> Enum.find(fn effect ->
      effect.id == effect_id and effect.status in [:completed, :failed, :cancelled]
    end)
  end

  @doc """
  Appends a compact chat-history entry under `state.data[:chat_history]`.
  """
  @spec record_turn(t(), Spectre.Input.t(), Spectre.Result.t(), pos_integer() | false | nil) ::
          t()
  def record_turn(%__MODULE__{} = state, _input, _result, limit)
      when limit in [nil, false, 0],
      do: state

  def record_turn(%__MODULE__{} = state, input, result, limit)
      when is_integer(limit) and limit > 0 do
    history =
      state.data
      |> Map.get(:chat_history, [])
      |> Kernel.++([history_entry(input, result)])
      |> Enum.take(-limit)

    %{state | data: Map.put(state.data, :chat_history, history)}
  end

  @doc """
  Prepends a compact trace event to the state.
  """
  @spec trace(t(), term()) :: t()
  def trace(%__MODULE__{} = state, event) do
    %{state | trace: Enum.take([event | state.trace], @max_trace_entries)}
  end

  @doc """
  Advances the optimistic-concurrency revision exactly once.
  """
  @spec bump_revision(t()) :: t()
  def bump_revision(%__MODULE__{revision: revision} = state)
      when is_integer(revision) and revision >= 0 do
    %{state | revision: revision + 1}
  end

  @spec history_entry(Spectre.Input.t(), Spectre.Result.t()) :: map()
  defp history_entry(input, result) do
    %{
      at: DateTime.utc_now(:second),
      user: input.text,
      assistant: result.reply_text,
      route: result.route && result.route.label,
      events: Enum.map(result.events, &Map.get(&1, :type))
    }
  end

  @spec migrate(map()) :: map()
  defp migrate(attrs) do
    if Map.has_key?(attrs, :pending_effects) or Map.has_key?(attrs, "pending_effects"),
      do: normalize_current(attrs),
      else: normalize_legacy(attrs)
  end

  @spec normalize_current(map()) :: map()
  defp normalize_current(attrs) do
    attrs
    |> normalize_list(:pending_effects, &Spectre.Effect.restore/1)
    |> normalize_list(:planned_effects, &Spectre.Effect.restore/1)
    |> normalize_list(:awaitables, &normalize_awaitable/1)
    |> Map.put(:state_version, @state_version)
    |> Map.put_new(:revision, 0)
  end

  @spec normalize_legacy(map()) :: map()
  defp normalize_legacy(attrs) do
    pending_action = Map.get(attrs, :pending_action) || Map.get(attrs, "pending_action")
    awaiting = Map.get(attrs, :awaiting) || Map.get(attrs, "awaiting")
    planned_actions = Map.get(attrs, :planned_actions) || Map.get(attrs, "planned_actions") || []

    effect = if pending_action, do: Spectre.Effect.restore(pending_action)
    awaitable = legacy_awaitable(awaiting, effect)

    attrs
    |> Map.put(:state_version, @state_version)
    |> Map.put_new(:revision, 0)
    |> Map.put(:pending_effects, List.wrap(effect))
    |> Map.put(:planned_effects, Enum.map(List.wrap(planned_actions), &Spectre.Effect.restore/1))
    |> Map.update!(:planned_effects, fn effects -> effects ++ List.wrap(effect) end)
    |> Map.put(:awaitables, List.wrap(awaitable))
    |> Map.drop([
      :pending_action,
      "pending_action",
      :planned_actions,
      "planned_actions",
      :awaiting,
      "awaiting"
    ])
  end

  @spec legacy_awaitable(term(), Spectre.Effect.t() | nil) :: Spectre.Awaitable.t() | nil
  defp legacy_awaitable(nil, _effect), do: nil

  defp legacy_awaitable(awaiting, effect) do
    map = normalize_map(awaiting)
    policy = Map.get(map, :policy) || Map.get(map, "policy")

    if policy && effect do
      policy
      |> Spectre.Awaitable.open_policy(effect)
      |> Map.put(:attempts, Map.get(map, :attempts) || Map.get(map, "attempts") || 0)
    end
  end

  @spec normalize_list(map(), atom(), (term() -> term())) :: map()
  defp normalize_list(attrs, key, mapper) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || []
    Map.put(attrs, key, Enum.map(List.wrap(value), mapper))
  end

  @spec normalize_awaitable(map() | struct()) :: Spectre.Awaitable.t()
  defp normalize_awaitable(%Spectre.Awaitable{} = awaitable), do: awaitable

  defp normalize_awaitable(attrs) do
    attrs = normalize_map(attrs)
    struct(Spectre.Awaitable, Map.take(attrs, awaitable_fields()))
  end

  @spec normalize_map(map() | struct()) :: map()
  defp normalize_map(%{__struct__: _} = attrs), do: Map.from_struct(attrs)
  defp normalize_map(attrs), do: attrs

  @spec normalize_known_keys(map()) :: map()
  defp normalize_known_keys(attrs) do
    Enum.reduce(fields(), attrs, fn key, normalized ->
      string_key = Atom.to_string(key)

      if Map.has_key?(normalized, string_key) and not Map.has_key?(normalized, key) do
        normalized
        |> Map.put(key, Map.fetch!(normalized, string_key))
        |> Map.delete(string_key)
      else
        normalized
      end
    end)
  end

  @spec awaitable_fields() :: [atom()]
  defp awaitable_fields do
    Spectre.Awaitable.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
