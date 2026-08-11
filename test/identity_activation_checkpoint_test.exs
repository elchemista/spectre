defmodule SpectreIdentityActivationCheckpointTest.Renderer do
  @moduledoc false

  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreIdentityActivationCheckpointTest.Actions do
  @moduledoc false

  def work(_arguments, context) do
    if pid = Keyword.get(context.opts, :test_pid), do: send(pid, :pinned_work_executed)
    {:ok, "worked"}
  end
end

defmodule SpectreIdentityActivationCheckpointTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :stable_activation_agent

  actions SpectreIdentityActivationCheckpointTest.Actions do
    protect(:work, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :activation do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreIdentityActivationCheckpointTest.Renderer, :render})
    end

    on :WORK, regex: ~r/^work$/i do
      action(:work,
        reply: :approval,
        renderer: {SpectreIdentityActivationCheckpointTest.Renderer, :render}
      )
    end
  end
end

defmodule SpectreIdentityActivationCheckpointTest.DefinitionStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts), do: Keyword.fetch!(opts, :id)

  @impl true
  def durability(_opts), do: :durable

  @impl true
  def get(key, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, key) do
        {:ok, value} -> {:ok, value}
        :error -> :not_found
      end
    end)
  end

  @impl true
  def put(key, encoded, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, key) do
        :error -> {{:ok, :created}, Map.put(entries, key, encoded)}
        {:ok, ^encoded} -> {{:ok, :existing}, entries}
        {:ok, _different} -> {{:error, {:immutable_conflict, key}}, entries}
      end
    end)
  end
end

defmodule SpectreIdentityActivationCheckpointTest.CheckpointStore do
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
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:checkpoint_owner_fence, Keyword.get(opts, :owner_fencing_token)})
    end

    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      entries = Map.put(entries, :__last_fence__, Keyword.get(opts, :owner_fencing_token))

      case Map.pop(entries, :__fault__) do
        {{:once, reason}, remaining} ->
          {{:error, reason}, remaining}

        {nil, entries} ->
          compare_and_swap_entry(entries, ref.key, checkpoint, expected, revision)
      end
    end)
  end

  defp compare_and_swap_entry(entries, key, checkpoint, expected, revision) do
    case Map.get(entries, key) do
      nil when expected == 0 ->
        {:ok, Map.put(entries, key, {revision, checkpoint})}

      {^expected, _current} ->
        {:ok, Map.put(entries, key, {revision, checkpoint})}

      {current, _checkpoint} ->
        {{:error, {:stale, expected, current}}, entries}

      nil ->
        {{:error, {:stale, expected, :not_found}}, entries}
    end
  end

  @impl true
  def migrate_instance_key(legacy_ref, stable_ref, legacy, migrated, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case {Map.get(entries, legacy_ref.key), Map.get(entries, stable_ref.key)} do
        {{_revision, ^legacy}, nil} ->
          revision = migrated |> Jason.decode!() |> Map.fetch!("revision")

          next =
            entries
            |> Map.delete(legacy_ref.key)
            |> Map.put(stable_ref.key, {revision, migrated})

          {{:ok, :moved}, next}

        {_legacy, {_revision, ^migrated}} ->
          {{:ok, :aliased}, entries}

        {_legacy, _stable} ->
          {{:error, :migration_conflict}, entries}
      end
    end)
  end

  def seed(server, ref, checkpoint, revision) do
    Agent.update(server, &Map.put(&1, ref.key, {revision, checkpoint}))
  end

  def fail_next(server, reason) do
    Agent.update(server, &Map.put(&1, :__fault__, {:once, reason}))
  end

  def observed_fence(server), do: Agent.get(server, &Map.get(&1, :__last_fence__))
end

