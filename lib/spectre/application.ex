defmodule Spectre.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    # Order is part of the lifetime boundary. A Registry restart invalidates
    # every downstream runtime, and losing the passthrough claim store also
    # invalidates Domains which could still hold one of its checkout receipts.
    children = [
      {Registry, keys: :unique, name: Spectre.Domain.Registry},
      Spectre.Secret.Broker.Passthrough,
      {Spectre.Domain.Supervisor, name: Spectre.Domain.Supervisor}
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: Spectre.ApplicationSupervisor
    )
  end
end
