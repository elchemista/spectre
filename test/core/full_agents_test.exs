defmodule Spectre.Core.FullAgentsTest do
  use ExUnit.Case, async: false

  alias Spectre.{
    Agent,
    Audit,
    Candidate,
    Consent,
    Definition,
    Evidence,
    Instance,
    Label,
    Ledger,
    Mind,
    Portable,
    Presentation
  }

  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Duty.EvidenceCause
  alias Spectre.Erasure.Analysis
  alias Spectre.Mind.Turn
  alias Spectre.V04Test.{Fixture, Ingress, Runtime}

  defmodule PaymentSkill do
    use Spectre.Skill, namespace: "full-agent", name: "payment", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule ManualSkill do
    use Spectre.Skill, namespace: "full-agent", name: "manual", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule PlainAgent do
    use Spectre.Agent, namespace: "full-agent", name: "plain", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule SkilledAgent do
    use Spectre.Agent, namespace: "full-agent", name: "skilled", revision: 1, declared_at: 0
    install(PaymentSkill, as: "payment")
  end

  defmodule MultiSkillAgent do
    use Spectre.Agent, namespace: "full-agent", name: "multi", revision: 1, declared_at: 0
    install(PaymentSkill, as: "payment")
    install(ManualSkill, as: "manual")
  end

  # Application routing stays outside the kernel. The same Mind can use a
  # portable declaration built directly or composed from Skills.
  defmodule Deliberation do
    def run(turn, opts) do
      send(Keyword.fetch!(opts, :observer), {:deliberation, self(), turn, opts})

      case Keyword.get(opts, :behavior, :normal) do
        :raise -> raise "private-mind-diagnostic"
        :throw -> throw(:private_mind_diagnostic)
        :exit -> exit(:private_mind_diagnostic)
        :error -> {:error, :application_declined}
        :malformed -> {:ok, :not_a_candidate}
        :normal -> route(turn, opts)
      end
    end

    defp route(turn, opts) do
      input = Enum.max_by(turn.evidence, &{&1.observed_at, &1.ref})

      case input.payload["command"] do
        "refund" -> propose(turn, Keyword.fetch!(opts, :template), opts)
        "manual" -> propose(turn, "manual/refund", opts)
        _unknown -> {:ok, []}
      end
    end

    defp propose(turn, template, opts) do
      attrs = Keyword.fetch!(opts, :candidate_attrs)
      disclosure = Map.put(attrs.disclosure, :source_evidence_refs, Turn.evidence_refs(turn))
      attrs = Map.put(attrs, :disclosure, disclosure)
      Agent.candidate(Keyword.fetch!(opts, :definition), template, turn, attrs)
    end
  end

  defmodule StatelessMind do
    @behaviour Spectre.Mind
    @impl true
    def ref, do: "mind:full-agent:stateless"
    @impl true
    defdelegate deliberate(turn, opts), to: Deliberation, as: :run
  end

  defmodule StatefulMind do
    @behaviour Spectre.Mind
    @impl true
    def ref, do: "mind:full-agent:stateful"
    @impl true
    defdelegate deliberate(turn, opts), to: Deliberation, as: :run
    @impl true
    def deliberate(turn, state, opts) do
      with {:ok, proposals} <- Deliberation.run(turn, opts), do: {:ok, proposals, state + 1}
    end
  end

  defmodule RecordingExecutor do
    @behaviour Spectre.Attempt.Executor
    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor

    @impl true
    def execute(act, attempt, capability, opts) do
      projection = Sequencer.projection(Keyword.fetch!(opts, :domain))

      send(
        Keyword.fetch!(opts, :observer),
        {:execution,
         %{
           act: act,
           attempt: attempt,
           capability: capability,
           attempt_durable: projection.attempts[attempt.ref] == attempt,
           pending: MapSet.member?(projection.pending_dispatches, act.ref)
         }}
      )

      case Keyword.fetch!(opts, :behavior) do
        :raise -> raise "private-executor-diagnostic"
        :malformed -> {:ok, %{raw_provider_response: capability}}
        status -> outcome(act, attempt, status)
      end
    end

    defp outcome(act, attempt, status) do
      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(), payload: "receipt")

      metadata = %{evidence: [evidence], details_ref: "receipt:full-agent"}
      if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end
  end

  defmodule Payloads do
    @behaviour Spectre.Payload.Store

    @impl true
    def verify(ref, opts) do
      case :ets.lookup(Keyword.fetch!(opts, :table), ref) do
        [] ->
          {:error, :not_found}

        [{^ref, value}] ->
          if Portable.content_ref!(:payload, value) == ref,
            do: :ok,
            else: {:error, :digest_mismatch}
      end
    end
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    authoring = Map.get(tags, :authoring, SkilledAgent)
    definition = authoring.definition()
    template = definition.body["candidates"] |> Map.values() |> hd()
    body = Map.put(definition.body, "candidates", %{"updated/refund" => template})
    {:ok, successor} = Definition.revise(definition, body, Runtime.now())
    mind = Map.get(tags, :mind, StatefulMind)
    namespace = "full-agent-#{System.unique_integer([:positive])}"
    ref = "v0.4:#{namespace}:domain"
    name = {:via, Registry, {Spectre.Domain.Registry, ref}}
    capability = {:host_payment_session, make_ref()}
    payload_table = :ets.new(__MODULE__, [:set, :public])
    payload_store = if tags[:external_payloads], do: {Payloads, table: payload_table}

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: name,
        mind: mind,
        consent: Map.get(tags, :consent, false),
        payload_store: payload_store,
        governance_allowed: true,
        emergency_mandate: Map.get(tags, :emergency_mandate, false),
        constitution_overrides: Map.get(tags, :constitution_overrides, %{}),
        duty_rules: Map.get(tags, :duty_rules, %{}),
        revocation_mode: Map.get(tags, :revocation_mode, :cascade),
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref, successor.ref],
        capability: capability,
        executors: [
          {RecordingExecutor,
           domain: name, observer: self(), behavior: Map.get(tags, :executor, :succeeded)}
        ]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    assert {:ok, domain} = Spectre.lookup_domain(ref)
    assert {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

    assert {:ok, admin} =
             Spectre.resume_scope(
               domain,
               Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
             )

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(admin, definition,
               identity_key: "publish-definition",
               requested_mandate_ref: fixture.governance_mandate.ref,
               accountable_ref: fixture.refs.accountable,
               purpose_ref: fixture.refs.purpose,
               purpose_params: %{"currency" => "EUR"}
             )

    instance =
      start_supervised!({Instance, scope: scope, definition_ref: definition.ref, state: 0})

    %{
      fixture: fixture,
      admin: admin,
      scope: scope,
      instance: instance,
      definition: definition,
      successor: successor,
      capability: capability,
      payload_table: payload_table,
      template: if(authoring == PlainAgent, do: "refund", else: "payment/refund")
    }
  end

  @tag authoring: PlainAgent, mind: StatelessMind
  test "an Agent without Skills completes ingress, deliberation and execution", c do
    assert {:ok, %{candidates: [candidate], evidence: [input]}} = turn(c, "refund")
    assert candidate.evidence_refs == [input.ref]
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert {:ok, result} = Instance.propose(c.instance, candidate)
    assert_success(c, result)
  end

  test "an Agent with a Skill exposes its exact Definition and advances local Mind state", c do
    assert {:ok, %{candidates: [candidate], turn: turn}} = turn(c, "refund")
    assert_receive {:deliberation, pid, ^turn, opts}
    assert pid == c.instance
    refute pid == c.fixture.server
    assert opts[:definition_ref] == c.definition.ref
    assert opts[:state_revision] == 0
    assert is_nil(turn.context.seal)
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert {:ok, result} = Instance.propose(c.instance, candidate)
    assert_success(c, result)
  end

  @tag authoring: MultiSkillAgent
  test "two Skills with the same local name are independently routable through namespaces", c do
    assert {:ok, %{candidates: [automatic]}} = turn(c, "refund", identity: "automatic")
    assert {:ok, first} = Instance.propose(c.instance, automatic)
    assert_success(c, first)
    Runtime.set_time(Runtime.now() + 1)

    assert {:ok, %{candidates: [manual]}} =
             turn(c, "manual", identity: "manual", context: automatic.evidence_refs)

    assert automatic.identity_key != manual.identity_key
    assert {:ok, second} = Instance.propose(c.instance, manual)
    assert_success(c, second)
    assert Instance.state(c.instance) == %{revision: 2, value: 2}
    assert balance(c).spent == 200
  end

  @tag authoring: PlainAgent, mind: StatelessMind
  test "the same plain Agent works through the public Scope without an Instance", c do
    assert {:ok, %{candidates: [candidate]}} =
             Spectre.turn(c.scope, input(c, "refund"), mind_opts: mind_options(c, []))

    assert {:ok, result} = Spectre.propose(c.scope, candidate)
    assert_success(c, result)
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
  end

  test "an unknown input can complete a local turn without proposing or executing", c do
    before = projection(c)
    assert {:ok, %{candidates: []}} = turn(c, "unrecognized")
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert projection(c).acts == before.acts
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "a Skill does not execute during deliberation", c do
    before = projection(c)
    assert {:ok, %{candidates: [_]}} = turn(c, "refund")
    assert projection(c).acts == before.acts
    assert projection(c).meters == before.meters
    assert projection(c).attempts == %{}
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "a fully configured Skill still cannot spend beyond its Mandate", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", amount: 10_001)

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert balance(c).available == 10_000
    assert balance(c).spent == 0
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "a complete Agent with an absent requested Mandate produces no external effect", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", mandate: "mandate:absent")

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert projection(c).attempts == %{}
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "a wildcard payment observation cannot authorize a Skill's refund", c do
    forged_input = Map.put(input(c, "refund"), :bindings, %{"order_ref" => :any})

    assert {:ok, %{candidates: [candidate]}} =
             Instance.turn(c.instance, forged_input,
               mind_opts: mind_options(c, identity: "wildcard-payment")
             )

    before = projection(c)

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert projection(c).acts == before.acts
    assert projection(c).attempts == %{}
    assert projection(c).meters == before.meters
    refute_received {:execution, _}

    # A real observation still admits through the same Scope, Skill and host
    # configuration. The rejection above must be factual, not a broken setup.
    assert {:ok, %{candidates: [valid]}} = turn(c, "refund", identity: "exact-payment")
    assert {:ok, result} = Instance.propose(c.instance, valid)
    assert_success(c, result)
  end

  test "repeated public proposals recover the result without invoking the executor twice", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
    assert {:ok, result} = Instance.propose(c.instance, candidate)
    assert_success(c, result)
    before = projection(c)
    assert {:ok, ^result} = Instance.propose(c.instance, candidate)
    assert projection(c) == before
    refute_received {:execution, _}
  end

  @tag executor: :definitive_no_effect
  test "a complete Agent releases funds only on definitive no-effect Evidence", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
    assert {:ok, %{primary: primary}} = Instance.propose(c.instance, candidate)
    assert primary.outcome.status == :definitive_no_effect
    assert_receive {:execution, %{attempt_durable: true, pending: false}}
    assert balance(c).available == 10_000
    assert balance(c).spent == 0
    assert balance(c).suspended == 0
    assert_replay(c)
  end

  @tag executor: :failed
  test "a failed execution is not mistaken for definitive no-effect and cannot refund its budget",
       c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
    assert {:ok, %{primary: primary}} = Instance.propose(c.instance, candidate)
    assert primary.outcome.status == :failed
    assert_receive {:execution, %{attempt_durable: true, pending: false}}
    assert balance(c).available == 9_900
    assert balance(c).spent == 100
    assert balance(c).reserved == 0
    assert_replay(c)
  end

  @tag mind: nil
  test "an Instance without a configured Mind cannot silently select or run an application module",
       c do
    before = projection(c)
    assert {:error, :mind_not_configured} = turn(c, "refund")
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c) == before
    assert {:ok, definition} = Instance.definition(c.instance)
    assert definition == c.definition
    refute_received {:deliberation, _, _, _}
    refute_received {:execution, _}
    assert_replay(c)
  end

  for behavior <- [:raise, :malformed] do
    @tag executor: behavior
    test "executor #{behavior} leaves ambiguity durable and cannot trigger a retry", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.outcome.status == :ambiguous
      assert_receive {:execution, %{attempt_durable: true, pending: false}}
      assert balance(c).suspended == 100
      assert map_size(projection(c).duties) == 1
      assert {:ok, ^result} = Instance.propose(c.instance, candidate)
      refute_received {:execution, _}
      refute inspect(result) =~ "private-executor-diagnostic"
      refute inspect(result) =~ inspect(c.capability)
      assert_replay(c)
    end
  end

  for behavior <- [:raise, :throw, :exit, :error, :malformed] do
    test "Mind #{behavior} preserves Instance state and never reaches execution", c do
      before = projection(c)
      assert {:error, reason} = turn(c, "refund", behavior: unquote(behavior))
      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert Process.alive?(c.instance)
      assert projection(c).acts == before.acts
      assert projection(c).attempts == %{}
      refute inspect(reason) =~ "private-mind-diagnostic"
      refute_received {:execution, _}
      assert {:ok, %{candidates: [_]}} = turn(c, "refund")
      assert Instance.state(c.instance) == %{revision: 1, value: 1}
      assert_replay(c)
    end
  end

  test "a malformed ingress input never invokes the Mind or advances Instance state", c do
    before = projection(c)
    assert {:error, _} = Instance.turn(c.instance, :invalid, mind_opts: mind_options(c, []))
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c) == before
    refute_received {:deliberation, _, _, _}
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "two Instances share the Domain but never share their local Mind state", c do
    other =
      start_supervised!({Instance, scope: c.scope, definition_ref: c.definition.ref, state: 20},
        id: :second
      )

    assert {:ok, %{candidates: [left]}} = turn(c, "refund", identity: "left")

    assert {:ok, %{candidates: [right]}} =
             turn(%{c | instance: other}, "refund", identity: "right")

    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert Instance.state(other) == %{revision: 1, value: 21}
    assert {:ok, first} = Instance.propose(c.instance, left)
    assert_success(c, first)
    assert {:ok, second} = Instance.propose(other, right)
    assert_success(c, second)
    assert balance(c).spent == 200
  end

  test "creating another Instance does not duplicate the shared Mandate budget", c do
    other =
      start_supervised!({Instance, scope: c.scope, definition_ref: c.definition.ref, state: 0},
        id: :second
      )

    assert {:ok, %{candidates: [first]}} = turn(c, "refund", amount: 9_000, identity: "large")
    assert {:ok, result} = Instance.propose(c.instance, first)
    assert_success(c, result)

    assert {:ok, %{candidates: [second]}} =
             turn(%{c | instance: other}, "refund", amount: 2_000, identity: "overdraft")

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             Instance.propose(other, second)

    assert balance(c).spent == 9_000
    assert balance(c).available == 1_000
    assert map_size(projection(c).attempts) == 1
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "concurrent complete turns serialize local state and cannot overspend the Domain", c do
    parent = self()

    tasks =
      for id <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              with {:ok, %{candidates: [candidate]}} <-
                     turn(c, "refund", amount: 2_000, identity: "concurrent:#{id}"),
                   do: Instance.propose(c.instance, candidate)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)
    assert length(results) == 8
    assert Enum.all?(results, &match?({:ok, _}, &1))

    assert Enum.count(results, &match?({:ok, %{primary: %{decision: %{outcome: :admitted}}}}, &1)) ==
             5

    assert Enum.count(
             results,
             &match?({:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}}, &1)
           ) == 3

    assert Instance.state(c.instance) == %{revision: 8, value: 8}
    assert balance(c).available == 0
    assert balance(c).spent == 10_000
    assert map_size(projection(c).attempts) == 5
    for _ <- 1..5, do: assert_receive({:execution, %{attempt_durable: true, pending: false}})
    refute_received {:execution, _}
    assert_replay(c)
  end

  @tag authoring: MultiSkillAgent
  test "a proposal that omits newly available recognition Evidence cannot execute", c do
    assert {:ok, %{candidates: [old]}} = turn(c, "refund", identity: "old")
    assert {:ok, %{evidence: [new]}} = turn(c, "manual", identity: "new")
    assert {:ok, %{primary: %{decision: decision, act: nil}}} = Instance.propose(c.instance, old)
    assert decision.outcome == :undecidable

    assert {:evidence_condition_undecidable, {:recognition_basis_not_declared, [new.ref]}} in decision.reasons

    assert projection(c).attempts == %{}
    assert balance(c).available == 10_000
    refute_received {:execution, _}
    assert_replay(c)
  end

  test "routing to an uninstalled Skill fails without changing local state or executing", c do
    before = projection(c)
    assert {:error, {:unknown_candidate_template, "manual/refund"}} = turn(c, "manual")
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c).acts == before.acts
    assert projection(c).attempts == %{}
    refute_received {:execution, _}
    assert_replay(c)
  end

  @tag executor: :raise
  test "stopping an agent cannot release its suspended quantity or erase its open Duty", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

    assert {:ok, %{primary: %{outcome: %{status: :ambiguous}}}} =
             Instance.propose(c.instance, candidate)

    assert_receive {:execution, _}
    before = projection(c)
    assert balance(c).suspended == 100
    assert map_size(before.duties) == 1
    GenServer.stop(c.instance)
    refute Process.alive?(c.instance)
    assert projection(c) == before
    assert_replay(c)
  end

  test "Domain loss stops the complete agent instead of leaving an unusable zombie", c do
    assert {:ok, %{candidates: [_]}} = turn(c, "refund")
    monitor = Process.monitor(c.instance)
    GenServer.stop(c.fixture.server)
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, {:domain_down, :normal}}}
    refute Process.alive?(c.instance)
    refute_received {:execution, _}
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end

  for provenance <- [:derived, :generated] do
    test "a full agent records #{provenance} Evidence with exact Turn lineage and no authority",
         c do
      assert {:ok, %{turn: turn, candidates: []}} = turn(c, "idle")
      before = projection(c)

      assert {:ok, evidence} =
               Mind.evidence(turn, Runtime.now(),
                 proposition: "agent.finding",
                 provenance: unquote(provenance),
                 payload: "finding"
               )

      assert evidence.source_ref == StatefulMind.ref()
      assert evidence.issuer_ref == StatefulMind.ref()
      assert evidence.parent_refs == Turn.evidence_refs(turn)
      assert evidence.provenance == unquote(provenance)
      assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
      assert projection(c).evidence[evidence.ref] == evidence
      assert projection(c).acts == before.acts
      assert projection(c).mandates == before.mandates
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  test "a Mind cannot relabel its generated conclusion as an observed fact", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")
    before = projection(c)

    assert {:error, {:invalid_mind_evidence_provenance, :observed}} =
             Mind.evidence(turn, Runtime.now(),
               proposition: "agent.finding",
               provenance: :observed
             )

    assert projection(c) == before
    assert_replay(c)
  end

  test "recording the same Mind derivation twice is idempotent", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, evidence} =
             Mind.evidence(turn, Runtime.now(), proposition: "agent.finding", payload: "finding")

    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    before = projection(c)
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    assert projection(c) == before
    assert_replay(c)
  end

  for {field, value} <- [
        source_ref: "foreign:mind",
        issuer_ref: "foreign:issuer",
        parent_refs: ["evidence:outside-turn"]
      ] do
    test "recomputing a derivation ref cannot forge its #{field} binding", c do
      assert {:ok, %{turn: turn}} = turn(c, "idle")

      assert {:ok, original} =
               Mind.evidence(turn, Runtime.now(),
                 proposition: "agent.finding",
                 payload: "finding"
               )

      assert {:ok, forged} = replace_evidence(original, unquote(field), unquote(value))
      refute forged.ref == original.ref
      before = projection(c)
      assert {:error, _} = Spectre.record_derivation(c.scope, turn, forged)
      assert projection(c) == before
      assert {:ok, ^original} = Spectre.record_derivation(c.scope, turn, original)
      assert_replay(c)
    end
  end

  test "a generated result cannot discard labels inherited from private input", c do
    assert {:ok, label} = Label.new(owner_ref: "owner:customer", value: "private")
    private_input = Map.put(input(c, "idle"), :labels, [label])

    assert {:ok, %{turn: turn, candidates: []}} =
             Instance.turn(c.instance, private_input, mind_opts: mind_options(c, []))

    assert {:ok, original} =
             Mind.evidence(turn, Runtime.now(),
               proposition: "private.finding",
               payload: "private"
             )

    assert original.labels == [label]
    assert {:ok, forged} = replace_evidence(original, :labels, [])
    before = projection(c)
    assert {:error, _} = Spectre.record_derivation(c.scope, turn, forged)
    assert projection(c) == before
    assert {:ok, ^original} = Spectre.record_derivation(c.scope, turn, original)
    assert_replay(c)
  end

  test "a derivation cannot replace its authenticated Scope binding", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, original} =
             Mind.evidence(turn, Runtime.now(), proposition: "agent.finding", payload: "finding")

    bindings = Map.put(original.bindings, "scope_ref", "foreign:scope")
    assert {:ok, forged} = replace_evidence(original, :bindings, bindings)
    before = projection(c)
    assert {:error, _} = Spectre.record_derivation(c.scope, turn, forged)
    assert projection(c) == before
    assert {:ok, ^original} = Spectre.record_derivation(c.scope, turn, original)
    assert_replay(c)
  end

  test "a conclusion cannot claim observation before its generating Turn", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:error, {:mind_derivation_precedes_turn, _}} =
             Mind.evidence(turn, turn.opened_at - 1,
               proposition: "agent.finding",
               payload: "finding"
             )

    assert_replay(c)
  end

  test "a future-dated Mind conclusion cannot be recorded using host-supplied time", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, future} =
             Mind.evidence(turn, Runtime.now() + 1,
               proposition: "agent.finding",
               payload: "finding"
             )

    before = projection(c)

    assert {:error, {:mind_derivation_from_future, _}} =
             Spectre.record_derivation(c.scope, turn, future)

    assert projection(c) == before
    assert_replay(c)
  end

  test "a mutated Turn cannot authenticate a Mind derivation", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, evidence} =
             Mind.evidence(turn, Runtime.now(), proposition: "agent.finding", payload: "finding")

    forged_turn = %{turn | mind_ref: "foreign:mind"}
    before = projection(c)
    assert {:error, _} = Spectre.record_derivation(c.scope, forged_turn, evidence)
    assert projection(c) == before
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    assert_replay(c)
  end

  describe "governed Definition changes with live agents" do
    test "activation does not silently repin an existing Instance", c do
      activate_successor(c)
      assert {:ok, definition} = Instance.definition(c.instance)
      assert definition == c.definition
      assert {:ok, %{candidates: [candidate], turn: turn}} = turn(c, "refund")
      assert_receive {:deliberation, _, ^turn, opts}
      assert opts[:definition_ref] == c.definition.ref
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert_success(c, result)
    end

    test "a fresh Instance can use the successor's template without changing the old one", c do
      activate_successor(c)

      updated =
        start_supervised!({Instance, scope: c.scope, definition_ref: c.successor.ref, state: 20},
          id: :updated
        )

      configured = %{c | instance: updated, definition: c.successor, template: "updated/refund"}
      assert {:ok, %{candidates: [candidate], turn: turn}} = turn(configured, "refund")
      assert_receive {:deliberation, ^updated, ^turn, opts}
      assert opts[:definition_ref] == c.successor.ref
      assert opts[:state_revision] == 0
      assert Instance.state(updated) == %{revision: 1, value: 21}
      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert {:ok, result} = Instance.propose(updated, candidate)
      assert_success(c, result)
    end

    test "a Candidate prepared before activation still needs and uses its original authority",
         c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      activate_successor(c)
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.act.mandate_ref == c.fixture.mandate.ref
      assert_success(c, result)
    end

    test "changing Definition leaves spent budget and historical outcomes untouched", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", amount: 700)
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert_success(c, result)
      before = projection(c)
      activate_successor(c)
      after_activation = projection(c)
      assert after_activation.meters == before.meters
      assert after_activation.outcomes == before.outcomes
      assert after_activation.attempts == before.attempts
      assert after_activation.acts[result.primary.act.ref] == result.primary.act
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "a valid successor does not authorize an agent to activate itself", c do
      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Spectre.revise_definition(c.scope, c.successor, revision_attrs(c))

      assert projection(c).catalog == before.catalog
      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert {:ok, definition} = Instance.definition(c.instance)
      assert definition == c.definition
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "a removed template fails locally without altering application state", c do
      activate_successor(c)
      before = projection(c)
      configured = %{c | definition: c.successor}

      assert {:error, {:unknown_candidate_template, "payment/refund"}} =
               turn(configured, "refund")

      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert projection(c).acts == before.acts
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  describe "retained control over a live agent's Mandate" do
    @describetag revocation_mode: :retained_controller

    test "the controller can revoke without satisfying the agent's payment Condition", c do
      before = projection(c)
      assert before.evidence == %{}

      assert {:ok, %{primary: primary}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      assert primary.decision.outcome == :admitted
      assert primary.act.class == "mandate.revoke"
      assert primary.act.mandate_ref == c.fixture.mandate.ref
      assert primary.attempt == nil
      assert projection(c).meters == before.meters
      assert Map.has_key?(projection(c).revocations, c.fixture.mandate.ref)
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "revocation fences a previously prepared Skill Candidate before any effect", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert projection(c).acts == before.acts
      assert projection(c).attempts == %{}
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "the agent cannot acquire controller authority by naming its own Mandate", c do
      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Spectre.revoke_mandate(c.scope, c.fixture.mandate.ref,
                 identity_key: "agent-revoke"
               )

      assert projection(c).revocations == %{}
      assert projection(c).acts == before.acts

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      refute_received {:execution, _}
      assert_replay(c)
    end

    @tag executor: :raise
    test "revocation cannot erase an ambiguous execution or release its suspended funds", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

      assert {:ok, %{primary: %{outcome: %{status: :ambiguous}}}} =
               Instance.propose(c.instance, candidate)

      assert_receive {:execution, %{attempt_durable: true}}
      before = projection(c)
      assert map_size(before.duties) == 1
      assert balance(c).suspended == 100

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      assert projection(c).duties == before.duties
      assert projection(c).outcomes == before.outcomes
      assert projection(c).attempts == before.attempts
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  defp activate_successor(c) do
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(c.admin, c.successor, revision_attrs(c))

    key = {c.definition.namespace, c.definition.name}
    assert projection(c).catalog.definition_heads[key] == c.successor.ref
  end

  describe "an explicitly bounded emergency agent" do
    @describetag emergency_mandate: true,
                 constitution_overrides: %{"emergency_max_duration_ms" => 601_000}

    test "emergency authority is visible in Genesis and still uses ordinary admission", c do
      assert projection(c).catalog.genesis.emergency_mandate_ref == c.fixture.mandate.ref
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.act.mandate_ref == c.fixture.mandate.ref
      assert_success(c, result)
    end

    test "emergency designation does not bypass its payment Evidence Condition", c do
      forged_input = Map.put(input(c, "refund"), :proposition, "payment.unverified")

      assert {:ok, %{candidates: [candidate]}} =
               Instance.turn(c.instance, forged_input, mind_opts: mind_options(c, []))

      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert projection(c).acts == before.acts
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "emergency designation does not bypass its quantitative ceiling", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", amount: 10_001)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert balance(c).available == 10_000
      assert projection(c).attempts == %{}
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "an expired emergency Mandate cannot dispatch a previously prepared Candidate", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      Runtime.set_time(c.fixture.mandate.expires_at)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert projection(c).attempts == %{}
      assert balance(c).available == 10_000
      refute_received {:execution, _}
      assert_replay(c)
    end

    @tag executor: :raise
    test "an ambiguous emergency effect leaves the same durable debt as an ordinary effect", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

      assert {:ok, %{primary: %{outcome: %{status: :ambiguous}}}} =
               Instance.propose(c.instance, candidate)

      assert_receive {:execution, %{attempt_durable: true}}
      assert balance(c).suspended == 100
      assert [duty] = Map.values(projection(c).duties)
      assert duty.class == :ambiguous_outcome
      assert duty.status == :open
      assert_replay(c)
    end
  end

  defp revision_attrs(c) do
    [
      identity_key: "activate-successor",
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    ]
  end

  describe "application Duty markers from complete agent turns" do
    @describetag duty_rules: %{
                   "app.missing_receipt" => %{
                     "cause_source_refs" => [Spectre.V04Test.Ingress.ref()],
                     "disposition_authority_refs" => [Spectre.V04Test.Executor.executor_ref()],
                     "containment" => %{"retry" => :forbidden}
                   }
                 }

    test "a configured observation opens a visible Duty without granting an Act", c do
      before = projection(c)
      assert {:ok, %{candidates: [], evidence: [evidence]}} = marker_turn(c)
      assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
      assert duty.class == "app.missing_receipt"
      assert duty.accountable == c.fixture.refs.accountable
      assert duty.mandate_ref == c.fixture.mandate.ref
      assert duty.evidence_refs == [evidence.ref]
      assert duty.disposition_authority_refs == [Spectre.V04Test.Executor.executor_ref()]
      assert duty.containment == %{"retry" => :forbidden}
      assert projection(c).acts == before.acts
      assert projection(c).meters == before.meters
      assert Instance.state(c.instance) == %{value: 1, revision: 1}
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "replaying the same application marker does not manufacture another obligation", c do
      assert {:ok, _} = marker_turn(c)
      before = projection(c)
      assert {:ok, _} = marker_turn(c)
      assert projection(c) == before
      assert map_size(before.duties) == 1
      assert Instance.state(c.instance) == %{value: 2, revision: 2}
      assert_replay(c)
    end

    test "the agent cannot give itself disposition authority inside a marker payload", c do
      input = marker_input(c)
      forged = put_in(input, [:payload, "disposition_authority_refs"], [c.fixture.refs.proposer])
      before = projection(c)
      assert {:error, _} = Instance.turn(c.instance, forged, mind_opts: mind_options(c, []))
      assert projection(c) == before
      assert Instance.state(c.instance) == %{value: 0, revision: 0}
      refute_received {:deliberation, _, _, _}
      assert_replay(c)
    end

    test "authorization of one application Duty class does not permit another", c do
      before = projection(c)
      input = put_in(marker_input(c), [:payload, "class"], "app.unconfigured")
      assert {:error, _} = Instance.turn(c.instance, input, mind_opts: mind_options(c, []))
      assert projection(c) == before
      assert Instance.state(c.instance) == %{value: 0, revision: 0}
      assert_replay(c)
    end

    test "stopping the agent cannot erase an application Duty", c do
      assert {:ok, _} = marker_turn(c)
      before = projection(c)
      GenServer.stop(c.instance, :normal)
      assert projection(c) == before
      assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
      assert duty.class == "app.missing_receipt"
      assert_replay(c)
    end

    test "recovery preserves a no-Act Duty linked to a causal Mandate", c do
      assert {:ok, _} = marker_turn(c)
      before = projection(c)
      assert [duty] = Map.values(before.duties)
      assert duty.act_ref == nil
      assert c.fixture.mandate.ref in duty.conflict_refs
      GenServer.stop(c.fixture.server)
      recovered = Fixture.restart_domain(c.fixture, generation: 8)
      on_exit(fn -> Fixture.stop_process(recovered.server) end)
      assert Sequencer.projection(recovered.server) == before
      assert_replay(%{c | fixture: recovered})
    end

    test "an application marker need not invent a causal Mandate", c do
      input = put_in(marker_input(c), [:payload, "mandate_ref"], nil)
      assert {:ok, _} = Instance.turn(c.instance, input, mind_opts: mind_options(c, []))
      assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
      assert duty.mandate_ref == nil
      assert duty.act_ref == nil
      assert duty.conflict_refs == [c.fixture.refs.accountable]
      assert_replay(c)
    end
  end

  describe "agents requiring consent before refund execution" do
    @describetag consent: true

    setup c do
      data = %{"refund_cents" => 100}
      {:ok, data_digest} = Consent.data_digest(data)

      consent = %{
        schema_version: 1,
        recipient_refs: [c.fixture.refs.proposer],
        data_digest: data_digest,
        cost: 100,
        purpose_ref: c.fixture.refs.purpose,
        purpose_params: %{"currency" => "EUR"},
        risk: "money transfer",
        reversibility: false,
        alternatives: ["cancel"]
      }

      opts =
        Keyword.update!(mind_options(c, []), :candidate_attrs, &Map.put(&1, :consent, consent))

      assert {:ok, %{candidates: [draft]}} =
               Instance.turn(c.instance, input(c, "refund"), mind_opts: opts)

      assert {:ok, presentation} =
               Spectre.prepare_presentation(c.scope, %{
                 candidate_binding_ref: Candidate.presentation_binding_ref(draft),
                 scope_ref: c.fixture.refs.scope,
                 recipient_refs: consent.recipient_refs,
                 approval_source_refs: [Ingress.ref()],
                 data: data,
                 cost: consent.cost,
                 purpose_ref: consent.purpose_ref,
                 purpose_params: consent.purpose_params,
                 risk: consent.risk,
                 reversibility: consent.reversibility,
                 alternatives: consent.alternatives,
                 renderer_ref: "full-agent:renderer",
                 rendered_payload: "Refund 100 cents?",
                 prepared_at: Runtime.now()
               })

      %{draft: draft, presentation: presentation}
    end

    test "preparing a prompt neither displays it nor authorizes the agent's refund", c do
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, []))
      assert result.primary.decision.outcome == :undecidable
      assert result.primary.act == nil
      assert balance(c).available == 10_000
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "successful display alone is not user approval", c do
      show_consent(c)
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, []))
      assert result.primary.decision.outcome == :undecidable
      assert result.primary.act == nil
      assert balance(c).spent == 0
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "the full agent executes only after authenticated approval of the delivered prompt", c do
      show = show_consent(c)
      approval = approve_consent(c, show)
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, [approval.ref]))
      assert result.primary.act.presentation_ref == c.presentation.ref
      assert approval.ref in result.primary.act.recognition_evidence_refs
      assert_success(c, result)
      assert balance(c).spent == 100
      assert map_size(projection(c).attempts) == 2
    end

    test "an explicit rejection leaves the agent unable to execute", c do
      show = show_consent(c)
      rejection = approve_consent(c, show, :contradicts)
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, [rejection.ref]))
      assert result.primary.decision.outcome == :refused
      assert result.primary.act == nil
      assert balance(c).spent == 0
      refute_received {:execution, _}
      assert_replay(c)
    end

    for status <- [:failed, :ambiguous, :definitive_no_effect] do
      @tag executor: status
      test "approval after a #{status} display cannot authorize the agent", c do
        show = show_consent(c, unquote(status))
        approval = consent_response(c, show, :supports)
        before = projection(c)

        assert {:error,
                {:invalid_presentation_approval_evidence, _,
                 :presentation_approval_precedes_successful_show}} =
                 Spectre.observe(c.scope, approval)

        assert projection(c) == before
        assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, []))
        refute result.primary.decision.outcome == :admitted
        assert result.primary.act == nil
        assert balance(c).spent == 0
        refute_received {:execution, _}
        assert_replay(c)
      end
    end

    test "approval is bound to the displayed cost, not merely to the user and order", c do
      show = show_consent(c)
      approval = approve_consent(c, show)
      candidate = consent_candidate(c, [approval.ref])

      {:ok, changed} =
        candidate
        |> Map.from_struct()
        |> Map.drop([:ref, :material_digest])
        |> Map.update!(:consent, &Map.put(&1, "cost", 1000))
        |> Candidate.new()

      assert {:ok, result} = Instance.propose(c.instance, changed)
      assert result.primary.decision.outcome == :undecidable
      assert result.primary.act == nil
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "retrying a consented proposal cannot display or pay a second time", c do
      show = show_consent(c)
      approval = approve_consent(c, show)
      candidate = consent_candidate(c, [approval.ref])
      assert {:ok, first} = Instance.propose(c.instance, candidate)
      assert_success(c, first)
      before = projection(c)
      assert {:ok, repeated} = Instance.propose(c.instance, candidate)
      assert repeated.primary.act == first.primary.act
      assert projection(c) == before
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  defp show_consent(c, status \\ :succeeded) do
    assert {:ok, result} =
             Spectre.show_presentation(c.scope, c.presentation.ref, %{
               identity_key: "full-agent:show",
               requested_mandate_ref: c.fixture.mandate.ref,
               accountable_ref: c.fixture.refs.accountable,
               executor_ref: c.fixture.refs.executor,
               executor_contract_ref: c.fixture.refs.executor_contract,
               subject_refs: [c.fixture.refs.customer],
               evidence_refs: c.draft.evidence_refs,
               observation_window_ms: 5000
             })

    assert result.primary.decision.outcome == :admitted
    assert result.primary.outcome.status == status
    assert_receive {:execution, %{act: %{class: "presentation.show"}, attempt_durable: true}}
    assert balance(c).spent == 0
    Runtime.set_time(Runtime.now() + 1)
    result.primary.act
  end

  defp approve_consent(c, show, stance \\ :supports) do
    approval = consent_response(c, show, stance)
    assert {:ok, [recorded]} = Spectre.observe(c.scope, approval)
    recorded
  end

  defp consent_response(c, show, stance) do
    {:ok, approval} =
      Presentation.response_evidence(
        Fixture.context(c.fixture),
        c.presentation,
        show,
        stance,
        Runtime.now(),
        payload: "user response"
      )

    approval
  end

  defp consent_candidate(c, approvals) do
    {:ok, candidate} =
      c.draft
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:presentation_ref, c.presentation.ref)
      |> Map.put(:evidence_refs, c.draft.evidence_refs ++ approvals)
      |> Candidate.new()

    candidate
  end

  describe "agents using host-managed external payloads" do
    @describetag external_payloads: true

    test "erasure closure preserves the dependency of a refused Decision without an Act", c do
      independent_decisions = Map.keys(projection(c).decisions)
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [evidence]} = Spectre.observe(c.scope, input)
      Runtime.set_time(Runtime.now() + 1)

      assert {:ok, %{candidates: [candidate]}} =
               turn(c, "refund", context: [evidence.ref], amount: 10_001)

      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.decision.outcome == :refused
      assert result.primary.act == nil
      assert evidence.ref in result.primary.decision.recognition_evidence_refs
      assert {:ok, affected} = Analysis.affected_refs(projection(c), ref)
      assert result.primary.decision.ref in affected
      refute Enum.any?(independent_decisions, &(&1 in affected))
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "a Skill-backed agent executes with a verified external receipt in its basis", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [evidence]} = Spectre.observe(c.scope, input)
      Runtime.set_time(Runtime.now() + 1)
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", context: [evidence.ref])
      assert evidence.ref in candidate.evidence_refs
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert_success(c, result)
    end

    test "missing external input is rejected before deliberation or local state changes", c do
      {ref, input} = external_input(c)
      before = projection(c)

      assert {:error, {:payload_not_found, ^ref}} =
               Instance.turn(c.instance, input, mind_opts: mind_options(c, []))

      assert projection(c) == before
      assert Instance.state(c.instance) == %{value: 0, revision: 0}
      refute_received {:deliberation, _, _, _}
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "wrong bytes under the claimed digest cannot enter an agent's context", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "forged receipt"})
      before = projection(c)

      assert {:error, {:payload_verification_failed, ^ref, :digest_mismatch}} =
               Spectre.observe(c.scope, input)

      assert projection(c) == before
      assert_replay(c)
    end

    for change <- [:delete, :corrupt] do
      test "#{change} after deliberation prevents capability release", c do
        {ref, input} = external_input(c)
        :ets.insert(c.payload_table, {ref, "external receipt"})
        assert {:ok, [evidence]} = Spectre.observe(c.scope, input)
        Runtime.set_time(Runtime.now() + 1)
        assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", context: [evidence.ref])

        before = projection(c)
        assert Instance.state(c.instance) == %{value: 1, revision: 1}
        Process.unlink(c.fixture.server)
        domain_monitor = Process.monitor(c.fixture.server)

        case unquote(change) do
          :delete -> :ets.delete(c.payload_table, ref)
          :corrupt -> :ets.insert(c.payload_table, {ref, "substituted receipt"})
        end

        assert {:error, _reason} = Instance.propose(c.instance, candidate)

        assert_receive {:DOWN, ^domain_monitor, :process, _,
                        {:shutdown, {:sequencer_halted, _reason}}}

        assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
        assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
        assert replayed.evidence == before.evidence
        assert map_size(replayed.acts) == map_size(before.acts) + 1
        [admitted] = Enum.reject(Map.values(replayed.acts), &Map.has_key?(before.acts, &1.ref))
        assert admitted.candidate_identity_key == candidate.identity_key
        assert admitted.material_digest == candidate.material_digest
        assert MapSet.member?(replayed.pending_dispatches, admitted.ref)
        account = replayed.meters[c.fixture.mandate.ref][c.fixture.refs.meter]
        assert account.reserved == 100
        assert account.spent == 0
        assert replayed.attempts == %{}
        refute_received {:execution, _}

        # Repair belongs to the host. Restoring the exact bytes permits verified
        # recovery; the old agent must not silently adopt the new generation.
        :ets.insert(c.payload_table, {ref, "external receipt"})
        recovered = Fixture.restart_domain(c.fixture, generation: 8)
        on_exit(fn -> Fixture.stop_process(recovered.server) end)
        assert Sequencer.projection(recovered.server) == replayed
        assert_replay(%{c | fixture: recovered})
      end
    end

    test "restart revalidates live content without duplicating evidence or admissions", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [_evidence]} = Spectre.observe(c.scope, input)
      before = projection(c)
      GenServer.stop(c.fixture.server)
      recovered = Fixture.restart_domain(c.fixture, generation: 8)
      on_exit(fn -> Fixture.stop_process(recovered.server) end)
      assert Sequencer.projection(recovered.server) == before
      assert_replay(%{c | fixture: recovered})
    end

    test "recovery refuses an unexplained loss of a live receipt", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [_evidence]} = Spectre.observe(c.scope, input)
      GenServer.stop(c.fixture.server)
      :ets.delete(c.payload_table, ref)
      # start/1 keeps this deliberately failed recovery from killing the caller.
      assert {:error, {:unexpected_missing_payload, ^ref}} =
               GenServer.start(Sequencer, Keyword.put(c.fixture.sequencer_opts, :generation, 8))
    end
  end

  test "an agent without a configured payload adapter cannot introduce external references", c do
    {ref, input} = external_input(c)
    before = projection(c)
    assert {:error, {:payload_store_required, ^ref}} = Spectre.observe(c.scope, input)
    assert projection(c) == before
    assert_replay(c)
  end

  defp external_input(c) do
    ref = Portable.content_ref!(:payload, "external receipt")
    {ref, Map.merge(input(c, "idle"), %{payload: nil, payload_ref: ref})}
  end

  defp marker_turn(c),
    do: Instance.turn(c.instance, marker_input(c), mind_opts: mind_options(c, []))

  defp marker_input(c) do
    {:ok, cause} =
      EvidenceCause.new(%{
        class: "app.missing_receipt",
        accountable_ref: c.fixture.refs.accountable,
        mandate_ref: c.fixture.mandate.ref,
        missing: [%{"receipt" => "not received"}]
      })

    Map.merge(input(c, "idle"), %{
      proposition: EvidenceCause.proposition(),
      payload: EvidenceCause.canonical(cause)
    })
  end

  defp replace_evidence(evidence, field, value),
    do:
      evidence
      |> Map.from_struct()
      |> Map.put(:ref, nil)
      |> Map.put(field, value)
      |> Evidence.new()

  defp turn(c, command, opts \\ []),
    do:
      Instance.turn(c.instance, input(c, command),
        mind_opts: mind_options(c, opts),
        context_evidence_refs: Keyword.get(opts, :context, [])
      )

  defp input(c, command) do
    c.fixture
    |> Fixture.paid_evidence(payload: %{"command" => command})
    |> Map.from_struct()
    |> Map.delete(:ref)
  end

  defp mind_options(c, opts) do
    attrs =
      c.fixture
      |> Fixture.refund_candidate(Keyword.get(opts, :amount, 100),
        identity_key: Keyword.get(opts, :identity, "full-agent:refund")
      )
      |> Map.drop([:class, :row, :proposer_ref, :scope_ref, :evidence_refs])
      |> Map.put(:requested_mandate_ref, Keyword.get(opts, :mandate, c.fixture.mandate.ref))

    [
      definition: c.definition,
      template: c.template,
      candidate_attrs: attrs,
      observer: self(),
      behavior: Keyword.get(opts, :behavior, :normal)
    ]
  end

  defp projection(c), do: Sequencer.projection(c.fixture.server)
  defp balance(c), do: projection(c).meters[c.fixture.mandate.ref][c.fixture.refs.meter]

  defp assert_success(c, result) do
    assert result.primary.decision.outcome == :admitted
    assert result.primary.outcome.status == :succeeded

    assert_receive {:execution,
                    %{
                      act: act,
                      attempt: attempt,
                      capability: capability,
                      attempt_durable: true,
                      pending: false
                    }}

    assert act == result.primary.act
    assert attempt == result.primary.attempt
    assert capability == c.capability
    refute inspect(result) =~ inspect(capability)
    assert_replay(c)
  end

  defp assert_replay(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, recovered} = Projection.replay(snapshot, c.fixture.constitution)
    assert recovered == projection(c)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
