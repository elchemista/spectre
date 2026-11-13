Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.CoreTest.InformationRecordsTest do
  use ExUnit.Case, async: true

  alias Spectre.GAM.{Declassification, Definition, Erasure, Evidence, Label, Portable}
  alias Spectre.GAM.Evidence.Derivation

  test "Definition content is portable and revisions keep a stable logical key" do
    assert {:ok, first} =
             Definition.new(
               namespace: "app",
               name: "agent",
               revision: 1,
               declared_at: 100,
               body: %{"instructions" => "Assist"}
             )

    assert {:ok, ^first} = Definition.from_canonical(Definition.canonical(first))
    assert Definition.content_ref(first) == first.ref
    assert Portable.sha256_digest?(Definition.digest(first))
    attrs = first |> Map.from_struct() |> Map.drop([:ref])
    assert {:ok, next} = Definition.new(%{attrs | revision: 2, previous_ref: first.ref})
    assert Definition.key(first) == Definition.key(next)
    refute first.ref == next.ref

    assert {:error, :revised_definition_missing_previous_ref} =
             Definition.new(%{attrs | revision: 2})

    assert {:error, :initial_definition_has_previous_ref} =
             Definition.new(%{attrs | previous_ref: first.ref})

    assert {:error, _} = Definition.new(%{first | body: %{"instructions" => "Forged"}})
    assert {:error, _} = Definition.new(%{attrs | body: %{"callback" => fn -> :unsafe end}})
  end

  test "labels bind ownership and conservative derivation cannot silently drop them" do
    label = label("owner:alice")
    other = label("owner:bob")
    refute label.ref == other.ref
    assert {:ok, ^label} = Label.from_canonical(Label.canonical(label))
    assert Label.content_ref(label) == label.ref
    assert {:ok, [^label]} = Label.normalize_many([label, Label.canonical(label)])
    parent = evidence(labels: [label])
    derived = evidence(provenance: :derived, parent_refs: [parent.ref], labels: [label])
    assert :ok = Derivation.validate(derived, [parent])
    stripped = evidence(provenance: :derived, parent_refs: [parent.ref])

    assert {:error, {:evidence_labels_not_conservative, _}} =
             Derivation.validate(stripped, [parent])

    assert {:ok, labels} = Derivation.conservative_labels([parent], [other])
    assert Enum.map(labels, & &1.ref) == Enum.sort([label.ref, other.ref])
    assert {:error, {:evidence_parent_mismatch, _, _, _}} = Derivation.validate(derived, [])
  end

  test "declassification records the exact removed labels, owners and immutable parents" do
    removed = label("owner:alice")
    retained = label("owner:bob")
    parent = evidence(labels: [removed, retained])
    output = evidence(provenance: :derived, parent_refs: [parent.ref], labels: [retained])
    assert {:ok, draft} = Declassification.draft(output, [removed])
    assert {:ok, decoded} = Declassification.decode_draft(draft)
    assert decoded.evidence == output
    assert decoded.removed_owner_refs == [removed.owner_ref]
    assert {:ok, record} = Declassification.from_draft(draft, "act:declassify", 100)
    assert :ok = Declassification.validate_transition(record, output, [parent])
    assert {:ok, ^record} = Declassification.from_canonical(Declassification.canonical(record))
    assert Declassification.content_ref(record) == record.ref
    assert Portable.sha256_digest?(Declassification.digest(record))
    assert {:ok, targets} = Declassification.required_target_refs(output, [removed])
    assert targets == Enum.sort([parent.ref, output.ref, removed.ref, removed.owner_ref])

    assert {:error, {:declassification_parent_mismatch, _}} =
             Declassification.validate_transition(record, output, [])

    assert {:error, {:declassification_owner_refs_mismatch, _, _}} =
             Declassification.decode_draft(%{draft | "removed_owner_refs" => ["owner:forged"]})
  end

  test "declassification cannot relabel observed facts or claim removal of retained labels" do
    removed = label("owner:alice")
    parent = evidence(labels: [removed])

    assert {:error, {:invalid_declassification_provenance, :observed}} =
             Declassification.draft(parent, [removed])

    output = evidence(provenance: :derived, parent_refs: [parent.ref], labels: [removed])
    assert {:error, {:removed_label_still_present, _}} = Declassification.draft(output, [removed])
    assert {:error, :declassification_labels_required} = Declassification.draft(output, [])
    assert {:ok, rebound} = Declassification.bind_producer(output, "producer:authorized")
    assert :ok = Declassification.validate_producer(rebound, "producer:authorized")

    assert {:error, {:declassification_producer_mismatch, _, _}} =
             Declassification.validate_producer(rebound, "producer:other")

    refute rebound.ref == output.ref
  end

  test "erasure is an immutable causal tombstone, not a claim that deletion succeeded" do
    digest = Portable.digest!(%{"payload" => "private"})

    attrs = %{
      target_ref: "payload:" <> digest,
      target_digest: digest,
      scope_ref: "scope:one",
      affected_refs: ["evidence:one"],
      reason: "retention expired",
      reduces_verifiability: true,
      requested_at: 100
    }

    assert {:ok, draft} = Erasure.request_draft(attrs)
    refute Map.has_key?(draft, "source_act_ref")
    assert {:ok, erasure} = Erasure.from_request_draft(draft, "act:erase")
    assert erasure.source_act_ref == "act:erase"
    refute Map.has_key?(erasure, :succeeded)
    assert {:ok, ^erasure} = Erasure.from_canonical(Erasure.canonical(erasure))
    assert {:ok, ^draft} = Erasure.request_draft(erasure)
    assert Erasure.content_ref(erasure) == erasure.ref
    assert Portable.sha256_digest?(Erasure.digest(erasure))

    assert {:error, {:erasure_target_digest_mismatch, _, _}} =
             Erasure.request_draft(%{attrs | target_ref: "evidence:" <> digest})

    assert {:error, {:invalid_erasure_reason, ""}} = Erasure.request_draft(%{attrs | reason: ""})
    assert {:error, _} = Erasure.new(%{erasure | reason: "rewritten history"})
  end

  defp label(owner) do
    {:ok, label} = Label.new(owner_ref: owner, value: %{"confidential" => true})
    label
  end

  test "declassification replay validates quantity of information removed, not just references" do
    removed = label("owner:alice")
    retained = label("owner:bob")
    parent = evidence(labels: [removed, retained])
    output = evidence(provenance: :derived, parent_refs: [parent.ref], labels: [retained])
    {:ok, draft} = Declassification.draft(output, [removed])
    {:ok, record} = Declassification.from_draft(draft, "act:redact", 100)
    assert :ok = Declassification.validate_transition(record, output, [parent])

    for {labels, reason} <- [
          {[removed, retained], :removed_label_still_present},
          {[], :declassification_drops_undeclared_label}
        ] do
      changed = evidence(provenance: :derived, parent_refs: [parent.ref], labels: labels)
      {:ok, proof} = Declassification.new(%{record | ref: nil, evidence_ref: changed.ref})

      assert {:error, {^reason, _}} =
               Declassification.validate_transition(proof, changed, [parent])
    end

    outside = label("owner:charlie")
    {:ok, outside_draft} = Declassification.draft(output, [outside])
    {:ok, outside_proof} = Declassification.from_draft(outside_draft, "act:redact", 100)

    assert {:error, {:declassification_removes_uninherited_label, _}} =
             Declassification.validate_transition(outside_proof, output, [parent])

    assert {:error, {:invalid_declassification_parent, _}} =
             Declassification.validate_transition(record, output, [%{}])

    assert {:error, {:declassification_evidence_mismatch, _, _}} =
             Declassification.validate_transition(
               record,
               %{output | ref: nil, payload: "different summary"}
               |> then(fn attrs ->
                 {:ok, e} = Evidence.new(attrs)
                 e
               end),
               [parent]
             )
  end

  test "declassification cannot cite future observations or future parents" do
    removed = label("owner:alice")
    parent = evidence(labels: [removed], observed_at: 101)
    output = evidence(provenance: :derived, parent_refs: [parent.ref], observed_at: 100)
    {:ok, draft} = Declassification.draft(output, [removed])
    {:ok, record} = Declassification.from_draft(draft, "act:redact", 100)

    assert {:error, {:evidence_parent_from_future, _, _}} =
             Declassification.validate_transition(record, output, [parent])

    {:ok, past} = Declassification.new(%{record | ref: nil, recorded_at: 99})

    assert {:error, {:declassified_evidence_from_future, _}} =
             Declassification.validate_transition(past, output, [parent])

    assert {:error, _} = Declassification.new(%{record | ref: nil, recorded_at: 100.0})
    assert {:error, _} = Declassification.new(%{record | ref: nil, schema_version: 99})
    assert {:error, _} = Declassification.decode_draft(%{draft | "schema_version" => 99})

    assert {:error, _} =
             Declassification.decode_draft(%{draft | "removed_label_refs" => ["wrong-label"]})
  end

  test "declassification public guards reject absent provenance and malformed removal lists" do
    assert {:error, _} = Declassification.bind_producer(nil, "producer")
    assert {:error, _} = Declassification.validate_producer(nil, "producer")
    assert {:error, _} = Declassification.from_draft(nil, "act", 1)
    assert {:error, _} = Declassification.required_target_refs(nil, [])
    assert {:error, _} = Declassification.validate_transition(nil, nil, [])
    assert {:error, {:invalid_declassification_labels, _}} = Declassification.label_refs([%{}])
  end

  defp evidence(overrides) do
    {:ok, evidence} =
      Evidence.new(
        Keyword.merge(
          [
            proposition: "fact",
            issuer_ref: "issuer",
            source_ref: "source",
            provenance: :observed,
            observed_at: 100,
            payload: "private"
          ],
          overrides
        )
      )

    evidence
  end
end
