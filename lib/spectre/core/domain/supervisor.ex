defmodule Spectre.Domain.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  @doc "Starts the dynamic Domain owner; this is supervision, not foundation recognition."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts one Domain child through its ordinary child spec and full bootstrap/recovery boundary."
  @spec start_domain(keyword()) :: DynamicSupervisor.on_start_child()
  def start_domain(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Spectre.Domain, opts})
  end
end
