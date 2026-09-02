defmodule Spectre.V04Test.ConsentDagTest do
  use ExUnit.Case, async: true

  alias Spectre.{
    Candidate,
    Evidence,
    HostProfile,
    Mandate,
    Presentation,
    Row,
    SubmissionContext,
    Surface
  }

  alias Spectre.Act
  alias Spectre.Domain.Event
  alias Spectre.Domain.Projection
  alias Spectre.Kernel, as: AdmissionKernel

  @now 1_000_000

  test "the pre-consent binding is exact, acyclic, and stable across consent records" do
    row = record!(Row.new(%{present: true}))
    draft = candidate!(row)

    expected_binding = %{
      "schema_version" => 1,
      "identity_key" => "candidate:consent:one",
      "class" => "delivery.send",
      "consequence" => %{"message_ref" => "message:one"},
      "row" => Row.canonical(row),
      "requested_mandate_ref" => "mandate:delivery",
      "proposer_ref" => "principal:agent",
      "executor_ref" => "principal:delivery-executor",
      "accountable_ref" => "principal:merchant",
      "scope_ref" => "scope:delivery",
      "subject_refs" => ["subject:customer"],
      "target_refs" => ["target:customer-channel"],
      "purpose_ref" => "purpose:order-update",
      "purpose_params" => %{"locale" => "it-IT"},
      "meter_requests" => %{},
      "executor_contract_ref" => "executor-contract:delivery-v1",
      "observation_window_ms" => 5_000
    }

    assert Candidate.presentation_binding(draft) == expected_binding
    draft_binding_ref = Candidate.presentation_binding_ref(draft)

    presentation = presentation!(draft_binding_ref)
    approval = approval!(presentation.ref)

    final =
      candidate!(row,
        presentation_ref: presentation.ref,
        evidence_refs: [approval.ref]
      )

    assert Candidate.presentation_binding(final) == expected_binding
    assert Candidate.presentation_binding_ref(final) == draft_binding_ref
    refute final.material_digest == draft.material_digest
    refute final.ref == draft.ref

    changed = candidate!(row, purpose_params: %{"locale" => "en-GB"})
    refute Candidate.presentation_binding_ref(changed) == draft_binding_ref
  end

  test "Presentation accepts only candidate_binding_ref and closes the approval proposition" do
    row = record!(Row.new(%{present: true}))
    candidate = candidate!(row)
    binding_ref = Candidate.presentation_binding_ref(candidate)
    presentation = presentation!(binding_ref)

    assert presentation.candidate_binding_ref == binding_ref

    assert Presentation.approval_proposition(presentation.ref) == %{
             "contract_ref" => "spectre.presentation.approval.v1",
             "presentation_ref" => presentation.ref
           }

    legacy_attrs =
      binding_ref
      |> presentation_attrs()
      |> Map.delete(:candidate_binding_ref)
      |> Map.put(:candidate_ref, candidate.ref)

    assert {:error, {:unknown_attribute, :presentation, :candidate_ref}} =
             Presentation.new(legacy_attrs)

    canonical = Presentation.canonical(presentation)
    assert canonical["candidate_binding_ref"] == binding_ref
    refute Map.has_key?(canonical, "candidate_ref")
    assert {:ok, ^presentation} = Presentation.from_canonical(canonical)
  end

  test "admission requires current observed approval of the exact Presentation" do
    %{row: row, mandate: mandate, projection: base_projection, context: context} = foundations()
    draft = candidate!(row, requested_mandate_ref: mandate.ref)
    presentation = presentation!(Candidate.presentation_binding_ref(draft))
    approval = approval!(presentation.ref)

    projection = %{
      base_projection
      | presentations: %{presentation.ref => presentation},
        evidence: %{approval.ref => approval}
    }

    candidate =
      candidate!(row,
        requested_mandate_ref: mandate.ref,
        presentation_ref: presentation.ref,
        evidence_refs: [approval.ref]
      )

    assert {:ok, decision, %Act{} = act} =
             AdmissionKernel.evaluate(candidate, context, projection, @now)

    assert decision.outcome == :admitted
    assert act.presentation_ref == presentation.ref
    assert act.evidence_refs == [approval.ref]
    assert act.requested_mandate_ref == candidate.requested_mandate_ref
    assert act.material_digest == candidate.material_digest
    assert {:ok, ^act} = act |> Act.canonical() |> Act.from_canonical()

    tampered_act = act |> Act.canonical() |> Map.put("requested_mandate_ref", nil)

    assert {:error, {:content_ref_mismatch, existing_ref, expected_ref}} =
             Act.from_canonical(tampered_act)

    assert existing_ref == act.ref
    refute expected_ref == act.ref

    assert {:ok, decision_event} = Event.record(:decision, decision)

    assert {:ok, after_decision} =
             Projection.apply_payload(projection, decision_event, projection.revision + 1)

    after_decision = %{after_decision | revision: projection.revision + 1}
    assert {:ok, act_event} = Event.record(:act, act)

    assert {:ok, replayed} =
             Projection.apply_payload(after_decision, act_event, after_decision.revision + 1)

    assert replayed.acts[act.ref] == act

    no_approval =
      candidate!(row,
        requested_mandate_ref: mandate.ref,
        presentation_ref: presentation.ref
      )

    assert {:ok, undecidable, nil} =
             AdmissionKernel.evaluate(no_approval, context, projection, @now)

    assert undecidable.outcome == :undecidable

    assert {:evidence_condition_undecidable, :presentation_approval_evidence_required} in undecidable.reasons

    other_approval = approval!("presentation:" <> String.duplicate("f", 64))

    wrong_projection = %{
      projection
      | evidence: %{other_approval.ref => other_approval}
    }

    wrong_candidate =
      candidate!(row,
        requested_mandate_ref: mandate.ref,
        presentation_ref: presentation.ref,
        evidence_refs: [other_approval.ref]
      )

    assert {:ok, wrong_decision, nil} =
             AdmissionKernel.evaluate(wrong_candidate, context, wrong_projection, @now)

    assert wrong_decision.outcome == :undecidable

    assert {:evidence_condition_undecidable, :presentation_approval_evidence_required} in wrong_decision.reasons

    premature_approval = approval!(presentation.ref, observed_at: @now - 11)

    premature_projection = %{
      projection
      | evidence: %{premature_approval.ref => premature_approval}
    }

    premature_candidate =
      candidate!(row,
        requested_mandate_ref: mandate.ref,
        presentation_ref: presentation.ref,
        evidence_refs: [premature_approval.ref]
      )

    assert {:ok, premature_decision, nil} =
             AdmissionKernel.evaluate(
               premature_candidate,
               context,
               premature_projection,
               @now
             )

    assert premature_decision.outcome == :undecidable

    assert {:evidence_condition_undecidable, :presentation_approval_not_current_or_final} in premature_decision.reasons
  end

  test "a current contradiction for the exact Presentation refuses admission" do
    %{row: row, mandate: mandate, projection: projection, context: context} = foundations()
    draft = candidate!(row, requested_mandate_ref: mandate.ref)
    presentation = presentation!(Candidate.presentation_binding_ref(draft))
    contradiction = approval!(presentation.ref, stance: :contradicts)

    projection = %{
      projection
      | presentations: %{presentation.ref => presentation},
        evidence: %{contradiction.ref => contradiction}
    }

    candidate =
      candidate!(row,
        requested_mandate_ref: mandate.ref,
        presentation_ref: presentation.ref,
        evidence_refs: [contradiction.ref]
      )

    assert {:ok, decision, nil} =
             AdmissionKernel.evaluate(candidate, context, projection, @now)

    assert decision.outcome == :refused

    assert {:evidence_condition_unsatisfied, :presentation_approval_contradicted} in decision.reasons
  end

  defp foundations do
    row = record!(Row.new(%{present: true}))

    surface =
      record!(
        Surface.new(%{
          revision: 4,
          declarations: %{"delivery.send" => row}
        })
      )

    host_profile =
      record!(
        HostProfile.new(%{
          mode: :development,
          attestation_ref: "attestation:test-host",
          assumptions: ["test projection"],
          declared_at: @now - 100
        })
      )

    mandate =
      record!(
        Mandate.new(%{
          revision: 1,
          grantor_ref: "principal:grantor",
          holder_ref: "principal:agent",
          accountable_ref: "principal:merchant",
          executor_refs: ["principal:delivery-executor"],
          executor_contract_refs: ["executor-contract:delivery-v1"],
          scope_refs: ["scope:delivery"],
          subject_refs: ["subject:customer"],
          target_refs: ["target:customer-channel"],
          classes: ["delivery.send"],
          ceiling: row,
          purpose_ref: "purpose:order-update",
          purpose_params: %{"locale" => "it-IT"},
          conditions: [],
          not_before: @now - 1_000,
          expires_at: @now + 1_000,
          meters: %{},
          delegation: %{"allowed" => false, "max_depth" => 0},
          revocation: %{
            "mode" => :cascade,
            "controller_refs" => ["principal:grantor"]
          },
          source_ref: "genesis:delivery"
        })
      )

    context =
      record!(
        SubmissionContext.new(%{
          domain_ref: "domain:delivery",
          scope_ref: "scope:delivery",
          authenticated_principal_ref: "principal:agent",
          authentication_ref: "authentication:test",
          ingress_ref: "ingress:test",
          host_generation: 9
        })
      )

    projection = %{
      Projection.new("domain:delivery")
      | revision: 12,
        surface: surface,
        host_profile: host_profile,
        principals: %{"principal:agent" => %{}},
        mandates: %{mandate.ref => mandate},
        meters: %{mandate.ref => %{}}
    }

    %{row: row, mandate: mandate, projection: projection, context: context}
  end

  defp candidate!(row, overrides \\ []) do
    attrs = %{
      identity_key: "candidate:consent:one",
      class: "delivery.send",
      consequence: %{"message_ref" => "message:one"},
      row: row,
      requested_mandate_ref: "mandate:delivery",
      proposer_ref: "principal:agent",
      executor_ref: "principal:delivery-executor",
      accountable_ref: "principal:merchant",
      scope_ref: "scope:delivery",
      subject_refs: ["subject:customer"],
      target_refs: ["target:customer-channel"],
      purpose_ref: "purpose:order-update",
      purpose_params: %{"locale" => "it-IT"},
      evidence_refs: [],
      presentation_ref: nil,
      meter_requests: %{},
      executor_contract_ref: "executor-contract:delivery-v1",
      observation_window_ms: 5_000
    }

    record!(Candidate.new(Map.merge(attrs, Map.new(overrides))))
  end

  defp presentation!(candidate_binding_ref) do
    record!(Presentation.new(presentation_attrs(candidate_binding_ref)))
  end

  defp presentation_attrs(candidate_binding_ref) do
    %{
      candidate_binding_ref: candidate_binding_ref,
      recipient_refs: ["subject:customer"],
      data: %{"message_ref" => "message:one"},
      cost: %{"currency" => "EUR", "value" => 0},
      purpose_ref: "purpose:order-update",
      purpose_params: %{"locale" => "it-IT"},
      risk: %{"level" => "low"},
      reversibility: %{"kind" => "irreversible"},
      alternatives: [%{"kind" => "do_not_send"}],
      renderer_ref: "renderer:consent-v1",
      rendered_payload: %{"text" => "Inviare l'aggiornamento?"},
      presented_at: @now - 10
    }
  end

  defp approval!(presentation_ref, overrides \\ []) do
    attrs = %{
      proposition: Presentation.approval_proposition(presentation_ref),
      stance: :supports,
      issuer_ref: "subject:customer",
      source_ref: "ingress:customer-consent",
      provenance: :observed,
      observed_at: @now - 5,
      bindings: %{},
      assumptions: [],
      labels: [],
      payload: %{"approved" => true},
      provisional: false
    }

    record!(Evidence.new(Map.merge(attrs, Map.new(overrides))))
  end

  defp record!({:ok, record}), do: record
end
