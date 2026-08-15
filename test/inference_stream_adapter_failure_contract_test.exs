defmodule SpectreInferenceStreamAdapterFailureContractTest.FixtureAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, opts) do
    case Keyword.get(opts, :capabilities_reply) do
      :raise -> raise "capability fixture failed"
      :throw -> throw(:capability_fixture_failed)
      {:throw, reason} -> throw(reason)
      nil -> Keyword.get(opts, :capabilities, MapSet.new([:stream, :pull_transport]))
      reply -> reply
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, opts) do
    if test_pid = Keyword.get(opts, :test_pid), do: send(test_pid, {:adapter_open_opts, opts})

    case Keyword.get(opts, :open_reply) do
      :raise -> raise "open fixture failed"
      :throw -> throw(:open_fixture_failed)
      nil -> {:ok, %{opts: opts, demand: 0}, %{provider: :fixture}}
      reply -> reply
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def resume(_descriptor, cursor, opts) do
    if test_pid = Keyword.get(opts, :test_pid), do: send(test_pid, {:adapter_resume_opts, opts})

    case Keyword.get(opts, :resume_reply) do
      :raise -> raise "resume fixture failed"
      :throw -> throw(:resume_fixture_failed)
      nil -> {:ok, %{opts: opts, cursor: cursor, demand: 0}, %{provider: :fixture}}
      reply -> reply
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(%{opts: opts} = state) do
    case Keyword.get(opts, :demand_reply) do
      :raise -> raise "demand fixture failed"
      :throw -> throw(:demand_fixture_failed)
      nil -> {:ok, Map.update!(state, :demand, &(&1 + 1))}
      reply -> reply
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(message, %{opts: opts} = state) do
    case {Keyword.get(opts, :transport_reply), message} do
      {:raise, _message} -> raise "transport fixture failed"
      {:throw, _message} -> throw(:transport_fixture_failed)
      {reply, _message} when not is_nil(reply) -> reply
      {nil, :ignore} -> {:ignore, state}
      {nil, {:events, events}} -> {:ok, events, state}
      {nil, {:transport_error, reason}} -> {:error, reason, state}
      {nil, reply} -> reply
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def cancel(%{opts: opts}, _reason) do
    case Keyword.get(opts, :cancel_reply, :ok) do
      :raise -> raise "cancel fixture failed"
      :throw -> throw(:cancel_fixture_failed)
      reply -> reply
    end
  end

  @impl Spectre.Inference.StreamAdapter
  def reconcile(_descriptor, _provider_request_id, opts) do
    case Keyword.get(opts, :reconcile_reply, :pending) do
      :raise -> raise "reconcile fixture failed"
      :throw -> throw(:reconcile_fixture_failed)
      reply -> reply
    end
  end
end

defmodule SpectreInferenceStreamAdapterFailureContractTest.MissingCapabilities do
  @moduledoc false
end

defmodule SpectreInferenceStreamAdapterFailureContractTest.MissingCoreCallbacks do
  @moduledoc false

  def capabilities(_profile, _opts), do: MapSet.new([:stream, :pull_transport])
end

defmodule SpectreInferenceStreamAdapterFailureContractTest.MissingDemand do
  @moduledoc false

  def capabilities(_profile, _opts), do: MapSet.new([:stream, :pull_transport])
  def open(_descriptor, _opts), do: {:ok, %{}, %{}}
  def handle_transport(_message, state), do: {:ignore, state}
  def cancel(_state, _reason), do: :ok
end

defmodule SpectreInferenceStreamAdapterFailureContractTest.MissingResume do
  @moduledoc false

  def capabilities(_profile, _opts),
    do: MapSet.new([:stream, :pull_transport, :resume])

  def open(_descriptor, _opts), do: {:ok, %{}, %{}}
  def request_transport_item(state), do: {:ok, state}
  def handle_transport(_message, state), do: {:ignore, state}
  def cancel(_state, _reason), do: :ok
end

defmodule SpectreInferenceStreamAdapterFailureContractTest.MissingReconcile do
  @moduledoc false

  def capabilities(_profile, _opts),
    do: MapSet.new([:stream, :pull_transport, :reconcile])

  def open(_descriptor, _opts), do: {:ok, %{}, %{}}
  def request_transport_item(state), do: {:ok, state}
  def handle_transport(_message, state), do: {:ignore, state}
  def cancel(_state, _reason), do: :ok
