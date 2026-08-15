defmodule SpectreInferenceStreamContractTest.Model do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:error, :streaming_must_not_call_complete}
end

defmodule SpectreInferenceStreamContractTest.PullAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, opts) do
    base = [:stream, :pull_transport]
    MapSet.new(base ++ Keyword.get(opts, :capabilities, [:incremental_usage]))
  end

  @impl Spectre.Inference.StreamAdapter
  def open(descriptor, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    ref = make_ref()
    batches = select_batches(descriptor, opts)
    send(test_pid, {:stream_adapter, :opened, self()})

    {:ok,
     %{
       batches: batches,
       cancel_reply: Keyword.get(opts, :cancel_reply, :ok),
       ref: ref,
       test_pid: test_pid
     }, %{transport: :fixture}}
  end

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(%{batches: [:stall | rest]} = state) do
    send(state.test_pid, {:stream_adapter, :credit, self()})
    {:ok, %{state | batches: rest}}
  end

  def request_transport_item(%{batches: [events | rest]} = state) do
    send(state.test_pid, {:stream_adapter, :credit, self()})
    send(self(), {:stream_fixture, state.ref, events})
    {:ok, %{state | batches: rest}}
  end

  def request_transport_item(%{batches: []} = state) do
    send(state.test_pid, {:stream_adapter, :unexpected_credit, self()})
    {:error, :fixture_exhausted_without_terminal}
  end

  @impl Spectre.Inference.StreamAdapter
  def handle_transport({:conformance, events}, state), do: {:ok, events, state}

  def handle_transport({:stream_fixture, ref, events}, %{ref: ref} = state),
    do: {:ok, events, state}

  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(state, reason) do
    send(state.test_pid, {:stream_adapter, :cancelled, reason})
    state.cancel_reply
  end

  defp select_batches(descriptor, opts) do
    case Keyword.get(opts, :steering_batches) do
      {marker, batches} when is_binary(marker) ->
        if String.contains?(descriptor.plan.rendered, marker),
          do: batches,
          else: Keyword.fetch!(opts, :batches)

      _none ->
        Keyword.fetch!(opts, :batches)
    end
  end
end

defmodule SpectreInferenceStreamContractTest.UnboundedPushAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts), do: MapSet.new([:stream, :push_transport])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, _opts), do: {:ok, %{}, %{}}

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(_state, _reason), do: :ok
end

defmodule SpectreInferenceStreamContractTest.BoundedPushAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts) do
    MapSet.new([:stream, :push_transport, :bounded_push_transport])
  end

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    ref = make_ref()

    Enum.each(Keyword.fetch!(opts, :messages), fn events ->
      send(self(), {:bounded_push_fixture, ref, events})
    end)

    send(test_pid, {:push_adapter, :opened, self()})
    {:ok, %{ref: ref, test_pid: test_pid}, %{transport: :bounded_push_fixture}}
  end

  @impl Spectre.Inference.StreamAdapter
  def handle_transport({:bounded_push_fixture, ref, events}, %{ref: ref} = state),
    do: {:ok, events, state}

  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(state, reason) do
    send(state.test_pid, {:push_adapter, :cancelled, reason})
    :ok
  end
end

defmodule SpectreInferenceStreamContractTest.MissingStreamCapabilityAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts), do: MapSet.new([:pull_transport])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, _opts), do: {:ok, %{}, %{}}

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(state), do: {:ok, state}

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(_state, _reason), do: :ok
end

defmodule SpectreInferenceStreamContractTest.FenceSession do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    key = Keyword.fetch!(opts, :key)
    {:ok, _owner} = Registry.register(registry, key, %{})
    {:ok, Keyword.fetch!(opts, :event)}
  end

  @impl GenServer
  def handle_call({:next, _token, _consumer, _claim, _demand}, _from, event),
    do: {:reply, {:ok, [event]}, event}
end

defmodule SpectreInferenceStreamContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :streaming do
    on :STREAM, regex: ~r/stream/i do
      ask(:base)
    end
  end
end

