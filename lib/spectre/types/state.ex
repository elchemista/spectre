defmodule Spectre.State do
  @moduledoc """
  Conversation state owned by Spectre.
  """

  defstruct [
    :conversation_id,
    :current_flow,
    pending_action: nil,
    planned_actions: [],
    awaiting: nil,
    memory_refs: [],
    data: %{},
    trace: []
  ]

  @type t :: %__MODULE__{
          conversation_id: term(),
          current_flow: atom() | nil,
          pending_action: Spectre.PendingAction.t() | nil,
          planned_actions: [Spectre.PendingAction.t()],
          awaiting: Spectre.Awaiting.t() | nil,
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
  def new(attrs) when is_map(attrs), do: struct(__MODULE__, Map.take(attrs, fields()))

  @doc """
  Returns true when the state is waiting for an active policy response.
  """
  @spec awaiting_policy?(t()) :: boolean()
  def awaiting_policy?(%__MODULE__{awaiting: %Spectre.Awaiting{kind: :policy}}), do: true
  def awaiting_policy?(_state), do: false

  @doc """
  Stores a pending action and optionally starts a policy gate for it.
  """
  @spec put_pending(t(), Spectre.PendingAction.t(), atom() | nil) :: t()
  def put_pending(%__MODULE__{} = state, pending_action, nil) do
    %{
      state
      | pending_action: pending_action,
        planned_actions: append_planned(state.planned_actions, pending_action)
    }
  end

  def put_pending(%__MODULE__{} = state, pending_action, policy) when is_atom(policy) do
    pending_action = %{pending_action | policy: policy, status: :waiting_policy}

    %{
      state
      | pending_action: pending_action,
        planned_actions: append_planned(state.planned_actions, pending_action),
        awaiting: Spectre.Awaiting.policy(policy, pending_action.id)
    }
  end

  @doc """
  Clears the active awaiting marker without removing the pending action.
  """
  @spec clear_awaiting(t()) :: t()
  def clear_awaiting(%__MODULE__{} = state), do: %{state | awaiting: nil}

  @doc """
  Clears the pending action and any awaiting marker.
  """
  @spec clear_pending(t()) :: t()
  def clear_pending(%__MODULE__{} = state), do: %{state | pending_action: nil, awaiting: nil}

  @doc """
  Cancels the pending action and appends a trace event.
  """
  @spec cancel_pending(t()) :: t()
  def cancel_pending(%__MODULE__{} = state) do
    state
    |> clear_pending()
    |> trace(%{type: :cancel_pending, at: DateTime.utc_now()})
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
  Prepends a trace event to the state.
  """
  @spec trace(t(), term()) :: t()
  def trace(%__MODULE__{} = state, event), do: %{state | trace: [event | state.trace]}

  @spec append_planned([Spectre.PendingAction.t()], Spectre.PendingAction.t()) :: [
          Spectre.PendingAction.t()
        ]
  defp append_planned(actions, action) do
    actions
    |> Enum.take(-31)
    |> Kernel.++([action])
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

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
