Code.require_file("../helper.exs", __DIR__)
Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.GAM.V04Test.ConsentDagTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.{Candidate, Consent, Evidence, Presentation, Row}
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.Erasure.Analysis
  alias Spectre.GAM.GovernedAct.Admission.Binding
  alias Spectre.GAM.GovernedAct.ReadIndex
  alias Spectre.GAM.GovernedAct.Transition.Admission.Presentation, as: PresentationProof
  alias Spectre.GAM.Kernel, as: AdmissionKernel
  alias Spectre.GAM.V04Test.{Fixture, Ingress, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "consent", consent: true)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)
    data = %{"refund_cents" => 500}
    {:ok, data_digest} = Consent.data_digest(data)

    consent = %{
      schema_version: 1,
      recipient_refs: [fixture.refs.proposer],
      data_digest: data_digest,
      cost: 500,
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      risk: "irreversible payment",
      reversibility: false,
      alternatives: ["cancel"]
    }

    attrs = Map.put(Fixture.refund_candidate(fixture, 500), :consent, consent)
    {:ok, draft} = Candidate.new(attrs)

    {:ok, presentation} =
      Presentation.new(%{
        candidate_binding_ref: Candidate.presentation_binding_ref(draft),
        scope_ref: fixture.refs.scope,
        recipient_refs: consent.recipient_refs,
        approval_source_refs: [Ingress.ref()],
        data: data,
        cost: consent.cost,
        purpose_ref: consent.purpose_ref,
        purpose_params: consent.purpose_params,
        risk: consent.risk,
        reversibility: consent.reversibility,
        alternatives: consent.alternatives,
        renderer_ref: "test:renderer",
        rendered_payload: "Refund 500 cents?",
        prepared_at: Runtime.now()
      })

    assert {:ok, ^presentation} =
             Sequencer.record_presentation(fixture.server, Fixture.context(fixture), presentation)

    %{fixture: fixture, draft: draft, attrs: attrs, presentation: presentation}
  end

  test "pre-consent binding excludes only the verified approval basis", ctx do
    {show, _outcome} = show!(ctx)
    approval = response!(ctx, show, :supports)
    candidate = final_candidate(ctx, [approval.ref])
    expected = Candidate.presentation_binding(ctx.draft)
    assert Candidate.presentation_binding(candidate, [approval.ref]) == expected

    assert Candidate.presentation_binding_ref(candidate, [approval.ref]) ==
             ctx.presentation.candidate_binding_ref

    refute Candidate.presentation_binding(candidate) == expected
    refute candidate.material_digest == ctx.draft.material_digest
    assert expected["evidence_refs"] == ctx.draft.evidence_refs
    assert expected["consent"] == ctx.draft.consent
    assert expected["disclosure"] != nil
    changed = ctx.attrs |> Map.put(:identity_key, "changed") |> Candidate.new() |> ok!()
    refute Candidate.presentation_binding_ref(changed) == ctx.presentation.candidate_binding_ref
  end

  test "prepared material round-trips and approval names the exact show Act", ctx do
    canonical = Presentation.canonical(ctx.presentation)
    assert {:ok, restored} = Presentation.from_canonical(canonical)
    assert restored == ctx.presentation

    assert Presentation.approval_proposition(ctx.presentation.ref, "act:show") == %{
             "contract_ref" => "spectre.presentation.approval.v1",
             "presentation_ref" => ctx.presentation.ref,
             "show_act_ref" => "act:show"
           }

    legacy = ctx.presentation |> Map.from_struct() |> Map.put(:candidate_ref, ctx.draft.ref)

    assert {:error, {:unknown_attribute, :presentation, :candidate_ref}} =
             Presentation.new(legacy)
  end

  test "admission and replay require observed approval after successful delivery", ctx do
    {show, _outcome} = show!(ctx)
    approval = response!(ctx, show, :supports)
    assert {:ok, ^approval} = Fixture.observe_payment(ctx.fixture, approval)
    candidate = final_candidate(ctx, [approval.ref])

    assert {:ok, %{decision: decision, act: act}} =
             Sequencer.submit(ctx.fixture.server, Fixture.context(ctx.fixture), candidate)

    assert decision.outcome == :admitted, inspect(decision.reasons)
    assert act.presentation_ref == ctx.presentation.ref
    assert approval.ref in act.recognition_evidence_refs
    assert {:ok, ^act} = act |> Spectre.GAM.Act.canonical() |> Spectre.GAM.Act.from_canonical()

    assert {:ok, report} =
             Spectre.GAM.Audit.verify(
               Fixture.snapshot(ctx.fixture),
               ctx.fixture.constitution,
               Runtime.now()
             )

    assert report.counts.acts == 2
  end

  test "valid approval cannot be recycled after changing any consent material", ctx do
    {show, _outcome} = show!(ctx)
    approval = response!(ctx, show, :supports)
    assert {:ok, ^approval} = Fixture.observe_payment(ctx.fixture, approval)
    candidate = final_candidate(ctx, [approval.ref])
    assert {:ok, %{outcome: :admitted}, _act} = evaluate(ctx, candidate)
    before = Sequencer.projection(ctx.fixture.server)

    for {field, value} <- [
          {"recipient_refs", [ctx.fixture.refs.executor]},
          {"data_digest", Consent.data_digest(%{"refund_cents" => 5_000}) |> ok!()},
          {"cost", 5_000},
          {"risk", "no risk"},
          {"reversibility", true},
          {"alternatives", []}
        ] do
      assert {:ok, forged} =
               candidate
               |> Map.from_struct()
               |> Map.drop([:ref, :material_digest])
               |> Map.update!(:consent, &Map.put(&1, field, value))
               |> Candidate.new()

      # Recompute canonical identity: rejection must be semantic, not a stale
      # digest. The original, genuinely observed approval remains in Evidence.
      assert forged.material_digest != candidate.material_digest
      assert approval.ref in forged.evidence_refs
      assert {:ok, decision, nil} = evaluate(ctx, forged)
      # The changed proposal lacks applicable approval. That is undecidable,
      # not a claim that the newly proposed consequence is itself forbidden.
      assert decision.outcome == :undecidable, inspect({field, decision.reasons})

      assert {:evidence_condition_undecidable,
              {:invalid_presentation, :presentation_consent_material_mismatch}} in decision.reasons

      assert Sequencer.projection(ctx.fixture.server) == before
    end

    for {field, value} <- [
          {"purpose_ref", "another-purpose"},
          {"purpose_params", %{"currency" => "USD"}}
        ] do
      assert {:error, :consent_purpose_mismatch} =
               candidate
               |> Map.from_struct()
               |> Map.drop([:ref, :material_digest])
               |> Map.update!(:consent, &Map.put(&1, field, value))
               |> Candidate.new()
    end
  end

  test "prepared material alone is not evidence that it was shown", ctx do
    assert {:ok, decision, nil} = evaluate(ctx, final_candidate(ctx, []))
    assert decision.outcome == :undecidable

    assert {:evidence_condition_undecidable, :presentation_approval_evidence_required} in decision.reasons

    assert Sequencer.projection(ctx.fixture.server).attempts == %{}
  end

  test "a current authenticated contradiction refuses admission", ctx do
    {show, _outcome} = show!(ctx)
    response = response!(ctx, show, :contradicts)
    assert {:ok, ^response} = Fixture.observe_payment(ctx.fixture, response)
    assert {:ok, decision, nil} = evaluate(ctx, final_candidate(ctx, [response.ref]))
    assert decision.outcome == :refused

    assert {:evidence_condition_unsatisfied, :presentation_approval_contradicted} in decision.reasons
  end

  for stance <- [:supports, :contradicts] do
    test "indexed consent keeps nested assumptions and #{stance} counterproofs", ctx do
      nested =
        Fixture.paid_evidence(ctx.fixture, %{
          proposition: "nested",
          issuer_ref: ctx.fixture.refs.proposer
        })

      basis =
        Fixture.paid_evidence(ctx.fixture, %{
          proposition: "basis",
          issuer_ref: ctx.fixture.refs.proposer,
          assumptions: ["nested"]
        })

      # Assumption Evidence is part of the material shown, unlike approval
      # responses. Adding it only after the show must fail the consent binding.
      for item <- [nested, basis] do
        assert {:ok, ^item} = Fixture.observe_payment(ctx.fixture, item)
      end

      ctx = with_consent_basis(ctx, [nested.ref, basis.ref])
      {show, _outcome} = show!(ctx)
      response = response!(ctx, show, :supports)
      attrs = response |> Map.from_struct() |> Map.drop([:ref])
      approval = Evidence.new(Map.put(attrs, :assumptions, ["basis"])) |> ok!()
      opposing = response!(ctx, show, unquote(stance))

      for item <- [approval, opposing] do
        assert {:ok, ^item} = Fixture.observe_payment(ctx.fixture, item)
      end

      for n <- 1..30 do
        evidence =
          Evidence.new(Map.merge(attrs, %{proposition: "noise-#{n}", assumptions: []})) |> ok!()

        assert {:ok, ^evidence} = Fixture.observe_payment(ctx.fixture, evidence)
      end

      projection = Sequencer.projection(ctx.fixture.server)
      all = projection |> Analysis.available_evidence() |> Map.values()

      selected =
        ReadIndex.evidence_for(projection, ctx.fixture.mandate.conditions, ctx.presentation.ref)

      {acts, outcomes} = ReadIndex.presentation_history(projection, ctx.presentation.ref)

      indexed =
        Presentation.classify_responses(ctx.presentation, acts, outcomes, selected, Runtime.now())

      exhaustive =
        Presentation.classify_responses(
          ctx.presentation,
          projection.acts,
          Map.values(projection.outcomes),
          all,
          Runtime.now()
        )

      assert indexed === exhaustive

      assert elem(indexed, 0) ===
               if(unquote(stance) === :supports, do: :supported, else: :contradicted)

      selected_refs = MapSet.new(selected, & &1.ref)

      assert MapSet.subset?(
               MapSet.new([nested.ref, basis.ref, approval.ref, opposing.ref]),
               selected_refs
             )

      assert length(selected) < map_size(projection.evidence) - 20
      assert Map.keys(acts) === [show.ref]

      candidate = final_candidate(ctx, elem(indexed, 1))
      context = Fixture.context(ctx.fixture)
      result = AdmissionKernel.evaluate(candidate, context, projection, Runtime.now())
      assert {:ok, decision, _act} = result

      assert decision.outcome === if(unquote(stance) === :supports, do: :admitted, else: :refused),
             inspect(decision.reasons)

      assert result ===
               AdmissionKernel.evaluate(
                 candidate,
                 context,
                 %{projection | read_index: %ReadIndex{}},
                 Runtime.now()
               )

      assert {:ok, %{decision: committed}} =
               Sequencer.submit(ctx.fixture.server, context, candidate)

      assert committed.outcome === decision.outcome

      assert {:ok, _report} =
               Spectre.GAM.Audit.verify(
                 Fixture.snapshot(ctx.fixture),
                 ctx.fixture.constitution,
                 Runtime.now()
               )
    end
  end

  test "premature and wrong-show responses cannot establish consent", ctx do
    {show, outcome} = show!(ctx)
    response = response!(ctx, show, :supports)

    premature =
      response
      |> Map.from_struct()
      |> Map.drop([:ref])
      |> Map.put(:observed_at, outcome.observed_at - 1)
      |> Evidence.new()
      |> ok!()

    assert {:error, _} =
             Presentation.validate_approval(
               premature,
               ctx.presentation,
               show,
               [outcome],
               [premature],
               Runtime.now()
             )

    wrong =
      response
      |> Map.from_struct()
      |> Map.drop([:ref])
      |> Map.put(
        :proposition,
        Presentation.approval_proposition(ctx.presentation.ref, "act:other")
      )
      |> Evidence.new()
      |> ok!()

    assert {:error, _} =
             Presentation.validate_approval(
               wrong,
               ctx.presentation,
               show,
               [outcome],
               [wrong],
               Runtime.now()
             )
  end

  test "consent replay fails closed across missing, stale and contradictory material", ctx do
    {show, outcome} = show!(ctx)
    show_ref = show.ref
    show_projection = Sequencer.projection(ctx.fixture.server)
    {:ok, show_candidate} = Binding.candidate(show)

    assert {:ok, []} = PresentationProof.validate(show_projection, show_candidate, show, [])

    assert {:error, {:act_presentation_not_found, ^show_ref}} =
             PresentationProof.validate(
               %{show_projection | presentations: %{}},
               show_candidate,
               show,
               []
             )

    future_presentation = %{ctx.presentation | prepared_at: show.committed_at + 1}
    state = put_in(show_projection.presentations[ctx.presentation.ref], future_presentation)

    assert {:error, {:act_presentation_show_precedes_preparation, ^show_ref}} =
             PresentationProof.validate(state, show_candidate, show, [])

    assert {:error, {:invalid_presentation_show_act, ^show_ref, :presentation_show_row_mismatch}} =
             PresentationProof.validate(
               show_projection,
               %{show_candidate | row: %Row{}},
               show,
               []
             )

    approval = response!(ctx, show, :supports)
    assert {:ok, ^approval} = Fixture.observe_payment(ctx.fixture, approval)
    candidate = final_candidate(ctx, [approval.ref])
    assert {:ok, %{outcome: :admitted} = decision, act} = evaluate(ctx, candidate)
    act_ref = act.ref
    presentation_ref = ctx.presentation.ref
    projection = Sequencer.projection(ctx.fixture.server)

    assert {:ok, [approval_ref]} =
             PresentationProof.validate(projection, candidate, act, [approval])

    assert approval_ref == approval.ref

    assert {:error, {:act_presentation_approval_missing, ^act_ref}} =
             PresentationProof.validate(projection, candidate, act, [])

    contradiction = response!(ctx, show, :contradicts)

    assert {:error, {:act_presentation_approval_contradicted, ^act_ref}} =
             PresentationProof.validate(projection, candidate, act, [contradiction])

    from_future = rebuild_evidence(approval, observed_at: act.committed_at + 1)

    assert {:error, {:act_presentation_approval_not_current_or_final, ^act_ref}} =
             PresentationProof.validate(projection, candidate, act, [from_future])

    changed = %{ctx.presentation | candidate_binding_ref: "candidate-binding:other"}
    changed_projection = put_in(projection.presentations[ctx.presentation.ref], changed)

    assert {:error, {:act_presentation_binding_mismatch, ^act_ref}} =
             PresentationProof.validate(changed_projection, candidate, act, [approval])

    assert {:error, {:act_presentation_not_found, ^act_ref, ^presentation_ref}} =
             PresentationProof.validate(
               %{projection | presentations: %{}},
               candidate,
               act,
               [approval]
             )

    # These delegates are application-facing boundaries. Invalid shapes and
    # temporal states must remain distinguishable without entering Admission.
    assert {:error, :invalid_presentation_response_evidence} =
             Presentation.response_evidence(nil, ctx.presentation, show, :supports, 0, [])

    assert {:error, :invalid_presentation_response} =
             Presentation.validate_response_with_basis(nil, ctx.presentation, show, [], [], 0)

    assert {:error, :invalid_presentation_approval} =
             Presentation.validate_approval_with_basis(nil, ctx.presentation, show, [], [], 0)

    assert {:error, :invalid_presentation_assumption_evidence} =
             Presentation.validate_assumption_contradiction_with_basis(
               nil,
               approval,
               ctx.presentation,
               [],
               0
             )

    contradiction_ref = contradiction.ref

    assert {:ok, [^contradiction_ref]} =
             Presentation.validate_approval_contradiction_with_basis(
               contradiction,
               ctx.presentation,
               show,
               [outcome],
               [contradiction],
               contradiction.observed_at
             )

    unrelated =
      Fixture.paid_evidence(ctx.fixture, %{
        proposition: "not-a-presentation-response",
        issuer_ref: ctx.fixture.refs.proposer
      })

    assert {:error, :not_presentation_approval} =
             Presentation.validate_approval(
               unrelated,
               ctx.presentation,
               show,
               [outcome],
               [unrelated],
               unrelated.observed_at
             )

    not_yet_valid = rebuild_evidence(approval, valid_from: approval.observed_at + 10)

    assert {:error, :presentation_approval_not_yet_valid} =
             Presentation.validate_approval(
               not_yet_valid,
               ctx.presentation,
               show,
               [outcome],
               [not_yet_valid],
               approval.observed_at
             )

    expired = rebuild_evidence(approval, valid_until: approval.observed_at + 5)

    assert {:error, :presentation_approval_expired} =
             Presentation.validate_approval(
               expired,
               ctx.presentation,
               show,
               [outcome],
               [expired],
               expired.valid_until
             )

    assert {:error, :presentation_approval_from_future} =
             Presentation.validate_approval(
               from_future,
               ctx.presentation,
               show,
               [outcome],
               [from_future],
               act.committed_at
             )

    assert :ok =
             Presentation.validate_approval(
               approval,
               ctx.presentation,
               show,
               [:corrupt_outcome, outcome],
               [approval],
               approval.observed_at
             )

    # The locally evaluated Decision is deliberately not appended by this
    # proof test; replay input remains the acknowledged prefix.
    assert decision.ref not in Map.keys(projection.decisions)
  end

  defp show!(ctx) do
    fixture = ctx.fixture

    attrs =
      ctx.attrs
      |> Map.merge(%{
        identity_key: "consent:show",
        class: Presentation.show_class(),
        row: Presentation.show_row(),
        consequence: Presentation.show_consequence(ctx.presentation),
        consent: nil,
        disclosure: ctx.presentation.disclosure,
        target_refs: ctx.presentation.recipient_refs,
        meter_requests: %{}
      })

    assert {:ok, %{decision: decision, act: act, grant: grant}} =
             Sequencer.submit(fixture.server, Fixture.context(fixture), attrs)

    assert decision.outcome == :admitted, inspect(decision.reasons)
    assert {:ok, ^act, attempt, _checkout} = Sequencer.consume_grant(fixture.server, grant)
    Runtime.set_time(Runtime.now() + 1)
    receipt = Fixture.receipt_evidence(fixture, act.ref)
    assert {:ok, ^receipt} = Fixture.record_receipt(fixture, receipt)
    outcome = Fixture.outcome(fixture, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)
    Runtime.set_time(Runtime.now() + 1)
    {act, outcome}
  end

  defp with_consent_basis(ctx, refs) do
    attrs = Map.update!(ctx.attrs, :evidence_refs, &(&1 ++ refs))
    draft = attrs |> Candidate.new() |> ok!()

    presentation =
      ctx.presentation
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:candidate_binding_ref, Candidate.presentation_binding_ref(draft))
      |> Presentation.new()
      |> ok!()

    assert {:ok, ^presentation} =
             Sequencer.record_presentation(
               ctx.fixture.server,
               Fixture.context(ctx.fixture),
               presentation
             )

    %{ctx | attrs: attrs, draft: draft, presentation: presentation}
  end

  defp response!(ctx, show, stance) do
    Presentation.response_evidence(
      Fixture.context(ctx.fixture),
      ctx.presentation,
      show,
      stance,
      Runtime.now(),
      payload: %{"response" => Atom.to_string(stance)}
    )
    |> ok!()
  end

  defp final_candidate(ctx, response_refs) do
    ctx.attrs
    |> Map.put(:presentation_ref, ctx.presentation.ref)
    |> Map.put(:evidence_refs, ctx.draft.evidence_refs ++ response_refs)
    |> Candidate.new()
    |> ok!()
  end

  defp rebuild_evidence(evidence, changes) do
    evidence
    |> Map.from_struct()
    |> Map.drop([:ref])
    |> Map.merge(Map.new(changes))
    |> Evidence.new()
    |> ok!()
  end

  defp evaluate(ctx, candidate) do
    AdmissionKernel.evaluate(
      candidate,
      Fixture.context(ctx.fixture),
      Sequencer.projection(ctx.fixture.server),
      Runtime.now()
    )
  end

  defp ok!({:ok, value}), do: value
end
