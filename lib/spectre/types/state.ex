defmodule Spectre.State do
  @moduledoc """
  Conversation state owned by Spectre.

  State is the authoritative machine state for routing and effect safety. It
  tracks the current flow, pending effects, active awaitables, compact chat
  history, and trace events.
  """

  defstruct state_version: 2,
            conversation_id: nil,
            current_flow: nil,
            pending_effects: [],
            planned_effects: [],
            awaitables: [],
            memory_refs: [],
            data: %{},
            trace: []

  @type t :: %__MODULE__{
          state_version: pos_integer(),
          conversation_id: term(),
          current_flow: atom() | nil,
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
  @spec put_pending_effect(t(), Spectre.Effect.t(), atom() | nil) :: t()
  def put_pending_effect(%__MODULE__{} = state, %Spectre.Effect{} = effect, nil) do
    effect = %{effect | status: :pending}

    %{
      state
      | pending_effects: [effect],
        planned_effects: append_planned(state.planned_effects, effect)
    }
  end

  def put_pending_effect(%__MODULE__{} = state, %Spectre.Effect{} = effect, policy)
      when is_atom(policy) do
    effect = Spectre.Effect.waiting_policy(effect, policy)
    awaitable = Spectre.Awaitable.open_policy(policy, effect)

    %{
      state
      | pending_effects: [effect],
        planned_effects: append_planned(state.planned_effects, effect),
        awaitables: [awaitable]
    }
  end

  @doc """
  Clears open awaitables without removing pending effects.
  """
  @spec clear_open_awaitables(t()) :: t()
  def clear_open_awaitables(%__MODULE__{} = state) do
    %{state | awaitables: Enum.reject(state.awaitables, &(&1.status == :open))}
  end

  @doc """
  Clears pending effects and open awaitables.
  """
  @spec clear_pending(t()) :: t()
  def clear_pending(%__MODULE__{} = state) do
    %{
      state
      | pending_effects: [],
        awaitables: Enum.reject(state.awaitables, &(&1.status == :open))
    }
  end

  @doc """
  Cancels pending effects and appends a trace event.
  """
  @spec cancel_pending(t()) :: t()
  def cancel_pending(%__MODULE__{} = state) do
    cancelled_effects =
      Enum.map(state.pending_effects, &Spectre.Effect.cancel(&1, :cancel_pending))

    awaitables = Enum.map(state.awaitables, &cancel_open/1)

    %{
      state
      | pending_effects: [],
        awaitables: awaitables,
        planned_effects: Enum.take(state.planned_effects, -31) ++ cancelled_effects
    }
    |> trace(%{type: :cancel_pending, at: DateTime.utc_now()})
  end

  @spec pending_effect(t()) :: Spectre.Effect.t() | nil
  def pending_effect(%__MODULE__{pending_effects: [effect | _]}), do: effect
  def pending_effect(%__MODULE__{}), do: nil

  @spec open_policy_awaitable(t()) :: Spectre.Awaitable.t() | nil
  def open_policy_awaitable(%__MODULE__{} = state) do
    Enum.find(state.awaitables, &(&1.kind == :policy and &1.status == :open))
  end

  @spec replace_awaitable(t(), Spectre.Awaitable.t()) :: t()
  def replace_awaitable(%__MODULE__{} = state, %Spectre.Awaitable{} = awaitable) do
    awaitables =
      state.awaitables
      |> Enum.reject(&(&1.id == awaitable.id))
      |> Kernel.++([awaitable])

    %{state | awaitables: awaitables}
  end

  @spec complete_pending_effect(t(), term()) :: {t(), Spectre.Effect.t() | nil}
  def complete_pending_effect(%__MODULE__{} = state, result) do
    case pending_effect(state) do
      nil ->
        {%{state | pending_effects: []}, nil}

      effect ->
        completed = Spectre.Effect.complete(effect, result)

        {%{
           state
           | pending_effects: [],
             planned_effects: append_planned(state.planned_effects, completed)
         }, completed}
    end
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
  def trace(%__MODULE__{} = state, event), do: %{state | trace: [event | state.trace]}

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

  @spec append_planned([Spectre.Effect.t()], Spectre.Effect.t()) :: [Spectre.Effect.t()]
  defp append_planned(effects, effect) do
    effects
    |> Enum.take(-31)
    |> Kernel.++([effect])
  end

  @spec cancel_open(Spectre.Awaitable.t()) :: Spectre.Awaitable.t()
  defp cancel_open(%Spectre.Awaitable{status: :open} = awaitable),
    do: Spectre.Awaitable.cancel(awaitable)

  defp cancel_open(awaitable), do: awaitable

  @spec migrate(map()) :: map()
  defp migrate(attrs) do
    if Map.has_key?(attrs, :pending_effects) or Map.has_key?(attrs, "pending_effects"),
      do: normalize_current(attrs),
      else: normalize_legacy(attrs)
  end

  @spec normalize_current(map()) :: map()
  defp normalize_current(attrs) do
    attrs
    |> normalize_list(:pending_effects, &Spectre.Effect.stage/1)
    |> normalize_list(:planned_effects, &Spectre.Effect.stage/1)
    |> normalize_list(:awaitables, &normalize_awaitable/1)
    |> Map.put(:state_version, 2)
  end

  @spec normalize_legacy(map()) :: map()
  defp normalize_legacy(attrs) do
    pending_action = Map.get(attrs, :pending_action) || Map.get(attrs, "pending_action")
    awaiting = Map.get(attrs, :awaiting) || Map.get(attrs, "awaiting")
    planned_actions = Map.get(attrs, :planned_actions) || Map.get(attrs, "planned_actions") || []

    effect = if pending_action, do: Spectre.Effect.stage(pending_action)
    awaitable = legacy_awaitable(awaiting, effect)

    attrs
    |> Map.put(:state_version, 2)
    |> Map.put(:pending_effects, List.wrap(effect))
    |> Map.put(:planned_effects, Enum.map(List.wrap(planned_actions), &Spectre.Effect.stage/1))
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
