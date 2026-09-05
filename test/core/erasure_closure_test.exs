defmodule Spectre.Core.ErasureClosureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.{Duty, Erasure, Evidence, Portable, Presentation}
  alias Spectre.Erasure.Analysis
  alias Spectre.Erasure.Analysis.{Closure, Facts}
  alias Spectre.GovernedAct.State

  setup do
    ref = Portable.content_ref!(:payload, "private receipt")
    root = evidence("root", [], payload: nil, payload_ref: ref)
    child = evidence("child", [root.ref])
    leaf = evidence("leaf", [child.ref])
    unrelated = evidence("unrelated", [])
    facts = %Facts{evidence: index([root, child, leaf, unrelated])}
    %{ref: ref, root: root, child: child, leaf: leaf, unrelated: unrelated, facts: facts}
  end

  test "a target must actually occur in the pinned prefix", c do
    unknown = Portable.content_ref!(:payload, "unseen")

    assert {:error, {:erasable_payload_not_referenced, ^unknown}} =
             Analysis.affected_refs(c.facts, unknown)
  end

  test "external payload ancestry includes descendants but excludes unrelated evidence", c do
    assert {:ok, refs} = Analysis.affected_refs(c.facts, c.ref)
    assert refs == Enum.sort([c.root.ref, c.child.ref, c.leaf.ref])
    refute c.unrelated.ref in refs
  end

  test "a join node is affected if even one of its parents depends on the payload", c do
    join = evidence("join", [c.leaf.ref, c.unrelated.ref])
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, join.ref, join)}
    assert {:ok, refs} = Analysis.affected_evidence_refs(facts, c.ref)
    assert MapSet.member?(refs, join.ref)
    refute MapSet.member?(refs, c.unrelated.ref)
  end

  test "all direct holders of the same content address seed the closure", c do
    another = evidence("other holder", [], payload: nil, payload_ref: c.ref)
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, another.ref, another)}
    assert {:ok, refs} = Analysis.affected_evidence_refs(facts, c.ref)
    assert MapSet.size(refs) == 4
    assert MapSet.member?(refs, another.ref)
  end

  test "a descendant's own inline payload does not break its information lineage", c do
    assert c.leaf.payload != nil
    assert c.leaf.payload_ref == nil
    assert {:ok, refs} = Analysis.affected_evidence_refs(c.facts, c.ref)
    assert MapSet.member?(refs, c.leaf.ref)
  end

  test "a descendant's independent external bytes do not erase its parent dependency", c do
    own_ref = Portable.content_ref!(:payload, "derived summary")
    derived = evidence("external summary", [c.leaf.ref], payload: nil, payload_ref: own_ref)
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, derived.ref, derived)}
    assert {:ok, refs} = Analysis.affected_evidence_refs(facts, c.ref)
    assert MapSet.member?(refs, derived.ref)
    assert {:ok, own_refs} = Analysis.affected_evidence_refs(facts, own_ref)
    assert own_refs == MapSet.new([derived.ref])
  end

  test "causal analysis does not follow text that merely mentions a reference", c do
    mention = evidence("mention", [], payload: %{"text" => c.root.ref})
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, mention.ref, mention)}
    assert {:ok, refs} = Analysis.affected_refs(facts, c.ref)
    refute mention.ref in refs
  end

  test "expiration does not remove historical dependency", c do
    expired = evidence("expired", [c.leaf.ref], valid_until: 101)
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, expired.ref, expired)}
    assert {:ok, request} = Analysis.derive_request(facts, c.ref, "scope", "delete", 1000)
    assert expired.ref in request.affected_refs
  end

  test "a diamond graph contains each affected record exactly once", c do
    sibling = evidence("sibling", [c.root.ref])
    join = evidence("join", [c.child.ref, sibling.ref])
    facts = %{c.facts | evidence: Map.merge(c.facts.evidence, index([sibling, join]))}
    assert {:ok, refs} = Analysis.affected_refs(facts, c.ref)
    assert length(refs) == 5
    assert length(Enum.uniq(refs)) == 5
    assert join.ref in refs
  end

  property "transitive ancestry reaches the last node independently of map insertion order" do
    check all(depth <- integer(1..45), salt <- binary(min_length: 1, max_length: 24)) do
      ref = Portable.content_ref!(:payload, salt)
      root = evidence("root", [], payload: nil, payload_ref: ref)

      chain =
        Enum.reduce(1..depth, [root], fn n, [parent | _] = nodes ->
          [evidence("derived #{n}", [parent.ref]) | nodes]
        end)

      expected = chain |> Enum.map(& &1.ref) |> MapSet.new()

      for records <- [chain, Enum.reverse(chain)] do
        assert {:ok, ^expected} =
                 Analysis.affected_evidence_refs(%Facts{evidence: index(records)}, ref)
      end
    end
  end

  test "prepared rendering is an erasable root even without Evidence records", c do
    presentation = presentation([], rendered_payload: nil, rendered_payload_ref: c.ref)
    facts = %Facts{presentations: index([presentation])}
    assert Analysis.affected_refs(facts, c.ref) == {:ok, [presentation.ref]}
    assert Analysis.affected_evidence_refs(facts, c.ref) == {:ok, MapSet.new()}
  end

  test "a Presentation inherits dependencies through its disclosure basis", c do
    presentation = presentation([c.leaf.ref])
    facts = %{c.facts | presentations: index([presentation])}
    assert {:ok, refs} = Analysis.affected_refs(facts, c.ref)
    assert presentation.ref in refs
    assert length(refs) == 4
  end

  test "an unrelated Presentation is not affected just because it uses the same renderer", c do
    affected = presentation([c.leaf.ref])
    unrelated = presentation([c.unrelated.ref])
    facts = %{c.facts | presentations: index([affected, unrelated])}
    assert {:ok, refs} = Analysis.affected_refs(facts, c.ref)
    assert affected.ref in refs
    refute unrelated.ref in refs
  end

  test "an Evidence-only closure excludes Presentation records from its return type", c do
    presentation = presentation([c.leaf.ref])
    facts = %{c.facts | presentations: index([presentation])}
    assert {:ok, refs} = Analysis.affected_evidence_refs(facts, c.ref)
    assert refs == MapSet.new([c.root.ref, c.child.ref, c.leaf.ref])
  end

  test "a Duty referring to affected Evidence remains part of the causal tombstone", c do
    {:ok, duty} =
      Duty.new(
        class: "app.review",
        accountable: "owner",
        opened_at: 101,
        evidence_refs: [c.leaf.ref],
        missing: ["review"]
      )

    facts = %{c.facts | duties: %{duty.cause_key => duty}}
    assert {:ok, refs} = Analysis.affected_refs(facts, c.ref)
    assert duty.ref in refs
    assert duty.cause_key not in refs
  end

  test "disposing a Duty does not remove its historical payload dependency", c do
    {:ok, duty} =
      Duty.new(
        class: "app.review",
        accountable: "owner",
        opened_at: 101,
        evidence_refs: [c.leaf.ref],
        status: :disposed,
        disposition_act_ref: "act:disposition"
      )

    facts = %{c.facts | duties: %{duty.cause_key => duty}}
    assert {:ok, refs} = Analysis.affected_refs(facts, c.ref)
    assert duty.ref in refs
  end

  test "an erasure draft binds the exact digest, scope and affected history", c do
    assert {:ok, draft} = Analysis.derive_request(c.facts, c.ref, "scope", "user request", 120)
    assert draft.target_ref == c.ref
    assert "payload:" <> draft.target_digest == c.ref
    assert draft.scope_ref == "scope"
    assert draft.reason == "user request"
    assert draft.requested_at == 120
    assert draft.reduces_verifiability
    assert Analysis.validate_request(c.facts, draft) == :ok
    assert {:ok, canonical} = Erasure.request_draft(draft)
    assert Analysis.validate_request(c.facts, canonical) == :ok
  end

  test "omitting a transitive descendant from the request is rejected", c do
    {:ok, draft} = Analysis.derive_request(c.facts, c.ref, "scope", "delete", 120)
    changed = %{draft | affected_refs: List.delete(draft.affected_refs, c.leaf.ref)}

    assert Analysis.validate_request(c.facts, changed) ==
             {:error, :erasure_request_not_derived_from_prefix}
  end

  test "an unrelated record cannot be smuggled into the affected closure", c do
    {:ok, draft} = Analysis.derive_request(c.facts, c.ref, "scope", "delete", 120)
    changed = %{draft | affected_refs: [c.unrelated.ref | draft.affected_refs]}

    assert Analysis.validate_request(c.facts, changed) ==
             {:error, :erasure_request_not_derived_from_prefix}
  end

  test "a caller cannot conceal reduced verifiability", c do
    {:ok, draft} = Analysis.derive_request(c.facts, c.ref, "scope", "delete", 120)

    assert Analysis.validate_request(c.facts, %{draft | reduces_verifiability: false}) ==
             {:error, :erasure_request_not_derived_from_prefix}
  end

  test "a formerly exact request becomes stale when dependent Evidence is added", c do
    {:ok, draft} = Analysis.derive_request(c.facts, c.ref, "scope", "delete", 120)
    extra = evidence("new dependency", [c.leaf.ref])
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, extra.ref, extra)}

    assert Analysis.validate_request(facts, draft) ==
             {:error, :erasure_request_not_derived_from_prefix}

    {:ok, refreshed} = Analysis.derive_request(facts, c.ref, "scope", "delete", 120)
    assert Analysis.validate_request(facts, refreshed) == :ok
  end

  test "unrelated new Evidence does not invalidate an exact closure", c do
    {:ok, draft} = Analysis.derive_request(c.facts, c.ref, "scope", "delete", 120)
    extra = evidence("unrelated later fact", [c.unrelated.ref])
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, extra.ref, extra)}
    assert Analysis.validate_request(facts, draft) == :ok
  end

  test "a State and its typed erasure view derive identical requests", c do
    state = %{State.new("domain") | evidence: c.facts.evidence}

    assert Analysis.derive_request(state, c.ref, "scope", "delete", 120) ==
             Analysis.derive_request(Facts.from_state(state), c.ref, "scope", "delete", 120)
  end

  test "without an erasure Attempt all Evidence remains usable", c do
    assert Analysis.available_evidence(c.facts) == c.facts.evidence
    assert Analysis.unavailable_evidence_refs(c.facts) == MapSet.new()
    assert Analysis.validate_evidence_available(c.facts, [c.root.ref, c.leaf.ref]) == :ok
  end

  test "invalid target addresses are errors rather than empty causal closures", c do
    for ref <- [nil, "", "payload:short", "payload:" <> String.duplicate("F", 64)] do
      assert {:error, {:invalid_erasable_payload_ref, ^ref}} =
               Analysis.affected_refs(c.facts, ref)
    end
  end

  test "empty deletion reasons and malformed prefix containers are rejected", c do
    assert Analysis.derive_request(c.facts, c.ref, "scope", "", 120) ==
             {:error, :invalid_erasure_reason}

    assert Analysis.derive_request(%{}, c.ref, "scope", "delete", 120) ==
             {:error, :invalid_erasure_facts}
  end

  test "fixed-point expansion terminates on a corrupted cyclic Evidence index", c do
    # Content-addressed constructors cannot produce cycles. Exercise the
    # disposable graph algorithm defensively, not as a valid ledger export.
    root = %{c.root | parent_refs: [c.leaf.ref]}
    facts = %{c.facts | evidence: Map.put(c.facts.evidence, root.ref, root)}
    assert {:ok, closure} = Closure.derive(facts, c.ref)
    assert closure.evidence == MapSet.new([root.ref, c.child.ref, c.leaf.ref])
  end

  defp evidence(name, parents, opts \\ []) do
    {:ok, evidence} =
      Evidence.new(
        Map.merge(
          %{
            proposition: name,
            source_ref: "source",
            issuer_ref: "issuer",
            provenance: if(parents == [], do: :observed, else: :derived),
            parent_refs: parents,
            observed_at: 100,
            payload: name
          },
          Map.new(opts)
        )
      )

    evidence
  end

  defp presentation(sources, opts \\ []) do
    {:ok, presentation} =
      Presentation.new(
        Map.merge(
          %{
            candidate_binding_ref: "candidate:binding",
            scope_ref: "scope",
            recipient_refs: ["recipient"],
            approval_source_refs: ["ingress"],
            data: "display",
            cost: 0,
            purpose_ref: "purpose",
            purpose_params: %{},
            risk: "none",
            reversibility: true,
            alternatives: [],
            renderer_ref: "renderer",
            rendered_payload: "display",
            prepared_at: 100,
            disclosure: %{
              destination_refs: ["recipient"],
              source_evidence_refs: sources,
              labels: []
            }
          },
          Map.new(opts)
        )
      )

    presentation
  end

  defp index(records), do: Map.new(records, &{&1.ref, &1})
end
