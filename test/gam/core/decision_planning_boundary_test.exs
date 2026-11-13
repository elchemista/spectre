Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.DecisionPlanningBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Act, Decision, Row}
  alias Spectre.GAM.Domain.Projection
  alias Spectre.GAM.GovernedAct.Index
  alias Spectre.GAM.Kernel.Authority.Effective
  alias Spectre.GAM.Kernel.{Commit, Observation}
  alias Spectre.GAM.Kernel.Decision, as: Planner
  alias Spectre.GAM.Kernel.Decision.Context
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  setup c do
    {:ok, accounts} = Projection.meter_accounts(c.before, c.f.mandate.ref)

    context = %Context{
      meter_accounts: accounts,
      host_profile_ref: c.act.host_profile_ref,
      surface_revision: c.act.surface_revision,
      authority_revision: c.before.revision
    }

    %{context: context, authority: Effective.from_mandate(c.f.mandate, c.candidate)}
  end

  test "authority ambiguity is explicit, deterministic and never reserves resources", c do
    first = c.authority
    second = %{first | mandate: %{first.mandate | ref: "another-mandate"}}

    decision = decide(c, {:ambiguous, [first, second]}, :satisfied)
    assert decision.outcome == :undecidable

    assert decision.reasons == [
             {:ambiguous_mandate, Enum.sort([first.mandate.ref, "another-mandate"])}
           ]

    assert decision.reservations == %{}
    assert decide(c, {:ambiguous, [second, first]}, :satisfied) == decision
  end

  test "invalid or candidate-mismatched resolution is not absence of authority", c do
    assert %{outcome: :refused, reasons: [:mandate_absent]} = decide(c, :none, :satisfied)

    assert %{outcome: :undecidable, reasons: [:invalid_authority_resolution]} =
             decide(c, {:ok, c.f.mandate}, :satisfied)

    assert %{outcome: :undecidable, reasons: [:effective_authority_candidate_mismatch]} =
             decide(c, {:ok, %{c.authority | candidate_ref: "other"}}, :satisfied)

    assert %{outcome: :undecidable, reasons: [:invalid_candidate], reservations: %{}} =
             Planner.decide(nil, :none, nil, c.context, Runtime.now())
  end

  test "Recognition cannot be omitted when the Mandate requires facts", c do
    assert %{outcome: :admitted} = decide(c, {:ok, c.authority}, :satisfied)

    assert %{outcome: :undecidable, reasons: [:recognition_missing]} =
             decide(c, {:ok, c.authority}, nil)

    assert %{outcome: :undecidable, reasons: [:invalid_recognition_result]} =
             decide(c, {:ok, c.authority}, :yes)

    authority = %{c.authority | mandate: %{c.f.mandate | conditions: []}}
    assert %{outcome: :admitted} = decide(c, {:ok, authority}, nil)
  end

  test "missing and corrupt Meter projections are undecidable, not insufficient funds", c do
    meter = c.f.refs.meter

    assert %{outcome: :undecidable, reasons: [{:meter_projection_missing, ^meter}]} =
             decide(
               %{c | context: %{c.context | meter_accounts: %{}}},
               {:ok, c.authority},
               :satisfied
             )

    context = %{c.context | meter_accounts: %{meter => nil}}

    assert %{outcome: :undecidable, reasons: [{:invalid_meter_view_or_request, _}]} =
             decide(%{c | context: context}, {:ok, c.authority}, :satisfied)

    assert %{outcome: :refused, reasons: [{:meter_outside_mandate, "foreign"}]} =
             decide(
               %{c | candidate: %{c.candidate | meter_requests: %{"foreign" => 1}}},
               {:ok, c.authority},
               :satisfied
             )
  end

  test "spending and reservation declarations must agree in both directions", c do
    without_spend = %{c.candidate | row: %{c.candidate.row | spend: false}}
    without_amount = %{c.candidate | meter_requests: %{}}

    assert %{outcome: :refused, reasons: [:meter_request_not_declared_in_row]} =
             decide(%{c | candidate: without_spend}, {:ok, c.authority}, :satisfied)

    assert %{outcome: :undecidable, reasons: [:spend_row_without_meter_request]} =
             decide(%{c | candidate: without_amount}, {:ok, c.authority}, :satisfied)
  end

  test "delegate dimension is not an escape hatch for arbitrary consequences", c do
    candidate = %{c.candidate | row: %Row{delegate: true}, meter_requests: %{}}

    assert %{outcome: :refused, reasons: [:unsupported_delegation_consequence]} =
             decide(%{c | candidate: candidate}, {:ok, c.authority}, :satisfied)

    assert %{
             outcome: :refused,
             reasons: [{:invalid_mandate_issue_draft, :mandate_issue_draft_missing}]
           } =
             decide(
               %{c | candidate: %{candidate | class: "mandate.delegate"}},
               {:ok, c.authority},
               :satisfied
             )

    for consequence <- [%{}, %{"mandate_issue" => %{}}, %{"mandate_issue" => nil}] do
      assert %{outcome: :refused, reasons: [{:invalid_mandate_issue_draft, _}]} =
               decide(
                 %{
                   c
                   | candidate: %{candidate | class: "mandate.delegate", consequence: consequence}
                 },
                 {:ok, c.authority},
                 :satisfied
               )
    end
  end

  test "devolution quantities are positive exact integers and have one explicit child", c do
    valid = %{
      "mandate_devolve" => %{"child_mandate_ref" => "child", "amounts" => %{"EUR" => 100}}
    }

    candidate = %{
      c.candidate
      | class: "mandate.devolve",
        row: %Row{delegate: true},
        meter_requests: %{},
        consequence: valid
    }

    assert %{outcome: :admitted} =
             decide(%{c | candidate: candidate}, {:ok, c.authority}, :satisfied)

    for invalid <- [
          %{},
          Map.put(valid, "extra", true),
          put_in(valid, ["mandate_devolve", "child_mandate_ref"], ""),
          put_in(valid, ["mandate_devolve", "amounts"], %{}),
          put_in(valid, ["mandate_devolve", "amounts", "EUR"], 100.0),
          put_in(valid, ["mandate_devolve", "amounts", "EUR"], -1)
        ] do
      assert %{outcome: :refused, reasons: [:invalid_meter_devolution], reservations: %{}} =
               decide(
                 %{c | candidate: %{candidate | consequence: invalid}},
                 {:ok, c.authority},
                 :satisfied
               )
    end
  end

  test "atomic admission requires exactly the Act paired with an admitted Decision", c do
    assert {:ok, payloads} = Commit.payloads(c.before, c.decision, c.act)

    assert Enum.map(payloads, & &1["type"]) == [
             "decision_recorded",
             "act_committed",
             "meter_reserved",
             "dispatch_ready"
           ]

    assert {:error, :admitted_decision_missing_act} = Commit.payloads(c.before, c.decision, nil)
    assert {:error, :invalid_admission_records} = Commit.payloads(c.before, c.decision, %{})

    {:ok, act} = Act.new(%{c.act | ref: nil, candidate_identity_key: "another-command"})

    assert {:error, {:decision_act_mismatch, :candidate_identity_key, _, _}} =
             Commit.payloads(c.before, c.decision, act)

    {:ok, refused} =
      Decision.new(%{
        c.decision
        | ref: nil,
          outcome: :refused,
          reasons: [:mandate_absent],
          reservations: %{}
      })

    assert {:error, {:non_admitted_decision_has_act, :refused}} =
             Commit.payloads(c.before, refused, c.act)

    assert {:ok, [%{"type" => "decision_recorded"}]} = Commit.payloads(c.before, refused, nil)
  end

  test "an observation requires a real, bound causal pair even if its own record is well formed",
       c do
    outcome = Fixture.outcome(c.f, c.act, c.attempt, :ambiguous)
    state = c.attempted
    ref = outcome.ref

    assert {:ok,
            [
              %{"type" => "outcome_recorded"},
              %{"type" => "meter_suspended"},
              %{"type" => "duty_opened"}
            ]} =
             Observation.payloads(state, outcome, Runtime.now())

    for {projection, reason} <- [
          {%{state | acts: %{}}, :observation_cause_not_found},
          {%{state | attempts: %{}}, :observation_cause_not_found},
          {%{state | attempts: %{c.attempt.ref => nil}}, :invalid_observation_cause},
          {put_in(state.attempts[c.attempt.ref].act_ref, "other"), :observation_cause_mismatch},
          {%{state | meter_reservations: %{}}, {:reservation_state_missing, c.act.ref}},
          {%{state | outcomes: %{ref => outcome}}, {:duplicate_outcome, ref}}
        ] do
      assert {:error, ^reason} = Observation.payloads(projection, outcome, Runtime.now())
    end

    assert {:error, {:outcome_from_future, ^ref, _}} =
             Observation.payloads(state, outcome, Runtime.now() - 1)

    assert {:error, {:invalid_trusted_time, 1.0}} = Observation.payloads(state, outcome, 1.0)

    assert {:error, :invalid_observation_input} =
             Observation.payloads(nil, outcome, Runtime.now())
  end

  test "required causal references preserve their type in missing-record errors", c do
    assert {:error, {:mandate_not_found, "missing"}} = Index.fetch_mandate(c.before, "missing")
    assert {:error, {:attempt_not_found, "missing"}} = Index.fetch_attempt(c.before, "missing")
    assert {:error, {:duty_not_found, "missing"}} = Index.fetch_duty_by_ref(c.before, "missing")

    assert {:error, {:duty_not_found, {:ambiguous, "missing"}}} =
             Index.fetch_duty_by_cause(c.before, {:ambiguous, "missing"})

    assert {:error, {:invalid_duty_cause_key, nil}} = Index.fetch_duty_by_cause(c.before, nil)
    assert {:error, {:invalid_duty_ref, nil}} = Index.fetch_duty_by_ref(c.before, nil)

    assert {:error, {:proof_missing, "missing"}} =
             Index.ensure_present(c.before.evidence, [c.payment.ref, "missing"], :proof_missing)
  end

  defp decide(c, resolution, recognition),
    do: Planner.decide(c.candidate, resolution, recognition, c.context, Runtime.now())
end
