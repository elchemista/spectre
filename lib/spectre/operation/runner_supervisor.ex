defmodule Spectre.Operation.RunnerSupervisor do
  @moduledoc "Dynamic supervisor for isolated, temporary runtime workers."

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_runner(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_runner(supervisor \\ __MODULE__, opts) when is_list(opts) do
    DynamicSupervisor.start_child(supervisor, {Spectre.Operation.Runner, opts})
  end

  @doc false
  @spec start_stream_session(GenServer.server(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_stream_session(supervisor \\ __MODULE__, opts) when is_list(opts) do
    DynamicSupervisor.start_child(supervisor, {Spectre.Inference.StreamSession, opts})
  end

  @spec stop_runner(GenServer.server(), pid()) :: :ok | {:error, term()}
  def stop_runner(supervisor \\ __MODULE__, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end
end
