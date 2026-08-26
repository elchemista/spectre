defmodule Spectre.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Spectre.Instance.Registry},
      {Spectre.Subject.Registry, name: Spectre.Subject.Registry},
      {Registry, keys: :duplicate, name: Spectre.Operation.EventRegistry},
      {Registry, keys: :unique, name: Spectre.Inference.StreamRegistry},
      Spectre.Inference.StreamCapacity,
      Spectre.Router.SemanticCache.Owner,
      Spectre.Operation.RunnerSupervisor,
      {Task.Supervisor, name: Spectre.Instance.BootTaskSupervisor},
      Spectre.Instance.BootCapacity,
      {Task.Supervisor, name: Spectre.Operation.TaskSupervisor},
      {Task.Supervisor, name: Spectre.Instance.CheckpointTaskSupervisor},
      {Task.Supervisor, name: Spectre.Receipt.TaskSupervisor},
      {Task.Supervisor, name: Spectre.Journal.TaskSupervisor},
      Spectre.Stack.Runtime.ResourceCache,
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
