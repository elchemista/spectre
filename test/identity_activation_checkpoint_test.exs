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

  test "owner fence loss blocks Effect dispatch, new admission, and activation commit" do
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

    Elixir.Agent.update(owner_server, &%{&1 | valid?: false})

    assert {:error, {:owner_fence_lost, :effect_dispatch, :lease_lost}} =
             Spectre.resume(instance, execution_ref, {:execute, execution_ref}, test_pid: self())

    refute_received :pinned_work_executed

    assert {:error, {:owner_fence_lost, :admission, :lease_lost}} =
             Spectre.turn(instance, "hello")

    assert {:error, {:owner_fence_lost, :activation_commit, :lease_lost}} =
             Spectre.activate(instance, candidate_b, expected_generation: 1)
  end

  test "legacy Instance key migration is Store-controlled and divergent histories fail closed" do
    checkpoint_store = durable_checkpoint_store()
    subject = Subject.new("legacy-key-#{System.unique_integer([:positive])}")
    stable_ref = InstanceRef.new(Agent, subject)
    assert {:ok, legacy_ref} = InstanceRef.legacy(stable_ref)
    legacy_checkpoint = legacy_checkpoint(legacy_ref)
    CheckpointStore.seed(checkpoint_server(checkpoint_store), legacy_ref, legacy_checkpoint, 0)

    instance = start_instance(subject, checkpoint_store: checkpoint_store)
    assert Instance.ref(instance).key == stable_ref.key
    assert :not_found = Spectre.Instance.CheckpointStore.load(checkpoint_store, legacy_ref, [])

    assert {:ok, migrated} =
             Spectre.Instance.CheckpointStore.load(checkpoint_store, stable_ref, [])

    assert {:ok, canonical} = CheckpointCodec.decode(migrated)
    assert canonical.revision == 1

    assert {:ok, correlations} = InstanceCanonical.fetch(canonical, :correlations)
    assert correlations.instance_key == stable_ref.key
    assert correlations.instance_key_migration.legacy_instance_key == legacy_ref.key
    :ok = GenServer.stop(instance, :normal)

    divergent_subject = Subject.new("divergent-key-#{System.unique_integer([:positive])}")
    divergent_stable = InstanceRef.new(Agent, divergent_subject)
    assert {:ok, divergent_legacy} = InstanceRef.legacy(divergent_stable)
    first = legacy_checkpoint(divergent_legacy)
    second = legacy_checkpoint(divergent_stable)
    server = checkpoint_server(checkpoint_store)
    CheckpointStore.seed(server, divergent_legacy, first, 0)
    CheckpointStore.seed(server, divergent_stable, second, 0)

    previous_trap = Process.flag(:trap_exit, true)

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
      build_fingerprints: %{"beam:Agent" => @digest},
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
