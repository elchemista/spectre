defmodule SpectreInferenceStreamSessionLifecycleContractTest.Adapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts), do: MapSet.new([:stream, :pull_transport, :resume])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, opts), do: open_or_resume(opts, :open)

  @impl Spectre.Inference.StreamAdapter
  def resume(_descriptor, cursor, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:adapter_resumed, cursor, opts})
    open_or_resume(opts, :resume)
  end

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(%{opts: opts} = state) do
    case Keyword.get(opts, :mode) do
      :request_error -> {:error, :request_failed}
      :request_invalid -> :invalid_request_reply
      :request_raise -> raise "request failed"
      :request_throw -> throw(:request_failed)
      _other -> deliver_next(state)
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(message, %{opts: opts} = state) do
    case {Keyword.get(opts, :mode), message} do
      {:transport_error, _message} -> {:error, :transport_failed, state}
      {:transport_invalid, _message} -> :invalid_transport_reply
      {:transport_raise, _message} -> raise "transport failed"
      {:transport_throw, _message} -> throw(:transport_failed)
      {_mode, {:session_fixture, ref, :ignore}} when ref == state.ref -> {:ignore, state}
      {_mode, {:session_fixture, ref, events}} when ref == state.ref -> {:ok, events, state}
      {_mode, _message} -> {:ignore, state}
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def cancel(%{opts: opts}, reason) do
    send(Keyword.fetch!(opts, :test_pid), {:adapter_cancelled, reason})

    case Keyword.get(opts, :cancel_reply, :ok) do
      :raise -> raise "cancel failed"
      :throw -> throw(:cancel_failed)
      reply -> reply
    end
  end

  defp open_or_resume(opts, operation) do
    case Keyword.get(opts, :mode) do
      :open_error ->
        {:error, :open_failed}

      :open_invalid ->
        :invalid_open_reply

      :open_map ->
        %{invalid: :open_reply}

      :open_raise ->
        raise "open failed"

      :open_throw ->
        throw(:open_failed)

      _other ->
        state = %{opts: opts, ref: make_ref(), batches: Keyword.get(opts, :batches, [])}
        send(Keyword.fetch!(opts, :test_pid), {:adapter_opened, operation, self()})
        {:ok, state, Keyword.get(opts, :provider_metadata, %{provider: :fixture})}
    end
  end

  defp deliver_next(%{batches: [batch | rest]} = state) do
    send(state.opts[:test_pid], {:adapter_credit, self()})

    case batch do
      {:ignore_then, events} ->
        send(self(), {:session_fixture, state.ref, :ignore})
        send(self(), {:session_fixture, state.ref, events})

      events ->
        send(self(), {:session_fixture, state.ref, events})
    end

    {:ok, %{state | batches: rest}}
  end

  defp deliver_next(state) do
    send(state.opts[:test_pid], {:adapter_credit, self()})
    {:ok, state}
  end
end

defmodule SpectreInferenceStreamSessionLifecycleContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"
end

