defmodule Spectre.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Spectre.Router.SemanticCache.Owner
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Spectre.ApplicationSupervisor
    )
  end
end
