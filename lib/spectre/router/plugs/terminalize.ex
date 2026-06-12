defmodule Spectre.Router.Plugs.Terminalize do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.{Context, Support}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{route: nil} = context, _state), do: {:cont, context}

  def call(%Context{route: route, opts: opts} = context, _state) do
    {:halt, %{context | route: Support.terminalize(route, opts)}}
  end
end
