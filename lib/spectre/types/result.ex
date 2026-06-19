defmodule Spectre.Result do
  @moduledoc """
  Output of a handled turn.

  Results carry everything the host boundary needs after a turn: user-visible
  reply text, updated state, effects, awaitables, route metadata, and events
  for logging.

      {:ok, %Spectre.Result{reply_text: text, state: state}} =
        Spectre.ask(MyAgent, "hello")
  """

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
end
