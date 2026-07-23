defmodule Spectre.Turn.Handler do
  @moduledoc """
  Optional boundary through which another runtime may own a normal turn before
  Spectre routes it.

  Handlers form an ordered pipeline. Each handler returns `:cont` when Spectre
  should consult the next handler and eventually its normal router, or
  `{:reply, reply}` when that integration owns the current request. A handler
  cannot inject Spectre state, routes, effects, or awaitables; it can only
  provide a typed `Spectre.Turn.Handler.Reply`.

  This is a chain-of-responsibility extension, not Spectre's universal turn
  protocol. `Spectre.turn/3` and `Spectre.Turn.decision()` are the canonical
  local host contract. A Directive mission, FSM, GenServer, or other stateful
  runtime should implement this behaviour only when it temporarily owns the
  user dialogue. Specialized integrations should still prefer Spectre's
  narrower memory, action, prompt, input, Skill, and telemetry/journal ports.

  Distributed protocol concerns such as sender and recipient addresses,
  correlation, task identity, retries, and delivery guarantees deliberately do
  not live here.
  """

  alias Spectre.Turn.Handler.Reply
  alias Spectre.Turn.Handler.Request

  @type response :: :cont | {:reply, Reply.t()} | {:error, term()}

  @doc "Inspects one loaded request and either continues or owns the turn."
  @callback handle_turn(Request.t(), keyword()) :: response()
end
