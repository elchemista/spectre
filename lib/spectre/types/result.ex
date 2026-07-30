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
  def open_awaitable(%__MODULE__{} = result) do
    open_awaitable(result, lifecycle_run_id(result))
  end

  @doc false
  @spec open_awaitable(t(), String.t() | nil) :: Awaitable.t() | nil
  def open_awaitable(%__MODULE__{state: %State{} = state}, run_id) do
    State.open_policy_awaitable(state, run_id)
  end

  def open_awaitable(%__MODULE__{awaitables: awaitables}, run_id) do
    Enum.find(awaitables, fn awaitable ->
      awaitable.status == :open and (is_nil(run_id) or awaitable.run_id == run_id)
    end)
  end

  @doc """
  Returns the current pending effect from authoritative state, or from a
  state-less result assembled by a host.
  """
  @spec pending_effect(t()) :: Effect.t() | nil
  def pending_effect(%__MODULE__{} = result) do
    pending_effect(result, lifecycle_run_id(result))
  end

  @doc false
  @spec pending_effect(t(), String.t() | nil) :: Effect.t() | nil
  def pending_effect(%__MODULE__{state: %State{} = state}, run_id),
    do: State.pending_effect(state, run_id)

  def pending_effect(%__MODULE__{effects: effects}, run_id) do
    Enum.find(effects, fn effect ->
      effect.status in [:pending, :waiting_policy, :approved] and
        (is_nil(run_id) or effect.run_id == run_id)
    end)
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
  def lifecycle(%__MODULE__{} = result), do: Spectre.Lifecycle.projection(result)

  @spec lifecycle_run_id(t()) :: String.t() | nil
  defp lifecycle_run_id(%__MODULE__{} = result) do
    case Map.get(result.metadata, :lifecycle_run_id) do
      run_id when is_binary(run_id) ->
        run_id

      _missing ->
        Enum.find_value(result.effects, & &1.run_id) ||
          Enum.find_value(result.awaitables, & &1.run_id)
    end
  end
end
