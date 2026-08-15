defmodule SpectreInferenceStreamHandleContractTest.Agent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreInferenceStreamHandleContractTest.Session do
  @moduledoc false

  use GenServer

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    key = Keyword.fetch!(opts, :key)
    {:ok, _owner} = Registry.register(registry, key, %{})

    {:ok,
     %{
       replies: Keyword.get(opts, :replies, []),
       await_reply: Keyword.get(opts, :await_reply, {:error, :no_result})
     }}
  end

  @impl GenServer
  def handle_call({:next, _token, _consumer, _claim, _demand}, _from, state) do
    case state.replies do
      [:hang | rest] -> {:noreply, %{state | replies: rest}}
      [{:stop, reason} | rest] -> {:stop, reason, %{state | replies: rest}}
      [reply | rest] -> {:reply, reply, %{state | replies: rest}}
      [] -> {:reply, {:error, :fixture_exhausted}, state}
    end
  end

  def handle_call({:await_result, _token, _awaiter_ref}, _from, state) do
    case state.await_reply do
      :hang -> {:noreply, state}
      {:stop, reason} -> {:stop, reason, state}
      reply -> {:reply, reply, state}
    end
  end

  @impl GenServer
  def handle_cast({:abandon_result_waiter, _token, _awaiter_ref}, state),
    do: {:noreply, state}
end

defmodule SpectreInferenceStreamHandleContractTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Spectre.Inference.Stream
  alias Spectre.Inference.StreamEvent
  alias Spectre.Instance.Ref
  alias Spectre.Result
  alias Spectre.Subject

  @registry SpectreInferenceStreamHandleContractTest.Registry
  @agent SpectreInferenceStreamHandleContractTest.Agent

  test "the opaque handle exposes safe inspection and Enumerable capabilities only" do
    start_registry()
    stream = stream()

    inspected = inspect(stream)
    assert inspected =~ "#Spectre.Inference.Stream<"
    assert inspected =~ "inference_id: \"inference\""
    refute inspected =~ stream.consumer_token

    assert {:error, _implementation} = Enumerable.count(stream)
    assert {:error, _implementation} = Enumerable.member?(stream, :event)
    assert {:error, _implementation} = Enumerable.slice(stream)

    assert Stream.session_key(stream) == {stream.invocation_id, stream.stream_epoch}
    assert {:error, :stream_not_found} = Stream.lookup_session(stream)

    assert_raise ArgumentError, "invalid inference stream handle", fn ->
      stream(overrides: [demand: 0])
    end

    assert_raise ArgumentError, "invalid inference stream handle", fn ->
      stream(overrides: [consumer_token: ""])
    end
  end

  test "enumeration accepts empty batches and a correctly fenced terminal event" do
    start_registry()
    stream = stream()
    terminal = event(stream, :already_consumed, 1)
    session = start_session(stream, replies: [{:ok, []}, {:ok, [terminal]}])

    assert {:ok, ^session} = Stream.lookup_session(stream)
    assert [^terminal] = Enum.to_list(stream)
    assert Process.alive?(session)
  end

  test "enumeration converts missing sessions and malformed batches into local terminals" do
    start_registry()

    missing = stream(overrides: [invocation_id: "missing"])
    assert [%StreamEvent{kind: :stream_expired, sequence: 1}] = Enum.to_list(missing)

    malformed = stream(overrides: [invocation_id: "malformed"])
    start_session(malformed, replies: [{:ok, :not_a_batch}])
    assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(malformed)

    invalid_event_stream = stream(overrides: [invocation_id: "invalid-event"])
    invalid_event = %{event(invalid_event_stream, :already_consumed, 1) | kind: :unknown}
    start_session(invalid_event_stream, replies: [{:ok, [invalid_event]}])
    assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(invalid_event_stream)

    invalid_singleton = stream(overrides: [invocation_id: "invalid-singleton"])
    malformed_singleton = %{event(invalid_singleton, :already_consumed, 1) | at: -1}
    start_session(invalid_singleton, replies: [{:ok, [malformed_singleton]}])
    assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(invalid_singleton)

    invalid_member = stream(overrides: [invocation_id: "invalid-member"])
    start_session(invalid_member, replies: [{:ok, [:not_a_stream_event]}])
    assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(invalid_member)
  end

  test "enumeration rejects stale fences, sequence gaps, and invalid singleton fences" do
    start_registry()

    stale = stream(overrides: [invocation_id: "stale"])
    stale_event = %{event(stale, :failed, 1) | generation: "old-generation"}
    start_session(stale, replies: [{:ok, [stale_event]}])
    assert [%StreamEvent{kind: :interrupted}] = Enum.to_list(stale)

    gap = stream(overrides: [invocation_id: "gap"])
    start_session(gap, replies: [{:ok, [event(gap, :failed, 2)]}])
    assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(gap)

    consumed = stream(overrides: [invocation_id: "consumed"])
    invalid_consumed = %{event(consumed, :already_consumed, 1) | dispatch_id: "stale"}
    start_session(consumed, replies: [{:ok, [invalid_consumed]}])
    assert [%StreamEvent{kind: :interrupted}] = Enum.to_list(consumed)
  end

  test "next-call timeout and session termination remain explicit stream outcomes" do
    start_registry()

    timeout_stream = stream(overrides: [invocation_id: "timeout", next_timeout: 10])
    start_session(timeout_stream, replies: [:hang])
    assert [%StreamEvent{kind: :interrupted}] = Enum.to_list(timeout_stream)

    normal_stream = stream(overrides: [invocation_id: "normal-exit"])
    start_session(normal_stream, replies: [{:stop, :normal}])
    assert [%StreamEvent{kind: :stream_expired}] = Enum.to_list(normal_stream)

    failed_stream = stream(overrides: [invocation_id: "failed-exit"])
    start_session(failed_stream, replies: [{:stop, :fixture_failed}])
    assert [%StreamEvent{kind: :interrupted}] = Enum.to_list(failed_stream)
  end

  test "await_result validates timeout and classifies lookup, timeout, and process exits" do
    start_registry()
    missing = stream(overrides: [invocation_id: "await-missing"])

    assert {:error, :invalid_stream_timeout} = Stream.await_result(missing, -1)
    assert {:error, :stream_not_found} = Stream.await_result(missing, 10)
    assert {:error, :stream_not_found} = Stream.await_result(missing)

    successful = stream(overrides: [invocation_id: "await-success"])
    result = %Result{reply_text: "done"}
    start_session(successful, await_reply: {:ok, result})
    assert {:ok, ^result} = Stream.await_result(successful, :infinity)

    timed_out = stream(overrides: [invocation_id: "await-timeout"])
    start_session(timed_out, await_reply: :hang)
    assert {:error, :stream_await_timeout} = Stream.await_result(timed_out, 10)

    normal = stream(overrides: [invocation_id: "await-normal"])
    start_session(normal, await_reply: {:stop, :normal})
    assert {:error, :stream_expired} = Stream.await_result(normal, 100)

    failed = stream(overrides: [invocation_id: "await-failed"])
    start_session(failed, await_reply: {:stop, :fixture_failed})

    assert {:error, {:stream_session_exit, :fixture_failed}} =
             Stream.await_result(failed, 100)
  end

  test "control operations are bounded when no live Instance owns the handle" do
    start_registry()
    stream = stream()

    assert :ok = Stream.cancel(stream)
    assert :ok = Stream.cancel(stream, :test_cancel)
    assert {:error, :instance_not_found} = Stream.steer(stream, "replacement")
    assert {:error, :invalid_stream_options} = Stream.steer(stream, "replacement", :invalid)
  end

  defp start_registry do
    start_supervised!({Registry, keys: :unique, name: @registry})
  end

  defp start_session(stream, opts) do
    {:ok, session} =
      SpectreInferenceStreamHandleContractTest.Session.start(
        [registry: @registry, key: Stream.session_key(stream)] ++ opts
      )

    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    session
  end

  defp stream(opts \\ []) do
    overrides = Keyword.get(opts, :overrides, [])

    defaults = [
      inference_id: "inference",
      invocation_id: "invocation",
      attempt_id: "attempt",
      run_id: "run",
      run_revision: 1,
      generation: "generation",
      dispatch_id: "dispatch",
      control_revision: 0,
      stream_epoch: "epoch",
      consumer_token: "consumer-secret-token",
      instance_ref: Ref.new(@agent, Subject.new("stream-handle")),
      registry: @registry,
      demand: 2,
      next_timeout: 100
    ]

    defaults |> Keyword.merge(overrides) |> Stream.new()
  end

  defp event(stream, kind, sequence) do
    StreamEvent.new(kind,
      inference_id: stream.inference_id,
      invocation_id: stream.invocation_id,
      attempt_id: stream.attempt_id,
      run_revision: stream.run_revision,
      generation: stream.generation,
      dispatch_id: stream.dispatch_id,
      control_revision: stream.control_revision,
      stream_epoch: stream.stream_epoch,
      sequence: sequence,
      payload: kind,
      content_class: :control
    )
  end
end