end

defmodule SpectreInferenceStreamAdapterFailureContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.ProviderProtocol
  alias Spectre.Inference.StreamAdapter
  alias Spectre.Inference.StreamAdapter.Conformance
  alias Spectre.Inference.StreamCapacity
  alias Spectre.Inference.StreamCheckpoint
  alias Spectre.Inference.Usage
  alias Spectre.Prompt.Plan

  @adapter SpectreInferenceStreamAdapterFailureContractTest.FixtureAdapter

  test "adapter validation rejects ambiguous capabilities and missing callbacks" do
    missing = Module.concat(__MODULE__, DoesNotExist)

    assert {:error, {:stream_adapter_not_loaded, ^missing}} = StreamAdapter.validate(missing, nil)

    assert {:error, {:stream_adapter_callback_missing, _, :capabilities, 2}} =
             StreamAdapter.validate(
               SpectreInferenceStreamAdapterFailureContractTest.MissingCapabilities,
               nil
             )

    assert {:error, {:streaming_unsupported, :adapter_capability}} =
             validate(capabilities: MapSet.new([:pull_transport]))

    assert {:error, {:streaming_unsupported, :transport}} =
             validate(capabilities: MapSet.new([:stream]))

    assert {:error, :ambiguous_stream_transport_mode} =
             validate(capabilities: MapSet.new([:stream, :pull_transport, :push_transport]))

    assert {:error, {:streaming_unsupported, :unbounded_push_transport}} =
             validate(capabilities: MapSet.new([:stream, :push_transport]))

    assert {:error, {:invalid_stream_adapter_capabilities, @adapter, class}} =
             validate(capabilities_reply: [])

    assert class == :list

    for {reply, expected_class} <- [
          {%{}, :map},
          {{:invalid}, :tuple},
          {:invalid, :atom},
          {12, :other}
        ] do
      assert {:error, {:invalid_stream_adapter_capabilities, @adapter, ^expected_class}} =
               validate(capabilities_reply: reply)
    end

    assert {:error, {:stream_adapter_exception, @adapter, RuntimeError}} =
             validate(capabilities_reply: :raise)

    assert {:error, {:stream_adapter_failure, @adapter, :throw, :capability_fixture_failed}} =
             validate(capabilities_reply: :throw)

    assert {:error, {:stream_adapter_failure, @adapter, :throw, :tuple_failure}} =
             validate(capabilities_reply: {:throw, {:tuple_failure, :private}})

    assert {:error, {:stream_adapter_failure, @adapter, :throw, :error}} =
             validate(capabilities_reply: {:throw, [:private]})

    assert {:error, {:stream_adapter_callback_missing, _, :open, 2}} =
             StreamAdapter.validate(
               SpectreInferenceStreamAdapterFailureContractTest.MissingCoreCallbacks,
               nil
             )

    assert {:error, {:stream_adapter_callback_missing, _, :request_transport_item, 1}} =
             StreamAdapter.validate(
               SpectreInferenceStreamAdapterFailureContractTest.MissingDemand,
               nil
             )

    assert {:error, {:stream_adapter_callback_missing, _, :resume, 3}} =
             StreamAdapter.validate(
               SpectreInferenceStreamAdapterFailureContractTest.MissingResume,
               nil
             )

    assert {:error, {:stream_adapter_callback_missing, _, :reconcile, 3}} =
             StreamAdapter.validate(
               SpectreInferenceStreamAdapterFailureContractTest.MissingReconcile,
               nil
             )

    assert {:ok, capabilities} =
             validate(
               capabilities: MapSet.new([:stream, :push_transport, :bounded_push_transport])
             )

    assert MapSet.member?(capabilities, :bounded_push_transport)
  end

  test "conformance accepts pull, push, resume, cancellation, and reconciliation" do
    events = successful_events()

    assert {:ok, pull} =
             Conformance.run(@adapter, descriptor(), [:ignore, {:events, events}],
               adapter_opts: []
             )

    assert pull.transport == :pull
    assert pull.transport_requests == 1
    assert pull.transport_items == 1
    assert pull.ignored_messages == 1
    assert pull.terminal == :completed

    assert {:ok, bounded} =
             Conformance.run(@adapter, descriptor(), [{:events, events}],
               max_transport_chunk_bytes: 12_345,
               max_parser_residual_bytes: 6_789,
               adapter_opts: [test_pid: self()]
             )

    assert bounded.bounds == %{
             max_transport_chunk_bytes: 12_345,
             max_parser_residual_bytes: 6_789
           }

    assert_receive {:adapter_open_opts, bounded_opts}
    assert bounded_opts[:max_transport_chunk_bytes] == 12_345
    assert bounded_opts[:max_parser_residual_bytes] == 6_789

    push_capabilities = MapSet.new([:stream, :push_transport, :bounded_push_transport])

    assert {:ok, %{transport: :push, transport_requests: 0}} =
             Conformance.run(@adapter, descriptor(), [{:events, events}],
               adapter_opts: [capabilities: push_capabilities]
             )

    extended = MapSet.new([:stream, :pull_transport, :resume, :reconcile])

    assert {:ok,
            %{
              cancel: :accepted,
              reconcile: :completed,
              terminal: :completed
            }} =
             Conformance.run(@adapter, descriptor(), [{:events, events}],
               open_mode: {:resume, "cursor-one"},
               cancel_after?: true,
               reconcile_provider_request_id: "provider-one",
               adapter_opts: [capabilities: extended, reconcile_reply: {:ok, "done"}]
             )

    for {reply, expected} <- [
          {:pending, :pending},
          {:not_found, :not_found},
          {{:error, {:provider_error, :detail}}, {:error, :provider_error}}
        ] do
      assert {:ok, %{reconcile: ^expected}} =
               Conformance.run(@adapter, descriptor(), [{:events, events}],
                 reconcile_provider_request_id: "provider-one",
                 adapter_opts: [capabilities: extended, reconcile_reply: reply]
               )
    end

    assert {:ok, %{cancel: {:error, :cancel_rejected}}} =
             Conformance.run(@adapter, descriptor(), [{:events, events}],
               cancel_after?: true,
               adapter_opts: [cancel_reply: {:error, {:cancel_rejected, :detail}}]
             )
  end

  test "conformance reports option, open, resume, demand, and transport failures by phase" do
    assert_failed(:options, :invalid_arguments, fn ->
      Conformance.run(@adapter, :invalid, [], [])
    end)

    assert_failed(:options, :invalid_options, fn ->
      Conformance.run(@adapter, descriptor(), [], [:not_keyword])
    end)

    assert_failed(:options, :invalid_adapter_options, fn ->
      Conformance.run(@adapter, descriptor(), [], adapter_opts: [:not_keyword])
    end)

    assert_failed(:options, :invalid_adapter_options, fn ->
      Conformance.run(@adapter, descriptor(), [], adapter_opts: %{})
    end)

    invalid_descriptor = %{descriptor() | purpose: nil}

    assert_failed(:protocol, :invalid_inference_descriptor_purpose, fn ->
      Conformance.run(@adapter, invalid_descriptor, [])
    end)

    assert_failed(:capabilities, {:streaming_unsupported, :adapter_capability}, fn ->
      run_with(capabilities: MapSet.new([:pull_transport]))
    end)

    assert_failed(:options, {:invalid_positive_option, :max_delta_bytes}, fn ->
      Conformance.run(@adapter, descriptor(), [],
        require_terminal?: false,
        max_delta_bytes: 0
      )
    end)

    assert_failed(:options, {:invalid_positive_option, :max_events_per_transport_item}, fn ->
      Conformance.run(@adapter, descriptor(), [],
        require_terminal?: false,
        max_events_per_transport_item: :unbounded
      )
    end)

    assert_failed(:options, {:invalid_positive_option, :max_transport_chunk_bytes}, fn ->
      Conformance.run(@adapter, descriptor(), [], max_transport_chunk_bytes: 0)
    end)

    assert_failed(:options, {:invalid_positive_option, :max_parser_residual_bytes}, fn ->
      Conformance.run(@adapter, descriptor(), [], max_parser_residual_bytes: :unbounded)
    end)

    assert_failed(:open, {:adapter_error, :provider_unavailable}, fn ->
      run_with(open_reply: {:error, {:provider_unavailable, :private}})
    end)

    assert_failed(:open, {:adapter_error, :mapped_provider_error}, fn ->
      run_with(open_reply: {:error, %{class: :mapped_provider_error}})
    end)

    assert_failed(:open, {:adapter_error, :error}, fn ->
      run_with(open_reply: {:error, [:private_provider_error]})
    end)

    assert_failed(:open, {:invalid_reply, :invalid}, fn -> run_with(open_reply: :invalid) end)

    for {reply, class} <- [
          {{:unexpected, :reply}, :tuple},
          {%{unexpected: :reply}, :map},
          {[:unexpected], :list},
          {12, :other}
        ] do
      assert_failed(:open, {:invalid_reply, class}, fn -> run_with(open_reply: reply) end)
    end

    assert_failed(:open, {:callback_exception, :open, RuntimeError}, fn ->
      run_with(open_reply: :raise)
    end)

    assert_failed(:open, {:callback_failure, :open, :throw, :open_fixture_failed}, fn ->
      run_with(open_reply: :throw)
    end)

    assert_failed(:open, :invalid_provider_metadata, fn ->
      run_with(open_reply: {:ok, %{opts: [], demand: 0}, []})
    end)

    assert_failed(:resume, :capability_unavailable, fn ->
      Conformance.run(@adapter, descriptor(), [], open_mode: {:resume, "cursor"})
    end)

    assert_failed(:options, :invalid_open_mode, fn ->
      Conformance.run(@adapter, descriptor(), [], open_mode: :restart)
    end)

    resume_capabilities = MapSet.new([:stream, :pull_transport, :resume])

    assert_failed(:resume, {:adapter_error, :resume_failed}, fn ->
      run_with(
        capabilities: resume_capabilities,
        resume_reply: {:error, :resume_failed},
        open_mode: {:resume, "cursor"}
      )
    end)

    for {reply, expected} <- [
          {{:error, {:credit_failed, :detail}}, {:adapter_error, :credit_failed}},
          {:invalid, {:invalid_reply, :invalid}},
          {:raise, {:callback_exception, :request_transport_item, RuntimeError}},
          {:throw, {:callback_failure, :request_transport_item, :throw, :demand_fixture_failed}}
        ] do
      assert_failed(:demand, expected, fn ->
        run_with(demand_reply: reply, messages: [:ignore])
      end)
    end

    for {reply, expected} <- [
          {{:error, {:transport_failed, :detail}, %{}}, {:adapter_error, :transport_failed}},
          {:invalid, {:invalid_reply, :invalid}},
          {:raise, {:callback_exception, :handle_transport, RuntimeError}},
          {:throw, {:callback_failure, :handle_transport, :throw, :transport_fixture_failed}}
        ] do
      assert_failed(:transport, expected, fn ->
        run_with(transport_reply: reply, messages: [:transport])
      end)
    end
  end

  test "conformance rejects invalid event framing, global ordering, and terminal misuse" do
    events = successful_events()

    assert_failed(:events, :provider_delta_too_large, fn ->
      Conformance.run(@adapter, descriptor(), [{:events, events}], max_delta_bytes: 2)
    end)

    assert_failed(:events, :provider_started_event_out_of_order, fn ->
      Conformance.run(
        @adapter,
        descriptor(),
        [
          {:events, [ProviderEvent.delta("first", provider_sequence: 0)]},
          {:events, [ProviderEvent.new(:started, provider_sequence: 1)]}
        ]
      )
    end)

    assert_failed(:events, :message_after_terminal, fn ->
      Conformance.run(
        @adapter,
        descriptor(),
        [{:events, events}, {:events, [ProviderEvent.delta("late", provider_sequence: 3)]}]
      )
    end)

    assert_failed(:events, :invalid_provider_terminal_order, fn ->
      Conformance.run(
        @adapter,
        descriptor(),
        [
          {:events, events ++ [ProviderEvent.delta("same-batch late", provider_sequence: 3)]}
        ]
      )
    end)

    assert_failed(:events, :provider_sequence_violation, fn ->
      Conformance.run(
        @adapter,
        descriptor(),
        [
          {:events,
           [
             ProviderEvent.new(:started, provider_sequence: 0),
             ProviderEvent.delta("gap", provider_sequence: 2)
           ]}
        ]
      )
    end)

    assert_failed(:events, {:invalid_provider_event_batch, :invalid_provider_event}, fn ->
      Conformance.run(@adapter, descriptor(), [{:events, [:not_an_event]}])
    end)

    assert_failed(:events, :provider_stream_overflow, fn ->
      Conformance.run(@adapter, descriptor(), [{:events, events}],
        max_events_per_transport_item: 2
      )
    end)

    assert_failed(:terminal, :missing_terminal_event, fn ->
      Conformance.run(
        @adapter,
        descriptor(),
        [{:events, [ProviderEvent.new(:started, provider_sequence: 0)]}]
      )
    end)

    assert {:ok, %{terminal: nil}} =
             Conformance.run(
               @adapter,
               descriptor(),
               [{:events, [ProviderEvent.new(:started, provider_sequence: 0)]}],
               require_terminal?: false
             )
  end

  test "conformance accepts codepoints split between normalized provider deltas" do
    <<left::binary-size(2), right::binary>> = "🙂"

    split_events = [
      ProviderEvent.new(:started, provider_sequence: 0),
      ProviderEvent.delta(left, provider_sequence: 1),
      ProviderEvent.delta(right, provider_sequence: 2),
      ProviderEvent.completed("🙂", provider_sequence: 3)
    ]

    assert {:ok, %{terminal: :completed}} =
             Conformance.run(@adapter, descriptor(), [{:events, split_events}])

    invalid_events = [
      ProviderEvent.new(:started, provider_sequence: 0),
      ProviderEvent.delta(<<0xC3, 0x28>>, provider_sequence: 1)
    ]

    assert_failed(:events, :invalid_provider_utf8, fn ->
      Conformance.run(@adapter, descriptor(), [{:events, invalid_events}],
        require_terminal?: false
      )
    end)

    incomplete_events = [
      ProviderEvent.new(:started, provider_sequence: 0),
      ProviderEvent.delta(<<0xF0, 0x9F>>, provider_sequence: 1),
      ProviderEvent.new(:failed, payload: :provider_failed, provider_sequence: 2)
    ]

    assert_failed(:events, :incomplete_provider_utf8, fn ->
      Conformance.run(@adapter, descriptor(), [{:events, incomplete_events}])
    end)
  end

  test "conformance rejects invalid cancel and reconcile callback replies" do
    events = successful_events()

    for {reply, expected} <- [
          {:invalid, {:invalid_reply, :invalid}},
          {:raise, {:callback_exception, :cancel, RuntimeError}},
          {:throw, {:callback_failure, :cancel, :throw, :cancel_fixture_failed}}
        ] do
      assert_failed(:cancel, expected, fn ->
        Conformance.run(@adapter, descriptor(), [{:events, events}],
          cancel_after?: true,
          adapter_opts: [cancel_reply: reply]
        )
      end)
    end

    assert_failed(:reconcile, :capability_unavailable, fn ->
      Conformance.run(@adapter, descriptor(), [{:events, events}],
        reconcile_provider_request_id: "provider"
      )
    end)

    capabilities = MapSet.new([:stream, :pull_transport, :reconcile])

    for {reply, expected} <- [
          {:invalid, {:invalid_reply, :invalid}},
          {:raise, {:callback_exception, :reconcile, RuntimeError}},
          {:throw, {:callback_failure, :reconcile, :throw, :reconcile_fixture_failed}}
        ] do
      assert_failed(:reconcile, expected, fn ->
        Conformance.run(@adapter, descriptor(), [{:events, events}],
          reconcile_provider_request_id: "provider",
          adapter_opts: [capabilities: capabilities, reconcile_reply: reply]
        )
      end)
    end
  end

  test "provider events validate payload, sequence, usage quality, and metadata" do
    assert %ProviderEvent{kind: :delta, payload: "delta"} = ProviderEvent.delta("delta")

    assert %ProviderEvent{kind: :delta, payload: <<0xF0, 0x9F>>} =
             ProviderEvent.delta(<<0xF0, 0x9F>>)

    assert %ProviderEvent{kind: :completed, payload: %{text: "complete"}} =
             ProviderEvent.completed("complete")

    assert %ProviderEvent{kind: :failed, payload: :provider_failed} =
             ProviderEvent.new(:failed, payload: :provider_failed)

    assert {:error, :invalid_provider_event} = ProviderEvent.validate(:invalid)

    invalid = ProviderEvent.new(:started)

    assert {:error, :invalid_provider_event_kind} =
             ProviderEvent.validate(%{invalid | kind: :unknown})

    assert {:error, :invalid_provider_event_sequence} =
             ProviderEvent.validate(%{invalid | provider_sequence: -1})

    assert {:error, :invalid_provider_event_usage_quality} =
             ProviderEvent.validate(%{invalid | usage_quality: :guessed})

    assert {:error, :invalid_provider_event_metadata} =
             ProviderEvent.validate(%{invalid | metadata: []})

    assert {:error, :invalid_provider_event_payload} =
             ProviderEvent.validate(%{invalid | kind: :delta, payload: :not_text})

    assert {:error, :invalid_provider_event_payload} =
             ProviderEvent.validate(%{invalid | kind: :failed, payload: nil})

    assert_raise ArgumentError, ~r/invalid provider stream event/, fn ->
      ProviderEvent.new(:completed, payload: :not_a_response)
    end
  end

  test "provider protocol validates batch framing and optional sequence fences" do
    assert {:error, :invalid_provider_event_batch} = ProviderProtocol.validate_batch(:invalid, 1)
    assert :ok = ProviderProtocol.validate_sequence(nil, nil)
    assert ProviderProtocol.next_sequence(7, nil) == 7

    invalid = %{ProviderEvent.new(:started) | metadata: []}

    assert {:error, {:invalid_provider_event_batch, :invalid_provider_event_metadata}} =
             ProviderProtocol.validate_batch([invalid], 1)

    terminals = [
      ProviderEvent.new(:failed, payload: :first, provider_sequence: 0),
      ProviderEvent.new(:failed, payload: :second, provider_sequence: 1)
    ]

    assert {:error, :invalid_provider_terminal_order} =
             ProviderProtocol.validate_batch(terminals, 2)

    assert {:error, :provider_sequence_violation} = ProviderProtocol.validate_sequence(1, nil)
    assert ProviderProtocol.next_sequence(1, 2) == 2
  end

  test "stream checkpoints reject invalid bounds and corrupt restored usage" do
    assert {:ok, empty} = StreamCheckpoint.new(nil, nil)
    refute StreamCheckpoint.meaningful?(empty)

    assert {:error, {:invalid_stream_checkpoint_max_bytes, 0}} =
             StreamCheckpoint.new(nil, nil, max_bytes: 0)

    corrupt = %{empty | usage: %URI{}}
    assert {:error, :invalid_stream_checkpoint_usage} = StreamCheckpoint.validate(corrupt)
  end

  test "budget snapshots normalize portable limits and enforce immutable deadlines" do
    snapshot =
      BudgetSnapshot.new(
        inference_id: "inference",
        attempt_id: "attempt",
        deadline_at: 20,
        remaining: %{
          "input_tokens" => 2,
          "output_tokens" => 3,
          "total_tokens" => 5,
          "cost" => 1.5,
          "duration_ms" => 10
        },
        reserved: %Usage{input_tokens: 1},
        pricing_ref: "pricing:v1",
        estimation_policy: :provider
      )

    assert :ok = BudgetSnapshot.exceeded(snapshot, input_tokens: 2, output_tokens: 3)
    assert {:error, :input_tokens} = BudgetSnapshot.exceeded(snapshot, input_tokens: 3)
    refute BudgetSnapshot.deadline_exceeded?(snapshot, 19)
    assert BudgetSnapshot.deadline_exceeded?(snapshot, 20)

    no_deadline = BudgetSnapshot.new(inference_id: "i", attempt_id: "a")
    refute BudgetSnapshot.deadline_exceeded?(no_deadline, 1_000)

    invalid = [
      [inference_id: "", attempt_id: "a"],
      [inference_id: "i", attempt_id: "", deadline_at: 1],
      [inference_id: "i", attempt_id: "a", deadline_at: -1],
      [inference_id: "i", attempt_id: "a", remaining: [bad: -1]],
      [inference_id: "i", attempt_id: "a", remaining: [:not_keyword]],
      [inference_id: "i", attempt_id: "a", remaining: %{"unknown" => 1}],
      [inference_id: "i", attempt_id: "a", remaining: %{cost: 1}],
      [inference_id: "i", attempt_id: "a", pricing_ref: ""],
      [inference_id: "i", attempt_id: "a", estimation_policy: :guess]
    ]

    Enum.each(invalid, fn opts ->
      assert_raise ArgumentError, ~r/invalid budget snapshot/, fn ->
        BudgetSnapshot.new(opts)
      end
    end)
  end

  test "stream capacity reservations are bounded, transferable, replaceable, and owner-monitored" do
    assert {:error, {:already_started, _pid}} = StreamCapacity.start_link()

    default_id = {:default_capacity, System.unique_integer([:positive, :monotonic])}
    successor_id = {:default_capacity_successor, elem(default_id, 1)}
    assert :ok = StreamCapacity.reserve(default_id)
    assert :ok = StreamCapacity.transfer(default_id, self())
    assert :ok = StreamCapacity.replace(default_id, successor_id, self())
    assert :ok = StreamCapacity.release(successor_id)

    server = start_supervised!({StreamCapacity, name: nil, limit: 2})
    owner_one = spawn(fn -> Process.sleep(:infinity) end)
    owner_two = spawn(fn -> Process.sleep(:infinity) end)
    owner_three = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Enum.each([owner_one, owner_two, owner_three], fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end)

    assert :ok = StreamCapacity.reserve(:one, owner_one, server)
    assert :ok = StreamCapacity.reserve(:one, owner_one, server)

    assert {:error, :stream_capacity_reservation_conflict} =
             StreamCapacity.reserve(:one, owner_two, server)

    assert :ok = StreamCapacity.reserve(:two, owner_two, server)

    assert {:error, :stream_node_capacity_exhausted} =
             StreamCapacity.reserve(:three, owner_three, server)

    assert %{active: 2, limit: 2} = StreamCapacity.status(server)
    assert :ok = StreamCapacity.transfer(:one, owner_three, server)

    assert {:error, :unknown_stream_capacity_reservation} =
             StreamCapacity.transfer(:unknown, owner_one, server)

    assert :ok = StreamCapacity.replace(:one, :successor, owner_three, server)
    assert :ok = StreamCapacity.replace(:successor, :successor, owner_three, server)

    assert {:error, :stream_capacity_reservation_conflict} =
             StreamCapacity.replace(:successor, :two, owner_three, server)

    assert {:error, :unknown_stream_capacity_reservation} =
             StreamCapacity.replace(:unknown, :unused, owner_three, server)

    assert :ok = StreamCapacity.release(:successor, server)
    assert :ok = StreamCapacity.release(:successor, server)
    send(server, :unrelated)

    Process.exit(owner_two, :kill)
    assert_eventually(fn -> StreamCapacity.status(server).active == 0 end)

    stale_owner = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = StreamCapacity.reserve(:stale_owner, stale_owner, server)
    stale_state = :sys.get_state(server)
    Process.exit(stale_owner, :kill)
    assert_eventually(fn -> not Process.alive?(stale_owner) end)

    assert {:reply, :ok, reclaimed} =
             StreamCapacity.handle_call(
               {:reserve, :stale_owner, self()},
               {self(), make_ref()},
               stale_state
             )

    assert reclaimed.reservations[:stale_owner].owner == self()

    assert {:noreply, ^reclaimed} =
             StreamCapacity.handle_info(
               {:DOWN, make_ref(), :process, self(), :unrelated},
               reclaimed
             )
  end

  defp validate(opts), do: StreamAdapter.validate(@adapter, nil, opts)

  defp run_with(opts) do
    {messages, opts} = Keyword.pop(opts, :messages, [])
    {open_mode, adapter_opts} = Keyword.pop(opts, :open_mode, :open)

    Conformance.run(@adapter, descriptor(), messages,
      open_mode: open_mode,
      adapter_opts: adapter_opts
    )
  end

  defp assert_failed(phase, reason, fun) do
    assert {:error, {:stream_adapter_conformance_failed, ^phase, ^reason}} = fun.()
  end

  defp successful_events do
    [
      ProviderEvent.new(:started, provider_sequence: 0),
      ProviderEvent.delta("text", provider_sequence: 1),
      ProviderEvent.completed("text", provider_sequence: 2)
    ]
  end

  defp descriptor do
    %Descriptor{
      id: "adapter-conformance",
      purpose: :response_generation,
      plan: %Plan{rendered: "adapter conformance"},
      constraints: %Spectre.Inference.Constraints{}
    }
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
end
