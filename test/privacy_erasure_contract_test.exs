defmodule SpectrePrivacyErasureContractTest.CheckpointStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  alias Spectre.Foundation.Conformance
  alias Spectre.Instance.Erasure.Status

  def seed(server, ref, checkpoint) do
    {:ok, report} = Conformance.verify_instance_checkpoint(checkpoint, ref)
    Agent.update(server, &Map.put(&1, ref.key, {:checkpoint, report.revision, checkpoint}))
  end

  def entry(server, ref), do: Agent.get(server, &Map.get(&1, ref.key))

  @impl true
  def load(ref, opts) do
    case entry(Keyword.fetch!(opts, :server), ref) do
      {:checkpoint, _revision, checkpoint} -> {:ok, checkpoint}
      {:erased, _status} -> :not_found
      nil -> :not_found
    end
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case Map.get(entries, ref.key) do
        nil when expected == 0 ->
          {:ok, Map.put(entries, ref.key, {:checkpoint, revision, checkpoint})}

        {:checkpoint, ^expected, _current} ->
          {:ok, Map.put(entries, ref.key, {:checkpoint, revision, checkpoint})}

        {:erased, _status} ->
          {{:error, :instance_erased}, entries}

        _other ->
          {{:error, :checkpoint_conflict}, entries}
      end
    end)
  end

  @impl true
  def erase(ref, request, opts) do
    notify(opts, {:checkpoint_erased, ref.key})
    server = Keyword.fetch!(opts, :server)

    Agent.get_and_update(server, fn entries ->
      case Map.get(entries, ref.key) do
        {:erased, _status} ->
          {{:ok, :already_erased}, entries}

        nil when is_nil(request.expected_revision) and is_nil(request.checkpoint_digest) ->
          mark_erased(entries, ref, request)

        {:checkpoint, revision, checkpoint} ->
          erase_checkpoint(entries, ref, request, revision, checkpoint)

        _other ->
          {{:error, :checkpoint_identity_mismatch}, entries}
      end
    end)
  end

  @impl true
  def erasure_status(ref, opts) do
    case entry(Keyword.fetch!(opts, :server), ref) do
      {:erased, status} -> {:ok, status}
      _other -> :not_erased
    end
  end

  defp erase_checkpoint(entries, ref, request, revision, checkpoint) do
    {:ok, report} = Conformance.verify_instance_checkpoint(checkpoint)

    if revision == request.expected_revision and report.digest == request.checkpoint_digest,
      do: mark_erased(entries, ref, request),
      else: {{:error, :checkpoint_identity_mismatch}, entries}
  end

  defp mark_erased(entries, ref, request) do
    {:ok, status} = Status.from_request(request, request.requested_at)
    {{:ok, :erased}, Map.put(entries, ref.key, {:erased, status})}
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :audit_pid), do: send(pid, message)
  end
end

defmodule SpectrePrivacyErasureContractTest.JournalStore do
  @moduledoc false

  @behaviour Spectre.Journal.Store

  def seed(server, ref), do: Agent.update(server, &MapSet.put(&1, ref.key))
  def present?(server, ref), do: Agent.get(server, &MapSet.member?(&1, ref.key))

  @impl true
  def append(_record, _opts), do: :ok

  @impl true
  def erase_instance(ref, opts) do
    if pid = Keyword.get(opts, :audit_pid), do: send(pid, {:journal_erased, ref.key})

    case Keyword.get(opts, :erase_reply) do
      nil -> erase_stored(ref, opts)
      :raise -> raise "journal erasure failed"
      :throw -> throw(:journal_erasure_failed)
      {:fail_ref, key, reason} when key == ref.key -> {:error, reason}
      {:fail_ref, _key, _reason} -> erase_stored(ref, opts)
      reply -> reply
    end
  end

  defp erase_stored(ref, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      if MapSet.member?(entries, ref.key),
        do: {{:ok, :erased}, MapSet.delete(entries, ref.key)},
        else: {{:ok, :already_erased}, entries}
    end)
  end
end

