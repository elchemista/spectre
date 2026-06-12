defmodule Spectre.Result do
  @moduledoc """
  Output of a handled turn.
  """

  defstruct [
    :input,
    :route,
    :state,
    reply_text: "",
    actions: [],
    events: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          input: Spectre.Input.t() | nil,
          route: Spectre.Route.t() | nil,
          state: Spectre.State.t() | nil,
          reply_text: String.t(),
          actions: [Spectre.PendingAction.t()],
          events: [term()],
          metadata: map()
        }
end
