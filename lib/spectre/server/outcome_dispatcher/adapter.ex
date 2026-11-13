defmodule Spectre.Server.OutcomeDispatcher.Adapter do
  @moduledoc """
  Host bridge from durable operation references to a recovered result and Server.

  `recover/3` reauthenticates and rebinds the appropriate GAM Scope, then reads
  recorded results, for example through `Spectre.GAM.recover_proposal/2`.
  It never resubmits an effect. Its event reference identifies a durable result
  revision. When a non-nil reference is requested it must recover that exact
  revision, not silently substitute a more recent result.

  `deliver/4` locates or restarts the target Server and calls
  `Spectre.Server.deliver(server, event_id, tag, result)`. It acknowledges only
  after the receiver has acquired the event, its checkpoint and commands.
  Delivery may repeat after any crash; receiver inbox deduplication is required.
  Neither a binding nor an event id authenticates an Outcome by itself.
  """

  @callback recover(map(), String.t() | nil, keyword()) ::
              {:ok, String.t(), term()} | :pending | {:error, term()}
  @callback deliver(map(), String.t(), term(), keyword()) :: :ok | {:error, term()}
end
