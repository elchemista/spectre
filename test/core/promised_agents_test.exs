defmodule Spectre.Core.PromisedAgentsTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Condition, Instance, Ledger}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Worker do
    use Spectre.Agent, namespace: "promise-tests", name: "worker", revision: 1, declared_at: 0
  end

  defmodule Mind do
    @behaviour Spectre.Mind
    @impl true
    def ref, do: "mind:promise-tests"
    @impl true
    def deliberate(_turn, _opts), do: {:ok, []}
    @impl true
    def deliberate(_turn, state, _opts), do: {:ok, [], state + 1}
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "promise-agent-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"
    scope_ref = "scope:#{namespace}:work"
    definition = Worker.definition()
    {:ok, scope_row} = Spectre.Row.new(%{write: true, govern: true})

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        mind: Mind,
        governance_allowed: true,
        governance_classes: ["definition.revise", "scope.open"],
        governance_targets: [definition.ref, scope_ref],
        governance_ceiling: scope_row,
        governance_declarations: %{"scope.open" => scope_row}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    assert {:ok, domain} = Spectre.lookup_domain(domain_ref)

    assert {:ok, admin} =
             Spectre.resume_scope(
               domain,
               Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
             )

    candidate_attrs = %{
      identity_key: "open-promise",
      requested_mandate_ref: fixture.governance_mandate.ref,
      accountable_ref: fixture.refs.accountable,
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    }

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(
               admin,
               definition,
               %{candidate_attrs | identity_key: "publish-worker"}
             )

    assert {:ok, context} =
             Spectre.authenticate(domain, scope_ref, %{
               principal_ref: fixture.refs.proposer,
               authentication_ref: "auth:worker",
               session_ref: "session:worker"
             })

    {:ok, condition} =
      Condition.new(%{
        proposition: "job.finished",
        bindings: %{"scope_ref" => scope_ref},
        freshness_ms: Map.get(tags, :freshness_ms),
        cardinality: %{"min" => Map.get(tags, :minimum_proofs, 1), "max" => nil}
      })

    opening_attrs = %{
      kind: Map.get(tags, :kind, :work),
      promise_condition: condition,
      accountable_ref: fixture.refs.accountable,
      disposition_authority_refs: [fixture.refs.executor],
      due_at: Runtime.now() + 60_000
    }

    assert {:ok, scope} = Spectre.open_scope(admin, context, opening_attrs, candidate_attrs)

    instance =
      start_supervised!({Instance, scope: scope, definition_ref: definition.ref, state: 0})

    %{
      fixture: fixture,
      domain: domain,
      admin: admin,
      context: context,
      scope: scope,
      instance: instance,
      condition: condition,
      opening_attrs: opening_attrs,
      candidate_attrs: candidate_attrs,
      due_at: opening_attrs.due_at
    }
  end

  test "Work executes a stateful turn without acquiring a Mandate or Meter", c do
    before = projection(c)
    assert {:ok, %{candidates: []}} = Instance.turn(c.instance, input(c, "job.progress"))
    assert %{revision: 1, value: 1} = Instance.state(c.instance)
    after_turn = projection(c)
    assert after_turn.catalog == before.catalog
    assert after_turn.meters == before.meters
    assert after_turn.acts == before.acts
    assert after_turn.attempts == %{}
    assert after_turn.duties == %{}
    assert_replay(c)
  end

  @tag kind: :vigil
  test "Vigil preserves its governed opening and promise while deliberating", c do
    opening = projection(c).catalog.scopes[c.context.scope_ref]
    assert opening.kind == :vigil
    assert opening.promise_condition == c.condition
    assert projection(c).acts[opening.source_act_ref].class == "scope.open"
    assert {:ok, %{candidates: []}} = Instance.turn(c.instance, input(c, "job.progress"))
    assert projection(c).catalog.scopes[opening.ref] == opening
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "an unmet promise becomes a Duty at the exact deadline, never before", c do
    reconcile(c, c.due_at - 1)
    assert projection(c).duties == %{}
    reconcile(c, c.due_at)
    duty = assert_overdue(c)
    assert duty.opened_at == c.due_at
    assert duty.accountable == c.fixture.refs.accountable
    assert duty.disposition_authority_refs == [c.fixture.refs.executor]
  end

  test "observed completion before the deadline satisfies the promise", c do
    Runtime.set_time(c.due_at - 1)
    assert {:ok, %{candidates: [], evidence: [_]}} = Instance.turn(c.instance, input(c))
    reconcile(c, c.due_at)
    assert projection(c).duties == %{}
    assert_replay(c)
  end

  test "late completion does not erase the overdue Duty", c do
    reconcile(c, c.due_at)
    duty = assert_overdue(c)
    Runtime.set_time(c.due_at + 1)
    assert {:ok, _} = Instance.turn(c.instance, input(c))
    assert {:ok, ^duty} = Projection.duty(projection(c), {:ref, duty.ref})
    assert_replay(c)
  end

  test "completion expiring at the deadline cannot satisfy that deadline", c do
    assert {:ok, _} = Instance.turn(c.instance, Map.put(input(c), :valid_until, c.due_at))
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "provisional completion is not definitive proof", c do
    evidence = Map.merge(input(c), %{provisional: true, valid_until: c.due_at + 1})
    assert {:ok, _} = Instance.turn(c.instance, evidence)
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "a matching proposition in another authenticated Scope cannot close Work", c do
    assert {:ok, [_]} = Spectre.observe(c.admin, input(c))
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "stopping the Instance before the deadline cannot cancel its promise", c do
    GenServer.stop(c.instance, :normal)
    refute Process.alive?(c.instance)
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "duplicate scope-open retry creates no second Act or promise", c do
    before = projection(c)

    assert {:ok, scope} =
             Spectre.open_scope(c.admin, c.context, c.opening_attrs, c.candidate_attrs)

    assert scope == c.scope
    assert projection(c) == before
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "a stale reconciliation message cannot create duplicate debt", c do
    %{reconciliation: {token, _timer}} = :sys.get_state(c.fixture.server)
    reconcile(c, c.due_at)
    duty = assert_overdue(c)
    before = projection(c)
    send(c.fixture.server, {:reconcile, token})
    assert projection(c) == before
    assert {:ok, ^duty} = Projection.duty(projection(c), {:ref, duty.ref})
  end

  test "recovery materializes an overdue promise even when its Instance died", c do
    monitor = Process.monitor(c.instance)
    GenServer.stop(c.fixture.server)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    Runtime.set_time(c.due_at)
    recovered = Fixture.restart_domain(c.fixture, generation: 8)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    assert_overdue(%{c | fixture: recovered})
  end

  test "recovery preserves an existing Duty without appending it twice", c do
    reconcile(c, c.due_at)
    duty = assert_overdue(c)
    before = projection(c)
    GenServer.stop(c.fixture.server)
    recovered = Fixture.restart_domain(c.fixture, generation: 8)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    assert Sequencer.projection(recovered.server) == before
    assert assert_overdue(%{c | fixture: recovered}) == duty
  end

  test "recovery respects completion recorded before the deadline", c do
    assert {:ok, _} = Instance.turn(c.instance, input(c))
    GenServer.stop(c.fixture.server)
    Runtime.set_time(c.due_at)
    recovered = Fixture.restart_domain(c.fixture, generation: 8)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    assert Sequencer.projection(recovered.server).duties == %{}
    assert_replay(%{c | fixture: recovered})
  end

  test "the session-opening API cannot bypass the governed Work Act", c do
    before = projection(c)

    assert {:error, {:governed_scope_opening_required, :work}} =
             Spectre.open_scope(c.domain, c.context, c.opening_attrs)

    assert projection(c) == before
  end

  test "changing a promise under the same identity key cannot rewrite its deadline", c do
    before = projection(c)
    altered = %{c.opening_attrs | due_at: c.due_at + 1}
    assert {:error, _} = Spectre.open_scope(c.admin, c.context, altered, c.candidate_attrs)
    assert projection(c).catalog == before.catalog
    assert projection(c).acts == before.acts
    assert_replay(c)
  end

  test "the worker can discover its Duty through the authenticated public view", c do
    reconcile(c, c.due_at)
    duty = assert_overdue(c)
    assert {:ok, [^duty]} = Spectre.duties(c.scope, status: :open)
    assert {:ok, []} = Spectre.duties(c.scope, status: :disposed)
    assert {:ok, %{duties: [^duty]}} = Spectre.view(c.scope)
  end

  test "a Mind-generated completion is not an observed application receipt", c do
    assert {:ok, %{turn: turn}} = Instance.turn(c.instance, input(c, "job.progress"))

    assert {:ok, generated} =
             Spectre.Mind.evidence(turn, Runtime.now(),
               proposition: "job.finished",
               provenance: :generated,
               payload: "the agent thinks it is done"
             )

    assert {:ok, ^generated} = Spectre.record_derivation(c.scope, turn, generated)
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  @tag freshness_ms: 100
  test "completion that is valid but too old at the deadline leaves a Duty", c do
    Runtime.set_time(c.due_at - 101)
    assert {:ok, _} = Instance.turn(c.instance, input(c))
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  @tag freshness_ms: 100
  test "completion at the freshness boundary is accepted", c do
    Runtime.set_time(c.due_at - 100)
    assert {:ok, _} = Instance.turn(c.instance, input(c))
    reconcile(c, c.due_at)
    assert projection(c).duties == %{}
    assert_replay(c)
  end

  @tag minimum_proofs: 2
  test "replaying one receipt cannot satisfy a two-proof promise", c do
    assert {:ok, %{evidence: [first]}} = Instance.turn(c.instance, input(c))
    assert {:ok, %{evidence: [second]}} = Instance.turn(c.instance, input(c))
    assert second == first
    reconcile(c, c.due_at)
    assert_overdue(c)
  end

  test "late input cannot backdate its acquisition to escape an overdue promise", c do
    reconcile(c, c.due_at)
    duty = assert_overdue(c)
    Runtime.set_time(c.due_at + 1)
    backdated = Map.put(input(c), :observed_at, c.due_at - 1)
    assert {:ok, %{evidence: [recorded]}} = Instance.turn(c.instance, backdated)
    assert recorded.observed_at == c.due_at + 1
    assert {:ok, ^duty} = Projection.duty(projection(c), {:ref, duty.ref})
    assert_replay(c)
  end

  defp input(c, proposition \\ "job.finished") do
    c.fixture
    |> Fixture.paid_evidence(%{proposition: proposition, payload: "application receipt"})
    |> Map.from_struct()
    |> Map.delete(:ref)
  end

  # Deliver the actual scheduled message after advancing the fixture clock.
  # No sleeps, manufactured ledger records or replacement of process state.
  defp reconcile(c, time) do
    %{reconciliation: {token, _timer}} = :sys.get_state(c.fixture.server)
    Runtime.set_time(time)
    send(c.fixture.server, {:reconcile, token})
    projection(c)
  end

  defp projection(c), do: Sequencer.projection(c.fixture.server)

  defp assert_overdue(c) do
    assert [duty] = Map.values(projection(c).duties)
    assert duty.class == :scope_promise_overdue
    assert duty.status == :open
    assert duty.act_ref == projection(c).catalog.scopes[c.context.scope_ref].source_act_ref
    assert duty.closing_conditions == [Condition.canonical(c.condition)]
    assert_replay(c)
    duty
  end

  defp assert_replay(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
    assert replayed == projection(c)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
