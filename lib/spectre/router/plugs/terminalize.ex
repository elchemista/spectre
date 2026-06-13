defmodule Spectre.Router.Plugs.Terminalize do
  @moduledoc """
  Applies terminal-route metadata after arbitration.

  Terminalization is deliberately late in the pipeline: it should not influence
  how evidence is collected, only whether the accepted route is strong enough to
  end a flow or escalate.
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{route: nil} = context, _state), do: {:cont, context}

  def call(%Context{route: route, opts: opts} = context, _state) do
    {:halt, %{context | route: Support.terminalize(route, opts)}}
  end
end
