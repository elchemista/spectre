Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.ConsentDagTest do
  use ExUnit.Case, async: false

  alias Spectre.{Candidate, Consent, Evidence, Presentation}
  alias Spectre.Domain.Sequencer
  alias Spectre.Kernel, as: AdmissionKernel
  alias Spectre.V04Test.{Fixture, Ingress, Runtime}

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
    assert {:ok, ^act} = act |> Spectre.Act.canonical() |> Spectre.Act.from_canonical()

    assert {:ok, report} =
             Spectre.Audit.verify(
               Fixture.snapshot(ctx.fixture),
               ctx.fixture.constitution,
               Runtime.now()
             )

    assert report.counts.acts == 2
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
