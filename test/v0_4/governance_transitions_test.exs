Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.GovernanceTransitionsTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.Projection
  alias Spectre.Domain.Sequencer
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel, as: AdmissionKernel
  alias Spectre.Kernel.Commit
  alias Spectre.Kernel.Grant
  alias Spectre.Scope.Opening, as: Opening
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
            "mandate_ref" => fixture.mandate.ref
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
             effective_at: ^effective_at,
             identity: revocation_ref,
             mode: :cascade
           } = projection.revocations[fixture.mandate.ref]

    assert revocation_ref == revocation_act.ref

    entries = Enum.drop(Fixture.snapshot(fixture).entries, revision)

    assert Enum.map(entries, & &1.payload["type"]) == [
             "decision_recorded",
             "act_committed",
             "mandate_revoked",
             "dispatch_cancelled",
             "meter_released"
           ]

    assert entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1

    assert {:error, :mandate_revoked} =
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

  test "a Duty closes atomically only with an exact independently authorized disposition" do
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

    assert {:ok, ^cause_act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)
    ambiguous = Fixture.outcome(fixture, cause_act, attempt, :ambiguous)
    assert {:ok, ^ambiguous} = Sequencer.record_outcome(fixture.server, ambiguous)

    [duty] = Map.values(Sequencer.projection(fixture.server).duties)
    assert duty.status == :open
    assert duty.disposition_authority_refs == [fixture.refs.grantor]

    # Legacy cause-key-only closure cannot resolve a live Duty.
    invalid_disposition =
      governance_candidate(
        fixture,
        "duty.dispose",
        %{"duty_disposition" => %{"cause_key" => duty.cause_key}},
        "dispose-ambiguous-duty"
      )

    assert {:ok, %{decision: rejected, act: nil}} =
             Sequencer.submit(fixture.server, governance_context(fixture), invalid_disposition)

    assert rejected.outcome == :refused
    assert Sequencer.projection(fixture.server).duties[duty.cause_key] == duty

    # The pure admission/replay contract takes an already verified authority
    # view. Supply an independent, exact-target route explicitly here; this is
    # not a claim that a runtime may insert a new root into an existing ledger.
    projection = Sequencer.projection(fixture.server)
    {:ok, reviewer} = Spectre.Principal.new(%{kind: :human, attributes: %{"role" => "reviewer"}})

    {:ok, review_mandate} =
      fixture.governance_mandate
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.merge(%{
        holder_ref: reviewer.ref,
        grantor_ref: reviewer.ref,
        accountable_ref: reviewer.ref,
        target_refs: [duty.ref],
        revocation: %{"mode" => :cascade, "controller_refs" => [reviewer.ref]}
      })
      |> Spectre.Mandate.new()

    {:ok, review_duty} =
      duty
      |> Map.from_struct()
      |> Map.put(:disposition_authority_refs, [reviewer.ref])
      |> Spectre.Duty.new()

    projection = %{
      projection
      | principals: Map.put(projection.principals, reviewer.ref, reviewer),
        mandates: Map.put(projection.mandates, review_mandate.ref, review_mandate),
        meters: Map.put(projection.meters, review_mandate.ref, %{}),
        meter_owner_aliases:
          Map.put(projection.meter_owner_aliases, review_mandate.ref, review_mandate.ref),
        duties: Map.put(projection.duties, duty.cause_key, review_duty)
    }

    {:ok, review_context} =
      governance_context(fixture)
      |> Map.from_struct()
      |> Map.drop([:ref, :seal])
      |> Map.put(:authenticated_principal_ref, reviewer.ref)
      |> Spectre.SubmissionContext.new()

    {:ok, review_scope} =
      projection.scopes[review_context.scope_ref]
      |> Map.from_struct()
      |> Map.merge(Opening.context_bindings(review_context))
      |> Opening.new()

    projection = %{
      projection
      | scopes: Map.put(projection.scopes, review_scope.ref, review_scope)
    }

    {:ok, disposition} = Disposition.for_duty(review_duty, :accept_loss, [ambiguous.ref], :settle)

    {:ok, candidate} =
      governance_candidate(
        fixture,
        "duty.dispose",
        Disposition.consequence(disposition),
        "independent-disposition"
      )
      |> Map.merge(%{
        proposer_ref: reviewer.ref,
        accountable_ref: reviewer.ref,
        requested_mandate_ref: review_mandate.ref,
        target_refs: [duty.ref]
      })
      |> Spectre.Candidate.new()

    assert {:ok, decision, disposition_act} =
             AdmissionKernel.evaluate(candidate, review_context, projection, Runtime.now())

    assert decision.outcome == :admitted, inspect(decision.reasons)
    refute disposition_act.ref == cause_act.ref

    assert {:ok, payloads} = Commit.payloads(projection, decision, disposition_act)
    assert {:ok, folded} = Projection.apply_payloads(projection, payloads, Runtime.now())
    disposed = folded.duties[duty.cause_key]
    assert disposed.status == :disposed
    assert disposed.disposition_act_ref == disposition_act.ref
    assert disposed.cause_key == duty.cause_key
    assert disposed.act_ref == duty.act_ref
    assert disposed.attempt_ref == duty.attempt_ref

    assert Enum.map(payloads, & &1["type"]) == [
             "decision_recorded",
             "act_committed",
             "meter_duty_resolved",
             "duty_disposed"
           ]

    assert folded.meters[fixture.mandate.ref][fixture.refs.meter].spent == 2_000
    assert folded.meters[fixture.mandate.ref][fixture.refs.meter].suspended == 0
  end

  defp start_domain(namespace) do
    fixture = Fixture.start_domain(namespace: namespace, governance_allowed: true)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp record_payment(fixture) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)
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
      executor_ref: GovernedExecution.kernel_executor_ref(),
      accountable_ref: fixture.refs.accountable,
      scope_ref: fixture.refs.governance_scope,
      subject_refs: [],
      target_refs: [fixture.mandate.ref],
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      evidence_refs: [],
      meter_requests: %{},
      executor_contract_ref: GovernedExecution.kernel_contract_ref(),
      observation_window_ms: 0
    }
  end
end
