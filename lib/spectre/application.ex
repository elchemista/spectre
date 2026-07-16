defmodule Spectre.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Spectre.Router.SemanticCache.Owner,
      {Task.Supervisor, name: Spectre.Journal.TaskSupervisor},
      Spectre.Journal.Buffer
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Spectre.ApplicationSupervisor
    )
  end
end
