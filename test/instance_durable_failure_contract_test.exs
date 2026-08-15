defmodule SpectreInstanceDurableFailureContractTest.Actions do
  @moduledoc false

  def work(_args, _context), do: {:ok, "worked"}
end

defmodule SpectreInstanceDurableFailureContractTest.Renderer do
  @moduledoc false

  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreInstanceDurableFailureContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :instance_durable_failure_contract

  actions SpectreInstanceDurableFailureContractTest.Actions do
    protect(:work, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :durable_failure_contract do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreInstanceDurableFailureContractTest.Renderer, :render})
    end

    on :WORK, regex: ~r/^work$/i do
      action(:work,
        reply: :approval,
        renderer: {SpectreInstanceDurableFailureContractTest.Renderer, :render}
      )
    end
  end
end

defmodule SpectreInstanceDurableFailureContractTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl true
  def append(_record, opts), do: Keyword.get(opts, :reply, :ok)
end

defmodule SpectreInstanceDurableFailureContractTest.DefinitionStore do
  @moduledoc false
  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts), do: Keyword.fetch!(opts, :id)

  @impl true
  def durability(_opts), do: :durable

  @impl true
  def get(key, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn
      %{fault: reason} when not is_nil(reason) ->
        {:error, reason}

      %{entries: entries} ->
        case Map.fetch(entries, key) do
          {:ok, value} -> {:ok, value}
          :error -> :not_found
        end
    end)
  end

  @impl true
  def put(key, encoded, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
      case Map.fetch(state.entries, key) do
        :error -> {{:ok, :created}, put_in(state.entries[key], encoded)}
        {:ok, ^encoded} -> {{:ok, :existing}, state}
        {:ok, _different} -> {{:error, {:immutable_conflict, key}}, state}
      end
    end)
  end
end

defmodule SpectreInstanceDurableFailureContractTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), &pop_load_reply(&1, ref))
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
      case state.write_faults do
        [{:ambiguous_with, stored_revision, stored_checkpoint} | rest] ->
          next =
            state
            |> Map.put(:write_faults, rest)
            |> put_in([:entries, ref.key], {stored_revision, stored_checkpoint})

          {{:error, {:ambiguous, :write_outcome_unknown}}, next}

        [{:error, reason} | rest] ->
          {{:error, reason}, %{state | write_faults: rest}}

        [] ->
          compare_and_swap_entry(state, ref.key, checkpoint, expected, revision)
      end
    end)
  end

  def queue_load_replies(server, replies) do
    Agent.update(server, &%{&1 | load_replies: &1.load_replies ++ replies})
  end

  def fail_next_write(server, reason) do
    Agent.update(server, &%{&1 | write_faults: &1.write_faults ++ [{:error, reason}]})
  end

  def ambiguously_store_next_write(server, revision, checkpoint) do
    fault = {:ambiguous_with, revision, checkpoint}
    Agent.update(server, &%{&1 | write_faults: &1.write_faults ++ [fault]})
  end

  defp pop_load_reply(%{load_replies: [reply | rest]} = state, _ref) do
    {reply, %{state | load_replies: rest}}
  end

  defp pop_load_reply(%{load_replies: [], entries: entries} = state, ref) do
    reply =
      case Map.fetch(entries, ref.key) do
        {:ok, {_revision, checkpoint}} -> {:ok, checkpoint}
        :error -> :not_found
      end

    {reply, state}
  end

  defp compare_and_swap_entry(state, key, checkpoint, expected, revision) do
    case Map.get(state.entries, key) do
      nil when expected == 0 ->
        {:ok, put_in(state.entries[key], {revision, checkpoint})}

      {^expected, _current} ->
        {:ok, put_in(state.entries[key], {revision, checkpoint})}

      {current, _checkpoint} ->
        {{:error, {:stale, expected, current}}, state}

      nil ->
        {{:error, {:stale, expected, :not_found}}, state}
    end
  end
end

defmodule SpectreInstanceDurableFailureContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spectre.AgentRef
  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Canonical, as: DefinitionCanonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Run
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  alias SpectreInstanceDurableFailureContractTest.Agent, as: TestAgent
  alias SpectreInstanceDurableFailureContractTest.CheckpointStore
  alias SpectreInstanceDurableFailureContractTest.DefinitionStore
  alias SpectreInstanceDurableFailureContractTest.JournalStore

  test "Run journal failures preserve the Instance contract before and after a committed move" do
    start_failure = start_instance()

    assert {:error, {:run_journal_failed, :run_started, _reason}} =
             Spectre.turn(start_failure, "hello", journal: failing_journal([:run_started]))

    assert [%{status: :failed, cursor: :complete}] =
             start_failure |> Instance.info() |> Map.fetch!(:runs) |> Map.values()

    commit_failure = start_instance()

    assert {:error, {:run_journal_failed, :run_boundary, _reason, %Spectre.Result{} = committed}} =
             Spectre.turn(commit_failure, "hello", journal: failing_journal([:run_boundary]))

    assert committed.state.revision == 1
    assert Spectre.state(commit_failure) == committed.state
    run_id = get_in(committed.metadata, [:run, :id])

    assert_eventually(fn ->
      match?({:ok, %{status: :failed, cursor: :complete}}, Instance.run(commit_failure, run_id))
    end)
  end

  test "a stale policy command is rejected without consuming the retained boundary" do
    instance = start_instance()

    assert {:ok, %Turn{observable: {:needs, _request}} = pending} =
             Spectre.turn(instance, "work")

    stale = %{pending.ref | revision: pending.ref.revision + 1}

    assert {:error,
            {:stale_run_reference, stale_run_id, stale_revision, expected_run_id,
             expected_revision}} =
             Spectre.resume(instance, pending.ref, {:policy, stale, {:accept, :approved}})

    assert stale_run_id == pending.ref.run_id
    assert expected_run_id == pending.ref.run_id
    assert stale_revision == pending.ref.revision + 1
    assert expected_revision == pending.ref.revision

    assert {:ok, %{status: :boundary, waiting: :needs}} =
             Instance.run(instance, pending.ref.run_id)

    assert {:ok, %Turn{observable: {:awaiting, _invocation_ref}}} =
             Spectre.resume(
               instance,
               pending.ref,
               {:policy, pending.ref, {:accept, :approved}}
             )
  end

  test "checkpoint restore distinguishes stable and legacy store failures" do
    previous_trap = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap) end)

    stable_subject = unique_subject("stable-load-error")
    stable_store = checkpoint_store()
    CheckpointStore.queue_load_replies(checkpoint_server(stable_store), [{:error, :stable_down}])

    assert {:error, {:canonical_checkpoint_load_failed, :stable, :stable_down}} =
             Instance.start_link(
               agent: TestAgent,
               subject: stable_subject,
               checkpoint_store: stable_store,
               idle: false
             )

    detected_subject = unique_subject("legacy-detection-error")
    detected_ref = InstanceRef.new(TestAgent, detected_subject)
    detected_checkpoint = canonical_checkpoint(detected_ref)
    detected_store = checkpoint_store()

    CheckpointStore.queue_load_replies(
      checkpoint_server(detected_store),
      [{:ok, detected_checkpoint}, {:error, :legacy_detection_down}]
    )

    assert {:error,
            {:canonical_checkpoint_load_failed, :legacy_detection, :legacy_detection_down}} =
             Instance.start_link(
               agent: TestAgent,
               subject: detected_subject,
               checkpoint_store: detected_store,
               idle: false
             )

    missing_subject = unique_subject("legacy-missing-error")
    missing_store = checkpoint_store()

    CheckpointStore.queue_load_replies(
      checkpoint_server(missing_store),
      [:not_found, {:error, :legacy_lookup_down}]
    )

    assert {:error, {:canonical_checkpoint_load_failed, :legacy_detection, :legacy_lookup_down}} =
             Instance.start_link(
               agent: TestAgent,
               subject: missing_subject,
               checkpoint_store: missing_store,
               idle: false
             )
  end

  test "a portable AgentRef restores the stable checkpoint without legacy probing" do
    compiled_ref = AgentRef.new(TestAgent)
    portable_ref = AgentRef.from_id(compiled_ref.id)
    subject = unique_subject("portable-agent-ref")
    instance_ref = InstanceRef.new(portable_ref, subject)
    store = checkpoint_store()

    CheckpointStore.queue_load_replies(
      checkpoint_server(store),
      [{:ok, canonical_checkpoint(instance_ref)}]
    )

    instance =
      start_instance(
        agent_ref: portable_ref,
        subject: subject,
        checkpoint_store: store
      )

    assert Instance.ref(instance) == instance_ref
  end

  test "restore rejects over-capacity and unresolvable pinned Runs before serving traffic" do
    previous_trap = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap) end)

    capacity_subject = unique_subject("restore-capacity")
    capacity_ref = InstanceRef.new(TestAgent, capacity_subject)

    capacity_runs = %{
      "capacity-a" => run_checkpoint(capacity_ref, "capacity-a"),
      "capacity-b" => run_checkpoint(capacity_ref, "capacity-b")
    }

    assert {:error, {:restored_run_capacity_exceeded, 2, 1}} =
             Instance.start_link(
               agent: TestAgent,
               subject: capacity_subject,
               canonical_checkpoint: canonical_checkpoint(capacity_ref, runs: capacity_runs),
               max_runs: 1,
               idle: false
             )

    pinned_subject = unique_subject("restore-pinned")
    pinned_ref = InstanceRef.new(TestAgent, pinned_subject)
    pinned = run_checkpoint(pinned_ref, "pinned", activation_generation: 1)

    assert {:error, {:restored_run_invalid, "pinned", :pinned_run_requires_definition_store}} =
             Instance.start_link(
               agent: TestAgent,
               subject: pinned_subject,
               canonical_checkpoint:
                 canonical_checkpoint(pinned_ref, runs: %{"pinned" => pinned}),
               idle: false
             )

    failing_definition_store = definition_store(fault: :definition_store_down)

    assert {:error, {:restored_run_invalid, "pinned", :definition_store_down}} =
             Instance.start_link(
               agent: TestAgent,
               subject: pinned_subject,
               canonical_checkpoint:
                 canonical_checkpoint(pinned_ref, runs: %{"pinned" => pinned}),
               definition_store: failing_definition_store,
               idle: false
             )
  end

  test "an activated checkpoint cannot be restored without its Definition Store" do
    definition_store = definition_store()
    {_definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(definition_store)
    subject = unique_subject("activation-store-required")
    instance = start_instance(subject: subject, definition_store: definition_store)

    assert {:ok, _activation} =
             Instance.activate(instance, candidate_a, expected_generation: 0)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    previous_trap = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap) end)

    assert {:error, :restored_activation_requires_definition_store} =
             Instance.start_link(
               agent: TestAgent,
               subject: subject,
               canonical_checkpoint: checkpoint,
               idle: false
             )
  end

  test "manual checkpoints fence activation until the exact canonical revision is durable" do
    definition_store = definition_store()
    {definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(definition_store)
    checkpoint_store = checkpoint_store()

    instance =
      start_instance(
        definition_store: definition_store,
        checkpoint_store: checkpoint_store,
        checkpoint_mode: :manual
      )

    assert {:ok, %Turn{ref: %{run_id: run_id}}} = Spectre.turn(instance, "hello")

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, run_id))
    end)

    status = Instance.checkpoint_status(instance)

    assert {:error, {:activation_checkpoint_not_current, persisted_revision, canonical_revision}} =
             Instance.activate(instance, candidate_a, expected_generation: 0)

    assert persisted_revision == status.persisted_revision
    assert canonical_revision == status.canonical_revision
    assert {:ok, ^canonical_revision} = Instance.flush_checkpoint(instance)

    assert {:ok, %{definition_ref: ^definition_a}} =
             Instance.activate(instance, candidate_a, expected_generation: 0)

    assert {:ok, %{definition_ref: ^definition_a}} =
             Instance.definition_lifecycle(instance, to_string(definition_a))

    invalid_ref = %DefinitionRef{
      algorithm: :sha256,
      digest: "invalid",
      canonicalization_version: 1,
      contract_version: 1
    }

    assert {:error, {:invalid_definition_lifecycle_ref, ^invalid_ref}} =
             Instance.definition_lifecycle(instance, invalid_ref)

    assert {:error, {:invalid_definition_lifecycle_ref, invalid_value}} =
             Instance.definition_lifecycle(instance, self())

    assert invalid_value == self()
  end

  test "activation checkpoint ambiguity and conflict stop the owning Instance" do
    definition_store = definition_store()
    {_definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(definition_store)

    log =
      capture_log(fn ->
        for {reason, stop_reason} <- [
              {{:ambiguous, :network_timeout}, :activation_checkpoint_outcome_unknown},
              {:conflict, :activation_checkpoint_conflict}
            ] do
          checkpoint_store = checkpoint_store()
          CheckpointStore.fail_next_write(checkpoint_server(checkpoint_store), reason)

          instance =
            start_instance(
              subject: unique_subject("activation-fence"),
              definition_store: definition_store,
              checkpoint_store: checkpoint_store
            )

          monitor = Process.monitor(instance)

          assert {:error, ^reason} =
                   Instance.activate(instance, candidate_a, expected_generation: 0)

          assert_receive {:DOWN, ^monitor, :process, ^instance, {^stop_reason, ^reason}}, 1_000
        end
      end)

    assert log =~ "activation_checkpoint_outcome_unknown"
    assert log =~ "activation_checkpoint_conflict"
  end

  test "rollback checkpoint ambiguity and both conflict shapes stop the owning Instance" do
    definition_store = definition_store()
    {_definition_a, candidate_a, _definition_b, candidate_b} = publish_lineage(definition_store)

    log =
      capture_log(fn ->
        for {reason, stop_reason} <- [
              {{:ambiguous, :network_timeout}, :rollback_checkpoint_outcome_unknown},
              {:conflict, :rollback_checkpoint_conflict},
              {{:stale, 2, 9}, :rollback_checkpoint_conflict}
            ] do
          checkpoint_store = checkpoint_store()

          instance =
            start_instance(
              subject: unique_subject("rollback-fence"),
              definition_store: definition_store,
              checkpoint_store: checkpoint_store
            )

          assert {:ok, %{generation: 1}} =
                   Instance.activate(instance, candidate_a, expected_generation: 0)

          assert {:ok, %{generation: 2}} =
                   Instance.activate(instance, candidate_b, expected_generation: 1)

          CheckpointStore.fail_next_write(checkpoint_server(checkpoint_store), reason)
          monitor = Process.monitor(instance)

          assert {:error, ^reason} =
                   Instance.rollback(instance, candidate_a, expected_generation: 2)

          assert_receive {:DOWN, ^monitor, :process, ^instance, {^stop_reason, ^reason}}, 1_000
        end
      end)

    assert log =~ "rollback_checkpoint_outcome_unknown"
    assert log =~ "rollback_checkpoint_conflict"
  end

  test "ambiguous writes reconcile as conflicts when the store exposes divergent durable bytes" do
    checkpoint_store = checkpoint_store()
    subject = unique_subject("reconciliation-conflict")
    ref = InstanceRef.new(TestAgent, subject)
    divergent = canonical_checkpoint(ref, revision: 7, state_data: %{source: :other_writer})

    instance =
      start_instance(
        subject: subject,
        checkpoint_store: checkpoint_store,
        checkpoint_mode: :manual
      )

    assert {:ok, %Turn{ref: %{run_id: run_id}}} = Spectre.turn(instance, "hello")

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, run_id))
    end)

    status = Instance.checkpoint_status(instance)

    CheckpointStore.ambiguously_store_next_write(
      checkpoint_server(checkpoint_store),
      7,
      divergent
    )

    assert {:error, {:checkpoint_reconciliation_required, target, _reason}} =
             Instance.flush_checkpoint(instance, timeout: 2_000)

    assert target == status.canonical_revision

    assert {:error, {:checkpoint_reconciliation_conflict, 0, ^target, 7}} =
             Instance.reconcile_checkpoint(instance, timeout: 2_000)

    assert Instance.checkpoint_status(instance).error == :checkpoint_reconciliation_conflict
  end

  test "activation reports missing candidates and invalid generation fences without mutation" do
    definition_store = definition_store()
    instance = start_instance(definition_store: definition_store)
    {:ok, missing} = CandidateRef.parse("candidate:sha256:" <> String.duplicate("a", 64))

    assert {:error, :activation_candidate_not_found} =
             Instance.activate(instance, missing, expected_generation: 0)

    assert {:error, {:invalid_expected_activation_generation, :latest}} =
             Instance.activate(instance, missing, expected_generation: :latest)

    assert Instance.activation(instance) == nil
  end

  test "data-driven execution rejects every unsupported public boundary shape" do
    instance = start_instance()

    assert {:error, {:invalid_data_driven_execution_start, :map, :binary}} =
             Instance.start_execution(instance, %{}, "invalid-options")

    assert {:error, {:invalid_data_driven_execution_start, :tuple, :other}} =
             Instance.start_execution(instance, {:invalid, :materialization}, self())
  end

  defp publish_lineage(store) do
    base = Definition.canonical!(TestAgent)

    definition_a =
      DefinitionCanonical.new!(Map.put(Map.from_struct(base), :declared_version, 101))

    definition_b =
      DefinitionCanonical.new!(Map.put(Map.from_struct(base), :declared_version, 102))

    closure = closure()
    manifest_a = Manifest.new!(definition_a, Envelope.empty(), closure)

    manifest_b =
      Manifest.new!(definition_b, Envelope.empty(), closure,
        parent_refs: [DefinitionCanonical.ref(definition_a)]
      )

    assert {:ok, _receipt} = Store.publish(store, definition_a, manifest_a)

    assert {:ok, candidate_a} =
             Resolver.bootstrap_candidate(store, DefinitionCanonical.ref(definition_a),
               source: :compiled,
               created_at: 1
             )

    assert {:ok, _receipt} = Store.publish(store, definition_b, manifest_b)

    assert {:ok, candidate_b} =
             Resolver.bootstrap_candidate(store, DefinitionCanonical.ref(definition_b),
               source: :compiled,
               parent_ref: candidate_a,
               created_at: 2
             )

    {DefinitionCanonical.ref(definition_a), candidate_a, DefinitionCanonical.ref(definition_b),
     candidate_b}
  end

  defp closure do
    {:ok, build_digest} = Closure.fingerprint(TestAgent)

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
      build_fingerprints: %{("beam:" <> Atom.to_string(TestAgent)) => build_digest},
      evaluation_corpus_digest: nil,
      compatibility_mode: :native_v2
    })
  end

  defp run_checkpoint(ref, run_id, opts \\ []) do
    run_opts = Keyword.merge([run_id: run_id], opts)

    {:ok, run} =
      Spectre.Runtime.admit(
        TestAgent,
        Spectre.Input.new("restored"),
        %State{conversation_id: ref.key},
        run_opts,
        run_opts
      )

    {:ok, checkpoint} = Run.checkpoint(run)
    checkpoint
  end

  defp canonical_checkpoint(ref, opts \\ []) do
    state = %State{
      conversation_id: ref.key,
      data: Keyword.get(opts, :state_data, %{})
    }

    {:ok, canonical} =
      Canonical.new(%{
        flow: state,
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}},
        runs: Keyword.get(opts, :runs, %{})
      })

    canonical = %{canonical | revision: Keyword.get(opts, :revision, canonical.revision)}
    {:ok, checkpoint} = Codec.encode_json(canonical)
    checkpoint
  end

  defp definition_store(opts \\ []) do
    server = start_agent(%{entries: %{}, fault: Keyword.get(opts, :fault)})

    {DefinitionStore,
     server: server, id: "definition-store-#{System.unique_integer([:positive])}"}
  end

  defp checkpoint_store do
    server = start_agent(%{entries: %{}, load_replies: [], write_faults: []})
    {CheckpointStore, server: server}
  end

  defp checkpoint_server({CheckpointStore, opts}), do: Keyword.fetch!(opts, :server)

  defp start_agent(initial) do
    {:ok, server} = Agent.start_link(fn -> initial end)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp start_instance(extra \\ []) do
    opts =
      [agent: TestAgent, subject: unique_subject("instance"), idle: false]
      |> Keyword.merge(extra)

    {:ok, instance} = Instance.start_link(opts)
    Process.unlink(instance)
    on_exit(fn -> stop_instance(instance) end)
    instance
  end

  defp stop_instance(instance) do
    if Process.alive?(instance), do: GenServer.stop(instance, :normal)
  end

  defp failing_journal(events) do
    {JournalStore,
     events: events, mode: :sync, on_error: :error, store_opts: [reply: {:error, :journal_down}]}
  end

  defp unique_subject(prefix) do
    Subject.new("#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
