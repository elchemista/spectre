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
      # One failure burst can legitimately take down the cache owner, its
      # linked collection owners, and both journal workers. Keep the
      # application alive for that bounded burst while still stopping a
      # genuinely looping child.
      max_restarts: 10,
      max_seconds: 5,
      name: Spectre.ApplicationSupervisor
    )
  end
end
