defmodule SpectreMorphRuntimeTurnTest.Renderer do
  @moduledoc false

  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreMorphRuntimeTurnTest.Actions do
  @moduledoc false

  def work(_arguments, context) do
    if pid = Keyword.get(context.opts, :test_pid), do: send(pid, :morph_pinned_work_executed)
    {:ok, "worked under Definition A"}
  end
end

defmodule SpectreMorphRuntimeTurnTest.QueuePlug do
  @moduledoc false
  @behaviour Spectre.Input.Plug

  @impl true
  def rehearsable?, do: true

  @impl true
  def init(opts), do: opts

  @impl true
  def call(input, %{opts: opts}, _state) do
    if Keyword.get(opts, :block_input?, false) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:morph_queue_blocked, self()})

      receive do
        :release_morph_queue -> :ok
      end
    end

    {:cont, input}
  end
end

defmodule SpectreMorphRuntimeTurnTest.WorkAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_runtime_turn_agent

  alias SpectreMorphRuntimeTurnTest.Actions
  alias SpectreMorphRuntimeTurnTest.QueuePlug
  alias SpectreMorphRuntimeTurnTest.Renderer

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:support, :billing], prompt_tokens: 512],
    approval: :human
  )

  input_pipeline([{QueuePlug, []}])

  actions Actions do
    protect(:work, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :compiled do
    on :WORK, regex: ~r/^work$/i do
      action(:work, reply: :approval, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreMorphRuntimeTurnTest.ConflictAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_runtime_conflict_agent

  alias SpectreMorphRuntimeTurnTest.Renderer

  morph(
    may_propose: [:mount_skill],
    within: [scopes: [:agent], prompt_tokens: 256],
    approval: :human
  )

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :compiled do
    on :COMPILED_REFUND, regex: ~r/^refund$/i do
      reply(:compiled_refund, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreMorphRuntimeTurnTest.InputBoundAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_runtime_input_bound_agent, input_max_bytes: 4

  morph(
    may_propose: [:mount_skill],
    within: [scopes: [:agent], prompt_tokens: 128],
    approval: :human
  )

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
end

defmodule SpectreMorphRuntimeTurnTest.DefinitionStore do
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

defmodule SpectreMorphRuntimeTurnTest.CheckpointStore do
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

        {actual, _current} ->
          {{:error, {:stale, expected, actual}}, entries}

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
          revision = migrated |> Spectre.JSON.decode!() |> Map.fetch!("revision")

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
end

defmodule SpectreMorphRuntimeTurnTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Instance
  alias Spectre.Morph
  alias Spectre.Run.Ref, as: RunRef
  alias Spectre.Subject
  alias Spectre.Turn

  alias SpectreMorphRuntimeTurnTest.CheckpointStore
  alias SpectreMorphRuntimeTurnTest.ConflictAgent
  alias SpectreMorphRuntimeTurnTest.DefinitionStore
  alias SpectreMorphRuntimeTurnTest.InputBoundAgent
  alias SpectreMorphRuntimeTurnTest.WorkAgent

  @protected_cases [
    %{
      "id" => "unrelated-input-stays-unhandled",
      "input" => "weather",
      "expected_outcome" => "clarify",
      "context" => %{"scope" => "support"},
      "llm" => "forbidden"
    }
  ]

  test "a Morph activation and its A/B run pins survive a durable Instance restart" do
    fixture = start_fixture(WorkAgent, checkpoint?: true)
    %{instance: instance, definition_ref: definition_a} = fixture

    assert {:ok, %Turn{observable: {:needs, _request}} = needs} =
             Spectre.turn(instance, "work")

    assert {:ok, %{definition_ref: ^definition_a, activation_generation: 1}} =
             Instance.run(instance, needs.ref.run_id)

    approved = approved_refund_change(instance, 100)
    assert {:ok, activation_b} = Morph.activate(approved, now: 103)
    assert activation_b.generation == 2
    refute activation_b.definition_ref == definition_a

    assert {:ok, learned} =
             Spectre.turn(instance, "refund",
               conversation_id: "definition-b",
               skill_context: %{"scope" => "billing"}
             )

    assert {:reply, "Refund learned for refund", _turn_ref} = learned.observable

    assert {:reply, learned_result} = learned.decision

    assert get_in(learned_result.metadata, [:runtime_skill, :agent_definition_ref]) ==
             to_string(activation_b.definition_ref)

    assert_eventually_quiescent(instance)

    assert {:ok, %{definition_ref: ^definition_a, activation_generation: 1}} =
             Instance.run(instance, needs.ref.run_id)

    assert {:ok, _revision} = Spectre.flush_checkpoint(instance)
    :ok = GenServer.stop(instance, :normal)

    restarted = restart_fixture(fixture)

    assert %Instance.Activation{
             definition_ref: restarted_definition_b,
             generation: 2
           } = Spectre.activation(restarted)

    assert restarted_definition_b == activation_b.definition_ref

    assert {:ok, %{definition_ref: ^definition_a, activation_generation: 1}} =
             Instance.run(restarted, needs.ref.run_id)

    assert {:ok, after_restart} =
             Spectre.turn(restarted, "refund",
               conversation_id: "definition-b",
               skill_context: %{"scope" => "support"}
             )

    assert {:reply, "Refund learned for refund", _turn_ref} = after_restart.observable

    assert_eventually_quiescent(restarted)

    assert {:ok, %Turn{observable: {:awaiting, %RunRef{} = work_ref}}} =
             Spectre.resume(
               restarted,
               needs.ref,
               {:policy, needs.ref, {:accept, :approved}}
             )

    assert {:ok, %Turn{observable: {:reply, "worked under Definition A", _turn_ref}}} =
             Spectre.resume(restarted, work_ref, {:execute, work_ref}, test_pid: self())

    assert_receive :morph_pinned_work_executed

    assert {:ok, %{definition_ref: ^definition_a, activation_generation: 1}} =
             Instance.run(restarted, work_ref.run_id)
  end

  test "a durable Morph activation refuses a different execution profile on restart" do
    fixture = start_fixture(WorkAgent, checkpoint?: true)
    approved = approved_refund_change(fixture.instance, 180)
    assert {:ok, activation} = Morph.activate(approved, now: 183)
    assert {:ok, _revision} = Spectre.flush_checkpoint(fixture.instance)
    :ok = GenServer.stop(fixture.instance, :normal)

    incompatible_opts = [
      agent: fixture.agent,
      subject: fixture.subject,
      definition_store: fixture.store,
      checkpoint_store: fixture.checkpoint_store,
      idle: false,
      opts: [
        checker_versions: Declarative.checker_versions(),
        turn_handlers: [Kernel]
      ]
    ]

    previous_trap = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:morph_instance_execution_profile_overridden, [:turn_handlers]}} =
               Instance.start_link(incompatible_opts)
    after
      Process.flag(:trap_exit, previous_trap)
    end

    restarted = restart_fixture(fixture)
    assert Spectre.activation(restarted).definition_ref == activation.definition_ref

    assert {:ok, learned} =
             Spectre.turn(restarted, "refund", skill_context: %{"scope" => "support"})

    assert {:reply, "Refund learned for refund", _turn_ref} = learned.observable
  end

  test "recovery rejects a Morph Activation whose dispatch marker contradicts its Definition" do
    fixture = start_fixture(WorkAgent, checkpoint?: true)
    assert {:ok, _revision} = Spectre.flush_checkpoint(fixture.instance)
    :ok = GenServer.stop(fixture.instance, :normal)

    rewrite_checkpoint(fixture.checkpoint_store, fn canonical ->
      {:ok, activation} = Spectre.Instance.Canonical.fetch(canonical, :activation)

      attrs =
        activation
        |> Map.from_struct()
        |> Map.delete(:activation_receipt)
        |> Map.put(:provenance, Map.put(activation.provenance, :change_surface?, false))

      {:ok, tampered} = Spectre.Instance.Activation.build(attrs)
      put_canonical_section(canonical, :activation, tampered)
    end)

    assert_instance_start_error(
      fixture,
      {:restored_activation_change_surface_marker_mismatch, false, true}
    )
  end

  test "recovery rejects a pinned Run whose dispatch marker contradicts its Definition" do
    fixture = start_fixture(WorkAgent, checkpoint?: true)

    assert {:ok, %Turn{observable: {:needs, _request}}} =
             Spectre.turn(fixture.instance, "work")

    assert {:ok, %Turn{observable: {:awaiting, %RunRef{} = work_ref}}} =
             Spectre.turn(fixture.instance, "yes")

    assert {:ok, _revision} = Spectre.flush_checkpoint(fixture.instance)
    :ok = GenServer.stop(fixture.instance, :normal)

    rewrite_checkpoint(fixture.checkpoint_store, fn canonical ->
      {:ok, runs} = Spectre.Instance.Canonical.fetch(canonical, :runs)
      {:ok, run} = runs |> Map.fetch!(work_ref.run_id) |> Spectre.Run.restore()

      tampered = %{
        run
        | metadata: Map.put(run.metadata, :runtime_skill_dispatch?, false)
      }

      {:ok, checkpoint} = Spectre.Run.checkpoint(tampered)
      put_canonical_section(canonical, :runs, Map.put(runs, work_ref.run_id, checkpoint))
    end)

    assert_instance_start_error(
      fixture,
      {:restored_run_invalid, work_ref.run_id, {:run_change_surface_marker_mismatch, false, true}}
    )
  end

  test "real turns require explicit context for a multi-scope Morph and never widen its ceiling" do
    %{instance: instance} = start_fixture(WorkAgent)
    approved = approved_refund_change(instance, 200)
    assert {:ok, _activation} = Morph.activate(approved, now: 203)

    assert {:error, {:runtime_skill_context_required, scopes}} = Spectre.turn(instance, "refund")
    assert MapSet.new(scopes) == MapSet.new(["support", "billing"])

    for scope <- ["support", "billing"] do
      assert {:ok, %Turn{observable: {:reply, "Refund learned for refund", _turn_ref}}} =
               Spectre.turn(instance, "refund", skill_context: %{"scope" => scope})
    end

    assert {:ok, outside} =
             Spectre.turn(instance, "refund", skill_context: %{"scope" => "sales"})

    assert {:no_response, _result} = outside.decision

    assert {:error, {:invalid_runtime_skill_context, [:not, :a, :map]}} =
             Spectre.turn(instance, "refund", skill_context: [:not, :a, :map])
  end

  test "a multi-scope Surface requires an explicit least-authority subset per Skill" do
    %{instance: instance} = start_fixture(WorkAgent)

    assert %Morph.Change{
             error: {:morph_skill_scopes_required, ["billing", "support"]}
           } =
             instance
             |> Morph.change(by: "actor:author", reason: "Do not infer a broad scope grant")
             |> Morph.mount_skill("refunds", match: "refund", reply: "billing only")

    approved =
      instance
      |> Morph.change(by: "actor:author", reason: "Grant the narrow billing scope")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "Billing refund for {{input.text}}",
        scopes: [:billing]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 230)
      |> Morph.approve(by: "actor:reviewer", now: 231)

    assert approved.error == nil
    assert approved.delta.passed
    assert {:ok, _activation} = Morph.activate(approved, now: 232)

    assert {:ok, support_turn} =
             Spectre.turn(instance, "refund", skill_context: %{"scope" => "support"})

    assert {:no_response, _result} = support_turn.decision

    assert {:ok, %Turn{observable: {:reply, "Billing refund for refund", _turn_ref}}} =
             Spectre.turn(instance, "refund", skill_context: %{"scope" => "billing"})
  end

  test "disable is rejected when the removed input still routes in a sibling Surface scope" do
    %{instance: instance} = start_fixture(WorkAgent)

    installed =
      instance
      |> Morph.change(by: "actor:author", reason: "Install scoped sibling Skills")
      |> Morph.mount_skill("support-status",
        match: "status",
        reply: "support status",
        scopes: [:support]
      )
      |> Morph.mount_skill("billing-status",
        match: "status",
        reply: "billing status",
        scopes: [:billing]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 240)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 241)

    assert installed.error == nil
    assert {:ok, _activation} = Morph.activate(installed, now: 242)

    disabled =
      instance
      |> Morph.change(by: "actor:author", reason: "Disable support only")
      |> Morph.disable_skill("support-status")
      |> Morph.evaluate(cases: @protected_cases, now: 243)

    assert disabled.error == nil
    assert disabled.state == :rejected
    refute disabled.delta.passed

    assert {:ok, support_turn} =
             Spectre.turn(instance, "status", skill_context: %{"scope" => "support"})

    assert %Turn{observable: {:reply, "support status", _turn_ref}} = support_turn

    assert {:ok, %Turn{observable: {:reply, "billing status", _turn_ref}}} =
             Spectre.turn(instance, "status", skill_context: %{"scope" => "billing"})
  end

  test "a queued Turn executes the Definition selected at admission across a concurrent activation" do
    %{instance: instance} = start_fixture(WorkAgent)

    old =
      instance
      |> Morph.change(by: "actor:author", reason: "Install the old answer")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "OLD {{input.text}}",
        scopes: [:support, :billing]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 250)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 251)

    assert {:ok, activation_a} = Morph.activate(old, now: 252)

    replacement =
      instance
      |> Morph.change(by: "actor:author", reason: "Install the new answer")
      |> Morph.replace_skill("refunds",
        match: "refund",
        reply: "NEW {{input.text}}",
        scopes: [:support, :billing]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 253)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 254)

    test_pid = self()

    blocker =
      Task.async(fn ->
        Spectre.turn(instance, "block",
          block_input?: true,
          test_pid: test_pid,
          skill_context: %{"scope" => "support"}
        )
      end)

    assert_receive {:morph_queue_blocked, worker}, 1_000

    queued =
      Task.async(fn ->
        Spectre.turn(instance, "refund", skill_context: %{"scope" => "support"})
      end)

    assert_eventually_ready(instance)
    assert {:ok, activation_b} = Morph.activate(replacement, now: 255)
    send(worker, :release_morph_queue)

    assert {:ok, _block_turn} = Task.await(blocker, 2_000)
    assert {:ok, queued_turn} = Task.await(queued, 2_000)
    assert {:reply, "OLD refund", _turn_ref} = queued_turn.observable
    assert {:reply, queued_result} = queued_turn.decision

    assert get_in(queued_result.metadata, [:runtime_skill, :agent_definition_ref]) ==
             to_string(activation_a.definition_ref)

    assert_eventually_quiescent(instance)

    assert {:ok, fresh_turn} =
             Spectre.turn(instance, "refund", skill_context: %{"scope" => "billing"})

    assert {:reply, "NEW refund", _turn_ref} = fresh_turn.observable
    assert {:reply, fresh_result} = fresh_turn.decision

    assert get_in(fresh_result.metadata, [:runtime_skill, :agent_definition_ref]) ==
             to_string(activation_b.definition_ref)
  end

  test "a runtime exact route conflicting with compiled behavior is rejected before activation" do
    %{instance: instance} = start_fixture(ConflictAgent)

    reviewed =
      instance
      |> Morph.change(by: "actor:author", reason: "Propose a deliberately colliding route")
      |> Morph.mount_skill("runtime-refund", match: "refund", reply: "runtime refund")
      |> Morph.evaluate(cases: @protected_cases, now: 300)

    assert reviewed.state == :rejected
    refute reviewed.delta.passed
    assert reviewed.error == nil

    assert {:error, {:morph_state, :approved, :rejected}} = Morph.activate(reviewed, now: 302)

    assert {:ok, %Turn{observable: {:reply, _compiled_output, _turn_ref}}} =
             Spectre.turn(instance, "refund")
  end

  test "a Morph prompt cap intersects a narrower Manifest authority without widening it" do
    %{instance: instance} = start_fixture(WorkAgent, authority_tokens: 256)

    approved =
      instance
      |> Morph.change(by: "actor:author", reason: "Use only the granted prompt slice")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "Bounded refund for {{input.text}}",
        token_cap: 128,
        scopes: [:support]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 350)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 351)

    assert approved.error == nil
    assert approved.delta.passed
    assert {:ok, _activation} = Morph.activate(approved, now: 352)

    assert {:ok, %Turn{observable: {:reply, "Bounded refund for refund", _turn_ref}}} =
             Spectre.turn(instance, "refund", skill_context: %{"scope" => "support"})
  end

  test "Morph never attests a candidate input that the real turn boundary rejects" do
    %{instance: instance} = start_fixture(InputBoundAgent)

    reviewed =
      instance
      |> Morph.change(by: "actor:author", reason: "Propose an input beyond the Agent cap")
      |> Morph.mount_skill("refunds", match: "refund", reply: "bounded")
      |> Morph.evaluate(
        cases: [
          %{
            "id" => "short-input",
            "input" => "ok",
            "expected_outcome" => "clarify",
            "llm" => "forbidden"
          }
        ],
        now: 360
      )

    assert reviewed.error == {:payload_too_large, :input, 6, 4}
    assert reviewed.state == :draft
    assert {:error, {:payload_too_large, :input, 6, 4}} = Spectre.turn(instance, "refund")
  end

  defp approved_refund_change(instance, now) do
    instance
    |> Morph.change(by: "actor:author", reason: "Teach a governed refund response")
    |> Morph.mount_skill("refunds",
      match: "refund",
      reply: "Refund learned for {{input.text}}",
      scopes: [:support, :billing]
    )
    |> Morph.evaluate(cases: @protected_cases, now: now)
    |> Morph.approve(by: "actor:reviewer", mode: :human, now: now + 1)
  end

  defp start_fixture(agent, opts \\ []) do
    definition_server = start_linked_agent(%{})
    store_id = "morph-runtime-#{System.unique_integer([:positive, :monotonic])}"
    definition_store = {DefinitionStore, server: definition_server, id: store_id}

    checkpoint_store =
      if Keyword.get(opts, :checkpoint?, false) do
        {CheckpointStore, server: start_linked_agent(%{})}
      end

    canonical = Definition.canonical!(agent)

    manifest =
      Manifest.new!(
        canonical,
        authority(Keyword.get(opts, :authority_tokens, 1_024)),
        closure(agent)
      )

    assert {:ok, _publication} = Store.publish(definition_store, canonical, manifest)

    assert {:ok, bootstrap} =
             Resolver.bootstrap_candidate(definition_store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    subject = Subject.new("morph-runtime-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_instance(agent, subject, definition_store, checkpoint_store: checkpoint_store)

    assert {:ok, activation} = Spectre.activate(instance, bootstrap, expected_generation: 0)

    %{
      agent: agent,
      subject: subject,
      store: definition_store,
      checkpoint_store: checkpoint_store,
      instance: instance,
      definition_ref: activation.definition_ref
    }
  end

  defp restart_fixture(fixture) do
    start_instance(fixture.agent, fixture.subject, fixture.store,
      checkpoint_store: fixture.checkpoint_store
    )
  end

  defp assert_instance_start_error(fixture, expected) do
    opts = [
      agent: fixture.agent,
      subject: fixture.subject,
      definition_store: fixture.store,
      checkpoint_store: fixture.checkpoint_store,
      idle: false,
      opts: [checker_versions: Declarative.checker_versions()]
    ]

    previous_trap = Process.flag(:trap_exit, true)

    try do
      assert {:error, ^expected} = Instance.start_link(opts)
    after
      Process.flag(:trap_exit, previous_trap)
    end
  end

  defp rewrite_checkpoint({CheckpointStore, opts}, rewrite) do
    server = Keyword.fetch!(opts, :server)

    Agent.update(server, fn entries ->
      Map.new(entries, fn {key, {revision, encoded}} ->
        canonical = Spectre.Instance.Canonical.Codec.decode!(encoded)

        {:ok, rewritten} =
          canonical |> rewrite.() |> Spectre.Instance.Canonical.Codec.encode_json()

        {key, {revision, rewritten}}
      end)
    end)
  end

  defp put_canonical_section(canonical, name, value) do
    section = Map.fetch!(canonical.sections, name)
    sections = Map.put(canonical.sections, name, %{section | value: value})
    %{canonical | sections: sections}
  end

  defp start_instance(agent, subject, definition_store, opts) do
    instance_opts = [
      agent: agent,
      subject: subject,
      definition_store: definition_store,
      idle: false,
      opts: [checker_versions: Declarative.checker_versions()]
    ]

    instance_opts =
      case Keyword.get(opts, :checkpoint_store) do
        nil -> instance_opts
        checkpoint_store -> Keyword.put(instance_opts, :checkpoint_store, checkpoint_store)
      end

    {:ok, instance} = Instance.start_link(instance_opts)
    Process.unlink(instance)
    on_exit(fn -> if Process.alive?(instance), do: GenServer.stop(instance) end)
    instance
  end

  defp authority(max_tokens) do
    Envelope.new!(
      open_capabilities: [
        Spectre.Skill.Runtime.capability(:mount),
        Spectre.Skill.Runtime.capability(:replace),
        Spectre.Skill.Runtime.capability(:disable)
      ],
      prompt_budget_classes: [:small, :standard],
      limits: %{max_tokens: max_tokens}
    )
  end

  defp closure(agent) do
    {:ok, build_digest} = Closure.fingerprint(agent)

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
      build_fingerprints: %{("beam:" <> Atom.to_string(agent)) => build_digest},
      evaluation_corpus_digest: EvaluationDelta.protected_corpus_digest!(@protected_cases),
      compatibility_mode: :native_v2
    })
  end

  defp start_linked_agent(initial) do
    {:ok, server} = Agent.start_link(fn -> initial end)
    Process.unlink(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp assert_eventually_quiescent(instance, attempts \\ 100)

  defp assert_eventually_quiescent(instance, attempts) when attempts > 0 do
    info = Instance.info(instance)

    if is_nil(info.active_run) and info.ready == [] do
      :ok
    else
      Process.sleep(5)
      assert_eventually_quiescent(instance, attempts - 1)
    end
  end

  defp assert_eventually_quiescent(instance, 0) do
    flunk("Instance did not quiesce: #{inspect(Instance.info(instance))}")
  end

  defp assert_eventually_ready(instance, attempts \\ 100)

  defp assert_eventually_ready(instance, attempts) when attempts > 0 do
    if Instance.info(instance).ready == [] do
      Process.sleep(5)
      assert_eventually_ready(instance, attempts - 1)
    else
      :ok
    end
  end

  defp assert_eventually_ready(instance, 0) do
    flunk("Turn was not queued: #{inspect(Instance.info(instance))}")
  end
end