defmodule SpectreIdentityActivationCheckpointTest.Owner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  @impl true
  def claim(ref, opts) do
    token =
      Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
        next = state.token + 1
        {next, %{state | token: next}}
      end)

    Lease.new(
      owner_id: "test-owner:" <> ref.key,
      fencing_token: token,
      issued_at: System.system_time(:millisecond),
      expires_at: nil,
      metadata: %{instance_key: ref.key}
    )
  end

  @impl true
  def validate(ref, lease, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn state ->
      cond do
        not state.valid? -> {:error, :lease_lost}
        state.token != lease.fencing_token -> {:error, :lease_superseded}
        lease.metadata.instance_key != ref.key -> {:error, :lease_instance_mismatch}
        true -> :ok
      end
    end)
  end

  @impl true
  def release(_ref, _lease, _opts), do: :ok
end

defmodule SpectreIdentityActivationCheckpointTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Instance
  alias Spectre.Instance.Canonical, as: InstanceCanonical
  alias Spectre.Instance.Canonical.Codec, as: CheckpointCodec
  alias Spectre.Instance.Canonical.Sections, as: CanonicalSections
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Run.Ref, as: RunRef
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  alias SpectreIdentityActivationCheckpointTest.Agent
  alias SpectreIdentityActivationCheckpointTest.CheckpointStore
  alias SpectreIdentityActivationCheckpointTest.DefinitionStore
  alias SpectreIdentityActivationCheckpointTest.Owner

  @digest String.duplicate("a", 64)

  test "AgentRef key is stable while the legacy key remains an explicit migration address" do
    current = AgentRef.new(Agent)
    changed_source = %{current | version: current.version + 1, stack_digest: @digest}

    assert AgentRef.key(current) == AgentRef.key(changed_source)
    assert {:ok, legacy_current} = AgentRef.legacy_key(current)
    assert {:ok, legacy_changed} = AgentRef.legacy_key(changed_source)
    refute legacy_current == legacy_changed

    assert {:ok, restored} = current |> AgentRef.to_data() |> AgentRef.from_data()
    assert restored == current

    portable = AgentRef.from_id(current.id)
    assert AgentRef.key(portable) == AgentRef.key(current)
    assert {:error, :legacy_agent_ref_source_unavailable} = AgentRef.legacy_key(portable)

    subject = Subject.new("stable-agent-subject")
    assert InstanceRef.new(current, subject).key == InstanceRef.new(changed_source, subject).key

    durable_subject = Subject.new("durable-agent-ref-#{System.unique_integer([:positive])}")

    assert {:ok, instance} =
             Instance.start_link(
               agent: Agent,
               agent_ref: portable,
               subject: durable_subject,
               idle: false
             )

    assert Instance.ref(instance).agent_ref == portable
    :ok = GenServer.stop(instance, :normal)
  end

  test "Definition A stays pinned to its open Run after B activates and across restart" do
    definition_store = durable_definition_store("activation-restart")
    checkpoint_store = durable_checkpoint_store()
    {definition_a, candidate_a, definition_b, candidate_b} = publish_lineage(definition_store)
    subject = Subject.new("activation-restart-#{System.unique_integer([:positive])}")

    instance =
      start_instance(subject,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store
      )

    assert {:ok, activation_a} = Spectre.activate(instance, candidate_a, expected_generation: 0)
    assert activation_a.definition_ref == definition_a
    assert activation_a.generation == 1

    assert {:ok, %Turn{observable: {:needs, _request}} = needs} =
             Spectre.turn(instance, "work")

    assert {:ok, %Turn{observable: {:awaiting, %RunRef{} = execution_ref}}} =
             Spectre.turn(instance, "yes")

    assert {:ok, _revision} = Spectre.flush_checkpoint(instance)

    assert {:error, {:stale_activation_generation, 0, 1}} =
             Spectre.activate(instance, candidate_b, expected_generation: 0)

    assert {:ok, activation_b} = Spectre.activate(instance, candidate_b, expected_generation: 1)
    assert activation_b.definition_ref == definition_b
    assert activation_b.generation == 2

    assert {:ok, %Turn{observable: {:reply, "hello:hello", hello_ref}}} =
             Spectre.turn(instance, "hello")

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, hello_ref.run_id))
    end)

    assert {:ok, a_before_restart} = Instance.run(instance, execution_ref.run_id)
    assert {:ok, b_before_restart} = Instance.run(instance, hello_ref.run_id)
    assert a_before_restart.definition_ref == definition_a
    assert a_before_restart.activation_generation == 1
    assert b_before_restart.definition_ref == definition_b
    assert b_before_restart.activation_generation == 2
    assert needs.ref.run_id == execution_ref.run_id

    assert {:ok, _revision} = Spectre.flush_checkpoint(instance)
    :ok = GenServer.stop(instance, :normal)

    restarted =
      start_instance(subject,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store
      )

    assert %Instance.Activation{definition_ref: ^definition_b, generation: 2} =
             Spectre.activation(restarted)

    assert {:ok, %{definition_ref: ^definition_a, activation_generation: 1}} =
             Instance.run(restarted, execution_ref.run_id)

    assert {:ok, %{definition_ref: ^definition_b, activation_generation: 2}} =
             Instance.run(restarted, hello_ref.run_id)

    assert {:ok, %Turn{observable: {:reply, "worked", _reply_ref}}} =
             Spectre.resume(
               restarted,
               execution_ref,
               {:execute, execution_ref},
               test_pid: self()
             )

    assert_receive :pinned_work_executed

    assert {:ok, %{definition_ref: ^definition_a, activation_generation: 1}} =
             Instance.run(restarted, execution_ref.run_id)
  end

  test "a superseding owner lease blocks Effect dispatch, admission, and activation commit" do
    definition_store = volatile_definition_store()
    {_definition_a, candidate_a, _definition_b, candidate_b} = publish_lineage(definition_store)
    owner_server = start_agent(%{token: 0, valid?: true})
    subject = Subject.new("owner-loss-#{System.unique_integer([:positive])}")

    instance =
      start_instance(subject,
        definition_store: definition_store,
        owner: {Owner, server: owner_server}
      )

    assert {:ok, _activation} = Spectre.activate(instance, candidate_a, expected_generation: 0)
    assert {:ok, %Turn{observable: {:needs, _request}}} = Spectre.turn(instance, "work")

    assert {:ok, %Turn{observable: {:awaiting, %RunRef{} = execution_ref}}} =
             Spectre.turn(instance, "yes")

    Elixir.Agent.update(owner_server, &%{&1 | token: &1.token + 1})

    assert {:error, {:owner_fence_lost, :effect_dispatch, :lease_superseded}} =
             Spectre.resume(instance, execution_ref, {:execute, execution_ref}, test_pid: self())

    refute_received :pinned_work_executed

    assert {:error, {:owner_fence_lost, :admission, :lease_superseded}} =
             Spectre.turn(instance, "hello")

    assert {:error, {:owner_fence_lost, :activation_commit, :lease_superseded}} =
             Spectre.activate(instance, candidate_b, expected_generation: 1)
  end

  test "the local owner advances past a durable fence after a simulated VM counter reset" do
    definition_store = durable_definition_store("local-owner-restart")
    checkpoint_store = durable_checkpoint_store()
    {_definition_a, candidate_a, _definition_b, candidate_b} = publish_lineage(definition_store)
    subject = Subject.new("local-owner-restart-#{System.unique_integer([:positive])}")

    instance =
      start_instance(subject,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store,
        owner: {Spectre.Instance.Owner.Local, fencing_token: 41},
        test_pid: self()
      )

    assert {:ok, %{owner_fencing_token: 41}} =
             Spectre.activate(instance, candidate_a, expected_generation: 0)

    assert {:ok, _revision} = Spectre.flush_checkpoint(instance)
    assert CheckpointStore.observed_fence(checkpoint_server(checkpoint_store)) == 41
    :ok = GenServer.stop(instance, :normal)

    restarted =
      start_instance(subject,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store,
        owner: {Spectre.Instance.Owner.Local, fencing_token: 1},
        test_pid: self()
      )

    assert %Instance.Activation{owner_fencing_token: 41} = Spectre.activation(restarted)

    assert {:ok, %{owner_fencing_token: 42, generation: 2}} =
             Spectre.activate(restarted, candidate_b, expected_generation: 1)

    assert CheckpointStore.observed_fence(checkpoint_server(checkpoint_store)) == 42
  end

  test "a host owner that reuses a persisted fencing token is rejected on restore" do
    definition_store = durable_definition_store("stale-owner-restart")
    checkpoint_store = durable_checkpoint_store()
    {_definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(definition_store)
    owner_server = start_agent(%{token: 0, valid?: true})
    subject = Subject.new("stale-owner-restart-#{System.unique_integer([:positive])}")

    instance =
      start_instance(subject,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store,
        owner: {Owner, server: owner_server}
      )

    assert {:ok, %{owner_fencing_token: 1}} =
             Spectre.activate(instance, candidate_a, expected_generation: 0)

    assert {:ok, _revision} = Spectre.flush_checkpoint(instance)
    :ok = GenServer.stop(instance, :normal)
    Elixir.Agent.update(owner_server, &%{&1 | token: 0})

    previous_trap = Process.flag(:trap_exit, true)

    assert {:error, {:owner_fencing_token_not_monotonic, 1, 1}} =
             Instance.start_link(
               agent: Agent,
               subject: subject,
               definition_store: definition_store,
               checkpoint_store: checkpoint_store,
               owner: {Owner, server: owner_server},
               idle: false
             )

    Process.flag(:trap_exit, previous_trap)
  end

  test "a shaped stale activation checkpoint fences and terminates the Instance" do
    definition_store = durable_definition_store("activation-shaped-stale")
    checkpoint_store = durable_checkpoint_store()
    {_definition_a, candidate_a, _definition_b, _candidate_b} = publish_lineage(definition_store)
    subject = Subject.new("activation-shaped-stale-#{System.unique_integer([:positive])}")

    instance =
      start_instance(subject,
        definition_store: definition_store,
        checkpoint_store: checkpoint_store
      )

    monitor = Process.monitor(instance)
    CheckpointStore.fail_next(checkpoint_server(checkpoint_store), {:stale, 0, 9})

    assert {:error, {:stale, 0, 9}} =
             Spectre.activate(instance, candidate_a, expected_generation: 0)

    assert_receive {:DOWN, ^monitor, :process, ^instance,
                    {:activation_checkpoint_conflict, {:stale, 0, 9}}}
  end

  test "concurrent Activation CAS calls commit exactly one generation" do
    definition_store = durable_definition_store("activation-race")
    {definition_a, candidate_a, definition_b, candidate_b} = publish_lineage(definition_store)
    subject = Subject.new("activation-race-#{System.unique_integer([:positive])}")
    instance = start_instance(subject, definition_store: definition_store)
    parent = self()

    tasks =
      Enum.map([candidate_a, candidate_b], fn candidate ->
        Task.async(fn ->
          send(parent, {:activation_ready, self()})
          receive do: (:activate -> Spectre.activate(instance, candidate, expected_generation: 0))
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:activation_ready, pid}
        pid
      end)

    Enum.each(pids, &send(&1, :activate))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [{:ok, %{generation: 1, definition_ref: winner}}] =
             Enum.filter(results, &match?({:ok, _activation}, &1))

    assert [{:error, {:stale_activation_generation, 0, 1}}] =
             Enum.filter(results, &match?({:error, _reason}, &1))

    assert winner in [definition_a, definition_b]

    assert %Instance.Activation{generation: 1, definition_ref: ^winner} =
             Spectre.activation(instance)
  end

  test "restore re-verifies Activation evidence and every pinned Run against the Store" do
    definition_store = durable_definition_store("restore-integrity")

    {_definition_a, candidate_a, _definition_b, _candidate_b} =
      publish_lineage(definition_store)

    subject = Subject.new("restore-integrity-#{System.unique_integer([:positive])}")
    instance = start_instance(subject, definition_store: definition_store)

    assert {:ok, _activation} = Spectre.activate(instance, candidate_a, expected_generation: 0)
    assert {:ok, %Turn{observable: {:needs, _request}}} = Spectre.turn(instance, "work")
    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = CheckpointCodec.decode(checkpoint)
    assert {:ok, activation} = InstanceCanonical.fetch(canonical, :activation)
    assert {:ok, runs} = InstanceCanonical.fetch(canonical, :runs)
    [{run_id, run_checkpoint}] = Map.to_list(runs)
    assert {:ok, run} = Spectre.Run.restore(run_checkpoint)
    :ok = GenServer.stop(instance, :normal)

    forged_provenance =
      Map.put(activation.provenance, :build_evidence, %{
        status: :matched,
        drifts: [],
        observed_builds: %{"beam:forged" => String.duplicate("f", 64)}
      })

    activation_attrs =
      activation
      |> Map.from_struct()
      |> Map.put(:provenance, forged_provenance)
      |> Map.delete(:activation_receipt)

    assert {:ok, forged_activation} = Instance.Activation.build(activation_attrs)

    assert_restore_error(
      put_canonical_section(canonical, :activation, forged_activation),
      subject,
      definition_store,
      :restored_activation_integrity_mismatch
    )

    mismatched_run = update_run_pin(run, closure_digest: String.duplicate("f", 64))
    assert {:ok, mismatched_checkpoint} = Spectre.Run.checkpoint(mismatched_run)

    assert_restore_error(
      put_canonical_section(canonical, :runs, %{run_id => mismatched_checkpoint}),
      subject,
      definition_store,
      {:restored_run_invalid, run_id,
       {:run_closure_digest_mismatch, mismatched_run.closure_digest, activation.closure_digest}}
    )

    assert {:ok, missing_ref} =
             Spectre.Definition.Ref.parse("sha256:" <> String.duplicate("9", 64))

    missing_definition_run = update_run_pin(run, definition_ref: missing_ref)
    assert {:ok, missing_definition_checkpoint} = Spectre.Run.checkpoint(missing_definition_run)

    assert_restore_error(
      put_canonical_section(canonical, :runs, %{run_id => missing_definition_checkpoint}),
      subject,
      definition_store,
      {:restored_run_invalid, run_id, {:pinned_run_definition_not_found, to_string(missing_ref)}}
    )

    {DefinitionStore, store_opts} = definition_store
    store_server = Keyword.fetch!(store_opts, :server)
    candidate_key = "candidate/" <> to_string(activation.candidate_ref)
    Elixir.Agent.update(store_server, &Map.delete(&1, candidate_key))

    assert_restore_error(
      canonical,
      subject,
      definition_store,
      :restored_activation_candidate_not_found
    )
  end

  test "legacy Instance keys require offline migration and divergent histories fail closed" do
    checkpoint_store = durable_checkpoint_store()
    subject = Subject.new("legacy-key-#{System.unique_integer([:positive])}")
    stable_ref = InstanceRef.new(Agent, subject)
    assert {:ok, legacy_ref} = InstanceRef.legacy(stable_ref)
    legacy_checkpoint = legacy_checkpoint(legacy_ref)
    CheckpointStore.seed(checkpoint_server(checkpoint_store), legacy_ref, legacy_checkpoint, 0)

    previous_trap = Process.flag(:trap_exit, true)

    assert {:error,
            {:legacy_instance_checkpoint_requires_offline_migration, legacy_key, stable_key}} =
             Instance.start_link(
               agent: Agent,
               subject: subject,
               checkpoint_store: checkpoint_store,
               idle: false
             )

    assert legacy_key == legacy_ref.key
    assert stable_key == stable_ref.key

    assert {:ok, ^legacy_checkpoint} =
             Spectre.Instance.CheckpointStore.load(checkpoint_store, legacy_ref, [])

    assert :not_found = Spectre.Instance.CheckpointStore.load(checkpoint_store, stable_ref, [])

    divergent_subject = Subject.new("divergent-key-#{System.unique_integer([:positive])}")
    divergent_stable = InstanceRef.new(Agent, divergent_subject)
    assert {:ok, divergent_legacy} = InstanceRef.legacy(divergent_stable)
    first = legacy_checkpoint(divergent_legacy)
    second = legacy_checkpoint(divergent_stable)
    server = checkpoint_server(checkpoint_store)
    CheckpointStore.seed(server, divergent_legacy, first, 0)
    CheckpointStore.seed(server, divergent_stable, second, 0)

    assert {:error,
            {:divergent_instance_key_histories, divergent_legacy_key, divergent_stable_key}} =
             Instance.start_link(
               agent: Agent,
               subject: divergent_subject,
               checkpoint_store: checkpoint_store,
               idle: false
             )

    Process.flag(:trap_exit, previous_trap)

    assert divergent_legacy_key == divergent_legacy.key
    assert divergent_stable_key == divergent_stable.key
  end

  defp publish_lineage(store) do
    base = Definition.canonical!(Agent)
    definition_a = Canonical.new!(Map.put(Map.from_struct(base), :declared_version, 101))
    definition_b = Canonical.new!(Map.put(Map.from_struct(base), :declared_version, 102))
    closure = closure()
    manifest_a = Manifest.new!(definition_a, Envelope.empty(), closure)

    manifest_b =
      Manifest.new!(definition_b, Envelope.empty(), closure,
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

  defp durable_definition_store(id) do
    server = start_agent(%{})
    {DefinitionStore, server: server, id: id}
  end

  defp volatile_definition_store do
    id = {:identity_activation_memory, System.unique_integer([:positive])}
    server = start_supervised!({Spectre.Definition.Store.Memory, id: id})
    {Spectre.Definition.Store.Memory, server: server}
  end

  defp durable_checkpoint_store do
    server = start_agent(%{})
    {CheckpointStore, server: server}
  end

  defp start_agent(initial) do
    {:ok, server} = Elixir.Agent.start_link(fn -> initial end)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp checkpoint_server({CheckpointStore, opts}), do: Keyword.fetch!(opts, :server)

  defp start_instance(subject, opts) do
    {:ok, instance} =
      Instance.start_link(
        [agent: Agent, subject: subject, idle: false]
        |> Keyword.merge(opts)
      )

    Process.unlink(instance)
    instance
  end

  defp legacy_checkpoint(instance_ref) do
    {:ok, canonical} =
      InstanceCanonical.new(%{
        flow: %State{conversation_id: instance_ref.key},
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: instance_ref.key},
        events: %{records: [], ids: %{}},
        activation: nil,
        runs: %{}
      })

    {:ok, checkpoint} = CheckpointCodec.encode_json(canonical)
    checkpoint
  end

  defp put_canonical_section(canonical, name, value) do
    {:ok, section} = CanonicalSections.fetch(canonical.sections, name)
    sections = CanonicalSections.put(canonical.sections, name, %{section | value: value})
    %{canonical | sections: sections}
  end

  defp assert_restore_error(canonical, subject, definition_store, expected) do
    assert {:ok, encoded} = CheckpointCodec.encode_json(canonical)
    previous_trap = Process.flag(:trap_exit, true)

    assert {:error, ^expected} =
             Instance.start_link(
               agent: Agent,
               subject: subject,
               definition_store: definition_store,
               canonical_checkpoint: encoded,
               idle: false
             )

    Process.flag(:trap_exit, previous_trap)
  end

  defp update_run_pin(run, changes) do
    identity = Map.merge(run.result.metadata.run, Map.new(changes))
    result = %{run.result | metadata: Map.put(run.result.metadata, :run, identity)}
    struct!(run, changes |> Map.new() |> Map.put(:result, result))
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
