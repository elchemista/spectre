defmodule Spectre.Router.Arbitrator do
  @moduledoc """
  Behaviour for final route selection from collected routing evidence.
  """

  @callback decide(Spectre.Router.Arbitration.t(), keyword()) ::
              {:ok, Spectre.Route.t()}
              | {:llm, Spectre.Router.Arbitration.t()}
              | {:clarify, String.t()}
              | {:error, term()}
end
