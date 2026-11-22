defmodule Spectre.Server.Context do
  @moduledoc """
  Application view of a Server dispatch.

  Use the Context passed into the current callback and return it after applying
  any helpers.

  - `agent` identifies the Agent module. `identity` and `session` identify the
    application principal and the active runtime session.
  - `input` contains the normalized turn and `interaction` correlates it with
    consumer events. Both can be absent in native OTP callbacks. `routing`
    carries the selected route and metadata including named captures under
    `:params`, when present.
  - `skill` and `activity` identify the current mounted Skill or Activity.
    An Activity Context carries its execution reference, key and revision.
  - `memory` contains the retrieval result attached to the turn. `pending`
    is the focused wait. `Spectre.Server.get_pending/2` reads any known wait.
  - Use `Spectre.Server.assign/3` for portable state and
    `Spectre.Server.put_private/3` for process-local handles. The runtime
    acquires these fields and queued commands when the callback returns.

  The runtime owns the dispatch token, command ordering and wait state.
  """
  defstruct agent: nil,
            assigns: %{},
            private: %{},
            identity: %{},
            session: nil,
            skill: nil,
            activity: nil,
            interaction: nil,
            input: nil,
            routing: %{},
            memory: nil,
            pending: nil,
            pending_by_id: %{},
            commands: [],
            dispatch_token: nil

  @typedoc "A Context passed to an application callback."
  @type t :: %__MODULE__{
          agent: module() | nil,
          assigns: map(),
          private: map(),
          identity: map(),
          session: binary() | nil,
          skill: map() | nil,
          activity: %{ref: binary(), key: atom() | nil, revision: non_neg_integer()} | nil,
          interaction: binary() | nil,
          input: Spectre.Input.t() | nil,
          routing: map(),
          memory: term(),
          pending: map() | nil,
          pending_by_id: map(),
          commands: [struct()],
          dispatch_token: reference() | nil
        }
end