defmodule SpectreInferenceStreamSessionLifecycleContractTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Prepared
  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Inference.Selection
  alias Spectre.Inference.StreamCapacity
  alias Spectre.Inference.StreamEvent
  alias Spectre.Inference.StreamSession
  alias Spectre.Inference.Usage
  alias Spectre.Input
  alias Spectre.Invocation
  alias Spectre.Prompt.Plan
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.InferenceContinuation
  alias Spectre.State

  @adapter SpectreInferenceStreamSessionLifecycleContractTest.Adapter
  @agent SpectreInferenceStreamSessionLifecycleContractTest.Agent
  @registry SpectreInferenceStreamSessionLifecycleContractTest.Registry
  @capacity SpectreInferenceStreamSessionLifecycleContractTest.Capacity
  @token "stream-session-consumer-token"

  setup do
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({StreamCapacity, name: @capacity, limit: 32})
    :ok
  end

  test "session construction rejects malformed durable and runtime bindings" do
    valid = session_options(test_pid: self())

    invalid = [
      Keyword.delete(valid, :prepared),
      Keyword.put(valid, :prepared, %{valid[:prepared] | stream_adapter: nil}),
      Keyword.put(valid, :prepared, %{valid[:prepared] | provider_opts: :invalid}),
      Keyword.put(valid, :instance, :not_a_pid),
      Keyword.put(valid, :consumer_token, ""),
      Keyword.put(valid, :budget_snapshot, :invalid),
      Keyword.put(valid, :stream_open_timeout, 0),
      Keyword.put(valid, :stream_attach_timeout, 4_294_967_296),
      Keyword.put(valid, :stream_max_transport_chunk_bytes, 0),
      Keyword.put(valid, :stream_max_parser_residual_bytes, :unbounded),
      Keyword.put(valid, :max_sanitizer_lookahead_bytes, 1),
      Keyword.put(valid, :resume_from, %{usage_quality: :approximate}),
      Keyword.put(valid, :resume_from, %{usage: %{output_bytes: 1}, output_bytes: 2}),
      Keyword.put(valid, :resume_from, %{provider_sequence: -1})
    ]

    Enum.each(invalid, fn opts ->
      assert {:stop, _reason} = Task.async(fn -> StreamSession.init(opts) end) |> Task.await()
    end)
  end

  test "authorization, one-shot ownership, pending demand, cancellation, and terminal retention" do
    context = start_session(mode: :stall, ack: :auto, cancel_reply: {:error, :unknown_remote})
    session = context.session
    claim = make_ref()
    consumer = self()

    assert {:error, :invalid_stream_consumer_token} =
             :gen_statem.call(
               context.session,
               {:next, "wrong", consumer, claim, 1}
             )

    assert {:error, :invalid_stream_demand} =
             :gen_statem.call(
               context.session,
               {:next, @token, consumer, claim, 0}
             )

    pending = next_task(context, consumer, claim, 1)
    assert_receive {:adapter_opened, :open, ^session}

    assert {:error, :stream_next_already_pending} =
             :gen_statem.call(
               context.session,
               {:next, @token, consumer, claim, 1}
             )

    assert {:ok, [%StreamEvent{kind: :already_consumed}]} =
             :gen_statem.call(
               context.session,
               {:next, @token, consumer, make_ref(), 1}
             )

    assert {:error, :invalid_stream_consumer_token} =
             :gen_statem.call(context.session, {:cancel, "wrong", :requested})

    assert :ok = :gen_statem.call(context.session, {:cancel, @token, :requested})
    assert_receive {:adapter_cancelled, :requested}
    assert {:ok, [%StreamEvent{kind: :cancelled}]} = Task.await(pending, 1_000)

    assert :ok = :gen_statem.call(context.session, {:cancel, @token, :duplicate})

    assert {:error, {:cancelled, :requested}} =
             :gen_statem.call(context.session, {:await_result, @token, make_ref()})

    # Once the queue has drained the retained terminal event remains
    # observable to the original consumer without manufacturing a new fence.
    assert {:ok, [%StreamEvent{kind: :cancelled}]} =
             :gen_statem.call(
               context.session,
               {:next, @token, consumer, claim, 1}
             )
  end

  test "open and demand callback failures always become terminal receipts" do
    cases = [
      {:open_error, :open_failed},
      {:open_invalid, :invalid_stream_adapter_open_reply},
      {:open_raise, :stream_adapter_exception},
      {:open_throw, :error},
      {:request_error, :provider_stream_request_failed},
      {:request_invalid, :provider_stream_request_failed},
      {:request_raise, :provider_stream_request_failed},
      {:request_throw, :provider_stream_request_failed}
    ]

    Enum.each(cases, fn {mode, expected_class} ->
      context = start_session(mode: mode, ack: :auto)
      result = context |> next_task(self(), make_ref(), 1) |> Task.await(1_000)

      assert {:ok, [%StreamEvent{kind: :failed, payload: reason}]} = result
      assert failure_class(reason) == expected_class
    end)
  end

  test "ignored, errored, malformed, raised, and thrown transport replies are explicit" do
    for mode <- [:transport_error, :transport_invalid, :transport_raise, :transport_throw] do
      context = start_session(mode: mode, batches: [:transport], ack: :auto)
      result = context |> next_task(self(), make_ref(), 1) |> Task.await(1_000)
      assert {:ok, [%StreamEvent{kind: :failed}]} = result
    end

    context =
      start_session(
        batches: [
          {:ignore_then, [ProviderEvent.new(:started, provider_sequence: 0)]},
          [ProviderEvent.new(:failed, payload: :provider_failed, provider_sequence: 1)]
        ],
        ack: :auto
      )

    session = context.session
    pending = next_task(context, self(), make_ref(), 1)
    assert_receive {:adapter_credit, ^session}
    send(context.session, :unowned_message)

    assert {:ok, [%StreamEvent{kind: :failed, payload: :provider_failed}]} =
             Task.await(pending, 1_000)
  end

  test "phase timeouts distinguish open, provider stall, consumer idle, commit, and result" do
    open = start_session(ack: :auto, stream_open_timeout: 15)
    assert_failed_next(open, :provider_open_timeout)

    stall =
      start_session(
        batches: [[ProviderEvent.new(:started, provider_sequence: 0)]],
        ack: :auto,
        stream_provider_stall_timeout: 15
      )

    assert_failed_next(stall, :provider_stall_timeout)

    idle =
      start_session(
        batches: [
          [
            ProviderEvent.new(:started, provider_sequence: 0),
            ProviderEvent.delta("delta", provider_sequence: 1)
          ]
        ],
        ack: :auto,
        stream_consumer_idle_timeout: 15
      )

    idle_session = idle.session
    claim = make_ref()

    assert {:ok, [%StreamEvent{kind: :delta}]} =
             idle |> next_task(self(), claim, 1) |> Task.await(1_000)

    assert_receive {:session_receipt, ^idle_session, %{outcome: {:error, :consumer_too_slow}}},
                   1_000

    assert {:ok, [%StreamEvent{kind: :failed, payload: :consumer_too_slow}]} =
             :gen_statem.call(idle.session, {:next, @token, self(), claim, 1})

    commit = start_session(mode: :open_error, ack: :hold, stream_provider_stall_timeout: 15)
    assert_failed_next(commit, :terminal_commit_timeout)

    result =
      start_session(
        batches: [successful_events("complete")],
        ack: :attempt_only,
        stream_result_timeout: 15
      )

    result_claim = make_ref()

    assert {:ok, [%StreamEvent{kind: :inference_completed}]} =
             result |> next_task(self(), result_claim, 1) |> Task.await(1_000)

    assert {:ok, [%StreamEvent{kind: :failed, payload: :stream_result_timeout}]} =
             result |> next_task(self(), result_claim, 1) |> Task.await(1_000)
  end

  test "absolute duration and budget timers cannot be renewed by transport activity" do
    duration = start_session(ack: :auto, stream_max_duration_ms: 15)
    assert_failed_next(duration, :stream_max_duration_exceeded)

    deadline =
      start_session(
        ack: :auto,
        budget_snapshot:
          Spectre.Inference.BudgetSnapshot.new(
            inference_id: "session",
            attempt_id: "attempt",
            deadline_at: System.system_time(:millisecond) + 15
          )
      )

    assert_failed_next(deadline, :inference_deadline_exceeded)
  end

  test "ephemeral heartbeats do not consume bounded determinism evidence" do
    context =
      start_session(
        mode: :stall,
        ack: :auto,
        inference_heartbeat_interval: 1,
        determinism_opts: [determinism_sample_limit: 1]
      )

    session = context.session
    pending = next_task(context, self(), make_ref(), 1)
    assert_receive {:adapter_opened, :open, ^session}

    {:opening, data} = :sys.get_state(session)
    ref = data.adapter_state.ref

    events = [
      ProviderEvent.new(:started, provider_sequence: 0),
      ProviderEvent.new(:usage, provider_sequence: 1, usage: %{output_tokens: 1}),
      ProviderEvent.new(:usage, provider_sequence: 2, usage: %{output_tokens: 2}),
      ProviderEvent.new(:usage, provider_sequence: 3, usage: %{output_tokens: 3})
    ]

    Enum.each(events, fn event ->
      Process.sleep(2)
      send(session, {:session_fixture, ref, [event]})
    end)

    Process.sleep(2)

    send(
      session,
      {:session_fixture, ref, [ProviderEvent.completed("bounded", provider_sequence: 4)]}
    )

    assert {:ok, [%StreamEvent{kind: :inference_completed}]} = Task.await(pending, 1_000)

    assert_receive {:session_receipt, ^session, %{metadata: %{nondeterminism_samples: []}}}
  end

  test "provider framing rejects duplicate starts, oversized deltas, large responses, and post-terminal events" do
    cases = [
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.new(:started, provider_sequence: 1)
      ],
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.delta("too large", provider_sequence: 1)
      ],
      successful_events("response too large"),
      [
        ProviderEvent.new(:started, provider_sequence: 0),
        ProviderEvent.completed("done", provider_sequence: 1),
        ProviderEvent.delta("late", provider_sequence: 2)
      ]
    ]

    Enum.with_index(cases)
    |> Enum.each(fn {events, index} ->
      limits =
        case index do
          1 -> [stream_max_delta_bytes: 2]
          2 -> [model_reply_max_bytes: 2]
          _other -> []
        end

      context = start_session([batches: [events], ack: :auto] ++ limits)

      assert {:ok, [%StreamEvent{kind: :failed}]} =
               context |> next_task(self(), make_ref(), 1) |> Task.await(1_000)
    end)

    # A duplicate start in a later transport item is a session-ordering
    # violation, not merely an invalid single adapter batch.
    duplicate_across_batches =
      start_session(
        batches: [
          [ProviderEvent.new(:started, provider_sequence: 0)],
          [ProviderEvent.new(:started, provider_sequence: 1)]
        ],
        ack: :auto
      )

    assert {:ok, [%StreamEvent{kind: :failed, payload: :provider_started_event_out_of_order}]} =
             duplicate_across_batches
             |> next_task(self(), make_ref(), 1)
             |> Task.await(1_000)
  end

  test "state callbacks retain ownership, timeout, and terminal fence invariants" do
    context = start_session(ack: :auto)
    {_state, data} = :sys.get_state(context.session)
    from = {self(), make_ref()}
    occupied = %{data | consumer: self(), consumer_claim: make_ref()}

    assert {:keep_state_and_data,
            [{:reply, ^from, {:ok, [%StreamEvent{kind: :already_consumed}]}}]} =
             StreamSession.handle_event(
               {:call, from},
               {:next, @token, self(), make_ref(), 1},
               :awaiting_consumer,
               occupied
             )

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :invalid_stream_consumer_token}}]} =
             StreamSession.handle_event(
               {:call, from},
               {:next, "wrong", self(), make_ref(), 1},
               :terminal,
               data
             )

    assert {:keep_state_and_data, [{:reply, ^from, {:error, :invalid_stream_consumer_token}}]} =
             StreamSession.handle_event(
               {:call, from},
               {:await_result, "wrong", make_ref()},
               :awaiting_consumer,
               data
             )

    # Corrupt process-local capabilities must fail closed even if comparing
    # their byte lengths would otherwise raise.
    assert {:keep_state_and_data, [{:reply, ^from, {:error, :invalid_stream_consumer_token}}]} =
             StreamSession.handle_event(
               {:call, from},
               {:next, @token, self(), make_ref(), 1},
               :terminal,
               %{data | consumer_token: nil}
             )

    claim = make_ref()
    attached = %{data | consumer: self(), consumer_claim: claim, pending_next: nil}

    assert {:keep_state, %{pending_next: %{demand: 1}}} =
             StreamSession.handle_event(
               {:call, from},
               {:next, @token, self(), claim, 1},
               :opening,
               attached
             )

    for {state, expected_kind} <- [
          {:terminal, :stream_expired},
          {:superseded, :superseded},
          {:interrupted, :interrupted}
        ] do
      terminal_data = %{data | consumer: nil, terminal_event: nil, queue: []}

      assert {:keep_state, returned,
              [{:reply, ^from, {:ok, [%StreamEvent{kind: ^expected_kind}]}}]} =
               StreamSession.handle_event(
                 {:call, from},
                 {:next, @token, self(), make_ref(), 1},
                 state,
                 terminal_data
               )

      Process.demonitor(returned.consumer_monitor, [:flush])
    end
  end

  test "transport callback edge cases preserve pull credit and bounded recovery evidence" do
    context = start_session(mode: :stall, ack: :auto)
    session = context.session
    claim = make_ref()
    pending = next_task(context, self(), claim, 1)
    assert_receive {:adapter_opened, :open, ^session}
    assert_eventually(fn -> match?({:opening, _data}, :sys.get_state(session)) end)

    {:opening, data} = :sys.get_state(session)
    ref = data.adapter_state.ref
    empty_item = {:session_fixture, ref, []}

    assert {:keep_state, %{transport_pending?: true}} =
             StreamSession.handle_event(:info, empty_item, :opening, data)

    assert {:next_state, :streaming, _next, _actions} =
             StreamSession.handle_event(:info, empty_item, :streaming, data)

    assert {:next_state, :streaming, _next, _actions} =
             StreamSession.handle_event(:info, :unowned, :streaming, data)

    invalid_checkpoint = %{
      data
      | last_heartbeat_at: nil,
        prepared: %{
          data.prepared
          | provider_opts:
              Keyword.put(data.prepared.provider_opts, :stream_checkpoint_max_bytes, :invalid)
        }
    }

    started =
      {:session_fixture, ref, [ProviderEvent.new(:started, provider_sequence: 0)]}

    assert {:next_state, :streaming, _next, _actions} =
             StreamSession.handle_event(:info, started, :opening, invalid_checkpoint)

    # Once a terminal receipt exists, later local failures may drive cleanup
    # but cannot overwrite the original terminal evidence.
    already_terminal = %{data | terminal_outcome: {:error, :first_failure}}

    assert {:next_state, :committing_terminal, %{terminal_outcome: {:error, :first_failure}}, _} =
             StreamSession.handle_event(
               :info,
               {:stream_transport_request_failed, :late_failure},
               :opening,
               already_terminal
             )

    assert :ok = :gen_statem.call(session, {:cancel, @token, :test_cleanup})
    assert {:ok, [%StreamEvent{kind: :cancelled}]} = Task.await(pending, 1_000)
  end

  test "waiter death and ambiguous cancellation remain terminal and capacity-safe" do
    waiter_context = start_session(ack: :auto)
    parent = self()

    {waiter, waiter_monitor} =
      spawn_monitor(fn ->
        send(parent, :result_waiter_started)

        :gen_statem.call(
          waiter_context.session,
          {:await_result, @token, make_ref()},
          5_000
        )
      end)

    assert_receive :result_waiter_started
    assert_receive {:adapter_opened, :open, waiter_session}
    assert waiter_session == waiter_context.session
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :killed}
    assert_receive {:adapter_cancelled, :result_waiter_gone}

    ambiguous = start_session(mode: :stall, ack: :auto, cancel_reply: %{unexpected: :reply})
    pending = next_task(ambiguous, self(), make_ref(), 1)
    assert_receive {:adapter_opened, :open, ambiguous_session}
    assert ambiguous_session == ambiguous.session
    assert :ok = :gen_statem.call(ambiguous.session, {:cancel, @token, :ambiguous_cancel})
    assert_receive {:adapter_cancelled, :ambiguous_cancel}

    assert_receive {:session_receipt, ^ambiguous_session,
                    %{metadata: %{remote_status: :ambiguous}}}

    assert {:ok, [%StreamEvent{kind: :cancelled}]} = Task.await(pending, 1_000)
  end

  test "terminal cleanup classifies failures without trusting process-local state" do
    context = start_session(ack: :auto)
    {_state, data} = :sys.get_state(context.session)
    invocation_id = data.invocation.id

    for {reason, expected_kind} <- [
          {:superseded, :superseded},
          {:interrupted, :interrupted},
          {:ambiguous, :ambiguous},
          {{:cancelled, :requested}, :cancelled},
          {{:inference_attempt_failed, 1, :superseded}, :superseded}
        ] do
      terminal_data = %{data | capacity_released?: true, result: nil, terminal_event: nil}

      assert {:next_state, :terminal, %{terminal_event: %StreamEvent{kind: ^expected_kind}},
              _actions} =
               StreamSession.handle_event(
                 :info,
                 {:spectre, :stream_attempt_failed, invocation_id, reason},
                 :opening,
                 terminal_data
               )
    end

    # Capacity release is best effort during terminal cleanup. A dead local
    # capacity process cannot turn an interruption into a session crash.
    for reason <- [{:shutdown, :instance_restart}, %{opaque: :reason}] do
      monitor = make_ref()

      interrupted = %{
        data
        | instance: self(),
          instance_monitor: monitor,
          capacity_server: SpectreInferenceStreamSessionLifecycleContractTest.MissingCapacity,
          capacity_released?: false,
          result: nil,
          terminal_event: nil
      }

      assert {:next_state, :interrupted, %{capacity_released?: true}, _actions} =
               StreamSession.handle_event(
                 :info,
                 {:DOWN, monitor, :process, self(), reason},
                 :opening,
                 interrupted
               )
    end

    waiter_monitor = make_ref()
    waiter = %{from: {self(), make_ref()}, ref: make_ref(), monitor: waiter_monitor}

    assert {:keep_state, %{result_waiters: []}} =
             StreamSession.handle_event(
               :info,
               {:DOWN, waiter_monitor, :process, self(), :normal},
               :terminal,
               %{data | result_waiters: [waiter], result_only?: false}
             )
  end

  test "result-only waiters are bounded and abandonment cancels unobserved work" do
    context = start_session(ack: :auto, stream_max_awaiters: 1)
    session = context.session
    first_ref = make_ref()

    first =
      Task.async(fn ->
        :gen_statem.call(context.session, {:await_result, @token, first_ref}, 1_000)
      end)

    assert_receive {:adapter_opened, :open, ^session}

    assert {:error, :stream_awaiter_capacity_reached} =
             :gen_statem.call(context.session, {:await_result, @token, make_ref()})

    assert {:error, :invalid_stream_awaiter} =
             :gen_statem.call(context.session, {:await_result, @token, :invalid})

    :gen_statem.cast(context.session, {:abandon_result_waiter, @token, first_ref})
    assert_receive {:adapter_cancelled, :result_waiter_gone}
    _ = Task.shutdown(first, :brutal_kill)
    refute Process.alive?(first.pid)

    # Invalid abandonment capabilities are deliberately ignored.
    :gen_statem.cast(context.session, {:abandon_result_waiter, "wrong", make_ref()})
    assert Process.alive?(context.session)
  end

  test "resume restores provider cursor and usage floors through the adapter contract" do
    usage = %Usage{input_tokens: 2, output_tokens: 3, total_tokens: 5, output_bytes: 12}

    context =
      start_session(
        ack: :auto,
        resume_from: %{
          provider_request_id: "provider-request",
          resume_cursor: "cursor-7",
          provider_sequence: 7,
          usage: usage,
          usage_quality: :provider,
          output_bytes: 12
        },
        batches: [[ProviderEvent.new(:failed, payload: :resumed_failure, provider_sequence: 8)]]
      )

    assert {:ok, [%StreamEvent{kind: :failed, payload: :resumed_failure}]} =
             context |> next_task(self(), make_ref(), 1) |> Task.await(1_000)

    assert_receive {:adapter_resumed, "cursor-7", opts}
    assert opts[:resume_provider_request_id] == "provider-request"
    assert opts[:resume_usage].output_tokens == 3
    assert opts[:resume_provider_sequence] == 7
    assert opts[:max_transport_chunk_bytes] == 256_000
    assert opts[:max_parser_residual_bytes] == 256_000
  end

  test "conservative stream accounting labels provider counters when a floor changes them" do
    snapshot =
      Spectre.Inference.BudgetSnapshot.new(
        inference_id: "session",
        attempt_id: "attempt",
        reserved: %{input_tokens: 4},
        estimation_policy: :conservative
      )

    response =
      Response.new(%{
        text: String.duplicate("x", 100),
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      })

    context =
      start_session(
        ack: :auto,
        budget_snapshot: snapshot,
        batches: [
          [
            ProviderEvent.new(:started, provider_sequence: 0),
            ProviderEvent.completed(response,
              provider_sequence: 1,
              usage_quality: :provider
            )
          ]
        ]
      )

    assert {:ok,
            [
              %StreamEvent{
                kind: :inference_completed,
                usage_quality: :estimated,
                usage: %Usage{input_tokens: 4, output_tokens: 25, total_tokens: 29}
              }
            ]} = context |> next_task(self(), make_ref(), 1) |> Task.await(1_000)

    assert_receive {:session_receipt, _, %{usage_quality: :estimated}}
  end

  test "session exposes only complete UTF-8 text when provider deltas split a codepoint" do
    <<left::binary-size(2), right::binary>> = "🙂"

    context =
      start_session(
        ack: :auto,
        batches: [
          [
            ProviderEvent.new(:started, provider_sequence: 0),
            ProviderEvent.delta(left, provider_sequence: 1)
          ],
          [
            ProviderEvent.delta(right, provider_sequence: 2),
            ProviderEvent.completed("🙂", provider_sequence: 3)
          ]
        ]
      )

    claim = make_ref()

    assert {:ok, [%StreamEvent{kind: :delta, payload: "🙂"}]} =
             context |> next_task(self(), claim, 1) |> Task.await(1_000)

    assert {:ok, [%StreamEvent{kind: :inference_completed}]} =
             context |> next_task(self(), claim, 1) |> Task.await(1_000)
  end

  test "result-only consumers receive both live and retained terminal results" do
    context = start_session(batches: [successful_events("awaited")], ack: :auto)

    assert {:ok, %Result{reply_text: "awaited"} = result} =
             :gen_statem.call(
               context.session,
               {:await_result, @token, make_ref()},
               1_000
             )

    assert {:ok, ^result} =
             :gen_statem.call(
               context.session,
               {:await_result, @token, make_ref()},
               1_000
             )

    assert {:error, :invalid_stream_consumer_token} =
             :gen_statem.call(
               context.session,
               {:await_result, "wrong", make_ref()},
               1_000
             )
  end

  test "Instance notifications remain idempotent across commit and result hand-offs" do
    committing =
      start_session(
        batches: [[ProviderEvent.new(:failed, payload: :provider_failed, provider_sequence: 0)]],
        ack: :hold,
        cancel_reply: :invalid
      )

    pending = next_task(committing, self(), make_ref(), 1)

    assert_receive {:session_receipt, session, %{outcome: {:error, :provider_failed}}}
    assert session == committing.session
    assert_eventually(fn -> session_state(session) == :committing_terminal end)

    assert {:error, :invocation_terminal} =
             :gen_statem.call(session, {:cancel, @token, :too_late})

    send(
      session,
      {:spectre, :stream_cancel_committed, committing.invocation.id, :duplicate,
       "duplicate-command"}
    )

    send(session, {:spectre, :stream_result, committing.invocation.id, {:ok, :too_early}})
    assert Process.alive?(session)

    send(session, {:spectre, :stream_attempt_failed, committing.invocation.id, :provider_failed})

    assert {:ok, [%StreamEvent{kind: :failed, payload: :provider_failed}]} =
             Task.await(pending, 1_000)

    # Duplicate terminal notifications neither append an event nor renew the
    # retention timer.
    send(session, {:spectre, :stream_result, committing.invocation.id, {:ok, :late}})
    send(session, {:spectre, :stream_attempt_failed, committing.invocation.id, :late})
    assert Process.alive?(session)
  end

  test "invalid committed responses and post-processing failures terminate explicitly" do
    invalid_response =
      start_session(batches: [successful_events("invalid response")], ack: :hold)

    invalid_pending = next_task(invalid_response, self(), make_ref(), 1)

    assert_receive {:session_receipt, invalid_session, %{outcome: {:ok, %Response{}}}}
    assert invalid_session == invalid_response.session

    send(
      invalid_session,
      {:spectre, :stream_attempt_committed, invalid_response.invocation.id,
       %Response{text: <<255>>}}
    )

    assert {:ok, [%StreamEvent{kind: :failed, payload: :invalid_inference_response_text}]} =
             Task.await(invalid_pending, 1_000)

    postprocess = start_session(batches: [successful_events("postprocess")], ack: :attempt_only)
    claim = make_ref()

    assert {:ok, [%StreamEvent{kind: :inference_completed}]} =
             postprocess |> next_task(self(), claim, 1) |> Task.await(1_000)

    postprocess_pending = next_task(postprocess, self(), claim, 1)

    send(
      postprocess.session,
      {:spectre, :stream_result, postprocess.invocation.id, {:error, :postprocessing_failed}}
    )

    assert {:ok, [%StreamEvent{kind: :failed, payload: :postprocessing_failed}]} =
             Task.await(postprocess_pending, 1_000)
  end

  test "terminal sessions accept one late consumer and long deadlines are rechecked" do
    unattached = start_session(ack: :auto, stream_attach_timeout: 15)

    assert_receive {:session_receipt, unattached_session,
                    %{outcome: {:error, :consumer_never_attached}}},
                   1_000

    assert unattached_session == unattached.session
    assert_eventually(fn -> session_state(unattached_session) == :terminal end)

    claim = make_ref()

    assert {:ok, [%StreamEvent{kind: :failed, payload: :consumer_never_attached}]} =
             :gen_statem.call(
               unattached_session,
               {:next, @token, self(), claim, 1}
             )

    assert {:ok, [%StreamEvent{kind: :already_consumed}]} =
             :gen_statem.call(
               unattached_session,
               {:next, @token, self(), make_ref(), 1}
             )

    future_deadline =
      Spectre.Inference.BudgetSnapshot.new(
        inference_id: "long-deadline",
        attempt_id: "attempt",
        deadline_at: System.system_time(:millisecond) + 60_000
      )

    deadline = start_session(ack: :auto, budget_snapshot: future_deadline)
    send(deadline.session, :stream_budget_deadline)
    Process.sleep(10)
    assert Process.alive?(deadline.session)
  end

  defp start_session(opts) do
    ack = Keyword.get(opts, :ack, :auto)
    parent = self()
    instance = spawn(fn -> instance_loop(parent, ack, nil) end)
    on_exit(fn -> send(instance, :stop) end)

    session_opts = session_options(Keyword.put(opts, :instance, instance))
    reservation = session_opts[:capacity_reservation]
    :ok = StreamCapacity.reserve(reservation, self(), @capacity)
    {:ok, session} = StreamSession.start_link(session_opts)
    send(instance, {:session, session})

    on_exit(fn ->
      if Process.alive?(session), do: :gen_statem.stop(session)
    end)

    %{session: session, instance: instance, invocation: session_opts[:invocation]}
  end

  defp session_options(opts) do
    id = "session-#{System.unique_integer([:positive, :monotonic])}"
    request = Request.new(id: id, purpose: :response_generation, plan: plan(id))
    descriptor = Descriptor.from_request(request, streaming?: true)

    selection =
      Selection.new(
        request_id: id,
        level: :default,
        model: :model,
        reason: :test,
        selector: Spectre.Inference.Selector.Default
      )

    frozen = FrozenSelection.from_selection(selection)
    continuation = InferenceContinuation.new(descriptor, frozen_selection: frozen)
    run = Run.new(@agent, Input.new(id), State.new(nil), run_id: "run-#{id}")
    invocation = Invocation.from_inference(run, continuation, streaming?: true)

    adapter_opts =
      opts
      |> Keyword.take([:mode, :batches, :cancel_reply, :provider_metadata])
      |> Keyword.put(:test_pid, Keyword.get(opts, :test_pid, self()))

    prepared = %Prepared{
      descriptor: descriptor,
      selection: selection,
      frozen_selection: frozen,
      provider_opts: adapter_opts,
      stream_adapter: @adapter,
      stream_adapter_opts: [],
      stream_capabilities: MapSet.new([:stream, :pull_transport, :resume])
    }

    defaults = [
      invocation: invocation,
      prepared: prepared,
      instance: Keyword.get(opts, :instance, self()),
      consumer_token: @token,
      capacity_reservation: {:session, id},
      capacity_server: @capacity,
      capability: make_ref(),
      generation: "generation",
      dispatch_id: "dispatch",
      registry: @registry,
      stream_attach_timeout: 500,
      stream_open_timeout: 500,
      stream_provider_stall_timeout: 500,
      stream_consumer_idle_timeout: 500,
      stream_max_duration_ms: 2_000,
      stream_terminal_retention: 2_000,
      stream_result_timeout: 500,
      stream_max_awaiters: 4
    ]

    override_keys =
      Keyword.keys(defaults) ++
        [
          :budget_snapshot,
          :determinism_opts,
          :inference_heartbeat_interval,
          :resume_from,
          :stream_max_transport_chunk_bytes,
          :stream_max_parser_residual_bytes,
          :stream_max_delta_bytes,
          :model_reply_max_bytes,
          :max_sanitizer_lookahead_bytes
        ]

    Keyword.merge(defaults, Keyword.take(opts, override_keys))
  end

  defp next_task(context, consumer, claim, demand) do
    Task.async(fn ->
      :gen_statem.call(
        context.session,
        {:next, @token, consumer, claim, demand},
        1_000
      )
    end)
  end

  defp assert_failed_next(context, expected) do
    assert {:ok, [%StreamEvent{kind: kind, payload: ^expected}]} =
             context |> next_task(self(), make_ref(), 1) |> Task.await(1_000)

    assert kind in [:failed, :ambiguous]
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp session_state(session) do
    {state, _data} = :sys.get_state(session)
    state
  end

  defp successful_events(text) do
    [
      ProviderEvent.new(:started, provider_sequence: 0),
      ProviderEvent.completed(Response.new(text), provider_sequence: 1)
    ]
  end

  defp instance_loop(parent, ack, session) do
    receive do
      {:session, pid} ->
        instance_loop(parent, ack, pid)

      {:spectre, :inference_heartbeat, _invocation_id, _progress, _checkpoint} ->
        instance_loop(parent, ack, session)

      {:spectre, :invocation_result, invocation_id, receipt} ->
        send(parent, {:session_receipt, session, receipt})
        acknowledge_attempt(ack, session, invocation_id, receipt)
        instance_loop(parent, ack, session)

      :stop ->
        :ok
    end
  end

  defp acknowledge_attempt(:hold, _session, _invocation_id, _receipt), do: :ok

  defp acknowledge_attempt(:attempt_only, session, invocation_id, %{outcome: {:ok, response}}) do
    send(session, {:spectre, :stream_attempt_committed, invocation_id, response})
  end

  defp acknowledge_attempt(:auto, session, invocation_id, %{outcome: {:ok, response}}) do
    send(session, {:spectre, :stream_attempt_committed, invocation_id, response})

    send(
      session,
      {:spectre, :stream_result, invocation_id, {:ok, %Result{reply_text: response.text}}}
    )
  end

  defp acknowledge_attempt(:auto, session, invocation_id, %{outcome: {:error, reason}}) do
    send(session, {:spectre, :stream_attempt_failed, invocation_id, reason})
  end

  defp failure_class({class, _detail}) when is_atom(class), do: class
  defp failure_class(%{class: class}) when is_atom(class), do: class
  defp failure_class(class) when is_atom(class), do: class

  defp plan(text) do
    {:ok, plan} = Plan.compose(text, [], [:agent])
    plan
  end
end
