defmodule Spectre.Governance.ChangeSet.Handler do
  @moduledoc """
  Trusted implementation boundary for registered ChangeSet operations.

  Implementations are compiled modules selected by a host-owned Registry. A
  handler declares every operation type and component class it may modify.
  """

  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition

  @doc "Lists the ChangeSet operation names handled by this module."
  @callback operation_types() :: [String.t()]

  @doc "Lists all component classes that operations from this handler may modify."
  @callback component_classes() :: [atom()]

  @doc "Applies one registered operation to the current composition using the host context."
  @callback apply(Operation.t(), Composition.t(), map()) ::
              {:ok, Composition.t()} | {:error, term()}
end
