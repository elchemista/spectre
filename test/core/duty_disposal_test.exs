defmodule Spectre.Core.DutyDisposalTest do
  use ExUnit.Case, async: true

  alias Spectre.{Act, Condition, Duty, Evidence, Outcome, Portable}
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.State
  alias Spectre.GovernedAct.Transition.Duty.Disposal

  # Isolate the closure contract using typed records. This is not a replacement
  # for Kernel admission, durable append or the independent-authority tests.
  setup do
    {:ok, condition} =
      Condition.new(
        proposition: "review.complete",
        bindings: %{"case" => "A"},
        parameters: %{"issuer_refs" => ["reviewer"]},
        accepted_provenance: [:observed]
      )

    evidence = evidence()

    {:ok, duty} =
      Duty.new(
        class: "app.review",
        cause_key: {:review, 1},
        accountable: "owner",
        opened_at: 90,
        missing: ["review"],
        closing_conditions: [Condition.canonical(condition)]
      )

    {:ok, disposition} = Disposition.for_duty(duty, :condition_met, [evidence.ref])
    act = act(disposition, [evidence.ref])
    state = %{State.new("domain") | evidence: %{evidence.ref => evidence}}
    c = %{duty: duty, disposition: disposition, act: act, state: state, evidence: evidence}
    assert {:ok, [{:evidence, ^evidence}]} = validate(c)
    c
  end

  test "precommitted conditions can close a Duty without inventing a discretionary reviewer", c do
    assert c.duty.disposition_authority_refs == []
    assert {:ok, [{:evidence, evidence}]} = validate(c)
    assert evidence == c.evidence
    assert c.duty.status == :open
    assert c.state.meters == %{}
  end

  test "a non-disposition Act cannot close the Duty", c do
    assert {:error, {:duty_disposition_act_class_mismatch, _, "app.read"}} =
             validate(%{c | act: update_act(c.act, class: "app.read")})
  end

  test "closure cannot append an extra effect-row dimension", c do
    assert {:error, {:duty_disposition_act_row_mismatch, _}} =
             validate(%{c | act: update_act(c.act, row: %{govern: true, write: true})})
  end

  test "closure cannot create a new Meter reservation", c do
    assert {:error, {:duty_disposition_act_has_reservations, _}} =
             validate(%{c | act: update_act(c.act, reservations: %{"meter" => 1})})
  end

  test "the disposed Duty must be an explicit target", c do
    assert {:error, {:duty_disposition_target_missing, _, _}} =
             validate(%{c | act: update_act(c.act, target_refs: [])})
  end

  test "the causal Act cannot double as its own later disposition", c do
    duty = %{c.duty | act_ref: c.act.ref}
    assert {:error, {:duty_cause_act_cannot_dispose, _, _}} = validate(%{c | duty: duty})
  end

  test "a disposition cannot target a different Duty while retaining this opening digest", c do
    c = change_disposition(c, duty_ref: "duty:another")
    # Keep the actual Duty in targets so the exact binding is what fails.
    assert {:error, {:duty_disposition_ref_mismatch, _, _}} = validate(c)
  end

  test "a different cause cannot reuse a valid opening digest", c do
    assert {:error, {:duty_disposition_cause_mismatch, _}} =
             validate(change_disposition(c, cause_key: {:review, 2}))
  end

  test "canonical integer and float causes are not interchangeable", c do
    assert {:error, {:duty_disposition_cause_mismatch, _}} =
             validate(change_disposition(c, cause_key: {:review, 1.0}))
  end

  test "a syntactically valid but wrong opening digest is rejected", c do
    assert {:error, {:duty_disposition_opening_mismatch, _}} =
             validate(change_disposition(c, opening_digest: Portable.digest!("wrong opening")))
  end

  test "changing a frozen obligation makes an earlier disposition stale", c do
    {:ok, changed} = Duty.new(c.duty |> Map.from_struct() |> Map.put(:missing, ["extra review"]))
    assert changed.ref == c.duty.ref
    assert {:error, {:duty_disposition_opening_mismatch, _}} = validate(%{c | duty: changed})
  end

  test "an absent supporting ref is not a successful condition", c do
    assert {:error, {:duty_disposition_support_not_found, "unknown"}} =
             validate(change_disposition(c, supporting_refs: ["unknown"]))
  end

  test "support must be frozen into the Act, not merely available in the Domain", c do
    assert {:error, {:duty_disposition_evidence_not_frozen, _, ref}} =
             validate(%{c | act: update_act(c.act, evidence_refs: [])})

    assert ref == c.evidence.ref
  end

  test "support from the future cannot justify an earlier disposition", c do
    c = change_evidence(c, observed_at: 101)
    assert {:error, {:duty_disposition_support_from_future, _}} = validate(c)
  end

  test "support observed exactly at disposition time is usable", c do
    assert {:ok, _} = validate(change_evidence(c, observed_at: 100))
  end

  test "expired Evidence cannot satisfy a preregistered closing condition", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_evidence(c, valid_until: 100))
  end

  test "a contrary review does not satisfy the closing condition", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_evidence(c, stance: :contradicts))
  end

  test "a different case's review does not release this obligation", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_evidence(c, bindings: %{"case" => "B"}))
  end

  test "a self-issued review does not satisfy the named independent issuer", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_evidence(c, issuer_ref: "owner"))
  end

  test "provisional evidence is not enough for a definitive closure", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_evidence(c, provisional: true, valid_until: 200))
  end

  test "a generated statement cannot impersonate an observed review", c do
    notes = evidence(proposition: "raw review notes")
    c = change_evidence(c, provenance: :generated, parent_refs: [notes.ref])
    state = %{c.state | evidence: Map.put(c.state.evidence, notes.ref, notes)}

    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(%{c | state: state})
  end

  test "an empty closing policy cannot be retrofitted with condition_met", c do
    c = change_duty(c, closing_conditions: [])
    assert {:error, {:duty_closing_condition_not_met, _}} = validate(c)
  end

  test "a prose instruction is not an executable closing predicate", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_duty(c, closing_conditions: ["please close now"]))
  end

  test "satisfying one of the frozen alternative conditions is sufficient", c do
    {:ok, unmet} = Condition.new(proposition: "another.review")
    conditions = [Condition.canonical(unmet) | c.duty.closing_conditions]
    assert {:ok, _} = validate(change_duty(c, closing_conditions: conditions))
  end

  test "a recognized basis outside the declared supporting refs cannot close the Duty", c do
    other = evidence(proposition: "unrelated")
    state = %{c.state | evidence: Map.put(c.state.evidence, other.ref, other)}
    c = change_disposition(%{c | state: state}, supporting_refs: [other.ref])
    c = %{c | act: update_act(c.act, evidence_refs: [other.ref])}
    assert {:error, {:duty_closing_condition_not_met, _}} = validate(c)
  end

  test "an index collision across support kinds is an error, not arbitrary selection", c do
    state = %{c.state | acts: %{c.evidence.ref => c.act}}
    assert {:error, {:duty_disposition_support_ambiguous, ref}} = validate(%{c | state: state})
    assert ref == c.evidence.ref
  end

  test "all definitive Outcome classes can satisfy a preregistered Outcome condition", c do
    for status <- [:succeeded, :failed, :definitive_no_effect] do
      c = with_outcome_condition(c, status)
      assert {:ok, [{:outcome, outcome}]} = validate(c)
      assert outcome.status == status
    end
  end

  test "ambiguity is never a definitive Outcome closing condition", c do
    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(with_outcome_condition(c, :ambiguous))
  end

  test "a definitive Outcome on another Attempt cannot close this Duty", c do
    c = with_outcome_condition(c, :succeeded)
    conditions = [%{"kind" => :definitive_outcome, "attempt_ref" => "attempt:other"}]

    assert {:error, {:duty_closing_condition_not_met, _}} =
             validate(change_duty(c, closing_conditions: conditions))
  end

  test "an Outcome arriving after disposition is unavailable as support", c do
    c = with_outcome_condition(c, :succeeded, observed_at: 101)
    assert {:error, {:duty_disposition_support_from_future, _}} = validate(c)
  end

  test "a corrected no-effect observation cannot still close the Duty", c do
    c = with_outcome_condition(c, :definitive_no_effect)
    [prior] = Map.values(c.state.outcomes)
    corrected = outcome(:succeeded, contradicts_outcome_ref: prior.ref, observed_at: 100)
    state = %{c.state | outcomes: Map.put(c.state.outcomes, corrected.ref, corrected)}
    assert {:error, {:duty_closing_condition_not_met, _}} = validate(%{c | state: state})
  end

  test "a future correction cannot rewrite what was known at disposition time", c do
    c = with_outcome_condition(c, :definitive_no_effect)
    [prior] = Map.values(c.state.outcomes)
    corrected = outcome(:succeeded, contradicts_outcome_ref: prior.ref, observed_at: 101)
    state = %{c.state | outcomes: Map.put(c.state.outcomes, corrected.ref, corrected)}
    assert {:ok, _} = validate(%{c | state: state})
  end

  defp validate(c), do: Disposal.validate(c.state, c.act, c.duty, c.disposition)

  defp change_disposition(c, attrs) do
    {:ok, disposition} =
      c.disposition |> Map.from_struct() |> Map.merge(Map.new(attrs)) |> Disposition.new()

    act = update_act(c.act, consequence: Disposition.consequence(disposition))
    %{c | disposition: disposition, act: act}
  end

  defp change_duty(c, attrs) do
    {:ok, duty} = c.duty |> Map.from_struct() |> Map.merge(Map.new(attrs)) |> Duty.new()
    change_disposition(%{c | duty: duty}, opening_digest: Duty.digest(duty))
  end

  defp change_evidence(c, attrs) do
    evidence = evidence(attrs)
    state = %{c.state | evidence: %{evidence.ref => evidence}}

    c =
      change_disposition(%{c | state: state, evidence: evidence}, supporting_refs: [evidence.ref])

    %{c | act: update_act(c.act, evidence_refs: [evidence.ref])}
  end

  defp with_outcome_condition(c, status, attrs \\ []) do
    outcome = outcome(status, attrs)

    c =
      change_duty(c,
        closing_conditions: [
          %{"kind" => :definitive_outcome, "attempt_ref" => outcome.attempt_ref}
        ]
      )

    state = %{c.state | outcomes: %{outcome.ref => outcome}}
    change_disposition(%{c | state: state}, supporting_refs: [outcome.ref])
  end

  defp outcome(status, attrs) do
    {:ok, outcome} =
      Outcome.new(
        Map.merge(
          %{
            act_ref: "act:cause",
            attempt_ref: "attempt:cause",
            status: status,
            evidence_refs: ["proof"],
            observed_at: 99,
            details_ref: "receipt"
          },
          Map.new(attrs)
        )
      )

    outcome
  end

  defp evidence(attrs \\ []) do
    {:ok, evidence} =
      Evidence.new(
        Map.merge(
          %{
            proposition: "review.complete",
            bindings: %{"case" => "A"},
            issuer_ref: "reviewer",
            source_ref: "observer",
            provenance: :observed,
            observed_at: 99,
            payload: "proof"
          },
          Map.new(attrs)
        )
      )

    evidence
  end

  defp update_act(act, attrs),
    do: act |> Map.from_struct() |> Map.delete(:ref) |> Map.merge(Map.new(attrs)) |> build_act()

  defp act(disposition, evidence_refs) do
    build_act(%{
      decision_ref: "decision",
      candidate_identity_key: "close-review",
      submission_context_ref: "context",
      authenticated_principal_ref: "agent",
      authentication_ref: "authentication",
      ingress_ref: "ingress",
      host_generation: 1,
      class: "duty.dispose",
      row: %{govern: true},
      consequence: Disposition.consequence(disposition),
      proposer_ref: "agent",
      executor_ref: "executor",
      authorizer_ref: "authorizer",
      accountable_ref: "owner",
      scope_ref: "scope",
      target_refs: [disposition.duty_ref],
      purpose_ref: "purpose",
      mandate_ref: "mandate",
      mandate_revision: 1,
      host_profile_ref: "profile",
      surface_revision: 1,
      executor_contract_ref: "contract",
      evidence_refs: evidence_refs,
      committed_at: 100
    })
  end

  defp build_act(attrs) do
    {:ok, act} =
      attrs |> Map.put(:material_digest, Portable.digest!(attrs.consequence)) |> Act.new()

    act
  end
end
