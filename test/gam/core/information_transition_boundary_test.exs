Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.InformationTransitionBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Domain.Event
  alias Spectre.GAM.Duty.EvidenceCause
  alias Spectre.GAM.{Evidence, Presentation}
  alias Spectre.GAM.GovernedAct.Transition.Information
  alias Spectre.GAM.Presentation.Approval
  alias Spectre.GAM.V04Test.Fixture

  test "a scoped observation cannot replace the ingress that authenticated its Scope", c do
    {:ok, evidence} =
      Spectre.GAM.Ingress.evidence(Fixture.context(c.f), c.act.committed_at,
        proposition: "customer.intent",
        issuer_ref: c.candidate.proposer_ref,
        payload: "cancel"
      )

    assert {:ok, _} = replay(c.before, "evidence_recorded", evidence)
    {:ok, forged} = Evidence.new(%{evidence | ref: nil, source_ref: "another-ingress"})

    assert {:error, {:evidence_scope_ingress_source_mismatch, _, _}} =
             replay(c.before, "evidence_recorded", forged)
  end

  test "prepared material must follow a real Scope opening, even before approval exists", c do
    opening = c.before.catalog.scopes[c.candidate.scope_ref]

    attrs = %{
      candidate_binding_ref: Spectre.GAM.Candidate.presentation_binding_ref(c.candidate),
      scope_ref: opening.ref,
      recipient_refs: [c.candidate.proposer_ref],
      data: "Refund quote",
      cost: 100,
      purpose_ref: c.candidate.purpose_ref,
      purpose_params: c.candidate.purpose_params,
      risk: "financial",
      reversibility: "none",
      alternatives: ["retain order"],
      approval_source_refs: [opening.ingress_ref],
      renderer_ref: "plain-text",
      rendered_payload: "You will receive EUR 1.00",
      prepared_at: opening.opened_at
    }

    {:ok, presentation} = Presentation.new(attrs)
    assert {:ok, _} = replay(c.before, "presentation_recorded", presentation)

    for {changes, error} <- [
          {%{prepared_at: opening.opened_at - 1}, :presentation_precedes_scope},
          {%{scope_ref: "missing-scope"}, :presentation_scope_not_open}
        ] do
      {:ok, invalid} = Presentation.new(Map.merge(attrs, changes))
      assert {:error, reason} = replay(c.before, "presentation_recorded", invalid)
      assert elem(reason, 0) == error
    end
  end

  test "approval cannot cite nonexistent show facts or smuggle fields into its proposition", c do
    proposition = Approval.proposition("presentation:missing", "act:show-missing")
    {:ok, evidence} = Evidence.new(%{c.payment | ref: nil, proposition: proposition})

    assert {:error,
            {:presentation_approval_cause_not_found, _, "presentation:missing",
             "act:show-missing"}} =
             replay(c.before, "evidence_recorded", evidence)

    {:ok, invalid} =
      Evidence.new(%{
        evidence
        | ref: nil,
          proposition: Map.put(proposition, "approved_everything", true)
      })

    assert {:error,
            {:invalid_presentation_approval_evidence, _,
             :noncanonical_presentation_approval_proposition}} =
             replay(c.before, "evidence_recorded", invalid)
  end

  test "a configured Duty cause still requires real accountability and causal references", c do
    state = %{
      c.before
      | constitution:
          Map.put(c.before.constitution, :duty_rules, %{
            "app.receipt_gap" => %{cause_source_refs: [c.payment.source_ref]}
          })
    }

    attrs = %{
      class: "app.receipt_gap",
      accountable_ref: c.f.refs.accountable,
      missing: ["receipt"]
    }

    assert {:ok, _} = replay(state, "evidence_recorded", marker(c, attrs))

    for {changes, reason} <- [
          {%{accountable_ref: "missing-owner"}, :duty_evidence_accountable_not_found},
          {%{mandate_ref: "missing-mandate"}, :duty_evidence_mandate_not_found},
          {%{related_evidence_refs: ["missing-proof"]}, :outcome_evidence_not_found}
        ] do
      assert {:error, error} =
               replay(state, "evidence_recorded", marker(c, Map.merge(attrs, changes)))

      assert elem(error, 0) == reason
    end
  end

  defp marker(c, attrs) do
    {:ok, cause} = EvidenceCause.new(attrs)

    {:ok, evidence} =
      Evidence.new(%{
        c.payment
        | ref: nil,
          proposition: EvidenceCause.proposition(),
          payload: EvidenceCause.canonical(cause)
      })

    evidence
  end

  defp replay(state, type, record) do
    payload = %{
      "schema_version" => 1,
      "type" => type,
      "identity" => record.ref,
      "data" => record.__struct__.canonical(record)
    }

    {:ok, event} = Event.decode(payload)
    Information.apply(state, event, nil)
  end
end