defmodule SpectreInferenceStreamContractTest.NonIncrementalPlanner do
  @moduledoc false

  @behaviour Spectre.Action.Planner

  @impl Spectre.Action.Planner
  def plan_response(text, _context, _opts), do: {:ok, %{reply_text: text, actions: []}}

  @impl Spectre.Action.Planner
  def clean_reply(text, _context, _opts), do: String.trim(text)
end

defmodule SpectreInferenceStreamContractTest.PlannerAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  action_planner(SpectreInferenceStreamContractTest.NonIncrementalPlanner)
  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :streaming do
    on :STREAM, regex: ~r/stream/i do
      ask(:base)
    end
  end
end

defmodule SpectreInferenceStreamContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.Budget
  alias Spectre.Inference.StreamEvent
  alias Spectre.Inference.StreamAdapter
  alias Spectre.Inference.Usage
  alias Spectre.Instance
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Operation.Control.Command
  alias Spectre.Result
  alias Spectre.Subject

  @agent SpectreInferenceStreamContractTest.Agent
  @adapter SpectreInferenceStreamContractTest.PullAdapter
  @model SpectreInferenceStreamContractTest.Model

  test "the Enumerable is lazy, pull-driven, fenced, and ends at the canonical Result" do
    instance = start_instance()
    {:ok, stream} = start_stream(instance, successful_batches("hello world"))

    refute_receive {:stream_adapter, :opened, _session}

    events = Enum.to_list(stream)

    assert Enum.map(events, & &1.kind) == [
             :delta,
             :usage,
             :delta,
             :inference_completed,
             :result
           ]

    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..5)
    assert Enum.map(events, & &1.stream_epoch) |> Enum.uniq() == [stream.stream_epoch]
    assert Enum.map(events, & &1.invocation_id) |> Enum.uniq() == [stream.invocation_id]

    assert events
           |> Enum.filter(&(&1.kind == :delta))
           |> Enum.map_join(& &1.payload) == "hello world"

    assert %StreamEvent{kind: :result, payload: %Result{reply_text: "hello world"}} =
             List.last(events)

    assert_receive {:stream_adapter, :opened, session}
    assert_receive {:stream_adapter, :credit, ^session}
    assert_receive {:stream_adapter, :credit, ^session}
    refute_receive {:stream_adapter, :unexpected_credit, _session}

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, stream.run_id))
    end)
  end

  test "await_result claims an untouched handle and suppresses provisional events" do
    instance = start_instance()
    {:ok, stream} = start_stream(instance, successful_batches("result only"))

    assert {:ok, %Result{reply_text: "result only"}} = Spectre.await_result(stream, 1_000)
    assert_receive {:stream_adapter, :opened, _session}

    assert [%StreamEvent{kind: :already_consumed}] = Enum.to_list(stream)
    assert {:ok, %Result{reply_text: "result only"}} = Spectre.await_result(stream, 1_000)
  end

  test "enumeration is one-shot and early halt cancels the provider" do
    instance = start_instance()

    batches = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("first", provider_sequence: 1)
      ],
      [ProviderEvent.delta("second", provider_sequence: 2)]
    ]

    {:ok, stream} = start_stream(instance, batches, stream_demand: 1)

    assert [%StreamEvent{kind: :delta, payload: "first"}] = Enum.take(stream, 1)
    assert_receive {:stream_adapter, :cancelled, :consumer_halted}, 1_000

    assert {:error, reason} = Spectre.await_result(stream, 1_000)
    assert inspect(reason) =~ "consumer_halted"
    assert [%StreamEvent{kind: :already_consumed}] = Enum.to_list(stream)

    assert_eventually(fn ->
      match?(
        {:ok, %{status: status}} when status in [:failed, :complete],
        Instance.run(instance, stream.run_id)
      )
    end)
  end

  test "a never-attached consumer terminalizes the Run and releases capacity" do
    instance = start_instance(max_stream_sessions: 1)

    {:ok, abandoned} =
      start_stream(instance, successful_batches("unused"), stream_attach_timeout: 30)

    assert {:error, :stream_capacity_exhausted} =
             start_stream(instance, successful_batches("blocked"))

    Process.sleep(60)
    assert {:error, reason} = Spectre.await_result(abandoned, 1_000)
    assert inspect(reason) =~ "consumer_never_attached"
    refute_receive {:stream_adapter, :opened, _session}

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Instance.run(instance, abandoned.run_id))
    end)

    assert {:ok, replacement} = start_stream(instance, successful_batches("released"))
    assert {:ok, %Result{reply_text: "released"}} = Spectre.await_result(replacement, 1_000)
  end

  test "restart-based steering returns a fresh epoch and never joins streams" do
    instance = start_instance()

    {:ok, original} =
      start_stream(instance, successful_batches("old"),
        stream_adapter_opts: [
          test_pid: self(),
          batches: successful_batches("old"),
          steering_batches: {"stream replacement", successful_batches("new")}
        ]
      )

    assert {:ok, replacement} =
             Spectre.Inference.Stream.steer(original, "stream replacement")

    assert replacement.stream_epoch != original.stream_epoch
    assert replacement.invocation_id != original.invocation_id
    assert [%StreamEvent{kind: :superseded}] = Enum.to_list(original)

    replacement_events = Enum.to_list(replacement)

    assert %StreamEvent{kind: :result, payload: %Result{reply_text: "new"}} =
             List.last(replacement_events)

    assert Enum.all?(replacement_events, &(&1.stream_epoch == replacement.stream_epoch))
    refute Enum.any?(replacement_events, &(&1.stream_epoch == original.stream_epoch))
  end

  test "stream adapters fail closed when push transport has no upstream bound" do
    assert {:error, {:streaming_unsupported, :unbounded_push_transport}} =
             StreamAdapter.validate(
               SpectreInferenceStreamContractTest.UnboundedPushAdapter,
               :default
             )
  end

  test "provider ordering violations fail the Run and cancel the transport" do
    instance = start_instance()

    batches = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("out of order", provider_sequence: 2)
      ]
    ]

    {:ok, stream} = start_stream(instance, batches)
    events = Enum.to_list(stream)

    assert %StreamEvent{kind: :failed, payload: reason} = List.last(events)
    assert inspect(reason) =~ "provider_sequence_violation"
    assert_receive {:stream_adapter, :cancelled, :provider_sequence_violation}

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Instance.run(instance, stream.run_id))
    end)
  end

  test "output budget is enforced during generation from the immutable snapshot" do
    instance = start_instance()

    {:ok, stream} =
      start_stream(instance, successful_batches("budget"),
        maximum_output_tokens: 2,
        inference_budget: [output_tokens: 2]
      )

    events = Enum.to_list(stream)
    assert %StreamEvent{kind: :failed, payload: reason} = List.last(events)
    assert inspect(reason) =~ "inference_budget_exceeded"
    assert inspect(reason) =~ "output_tokens"
    assert_receive {:stream_adapter, :cancelled, {:inference_budget_exceeded, :output_tokens}}
  end

  test "hard cost budgets require authoritative provider cost usage" do
    instance = start_instance()

    assert {:error, :inference_cost_budget_usage_unavailable} =
             start_stream(instance, successful_batches("cost"),
               inference_budget: [cost: 1.0],
               inference_pricing_ref: "pricing:test-v1"
             )
  end

  test "control markers split across provider deltas never reach the provisional lane" do
    instance = start_instance()
    response = "<think>private reasoning</think>visible"

    batches = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("<thi", provider_sequence: 1)
      ],
      [
        ProviderEvent.delta("nk>private reasoning</th", provider_sequence: 2),
        ProviderEvent.delta("ink>visible", provider_sequence: 3),
        ProviderEvent.completed(response, provider_sequence: 4)
      ]
    ]

    {:ok, stream} = start_stream(instance, batches)
    events = Enum.to_list(stream)

    assert events
           |> Enum.filter(&(&1.kind == :delta))
           |> Enum.map_join(& &1.payload) == "visible"

    refute inspect(Enum.filter(events, &(&1.kind == :delta))) =~ "private reasoning"

    assert %StreamEvent{kind: :result, payload: %Result{reply_text: "visible"}} =
             List.last(events)
  end

  test "observer lane publishes only committed, text-free lifecycle facts" do
    instance =
      start_instance(
        inference_observer_lane: true,
        inference_progress_commit_interval: 1,
        inference_stream_checkpoint_interval: 1,
        inference_heartbeat_interval: 1
      )

    assert {:ok, _subscription} = Spectre.Inference.Events.subscribe(instance)
    {:ok, stream} = start_stream(instance, successful_batches("never publish this text"))
    assert {:ok, %Result{}} = Spectre.await_result(stream, 1_000)

    observer_events = collect_inference_events([])
    assert observer_events != []
    assert Enum.any?(observer_events, &(&1.type == :progress_committed))
    assert Enum.any?(observer_events, &(&1.type == :terminal_committed))

    assert Enum.all?(observer_events, fn event ->
             event.canonical_revision >= 0 and
               not String.contains?(inspect(event), "never publish this text")
           end)
  end

  test "Instance death interrupts the old Enumerable and cancels the provider" do
    {:ok, instance} =
      Instance.start_link(
        agent: @agent,
        subject: Subject.new("stream-crash-#{System.unique_integer([:positive, :monotonic])}"),
        idle: false
      )

    Process.unlink(instance)

    batches = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("before restart", provider_sequence: 1)
      ],
      :stall
    ]

    {:ok, stream} = start_stream(instance, batches, stream_demand: 1)
    consumer = Task.async(fn -> Enum.to_list(stream) end)

    assert_receive {:stream_adapter, :credit, session}
    assert_receive {:stream_adapter, :credit, ^session}
    Process.exit(instance, :kill)

    events = Task.await(consumer, 1_000)
    assert %StreamEvent{kind: :interrupted} = List.last(events)
    assert_receive {:stream_adapter, :cancelled, :instance_down}
  end

  test "adapter conformance exercises pull credit, global order, and terminal cardinality" do
    batches = successful_batches("conformance")

    descriptor = %Spectre.Inference.Descriptor{
      id: "conformance-inference",
      purpose: :response_generation,
      plan: %Spectre.Prompt.Plan{rendered: "conformance"},
      constraints: %Spectre.Inference.Constraints{}
    }

    messages = Enum.map(batches, &{:conformance, &1})

    assert {:ok,
            %{
              transport: :pull,
              transport_requests: 2,
              transport_items: 2,
              events: 5,
              terminal: :completed
            }} =
             Spectre.Inference.StreamAdapter.Conformance.run(
               @adapter,
               descriptor,
               messages,
               adapter_opts: [test_pid: self(), batches: batches]
             )
  end

  test "consumer exceptions and consumer death both cancel owned provider work" do
    instance = start_instance()

    {:ok, exceptional} =
      start_stream(instance, successful_batches("exception"), stream_demand: 1)

    assert_raise RuntimeError, "consumer failed", fn ->
      Enum.each(exceptional, fn
        %StreamEvent{kind: :delta} -> raise "consumer failed"
        _event -> :ok
      end)
    end

    assert_receive {:stream_adapter, :opened, _exceptional_session}
    assert_receive {:stream_adapter, :cancelled, :consumer_halted}

    {:ok, killed} =
      start_stream(
        instance,
        [
          [
            ProviderEvent.new(:started, provider_sequence: 0),
            ProviderEvent.delta("attached", provider_sequence: 1)
          ],
          :stall
        ],
        stream_demand: 1
      )

    {consumer, monitor} = spawn_monitor(fn -> Enum.to_list(killed) end)
    assert_receive {:stream_adapter, :opened, session}
    assert_receive {:stream_adapter, :credit, ^session}
    assert_receive {:stream_adapter, :credit, ^session}
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^consumer, :killed}
    assert_receive {:stream_adapter, :cancelled, :consumer_down}
  end

  test "a slow consumer and a stalled provider terminate through distinct deadlines" do
    instance = start_instance()

    {:ok, slow} =
      start_stream(instance, successful_batches("slow consumer"),
        stream_demand: 1,
        stream_consumer_idle_timeout: 20
      )

    slow_events =
      Enum.reduce(slow, [], fn event, events ->
        if event.kind == :delta and events == [], do: Process.sleep(50)
        [event | events]
      end)
      |> Enum.reverse()

    assert_attempt_failure(slow_events, :consumer_too_slow)

    assert_receive {:stream_adapter, :cancelled, :consumer_too_slow}

    {:ok, stalled} =
      start_stream(
        instance,
        [[ProviderEvent.new(:started, provider_sequence: 0)], :stall],
        stream_provider_stall_timeout: 20
      )

    assert_attempt_failure(Enum.to_list(stalled), :provider_stall_timeout)

    assert_receive {:stream_adapter, :cancelled, :provider_stall_timeout}
  end

  test "absolute inference deadline is not renewed by valid provider progress" do
    instance = start_instance()

    batches = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("progress", provider_sequence: 1)
      ],
      :stall
    ]

    {:ok, stream} =
      start_stream(instance, batches,
        stream_demand: 1,
        stream_provider_stall_timeout: 1_000,
        stream_max_duration_ms: 1_000,
        inference_budget: [duration_ms: 30]
      )

    assert_attempt_failure(Enum.to_list(stream), :inference_deadline_exceeded)

    assert_receive {:stream_adapter, :cancelled, :inference_deadline_exceeded}
  end

  test "bounded push overflow fails explicitly instead of dropping queued text" do
    instance = start_instance()

    messages = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("one", provider_sequence: 1)
      ],
      [ProviderEvent.delta("two", provider_sequence: 2)],
      [ProviderEvent.delta("three", provider_sequence: 3)],
      [ProviderEvent.completed("onetwothree", provider_sequence: 4)]
    ]

    assert {:ok, stream} =
             Spectre.stream(instance, "stream this",
               model: @model,
               plan_actions?: false,
               stream_adapter: SpectreInferenceStreamContractTest.BoundedPushAdapter,
               stream_adapter_opts: [test_pid: self(), messages: messages],
               stream_demand: 1,
               stream_max_buffer_events: 1,
               stream_provider_stall_timeout: 1_000,
               stream_result_timeout: 1_000
             )

    events =
      Enum.reduce(stream, [], fn event, acc ->
        if event.kind == :delta and acc == [], do: Process.sleep(30)
        [event | acc]
      end)
      |> Enum.reverse()

    assert_attempt_failure(events, :consumer_too_slow)
    assert_receive {:push_adapter, :cancelled, :consumer_too_slow}
  end

  test "the Enumerable rejects a correctly sequenced event with a stale generation fence" do
    instance = start_instance()
    {:ok, original} = start_stream(instance, successful_batches("real"))
    registry = SpectreInferenceStreamContractTest.FenceRegistry
    start_supervised!({Registry, keys: :unique, name: registry})

    forged_event =
      StreamEvent.new(:delta,
        inference_id: original.inference_id,
        invocation_id: original.invocation_id,
        attempt_id: original.attempt_id,
        run_revision: original.run_revision,
        generation: "stale-generation",
        dispatch_id: original.dispatch_id,
        control_revision: original.control_revision,
        stream_epoch: original.stream_epoch,
        sequence: 1,
        payload: "forged text"
      )

    start_supervised!(
      {SpectreInferenceStreamContractTest.FenceSession,
       registry: registry,
       key: Spectre.Inference.Stream.session_key(original),
       event: forged_event}
    )

    forged_handle = %{original | registry: registry}
    events = Enum.to_list(forged_handle)

    assert [%StreamEvent{kind: :interrupted, payload: :interrupted}] = events
    refute inspect(events) =~ "forged text"
    assert :ok = Spectre.Inference.Stream.cancel(original, :test_cleanup)
  end

  test "unsupported purposes and missing capabilities reject rather than buffer" do
    instance = start_instance()

    common = [
      model: @model,
      stream_adapter: @adapter,
      stream_adapter_opts: [test_pid: self(), batches: successful_batches("unused")]
    ]

    assert {:error, {:streaming_unsupported, :action_planning}} =
             Spectre.stream(instance, "stream this", common)

    assert {:error, {:streaming_unsupported, :structured_output}} =
             Spectre.stream(
               instance,
               "stream this",
               Keyword.merge(common, plan_actions?: false, structured_output?: true)
             )

    assert {:error, {:streaming_unsupported, :adapter_capability}} =
             Spectre.stream(instance, "stream this",
               model: @model,
               plan_actions?: false,
               stream_adapter: SpectreInferenceStreamContractTest.MissingStreamCapabilityAdapter
             )

    planner_instance =
      start_instance(agent: SpectreInferenceStreamContractTest.PlannerAgent)

    assert {:error, {:streaming_unsupported, :planner_cleaner_not_incremental}} =
             Spectre.stream(planner_instance, "stream this",
               model: @model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [
                 test_pid: self(),
                 batches: successful_batches("unused")
               ]
             )

    refute_receive {:stream_adapter, :opened, _session}
  end

  test "sanitizer opt-out marks every delta as unsanitized" do
    instance = start_instance()

    {:ok, stream} =
      start_stream(instance, successful_batches("raw provisional"), sanitize_reply: false)

    events = Enum.to_list(stream)
    deltas = Enum.filter(events, &(&1.kind == :delta))
    assert deltas != []
    assert Enum.all?(deltas, &(&1.content_class == :unsanitized))

    assert %StreamEvent{kind: :result, payload: %Result{reply_text: "raw provisional"}} =
             List.last(events)
  end

  test "Instance stream controls reject malformed options and forged handles" do
    instance = start_instance()

    assert {:error, :invalid_stream_options} = Instance.stream(instance, "stream", :invalid)

    {:ok, stream} = start_stream(instance, successful_batches("control target"))

    assert {:error, :invalid_stream_options} =
             Instance.resume_stream(instance, stream, :invalid)

    assert {:error, :invalid_stream_options} =
             Instance.steer_stream(instance, stream, "replacement", :invalid)

    assert {:error, :invalid_stream_options} =
             Instance.cancel_stream(instance, stream, :requested, :invalid)

    assert {:error, :stream_resume_unavailable} = Instance.resume_stream(instance, stream)

    forged_token = %{stream | consumer_token: "forged-consumer-token"}
    stale_handle = %{stream | dispatch_id: "stale-dispatch"}

    assert {:error, :invalid_stream_consumer_token} =
             Instance.steer_stream(instance, forged_token, "replacement")

    assert {:error, :stale_stream_handle} =
             Instance.steer_stream(instance, stale_handle, "replacement")

    assert {:error, :empty_stream_steer_input} =
             Instance.steer_stream(instance, stream, "")

    assert {:error, {:stream_steer_input_too_large, 8, 4}} =
             Instance.steer_stream(
               instance,
               stream,
               "too-long",
               stream_steer_max_bytes: 4
             )

    assert {:error, {:invalid_stream_steer_input, Protocol.UndefinedError}} =
             Instance.steer_stream(instance, stream, fn -> :not_stringable end)

    assert {:error, :invalid_stream_consumer_token} =
             Instance.cancel_stream(instance, forged_token, :requested)

    assert :ok = Instance.cancel_stream(instance, stream, :requested)
    assert :ok = Instance.cancel_stream(instance, stream, :requested)

    assert {:error, {:inference_attempt_failed, 1, {:cancelled, :requested}}} =
             Spectre.await_result(stream, 1_000)
  end

  test "Instance normalizes budget keys and fails closed on invalid accounting" do
    instance = start_instance(max_runs: 32)

    invalid_cases = [
      {[inference_budget: :invalid], :invalid_inference_budget},
      {[inference_budget: [:not_keyword]], :invalid_inference_budget},
      {[
         inference_budget: %{"unknown" => 1}
       ], {:unknown_inference_budget_limit, "unknown"}},
      {[
         inference_budget: %{unknown: 1}
       ], {:unknown_inference_budget_limit, :unknown}},
      {[
         inference_budget: %{attempts: 0}
       ], {:invalid_inference_budget_limit, :attempts, 0}},
      {[
         inference_budget: %{output_tokens: :many}
       ], {:invalid_inference_budget_limit, :output_tokens, :many}},
      {[
         stream_max_attempts: 0
       ], {:invalid_inference_attempt_limit, 0}},
      {[
         inference_pricing_ref: ""
       ], {:invalid_inference_pricing_ref, ""}},
      {[
         inference_budget: %{cost: 1.0}
       ], :inference_cost_budget_requires_pricing_ref},
      {[
         inference_budget: %{cost: 1.0},
         inference_pricing_ref: "pricing:test:v1"
       ], :inference_cost_budget_usage_unavailable}
    ]

    Enum.each(invalid_cases, fn {opts, expected} ->
      assert {:error, ^expected} =
               start_stream(instance, successful_batches("unused"), opts)
    end)

    all_string_keys = %{
      "input_tokens" => 10,
      "output_tokens" => 10,
      "total_tokens" => 20,
      "cost" => 1.0,
      "attempts" => 2,
      "duration_ms" => 1_000
    }

    assert {:error, :inference_cost_budget_usage_unavailable} =
             start_stream(instance, successful_batches("unused"),
               inference_budget: all_string_keys,
               inference_pricing_ref: "pricing:test:v1"
             )

    assert {:error, :inference_cost_budget_usage_unavailable} =
             Instance.ask(instance, "stream this",
               model: @model,
               plan_actions?: false,
               inference_budget: %{cost: 1.0},
               inference_pricing_ref: "pricing:test:v1"
             )
  end

  test "Instance control conflicts are fenced before provider or Run mutation" do
    instance = start_instance()
    {:ok, stream} = start_stream(instance, [:stall])
    control_revision = stream.control_revision

    pending =
      Command.new(stream.inference_id, :steer,
        id: "pending-steer",
        correlation_id: stream.run_id,
        causation_id: stream.invocation_id,
        base_revision: stream.control_revision,
        provenance: %{source: :test}
      )
      |> Command.committed()

    replace_inference_control(instance, stream.inference_id, %{
      generation: stream.control_revision + 1,
      pending: nil,
      last_command: nil,
      history: []
    })

    assert {:error, {:stale_inference_control_revision, ^control_revision, next_control_revision}} =
             Instance.cancel_stream(instance, stream, :requested)

    assert next_control_revision == control_revision + 1

    replace_inference_control(instance, stream.inference_id, %{
      generation: stream.control_revision,
      pending: pending,
      last_command: nil,
      history: []
    })

    assert {:error, {:inference_control_pending, "pending-steer"}} =
             Instance.cancel_stream(instance, stream, :requested)

    assert {:error, {:inference_control_pending, "pending-steer"}} =
             Instance.steer_stream(instance, stream, "replacement")

    applied = pending |> Command.applied()

    replace_inference_control(instance, stream.inference_id, %{
      generation: stream.control_revision,
      pending: nil,
      last_command: applied,
      history: [applied]
    })

    assert {:error, {:duplicate_inference_control, "pending-steer"}} =
             Instance.steer_stream(instance, stream, "replacement", command_id: "pending-steer")

    assert {:error, :invalid_loop_control_identity} =
             Instance.cancel_stream(instance, stream, :requested, command_id: "")

    assert {:error, :invalid_loop_control_identity} =
             Instance.steer_stream(instance, stream, "replacement", command_id: "")
  end

  test "stream ownership rejects malformed handles and missing or terminal Runs" do
    instance = start_instance()
    {:ok, stream} = start_stream(instance, [:stall])

    assert {:error, :invalid_stream_consumer_token} =
             Instance.cancel_stream(instance, %{stream | consumer_token: nil}, :requested)

    :sys.replace_state(instance, fn data ->
      run = Map.fetch!(data.runs, stream.run_id)
      %{data | runs: Map.put(data.runs, run.id, %{run | status: :complete})}
    end)

    assert {:error, :invocation_terminal} =
             Instance.steer_stream(instance, stream, "replacement")

    :sys.replace_state(instance, fn data ->
      %{data | runs: Map.delete(data.runs, stream.run_id)}
    end)

    assert {:error, :unknown_stream_run} =
             Instance.steer_stream(instance, stream, "replacement")
  end

  test "failed steer settlement rejects the command canonically and keeps the old epoch" do
    instance = start_instance()
    {:ok, stream} = start_stream(instance, [:stall])

    :sys.replace_state(instance, fn data ->
      run = Map.fetch!(data.runs, stream.run_id)
      %Budget{} = budget = run.inference_continuation.budget
      attempt_id = run.waiting.attempt_id

      conflicting = %{
        budget
        | settlements: %{
            attempt_id => %{
              usage: %Usage{output_tokens: 1, total_tokens: 1},
              status: :confirmed
            }
          }
      }

      continuation = %{run.inference_continuation | budget: conflicting}
      %{data | runs: Map.put(data.runs, run.id, %{run | inference_continuation: continuation})}
    end)

    assert {:error, {:inference_budget_settlement_failed, _reason}} =
             Instance.steer_stream(instance, stream, "replacement",
               command_id: "settlement-conflict"
             )

    data = :sys.get_state(instance)
    {:ok, controls} = Spectre.Instance.Canonical.fetch(data.canonical, :inference_control)
    control = Map.fetch!(controls, stream.inference_id)

    assert control.pending == nil
    assert control.last_command.id == "settlement-conflict"
    assert control.last_command.status == :rejected
    assert data.runs[stream.run_id].waiting.id == stream.invocation_id
  end

  defp start_stream(instance, batches, extra \\ []) do
    opts = [
      model: @model,
      plan_actions?: false,
      stream_adapter: @adapter,
      stream_adapter_opts: [test_pid: self(), batches: batches],
      stream_open_timeout: 1_000,
      stream_provider_stall_timeout: 1_000,
      stream_consumer_idle_timeout: 1_000,
      stream_result_timeout: 1_000,
      stream_terminal_retention: 2_000
    ]

    Spectre.stream(instance, "stream this", Keyword.merge(opts, extra))
  end

  defp successful_batches(text) do
    split_at = max(div(byte_size(text), 2), 1)
    <<first::binary-size(^split_at), second::binary>> = text

    [
      [
        ProviderEvent.new(:started,
          provider_sequence: 0,
          provider_request_id: "fixture-request"
        ),
        ProviderEvent.delta(first,
          provider_sequence: 1,
          usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3},
          usage_quality: :provider
        )
      ],
      [
        ProviderEvent.new(:usage,
          provider_sequence: 2,
          usage: %{input_tokens: 2, output_tokens: 2, total_tokens: 4},
          usage_quality: :provider
        ),
        ProviderEvent.delta(second,
          provider_sequence: 3,
          usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5},
          usage_quality: :provider
        ),
        ProviderEvent.completed(text,
          provider_sequence: 4,
          usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5},
          usage_quality: :provider
        )
      ]
    ]
  end

  defp start_instance(extra \\ []) do
    opts =
      [
        agent: @agent,
        subject: Subject.new("stream-contract-#{System.unique_integer([:positive, :monotonic])}"),
        idle: false
      ]
      |> Keyword.merge(extra)

    start_supervised!({Instance, opts})
  end

  defp replace_inference_control(instance, inference_id, control) do
    :sys.replace_state(instance, fn data ->
      {:ok, %Section{} = current} =
        Sections.fetch(data.canonical.sections, :inference_control)

      value = Map.put(current.value, inference_id, control)
      section = %{current | value: value}
      sections = Sections.put(data.canonical.sections, :inference_control, section)
      %{data | canonical: %{data.canonical | sections: sections}}
    end)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_attempt_failure(events, reason) do
    assert %StreamEvent{
             kind: :failed,
             payload: {:inference_attempt_failed, 1, ^reason}
           } = List.last(events)
  end

  defp collect_inference_events(events) do
    receive do
      {:spectre, :inference_event, event} -> collect_inference_events([event | events])
    after
      50 -> Enum.reverse(events)
    end
  end
end
