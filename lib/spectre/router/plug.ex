defmodule Spectre.Router.Plug do
  @moduledoc """
  Behaviour for Spectre router pipeline stages.

  Router plugs receive a `%Spectre.Router.Context{}` and return either a
  continued context, a halted context, or an error. Most plugs add candidates or
  trace metadata; only terminal decision plugs should halt routing.

      defmodule MyApp.Router.Plugs.StaticHelp do
        @behaviour Spectre.Router.Plug

        @impl Spectre.Router.Plug
        def init(opts), do: opts

        @impl Spectre.Router.Plug
        def call(context, _opts) do
          {:cont, context}
        end
      end
  """

  @callback init(keyword()) :: term()

  @callback call(Spectre.Router.Context.t(), term()) ::
              {:cont, Spectre.Router.Context.t()}
              | {:halt, Spectre.Router.Context.t()}
              | {:error, term()}
end