defmodule SpectrePrivacyErasureContractTest.ReceiptSink do
  @moduledoc false

  @behaviour Spectre.Receipt.Sink

  alias Spectre.Receipt.Sink.Memory

  @impl true
  defdelegate append(envelope, opts), to: Memory

  @impl true
  defdelegate lookup(id, opts), to: Memory

  @impl true
  defdelegate put_payload(envelope, opts), to: Memory

  @impl true
  defdelegate get_payload(ref, opts), to: Memory

  @impl true
  def delete_payload(ref, opts) do
    if pid = Keyword.get(opts, :audit_pid), do: send(pid, {:receipt_payload_erased, ref})

    case Keyword.get(opts, :delete_reply) do
      nil -> Memory.delete_payload(ref, opts)
      :raise -> raise "receipt payload deletion failed"
      :throw -> throw(:receipt_payload_deletion_failed)
      reply -> reply
    end
  end
end

defmodule SpectrePrivacyErasureContractTest.UnsupportedJournal do
  @moduledoc false
  @behaviour Spectre.Journal.Store
  @impl true
  def append(_record, _opts), do: raise("must remain read-only")
end

defmodule SpectrePrivacyErasureContractTest.UnsupportedReceiptSink do
  @moduledoc false
  @behaviour Spectre.Receipt.Sink
  def append(_envelope, _opts), do: raise("must remain read-only")
  def lookup(_id, _opts), do: raise("must remain read-only")
end

defmodule SpectrePrivacyErasureContractTest.MissingValidationOwner do
  @moduledoc false

  def claim_maintenance(_ref, :erasure, _opts),
    do: raise("capability preflight must not claim ownership")
end

defmodule SpectrePrivacyErasureContractTest.AgentDefinition do
  @moduledoc false
  use Spectre.Agent, id: :privacy_erasure_contract_agent
end

defmodule SpectrePrivacyErasureContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Erasure.Proof
  alias Spectre.Instance.Ref
  alias Spectre.Privacy
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.OutboxEntry
  alias Spectre.Receipt.Sink
  alias Spectre.Receipt.Sink.Memory

  alias SpectrePrivacyErasureContractTest.AgentDefinition
  alias SpectrePrivacyErasureContractTest.CheckpointStore
  alias SpectrePrivacyErasureContractTest.JournalStore
  alias SpectrePrivacyErasureContractTest.MissingValidationOwner
  alias SpectrePrivacyErasureContractTest.ReceiptSink, as: LifecycleReceiptSink
  alias SpectrePrivacyErasureContractTest.UnsupportedJournal
  alias SpectrePrivacyErasureContractTest.UnsupportedReceiptSink

  setup do
    checkpoint_server =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> %{} end}, id: :privacy_checkpoint_server)
      )

    journal_server =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> MapSet.new() end}, id: :privacy_journal_server)
      )

    receipt_server = start_supervised!({Memory, []})

    %{
      checkpoint: {CheckpointStore, server: checkpoint_server},
      checkpoint_server: checkpoint_server,
      journal: {JournalStore, server: journal_server},
      journal_server: journal_server,
      receipt: {LifecycleReceiptSink, server: receipt_server},
      receipt_server: receipt_server
    }
  end

  test "the read-only plan and coordinator cover configured data in the promised order",
       context do
    ref = fresh_ref("complete")
    {:ok, legacy_ref} = Ref.legacy(ref)
    {checkpoint, envelope, payload_ref} = checkpoint_with_payload(ref)
    CheckpointStore.seed(context.checkpoint_server, ref, checkpoint)
    JournalStore.seed(context.journal_server, ref)
    {:ok, ^payload_ref} = Sink.put_payload(context.receipt, envelope, [])

    opts = [
      checkpoint_store: context.checkpoint,
      journal: context.journal,
      receipt_sink: context.receipt
    ]

    assert {:ok,
            %Spectre.Privacy.ErasurePlan{
              ready: true,
              order: [:journal, :receipt_payloads, :checkpoint],
              components: %{
                owner: %{status: :ready},
                journal: %{status: :ready},
                receipt_payloads: %{status: :ready},
                checkpoint: %{status: :ready}
              }
            }} = Privacy.erasure_plan(ref, ref.subject, opts)

    assert JournalStore.present?(context.journal_server, ref)
    assert {:ok, ^envelope} = Sink.get_payload(context.receipt, payload_ref, [])
    assert {:checkpoint, 0, ^checkpoint} = CheckpointStore.entry(context.checkpoint_server, ref)

    assert {:ok,
            %Proof{
              scope: :configured_instance_data,
              outcome: :erased,
              components: %{
                journal: %{outcome: :erased, key_count: 2},
                receipt_payloads: %{
                  outcome: :erased,
                  payload_count: 1,
                  deleted_count: 1,
                  not_found_count: 0
                },
                checkpoint: %{outcome: :erased, key_count: 2}
              }
            }} =
             Spectre.erase_instance(
               ref,
               ref.subject,
               opts ++ [confirm: ref.key, opts: [audit_pid: self()], now: 10]
             )

    assert_receive {:journal_erased, stable_key}
    assert stable_key == ref.key
    assert_receive {:journal_erased, legacy_key}
    assert legacy_key == legacy_ref.key
    assert_receive {:receipt_payload_erased, ^payload_ref}
    assert_receive {:checkpoint_erased, ^stable_key}
    assert_receive {:checkpoint_erased, ^legacy_key}

    refute JournalStore.present?(context.journal_server, ref)
    assert :not_found = Sink.get_payload(context.receipt, payload_ref, [])
    assert :not_found = Spectre.Instance.CheckpointStore.load(context.checkpoint, ref, [])
  end

  test "preflight reports unsupported adapters without invoking or mutating them", context do
    ref = fresh_ref("preflight")
    checkpoint = checkpoint(ref)
    CheckpointStore.seed(context.checkpoint_server, ref, checkpoint)

    assert {:ok, plan} =
             Privacy.erasure_plan(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               journal: UnsupportedJournal,
               receipt_sink: UnsupportedReceiptSink
             )

    refute plan.ready
    assert plan.components.journal.status == :unsupported
    assert plan.components.receipt_payloads.status == :unsupported

    assert {:error, {:journal_store_erasure_unsupported, UnsupportedJournal}} =
             Spectre.erase_instance(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               journal: UnsupportedJournal,
               confirm: ref.key
             )

    assert {:checkpoint, 0, ^checkpoint} = CheckpointStore.entry(context.checkpoint_server, ref)

    assert {:ok, owner_plan} =
             Privacy.erasure_plan(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               owner: MissingValidationOwner
             )

    refute owner_plan.ready
    assert owner_plan.components.owner.status == :unsupported

    assert {:error, {:instance_owner_callback_missing, MissingValidationOwner, :validate, 3}} =
             Spectre.erase_instance(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               owner: MissingValidationOwner,
               confirm: ref.key
             )

    assert {:checkpoint, 0, ^checkpoint} = CheckpointStore.entry(context.checkpoint_server, ref)
  end

  test "a payload failure retries cleanly after the sink recovers",
       context do
    ref = fresh_ref("partial")
    {checkpoint, envelope, payload_ref} = checkpoint_with_payload(ref)
    CheckpointStore.seed(context.checkpoint_server, ref, checkpoint)
    JournalStore.seed(context.journal_server, ref)
    {:ok, ^payload_ref} = Sink.put_payload(context.receipt, envelope, [])

    assert {:error,
            {:ambiguous,
             {:instance_erasure_partial, [:journal],
              {:receipt_payload_erase_failed, 0, {:receipt_sink_error, :offline}}}}} =
             Spectre.erase_instance(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               journal: context.journal,
               receipt_sink:
                 {LifecycleReceiptSink,
                  server: context.receipt_server, delete_reply: {:error, :offline}},
               confirm: ref.key
             )

    refute JournalStore.present?(context.journal_server, ref)
    assert {:ok, ^envelope} = Sink.get_payload(context.receipt, payload_ref, [])
    assert {:checkpoint, 0, ^checkpoint} = CheckpointStore.entry(context.checkpoint_server, ref)

    assert {:ok,
            %Proof{
              outcome: :erased,
              components: %{
                journal: %{outcome: :already_erased, key_count: 2},
                receipt_payloads: %{
                  outcome: :erased,
                  payload_count: 1,
                  deleted_count: 1,
                  not_found_count: 0
                },
                checkpoint: %{outcome: :erased, key_count: 2}
              }
            }} =
             Spectre.erase_instance(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               journal: context.journal,
               receipt_sink: context.receipt,
               confirm: ref.key
             )

    assert :not_found = Sink.get_payload(context.receipt, payload_ref, [])
    assert :not_found = Spectre.Instance.CheckpointStore.load(context.checkpoint, ref, [])

    assert {:ok,
            %Proof{
              outcome: :already_erased,
              components: %{
                receipt_payloads: %{
                  outcome: :not_applicable,
                  payload_count: 0,
                  deleted_count: 0,
                  not_found_count: 0
                }
              }
            }} =
             Spectre.erase_instance(ref, ref.subject,
               checkpoint_store: context.checkpoint,
               journal: context.journal,
               receipt_sink: context.receipt,
               confirm: ref.key
             )
  end

  test "journal failures distinguish no mutation from a partial stable-ref erase", context do
    failed_ref = fresh_ref("journal-first-failure")
    failed_checkpoint = checkpoint(failed_ref)
    CheckpointStore.seed(context.checkpoint_server, failed_ref, failed_checkpoint)
    JournalStore.seed(context.journal_server, failed_ref)

    assert {:error, {:instance_journal_erase_failed, :offline}} =
             Spectre.erase_instance(failed_ref, failed_ref.subject,
               checkpoint_store: context.checkpoint,
               journal:
                 {JournalStore, server: context.journal_server, erase_reply: {:error, :offline}},
               confirm: failed_ref.key
             )

    assert JournalStore.present?(context.journal_server, failed_ref)

    assert {:checkpoint, 0, ^failed_checkpoint} =
             CheckpointStore.entry(context.checkpoint_server, failed_ref)

    partial_ref = fresh_ref("journal-partial-failure")
    {:ok, legacy_ref} = Ref.legacy(partial_ref)
    partial_checkpoint = checkpoint(partial_ref)
    CheckpointStore.seed(context.checkpoint_server, partial_ref, partial_checkpoint)
    JournalStore.seed(context.journal_server, partial_ref)
    JournalStore.seed(context.journal_server, legacy_ref)

    assert {:error,
            {:ambiguous,
             {:instance_erasure_partial, [:journal],
              {:instance_journal_erase_failed, 1, :offline}}}} =
             Spectre.erase_instance(partial_ref, partial_ref.subject,
               checkpoint_store: context.checkpoint,
               journal:
                 {JournalStore,
                  server: context.journal_server,
                  erase_reply: {:fail_ref, legacy_ref.key, :offline}},
               confirm: partial_ref.key
             )

    refute JournalStore.present?(context.journal_server, partial_ref)
    assert JournalStore.present?(context.journal_server, legacy_ref)

    assert {:checkpoint, 0, ^partial_checkpoint} =
             CheckpointStore.entry(context.checkpoint_server, partial_ref)
  end

  test "journal and receipt erasure wrappers keep failures typed and bounded", context do
    ref = fresh_ref("wrappers")
    journal_server = context.journal_server

    assert {:ok, nil} = Spectre.Journal.Store.normalize(false)
    assert {:ok, {JournalStore, []}} = Spectre.Journal.Store.normalize(JournalStore)

    assert {:ok, {JournalStore, [server: ^journal_server]}} =
             Spectre.Journal.Store.normalize(
               store: JournalStore,
               server: context.journal_server
             )

    assert {:error, :invalid_journal_store} =
             Spectre.Journal.Store.normalize(server: context.journal_server)

    assert {:error, :invalid_journal_store} = Spectre.Journal.Store.normalize({nil, []})

    assert {:error, {:invalid_journal_store, :options}} =
             Spectre.Journal.Store.normalize([:not_keyword])

    assert {:error, :invalid_journal_store} = Spectre.Journal.Store.normalize(%{})

    assert {:error, {:journal_store_not_loaded, MissingJournalStore}} =
             Spectre.Journal.Store.erasure_capability({MissingJournalStore, []})

    assert {:error, {:journal_store_erasure_unsupported, UnsupportedJournal}} =
             Spectre.Journal.Store.erasure_capability({UnsupportedJournal, []})

    assert {:ok, :not_configured} =
             Spectre.Journal.Store.erase_instance(nil, ref, [])

    assert {:error, :offline} =
             Spectre.Journal.Store.erase_instance(
               {JournalStore, server: context.journal_server, erase_reply: {:error, :offline}},
               ref,
               []
             )

    for reply <- [:invalid, :raise, :throw] do
      assert {:error, {:ambiguous, _reason}} =
               Spectre.Journal.Store.erase_instance(
                 {JournalStore, server: context.journal_server, erase_reply: reply},
                 ref,
                 []
               )
    end

    assert {:ok, :not_configured} = Sink.delete_payload(nil, "receipt-payload:none", [])

    assert {:error, {:receipt_sink_error, :invalid_receipt_payload_ref}} =
             Sink.delete_payload(context.receipt, "", [])

    for reply <- [:invalid, :raise, :throw] do
      assert {:error, {:ambiguous, _reason}} =
               Sink.delete_payload(
                 {LifecycleReceiptSink, server: context.receipt_server, delete_reply: reply},
                 "receipt-payload:none",
                 []
               )
    end

    assert {:error, :invalid_privacy_erasure_options} =
             Privacy.erasure_plan(ref, ref.subject, [:invalid])

    assert {:error, :privacy_erasure_subject_mismatch} =
             Privacy.erasure_plan(ref, "different-subject")
  end

  test "the privacy plan covers identity forms and invalid read-only configuration" do
    subject = "privacy-plan-identities"
    missing_owner = Module.concat(__MODULE__, MissingOwner)

    assert {:ok, module_plan} =
             Privacy.erasure_plan(AgentDefinition, subject, checkpoint_store: false)

    refute module_plan.ready
    assert module_plan.components.checkpoint == %{configured: false, status: :required}

    agent_ref = Spectre.AgentRef.new(AgentDefinition)

    assert {:ok, agent_ref_plan} =
             Privacy.erasure_plan(agent_ref, subject, checkpoint_store: false)

    assert agent_ref_plan.instance_key == module_plan.instance_key

    assert {:ok, unavailable} =
             Privacy.erasure_plan(AgentDefinition, subject,
               checkpoint_store: MissingCheckpointStore,
               owner: missing_owner,
               journal: MissingJournalStore,
               receipt_sink: MissingReceiptSink
             )

    refute unavailable.ready
    assert unavailable.components.checkpoint.status == :unavailable
    assert unavailable.components.owner.status == :unavailable
    assert unavailable.components.journal.status == :unavailable
    assert unavailable.components.receipt_payloads.status == :unavailable

    assert {:error, {:invalid_privacy_erasure_option, :opts}} =
             Privacy.erasure_plan(AgentDefinition, subject, opts: :invalid)

    assert {:error, :invalid_privacy_erasure_options} =
             Privacy.erasure_plan(AgentDefinition, subject, %{})

    assert {:error, :invalid_privacy_erasure_identity} =
             Privacy.erasure_plan(%{}, subject)

    assert {:error, :invalid_privacy_erasure_identity} =
             Privacy.erasure_plan(AgentDefinition, %Spectre.Subject{id: ""})
  end

  defp fresh_ref(label) do
    Ref.new(AgentDefinition, "privacy-erasure-#{label}-#{System.unique_integer([:positive])}")
  end

  defp checkpoint_with_payload(ref) do
    envelope =
      Envelope.new!(
        kind: :nondeterminism_sample,
        instance_ref: ref.key,
        correlation_id: "privacy-erasure",
        payload_schema_ref: "spectre.test/privacy-erasure/1",
        payload: %{value: "personal"},
        privacy: :confidential,
        recorded_at: 1
      )

    payload_ref = Sink.payload_ref(envelope)
    entry = OutboxEntry.new(envelope, payload_ref, 0)
    {checkpoint(ref, entry), envelope, payload_ref}
  end

  defp checkpoint(ref, entry \\ nil) do
    receipt_outbox =
      if entry,
        do: %{entries: [entry], ids: %{entry.id => entry.digest}},
        else: %{entries: [], ids: %{}}

    {:ok, canonical} =
      Canonical.new(%{
        flow: %Spectre.State{conversation_id: ref.key},
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}},
        receipt_outbox: receipt_outbox
      })

    {:ok, encoded} = Codec.encode_json(canonical)
    encoded
  end
end
