defmodule SpectreReceiptContractTest.Model do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:ok, "receipted response"}
end

defmodule SpectreReceiptContractTest.FailingSink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(_envelope, _opts),
    do: {:error, {:provider_response, "SECRET-EXTERNAL-ERROR"}}

  @impl Spectre.Receipt.Sink
  def lookup(_id, _opts), do: :not_found
end

defmodule SpectreReceiptContractTest.RaisingSink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(_envelope, _opts), do: raise("SECRET-APPEND-FAILURE")

  @impl Spectre.Receipt.Sink
  def lookup(_id, _opts), do: :not_found
end

defmodule SpectreReceiptContractTest.AmbiguousCommittedSink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  alias Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(envelope, opts) do
    server = Keyword.fetch!(opts, :server)

    result =
      Agent.get_and_update(server, fn state ->
        case Map.fetch(state.receipts, envelope.id) do
          :error ->
            next = put_in(state, [:receipts, envelope.id], envelope)
            {{:error, {:ambiguous, :lost_ack}}, next}

          {:ok, ^envelope} ->
            {{:ok, :idempotent}, state}

          {:ok, _different} ->
            {{:error, :receipt_conflict}, state}
        end
      end)

    send(Keyword.fetch!(opts, :test_pid), {:ambiguous_sink_append, envelope.id, result})
    result
  end

  @impl Spectre.Receipt.Sink
  def lookup(id, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn state ->
      case Map.fetch(state.receipts, id) do
        {:ok, envelope} -> {:ok, envelope}
        :error -> :not_found
      end
    end)
  end

  @impl Spectre.Receipt.Sink
  def put_payload(envelope, opts) do
    ref = Sink.payload_ref(envelope)

    Agent.update(Keyword.fetch!(opts, :server), fn state ->
      put_in(state, [:payloads, ref], envelope)
    end)

    {:ok, ref}
  end

  @impl Spectre.Receipt.Sink
  def get_payload(ref, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn state ->
      case Map.fetch(state.payloads, ref) do
        {:ok, envelope} -> {:ok, envelope}
        :error -> :not_found
      end
    end)
  end
end

defmodule SpectreReceiptContractTest.BlockingSink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  alias Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(envelope, opts) do
    server = Keyword.fetch!(opts, :server)

    block? =
      Agent.get_and_update(server, fn state ->
        if state.blocks_left > 0 do
          {true, %{state | blocks_left: state.blocks_left - 1}}
        else
          {false, state}
        end
      end)

    if block? do
      send(Keyword.fetch!(opts, :test_pid), {:blocking_sink_append, envelope.id, self()})

      receive do
        {:release_blocking_sink, id} when id == envelope.id -> :ok
      end
    end

    Agent.get_and_update(server, fn state ->
      case Map.fetch(state.receipts, envelope.id) do
        :error ->
          {{:ok, :appended}, put_in(state, [:receipts, envelope.id], envelope)}

        {:ok, ^envelope} ->
          {{:ok, :idempotent}, state}

        {:ok, _different} ->
          {{:error, :receipt_conflict}, state}
      end
    end)
  end

  @impl Spectre.Receipt.Sink
  def lookup(id, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn state ->
      case Map.fetch(state.receipts, id) do
        {:ok, envelope} -> {:ok, envelope}
        :error -> :not_found
      end
    end)
  end

  @impl Spectre.Receipt.Sink
  def put_payload(envelope, opts) do
    ref = Sink.payload_ref(envelope)

    Agent.update(Keyword.fetch!(opts, :server), fn state ->
      put_in(state, [:payloads, ref], envelope)
    end)

    {:ok, ref}
  end

  @impl Spectre.Receipt.Sink
  def get_payload(ref, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn state ->
      case Map.fetch(state.payloads, ref) do
        {:ok, envelope} -> {:ok, envelope}
        :error -> :not_found
      end
    end)
  end
end

defmodule SpectreReceiptContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :receipts do
    on :RECEIPT, regex: ~r/receipt/i do
      ask(:base)
    end
  end
end

defmodule SpectreReceiptContractTest.DefinitionStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  @impl Spectre.Definition.Store
  def identity(opts), do: Keyword.fetch!(opts, :id)

  @impl Spectre.Definition.Store
  def durability(_opts), do: :durable

  @impl Spectre.Definition.Store
  def get(key, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, key) do
        {:ok, value} -> {:ok, value}
        :error -> :not_found
      end
    end)
  end

  @impl Spectre.Definition.Store
  def put(key, value, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, key) do
        :error -> {{:ok, :created}, Map.put(entries, key, value)}
        {:ok, ^value} -> {{:ok, :existing}, entries}
        {:ok, _different} -> {{:error, {:immutable_conflict, key}}, entries}
      end
    end)
  end
