defmodule Spectre.Result do
  @moduledoc """
  Output of a handled turn.

  Results carry everything the host boundary needs after a turn: user-visible
  reply text, updated state, effects, awaitables, route metadata, and events
  for logging.

      {:ok, %Spectre.Result{reply_text: text, state: state}} =
        Spectre.ask(MyAgent, "hello")
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.State

  defstruct [
    :input,
    :route,
    :state,
    reply_text: "",
    effects: [],
    awaitables: [],
    events: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          input: Spectre.Input.t() | nil,
          route: Spectre.Route.t() | nil,
          state: Spectre.State.t() | nil,
          reply_text: String.t(),
          effects: [Spectre.Effect.t()],
          awaitables: [Spectre.Awaitable.t()],
          events: [term()],
          metadata: map()
        }

  @doc """
  Returns the active awaitable from authoritative state, falling back to the
  transition-local awaitables carried by the result.
  """
  @spec open_awaitable(t()) :: Awaitable.t() | nil
  def open_awaitable(%__MODULE__{state: %State{} = state}) do
    State.open_policy_awaitable(state)
  end

  def open_awaitable(%__MODULE__{awaitables: awaitables}) do
    Enum.find(awaitables, &(&1.status == :open))
  end

  @doc """
  Returns the current pending effect from authoritative state, or from a
  state-less result assembled by a host.
  """
  @spec pending_effect(t()) :: Effect.t() | nil
  def pending_effect(%__MODULE__{state: %State{} = state}), do: State.pending_effect(state)

  def pending_effect(%__MODULE__{effects: effects}) do
    Enum.find(effects, &(&1.status in [:pending, :waiting_policy, :approved]))
  end

  @doc """
  Returns every terminal lifecycle transition emitted by this result.
  """
  @spec completions(t()) :: [Effect.t() | Awaitable.t()]
  def completions(%__MODULE__{effects: effects, awaitables: awaitables}) do
    terminal_effects = Enum.filter(effects, &Effect.terminal?/1)

    terminal_awaitables =
      Enum.filter(awaitables, &(&1.status in [:accepted, :rejected, :cancelled, :expired]))

    terminal_effects ++ terminal_awaitables
  end

  @doc """
  Returns the completion with the same precedence used by turn decisions:
  effect transitions first, then awaitables.
  """
  @spec latest_completion(t()) :: Effect.t() | Awaitable.t() | nil
  def latest_completion(%__MODULE__{effects: effects, awaitables: awaitables}) do
    Enum.find(Enum.reverse(effects), &Effect.terminal?/1) ||
      Enum.find(
        Enum.reverse(awaitables),
        &(&1.status in [:accepted, :rejected, :cancelled, :expired])
      )
  end

  @doc """
  Normalizes the latest terminal action effect into a host-facing outcome.
  """
  @spec action_outcome(t()) :: Effect.outcome()
  def action_outcome(%__MODULE__{effects: effects}) do
    effects
    |> Enum.reverse()
    |> Enum.find(&(&1.kind == :action and Effect.terminal?(&1)))
    |> case do
      %Effect{} = effect -> Effect.outcome(effect)
      nil -> nil
    end
  end

  @doc """
  Returns whether the result contains non-blank user-visible reply text.
  """
  @spec visible_reply?(t()) :: boolean()
  def visible_reply?(%__MODULE__{reply_text: text}) when is_binary(text),
    do: String.trim(text) != ""

  def visible_reply?(%__MODULE__{}), do: false

  @doc """
  Returns a compact, normalized lifecycle view for host turn dispatch.
  """
  @spec lifecycle(t()) :: map()
  def lifecycle(%__MODULE__{} = result) do
    %{
      open_awaitable: open_awaitable(result),
      pending_effect: pending_effect(result),
      completions: completions(result),
      latest_completion: latest_completion(result),
      action_outcome: action_outcome(result),
      visible_reply?: visible_reply?(result)
    }
  end
end
