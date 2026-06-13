defmodule Spectre.Input.Plug do
  @moduledoc """
  Behaviour for Spectre input normalization/enrichment stages.

  Input plugs run before state, memory, policy, router, checks, prompt rendering,
  and action execution see the turn.
  """

  @callback init(keyword()) :: term()

  @callback call(Spectre.Input.t(), map(), term()) ::
              {:cont, Spectre.Input.t()}
              | {:halt, Spectre.Input.t()}
              | {:error, term()}
end