end

defmodule SpectreReceiptContractTest.CheckpointStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  @impl Spectre.Instance.CheckpointStore
  def load(ref, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, ref.key) do
        {:ok, {_revision, checkpoint}} -> {:ok, checkpoint}
        :error -> :not_found
      end
    end)
  end

  @impl Spectre.Instance.CheckpointStore
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case Map.get(entries, ref.key) do
        nil when expected == 0 ->
          {:ok, Map.put(entries, ref.key, {revision, checkpoint})}

        {^expected, _current} ->
          {:ok, Map.put(entries, ref.key, {revision, checkpoint})}

        {current, _checkpoint} ->
          {{:error, {:stale, expected, current}}, entries}

        nil ->
          {{:error, {:stale, expected, :not_found}}, entries}
      end
    end)
  end
end

defmodule SpectreReceiptContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.OutboxEntry
  alias Spectre.Receipt.Sink
  alias Spectre.Receipt.Sink.Memory
  alias Spectre.Subject

  @agent SpectreReceiptContractTest.Agent

  test "envelope identity is deterministic and binds payload without delivery time" do
    first = envelope(recorded_at: 10)
    second = envelope(recorded_at: 20)

    assert first.id == second.id
    assert first.payload_digest == second.payload_digest
    refute first == second
    assert "receipt:" <> digest = first.id
    assert byte_size(digest) == 64
    assert Envelope.digest(first) != Envelope.digest(second)

    data = Envelope.to_data(first)
    assert Enum.all?(Map.keys(data), &is_binary/1)
    assert Map.has_key?(data, "payload")

    assert {:error, :receipt_id_mismatch} =
             first
             |> Map.from_struct()
             |> Map.put(:id, "receipt:" <> String.duplicate("0", 64))
             |> Envelope.new()

    assert {:error, :receipt_payload_digest_mismatch} =
             first
             |> Map.from_struct()
             |> Map.put(:id, nil)
             |> Map.put(:payload_digest, String.duplicate("0", 64))
             |> Envelope.new()
  end

  test "public receipts reject sensitive fields and payload references are exclusive" do
    attrs = [
      kind: :nondeterminism_sample,
      correlation_id: "privacy",
      payload_schema_ref: "spectre.test/privacy/1",
      privacy: :public
    ]

    assert {:error, {:public_receipt_contains_sensitive_data, [:nested, :api_key]}} =
             Envelope.new(attrs ++ [payload: %{nested: %{api_key: "secret"}}])

    assert {:error, :receipt_payload_and_ref_conflict} =
             Envelope.new(attrs ++ [payload: %{safe: true}, payload_ref: "payload:one"])

    assert {:ok, %Envelope{payload: nil, payload_ref: "payload:one"}} =
             Envelope.new(attrs ++ [payload_ref: "payload:one"])
  end

  test "memory sink conformance covers exact idempotency and content-addressed payloads" do
    sink = start_supervised!({Memory, []})

    assert {:ok,
            %{
              append: :verified,
              idempotency: :verified,
              lookup: :verified,
              payload_store: :verified
            }} = Sink.Conformance.run({Memory, server: sink})

    receipt = envelope()
    normalized = {Memory, [server: sink]}

    assert {:ok, payload_ref} = Sink.put_payload(normalized, receipt, [])
    assert payload_ref == Sink.payload_ref(receipt)
    assert {:ok, ^receipt} = Sink.get_payload(normalized, payload_ref, [])

    entry = OutboxEntry.new(receipt, payload_ref, 7)
    assert :ok = OutboxEntry.validate(entry)

    assert {:error, :invalid_receipt_outbox_payload_ref} =
             OutboxEntry.validate(%{entry | payload_ref: "receipt-payload:wrong"})
  end

  test "memory sink rejects forged identity collisions and reports missing entries" do
    {:ok, unnamed} = Memory.start_link()
    on_exit(fn -> if Process.alive?(unnamed), do: Agent.stop(unnamed) end)

    sink = start_supervised!({Memory, []})
    opts = [server: sink]
    receipt = envelope(correlation_id: "memory-collision")
    forged = %{receipt | recorded_at: receipt.recorded_at + 1}

    assert {:ok, :appended} = Memory.append(receipt, opts)
    assert {:ok, :idempotent} = Memory.append(receipt, opts)
    assert {:error, :receipt_id_conflict} = Memory.append(forged, opts)
    assert :not_found = Memory.lookup("receipt:missing", opts)
    assert :not_found = Memory.get_payload("receipt-payload:missing", opts)

    payload_ref = Sink.payload_ref(receipt)

    Agent.update(sink, fn state ->
      put_in(state, [:payloads, payload_ref], forged)
    end)

    assert {:error, :receipt_payload_conflict} = Memory.put_payload(receipt, opts)
  end

  test "envelope bang and digest APIs reject forged non-canonical evidence" do
    assert_raise ArgumentError, ~r/invalid receipt envelope/, fn ->
      Envelope.new!(kind: :unknown, correlation_id: "invalid", payload_schema_ref: "test/1")
    end

    assert {:error, {:invalid_receipt_envelope, :map}} = Envelope.new(%URI{})

    forged = %{envelope(correlation_id: "forged-digest") | payload: %{owner: self()}}

    assert_raise ArgumentError, ~r/cannot digest receipt envelope/, fn ->
      Envelope.digest(forged)
    end

    nonportable =
      envelope(correlation_id: "nonportable")
      |> Map.from_struct()
      |> Map.put(:id, nil)
      |> Map.put(:metadata, %{owner: self()})

    assert {:error, {:nonportable_receipt_envelope, {:nonportable_run_value, _, :pid}}} =
             Envelope.new(nonportable)
  end

  test "sink failures expose only bounded classes and append exceptions stay ambiguous" do
    receipt = envelope()

    assert {:error, {:receipt_sink_error, :provider_response}} =
             Sink.append({SpectreReceiptContractTest.FailingSink, []}, receipt, [])

    refute inspect(Sink.append({SpectreReceiptContractTest.FailingSink, []}, receipt, [])) =~
             "SECRET"

    assert {:error, {:ambiguous, :receipt_append_exception}} =
             Sink.append({SpectreReceiptContractTest.RaisingSink, []}, receipt, [])
  end

  test "observational mode emits every inference boundary after canonical commit" do
    sink = start_supervised!({Memory, []})

    instance =
      start_instance(
        receipt_mode: :observational,
        receipt_sink: {Memory, server: sink}
      )

    assert {:ok, %Spectre.Result{reply_text: "receipted response"}} =
             Instance.ask(instance, "receipt this", model: SpectreReceiptContractTest.Model)

    assert_eventually(fn -> length(Memory.all(server: sink)) >= 4 end)
    receipts = Memory.all(server: sink)
    kinds = MapSet.new(receipts, & &1.kind)

    assert MapSet.subset?(
             MapSet.new([
               :run_input_admitted,
               :inference_selected,
               :inference_attempt_started,
               :inference_attempt_terminal
             ]),
             kinds
           )

    assert Enum.all?(receipts, fn receipt ->
             is_binary(receipt.pre_state_digest) and
               is_binary(receipt.post_state_digest) and
               receipt.pre_state_digest != receipt.post_state_digest and
               is_integer(receipt.canonical_revision)
           end)

    assert Enum.uniq_by(receipts, & &1.id) == receipts
  end

  test "required receipt mode fails closed without a durable checkpoint store" do
    sink = start_supervised!({Memory, []})
    subject = unique_subject("required-without-checkpoint")
    previous_trap = Process.flag(:trap_exit, true)

    assert {:error, :required_receipts_need_checkpoint_store} =
             Instance.start_link(
               agent: @agent,
               subject: subject,
               idle: false,
               receipt_mode: :required,
               receipt_sink: {Memory, server: sink}
             )

    Process.flag(:trap_exit, previous_trap)
  end

  test "required mode crosses payload, outbox, checkpoint, delivery, and ack barriers" do
    sink = start_supervised!({Memory, []})
    definition_server = start_agent(%{})
    checkpoint_server = start_agent(%{})

    definition_store =
      {SpectreReceiptContractTest.DefinitionStore,
       server: definition_server,
       id: "receipt-definition-store-#{System.unique_integer([:positive])}"}

    checkpoint_store =
      {SpectreReceiptContractTest.CheckpointStore, server: checkpoint_server}

    instance =
      start_instance(
        receipt_mode: :required,
        receipt_sink: {Memory, server: sink},
        definition_store: definition_store,
        checkpoint_store: checkpoint_store
      )

    assert {:ok, %Spectre.Result{reply_text: "receipted response"}} =
             Instance.ask(instance, "receipt required", model: SpectreReceiptContractTest.Model)

    assert_eventually(fn -> length(Memory.all(server: sink)) >= 4 end)

    assert_eventually(fn ->
      Agent.get(checkpoint_server, fn entries ->
        Enum.any?(entries, fn {_key, {revision, checkpoint}} ->
          revision > 0 and is_binary(checkpoint)
        end)
      end)
    end)

    assert_eventually(fn ->
      info = Instance.info(instance)
      info.active_run == nil and info.invocations == %{}
    end)
  end

  test "required mode admits below outbox capacity while a receipt append is pending" do
    sink_server = start_agent(%{blocks_left: 1, payloads: %{}, receipts: %{}})
    definition_server = start_agent(%{})
    checkpoint_server = start_agent(%{})

    definition_store =
      {SpectreReceiptContractTest.DefinitionStore,
       server: definition_server,
       id: "receipt-pending-store-#{System.unique_integer([:positive])}"}

    checkpoint_store =
      {SpectreReceiptContractTest.CheckpointStore, server: checkpoint_server}

    sink =
      {SpectreReceiptContractTest.BlockingSink, server: sink_server, test_pid: self()}

    instance =
      start_instance(
        receipt_mode: :required,
        receipt_outbox_limit: 8,
        receipt_sink: sink,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store
      )

    first =
      Task.async(fn ->
        Instance.ask(instance, "receipt first", model: SpectreReceiptContractTest.Model)
      end)

    assert_receive {:blocking_sink_append, receipt_id, delivery}

    on_exit(fn ->
      if Process.alive?(delivery), do: send(delivery, {:release_blocking_sink, receipt_id})
    end)

    second =
      Task.async(fn ->
        Instance.ask(instance, "receipt second", model: SpectreReceiptContractTest.Model)
      end)

    # Admission is accepted and remains queued behind the durable boundary;
    # it is not rejected merely because one outbox entry is in flight.
    assert Task.yield(second, 100) == nil

    send(delivery, {:release_blocking_sink, receipt_id})

    assert {:ok, %Spectre.Result{reply_text: "receipted response"}} = Task.await(first, 5_000)
    assert {:ok, %Spectre.Result{reply_text: "receipted response"}} = Task.await(second, 5_000)
  end

  test "required mode reconciles an append that committed before its acknowledgement was lost" do
    sink_server = start_agent(%{payloads: %{}, receipts: %{}})
    definition_server = start_agent(%{})
    checkpoint_server = start_agent(%{})

    definition_store =
      {SpectreReceiptContractTest.DefinitionStore,
       server: definition_server,
       id: "receipt-ambiguous-store-#{System.unique_integer([:positive])}"}

    checkpoint_store =
      {SpectreReceiptContractTest.CheckpointStore, server: checkpoint_server}

    sink =
      {SpectreReceiptContractTest.AmbiguousCommittedSink, server: sink_server, test_pid: self()}

    instance =
      start_instance(
        receipt_mode: :required,
        receipt_sink: sink,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store
      )

    assert {:ok, %Spectre.Result{reply_text: "receipted response"}} =
             Instance.ask(instance, "receipt ambiguous", model: SpectreReceiptContractTest.Model)

    for _boundary <- 1..4 do
      assert_receive {:ambiguous_sink_append, _receipt_id, {:error, {:ambiguous, :lost_ack}}}
    end

    assert_eventually(fn ->
      Agent.get(sink_server, &(map_size(&1.receipts) >= 4))
    end)

    assert_eventually(fn ->
      data = :sys.get_state(instance)

      match?(
        {:ok, %{entries: [], ids: ids}} when ids == %{},
        Spectre.Instance.Canonical.fetch(data.canonical, :receipt_outbox)
      )
    end)
  end

  defp envelope(extra \\ []) do
    attrs = [
      kind: :nondeterminism_sample,
      correlation_id: "receipt-contract",
      causation_id: "boundary-one",
      payload_schema_ref: "spectre.test/receipt/1",
      payload: %{sample: 1},
      privacy: :internal,
      recorded_at: 1
    ]

    attrs |> Keyword.merge(extra) |> Envelope.new!()
  end

  defp start_instance(extra) do
    opts =
      [
        agent: @agent,
        subject: unique_subject("receipt-instance"),
        idle: false
      ]
      |> Keyword.merge(extra)

    start_supervised!({Instance, opts})
  end

  defp unique_subject(prefix) do
    Subject.new("#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp start_agent(initial) do
    {:ok, server} = Agent.start_link(fn -> initial end)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
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
