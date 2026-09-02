Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.GovernanceDelegationTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
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

    assert decision.outcome == :admitted
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

  defp start_domain(namespace) do
    fixture = Fixture.start_domain(namespace: namespace, delegation_allowed: true)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp record_payment(fixture) do
    evidence = Fixture.paid_evidence(fixture)
    assert {:ok, ^evidence} = Sequencer.record_evidence(fixture.server, evidence)
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
      executor_ref: fixture.refs.executor,
      accountable_ref: fixture.refs.accountable,
      scope_ref: fixture.refs.scope,
      subject_refs: [fixture.refs.customer],
      target_refs: [fixture.refs.payment_target],
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      evidence_refs: [evidence_ref],
      meter_requests: %{},
      executor_contract_ref: fixture.refs.executor_contract,
      observation_window_ms: 0
    }
  end
end
