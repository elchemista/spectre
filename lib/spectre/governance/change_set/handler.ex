defmodule Spectre.Governance.ChangeSet.Handler do
  @moduledoc """
  Trusted implementation boundary for registered ChangeSet operations.

  Implementations are compiled modules selected by a host-owned Registry. A
  handler declares every operation type and component class it may modify.
  """

  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition

  @callback operation_types() :: [String.t()]
  @callback component_classes() :: [atom()]
  @callback apply(Operation.t(), Composition.t(), map()) ::
              {:ok, Composition.t()} | {:error, term()}
end
