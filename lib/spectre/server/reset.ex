defmodule Spectre.Server.Reset do
  @moduledoc false

  alias Spectre.Server.{Runtime, Session, Skills, TaskGuard, Tool}
  alias Spectre.Server.GAM.Managed

  @doc false
  @spec options(term()) :: {:ok, keyword()} | {:error, atom()}
  def options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:storage, :timeout] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.get(opts, :storage, :configured) in [:configured, :ephemeral] and
         is_integer(Keyword.get(opts, :timeout, 30_000)) and
         Keyword.get(opts, :timeout, 30_000) in 1..4_294_967_295,
       do: {:ok, opts},
       else: {:error, :invalid_reset_options}
  end

  def options(_), do: {:error, :invalid_reset_options}

  @doc false
  @spec available(map(), (atom() -> boolean())) :: :ok | {:error, atom()}
  def available(state, governed?) do
    busy =
      map_size(state.operations) > 0 or
        Enum.any?(state.workers, fn {_ref, worker} ->
          governed?.(worker.kind) or match?(%{tool_identity: %{retry: :never}}, worker)
        end) or
        Enum.any?(state.pending, fn {_id, pending} ->
          pending.status in [:resolving, :uncertain]
        end) or
        Enum.any?(state.outbox, fn {_id, entry} ->
          Map.has_key?(entry, :lifecycle) or
            (entry.execution_started and Tool.never?(entry.command))
        end)

    if busy, do: {:error, :reset_busy}, else: :ok
  end

  @doc false
  @spec start(map(), GenServer.from(), keyword()) :: {:ok, map()}
  def start(state, from, opts) do
    parent = self()
    token = make_ref()
    control = make_ref()
    staging = Map.take(state, [:agent, :skill_supervisor, :managed_owner, :control])

    {:ok, pid} =
      Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
        result =
          with {:ok, _guard} <- TaskGuard.start(parent, self()),
               do: stage(staging, opts, parent, token, control)

        send(parent, {Runtime, staging.control, :reset_ready, token, result})

        if match?({:ok, _, _}, result) do
          receive do
            {^token, :adopted} -> :ok
          end
        end
      end)

    timer =
      Process.send_after(
        parent,
        {Runtime, state.control, :reset_timeout, token},
        Keyword.get(opts, :timeout, 30_000)
      )

    {:ok,
     %{
       from: from,
       pid: pid,
       monitor: Process.monitor(pid),
       timer: timer,
       token: token,
       control: control,
       deferred: [],
       phase: :preparing,
       owner: nil
     }}
  end

  defp stage(state, opts, parent, token, control) do
    with :ok <- freeze_skills(state),
         {:ok, info} <- Managed.prepare_reset(state.managed_owner, state.control),
         mode = if(opts[:storage] == :ephemeral, do: :memory, else: info.session.mode),
         {:ok, candidate, managed_opts} <- Session.prepare(info.session, mode),
         managed_opts =
           managed_opts
           |> Keyword.put(:runtime_control, control)
           |> Keyword.put(:bootstrap_owner, self()),
         {:ok, owner} <- Managed.start_link(managed_opts) do
      send(parent, {Runtime, state.control, :reset_activating, token, owner})

      # The owner must record the irreversible phase before the CAS can start.
      receive do
        {^token, :activate} -> :ok
      end

      case Session.activate(candidate) do
        {:ok, active} ->
          {:ok, owner, active}

        {:error, reason} ->
          Managed.close(owner)
          {:error, {:session_activation_unknown, reason}}
      end
    end
  rescue
    exception -> {:error, {:reset_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:reset_failed, reason}}
  end

  defp freeze_skills(%{skill_supervisor: nil}), do: :ok

  defp freeze_skills(state) do
    frozen =
      Enum.reduce_while(Skills.mounts(state.agent), {:ok, []}, fn mount, {:ok, pids} ->
        with {:ok, pid} <- Skills.lookup(state.skill_supervisor, mount.id),
             :ok <- GenServer.call(pid, {Runtime, :freeze_reset, state.control}) do
          {:cont, {:ok, [pid | pids]}}
        else
          error -> {:halt, error}
        end
      end)

    with {:ok, pids} <- frozen,
         :ok <- :sys.suspend(state.skill_supervisor) do
      if Enum.all?(pids, &Process.alive?/1), do: :ok, else: {:error, :reset_busy}
    end
  end

  @doc false
  @spec resume(map()) :: :ok
  def resume(state) do
    staging = Map.take(state, [:agent, :skill_supervisor, :managed_owner, :control])

    Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
      try do
        if staging.skill_supervisor, do: :sys.resume(staging.skill_supervisor)

        Enum.each(Skills.mounts(staging.agent), fn mount ->
          case Skills.lookup(staging.skill_supervisor, mount.id) do
            {:ok, pid} -> GenServer.cast(pid, {Runtime, :resume_reset, staging.control})
            _ -> :ok
          end
        end)

        Managed.resume_reset(staging.managed_owner, staging.control)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  @doc false
  @spec finish(map(), :adopted | :abort) :: :ok
  def finish(reset, result) do
    Process.cancel_timer(reset.timer)
    Process.demonitor(reset.monitor, [:flush])

    if result == :adopted,
      do: send(reset.pid, {reset.token, :adopted}),
      else: Process.exit(reset.pid, :kill)

    :ok
  end
end
