# ERL_FLAGS='+S 2:2' mix run bench/profile_activity.exs ram 256
# ERL_FLAGS='+S 2:2' mix run bench/profile_activity.exs disk 16
# Set TMPDIR to a directory on the target filesystem to measure persisted writes.
defmodule ActivityProfile.Job do
  use Spectre.Activity

  def handle_start(:waiting, ctx) do
    await_input(ctx, :answer, accept: ~r/^answer$/, prompt: "Ready?", timeout: 120_000)
  end

  def handle_start(:working, ctx), do: generate(ctx, :profile)
  def handle_start(:idle, ctx), do: ctx

  def handle_result(:generate, {:generated, %{text: text}}, ctx), do: complete(ctx, text)
end

defmodule ActivityProfile.Stack do
  use Spectre.Stack
  activity(:job, ActivityProfile.Job)
end

defmodule ActivityProfile.Root do
  use Spectre.Server

  def handle_flow(:unmatched, %Spectre.Input{text: "ping"}, ctx), do: respond(ctx, "pong")

  def handle_call({:job, mode}, _from, ctx),
    do: {:reply, :ok, start_activity(ctx, :job, mode)}
end

defmodule ActivityProfile.Agent do
  use Spectre.Agent, stack: ActivityProfile.Stack, server: ActivityProfile.Root
end

defmodule ActivityProfile do
  alias Spectre.Server

  def generate(_request, _context, _opts) do
    send(__MODULE__, {:worker_started, self(), now()})

    receive do
      :release -> {:generated, %{text: "done"}}
    after
      120_000 -> {:error, :profile_worker_timeout}
    end
  end

  def run(mode, cycles) when mode in ["ram", "disk"] and cycles > 0 do
    Process.register(self(), __MODULE__)
    directory = Path.join(System.tmp_dir!(), "spectre-activity-#{Spectre.Identity.uuid7()}")
    storage = if mode == "disk", do: {:disk, directory}, else: :ephemeral
    baseline = MapSet.new(Process.list())
    io_baseline = write_bytes()

    print(%{mode: mode, cycles_per_batch: cycles, schedulers: System.schedulers_online()})

    try do
      {:ok, root} =
        Server.start_link(
          agent: ActivityProfile.Agent,
          identity: %{subject: "profile"},
          consumer: self(),
          services: [generate: __MODULE__],
          gam: [storage: storage],
          worker_timeout: 120_000,
          history_limit: 8,
          max_seen_events: 16
        )

      turns(root, 5)
      sample(:idle, root, baseline, directory, io_baseline, turns(root, 24))

      waiting = start(root, :waiting)
      activity(root, waiting, fn event -> match?({:waiting_input, _}, event) end)
      sample(:one_wait, root, baseline, directory, io_baseline, turns(root, 24))
      cancel(root, waiting)

      workers = for _ <- 1..2, do: start_worker(root)
      sample(:two_workers, root, baseline, directory, io_baseline, turns(root, 24))
      print(%{worker_lifetime_us: Enum.map(workers, &release(root, &1))})

      Enum.each(1..3, fn batch ->
        for _ <- 1..cycles, do: cancel(root, start(root, :idle))
        sample({:churn, batch * cycles}, root, baseline, directory, io_baseline, turns(root, 24))
      end)

      :ok = GenServer.stop(root)
      sample(:teardown, nil, baseline, directory, io_baseline, nil)
    after
      File.rm_rf!(directory)
    end
  end

  defp start(root, mode) do
    :ok = GenServer.call(root, {:job, mode})

    receive do
      {Server, ^root, {:activity, %{ref: ref}, :started}} -> ref
    after
      30_000 -> raise "Activity did not start"
    end
  end

  defp cancel(root, ref) do
    {:ok, _} = Server.cancel_activity(root, ref)
    activity(root, ref, &(&1 == :cancelled))
  end

  defp start_worker(root) do
    ref = start(root, :working)

    receive do
      {:worker_started, pid, started} -> {ref, pid, started}
    after
      30_000 -> raise "Worker did not start"
    end
  end

  defp release(root, {ref, pid, started}) do
    send(pid, :release)
    activity(root, ref, &(&1 == {:completed, "done"}))
    now() - started
  end

  defp activity(root, ref, expected?) do
    receive do
      {Server, ^root, {:activity, %{ref: ^ref}, event}} ->
        if not expected?.(event), do: activity(root, ref, expected?)
    after
      30_000 -> raise "Activity event missing for #{ref}"
    end
  end

  defp turns(root, count) do
    durations =
      Enum.map(1..count, fn _ ->
        started = now()
        {:ok, turn} = Server.input(root, "ping")

        receive do
          {Server, ^root, {:response, ^turn, "pong", _}} -> now() - started
        after
          30_000 -> raise "Root stopped answering"
        end
      end)
      |> Enum.sort()

    %{p50_us: percentile(durations, 50), p95_us: percentile(durations, 95)}
  end

  defp percentile(sorted, n), do: Enum.at(sorted, div(length(sorted) * n + 99, 100) - 1)

  defp sample(label, root, baseline, directory, io_baseline, latency) do
    # Allow lifecycle delivery and asynchronous checkpoint retirement to settle.
    Process.sleep(100)
    pids = Process.list() |> MapSet.new() |> MapSet.difference(baseline)

    for pid <- pids, do: :erlang.garbage_collect(pid)

    fields = [:memory, :reductions, :message_queue_len]

    processes =
      for pid <- pids, info = Process.info(pid, fields) do
        {module, _function, _arity} = :proc_lib.translate_initial_call(pid)
        info |> Map.new() |> Map.put(:module, module)
      end

    print(%{
      phase: label,
      new_processes: length(processes),
      new_process_memory_bytes: processes |> Enum.map(& &1.memory) |> Enum.sum(),
      largest_processes: largest_processes(processes),
      live_process_reductions: processes |> Enum.map(& &1.reductions) |> Enum.sum(),
      vm_reductions: elem(:erlang.statistics(:reductions), 0),
      max_mailbox: processes |> Enum.map(& &1.message_queue_len) |> Enum.max(fn -> 0 end),
      root: if(root, do: Map.new(Process.info(root, fields))),
      latency: latency,
      checkpoint: checkpoint(root),
      disk_commands_bytes: file_size(Path.join(directory, "commands.store")),
      io_write_bytes_since_start: delta(write_bytes(), io_baseline)
    })
  end

  defp largest_processes(processes) do
    processes
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(3)
    |> Enum.map(&{&1.module, &1.memory})
  end

  # Internal snapshot inspection is confined to this maintainer benchmark.
  defp checkpoint(nil), do: nil

  defp checkpoint(root) do
    %{opts: opts} = :sys.get_state(root)
    {module, store, key} = Keyword.fetch!(opts, :checkpoint)
    {:ok, %{value: value}} = module.fetch(store, key)
    %{sequence: sequence} = state = :sys.get_state(store)
    entries = state[:entries] || state.values
    %{root_bytes: byte_size(value), store_entries: map_size(entries), sequence: sequence}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> nil
    end
  end

  defp write_bytes do
    with {:ok, data} <- File.read("/proc/self/io"),
         [_, bytes] <- Regex.run(~r/^write_bytes: ([0-9]+)$/m, data) do
      String.to_integer(bytes)
    end
  end

  defp delta(a, b) when is_integer(a) and is_integer(b), do: a - b
  defp delta(_, _), do: nil
  defp now, do: System.monotonic_time(:microsecond)
  defp print(value), do: IO.puts(inspect(value, pretty: true))
end

[mode, cycles] = System.argv()
ActivityProfile.run(mode, String.to_integer(cycles))
