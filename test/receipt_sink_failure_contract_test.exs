defmodule SpectreReceiptSinkFailureContractTest.FixtureSink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(_envelope, opts) do
    callback_reply(opts, :append_reply, {:ok, :appended})
  end

  @impl Spectre.Receipt.Sink
  def lookup(_id, opts) do
    callback_reply(opts, :lookup_reply, :not_found)
  end

  @impl Spectre.Receipt.Sink
  def put_payload(envelope, opts) do
    callback_reply(
      opts,
      :put_payload_reply,
      {:ok, Spectre.Receipt.Sink.payload_ref(envelope)}
    )
  end

  @impl Spectre.Receipt.Sink
  def get_payload(_ref, opts) do
    callback_reply(opts, :get_payload_reply, :not_found)
  end

  defp callback_reply(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :raise -> raise "receipt sink fixture failed"
      :throw -> throw(:receipt_sink_fixture_failed)
      reply -> reply
    end
  end
end

defmodule SpectreReceiptSinkFailureContractTest.RequiredOnlySink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(_envelope, _opts), do: {:ok, :appended}

  @impl Spectre.Receipt.Sink
  def lookup(_id, _opts), do: :not_found
end

defmodule SpectreReceiptSinkFailureContractTest.NoCallbacks do
  @moduledoc false
end

defmodule SpectreReceiptSinkFailureContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.OutboxEntry
  alias Spectre.Receipt.Sink

  @sink SpectreReceiptSinkFailureContractTest.FixtureSink

  test "sink configuration and callback discovery fail closed" do
    assert {:ok, nil} = Sink.normalize(nil)
    assert {:ok, nil} = Sink.normalize(false)
    assert {:ok, {@sink, []}} = Sink.normalize(@sink)
    assert {:ok, {@sink, [namespace: :test]}} = Sink.normalize({@sink, [namespace: :test]})
    assert {:error, {:invalid_receipt_sink, :options}} = Sink.normalize({@sink, [:invalid]})

    for {value, class} <- [
          {true, :other},
          {{:invalid, :shape, :tuple}, :tuple},
          {[:invalid], :list},
          {%{invalid: true}, :map},
          {1, :other}
        ] do
      assert {:error, {:invalid_receipt_sink, ^class}} = Sink.normalize(value)
    end

    assert Sink.payload_capable?({@sink, []})

    refute Sink.payload_capable?({SpectreReceiptSinkFailureContractTest.RequiredOnlySink, []})

    refute Sink.payload_capable?(nil)
    refute Sink.payload_capable?({Module.concat(__MODULE__, Missing), []})

    receipt = envelope()
    no_callbacks = {SpectreReceiptSinkFailureContractTest.NoCallbacks, []}
    missing = {Module.concat(__MODULE__, Missing), []}

    assert {:error, {:receipt_sink_callback_missing, _, :append, 2}} =
             Sink.append(no_callbacks, receipt, [])

    assert {:error, {:receipt_sink_not_loaded, _module}} = Sink.append(missing, receipt, [])

    assert {:error, {:receipt_sink_callback_missing, _, :lookup, 2}} =
             Sink.lookup(no_callbacks, receipt.id, [])

    assert {:error, {:receipt_sink_callback_missing, _, :put_payload, 2}} =
             Sink.put_payload(no_callbacks, receipt, [])

    assert {:error, {:receipt_sink_callback_missing, _, :get_payload, 2}} =
             Sink.get_payload(no_callbacks, Sink.payload_ref(receipt), [])

    assert {:error, {:receipt_sink_conformance_failed, {:receipt_sink_error, :down}}} =
             Sink.Conformance.run({@sink, append_reply: {:error, :down}})

    assert {:error, {:receipt_sink_conformance_failed, :not_found}} =
             Sink.Conformance.run({@sink, []})
  end

  test "append and lookup normalize adapter replies without leaking external detail" do
    receipt = envelope()
    sink = {@sink, []}

    assert {:error, :receipt_sink_disabled} = Sink.append(nil, receipt, [])
    assert {:ok, :appended} = Sink.append(sink, receipt, [])

    assert {:ok, :idempotent} =
             Sink.append({@sink, append_reply: {:ok, :idempotent}}, receipt, [])

    for {reply, expected} <- [
          {{:error, :ambiguous}, :ambiguous},
          {{:error, {:ambiguous, {:lost_ack, "private"}}}, {:ambiguous, :lost_ack}},
          {{:error, :provider_failure}, {:receipt_sink_error, :provider_failure}},
          {{:error, {:provider_failure, "private"}}, {:receipt_sink_error, :provider_failure}},
          {{:error, {:provider_failure, :one, :two}}, {:receipt_sink_error, :provider_failure}},
          {{:error, %{private: true}}, {:receipt_sink_error, :error}},
          {:invalid, {:ambiguous, :invalid_receipt_append_reply}}
        ] do
      assert {:error, ^expected} =
               Sink.append({@sink, append_reply: reply}, receipt, [])
    end

    assert {:error, {:ambiguous, :receipt_append_exception}} =
             Sink.append({@sink, append_reply: :raise}, receipt, [])

    assert {:error, {:ambiguous, :receipt_append_failure}} =
             Sink.append({@sink, append_reply: :throw}, receipt, [])

    assert :not_found = Sink.lookup(nil, receipt.id, [])
    assert {:ok, ^receipt} = Sink.lookup({@sink, lookup_reply: {:ok, receipt}}, receipt.id, [])
    assert :not_found = Sink.lookup({@sink, lookup_reply: :not_found}, receipt.id, [])

    other = envelope(correlation_id: "other")

    assert {:error, :receipt_lookup_id_mismatch} =
             Sink.lookup({@sink, lookup_reply: {:ok, other}}, receipt.id, [])

    noncanonical = %{receipt | payload_digest: nil}

    assert {:error, {:receipt_sink_error, :invalid_receipt_envelope}} =
             Sink.lookup({@sink, lookup_reply: {:ok, noncanonical}}, receipt.id, [])

    assert {:error, {:receipt_sink_error, :provider_failure}} =
             Sink.lookup(
               {@sink, lookup_reply: {:error, {:provider_failure, "private"}}},
               receipt.id,
               []
             )

    assert {:error, {:receipt_sink_error, :invalid_receipt_lookup_reply}} =
             Sink.lookup({@sink, lookup_reply: :invalid}, receipt.id, [])

    assert {:error, {:receipt_sink_error, :receipt_lookup_exception}} =
             Sink.lookup({@sink, lookup_reply: :raise}, receipt.id, [])

    assert {:error, {:receipt_sink_error, :receipt_lookup_failure}} =
             Sink.lookup({@sink, lookup_reply: :throw}, receipt.id, [])
  end

  test "content-addressed payload writes reconcile ambiguous acknowledgements" do
    receipt = envelope()
    ref = Sink.payload_ref(receipt)

    assert {:error, :receipt_sink_disabled} = Sink.put_payload(nil, receipt, [])
    assert {:ok, ^ref} = Sink.put_payload({@sink, []}, receipt, [])

    assert {:error, :receipt_payload_ref_mismatch} =
             Sink.put_payload({@sink, put_payload_reply: {:ok, "wrong"}}, receipt, [])

    assert {:error, {:receipt_sink_error, :provider_failure}} =
             Sink.put_payload(
               {@sink, put_payload_reply: {:error, {:provider_failure, "private"}}},
               receipt,
               []
             )

    assert {:error, {:ambiguous, :invalid_receipt_payload_reply}} =
             Sink.put_payload({@sink, put_payload_reply: :invalid}, receipt, [])

    assert {:error, {:ambiguous, :receipt_payload_exception}} =
             Sink.put_payload({@sink, put_payload_reply: :raise}, receipt, [])

    assert {:error, {:ambiguous, :receipt_payload_failure}} =
             Sink.put_payload({@sink, put_payload_reply: :throw}, receipt, [])

    assert {:ok, ^ref} =
             Sink.put_payload(
               {@sink,
                put_payload_reply: {:error, :ambiguous}, get_payload_reply: {:ok, receipt}},
               receipt,
               []
             )

    other = envelope(correlation_id: "other-payload")

    assert {:error,
            {:receipt_payload_reconciliation_failed, :receipt_payload_lookup_ref_mismatch}} =
             Sink.put_payload(
               {@sink,
                put_payload_reply: {:error, {:ambiguous, :lost_ack}},
                get_payload_reply: {:ok, other}},
               receipt,
               []
             )

    assert {:error, {:ambiguous, :lost_ack}} =
             Sink.put_payload(
               {@sink,
                put_payload_reply: {:error, {:ambiguous, :lost_ack}},
                get_payload_reply: :not_found},
               receipt,
               []
             )

    assert {:error,
            {:receipt_payload_reconciliation_failed, {:receipt_sink_error, :lookup_failed}}} =
             Sink.put_payload(
               {@sink,
                put_payload_reply: {:error, :ambiguous},
                get_payload_reply: {:error, :lookup_failed}},
               receipt,
               []
             )
  end

  test "payload lookup verifies both envelope validity and content address" do
    receipt = envelope()
    ref = Sink.payload_ref(receipt)

    assert :not_found = Sink.get_payload(nil, ref, [])
    assert :not_found = Sink.get_payload({@sink, get_payload_reply: :not_found}, ref, [])
    assert {:ok, ^receipt} = Sink.get_payload({@sink, get_payload_reply: {:ok, receipt}}, ref, [])

    other = envelope(correlation_id: "other")

    assert {:error, :receipt_payload_lookup_ref_mismatch} =
             Sink.get_payload({@sink, get_payload_reply: {:ok, other}}, ref, [])

    assert {:error, {:receipt_sink_error, :invalid_receipt_envelope}} =
             Sink.get_payload(
               {@sink, get_payload_reply: {:ok, %{receipt | payload_digest: nil}}},
               ref,
               []
             )

    assert {:error, {:receipt_sink_error, :provider_failure}} =
             Sink.get_payload(
               {@sink, get_payload_reply: {:error, {:provider_failure, "private"}}},
               ref,
               []
             )

    assert {:error, {:receipt_sink_error, :invalid_receipt_payload_lookup_reply}} =
             Sink.get_payload({@sink, get_payload_reply: :invalid}, ref, [])

    assert {:error, {:receipt_sink_error, :receipt_payload_lookup_exception}} =
             Sink.get_payload({@sink, get_payload_reply: :raise}, ref, [])

    assert {:error, {:receipt_sink_error, :receipt_payload_lookup_failure}} =
             Sink.get_payload({@sink, get_payload_reply: :throw}, ref, [])
  end

  test "sink writes reject malformed receipt structs before invoking adapters" do
    receipt = envelope()
    malformed = %{receipt | metadata: %URI{}}

    assert {:error, :invalid_receipt_metadata} = Sink.append({@sink, []}, malformed, [])
  end

  test "receipt envelope schema rejects malformed identity, payload, and boundary evidence" do
    assert :nondeterminism_sample in Envelope.kinds()
    assert :inference_attempt_terminal in Envelope.kinds()

    for {value, shape} <- [
          {:invalid, :atom},
          {"invalid", :binary},
          {{:invalid}, :tuple},
          {1, :other}
        ] do
      assert {:error, {:invalid_receipt_envelope, ^shape}} = Envelope.new(value)
    end

    attrs = envelope_attrs()

    failures = [
      {Keyword.put(attrs, :unknown, true), {:unknown_receipt_envelope_fields, [:unknown]}},
      {Keyword.put(attrs, :schema_version, 99), {:unsupported_receipt_schema, 99}},
      {Keyword.put(attrs, :kind, :unknown), {:invalid_receipt_kind, :unknown}},
      {Keyword.put(attrs, :correlation_id, ""), {:invalid_receipt_field, :correlation_id}},
      {Keyword.put(attrs, :causation_id, 1), {:invalid_receipt_field, :causation_id}},
      {Keyword.put(attrs, :privacy, :secret), {:invalid_receipt_privacy, :secret}},
      {Keyword.put(attrs, :payload_schema_ref, ""),
       {:invalid_receipt_field, :payload_schema_ref}},
      {Keyword.put(attrs, :recorded_at, -1), {:invalid_receipt_field, :recorded_at}},
      {Keyword.put(attrs, :run_revision, -1), {:invalid_receipt_field, :run_revision}},
      {Keyword.put(attrs, :instance_ref, ""), {:invalid_receipt_field, :instance_ref}},
      {Keyword.put(attrs, :metadata, []), :invalid_receipt_metadata},
      {Keyword.put(attrs, :payload_ref, 1), :invalid_receipt_payload_ref},
      {Keyword.put(attrs, :manifest_digest, "not-a-digest"),
       {:invalid_receipt_digest, :manifest_digest}}
    ]

    Enum.each(failures, fn {invalid, reason} ->
      assert {:error, ^reason} = Envelope.new(invalid)
    end)

    assert {:error, :receipt_payload_and_ref_conflict} =
             Envelope.new(Keyword.put(attrs, :payload_ref, "payload:also-present"))

    assert {:error, {:nonportable_run_value, [], :pid}} =
             Envelope.new(Keyword.put(attrs, :payload, self()))

    assert_raise ArgumentError, ~r/invalid receipt envelope/, fn ->
      Envelope.new!(Keyword.put(attrs, :privacy, :invalid))
    end
  end

  test "boundary-specific receipts require their canonical and inference fences" do
    digest = String.duplicate("a", 64)

    common = [
      correlation_id: "boundary",
      payload_schema_ref: "spectre.test/boundary/1",
      payload: %{},
      instance_ref: "instance",
      run_id: "run",
      run_revision: 1,
      canonical_revision: 2,
      definition_ref: "definition",
      pre_state_digest: digest,
      post_state_digest: digest,
      recorded_at: 1
    ]

    assert {:ok, %Envelope{kind: :run_input_admitted}} =
             Envelope.new(Keyword.put(common, :kind, :run_input_admitted))

    inference =
      common ++
        [
          inference_id: "inference",
          invocation_id: "invocation",
          attempt_id: "attempt",
          control_revision: 0,
          stream_epoch: "epoch"
        ]

    for kind <- [
          :inference_selected,
          :inference_attempt_started,
          :inference_attempt_terminal,
          :inference_attempt_superseded,
          :inference_consumer_never_attached
        ] do
      assert {:ok, %Envelope{kind: ^kind}} = Envelope.new(Keyword.put(inference, :kind, kind))
    end

    assert {:error, {:missing_receipt_field, :inference_id}} =
             Envelope.new(Keyword.put(common, :kind, :inference_selected))

    assert {:error, {:missing_receipt_field, :instance_ref}} =
             common
             |> Keyword.put(:kind, :run_input_admitted)
             |> Keyword.delete(:instance_ref)
             |> Envelope.new()

    for kind <- [:policy_decision, :effect_terminal, :action_terminal, :authority_decision] do
      attrs = Keyword.put(common, :kind, kind)

      attrs =
        if kind in [:effect_terminal, :action_terminal],
          do: Keyword.put(attrs, :invocation_id, "invocation"),
          else: attrs

      assert {:ok, %Envelope{kind: ^kind}} = Envelope.new(attrs)
    end

    assert {:ok, %Envelope{kind: :canonical_commit}} =
             Envelope.new(
               kind: :canonical_commit,
               correlation_id: "commit",
               payload_schema_ref: "spectre.test/commit/1",
               payload: %{},
               instance_ref: "instance",
               canonical_revision: 1,
               pre_state_digest: digest,
               post_state_digest: digest,
               recorded_at: 1
             )
  end

  test "non-canonical envelopes cannot be digested and outbox entries validate every pointer" do
    receipt = envelope()

    assert_raise ArgumentError, ~r/non-canonical receipt envelope/, fn ->
      Envelope.digest(%{receipt | payload_digest: nil})
    end

    ref = Sink.payload_ref(receipt)
    entry = OutboxEntry.new(receipt, ref, 1)
    assert :ok = OutboxEntry.validate(entry)
    assert {:error, :invalid_receipt_outbox_entry} = OutboxEntry.validate(:invalid)

    invalid = [
      {%{entry | id: "invalid"}, :invalid_receipt_outbox_id},
      {%{entry | digest: "invalid"}, :invalid_receipt_outbox_digest},
      {%{entry | payload_ref: "invalid"}, :invalid_receipt_outbox_payload_ref},
      {%{entry | inserted_revision: -1}, :invalid_receipt_outbox_revision},
      {%{entry | status: :delivered}, :invalid_receipt_outbox_status},
      {%{entry | attempts: -1}, :invalid_receipt_outbox_attempts},
      {%{entry | last_error_class: true}, :invalid_receipt_outbox_error_class}
    ]

    Enum.each(invalid, fn {value, reason} ->
      assert {:error, ^reason} = OutboxEntry.validate(value)
    end)
  end

  defp envelope(extra \\ []) do
    envelope_attrs()
    |> Keyword.merge(extra)
    |> Envelope.new!()
  end

  defp envelope_attrs do
    [
      kind: :nondeterminism_sample,
      correlation_id: "receipt-failure-contract",
      causation_id: "sample-one",
      payload_schema_ref: "spectre.test/receipt/1",
      payload: %{sample: 1},
      privacy: :internal,
      recorded_at: 1
    ]
  end
end
