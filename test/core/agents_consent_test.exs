defmodule Spectre.Core.AgentsConsentTest do
  use Spectre.Test.FullAgentCase, async: false

  alias Spectre.{Audit, Candidate, Consent, Instance, Ledger, Presentation}
  alias Spectre.Domain.{Event, Projection}
  alias Spectre.Ledger.Entry
  alias Spectre.V04Test.{Fixture, Ingress, Runtime}

  describe "agents requiring consent before refund execution" do
    @describetag consent: true

    setup c do
      data = %{"refund_cents" => 100}
      {:ok, data_digest} = Consent.data_digest(data)

      consent = %{
        schema_version: 1,
        recipient_refs: [c.fixture.refs.proposer],
        data_digest: data_digest,
        cost: 100,
        purpose_ref: c.fixture.refs.purpose,
        purpose_params: %{"currency" => "EUR"},
        risk: "money transfer",
        reversibility: false,
        alternatives: ["cancel"]
      }

      opts =
        Keyword.update!(mind_options(c, []), :candidate_attrs, &Map.put(&1, :consent, consent))

      assert {:ok, %{candidates: [draft]}} =
               Instance.turn(c.instance, input(c, "refund"), mind_opts: opts)

      assert {:ok, presentation} =
               Spectre.prepare_presentation(c.scope, %{
                 candidate_binding_ref: Candidate.presentation_binding_ref(draft),
                 scope_ref: c.fixture.refs.scope,
                 recipient_refs: consent.recipient_refs,
                 approval_source_refs: [Ingress.ref()],
                 data: data,
                 cost: consent.cost,
                 purpose_ref: consent.purpose_ref,
                 purpose_params: consent.purpose_params,
                 risk: consent.risk,
                 reversibility: consent.reversibility,
                 alternatives: consent.alternatives,
                 renderer_ref: "full-agent:renderer",
                 rendered_payload: "Refund 100 cents?",
                 prepared_at: Runtime.now()
               })

      %{draft: draft, presentation: presentation}
    end

    test "preparing a prompt neither displays it nor authorizes the agent's refund", c do
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, []))
      assert result.primary.decision.outcome == :undecidable
      assert result.primary.act == nil
      assert balance(c).available == 10_000
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "successful display alone is not user approval", c do
      show_consent(c)
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, []))
      assert result.primary.decision.outcome == :undecidable
      assert result.primary.act == nil
      assert balance(c).spent == 0
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "approval arriving in another authenticated Scope cannot approve this Scope's presentation",
         c do
      show = show_consent(c)

      assert {:ok, context} =
               Spectre.authenticate(c.scope.domain, "other-consent-session", %{
                 principal_ref: c.fixture.refs.proposer,
                 authentication_ref: "other-session-authentication",
                 session_ref: "other-session"
               })

      assert {:ok, other_scope} =
               Spectre.open_scope(c.scope.domain, context, opened_at: Runtime.now())

      # The host helper refuses this binding. Bypassing the helper with plain
      # observed data must not make the same response valid at the ledger edge.
      assert {:error, :presentation_response_scope_mismatch} =
               Presentation.response_evidence(
                 context,
                 c.presentation,
                 show,
                 :supports,
                 Runtime.now(),
                 []
               )

      attrs = consent_response(c, show, :supports) |> Map.from_struct() |> Map.delete(:ref)
      before = projection(c)

      assert {:error,
              {:invalid_presentation_approval_evidence, _, :presentation_approval_scope_mismatch}} =
               Spectre.observe(other_scope, attrs)

      assert projection(c) === before

      # Also try a fully rehashed entry, so hash-chain rejection cannot hide a
      # missing semantic check. The other Scope is genuinely open in this prefix.
      assert {:ok, foreign} = Ingress.observe(context, attrs, Runtime.now(), [])
      assert {:ok, payload} = Event.record(:evidence, foreign)
      snapshot = Fixture.snapshot(c.fixture)

      assert {:ok, [entry]} =
               Entry.build_batch(
                 snapshot.domain_ref,
                 "foreign-approval",
                 [payload],
                 snapshot.revision,
                 Runtime.now(),
                 snapshot.head_digest
               )

      forged = %{
        snapshot
        | entries: snapshot.entries ++ [entry],
          revision: entry.revision,
          head_digest: entry.digest
      }

      assert {:ok, _verified} = Ledger.verify_snapshot(forged)

      reason =
        {:invalid_presentation_approval_evidence, foreign.ref,
         :presentation_approval_scope_mismatch}

      assert {:error, ^reason} =
               Projection.replay(forged, c.fixture.constitution)

      assert {:error, {:semantic_violation, %{reason: ^reason}}} =
               Audit.verify(forged, c.fixture.constitution, Runtime.now())

      refute_received {:execution, _}
      assert_replay(c)
    end

    test "the full agent executes only after authenticated approval of the delivered prompt", c do
      show = show_consent(c)
      approval = approve_consent(c, show)
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, [approval.ref]))
      assert result.primary.act.presentation_ref == c.presentation.ref
      assert approval.ref in result.primary.act.recognition_evidence_refs
      assert_success(c, result)
      assert balance(c).spent == 100
      assert map_size(projection(c).attempts) == 2
    end

    test "nested consent assumptions are frozen in the Act and their later dispute creates durable debt",
         c do
      [shared, fee, risk] = consent_premises(c)
      c = bind_consent_premises(c, [shared, fee, risk])
      show = show_consent(c)
      approval = approve_with_assumptions(c, show, [fee.proposition, risk.proposition])
      basis = [shared.ref, fee.ref, risk.ref, approval.ref]

      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, [approval.ref]))

      assert result.primary.decision.outcome == :admitted,
             inspect(result.primary.decision.reasons)

      assert_success(c, result)
      assert Enum.all?(basis, &(&1 in result.primary.act.recognition_evidence_refs))
      before = projection(c)
      assert before.duties == %{}
      Runtime.set_time(Runtime.now() + 1)
      dispute = observe_consent_premise(c, shared.proposition, stance: :contradicts)

      after_dispute = projection(c)
      assert [duty] = Map.values(after_dispute.duties)
      assert duty.class == :disputed_evidence
      assert duty.act_ref == result.primary.act.ref
      assert duty.status == :open
      assert duty.opened_at == Runtime.now()
      assert dispute.ref in duty.evidence_refs
      assert Enum.all?(basis, &(&1 in duty.evidence_refs))
      assert duty.containment["retry"] == :forbidden
      assert after_dispute.acts === before.acts
      assert after_dispute.outcomes === before.outcomes
      assert balance(c).spent == 100
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "an approval cannot hide a missing nested premise from Candidate recognition", c do
      [shared, fee, risk] = consent_premises(c)
      c = bind_consent_premises(c, [fee, risk])
      show = show_consent(c)
      approval = approve_with_assumptions(c, show, [fee.proposition, risk.proposition])

      assert {:ok, result} =
               Instance.propose(c.instance, consent_candidate(c, [approval.ref]))

      assert result.primary.decision.outcome == :undecidable,
             inspect(result.primary.decision.reasons)

      assert result.primary.act == nil
      assert balance(c).spent == 0
      assert Map.has_key?(projection(c).evidence, shared.ref)
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "an explicit rejection leaves the agent unable to execute", c do
      show = show_consent(c)
      rejection = approve_consent(c, show, :contradicts)
      assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, [rejection.ref]))
      assert result.primary.decision.outcome == :refused
      assert result.primary.act == nil
      assert balance(c).spent == 0
      refute_received {:execution, _}
      assert_replay(c)
    end

    for status <- [:failed, :ambiguous, :definitive_no_effect] do
      @tag executor: status
      test "approval after a #{status} display cannot authorize the agent", c do
        show = show_consent(c, unquote(status))
        approval = consent_response(c, show, :supports)
        before = projection(c)

        assert {:error,
                {:invalid_presentation_approval_evidence, _,
                 :presentation_approval_precedes_successful_show}} =
                 Spectre.observe(c.scope, approval)

        assert projection(c) == before
        assert {:ok, result} = Instance.propose(c.instance, consent_candidate(c, []))
        refute result.primary.decision.outcome == :admitted
        assert result.primary.act == nil
        assert balance(c).spent == 0
        refute_received {:execution, _}
        assert_replay(c)
      end
    end

    test "approval is bound to the displayed cost, not merely to the user and order", c do
      show = show_consent(c)
      approval = approve_consent(c, show)
      candidate = consent_candidate(c, [approval.ref])

      {:ok, changed} =
        candidate
        |> Map.from_struct()
        |> Map.drop([:ref, :material_digest])
        |> Map.update!(:consent, &Map.put(&1, "cost", 1000))
        |> Candidate.new()

      assert {:ok, result} = Instance.propose(c.instance, changed)
      assert result.primary.decision.outcome == :undecidable
      assert result.primary.act == nil
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "retrying a consented proposal cannot display or pay a second time", c do
      show = show_consent(c)
      approval = approve_consent(c, show)
      candidate = consent_candidate(c, [approval.ref])
      assert {:ok, first} = Instance.propose(c.instance, candidate)
      assert_success(c, first)
      before = projection(c)
      assert {:ok, repeated} = Instance.propose(c.instance, candidate)
      assert repeated.primary.act == first.primary.act
      assert projection(c) == before
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  defp show_consent(c, status \\ :succeeded) do
    assert {:ok, result} =
             Spectre.show_presentation(c.scope, c.presentation.ref, %{
               identity_key: "full-agent:show",
               requested_mandate_ref: c.fixture.mandate.ref,
               accountable_ref: c.fixture.refs.accountable,
               executor_ref: c.fixture.refs.executor,
               executor_contract_ref: c.fixture.refs.executor_contract,
               subject_refs: [c.fixture.refs.customer],
               evidence_refs: c.draft.evidence_refs,
               observation_window_ms: 5000
             })

    assert result.primary.decision.outcome == :admitted
    assert result.primary.outcome.status == status
    assert_receive {:execution, %{act: %{class: "presentation.show"}, attempt_durable: true}}
    assert balance(c).spent == 0
    Runtime.set_time(Runtime.now() + 1)
    result.primary.act
  end

  defp approve_consent(c, show, stance \\ :supports) do
    approval = consent_response(c, show, stance)
    assert {:ok, [recorded]} = Spectre.observe(c.scope, approval)
    recorded
  end

  defp consent_response(c, show, stance) do
    {:ok, approval} =
      Presentation.response_evidence(
        Fixture.context(c.fixture),
        c.presentation,
        show,
        stance,
        Runtime.now(),
        payload: "user response"
      )

    approval
  end

  defp consent_premises(c) do
    shared = observe_consent_premise(c, "terms-known")
    fee = observe_consent_premise(c, "fee-known", assumptions: [shared.proposition])
    risk = observe_consent_premise(c, "risk-known", assumptions: [shared.proposition])
    [shared, fee, risk]
  end

  defp bind_consent_premises(c, premises) do
    assert {:ok, draft} =
             c.draft
             |> Map.from_struct()
             |> Map.drop([:ref, :material_digest])
             |> Map.update!(:evidence_refs, &(&1 ++ Enum.map(premises, fn item -> item.ref end)))
             |> Candidate.new()

    attrs =
      c.presentation
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:candidate_binding_ref, Candidate.presentation_binding_ref(draft))

    assert {:ok, presentation} = Spectre.prepare_presentation(c.scope, attrs)
    %{c | draft: draft, presentation: presentation}
  end

  defp observe_consent_premise(c, proposition, attrs \\ []) do
    attrs =
      Map.merge(
        %{
          proposition: proposition,
          issuer_ref: c.fixture.refs.proposer,
          payload: "user observation"
        },
        Map.new(attrs)
      )

    assert {:ok, evidence} =
             Spectre.Ingress.evidence(c.scope.context, Runtime.now(), attrs)

    assert {:ok, [recorded]} = Spectre.observe(c.scope, evidence)
    recorded
  end

  defp approve_with_assumptions(c, show, assumptions) do
    assert {:ok, evidence} =
             Presentation.response_evidence(
               c.scope.context,
               c.presentation,
               show,
               :supports,
               Runtime.now(),
               assumptions: assumptions,
               payload: "conditional approval"
             )

    assert {:ok, [recorded]} = Spectre.observe(c.scope, evidence)
    recorded
  end

  defp consent_candidate(c, approvals) do
    {:ok, candidate} =
      c.draft
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:presentation_ref, c.presentation.ref)
      |> Map.put(:evidence_refs, c.draft.evidence_refs ++ approvals)
      |> Candidate.new()

    candidate
  end
end
