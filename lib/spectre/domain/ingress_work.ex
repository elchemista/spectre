defmodule Spectre.Domain.IngressWork do
  @moduledoc """
  Bounded, short-lived ingress callbacks outside the Domain ordering process.

  Workers receive only adapter arguments: never the projection, seal keys or
  executor capabilities. Their results are revalidated and committed by the
  sequencer at completion, not at callback start. No completion can survive a
  Domain generation change. The worker limit bounds admitted callback work;
  it is not transport-level backpressure against arbitrary BEAM messages.
  """

  alias Spectre.Domain.Command.Input
  alias Spectre.Domain.Context

  @doc false
  def authenticate(state, from, scope_ref, input, opts) do
    case Context.authentication_request(state, scope_ref, input, opts) do
      {:ok, request} ->
        start(state, from, {:authenticate, scope_ref}, fn ->
          Context.run_authentication(request)
        end)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc false
  def observe(state, from, context, input, opts, operation, context_refs \\ []) do
    case Input.prepare_observation(state, context, context_refs) do
      {:ok, context, now} ->
        ingress = state.ingress

        start(state, from, {operation, context, context_refs}, fn ->
          Spectre.Ingress.observe(ingress, context, input, now, opts)
        end)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start(state, from, operation, callback) do
    if map_size(state.ingress_jobs) >= state.ingress_max_concurrency do
      {:reply, {:error, :ingress_busy}, state}
    else
      task = Task.Supervisor.async_nolink(state.ingress_supervisor, callback)
      timer = Process.send_after(self(), {:ingress_timeout, task.ref}, state.ingress_timeout)
      job = %{task: task, timer: timer, from: from, operation: operation}
      {:noreply, %{state | ingress_jobs: Map.put(state.ingress_jobs, task.ref, job)}}
    end
  end

  @doc false
  def take(state, ref) do
    case Map.pop(state.ingress_jobs, ref) do
      {nil, _jobs} ->
        :not_found

      {job, jobs} ->
        Process.cancel_timer(job.timer, async: true, info: false)
        Process.demonitor(ref, [:flush])
        {:ok, job, %{state | ingress_jobs: jobs}}
    end
  end

  @doc false
  def stop(job), do: Process.exit(job.task.pid, :kill)

  @doc false
  def stop_all(state), do: Enum.each(state.ingress_jobs, fn {_ref, job} -> stop(job) end)
end
