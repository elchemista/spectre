defmodule Spectre.KernelRecognitionBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Candidate, Condition, Consent, Evidence, Presentation, Row, Surface}
  alias Spectre.GovernedAct.{ReadIndex, State}
  alias Spectre.Kernel, as: Admission
  alias Spectre.Kernel.Recognition
  alias Spectre.V04Test.Fixture

  test "input and foundation errors cannot become Decisions in the wrong Domain", c do
    context = Fixture.context(c.f)
    time = c.act.committed_at

    assert {:error, {:invalid_trusted_time, 1.0}} =
             Admission.evaluate(c.candidate, context, c.before, 1.0)

    assert {:error, :invalid_admission_input} = Admission.evaluate(%{}, context, c.before, time)

    assert {:error, {:submission_domain_mismatch, _, "foreign"}} =
             Admission.evaluate(c.candidate, context, %{c.before | domain_ref: "foreign"}, time)

    state = c.before

    assert {:error, :surface_not_initialized} =
             Admission.evaluate(c.candidate, context, put_in(state.catalog.surfaces, %{}), time)

    assert {:error, :host_profile_not_initialized} =
             Admission.evaluate(
               c.candidate,
               context,
               put_in(state.catalog.host_profiles, %{}),
               time
             )

    invalid = put_in(state.catalog.surfaces[state.catalog.surface_ref], %{})

    assert {:error, :invalid_admission_foundations} =
             Admission.evaluate(c.candidate, context, invalid, time)
  end

  test "the candidate cannot narrow its declared effect Row to evade classification", c do
    {:ok, row} = Row.new(attempt: true, spend: true)

    {:ok, candidate} =
      Candidate.new(%{c.candidate | ref: nil, material_digest: nil, row: row, disclosure: nil})

    assert {:ok, decision, nil} = evaluate(c, candidate, c.before)
    assert decision.outcome == :refused

    assert [{:candidate_row_mismatch, %{candidate: proposed, declared: declared}}] =
             decision.reasons

    refute :disclose in proposed
    assert :disclose in declared
    surface = State.surface(c.before)

    {:ok, surface} =
      Surface.new(%{surface | ref: nil, presentation_required_classes: [c.candidate.class]})

    state = c.before
    state = put_in(state.catalog.surfaces[state.catalog.surface_ref], surface)
    assert {:ok, decision, nil} = evaluate(c, c.candidate, state)
    assert decision.reasons == [{:presentation_required, c.candidate.class}]
  end

  test "absent references and undeclared contrary facts never become permission", c do
    for stance <- [:supports, :contradicts] do
      {:ok, evidence} = Evidence.new(%{c.payment | ref: nil, stance: stance})
      # Use the normal fold index build so the recognition query sees this fact.
      state = %{c.before | evidence: %{evidence.ref => evidence}}
      state = %{state | read_index: %{state.read_index | evidence_by_proposition: %{}}}

      state =
        ReadIndex.record(state, %{
          type: "evidence_recorded",
          identity: evidence.ref,
          revision: state.revision
        })

      {:ok, candidate} =
        Candidate.new(%{
          c.candidate
          | ref: nil,
            material_digest: nil,
            evidence_refs: ["missing"],
            disclosure: nil,
            row: %{c.candidate.row | disclose: false}
        })

      # Preserve the Surface Row: empty disclosure is still explicit, but it
      # cannot claim the missing reference was externally observed.
      {:ok, candidate} =
        Candidate.new(%{
          candidate
          | ref: nil,
            material_digest: nil,
            row: c.candidate.row,
            disclosure: %{c.candidate.disclosure | source_evidence_refs: []}
        })

      assert {:ok, decision, nil} = evaluate(c, candidate, state)
      assert decision.outcome == :undecidable
      assert inspect(decision.reasons) =~ "missing_evidence_refs"
    end
  end

  test "recognition rejects malformed conditions and future proofs without inventing a basis",
       c do
    condition = c.f.condition
    assert :satisfied = Recognition.check(nil, nil, 100)
    assert {:undecidable, [:invalid_conditions]} = Recognition.check(%{}, [], 100)

    assert {{:undecidable, [:invalid_conditions]}, []} =
             Recognition.check_with_basis([condition], [], 1.0)

    assert {:error, :invalid_recognition_basis} = Recognition.validate_declared_basis(nil, [])

    assert {:undecidable, {:unknown_condition, :invalid_condition}} =
             Recognition.check_condition(nil, [], 100)

    assert {:undecidable, {:unknown_condition, ref}} =
             Recognition.check_condition(condition, [], 1.0)

    assert ref == condition.ref

    assert {{:undecidable, [{:unknown_condition, :invalid_condition}]}, []} =
             Recognition.check_with_basis([nil], [], 100)

    refute Recognition.qualified?(nil, condition, [], 100)

    for empty <- [nil, :unavailable] do
      assert {{:undecidable, _}, []} =
               Recognition.check_with_basis([condition], empty, c.act.committed_at)
    end

    for changes <- [%{observed_at: c.act.committed_at + 1}, %{valid_from: c.act.committed_at + 1}] do
      {:ok, evidence} =
        c.payment
        |> Map.from_struct()
        |> Map.put(:ref, nil)
        |> Map.merge(changes)
        |> Evidence.new()

      refute Recognition.qualified?(evidence, condition, [evidence], c.act.committed_at)

      assert {{:undecidable, _}, []} =
               Recognition.check_with_basis([condition], [evidence], c.act.committed_at)
    end

    {:ok, exact_issuer} =
      Condition.new(%{condition | ref: nil, parameters: %{"issuer_refs" => c.payment.issuer_ref}})

    assert :satisfied = Recognition.check([exact_issuer], [c.payment], c.act.committed_at)
  end

  test "consent recognition composes contrary facts with missing, corrupt and mismatched material",
       c do
    {candidate, presentation} = presented_candidate(c)

    assert {:ok, missing, nil} = evaluate(c, candidate, c.before)
    assert missing.outcome == :undecidable
    assert inspect(missing.reasons) =~ "presentation_not_found"

    invalid = %{c.before | presentations: %{presentation.ref => %{}}}
    assert {:ok, corrupt, nil} = evaluate(c, candidate, invalid)
    assert corrupt.outcome == :undecidable
    assert inspect(corrupt.reasons) =~ "invalid_presentation_record"

    mismatched = %{presentation | candidate_binding_ref: "candidate_binding:other"}
    state = %{c.before | presentations: %{presentation.ref => mismatched}}
    assert {:ok, unbound, nil} = evaluate(c, candidate, state)
    assert unbound.outcome == :refused
    assert inspect(unbound.reasons) =~ "presentation_candidate_binding_mismatch"

    {:ok, contrary} = Evidence.new(%{c.payment | ref: nil, stance: :contradicts})

    {:ok, contrary_draft} =
      candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:presentation_ref, nil)
      |> Map.put(:evidence_refs, [contrary.ref])
      |> Map.update!(:disclosure, &%{&1 | source_evidence_refs: [contrary.ref]})
      |> Candidate.new()

    {:ok, contrary_presentation} =
      presentation
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:candidate_binding_ref, Candidate.presentation_binding_ref(contrary_draft))
      |> Presentation.new()

    {:ok, contrary_candidate} =
      contrary_draft
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:presentation_ref, contrary_presentation.ref)
      |> Candidate.new()

    read_index = %{
      c.before.read_index
      | evidence_by_revision: :gb_trees.empty(),
        presentation_count: 0
    }

    contrary_state = %{c.before | evidence: %{contrary.ref => contrary}, read_index: read_index}

    assert {:ok, mixed, nil} = evaluate(c, contrary_candidate, contrary_state)
    assert mixed.outcome == :refused
    assert inspect(mixed.reasons) =~ "evidence_condition_unsatisfied"

    wrong_binding = %{contrary_presentation | candidate_binding_ref: "candidate_binding:other"}

    contrary_state = %{
      contrary_state
      | presentations: %{contrary_presentation.ref => wrong_binding}
    }

    assert {:ok, refused, nil} = evaluate(c, contrary_candidate, contrary_state)
    assert refused.outcome == :refused
    assert inspect(refused.reasons) =~ "presentation_candidate_binding_mismatch"
  end

  defp presented_candidate(c) do
    data = %{"refund_cents" => 100}
    {:ok, data_digest} = Consent.data_digest(data)

    consent = %{
      schema_version: 1,
      recipient_refs: [c.candidate.proposer_ref],
      data_digest: data_digest,
      cost: 100,
      purpose_ref: c.candidate.purpose_ref,
      purpose_params: c.candidate.purpose_params,
      risk: "external payment",
      reversibility: false,
      alternatives: ["cancel"]
    }

    {:ok, draft} =
      c.candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:consent, consent)
      |> Candidate.new()

    {:ok, presentation} =
      Presentation.new(%{
        candidate_binding_ref: Candidate.presentation_binding_ref(draft),
        scope_ref: draft.scope_ref,
        recipient_refs: consent.recipient_refs,
        approval_source_refs: [c.f.refs.ingress],
        data: data,
        cost: consent.cost,
        purpose_ref: consent.purpose_ref,
        purpose_params: consent.purpose_params,
        risk: consent.risk,
        reversibility: consent.reversibility,
        alternatives: consent.alternatives,
        renderer_ref: "test:renderer",
        rendered_payload: "Refund 100 cents?",
        prepared_at: c.act.committed_at
      })

    {:ok, candidate} =
      draft
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:presentation_ref, presentation.ref)
      |> Candidate.new()

    {candidate, presentation}
  end

  defp evaluate(c, candidate, state),
    do: Admission.evaluate(candidate, Fixture.context(c.f), state, c.act.committed_at)
end
