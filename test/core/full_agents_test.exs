defmodule Spectre.Core.FullAgentsTest do
  use Spectre.Test.FullAgentCase, async: false

  alias Spectre.{Audit, Instance, Ledger, Portable}
  alias Spectre.Test.FullAgentCase.{MultiSkillAgent, PlainAgent, StatelessMind}
  alias Spectre.V04Test.Runtime

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
    refute pid == c.instance
    refute pid == c.fixture.server
    assert opts[:definition_ref] == c.definition.ref
    assert opts[:state_revision] == 0
    assert is_nil(turn.context.seal)
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert {:ok, result} = Instance.propose(c.instance, candidate)
    assert_success(c, result)
  end

  test "public scoped operations ask narrow questions without requesting the full projection",
       c do
    server = c.fixture.server
    assert 1 = :erlang.trace(server, true, [:receive])

    try do
      assert {:error, {:presentation_not_found, "missing"}} =
               Spectre.show_presentation(c.scope, "missing", %{})

      assert {:error, {:mandate_not_found, "missing"}} =
               Spectre.revoke_mandate(c.scope, "missing", %{})

      assert {:error, {:late_observation_attempt_not_found, "missing"}} =
               Spectre.record_late_observation(c.scope, "missing", %{})

      assert {:error, {:outcome_act_not_found, "missing"}} =
               Spectre.record_outcome(c.scope, %{
                 act_ref: "missing",
                 attempt_ref: "missing",
                 status: :succeeded,
                 evidence_refs: ["receipt"],
                 observed_at: Runtime.now(),
                 details_ref: "late"
               })

      target = Portable.content_ref!(:payload, "not recorded")

      assert {:error, {:erasable_payload_not_referenced, ^target}} =
               Spectre.request_erasure(
                 c.scope,
                 %{target_ref: target, reason: "delete", requested_at: Runtime.now()},
                 %{}
               )

      barrier = :erlang.trace_delivered(server)
      assert_receive {:trace_delivered, ^server, ^barrier}, 1_000
      refute_received {:trace, ^server, :receive, {:"$gen_call", _, {:scope_projection, _}}}
      refute_received {:trace, ^server, :receive, {:"$gen_call", _, :projection}}

      for kind <- [:presentation, :mandate, :late_observation, :outcome_scope] do
        assert_received {:trace, ^server, :receive,
                         {:"$gen_call", _, {:query, _, {^kind, "missing"}}}}
      end

      assert_received {:trace, ^server, :receive,
                       {:"$gen_call", _, {:query, _, {:erasure_candidate, _, _}}}}
    after
      :erlang.trace(server, false, [:receive])
    end
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

  test "an application identity beginning with fallback is still entitled to its declared refusal policy",
       c do
    assert {:ok, %{candidates: [candidate]}} =
             turn(c, "refund", identity: "fallback:customer-request", amount: 10_001)

    assert {:ok, result} = Instance.propose(c.instance, candidate)
    assert result.primary.decision.outcome == :refused
    assert result.fallback == :silence
    assert result.primary.act == nil
    assert balance(c).spent == 0
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
end
