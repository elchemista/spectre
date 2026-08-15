defmodule SpectreInferenceCanonicalReceiptEdgeContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"
end

defmodule SpectreInferenceCanonicalReceiptEdgeContractTest.Sink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  @impl Spectre.Receipt.Sink
  def append(_envelope, opts), do: Keyword.get(opts, :append_reply, {:ok, :appended})

  @impl Spectre.Receipt.Sink
  def lookup(_id, opts), do: Keyword.get(opts, :lookup_reply, :not_found)

  @impl Spectre.Receipt.Sink
  def put_payload(envelope, _opts), do: {:ok, Spectre.Receipt.Sink.payload_ref(envelope)}

  @impl Spectre.Receipt.Sink
  def get_payload(_ref, opts), do: Keyword.get(opts, :get_payload_reply, :not_found)
end

defmodule SpectreInferenceCanonicalReceiptEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.AgentRef
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Event.Envelope, as: EventEnvelope
  alias Spectre.Inference.Progress
  alias Spectre.Instance
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Validator
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Input
  alias Spectre.Operation.Control.Command
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.OutboxEntry
  alias Spectre.Receipt.Sink
  alias Spectre.Run
  alias Spectre.State
  alias Spectre.Subject

  @agent SpectreInferenceCanonicalReceiptEdgeContractTest.Agent

  describe "Canonical v3 inference sections" do
    test "validator rejects forged flow, activation, lifecycle, event, and event-window shapes" do
      data = instance_state()

      invalid_flow = %{data.state | revision: -1}

      assert {:error, {:invalid_canonical_flow_state, {:invalid_state_revision, -1}}} =
               data |> put_section(:flow, invalid_flow) |> validate()

      invalid_activation = struct(Activation)

      assert {:error, {:invalid_canonical_activation, _reason}} =
               data |> put_section(:activation, invalid_activation) |> validate()

      definition_ref = Run.definition_ref(@agent)

      {:ok, activation} =
        Activation.build(%{
          definition_ref: definition_ref,
          candidate_ref: %CandidateRef{algorithm: :sha256, digest: hex_digest("c")},
          manifest_digest: hex_digest("d"),
          publication_id: "publication",
          closure_digest: hex_digest("e"),
          generation: 1,
          authority_epoch: 0,
          owner_fencing_token: 1,
          activated_at: 1
        })

      normalized_activation = %{activation | definition_ref: to_string(definition_ref)}

      assert {:error, :canonical_activation_integrity_mismatch} =
               data |> put_section(:activation, normalized_activation) |> validate()

      assert {:error, :canonical_activation_lifecycle_mismatch} =
               data
               |> put_section(:activation, activation)
               |> put_section(:lifecycles, %{})
               |> validate()

      lifecycle =
        Lifecycle.new!(
          definition_ref: definition_ref,
          changed_at: 1
        )

      lifecycle_key = "forged-lifecycle-key"

      assert {:error, {:canonical_lifecycle_key_mismatch, ^lifecycle_key}} =
               data
               |> put_section(:lifecycles, %{lifecycle_key => lifecycle})
               |> validate()

      pending =
        EventEnvelope.new!(
          event_class: :input,
          payload_schema_ref: "spectre.test/event/1",
          payload: %{message: "safe"},
          emitted_at: 1
        )

      assert {:ok, admitted} =
               EventEnvelope.admit(pending,
                 owner_definition_ref: definition_ref,
                 admitted_activation_generation: 1,
                 authority_epoch: 0,
                 owner_fencing_token: 1,
                 admission_revision: 1,
                 status: :admitted,
                 admitted_at: 2
               )

      base = %{data | canonical: %{data.canonical | revision: 1}}

      window = %{
        records: [admitted],
        ids: %{
          admitted.id => %{
            intent_digest: EventEnvelope.intent_digest(admitted),
            admission_receipt: admitted.admission_receipt
          }
        }
      }

      assert :ok = base |> put_section(:event_admissions, window) |> validate()

      normalized_event = %{admitted | owner_definition_ref: to_string(definition_ref)}

      assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
               base
               |> put_section(:event_admissions, %{window | records: [normalized_event]})
               |> validate()

      invalid_event = %{admitted | admission_receipt: "invalid"}

      assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
               base
               |> put_section(:event_admissions, %{window | records: [invalid_event]})
               |> validate()

      assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
               base
               |> put_section(:event_admissions, %{records: [:invalid], ids: %{}})
               |> validate()

      assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
               base
               |> put_section(:event_admissions, %{records: [:invalid, :invalid], ids: %{}})
               |> validate()

      assert {:error, :invalid_canonical_operation_events} =
               base |> put_section(:events, :invalid) |> validate()

      assert {:error, :invalid_canonical_operation_events} =
               base
               |> put_section(:events, %{records: %{}, ids: %{}})
               |> validate()
    end

    test "accepts a fully fenced inference control and rejects malformed variants" do
      data = instance_state()
      pending = command(:committed)
      completed = command(:applied)

      control = %{
        generation: 1,
        pending: pending,
        last_command: completed,
        history: [completed]
      }

      assert :ok =
               data |> put_section(:inference_control, %{"inference" => control}) |> validate()

      invalid = [
        {[], {:invalid_canonical_inference_control, []}},
        {%{"" => control}, :invalid_inference_control_entry},
        {%{"inference" => :invalid},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}},
        {%{"inference" => Map.put(control, :extra, true)},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}},
        {%{"inference" => %{control | generation: -1}},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}},
        {%{"inference" => %{control | history: List.duplicate(completed, 129)}},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}},
        {%{"inference" => %{control | pending: command(:pending)}},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}},
        {%{"inference" => %{control | pending: %{pending | loop_id: "other"}}},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}},
        {%{"inference" => %{control | pending: %{pending | action: :pause}}},
         {:invalid_inference_control, "inference", :invalid_inference_control_shape}}
      ]

      Enum.each(invalid, fn {value, reason} ->
        assert {:error, ^reason} = data |> put_section(:inference_control, value) |> validate()
      end)
    end

    test "progress entries are typed, owner-keyed, valid, and never from the future" do
      data = instance_state()
      progress = progress(canonical_revision: 0)

      assert :ok =
               data |> put_section(:inference_progress, %{"inference" => progress}) |> validate()

      second = %{progress | inference_id: "inference-two"}
      bounded = %{"inference" => progress, "inference-two" => second}

      assert :ok =
               data
               |> put_section(:inference_progress, bounded)
               |> validate(inference_progress_limit: 2)

      assert {:error, {:canonical_inference_progress_limit_exceeded, 2, 1}} =
               data
               |> put_section(:inference_progress, bounded)
               |> validate(inference_progress_limit: 1)

      assert {:error, {:invalid_canonical_inference_progress_limit, -1}} =
               data
               |> put_section(:inference_progress, %{})
               |> validate(inference_progress_limit: -1)

      invalid = [
        {[], {:invalid_canonical_inference_progress, []}},
        {%{"other" => progress}, {:invalid_inference_progress_entry, "other"}},
        {%{"inference" => %{progress | state: :invalid}},
         {:invalid_inference_progress, "inference", :invalid_inference_progress_state}},
        {%{"inference" => %{progress | canonical_revision: 1}},
         {:future_inference_progress, "inference"}}
      ]

      Enum.each(invalid, fn {value, reason} ->
        assert {:error, ^reason} = data |> put_section(:inference_progress, value) |> validate()
      end)
    end

    test "receipt outbox validation binds entry, digest index, limits, and revision" do
      data = instance_state()
      data = %{data | canonical: %{data.canonical | revision: 1}}
      envelope = envelope(canonical_revision: 1)
      entry = OutboxEntry.new(envelope, Sink.payload_ref(envelope), 1)
      outbox = %{entries: [entry], ids: %{entry.id => entry.digest}}

      assert :ok =
               data |> put_section(:receipt_outbox, outbox) |> validate(receipt_outbox_limit: 1)

      second_envelope = envelope(canonical_revision: 1, correlation_id: "canonical-receipt-two")
      second_entry = OutboxEntry.new(second_envelope, Sink.payload_ref(second_envelope), 1)

      bounded_outbox = %{
        entries: [entry, second_entry],
        ids: %{entry.id => entry.digest, second_entry.id => second_entry.digest}
      }

      assert :ok =
               data
               |> put_section(:receipt_outbox, bounded_outbox)
               |> validate(receipt_outbox_limit: 2)

      assert {:error, :invalid_canonical_receipt_outbox} =
               data
               |> put_section(:receipt_outbox, bounded_outbox)
               |> validate(receipt_outbox_limit: 1)

      invalid = [
        {[], {:invalid_canonical_receipt_outbox, []}, []},
        {%{entries: []}, :invalid_canonical_receipt_outbox, []},
        {%{entries: [entry, entry], ids: %{entry.id => entry.digest}},
         :invalid_canonical_receipt_outbox, []},
        {%{entries: [%{entry | digest: "invalid"}], ids: %{entry.id => "invalid"}},
         :invalid_canonical_receipt_outbox, []},
        {%{entries: [%{entry | inserted_revision: 2}], ids: %{entry.id => entry.digest}},
         :invalid_canonical_receipt_outbox, []},
        {%{entries: [entry], ids: %{}}, :invalid_canonical_receipt_outbox, []},
        {outbox, :invalid_canonical_receipt_outbox, [receipt_outbox_limit: 0]}
      ]

      Enum.each(invalid, fn {value, reason, opts} ->
        assert {:error, ^reason} = data |> put_section(:receipt_outbox, value) |> validate(opts)
      end)
    end
  end

  describe "required receipt rebasing and delivery state" do
    test "core receipts redact sensitive keys and use millisecond timestamps" do
      data = instance_state()
      before = System.system_time(:millisecond)

      assert {:ok, prepared} =
               Receipts.prepare_sections(
                 data,
                 %{},
                 :nondeterminism_sample,
                 %{
                   api_key: "payload-secret",
                   arguments: [credentials: "nested-secret"],
                   visible: "retained"
                 },
                 correlation_id: "receipt-redaction",
                 payload_schema_ref: "spectre.test/receipt-redaction/1",
                 privacy: :confidential,
                 metadata: %{authorization: "metadata-secret"}
               )

      after_prepare = System.system_time(:millisecond)
      envelope = prepared.envelope

      assert envelope.payload.api_key == "[REDACTED]"
      assert envelope.payload.arguments == [credentials: "[REDACTED]"]
      assert envelope.payload.visible == "retained"
      assert envelope.metadata.authorization == "[REDACTED]"

      assert Enum.sort(envelope.metadata.sensitive_data_redactions) ==
               Enum.sort([
                 [:payload, :api_key],
                 [:payload, :arguments, 0, :credentials],
                 [:metadata, :authorization]
               ])

      assert envelope.recorded_at >= before
      assert envelope.recorded_at <= after_prepare
      assert envelope.recorded_at > envelope.canonical_revision
    end

    test "records delivery failures and blocks admission only at capacity" do
      data = instance_state(receipt_mode: :required, max_receipt_outbox: 2)
      prepared = prepared(data, %{flow: %{data.state | revision: 1}})
      payload_ref = Sink.payload_ref(prepared.envelope)

      assert {:ok, committed, _envelope} = Receipts.commit(data, prepared, :required, payload_ref)
      assert :ok = Receipts.admission_available?(committed)

      assert {:ok, failed} =
               Receipts.mark_delivery_failure(committed, prepared.envelope.id, :temporarily_down)

      assert {:ok, %{entries: [%{status: :ambiguous, attempts: 1}]}} =
               Canonical.fetch(failed.canonical, :receipt_outbox)

      assert {:error, :receipt_outbox_entry_not_found} =
               Receipts.mark_delivery_failure(failed, "receipt:missing", :missing)

      assert {:error, :receipt_outbox_full} =
               failed
               |> Map.put(:max_receipt_outbox, 1)
               |> Receipts.admission_available?()

      assert {:ok, acknowledged} = Receipts.acknowledge(failed, prepared.envelope.id)
      assert :ok = Receipts.admission_available?(acknowledged)

      assert {:ok, %{entries: [], ids: %{}}} =
               Canonical.fetch(acknowledged.canonical, :receipt_outbox)

      assert :ok = Receipts.admission_available?(%{acknowledged | receipt_mode: :observational})
    end

    test "required commits reject unstaged payloads, full outboxes, and digest drift" do
      data = instance_state(receipt_mode: :required, max_receipt_outbox: 0)
      prepared = prepared(data, %{flow: %{data.state | revision: 1}})

      assert {:error, :required_receipt_payload_not_staged} =
               Receipts.commit(data, prepared, :required, nil)

      assert {:error, :receipt_outbox_full} =
               Receipts.commit(data, prepared, :required, Sink.payload_ref(prepared.envelope))

      drifted = %{prepared | envelope: %{prepared.envelope | post_state_digest: hex_digest("0")}}

      assert {:error, {:receipt_post_state_digest_mismatch, actual}} =
               Receipts.commit(%{data | max_receipt_outbox: 2}, drifted, :observational)

      assert is_binary(actual)
    end

    test "refresh rebases aggregate targets without overwriting unrelated commits" do
      data = instance_state()

      prepared =
        prepared(
          data,
          %{runs: %{"target" => "new-target"}},
          run_id: "target"
        )

      advanced = put_section(data, :runs, %{"other" => "unrelated"})
      assert {:ok, refreshed} = Receipts.refresh(advanced, prepared)
      assert refreshed.writes.runs == %{"other" => "unrelated", "target" => "new-target"}
      assert refreshed.envelope.recorded_at == prepared.envelope.recorded_at

      assert {:error, {:receipt_refresh_target_missing, :runs, "target"}} =
               Receipts.refresh(advanced, %{prepared | writes: %{runs: %{}}})

      assert {:error, {:invalid_receipt_refresh_section, :runs}} =
               Receipts.refresh(advanced, %{prepared | writes: %{runs: []}})

      assert {:error, {:receipt_refresh_base_missing, :runs}} =
               Receipts.refresh(advanced, %{prepared | base_sections: %{}})

      conflict = put_section(data, :runs, %{"target" => "concurrent"})

      assert {:error, {:receipt_refresh_conflict, :runs, "target"}} =
               Receipts.refresh(conflict, prepared)
    end

    test "refresh rejects concurrent changes to scalar staged sections" do
      data = instance_state()
      staged = %{data.state | revision: 1}
      prepared = prepared(data, %{flow: staged})
      concurrent = put_section(data, :flow, %{data.state | revision: 2})

      assert {:error, {:receipt_refresh_conflict, :flow}} =
               Receipts.refresh(concurrent, prepared)
    end

    test "required delivery tasks classify payload and append reconciliation failures" do
      {base, entry, receipt} = required_delivery_fixture()
      other = envelope(canonical_revision: receipt.canonical_revision, recorded_at: 2)
      digest_drift = %{receipt | recorded_at: receipt.recorded_at + 1}

      scenarios = [
        [get_payload_reply: :not_found],
        [get_payload_reply: {:error, :payload_store_down}],
        [get_payload_reply: {:ok, other}],
        [get_payload_reply: {:ok, digest_drift}],
        [
          get_payload_reply: {:ok, receipt},
          append_reply: {:error, :ambiguous},
          lookup_reply: :not_found
        ],
        [
          get_payload_reply: {:ok, receipt},
          append_reply: {:error, :ambiguous},
          lookup_reply: {:error, :lookup_down}
        ],
        [
          get_payload_reply: {:ok, receipt},
          append_reply: {:error, :ambiguous},
          lookup_reply: {:ok, other}
        ],
        [
          get_payload_reply: {:ok, receipt},
          append_reply: {:error, :ambiguous},
          lookup_reply: {:ok, receipt}
        ]
      ]

      Enum.each(scenarios, fn sink_opts ->
        data = %{
          base
          | receipt_sink: {SpectreInferenceCanonicalReceiptEdgeContractTest.Sink, sink_opts}
        }

        {:noreply, delivering} =
          Instance.handle_info({:spectre, :receipt_delivery_retry, entry.id}, data)

        assert %{mode: :required} = Map.fetch!(delivering.receipt_deliveries, entry.id)

        assert_receive {:spectre, :receipt_delivery_result, receipt_id, result}, 1_000
        assert receipt_id == entry.id

        {:noreply, failed} =
          Instance.handle_info(
            {:spectre, :receipt_delivery_result, receipt_id, result},
            delivering
          )

        assert Map.has_key?(failed.receipt_retry_timers, receipt_id)
        cancel_retry_timers(failed)
      end)
    end

    test "receipt delivery and staging mailbox races are harmless" do
      data = instance_state(receipt_mode: :required)

      assert {:noreply, ^data} =
               Instance.handle_info(
                 {:spectre, :receipt_payload_staged, "unknown", {:error, :late}},
                 data
               )

      assert {:noreply, ^data} =
               Instance.handle_info(
                 {:spectre, :receipt_delivery_result, "unknown", {:error, :late}},
                 data
               )

      timer = make_ref()

      retrying = %{
        data
        | receipt_retry_timers: %{"receipt" => timer},
          receipt_deliveries: %{"receipt" => %{mode: :required}}
      }

      assert {:noreply, retried} =
               Instance.handle_info({:spectre, :receipt_delivery_retry, "receipt"}, retrying)

      assert retried.receipt_retry_timers == %{}
      assert retried.receipt_deliveries == retrying.receipt_deliveries
    end

    test "required payload staging contains storage, refresh, commit, and starvation failures" do
      base =
        instance_state(
          receipt_mode: :required,
          receipt_sink: {SpectreInferenceCanonicalReceiptEdgeContractTest.Sink, []}
        )

      prepared = prepared(base, %{flow: %{base.state | revision: 1}})
      payload_ref = Sink.payload_ref(prepared.envelope)

      scenarios = [
        {
          prepared,
          {:error, :payload_store_down},
          [],
          {:required_receipt_payload_failed, :payload_store_down}
        },
        {
          %{prepared | base_sections: %{}},
          {:ok, payload_ref},
          [],
          {:receipt_refresh_base_missing, :flow}
        },
        {prepared, {:ok, payload_ref}, [max_receipt_outbox: 0], :receipt_outbox_full}
      ]

      Enum.each(scenarios, fn {candidate, result, overrides, expected_reason} ->
        tag = make_ref()
        staging = receipt_staging(candidate, tag)

        data =
          base
          |> Map.merge(Map.new(overrides))
          |> Map.merge(%{
            receipt_staging: %{staging.token => staging},
            state_lock: %{receipt_id: staging.token}
          })

        assert {:noreply, failed} =
                 Instance.handle_info(
                   {:spectre, :receipt_payload_staged, staging.token, result},
                   data
                 )

        assert failed.receipt_staging == %{}
        assert failed.state_lock == nil
        assert_receive {^tag, {:error, ^expected_reason}}
      end)

      assert {:ok, advanced} =
               Commit.canonical_sections(
                 base,
                 %{directive: %{unrelated: :commit}},
                 correlation_id: "receipt-rebase",
                 provenance: %{source: :test},
                 checkpoint: :defer
               )

      rebase_tag = make_ref()
      rebase_staging = receipt_staging(prepared, rebase_tag)

      rebasing = %{
        advanced
        | receipt_staging: %{rebase_staging.token => rebase_staging},
          state_lock: %{receipt_id: rebase_staging.token}
      }

      assert {:noreply, restaged} =
               Instance.handle_info(
                 {:spectre, :receipt_payload_staged, rebase_staging.token, {:ok, payload_ref}},
                 rebasing
               )

      assert map_size(restaged.receipt_staging) == 1
      [{new_token, new_staging}] = Map.to_list(restaged.receipt_staging)
      assert new_token != rebase_staging.token
      assert new_staging.attempt == 1
      assert new_staging.prepared.envelope.canonical_revision == advanced.canonical.revision + 1

      assert_receive {:spectre, :receipt_payload_staged, ^new_token, {:ok, _new_payload_ref}}
      Process.demonitor(new_staging.monitor, [:flush])

      starvation_tag = make_ref()
      starvation = receipt_staging(prepared, starvation_tag)

      starved_data = %{
        advanced
        | base_opts: [receipt_staging_rebase_limit: 0],
          receipt_staging: %{starvation.token => starvation},
          state_lock: %{receipt_id: starvation.token}
      }

      assert {:noreply, starved} =
               Instance.handle_info(
                 {:spectre, :receipt_payload_staged, starvation.token, {:ok, payload_ref}},
                 starved_data
               )

      assert starved.receipt_staging == %{}
      assert starved.state_lock == nil
      assert_receive {^starvation_tag, {:error, :required_receipt_staging_starved}}
    end

    test "required delivery validates every durable boundary against its canonical owner" do
      base = instance_state(receipt_mode: :required, max_receipt_outbox: 8)
      inference = inference_receipt_fences()

      superseded_run =
        base
        |> boundary_run("superseded-run", 2)
        |> Map.merge(%{
          status: :awaiting,
          cursor: :inference,
          inference_continuation: %{
            inference_id: inference.inference_id,
            previous_attempts: [
              %{
                attempt_id: inference.attempt_id,
                invocation_id: inference.invocation_id,
                control_revision: inference.control_revision,
                stream_epoch: inference.stream_epoch,
                outcome: :failed
              }
            ]
          }
        })

      superseded =
        boundary_envelope(base, :inference_attempt_superseded, superseded_run, inference,
          payload: %{outcome: :superseded}
        )

      assert_required_delivery_rejected(base, superseded_run, superseded)
      assert_required_delivery_rejected(base, nil, superseded)

      terminal_metadata = inference

      failed_run =
        base
        |> boundary_run("terminal-run", 3)
        |> Map.merge(%{
          status: :failed,
          metadata: %{inference_terminal: terminal_metadata}
        })

      terminal =
        boundary_envelope(base, :inference_attempt_terminal, failed_run, inference,
          payload: %{outcome: :failed}
        )

      assert_required_delivery_accepted(base, failed_run, terminal)

      mismatched_terminal =
        put_in(
          failed_run.metadata.inference_terminal.stream_epoch,
          "different-epoch"
        )

      assert_required_delivery_rejected(base, mismatched_terminal, terminal)

      completed_run = %{failed_run | status: :complete, metadata: %{}}
      assert_required_delivery_rejected(base, completed_run, terminal)

      policy_run =
        base
        |> boundary_run("policy-run", 4)
        |> Map.put(:metadata, %{policy_decision: %{boundary_id: "policy-boundary"}})

      policy =
        boundary_envelope(base, :policy_decision, policy_run, %{},
          payload: %{boundary_id: "policy-boundary", decision: :accept}
        )

      assert_required_delivery_accepted(base, policy_run, policy)
      assert_required_delivery_rejected(base, %{policy_run | metadata: %{}}, policy)

      effect_run =
        base
        |> boundary_run("effect-run", 5)
        |> Map.put(:metadata, %{
          effect_terminal: %{
            invocation_id: "effect-invocation",
            effect_id: "effect-one",
            kind: :effect_terminal,
            idempotency_key: "effect-key"
          }
        })

      effect =
        boundary_envelope(
          base,
          :effect_terminal,
          effect_run,
          %{invocation_id: "effect-invocation"},
          payload: %{effect: %{id: "effect-one"}, idempotency_key: "effect-key"}
        )

      assert_required_delivery_accepted(base, effect_run, effect)
      assert_required_delivery_rejected(base, %{effect_run | metadata: %{}}, effect)

      definition_ref = Run.definition_ref(@agent)

      lifecycle =
        Lifecycle.new!(
          definition_ref: definition_ref,
          admission: :draining,
          revision: 6,
          authority_epoch: 2,
          changed_at: 6
        )

      authority =
        boundary_envelope(
          base,
          :authority_decision,
          nil,
          %{definition_ref: to_string(definition_ref)},
          payload: %{
            axis: :admission,
            to: :draining,
            lifecycle_revision: 6,
            authority_epoch: 2
          }
        )

      lifecycles = %{to_string(definition_ref) => lifecycle}
      assert_required_delivery_accepted(base, nil, authority, lifecycles: lifecycles)

      rejected_authority = %{authority | payload: %{authority.payload | to: :closed}}

      # Changing a payload changes both the receipt identity and its outbox
      # digest, so construct a fresh envelope rather than forging the receipt.
      rejected_authority =
        rejected_authority
        |> Map.from_struct()
        |> Map.put(:id, nil)
        |> Map.put(:payload_digest, nil)
        |> Envelope.new!()

      assert_required_delivery_rejected(base, nil, rejected_authority, lifecycles: lifecycles)
    end
  end

  defp instance_state(overrides \\ []) do
    agent_ref = AgentRef.new(@agent)
    subject = Subject.new("receipt-edge-#{System.unique_integer([:positive, :monotonic])}")
    ref = InstanceRef.new(agent_ref, subject)
    state = %State{conversation_id: ref.key}

    {:ok, canonical} =
      Canonical.new(%{
        flow: state,
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}}
      })

    lease =
      Lease.new!(
        owner_id: "receipt-edge-owner",
        fencing_token: 1,
        issued_at: 0,
        metadata: %{instance_key: ref.key, scope: :single_owner_local}
      )

    defaults = %{
      agent: @agent,
      agent_ref: agent_ref,
      subject: subject,
      ref: ref,
      state: state,
      canonical: canonical,
      activation: nil,
      owner: {Spectre.Instance.Owner.Local, []},
      owner_lease: lease,
      base_opts: [],
      idle_timeout: false,
      max_runs: 16,
      max_tombstones: 16,
      max_operation_runners: 1,
      generation: "receipt-edge-generation",
      checkpoint_mode: :manual,
      checkpoint_revision: 0,
      receipt_mode: :observational,
      max_receipt_outbox: 4
    }

    struct!(InstanceState, Map.merge(defaults, Map.new(overrides)))
  end

  defp prepared(data, writes, opts \\ []) do
    receipt_opts =
      [
        correlation_id: "receipt-edge-correlation",
        payload_schema_ref: "spectre.test/receipt-edge/1"
      ]
      |> Keyword.merge(opts)

    assert {:ok, prepared} =
             Receipts.prepare_sections(
               data,
               writes,
               :nondeterminism_sample,
               %{boundary: :tested},
               receipt_opts
             )

    prepared
  end

  defp envelope(opts) do
    Envelope.new!(
      kind: :nondeterminism_sample,
      correlation_id: Keyword.get(opts, :correlation_id, "canonical-receipt"),
      canonical_revision: Keyword.fetch!(opts, :canonical_revision),
      pre_state_digest: hex_digest("1"),
      post_state_digest: hex_digest("2"),
      payload_schema_ref: "spectre.test/canonical-receipt/1",
      payload: %{sample: 1},
      recorded_at: Keyword.get(opts, :recorded_at, 1)
    )
  end

  defp required_delivery_fixture do
    data =
      instance_state(
        receipt_mode: :required,
        max_receipt_outbox: 4,
        checkpoint_revision: 1_000
      )

    prepared = prepared(data, %{flow: %{data.state | revision: 1}})
    payload_ref = Sink.payload_ref(prepared.envelope)
    assert {:ok, committed, receipt} = Receipts.commit(data, prepared, :required, payload_ref)
    assert {:ok, %{entries: [entry]}} = Canonical.fetch(committed.canonical, :receipt_outbox)
    {%{committed | checkpoint_revision: 1_000}, entry, receipt}
  end

  defp receipt_staging(prepared, tag) do
    %{
      token: "staging-#{System.unique_integer([:positive, :monotonic])}",
      pid: self(),
      monitor: make_ref(),
      run: nil,
      resume: {:authority_decision, {self(), tag}, :ignored},
      prepared: prepared,
      attempt: 0
    }
  end

  defp inference_receipt_fences do
    %{
      inference_id: "receipt-inference",
      invocation_id: "receipt-invocation",
      attempt_id: "receipt-attempt",
      control_revision: 1,
      stream_epoch: "receipt-epoch"
    }
  end

  defp boundary_run(data, id, revision) do
    %{Run.new(@agent, Input.new(id), data.state, run_id: id) | revision: revision}
  end

  defp boundary_envelope(data, kind, run, fences, opts) do
    definition_ref =
      Keyword.get_lazy(opts, :definition_ref, fn ->
        run
        |> case do
          %Run{} = owned -> owned.definition_ref
          nil -> Run.definition_ref(@agent)
        end
        |> to_string()
      end)

    attrs =
      %{
        kind: kind,
        instance_ref: data.ref.key,
        run_id: run && run.id,
        run_revision: run && run.revision,
        canonical_revision: 1,
        correlation_id: "boundary-#{kind}",
        definition_ref: definition_ref,
        pre_state_digest: hex_digest("a"),
        post_state_digest: hex_digest("b"),
        payload_schema_ref: "spectre.test/boundary/1",
        payload: Keyword.fetch!(opts, :payload),
        privacy: :internal,
        recorded_at: 1
      }
      |> Map.merge(Map.new(fences))

    Envelope.new!(attrs)
  end

  defp assert_required_delivery_accepted(base, run, envelope, opts \\ []) do
    {data, entry} = required_delivery_state(base, run, envelope, opts)

    assert {:noreply, delivered} =
             Instance.handle_info(
               {:spectre, :receipt_delivery_result, entry.id, {:ok, :appended, envelope}},
               data
             )

    refute Map.has_key?(delivered.receipt_retry_timers, entry.id)
    assert {:ok, %{entries: entries}} = Canonical.fetch(delivered.canonical, :receipt_outbox)
    refute Enum.any?(entries, &(&1.id == entry.id))
  end

  defp assert_required_delivery_rejected(base, run, envelope, opts \\ []) do
    {data, entry} = required_delivery_state(base, run, envelope, opts)

    assert {:noreply, rejected} =
             Instance.handle_info(
               {:spectre, :receipt_delivery_result, entry.id, {:ok, :appended, envelope}},
               data
             )

    assert Map.has_key?(rejected.receipt_retry_timers, entry.id)
    cancel_retry_timers(rejected)
  end

  defp required_delivery_state(base, run, envelope, opts) do
    data = %{base | canonical: %{base.canonical | revision: 1}}

    data =
      case Keyword.get(opts, :lifecycles) do
        nil -> data
        lifecycles -> put_section(data, :lifecycles, lifecycles)
      end

    entry = OutboxEntry.new(envelope, Sink.payload_ref(envelope), 1)

    dummy =
      Envelope.new!(
        kind: :nondeterminism_sample,
        instance_ref: data.ref.key,
        canonical_revision: 1,
        correlation_id: "dummy-#{entry.id}",
        pre_state_digest: hex_digest("c"),
        post_state_digest: hex_digest("d"),
        payload_schema_ref: "spectre.test/dummy/1",
        payload: %{target_receipt_id: entry.id},
        privacy: :internal,
        recorded_at: 1
      )

    dummy_entry = OutboxEntry.new(dummy, Sink.payload_ref(dummy), 1)

    outbox = %{
      entries: [entry, dummy_entry],
      ids: %{entry.id => entry.digest, dummy_entry.id => dummy_entry.digest}
    }

    data = put_section(data, :receipt_outbox, outbox)

    delivery = %{
      id: entry.id,
      pid: self(),
      monitor: make_ref(),
      mode: :required,
      entry: entry
    }

    runs = if run, do: %{run.id => run}, else: %{}

    data = %{
      data
      | runs: runs,
        receipt_recovery_deferred: true,
        receipt_deliveries: %{entry.id => delivery}
    }

    {data, entry}
  end

  defp cancel_retry_timers(data) do
    Enum.each(data.receipt_retry_timers, fn {_id, timer} ->
      Process.cancel_timer(timer)
    end)
  end

  defp command(status) do
    command =
      Command.new("inference", :steer,
        id: "command-#{status}",
        correlation_id: "control-correlation",
        base_revision: 0,
        requested_at: 1,
        provenance: %{source: :test}
      )

    case status do
      :pending -> command
      :committed -> %{command | status: :committed, committed_at: 2}
      :applied -> %{command | status: :applied, committed_at: 2, completed_at: 3}
    end
  end

  defp progress(opts) do
    Progress.new(
      inference_id: "inference",
      invocation_id: "invocation",
      attempt_id: "attempt",
      run_revision: 0,
      generation: "generation",
      dispatch_id: "dispatch",
      control_revision: 0,
      stream_epoch: "epoch",
      sequence: 1,
      state: :streaming,
      at: 1,
      canonical_revision: Keyword.get(opts, :canonical_revision)
    )
  end

  defp put_section(%InstanceState{} = data, name, value) do
    %{data | canonical: put_section(data.canonical, name, value)}
  end

  defp put_section(%Canonical{} = canonical, name, value) do
    {:ok, %Section{} = current} = Sections.fetch(canonical.sections, name)
    section = %{current | value: value}
    %{canonical | sections: Sections.put(canonical.sections, name, section)}
  end

  defp validate(data, opts \\ []), do: Validator.validate(data.canonical, data.ref, opts)
  defp hex_digest(character), do: String.duplicate(character, 64)
end
