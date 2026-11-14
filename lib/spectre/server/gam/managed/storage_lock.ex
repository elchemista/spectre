defmodule Spectre.Server.GAM.Managed.StorageLock do
  @moduledoc false
  use GenServer

  # This is local filesystem ownership, not a distributed filesystem fence.
  # Device/inode identity makes symlink aliases share one owner on this BEAM.
  # Disconnected nodes sharing a disk still need deployment-level fencing.
  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    case File.stat(Keyword.fetch!(opts, :path)) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        state = %{
          name: {__MODULE__, node(), stat.major_device, stat.minor_device, stat.inode},
          runtime: Keyword.get(opts, :runtime),
          drain_timeout: min(Keyword.get(opts, :shutdown_timeout, 30_000) + 5_000, 4_294_967_295)
        }

        case acquire(state.name) do
          :ok -> {:ok, state}
          {:error, reason} -> {:stop, reason}
        end

      _ ->
        {:stop, :invalid_managed_storage_directory}
    end
  end

  @impl true
  def handle_call(:owner, _from, state), do: {:reply, state, state}

  @impl true
  def terminate(_reason, state) do
    :global.unregister_name(state.name)
    :ok
  end

  @spec acquire(term()) :: :ok | {:error, atom()}
  defp acquire(name) do
    case :global.register_name(name, self()) do
      :yes -> :ok
      :no -> await_draining_owner(name, :global.whereis_name(name))
    end
  end

  @spec await_draining_owner(term(), pid() | :undefined) :: :ok | {:error, atom()}
  defp await_draining_owner(name, owner) when is_pid(owner) do
    case GenServer.call(owner, :owner, 1_000) do
      %{runtime: runtime, drain_timeout: timeout} when is_pid(runtime) ->
        if Process.alive?(runtime),
          do: {:error, :managed_storage_path_in_use},
          else: await_release(name, owner, timeout)

      _ ->
        {:error, :managed_storage_path_in_use}
    end
  catch
    :exit, _ ->
      if Process.alive?(owner),
        do: {:error, :managed_storage_path_in_use},
        else: claim_released(name)
  end

  defp await_draining_owner(name, :undefined), do: claim_released(name)

  @spec await_release(term(), pid(), pos_integer()) :: :ok | {:error, atom()}
  defp await_release(name, owner, timeout) do
    monitor = Process.monitor(owner)

    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> claim_released(name)
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :managed_storage_drain_timeout}
    end
  end

  @spec claim_released(term()) :: :ok | {:error, atom()}
  defp claim_released(name) do
    case :global.register_name(name, self()) do
      :yes -> :ok
      :no -> {:error, :managed_storage_path_in_use}
    end
  end
end
