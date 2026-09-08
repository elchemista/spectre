defmodule Spectre.ValueContractBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Act, Condition, Decision, Disclosure, Duty, Evidence, Label, Mandate, Outcome, Row}
  alias Spectre.Consequence.Contract
  alias Spectre.Evidence.Derivation

  test "record identity helpers expose exact canonical values rather than loose equality", c do
    outcome = Spectre.V04Test.Fixture.outcome(c.f, c.act, c.attempt, :succeeded, [c.receipt.ref])
    assert Act.digest(c.act) == Spectre.Portable.digest!(Act.canonical(c.act))
    assert Act.content_ref(c.act) == c.act.ref
    assert Decision.admitted?(c.decision)
    refute Decision.admitted?(%{c.decision | outcome: :refused})
    assert Decision.digest(c.decision) == Spectre.Portable.digest!(Decision.canonical(c.decision))
    assert Decision.content_ref(c.decision) == c.decision.ref
    assert Outcome.statuses() == [:succeeded, :failed, :definitive_no_effect, :ambiguous]
    refute Outcome.definitive_no_effect?(outcome)
    assert Outcome.definitive_no_effect?(%{outcome | status: :definitive_no_effect})
    assert Outcome.digest(outcome) == Spectre.Portable.digest!(Outcome.canonical(outcome))
    assert Outcome.content_ref(outcome) == outcome.ref
    assert Condition.content_ref(c.f.condition) == c.f.condition.ref
  end

  test "derivation helpers reject malformed parents and non-derivation provenance", c do
    assert {:error, :invalid_derivation_evidence} = Derivation.inherited_labels(nil)
    assert {:error, :invalid_derivation_labels} = Derivation.conservative_labels([], nil)
    assert {:error, :invalid_evidence_derivation} = Derivation.validate(nil, [])
    assert {:error, {:invalid_derivation_parent, _}} = Derivation.inherited_labels([%{}])
    assert {:error, {:invalid_derivation_provenance, :observed}} = Derivation.validate(c.payment, [])
  end

  test "Disclosure proves both its effect row and inherited labels", c do
    {:ok, row} = Row.new(disclose: false)
    {:ok, label} = Label.new(owner_ref: "owner", value: "private")
    {:ok, disclosure} = Disclosure.new(destination_refs: ["customer"], source_evidence_refs: [c.payment.ref], labels: [label])
    assert {:error, :disclosure_not_declared_in_row} = Disclosure.validate_boundary(row, disclosure, ["customer"], [c.payment.ref])
    assert {:error, :invalid_disclosure_sources} = Disclosure.verify_sources(nil, nil)
    assert {:error, :disclosure_labels_not_derived_from_sources} = Disclosure.verify_sources(disclosure, %{c.payment.ref => c.payment})
    assert {:error, {:invalid_disclosure_evidence, _}} = Disclosure.verify_sources(disclosure, %{c.payment.ref => %{}})
    refute Disclosure.labels_covered?(nil, [])
    refute Disclosure.labels_covered?(disclosure, [nil])
    assert {:error, {:unsupported_disclosure_schema_version, 2}} = Disclosure.new(%{disclosure | schema_version: 2})
    assert {:ok, ^disclosure} = Disclosure.from_canonical(Disclosure.canonical(disclosure))
  end

  test "Condition and Duty constructors reject malformed collection tails", c do
    assert {:error, {:invalid_condition_cardinality, :list}} = Condition.new(cardinality: [])
    assert {:error, {:invalid_condition_provenance, :observed}} = Condition.new(accepted_provenance: :observed)
    assert {:error, {:invalid_condition_provenance, _}} = Condition.new(accepted_provenance: [:observed | :bad])
    assert {:error, _} = Condition.new(%{c.f.condition | ref: nil, accepted_provenance: []})
    assert {:error, {:missing_outcome_evidence, :succeeded}} = Outcome.new(%{act_ref: "act", attempt_ref: "attempt", status: :succeeded, evidence_refs: [], observed_at: 1, details_ref: "details"})
    assert {:error, _} = Duty.new(class: "app.review", cause_key: {:review, 1}, accountable: "owner", conflict_refs: ["owner" | :bad], opened_at: 1)
  end

  test "Evidence identity and freshness helpers preserve lineage and exact time bounds", c do
    assert Evidence.stances() == [:supports, :contradicts]
    assert Evidence.provenances() == [:observed, :derived, :generated]
    assert Evidence.content_ref(c.payment) == c.payment.ref
    refute Evidence.opposes?(c.payment, nil)

    assert {:error, {:evidence_lineage_required, _ref, :derived}} =
             Evidence.new(%{c.payment | ref: nil, provenance: :derived, parent_refs: []})

    {:ok, expiring} = Evidence.new(%{c.payment | ref: nil, freshness_ms: 10})
    assert Evidence.current_at?(expiring, expiring.observed_at + 5, 20)
    refute Evidence.current_at?(expiring, expiring.observed_at + 5, 3)
    assert {:ok, ^expiring} = expiring |> Evidence.canonical() |> Evidence.from_canonical()
  end

  test "Mandate drafts and policies reject noncanonical or malformed authority", c do
    mandate = c.f.mandate
    assert Mandate.content_ref(mandate) == mandate.ref
    assert {:ok, draft} = Mandate.issue_draft(mandate)

    atom_draft = Map.new(draft, fn {key, value} -> {String.to_existing_atom(key), value} end)

    assert {:error, :noncanonical_mandate_issue_draft} =
             Mandate.from_issue_draft(atom_draft, "act:issuer")

    for changes <- [
          %{classes: [hd(mandate.classes) | :improper]},
          %{delegation: %{"allowed" => true, "max_depth" => 0}},
          %{revocation: %{"mode" => :unknown, "controller_refs" => [mandate.grantor_ref]}}
        ] do
      attrs = mandate |> Map.from_struct() |> Map.merge(changes) |> Map.put(:ref, nil)
      assert {:error, _reason} = Mandate.new(attrs)
    end
  end

  test "Consequence contracts expose one canonical static-validation path" do
    {:ok, contract} = Contract.new(shape: %{"target" => "target_ref"})
    assert {:error, :invalid_consequence_contract} = Contract.validate_static(nil, %{}, %{})
    assert Contract.content_ref(contract) == contract.ref
    assert {:ok, ^contract} = contract |> Contract.canonical() |> Contract.from_canonical()

    assert {:ok, %{target_refs: ["target:one"]}} =
             Contract.bindings(contract, %{"target" => "target:one"})
  end
end
