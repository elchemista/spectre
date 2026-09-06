defmodule Spectre.Core.ErasureDebtTest do
  use ExUnit.Case, async: true

  alias Spectre.{Act, Attempt, Duty, Erasure, Outcome, Portable}
  alias Spectre.Domain.Event.Metadata
  alias Spectre.Duty.Derive
  alias Spectre.Duty.Derive.{ErasureVerifiability, Facts}
  alias Spectre.GovernedAct.State

  # These tests isolate debt derivation from typed, constructor-validated
  # records. They do not claim to execute deletion in an external payload store.
  setup do
    constitution = %{
      "duty_rules" => %{
        "erasure_reduces_verifiability" => %{
          "disposition_authority_refs" => ["reviewer"],
          "conflict_refs" => ["data-custodian"],
          "containment" => %{"requires_review" => true},
          "closing_conditions" => []
        }
      }
    }

    "payload:" <> digest = target = Portable.content_ref!(:payload, "sensitive document")

    {:ok, draft} =
      Erasure.request_draft(
        target_ref: target,
        target_digest: digest,
        scope_ref: "scope",
        affected_refs: ["evidence:original"],
        reason: "subject-requested deletion",
        reduces_verifiability: true,
        requested_at: 100
      )

    act = act(draft)

    {:ok, attempt} =
      Attempt.new(
        ref: "01900000-0000-7000-8000-000000000001",
        act_ref: act.ref,
        executor_ref: act.executor_ref,
        material_digest: act.material_digest,
        generation: 1,
        grant_nonce_digest: Portable.digest!("nonce"),
        started_at: 101
      )

    {:ok, erasure} = Erasure.from_request_draft(draft, act.ref)

    outcome = outcome(act.ref, attempt.ref, :succeeded)

    state = %{
      State.new("domain", constitution)
      | acts: %{act.ref => act},
        attempts: %{attempt.ref => attempt},
        erasures: %{erasure.ref => erasure},
        outcomes: %{outcome.ref => outcome},
        event_metadata: %{
          act.ref => metadata(1, 100),
          erasure.ref => metadata(2, 100),
          attempt.ref => metadata(3, 101),
          outcome.ref => metadata(4, 120)
        }
    }

    %{state: state, act: act, attempt: attempt, erasure: erasure, outcome: outcome}
  end

  test "confirmed erasure binds verification debt to the exact request, Act, Attempt and receipt",
       c do
    assert [cause] = causes(c.state, 120)
    assert cause.cause_class == :erasure_reduces_verifiability

    assert cause.cause_key ==
             {:erasure_reduces_verifiability, c.erasure.ref, c.act.ref, c.attempt.ref,
              c.outcome.ref}

    assert cause.causal_refs == %{
             "erasure_ref" => c.erasure.ref,
             "act_ref" => c.act.ref,
             "attempt_ref" => c.attempt.ref,
             "outcome_ref" => c.outcome.ref
           }

    assert cause.known_evidence_refs == c.outcome.evidence_refs
    assert cause.missing_evidence == [:continued_verifiability]
    assert cause.accountable_ref == c.act.accountable_ref
    assert cause.mandate_ref == c.act.mandate_ref
    assert cause.subject_refs == c.act.subject_refs
  end

  test "the authorizing request or a pending Attempt alone is not proof of deletion", c do
    assert causes(%{c.state | outcomes: %{}}, 1_000) == []
    assert causes(%{c.state | attempts: %{}, outcomes: %{}}, 1_000) == []
    assert [_positive_control] = causes(c.state, 120)
  end

  test "failed, no-effect and ambiguous receipts do not assert successful erasure", c do
    for status <- [:failed, :definitive_no_effect, :ambiguous] do
      outcome = outcome(c.act.ref, c.attempt.ref, status)
      state = with_outcome(c.state, outcome)
      assert [] = causes(state, 1_000)
    end
  end

  test "success becomes known at acquisition, not the receipt's earlier claimed observation", c do
    assert c.outcome.observed_at == 110
    assert [] = causes(c.state, 110)
    assert [] = causes(c.state, 119)
    assert [cause] = causes(c.state, 120)
    assert cause.required_at == 110
  end

  test "a receipt without trusted ledger metadata is not an acquired fact", c do
    state = %{c.state | event_metadata: Map.delete(c.state.event_metadata, c.outcome.ref)}
    assert [] = causes(state, 1_000)
  end

  test "another Act's successful deletion cannot confirm this request", c do
    unrelated = outcome("act:other", c.attempt.ref, :succeeded)
    assert [] = causes(with_outcome(c.state, unrelated), 120)
  end

  test "an absent or foreign Attempt cannot be substituted behind a successful receipt", c do
    assert [] = causes(%{c.state | attempts: %{}}, 120)
    foreign = %{c.attempt | act_ref: "act:other"}
    assert {:ok, ^foreign} = Attempt.new(foreign)
    assert [] = causes(%{c.state | attempts: %{foreign.ref => foreign}}, 120)
  end

  test "an erasure without its authorizing Act cannot invent an accountable party", c do
    assert [] = causes(%{c.state | acts: %{}}, 120)
  end

  test "a deletion that preserves verifiability does not create this distinct kind of debt", c do
    {:ok, erasure} =
      c.erasure
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.put(:reduces_verifiability, false)
      |> Erasure.new()

    assert [] = causes(%{c.state | erasures: %{erasure.ref => erasure}}, 120)
  end

  test "the Constitution supplies review policy and the original interested parties stay conflicted",
       c do
    assert [cause] = causes(c.state, 120)
    assert cause.disposition_authority == ["reviewer"]
    assert cause.containment == %{"requires_review" => true}

    assert cause.conflict_refs ==
             Enum.sort([
               "agent",
               "authorizer",
               "data-custodian",
               "executor",
               "mandate",
               "owner",
               "subject",
               c.erasure.target_ref
             ])

    refute "reviewer" in cause.conflict_refs
  end

  test "delayed materialization retains the original causal time and independent review route",
       c do
    assert [cause] = causes(c.state, 120)
    assert {:ok, duty} = cause |> Derive.materialization_attrs(500) |> Duty.new()
    assert duty.opened_at == c.outcome.observed_at
    assert duty.status == :open
    assert duty.disposition_authority_refs == ["reviewer"]
    assert duty.act_ref == c.act.ref
    assert duty.attempt_ref == c.attempt.ref
    assert duty.missing == [:continued_verifiability]
    assert duty.disposition_act_ref == nil
  end

  test "the debt survives absent payload bytes and absent current Mandates", c do
    assert c.state.evidence == %{}
    assert c.state.mandates == %{}
    assert [cause] = causes(c.state, 120)
    assert [^cause] = causes(c.state, 1_000_000)
    refute inspect(cause) =~ "sensitive document"
  end

  test "recovery does not reopen a materialized Duty but the cause remains auditable", c do
    assert [cause] = Derive.missing_openings(c.state, 120)
    assert {:ok, duty} = cause |> Derive.materialization_attrs(120) |> Duty.new()
    state = %{c.state | duties: %{cause.cause_key => duty}}
    assert [] = Derive.missing_openings(state, 120)
    assert [^cause] = Derive.required_duties(state, 120)
  end

  defp causes(state, time),
    do: ErasureVerifiability.causes(Facts.from_state(state), state.constitution, time)

  defp with_outcome(state, outcome) do
    %{
      state
      | outcomes: %{outcome.ref => outcome},
        event_metadata: Map.put(state.event_metadata, outcome.ref, metadata(4, 120))
    }
  end

  defp metadata(revision, time),
    do: %Metadata{revision: revision, batch_id: "batch:#{revision}", recorded_at: time}

  defp outcome(act_ref, attempt_ref, status) do
    {:ok, outcome} =
      Outcome.new(
        act_ref: act_ref,
        attempt_ref: attempt_ref,
        status: status,
        evidence_refs: ["evidence:deletion-receipt"],
        details_ref: "receipt:delete",
        observed_at: 110
      )

    outcome
  end

  defp act(draft) do
    consequence = %{"erasure_request" => draft}

    {:ok, act} =
      Act.new(
        decision_ref: "decision",
        candidate_identity_key: "erase-sensitive-document",
        submission_context_ref: "context",
        authenticated_principal_ref: "agent",
        authentication_ref: "authentication",
        ingress_ref: "ingress",
        host_generation: 1,
        class: "data.erase",
        row: %{govern: true, write: true, attempt: true},
        consequence: consequence,
        material_digest: Portable.digest!(consequence),
        proposer_ref: "agent",
        executor_ref: "executor",
        authorizer_ref: "authorizer",
        accountable_ref: "owner",
        scope_ref: "scope",
        subject_refs: ["subject"],
        target_refs: [draft["target_ref"]],
        purpose_ref: "purpose",
        mandate_ref: "mandate",
        mandate_revision: 1,
        host_profile_ref: "profile",
        surface_revision: 1,
        executor_contract_ref: "contract",
        evidence_refs: ["evidence:original"],
        observation_window_ms: 50,
        committed_at: 100
      )

    act
  end
end
