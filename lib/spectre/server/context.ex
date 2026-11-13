defmodule Spectre.Server.Context do
  @moduledoc """
  Application view of a Server dispatch.

  `assigns`, process-local `private` data and commands added by the Server
  helpers are acquired on return. `private` may hold timer/monitor references
  and actor handles; it is never checkpointed or sent to cognitive services.
  Identity, input and pending fields are read-only views. The dispatch
  token detects accidentally returning a context from another callback; it is
  not a security boundary against code in the same BEAM process.
  """
  defstruct agent: nil,
            assigns: %{},
            private: %{},
            identity: %{},
            interaction: nil,
            input: nil,
            routing: %{},
            memory: nil,
            pending: nil,
            pending_by_id: %{},
            commands: [],
            dispatch_token: nil

  @type t :: %__MODULE__{}
end
