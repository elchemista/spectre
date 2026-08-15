defmodule SpectreEventLifecycleSemanticsTest.Renderer do
  @moduledoc false

  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreEventLifecycleSemanticsTest.Actions do
  @moduledoc false

  def work(_arguments, context) do
    if pid = Keyword.get(context.opts, :test_pid), do: send(pid, :revoked_work_dispatched)
    {:ok, "worked"}
  end
end

defmodule SpectreEventLifecycleSemanticsTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :event_lifecycle_agent

  actions SpectreEventLifecycleSemanticsTest.Actions do
    protect(:work, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :events do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreEventLifecycleSemanticsTest.Renderer, :render})
    end

    on :WORK, regex: ~r/^work$/i do
      action(:work,
        reply: :approval,
        renderer: {SpectreEventLifecycleSemanticsTest.Renderer, :render}
      )
    end
  end
end

defmodule SpectreEventLifecycleSemanticsTest.CheckpointStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, ref.key) do
        {:ok, {_revision, checkpoint}} -> {:ok, checkpoint}
        :error -> :not_found
      end
    end)
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case Map.get(entries, ref.key) do
        nil when expected == 0 -> {:ok, Map.put(entries, ref.key, {revision, checkpoint})}
        {^expected, _current} -> {:ok, Map.put(entries, ref.key, {revision, checkpoint})}
        {actual, _current} -> {{:error, {:stale, expected, actual}}, entries}
        nil -> {{:error, {:stale, expected, :not_found}}, entries}
      end
    end)
  end

  @impl true
  def migrate_instance_key(legacy_ref, stable_ref, legacy, migrated, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case {Map.get(entries, legacy_ref.key), Map.get(entries, stable_ref.key)} do
        {{_revision, ^legacy}, nil} ->
          revision = migrated |> Jason.decode!() |> Map.fetch!("revision")

          next =
            entries |> Map.delete(legacy_ref.key) |> Map.put(stable_ref.key, {revision, migrated})

          {{:ok, :moved}, next}

        {_legacy, {_revision, ^migrated}} ->
          {{:ok, :aliased}, entries}

        {_legacy, _stable} ->
          {{:error, :migration_conflict}, entries}
      end
    end)
  end
end

defmodule SpectreEventLifecycleSemanticsTest.SchemaRegistry do
  @moduledoc false
  @behaviour Spectre.Event.SchemaRegistry

  @impl true
  def compatible?(definition_ref, envelope, opts) do
    case Keyword.get(opts, :mode) do
      :invalid_reply -> :invalid_reply
      :raise -> raise "schema registry failure"
      :throw -> throw(:schema_registry_failure)
      _mode -> compatible_payload?(definition_ref, envelope, opts)
    end
  end

  defp compatible_payload?(definition_ref, envelope, opts) do
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:schema_checked, definition_ref, envelope.id})
    end

    if envelope.payload_schema_ref == "spectre.test/global/1" and
         envelope.payload == %{"version" => 1},
       do: :ok,
       else: {:error, :global_schema_mismatch}
  end
end

defmodule SpectreEventLifecycleSemanticsTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope, as: AuthorityEnvelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Event.Envelope
  alias Spectre.Execution.Closure
  alias Spectre.Instance
  alias Spectre.Instance.Lifecycle
  alias Spectre.Run.Ref, as: RunRef
  alias Spectre.Subject
  alias Spectre.Turn

  alias SpectreEventLifecycleSemanticsTest.Agent
  alias SpectreEventLifecycleSemanticsTest.CheckpointStore
  alias SpectreEventLifecycleSemanticsTest.SchemaRegistry

  @digest String.duplicate("c", 64)

  test "Event Envelope round-trips its continuation and admission receipt" do
    {:ok, definition_ref} = Spectre.Definition.Ref.parse("sha256:" <> @digest)

    pending =
      Envelope.new!(
        id: "event-envelope-roundtrip",
        event_class: :policy_answer,
        correlation_id: "correlation-roundtrip",
        continuation_ref: %RunRef{
          run_id: "run-roundtrip",
          revision: 4,
          kind: :policy,
          boundary_id: "boundary-roundtrip",
          subject_id: nil
        },
        origin_definition_ref: definition_ref,
        payload_schema_ref: "spectre.test/policy-answer/1",
        payload: %{"answer" => "yes"},
        provenance: %{"transport" => "test"},
        authenticity: %{"authenticated" => true},
        emitted_at: 10
      )

    assert pending.status == :pending
    refute Envelope.admitted?(pending)

    assert {:ok, admitted} =
             Envelope.admit(pending,
               owner_definition_ref: definition_ref,
               admitted_activation_generation: 2,
               authority_epoch: 7,
               owner_fencing_token: 11,
               admission_revision: 13,
               status: :admitted,
               admitted_at: 12
             )

    assert Envelope.admitted?(admitted)
    assert is_binary(admitted.admission_receipt)
    assert {:ok, encoded} = Envelope.encode(admitted)
    assert {:ok, ^admitted} = Envelope.decode(encoded)
    assert {:ok, ^admitted} = admitted |> Envelope.to_data() |> Envelope.from_data()
  end

  test "continuation ownership wins over origin and the current activation" do
    store = definition_store()
    {definition_a, candidate_a, definition_b, candidate_b} = publish_lineage(store)
    instance = start_instance(store, "event-owner")

    assert {:ok, _activation_a} = Spectre.activate(instance, candidate_a, expected_generation: 0)

    assert {:ok, %Turn{observable: {:needs, _request}} = needs} =
             Spectre.turn(instance, "work")

    assert {:ok, activation_b} =
             Spectre.activate(instance, candidate_b, expected_generation: 1)

    assert {:ok, owned} =
             Spectre.admit_event(instance,
               id: "event-owned-by-a",
               event_class: :policy_answer,
               correlation_id: "policy-answer-a",
               continuation_ref: needs.ref,
               origin_definition_ref: definition_b,
               payload_schema_ref: "spectre.test/policy-answer/1",
               payload: %{"answer" => "yes"},
               emitted_at: 20
             )

    assert owned.status == :admitted
    assert owned.owner_definition_ref == definition_a
    assert owned.origin_definition_ref == definition_b
    assert owned.admitted_activation_generation == activation_b.generation

    assert {:ok, unowned_input} =
             Spectre.admit_event(instance,
               id: "event-owned-by-b",
               event_class: :input,
               correlation_id: "new-input-b",
               origin_definition_ref: definition_a,
               payload_schema_ref: "spectre.test/input/1",
               payload: %{"text" => "hello"},
               emitted_at: 21
             )

    assert unowned_input.owner_definition_ref == definition_b
    assert unowned_input.origin_definition_ref == definition_a

    assert Enum.map(Spectre.admitted_events(instance), & &1.id) == [
             "event-owned-by-b",
             "event-owned-by-a"
           ]
  end

  test "drain preserves a continuation while revoke blocks its Effect at the current epoch" do
    store = definition_store()
    {definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(store)
    instance = start_instance(store, "drain-revoke")

    assert {:ok, _activation} = Spectre.activate(instance, candidate_a, expected_generation: 0)

    assert {:ok, %Turn{observable: {:needs, _request}}} = Spectre.turn(instance, "work")
    assert {:ok, %Lifecycle{revision: 0}} = Spectre.definition_lifecycle(instance)

    assert {:ok, %Lifecycle{admission: :draining, revision: 1}} =
             Spectre.drain_definition(instance, definition_a,
               expected_revision: 0,
               changed_at: 30
             )

    assert {:error, {:definition_admission_blocked, _, :draining}} =
             Spectre.turn(instance, "hello", origin_conversation_id: "fresh-after-drain")

    assert {:ok, %Turn{observable: {:awaiting, %RunRef{} = execution_ref}}} =
             Spectre.turn(instance, "yes")

    assert {:ok, run_before_revoke} = Instance.run(instance, execution_ref)

    assert {:ok,
            %Lifecycle{
              authority: :revoked,
              authority_epoch: current_epoch,
              revision: 2
            }} =
             Spectre.revoke_definition(instance, definition_a,
               expected_revision: 1,
               changed_at: 31
             )

    assert current_epoch > run_before_revoke.authority_epoch

    assert {:error, {:definition_authority_revoked, _, ^current_epoch, :continuation}} =
             Spectre.resume(instance, execution_ref, {:execute, execution_ref}, test_pid: self())

    refute_received :revoked_work_dispatched
  end

  test "restricted authority blocks new admissions and dispatch while preserving existing commits" do
    store = definition_store()
    {definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(store)
    instance = start_instance(store, "restricted-authority")

    assert {:ok, _activation} = Spectre.activate(instance, candidate_a, expected_generation: 0)
    assert {:ok, %Lifecycle{revision: 0}} = Spectre.definition_lifecycle(instance, definition_a)

    assert {:ok, %Lifecycle{authority: :restricted, authority_epoch: epoch} = restricted} =
             Spectre.transition_definition_lifecycle(
               instance,
               definition_a,
               :authority,
               :restricted,
               expected_revision: 0,
               changed_at: 35
             )

    assert epoch > 0
    assert :ok = Lifecycle.authorize(restricted, :continuation)
    assert :ok = Lifecycle.authorize(restricted, :commit)

    assert {:error, {:definition_authority_restricted, _, ^epoch, :new_admission}} =
             Spectre.turn(instance, "hello", origin_conversation_id: "restricted-new-input")

    assert {:error, {:definition_authority_restricted, _, ^epoch, :dispatch}} =
             Lifecycle.authorize(restricted, :dispatch)
  end

  test "missing and ambiguous continuations are quarantined deterministically" do
    store = definition_store()
    {_definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(store)
    instance = start_instance(store, "event-quarantine")
    assert {:ok, _activation} = Spectre.activate(instance, candidate_a, expected_generation: 0)

    missing_ref = %RunRef{
      run_id: "missing-run",
      revision: 0,
      kind: :policy,
      boundary_id: "missing-boundary",
      subject_id: nil
    }

    assert {:ok, %Envelope{status: :quarantined, quarantine_reason: :continuation_not_found}} =
             Spectre.admit_event(instance,
               id: "missing-continuation",
               event_class: :policy_answer,
               correlation_id: "missing-correlation",
               continuation_ref: missing_ref,
               payload_schema_ref: "spectre.test/policy-answer/1",
               payload: %{"answer" => "yes"},
               emitted_at: 40
             )

    assert {:ok, %Turn{observable: {:needs, _request}}} =
             Spectre.turn(instance, "work",
               correlation_id: "ambiguous-correlation",
               origin_conversation_id: "conversation-one"
             )

    assert {:ok, %Turn{observable: {:needs, _request}}} =
             Spectre.turn(instance, "work",
               correlation_id: "ambiguous-correlation",
               origin_conversation_id: "conversation-two"
             )

    assert {:ok,
            %Envelope{
              status: :quarantined,
              quarantine_reason: {:ambiguous_continuation, candidates}
            }} =
             Spectre.admit_event(instance,
               id: "ambiguous-continuation",
               event_class: :policy_answer,
               correlation_id: "ambiguous-correlation",
               payload_schema_ref: "spectre.test/policy-answer/1",
               payload: %{"answer" => "yes"},
               emitted_at: 41
             )

    assert length(candidates) == 2

    assert Enum.map(Spectre.quarantined_events(instance), & &1.id) == [
             "ambiguous-continuation",
             "missing-continuation"
           ]
  end

  test "global events pass a host schema registry instead of trusting a caller boolean" do
    store = definition_store()
    {_definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(store)
    unconfigured = start_instance(store, "global-without-registry")

    assert {:ok, _activation} =
             Spectre.activate(unconfigured, candidate_a, expected_generation: 0)

    assert {:ok,
            %Envelope{
              status: :quarantined,
              quarantine_reason:
                {:payload_schema_incompatible, :global_event_schema_registry_required}
            }} =
             Spectre.admit_event(
               unconfigured,
               [
                 id: "global-unconfigured",
                 event_class: :global,
                 correlation_id: "global-unconfigured",
                 payload_schema_ref: "spectre.test/global/1",
                 payload: %{"version" => 1},
                 emitted_at: 45
               ],
               schema_compatible?: true
             )

    configured =
      start_instance(store, "global-with-registry",
        event_schema_registry: {SchemaRegistry, test_pid: self()}
      )

    assert {:ok, activation} = Spectre.activate(configured, candidate_a, expected_generation: 0)

    assert {:ok, %Envelope{status: :admitted, owner_definition_ref: owner}} =
             Spectre.admit_event(configured,
               id: "global-compatible",
               event_class: :global,
               correlation_id: "global-compatible",
               payload_schema_ref: "spectre.test/global/1",
               payload: %{"version" => 1},
               emitted_at: 46
             )

    assert owner == activation.definition_ref
    assert_receive {:schema_checked, ^owner, "global-compatible"}

    assert {:ok,
            %Envelope{
              status: :quarantined,
              quarantine_reason: {:payload_schema_incompatible, :global_schema_mismatch}
            }} =
             Spectre.admit_event(configured,
               id: "global-incompatible",
               event_class: :global,
               correlation_id: "global-incompatible",
               payload_schema_ref: "spectre.test/global/1",
               payload: %{"version" => 2},
               emitted_at: 47
             )

    assert {:error, :event_schema_registry_not_loaded} =
             Spectre.Event.SchemaRegistry.verify(String, owner, quarantined_global())

    assert {:error, :invalid_event_schema_registry} =
             Spectre.Event.SchemaRegistry.verify(
               {SchemaRegistry, [1]},
               owner,
               quarantined_global()
             )

    assert {:error, {:invalid_event_schema_registry_reply, SchemaRegistry, :invalid_reply}} =
             Spectre.Event.SchemaRegistry.verify(
               {SchemaRegistry, mode: :invalid_reply},
               owner,
               quarantined_global()
             )

    assert {:error, {:event_schema_registry_exception, SchemaRegistry, RuntimeError}} =
             Spectre.Event.SchemaRegistry.verify(
               {SchemaRegistry, mode: :raise},
               owner,
               quarantined_global()
             )

    assert {:error,
            {:event_schema_registry_failure, SchemaRegistry, :throw, :schema_registry_failure}} =
             Spectre.Event.SchemaRegistry.verify(
               {SchemaRegistry, mode: :throw},
               owner,
               quarantined_global()
             )
  end

  test "event replay identity survives beyond the 512-record inspection window" do
    instance = start_instance(definition_store(), "event-dedup-window")

    receipts =
      Enum.map(1..513, fn index ->
        assert {:ok, %Envelope{status: :admitted, admission_receipt: receipt}} =
                 Spectre.admit_event(instance,
                   id: "window-event-#{index}",
                   event_class: :input,
                   correlation_id: "window-correlation-#{index}",
                   payload_schema_ref: "spectre.test/input/1",
                   payload: %{"text" => "event #{index}"},
                   emitted_at: index
                 )

        receipt
      end)

    assert length(Spectre.admitted_events(instance)) == 512
    refute Enum.any?(Spectre.admitted_events(instance), &(&1.id == "window-event-1"))
    first_receipt = hd(receipts)

    assert {:error,
            {:event_replay_already_committed, "window-event-1", :admitted, ^first_receipt}} =
             Spectre.admit_event(instance,
               id: "window-event-1",
               event_class: :input,
               correlation_id: "window-correlation-1",
               payload_schema_ref: "spectre.test/input/1",
               payload: %{"text" => "event 1"},
               emitted_at: 1
             )

    assert {:error, {:event_id_conflict, "window-event-1"}} =
             Spectre.admit_event(instance,
               id: "window-event-1",
               event_class: :input,
               correlation_id: "window-correlation-1",
               payload_schema_ref: "spectre.test/input/1",
               payload: %{"text" => "tampered"},
               emitted_at: 1
             )
  end

  test "current checkpoint preserves event admission and lifecycle across restart" do
    checkpoint_server = start_agent(%{})
    checkpoint_store = {CheckpointStore, server: checkpoint_server}
    subject = Subject.new("event-checkpoint-#{System.unique_integer([:positive])}")

    {:ok, instance} =
      Instance.start_link(
        agent: Agent,
        subject: subject,
        checkpoint_store: checkpoint_store,
        idle: false
      )

    Process.unlink(instance)

    assert {:ok, %Envelope{status: :admitted}} =
             Spectre.admit_event(instance,
               id: "checkpointed-event",
               event_class: :input,
               correlation_id: "checkpointed-event-correlation",
               payload_schema_ref: "spectre.test/input/1",
               payload: %{"text" => "hello"},
               emitted_at: 50
             )

    assert {:ok, %Lifecycle{admission: :draining}} =
             Spectre.drain_definition(instance, :active, expected_revision: 0, changed_at: 51)

    assert {:ok, _revision} = Spectre.flush_checkpoint(instance)
    :ok = GenServer.stop(instance, :normal)

    {:ok, restarted} =
      Instance.start_link(
        agent: Agent,
        subject: subject,
        checkpoint_store: checkpoint_store,
        idle: false
      )

    Process.unlink(restarted)

    assert [%Envelope{id: "checkpointed-event"}] = Spectre.admitted_events(restarted)
    assert {:ok, %Lifecycle{admission: :draining}} = Spectre.definition_lifecycle(restarted)
    assert {:ok, checkpoint} = Spectre.checkpoint(restarted)

    assert %{
             "format" => "spectre/instance-checkpoint",
             "checkpoint_version" => 3,
             "state_schema_version" => 3
           } = Jason.decode!(checkpoint)

    :ok = GenServer.stop(restarted, :normal)
  end

  defp definition_store do
    id = {:event_lifecycle_store, System.unique_integer([:positive])}
    server = start_supervised!({Spectre.Definition.Store.Memory, id: id})
    {Spectre.Definition.Store.Memory, server: server}
  end

  defp publish_lineage(store) do
    base = Definition.canonical!(Agent)
    definition_a = Canonical.new!(Map.put(Map.from_struct(base), :declared_version, 201))
    definition_b = Canonical.new!(Map.put(Map.from_struct(base), :declared_version, 202))
    closure = closure()
    manifest_a = Manifest.new!(definition_a, AuthorityEnvelope.empty(), closure)

    manifest_b =
      Manifest.new!(definition_b, AuthorityEnvelope.empty(), closure,
        parent_refs: [Canonical.ref(definition_a)]
      )

    assert {:ok, _receipt} = Store.publish(store, definition_a, manifest_a)

    assert {:ok, candidate_a} =
             Resolver.bootstrap_candidate(store, Canonical.ref(definition_a),
               source: :compiled,
               created_at: 1
             )

    assert {:ok, _receipt} = Store.publish(store, definition_b, manifest_b)

    assert {:ok, candidate_b} =
             Resolver.bootstrap_candidate(store, Canonical.ref(definition_b),
               source: :compiled,
               parent_ref: candidate_a,
               created_at: 2
             )

    {Canonical.ref(definition_a), candidate_a, Canonical.ref(definition_b), candidate_b}
  end

  defp closure do
    {:ok, build_digest} = Closure.fingerprint(Agent)

    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/2",
      state_codec_ref: "spectre.instance.canonical.codec/2",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{("beam:" <> Atom.to_string(Agent)) => build_digest},
      evaluation_corpus_digest: nil,
      compatibility_mode: :native_v2
    })
  end

  defp quarantined_global do
    Envelope.new!(
      id: "schema-registry-probe",
      event_class: :global,
      correlation_id: "schema-registry-probe",
      payload_schema_ref: "spectre.test/global/1",
      payload: %{"version" => 1},
      emitted_at: 48
    )
  end

  defp start_instance(store, suffix, opts \\ []) do
    subject = Subject.new("#{suffix}-#{System.unique_integer([:positive])}")

    {:ok, instance} =
      Instance.start_link(
        [agent: Agent, subject: subject, definition_store: store, idle: false]
        |> Keyword.merge(opts)
      )

    Process.unlink(instance)
    on_exit(fn -> if Process.alive?(instance), do: GenServer.stop(instance, :normal) end)
    instance
  end

  defp start_agent(initial) do
    {:ok, server} = Elixir.Agent.start_link(fn -> initial end)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end
end
