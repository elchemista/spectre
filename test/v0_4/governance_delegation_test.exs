Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.GovernanceDelegationTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel.Authority.Coverage
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
  end

  test "the implicit parent target is confined to delegation, never an arbitrary destination" do
    fixture = start_domain("delegation-targets")
    payment = record_payment(fixture)

    {:ok, candidate} =
      fixture
      |> delegation_candidate(issue_draft(fixture, 100), "targets", payment.ref)
      |> Spectre.Candidate.new()

    assert :ok = Coverage.covered_values(:targets, candidate, fixture.mandate)

    assert {:error, {:targets, :outside_mandate}} =
             Coverage.covered_values(
               :targets,
               %{candidate | target_refs: ["unrelated:target"]},
               fixture.mandate
             )

    assert {:error, {:targets, :outside_mandate}} =
             Coverage.covered_values(
               :targets,
               %{candidate | class: "refund.issue"},
               fixture.mandate
             )
  end

  test "a delegation Act and its content-addressed child Mandate commit atomically" do
    fixture = start_domain("delegation")
    payment = record_payment(fixture)
    draft = issue_draft(fixture, 3_000)
    before_revision = Fixture.snapshot(fixture).revision

    assert {:ok, %{decision: decision, act: act, grant: nil}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               delegation_candidate(fixture, draft, "delegate-3k", payment.ref)
             )

    assert decision.outcome == :admitted, inspect(decision.reasons)
    assert act.row.delegate
    assert act.row.govern
    assert act.consequence == %{"mandate_issue" => draft}

    projection = Sequencer.projection(fixture.server)
    [child] = projection.mandates |> Map.values() |> Enum.reject(&(&1.ref == fixture.mandate.ref))

    assert child.source_ref == act.ref
    assert child.parent_ref == fixture.mandate.ref
    assert child.ref == Spectre.Mandate.content_ref(child)

    assert %{ceiling: 10_000, available: 7_000, delegated: 3_000} =
             projection.meters[fixture.mandate.ref][fixture.refs.meter]

    assert %{ceiling: 3_000, available: 3_000, delegated: 0} =
             projection.meters[child.ref][fixture.refs.meter]

    entries = Enum.drop(Fixture.snapshot(fixture).entries, before_revision)

    assert Enum.map(entries, & &1.payload["type"]) == [
             "decision_recorded",
             "act_committed",
             "mandate_issued"
           ]

    assert entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1
  end

  test "a child cannot mint more Meter quantity than the parent owns" do
    fixture = start_domain("delegation-amplification")
    payment = record_payment(fixture)
    oversized = issue_draft(fixture, 10_001)
    revision = Fixture.snapshot(fixture).revision

    assert {:ok, %{decision: decision, act: nil, grant: nil}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               delegation_candidate(fixture, oversized, "delegate-too-much", payment.ref)
             )

    assert decision.outcome == :refused
    assert Enum.any?(decision.reasons, &match?({:delegation_expanded, :meters, _}, &1))

    projection = Sequencer.projection(fixture.server)
    assert map_size(projection.mandates) == 1
    assert projection.meters[fixture.mandate.ref][fixture.refs.meter].available == 10_000
    assert Fixture.snapshot(fixture).revision == revision + 1
  end

  test "delegation cannot remove Conditions, widen time, change purpose or evade revocation" do
    fixture = start_domain("delegation-policy-attacks")
    payment = record_payment(fixture)
    original = Sequencer.projection(fixture.server)
    [condition] = fixture.mandate.conditions

    attacks = [
      {"conditions", [], {:delegation_expanded, :conditions, condition.ref}},
      {"expires_at", fixture.mandate.expires_at + 1, {:delegation_expanded, :time_window}},
      {"not_before", fixture.mandate.not_before - 1, {:delegation_expanded, :time_window}},
      {"purpose_ref", "unauthorized-purpose", {:delegation_expanded, :purpose}},
      {"scope_refs", ["unauthorized-scope"], {:delegation_expanded, :scope_refs}},
      {"classes", ["refund.issue", "secret.read"], {:delegation_expanded, :classes}},
      {"revocation", %{"mode" => :cascade, "controller_refs" => [fixture.refs.executor]},
       {:delegation_expanded, :revocation}}
    ]

    for {field, value, reason} <- attacks do
      draft = Map.put(issue_draft(fixture, 100), field, value)

      assert {:ok, %{decision: decision, act: nil, grant: nil}} =
               Sequencer.submit(
                 fixture.server,
                 Fixture.context(fixture),
                 delegation_candidate(fixture, draft, "attack-" <> field, payment.ref)
               )

      assert decision.outcome == :refused
      assert reason in decision.reasons, inspect({field, decision.reasons})
      projection = Sequencer.projection(fixture.server)
      assert projection.mandates == original.mandates
      assert projection.meters == original.meters
      assert projection.acts == original.acts
    end
  end

  test "two otherwise valid children cannot allocate the same parent budget twice" do
    fixture = start_domain("delegation-double-spend")
    payment = record_payment(fixture)
    first = issue_draft(fixture, 6_000)
    second = Map.put(first, "expires_at", first["expires_at"] - 1)
    assert first != second

    tasks =
      for {draft, identity} <- [{first, "child-a"}, {second, "child-b"}] do
        Task.async(fn ->
          Sequencer.submit(
            fixture.server,
            Fixture.context(fixture),
            delegation_candidate(fixture, draft, identity, payment.ref)
          )
        end)
      end

    results = Task.await_many(tasks)
    assert Enum.count(results, &match?({:ok, %{decision: %{outcome: :admitted}}}, &1)) == 1

    assert Enum.count(results, &match?({:ok, %{decision: %{outcome: :refused}, act: nil}}, &1)) ==
             1

    projection = Sequencer.projection(fixture.server)
    assert map_size(projection.mandates) == 2
    assert map_size(projection.acts) == 1

    assert %{available: 4_000, delegated: 6_000} =
             projection.meters[fixture.mandate.ref][fixture.refs.meter]

    total_available =
      Enum.reduce(projection.meters, 0, fn {_mandate, accounts}, total ->
        total + accounts[fixture.refs.meter].available
      end)

    assert total_available == 10_000

    assert {:ok, ^projection} =
             Projection.replay(Fixture.snapshot(fixture), fixture.constitution)

    assert {:ok, _report} =
             Spectre.Audit.verify(Fixture.snapshot(fixture), fixture.constitution, Runtime.now())
  end

  defp start_domain(namespace) do
    fixture = Fixture.start_domain(namespace: namespace, delegation_allowed: true)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp record_payment(fixture) do
    evidence = Fixture.paid_evidence(fixture)
    assert {:ok, ^evidence} = Fixture.observe_payment(fixture, evidence)
    evidence
  end

  defp issue_draft(fixture, quantity) do
    {:ok, draft} =
      Spectre.Mandate.issue_draft(%{
        revision: 1,
        grantor_ref: fixture.mandate.holder_ref,
        holder_ref: fixture.refs.executor,
        accountable_ref: fixture.mandate.accountable_ref,
        executor_refs: [fixture.refs.executor],
        executor_contract_refs: [fixture.refs.executor_contract],
        scope_refs: [fixture.refs.scope],
        subject_refs: [fixture.refs.customer],
        target_refs: [fixture.refs.payment_target],
        classes: ["refund.issue"],
        ceiling: fixture.row,
        purpose_ref: fixture.refs.purpose,
        purpose_params: %{"currency" => "EUR"},
        conditions: fixture.mandate.conditions,
        not_before: fixture.mandate.not_before + 1,
        expires_at: fixture.mandate.expires_at - 1,
        meters: %{fixture.refs.meter => quantity},
        delegation: %{"allowed" => false, "max_depth" => 0},
        revocation: fixture.mandate.revocation,
        parent_ref: fixture.mandate.ref
      })

    draft
  end

  defp delegation_candidate(fixture, draft, identity_suffix, evidence_ref) do
    %{
      identity_key: fixture.refs.candidate_identity <> ":" <> identity_suffix,
      class: "mandate.delegate",
      consequence: %{"mandate_issue" => draft},
      row: fixture.delegation_row,
      requested_mandate_ref: fixture.mandate.ref,
      proposer_ref: fixture.refs.proposer,
      executor_ref: GovernedExecution.kernel_executor_ref(),
      accountable_ref: fixture.refs.accountable,
      scope_ref: fixture.refs.scope,
      subject_refs: [fixture.refs.customer],
      target_refs: Enum.sort([fixture.mandate.ref, fixture.refs.payment_target]),
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      evidence_refs: [evidence_ref],
      meter_requests: %{},
      executor_contract_ref: GovernedExecution.kernel_contract_ref(),
      observation_window_ms: 0
    }
  end
end
