defmodule Spectre.Agent.Observer do
  @moduledoc """
  Optional, payload-free authoring instrumentation owned by the host.

  Declare an observer/events adapter port to receive phase start/stop events.
  Callbacks run in the existing temporary Instance worker, not the Sequencer
  or the state owner's mailbox. A host may forward them to telemetry or a
  bounded collector. No extra process or dependency is installed by Spectre.

  The default adapter forwards ordinary messages to a host-owned process:

      adapter :observer, :events, Spectre.Agent.Observer, to: MyApp.Metrics

  Or implement handle_event/4 in an application module and wire that same port.
  No observer is installed implicitly. The receiving process owns buffering,
  overflow policy and any telemetry/export integration; Spectre starts none.

  Measurements use monotonic time and are not GAM Evidence. Callback failures
  do not replace the operation's result, retry an executor or roll back a fact.
  A slow observer delays its worker: adapters should hand off promptly to their
  host-owned collector. Inputs, prompts, provider bodies and options are absent.
  """

  alias Spectre.Adapter
  alias Spectre.Agent.Wiring

  @callback handle_event([atom()], map(), map(), keyword()) :: term()
  @metadata [
    :instance_ref,
    :definition_ref,
    :turn_ref,
    :request_ref,
    :flow,
    :owner,
    :operation,
    :decision_ref,
    :act_ref,
    :attempt_ref,
    :outcome_ref,
    :profile_ref,
    :status,
    :message_ref
  ]

  @doc """
  Default adapter: sends {:spectre_agent_event, event, measurements, metadata}.

  :to is an explicit host PID or registered process name. Sending is not an
  acknowledgement of delivery; the receiver must manage its mailbox capacity.
  """
  @spec handle_event([atom()], map(), map(), keyword()) :: :ok
  def handle_event(event, measurements, metadata, opts) do
    send(Keyword.fetch!(opts, :to), {:spectre_agent_event, event, measurements, metadata})
    :ok
  end

  @doc false
  @spec span(map() | nil, atom(), map(), (-> result)) :: result when result: term()
  def span(runtime, phase, metadata, work),
    do: span_with(adapter(runtime), phase, metadata, work)

  @doc "Measures a host-owned provider or persistence callback using the same payload-free event contract."
  @spec span_with({module(), keyword()} | nil, atom(), map(), (-> result)) :: result
        when result: term()
  def span_with(observer, phase, metadata, work) do
    start = System.monotonic_time()
    notify(observer, [phase, :start], %{system_time: System.system_time()}, metadata)

    try do
      work.()
    after
      notify(observer, [phase, :stop], %{duration: System.monotonic_time() - start}, metadata)
    end
  end

  @doc false
  @spec emit(map() | nil, [atom()], map(), map()) :: :ok
  def emit(runtime, event, measurements, metadata),
    do: notify(adapter(runtime), event, measurements, metadata)

  defp adapter(nil), do: nil

  defp adapter(runtime) do
    case Wiring.fetch(runtime.wiring, "", :observer, :events) do
      {:ok, adapter} -> adapter
      :error -> nil
    end
  end

  defp notify({module, opts}, event, measurements, metadata) do
    with :ok <- Adapter.validate(module, handle_event: 4) do
      Adapter.invoke(module, :handle_event, [
        [:spectre, :agent | event],
        measurements,
        Map.take(metadata, @metadata),
        opts
      ])
    end

    :ok
  end

  defp notify(_not_configured, _event, _measurements, _metadata), do: :ok
end
