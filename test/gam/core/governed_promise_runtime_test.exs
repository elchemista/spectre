Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.GovernedPromiseRuntimeTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Audit, Candidate, Condition, Governance, Ledger, Row}
  alias Spectre.GAM.Domain.{Projection, Sequencer}
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule Mind do
    use Spectre.GAM.Mind, ref: "mind:promise-runtime"
    def deliberate(_turn, _opts), do: {:ok, []}
    def deliberate(_turn, state, _opts), do: {:ok, [], state + 1}
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "promise-runtime-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"
    child_ref = "scope:#{namespace}:work"
    {:ok, row} = Row.new(%{write: true, govern: true})

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {Spectre.GAM.Domain.Registry, domain_ref}},
        mind: Mind,
        governance_allowed: true,
        governance_classes: ["scope.open"],
        governance_targets: [child_ref],
        governance_ceiling: row,
        governance_declarations: %{"scope.open" => row}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = GAM.lookup_domain(domain_ref)

    {:ok, admin} =
      GAM.resume_scope(
        domain,
        Fixture.context(fixture,
          authenticated_principal_ref: fixture.refs.grantor
        )
      )

    {:ok, context} =
      GAM.authenticate(domain, child_ref, %{
        principal_ref: fixture.refs.proposer,
        authentication_ref: "auth:worker",
        session_ref: "session:worker"
      })

    {:ok, condition} =
      Condition.new(proposition: "job.finished", bindings: %{"scope_ref" => child_ref})

    opening = %{
      kind: Map.get(tags, :kind, :work),
      promise_condition: condition,
      accountable_ref: fixture.refs.accountable,
      disposition_authority_refs: [fixture.refs.executor],
      due_at: Runtime.now() + 60_000
    }

    attrs = %{
      identity_key: "open-work",
      requested_mandate_ref: fixture.governance_mandate.ref,
      accountable_ref: fixture.refs.accountable,
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    }

    %{
      fixture: fixture,
      domain: domain,
      admin: admin,
      context: context,
      condition: condition,
      opening: opening,
      attrs: attrs
    }
  end

  test "governed Work opens once and stateful cognition does not acquire authority", c do
    {:ok, scope} = open(c)
    before = projection(c)
    assert {:ok, %{state: 1, candidates: []}} = GAM.turn(scope, input(c, "job.progress"), 0, [])
    after_turn = projection(c)
    assert after_turn.catalog == before.catalog
    assert after_turn.meters == before.meters
    assert after_turn.acts == before.acts
    assert after_turn.attempts == %{}
    assert {:ok, ^scope} = open(c)
    assert projection(c) == after_turn
    assert_replay(c)
  end

  @tag kind: :vigil
  test "an unmet Vigil promise becomes durable debt at the exact deadline", c do
    {:ok, scope} = open(c)
    reconcile(c, c.opening.due_at - 1)
    assert projection(c).duties == %{}
    reconcile(c, c.opening.due_at)
    [duty] = Map.values(projection(c).duties)
    assert duty.class == :scope_promise_overdue
    assert duty.opened_at == c.opening.due_at
    assert duty.accountable == c.fixture.refs.accountable
    assert duty.disposition_authority_refs == [c.fixture.refs.executor]
    assert {:ok, [^duty]} = GAM.duties(scope, status: :open)
    assert_replay(c)
  end

  test "an observed application receipt discharges the promise while generated text does not",
       c do
    {:ok, scope} = open(c)
    {:ok, turn} = GAM.open_turn(scope, input(c, "job.progress"))

    {:ok, generated} =
      GAM.Mind.evidence(turn, Runtime.now(),
        proposition: "job.finished",
        payload: "The model thinks the job is done"
      )

    assert {:ok, ^generated} = GAM.record_derivation(scope, turn, generated)
    Runtime.set_time(c.opening.due_at - 1)
    assert {:ok, [_]} = GAM.observe(scope, input(c))
    reconcile(c, c.opening.due_at)
    assert projection(c).duties == %{}
    assert_replay(c)
  end

  test "generated completion alone and late observations cannot erase the original Duty", c do
    {:ok, scope} = open(c)
    {:ok, turn} = GAM.open_turn(scope, input(c, "job.progress"))

    {:ok, generated} =
      GAM.Mind.evidence(turn, Runtime.now(),
        proposition: "job.finished",
        payload: "Generated completion"
      )

    {:ok, _} = GAM.record_derivation(scope, turn, generated)
    reconcile(c, c.opening.due_at)
    [duty] = Map.values(projection(c).duties)
    Runtime.set_time(c.opening.due_at + 1)
    assert {:ok, [_]} = GAM.observe(scope, Map.put(input(c), :observed_at, c.opening.due_at - 1))
    assert projection(c).duties[duty.cause_key] == duty
    assert_replay(c)
  end

  test "a completion in the parent's authenticated Scope cannot satisfy the child promise", c do
    {:ok, _scope} = open(c)
    assert {:ok, [_]} = GAM.observe(c.admin, input(c))
    reconcile(c, c.opening.due_at)
    assert [_duty] = Map.values(projection(c).duties)
    assert_replay(c)
  end

  test "scope opening boundaries fail before appending an unauthorized promise", c do
    {:ok, candidate} = Governance.open_scope(c.admin, c.context, c.opening, c.attrs)
    before = projection(c)

    assert {:error, :governed_scope_context_required} =
             Sequencer.submit(c.fixture.server, c.admin.context, candidate)

    {:ok, wrong_row} = Row.new(%{govern: true})

    variants = [
      {%{row: wrong_row}, :invalid_governed_scope_opening_row},
      {%{executor_ref: "executor:unrelated"}, :governed_scope_opening_not_ledger_internal},
      {%{observation_window_ms: 1}, :invalid_governed_scope_opening_execution},
      {%{accountable_ref: "principal:unrelated"}, :governed_scope_accountable_mismatch},
      {%{target_refs: []}, :governed_scope_opening_target_missing},
      {%{consequence: %{"unrelated" => true}}, :invalid_governed_scope_opening_consequence}
    ]

    for {changes, reason} <- variants do
      attrs =
        candidate |> Map.from_struct() |> Map.drop([:ref, :material_digest]) |> Map.merge(changes)

      {:ok, changed} = Candidate.new(attrs)

      assert {:error, ^reason} =
               Sequencer.submit_scope_opening(
                 c.fixture.server,
                 c.admin.context,
                 c.context,
                 changed
               )

      assert projection(c) == before
    end

    assert_replay(c)
  end

  test "changing a promise under an existing identity never rewrites its deadline", c do
    {:ok, _scope} = open(c)
    before = projection(c)

    assert {:error, _} =
             GAM.open_scope(
               c.admin,
               c.context,
               %{c.opening | due_at: c.opening.due_at + 1},
               c.attrs
             )

    assert projection(c) == before
    assert_replay(c)
  end

  defp open(c), do: GAM.open_scope(c.admin, c.context, c.opening, c.attrs)
  defp projection(c), do: Sequencer.projection(c.fixture.server)

  defp input(c, proposition \\ "job.finished") do
    c.fixture
    |> Fixture.paid_evidence(%{proposition: proposition, payload: "application receipt"})
    |> Map.from_struct()
    |> Map.delete(:ref)
  end

  defp reconcile(c, time) do
    %{reconciliation: {token, _timer}} = :sys.get_state(c.fixture.server)
    Runtime.set_time(time)
    send(c.fixture.server, {:reconcile, token})
    projection(c)
  end

  defp assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
    assert replayed == projection(c)
    {:ok, exported} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(exported, c.fixture.constitution, Runtime.now())
  end
end
