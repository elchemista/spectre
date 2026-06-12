defmodule Spectre.Router.Plug do
  @moduledoc """
  Behaviour for Spectre router pipeline stages.
  """

  @callback init(keyword()) :: term()

  @callback call(Spectre.Router.Context.t(), term()) ::
              {:cont, Spectre.Router.Context.t()}
              | {:halt, Spectre.Router.Context.t()}
              | {:error, term()}
end
