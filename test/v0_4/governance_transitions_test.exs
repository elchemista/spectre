Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.GovernanceTransitionsTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Kernel.Grant
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
  end

  test "revocation is an exact governed Act, preserves history, and stops future capability" do
    fixture = start_domain("governed-revocation")
    payment = record_payment(fixture)

    assert {:ok, %{act: historical_act, grant: %Grant{} = stale_grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 1_000,
                 identity_key: fixture.refs.candidate_identity <> ":before-revocation",
                 evidence_refs: [payment.ref]
               )
             )

    revision = Fixture.snapshot(fixture).revision
    effective_at = Runtime.now()

    revoke =
      governance_candidate(
        fixture,
        "mandate.revoke",
        %{
          "mandate_revoke" => %{
            "mandate_ref" => fixture.mandate.ref,
            "effective_at" => effective_at,
            "mode" => :cascade
          }
        },
        "revoke-operational-mandate"
      )

    assert {:ok, %{decision: decision, act: revocation_act, grant: nil}} =
             Sequencer.submit(fixture.server, governance_context(fixture), revoke)

    assert decision.outcome == :admitted
    assert revocation_act.class == "mandate.revoke"
    assert revocation_act.row.govern

    projection = Sequencer.projection(fixture.server)
    assert projection.acts[historical_act.ref] == historical_act

    assert %{
             "effective_at" => ^effective_at,
             "identity" => revocation_ref,
             "mode" => :cascade
           } = projection.revocations[fixture.mandate.ref]

    assert revocation_ref == revocation_act.ref

    entries = Enum.drop(Fixture.snapshot(fixture).entries, revision)

    assert Enum.map(entries, & &1.payload["type"]) == [
             "decision_recorded",
             "act_committed",
             "mandate_revoked"
           ]

    assert entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1

    mandate_ref = fixture.mandate.ref

    assert {:error, {:mandate_revoked, ^mandate_ref}} =
             Sequencer.consume_grant(fixture.server, stale_grant)

    assert {:ok, %{decision: refused, act: nil, grant: nil}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 1_000,
                 identity_key: fixture.refs.candidate_identity <> ":after-revocation",
                 evidence_refs: [payment.ref]
               )
             )

    assert refused.outcome == :refused
    assert :mandate_absent in refused.reasons
    assert Sequencer.projection(fixture.server).acts[historical_act.ref] == historical_act
  end

  test "a Duty remains open until an independent governed disposition Act is committed" do
    fixture = start_domain("governed-duty-disposition")
    payment = record_payment(fixture)

    assert {:ok, %{act: cause_act, grant: %Grant{} = grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 2_000,
                 evidence_refs: [payment.ref],
                 observation_window_ms: 100
               )
             )

    assert {:ok, ^cause_act, attempt} = Sequencer.consume_grant(fixture.server, grant)
    ambiguous = Fixture.outcome(fixture, cause_act, attempt, :ambiguous)
    assert {:ok, ^ambiguous} = Sequencer.record_outcome(fixture.server, ambiguous)

    [duty] = Map.values(Sequencer.projection(fixture.server).duties)
    assert duty.status == :open
    assert duty.disposition_authority_refs == [fixture.refs.grantor]

    disposition =
      governance_candidate(
        fixture,
        "duty.dispose",
        %{"duty_disposition" => %{"cause_key" => duty.cause_key}},
        "dispose-ambiguous-duty"
      )

    revision = Fixture.snapshot(fixture).revision

    assert {:ok, %{decision: decision, act: disposition_act, grant: nil}} =
             Sequencer.submit(fixture.server, governance_context(fixture), disposition)

    assert decision.outcome == :admitted
    refute disposition_act.ref == cause_act.ref

    disposed = Sequencer.projection(fixture.server).duties[duty.cause_key]
    assert disposed.status == :disposed
    assert disposed.disposition_act_ref == disposition_act.ref
    assert disposed.cause_key == duty.cause_key
    assert disposed.act_ref == duty.act_ref
    assert disposed.attempt_ref == duty.attempt_ref

    entries = Enum.drop(Fixture.snapshot(fixture).entries, revision)

    assert Enum.map(entries, & &1.payload["type"]) == [
             "decision_recorded",
             "act_committed",
             "duty_disposed"
           ]

    assert entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1
  end

  defp start_domain(namespace) do
    fixture = Fixture.start_domain(namespace: namespace, governance_allowed: true)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp record_payment(fixture) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Sequencer.record_evidence(fixture.server, payment)
    payment
  end

  defp governance_context(fixture) do
    Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
  end

  defp governance_candidate(fixture, class, consequence, identity_suffix) do
    %{
      identity_key: fixture.refs.candidate_identity <> ":" <> identity_suffix,
      class: class,
      consequence: consequence,
      row: fixture.governance_row,
      requested_mandate_ref: fixture.governance_mandate.ref,
      proposer_ref: fixture.refs.grantor,
      executor_ref: fixture.refs.executor,
      accountable_ref: fixture.refs.accountable,
      scope_ref: fixture.refs.scope,
      subject_refs: [],
      target_refs: [],
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      evidence_refs: [],
      meter_requests: %{},
      executor_contract_ref: fixture.refs.executor_contract,
      observation_window_ms: 0
    }
  end
end
