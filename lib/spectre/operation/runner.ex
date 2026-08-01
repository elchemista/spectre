defmodule Spectre.Operation.Runner do
  @moduledoc """
  Temporary supervised process for one operation and one fenced attempt.

  The Runner owns no canonical state and always terminates after sending one
  result. Its supervisor uses `restart: :temporary`; semantic retry belongs to
  the Agent owner.
  """

  use GenServer

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Execution
  alias Spectre.Operation.ExecutionContext
  alias Spectre.Operation.Executor
  alias Spectre.Operation.Progress
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Spec

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :attempt) |> Map.fetch!(:id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: Keyword.get(opts, :shutdown, 5_000),
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  @spec execute(GenServer.server()) :: :ok
  def execute(server), do: GenServer.cast(server, :execute)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, false)
    Process.put(:spectre_operation_runner, true)

    attempt = Keyword.fetch!(opts, :attempt)
    spec = Keyword.fetch!(opts, :spec)
    request = Keyword.fetch!(opts, :request)

    if match?(%Attempt{}, attempt) and match?(%Spec{}, spec) and
         match?(%Request{}, request) do
      state = Map.new(opts)

      if Keyword.get(opts, :defer_execute, false),
        do: {:ok, state},
        else: {:ok, state, {:continue, :execute}}
    else
      {:stop, :invalid_operation_runner_arguments}
    end
  end

  @impl GenServer
  def handle_continue(:execute, state), do: run(state)

  @impl GenServer
  def handle_cast(:execute, state), do: run(state)

  defp run(state) do
    owner = Map.fetch!(state, :owner)
    attempt = Map.fetch!(state, :attempt)
    spec = Map.fetch!(state, :spec)
    request = Map.fetch!(state, :request)
    opts = Map.get(state, :opts, [])

    progress = fn value, metadata ->
      emit_progress(owner, attempt, value, metadata, opts)
    end

    context = %ExecutionContext{
      agent: Map.fetch!(state, :agent),
      subject: Map.fetch!(state, :subject),
      loop_id: attempt.loop_id,
      loop_kind: attempt.loop_kind,
      controller: Map.fetch!(state, :controller),
      attempt: attempt,
      input: Map.get(state, :input),
      state: Map.get(state, :agent_state),
      cognitive: Map.get(state, :cognitive, %{}),
      progress: progress,
      opts: opts,
      metadata: Map.get(state, :metadata, %{})
    }

    execution =
      if Map.get(state, :reconcile?, false),
        do: Executor.reconcile(spec, request.input, context),
        else: Executor.execute(spec, request, context)

    result = normalize_result(attempt, execution)
    send(owner, {:spectre, :operation_result, result})
    {:stop, :normal, Map.put(state, :completed?, true)}
  end

  @impl GenServer
  def terminate(reason, state) do
    if reason != :normal and not Map.get(state, :completed?, false) do
      owner = Map.get(state, :owner)
      attempt = Map.get(state, :attempt)

      if is_pid(owner) and match?(%Attempt{}, attempt) do
        send(owner, {:spectre, :operation_runner_terminating, attempt.id, reason})
      end
    end

    :ok
  end

  @spec emit_progress(pid(), Attempt.t(), term(), map(), keyword()) :: :ok
  defp emit_progress(owner, attempt, value, metadata, opts) do
    now = System.monotonic_time(:millisecond)
    key = {:spectre_operation_progress, attempt.id}
    {sequence, previous} = Process.get(key, {0, nil})
    min_interval = Keyword.get(opts, :operation_progress_interval, 100)

    if is_nil(previous) or now - previous >= min_interval do
      sequence = sequence + 1
      Process.put(key, {sequence, now})

      progress = %Progress{
        id: Spectre.Identity.uuid7(),
        attempt_id: attempt.id,
        loop_id: attempt.loop_id,
        epoch: attempt.epoch,
        fencing_token: attempt.fencing_token,
        context_revision: attempt.context_revision,
        control_generation: attempt.control_generation,
        trigger_generation: attempt.trigger_generation,
        sequence: sequence,
        value: value,
        at: System.system_time(:millisecond),
        metadata: metadata
      }

      send(owner, {:spectre, :operation_progress, progress})
    end

    :ok
  end

  defp normalize_result(attempt, {:ok, %Execution{} = execution}) do
    Result.new(attempt, :ok, execution.value,
      receipt: execution.receipt,
      usage: execution.usage,
      artifacts: execution.artifacts,
      metadata: execution.metadata
    )
  end

  defp normalize_result(attempt, {:error, reason}), do: Result.new(attempt, :error, reason)

  defp normalize_result(attempt, {:ambiguous, reason}),
    do: Result.new(attempt, :ambiguous, reason)
end
