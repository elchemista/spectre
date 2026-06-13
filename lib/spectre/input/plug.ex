defmodule Spectre.Input.Plug do
  @moduledoc """
  Behaviour for Spectre input normalization/enrichment stages.

  Input plugs run before state, memory, policy, router, checks, prompt rendering,
  and action execution see the turn.

  Example:

      defmodule MyApp.LocalePlug do
        @behaviour Spectre.Input.Plug

        @impl Spectre.Input.Plug
        def init(opts), do: opts

        @impl Spectre.Input.Plug
        def call(input, _context, _opts) do
          {:cont, Spectre.Input.put_meta(input, :locale, "en")}
        end
      end
  """

  @callback init(keyword()) :: term()

  @callback call(Spectre.Input.t(), map(), term()) ::
              {:cont, Spectre.Input.t()}
              | {:halt, Spectre.Input.t()}
              | {:error, term()}
end
