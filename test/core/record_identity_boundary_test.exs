defmodule Spectre.RecordIdentityBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Candidate, Constitution, HostProfile, Mandate, Portable, SubmissionContext}
  alias Spectre.GovernedAct.State
  alias Spectre.Mandate.{Ancestry, Revocation}
  alias Spectre.Scope.Opening
  alias Spectre.V04Test.Fixture

  test "public identity and digest functions agree with exact canonical round trips", c do
    context = Fixture.context(c.f)
    profile = State.host_profile(c.before)

    for record <- [c.candidate, c.f.mandate, profile, c.before.catalog.scopes[c.f.refs.scope]] do
      module = record.__struct__
      canonical = module.canonical(record)
      assert {:ok, ^record} = module.from_canonical(canonical)
      assert module.digest(record) == Portable.digest!(canonical)
    end

    assert Candidate.content_ref(c.candidate) == c.candidate.ref
    assert HostProfile.content_ref(profile) == profile.ref
    assert SubmissionContext.content_ref(context) == context.ref
    assert Mandate.root?(c.f.mandate)
  end

  for {field, value, error} <- [
        {:class, "", {:invalid_candidate_class, ""}},
        {:purpose_params, [], {:invalid_candidate_purpose_params, :list}},
        {:observation_window_ms, 1.0, {:invalid_candidate_observation_window_ms, 1.0}},
        {:presentation_ref, "presentation:unbound", :presentation_missing_consent_material}
      ] do
    test "a freshly hashed Candidate still rejects #{field}=#{inspect(value)}", c do
      attrs =
        c.candidate
        |> Map.from_struct()
        |> Map.drop([:ref, :material_digest])
        |> Map.put(unquote(field), unquote(Macro.escape(value)))

      assert {:error, unquote(Macro.escape(error))} = Candidate.new(attrs)
    end
  end

  test "effect identity rejects malformed effects instead of hashing a partial envelope", c do
    assert {:error, :invalid_candidate_effect} = Candidate.effect_digest(nil)

    for attrs <- [%{class: ""}, %{consequence: nil}] do
      assert {:error, :invalid_candidate_effect} =
               Candidate.effect_digest(struct(c.candidate, attrs))
    end

    assert {:error, _} = Candidate.effect_digest(%{c.candidate | row: %{unknown: true}})
    assert {:error, _} = Candidate.effect_digest(%{c.candidate | subject_refs: nil})
    assert {:error, _} = Candidate.effect_digest(%{c.candidate | disclosure: self()})
  end

  for {field, value} <- [
        conditions: [:not_a_condition],
        classes: [123],
        executor_refs: [],
        executor_contract_refs: [nil],
        delegation: [],
        revocation: [],
        meters: []
      ] do
    test "Mandate rejects malformed #{field} even without a preassigned content ref", c do
      attrs =
        c.f.mandate
        |> Map.from_struct()
        |> Map.delete(:ref)
        |> Map.put(unquote(field), unquote(Macro.escape(value)))

      assert {:error, _} = Mandate.new(attrs)
    end
  end

  test "condition aliases cannot smuggle two contradictory requirements under one ref", c do
    condition = c.f.condition

    assert {:error, _} =
             Mandate.new(%{c.f.mandate | ref: nil, conditions: [condition | :invalid_tail]})

    assert {:error, _} = Mandate.from_issue_draft(%{"unrecognized" => true}, "act:source")
  end

  test "ancestry traversal rejects malformed lineage and does not interpret it as unrevoked", c do
    for {name, args} <- [
          revoked?: [nil, %{}, c.f.mandate, 0],
          status: [%{}, nil, c.f.mandate, 0],
          status_in_lineage: [nil, %{}, 0],
          directly_revoked?: [nil, c.f.mandate, 0],
          terminal?: [%{}, %{}, nil, 0],
          descendant?: [%{}, nil, "root"],
          affected_by?: [%{}, nil, "root", true],
          lineage: [nil, c.f.mandate]
        ] do
      assert {:error, :invalid_mandate_ancestry_input} = apply(Ancestry, name, args)
    end

    assert {:error, _} = Ancestry.status_in_lineage([c.f.mandate, :corrupt], %{}, 0)
    mandate = %{c.f.mandate | parent_ref: 42}
    assert {:error, _} = Ancestry.lineage(%{mandate.ref => mandate}, mandate)
    assert {:error, _} = Revocation.from_event("revocation", %{}, :cascade)
    assert {:error, _} = Revocation.from_event(nil, nil, :cascade)
  end

  test "Scope drafts cannot upgrade a session to a promise without parent, due time and cause",
       c do
    opening = c.before.catalog.scopes[c.f.refs.scope]
    assert {:error, :governed_scope_kind_required} = Opening.governed_draft(opening)
    assert {:error, _} = Opening.governed_draft(%{opening | schema_version: 99})
    assert {:error, :governed_scope_due_at_required} = Opening.governed_draft(%{})
    assert {:error, :invalid_governed_scope_due_at} = Opening.governed_draft(%{due_at: 1.0})
    assert {:error, :invalid_governed_scope_draft} = Opening.from_governed_draft(nil, "act", 100)

    for kind <- [:work, :vigil] do
      assert {:error, {:scope_parent_required, ^kind}} =
               Opening.new(%{opening | kind: kind, parent_ref: nil})

      assert {:error, {:scope_promise_required, ^kind}} =
               Opening.new(%{opening | kind: kind, parent_ref: "parent"})
    end

    assert {:error, {:scope_promise_not_allowed, :session}} =
             Opening.new(%{opening | promise_condition: c.f.condition})
  end

  test "context decoding rejects mixed key encodings and spoofed trusted bindings", c do
    context = Fixture.context(c.f)
    bindings = SubmissionContext.evidence_bindings(context)
    assert {:error, :invalid_decision_submission_context} = SubmissionContext.from_decision(nil)
    assert {:error, _} = SubmissionContext.merge_evidence_bindings(nil)
    assert {:error, _} = SubmissionContext.merge_evidence_bindings(context, [])
    assert {:error, _} = SubmissionContext.from_evidence_bindings(nil)
    assert {:error, _} = SubmissionContext.extract_evidence_context(nil)
    assert {:error, _} = SubmissionContext.validate_evidence_bindings(nil, bindings)
    assert {:ok, another} = SubmissionContext.new(%{context | ref: nil, scope_ref: "another"})

    assert {:error, :evidence_submission_context_mismatch} =
             SubmissionContext.validate_evidence_bindings(another, bindings)

    assert {:error, {:noncanonical_evidence_context_binding, :scope_ref}} =
             SubmissionContext.from_evidence_bindings(
               Map.put(bindings, :scope_ref, context.scope_ref)
             )

    assert {:error, :invalid_submission_context_seal_material} =
             SubmissionContext.seal(context, "short")

    for attrs <- [%{schema_version: 99}, %{host_generation: 1.0}, %{seal: 42}] do
      assert {:error, _} =
               SubmissionContext.new(
                 context
                 |> Map.from_struct()
                 |> Map.delete(:ref)
                 |> Map.merge(attrs)
               )
    end
  end

  test "Constitution validates policy rather than quietly accepting corrupt rule shapes" do
    assert {:error, :invalid_constitution} = Constitution.validate([])
    assert_raise ArgumentError, fn -> Constitution.ref!([]) end
    assert %{} = Constitution.duty_rule(%{duty_rules: []}, :ambiguous_outcome)
    assert %{} = Constitution.duty_rule(nil, :ambiguous_outcome)
    assert :fallback = Constitution.rule_value([], :missing, :fallback)
    assert {:error, :invalid_constitution} = Constitution.emergency_max_duration(nil)
    assert {:error, _} = Constitution.validate(%{duty_rules: nil})
    assert {:error, _} = Constitution.validate(%{secret: self()})
    assert :ok = Constitution.validate(%{1 => :application_value})
    assert {:error, _} = Constitution.validate(%{:rule => 1, "rule" => 2})
    assert {:error, _} = Constitution.validate(%{duty_rules: %{42 => %{}}})

    assert {:error, _} =
             Constitution.validate(%{
               duty_rules: %{ambiguous_outcome: %{disposition_authority_refs: [nil]}}
             })

    assert Constitution.conflict_refs(
             %{duty_rules: %{ambiguous_outcome: %{conflict_refs: [nil, "", "owner", "owner"]}}},
             :ambiguous_outcome
           ) == ["owner"]
  end
end
