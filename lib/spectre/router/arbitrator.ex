defmodule Spectre.Router.Arbitrator do
  @moduledoc """
  Behaviour for final route selection from collected routing evidence.

  Arbitrators keep route selection policy separate from evidence providers.
  This allows applications to customize conflict handling without replacing the
  regex/cache/classifier/embedding plugs.

      defmodule MyApp.Router.Arbitrator do
        @behaviour Spectre.Router.Arbitrator

        @impl Spectre.Router.Arbitrator
        def decide(arbitration, _opts) do
          {:ok, hd(arbitration.candidates) |> Spectre.Router.Candidate.to_route()}
        end
      end
  """

  @callback decide(Spectre.Router.Arbitration.t(), keyword()) ::
              {:ok, Spectre.Route.t()}
              | {:llm, Spectre.Router.Arbitration.t()}
              | {:clarify, String.t()}
              | {:error, term()}
end
