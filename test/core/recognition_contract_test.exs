defmodule Spectre.Core.RecognitionContractTest do
  use ExUnit.Case, async: true

  alias Spectre.{Condition, Evidence, Label}
  alias Spectre.Kernel.Recognition

  # These values are application facts, not numbers on which the kernel may
  # perform arithmetic. Distinct canonical values must remain distinct claims.
  for {name, required, asserted} <- [
        {"scalar", 1, 1.0},
        {"nested map", %{"version" => 1}, %{"version" => 1.0}},
        {"tuple", {:revision, 1}, {:revision, 1.0}},
        {"list", [1], [1.0]}
      ] do
    test "proposition identity preserves numeric types in a #{name}" do
      required = unquote(Macro.escape(required))
      asserted = unquote(Macro.escape(asserted))
      condition = condition(proposition: required)
      wrong = evidence(proposition: asserted)
      exact = evidence(proposition: required)
      assert wrong.ref != exact.ref
      assert {{:undecidable, _}, []} = check(condition, [wrong])
      assert {:satisfied, [ref]} = check(condition, [exact])
      assert ref == exact.ref
    end
  end

  test "a wildcard in asserted bindings is not proof of a specific account" do
    condition = condition(bindings: %{"account" => "alice"})
    wildcard = evidence(bindings: %{"account" => :any})
    assert_rejected(condition, wildcard, :binding_mismatch)
    exact = evidence(bindings: %{"account" => "alice"})
    assert {:satisfied, [ref]} = check(condition, [exact])
    assert ref == exact.ref
  end

  test "nested wildcard bindings cannot stand in for an entire required object" do
    condition = condition(bindings: %{"order" => %{"id" => "A", "paid" => true}})
    assert_rejected(condition, evidence(bindings: %{"order" => :any}), :binding_mismatch)
  end

  test "opaque binding values distinguish integer from floating-point identifiers" do
    condition = condition(bindings: %{"account" => 1})
    assert_rejected(condition, evidence(bindings: %{"account" => 1.0}), :binding_mismatch)
  end

  test "extra bindings do not invalidate an otherwise exact required binding" do
    condition = condition(bindings: %{"account" => "alice"})
    proof = evidence(bindings: %{"account" => "alice", "receipt" => "R"})
    assert {:satisfied, [ref]} = check(condition, [proof])
    assert ref == proof.ref
  end

  test "an absent binding is not an explicitly present nil value" do
    condition = condition(bindings: %{"account" => nil})
    assert_rejected(condition, evidence(), :binding_mismatch)
    assert {:satisfied, [_]} = check(condition, [evidence(bindings: %{"account" => nil})])
  end

  test "set-valued bindings require every requested member" do
    condition = condition(bindings: %{"regions" => ["EU", "US"]})
    assert_rejected(condition, evidence(bindings: %{"regions" => ["EU"]}), :binding_mismatch)

    assert {:satisfied, [_]} =
             check(condition, [evidence(bindings: %{"regions" => ["US", "EU", "CA"]})])
  end

  test "two receipts from one issuer are not two independent witnesses" do
    condition = condition(cardinality: 2)
    first = evidence(payload: "first")
    second = evidence(payload: "second")
    assert first.ref != second.ref

    assert {{:undecidable, [{_, :insufficient_evidence, %{actual: 1, minimum: 2}}]}, refs} =
             check(condition, [first, second])

    assert refs == Enum.sort([first.ref, second.ref])
  end

  test "distinct sources under the same issuer do not manufacture independence" do
    condition = condition(cardinality: 2)
    first = evidence(source_ref: "source:A")
    second = evidence(source_ref: "source:B")

    assert {{:undecidable, [{_, :insufficient_evidence, %{actual: 1}}]}, _} =
             check(condition, [first, second])
  end

  test "independent issuers satisfy the minimum even when they share a source" do
    condition = condition(cardinality: 2)
    first = evidence(issuer_ref: "issuer:A")
    second = evidence(issuer_ref: "issuer:B")
    assert {:satisfied, refs} = check(condition, [second, first])
    assert refs == Enum.sort([first.ref, second.ref])
  end

  test "too many independent witnesses violates an explicit maximum" do
    condition = condition(cardinality: 1)
    first = evidence(issuer_ref: "issuer:A")
    second = evidence(issuer_ref: "issuer:B")

    assert {{:undecidable, [{_, :cardinality_exceeded, %{actual: 2, maximum: 1}}]}, _} =
             check(condition, [first, second])
  end

  test "contradiction cannot be outvoted by many supporting issuers" do
    condition = condition()
    support = Enum.map(["A", "B", "C"], &evidence(issuer_ref: &1))
    contrary = evidence(issuer_ref: "D", stance: :contradicts)

    assert {{:undecidable, [{_, :conflicting_evidence, refs}]}, basis} =
             check(condition, [contrary | support])

    assert refs == basis
    assert basis == Enum.sort(Enum.map([contrary | support], & &1.ref))
  end

  test "stale contradiction is excluded rather than poisoning current support" do
    condition = condition(freshness_ms: 10)
    support = evidence()
    stale = evidence(observed_at: 89, stance: :contradicts)
    assert {:satisfied, [ref]} = check(condition, [stale, support])
    assert ref == support.ref
  end

  test "an empty requirement list needs no factual basis" do
    assert {:satisfied, []} = Recognition.check_with_basis([], [evidence()], 100)
  end

  test "one contradicted condition dominates a different unresolved condition" do
    first = condition(proposition: "A")
    second = condition(proposition: "B")
    contrary = evidence(proposition: "A", stance: :contradicts)

    assert {{:unsatisfied, [{ref, :contradicted, _}]}, [basis_ref]} =
             Recognition.check_with_basis([first, second], [contrary], 100)

    assert ref == first.ref
    assert basis_ref == contrary.ref
  end

  test "issuer restrictions are enforced independently of source restrictions" do
    condition =
      condition(parameters: %{"issuer_refs" => ["trusted"], "source_refs" => ["source"]})

    assert_rejected(condition, evidence(), {:unaccepted_issuer, "issuer"})
    assert {:satisfied, [_]} = check(condition, [evidence(issuer_ref: "trusted")])
  end

  test "a trusted issuer cannot substitute a different source" do
    condition =
      condition(parameters: %{"issuer_refs" => ["issuer"], "source_refs" => ["trusted"]})

    assert_rejected(condition, evidence(), {:unaccepted_source, "source"})
    assert {:satisfied, [_]} = check(condition, [evidence(source_ref: "trusted")])
  end

  test "an empty issuer allowlist accepts nobody" do
    assert_rejected(
      condition(parameters: %{"issuer_refs" => []}),
      evidence(),
      {:unaccepted_issuer, "issuer"}
    )
  end

  test "derived facts cannot satisfy observed-only policy" do
    proof = evidence(provenance: :derived, parent_refs: ["evidence:parent"])
    assert_rejected(condition(), proof, {:unaccepted_provenance, :derived})
  end

  test "explicit generated acceptance is supported without promoting provenance" do
    proof = evidence(provenance: :generated, parent_refs: ["evidence:parent"])
    assert {:satisfied, [ref]} = check(condition(accepted_provenance: [:generated]), [proof])
    assert ref == proof.ref
    assert proof.provenance == :generated
    assert_rejected(condition(), proof, {:unaccepted_provenance, :generated})
  end

  test "provisional acceptance never extends a proof's finite validity" do
    proof = evidence(provisional: true, valid_until: 101)
    accepting = condition(allow_provisional: true)
    assert {:satisfied, [_]} = check(accepting, [proof])

    assert {:undecidable, {_, :insufficient_evidence, %{rejected: [{_, :evidence_expired}]}}} =
             Recognition.check_condition(accepting, [proof], 101)
  end

  test "required information labels bind their owners as well as their values" do
    {:ok, required} = Label.new(owner_ref: "alice", value: "private")
    {:ok, other} = Label.new(owner_ref: "bob", value: "private")
    condition = condition(parameters: %{"required_labels" => [Label.canonical(required)]})
    assert_rejected(condition, evidence(labels: [other]), :required_labels_missing)
    assert {:satisfied, [_]} = check(condition, [evidence(labels: [required, other])])
  end

  test "an unresolved assumption excludes its dependent proof from the basis" do
    proof = evidence(assumptions: ["network.available"])
    assert_rejected(condition(), proof, {:unresolved_evidence_assumption, "network.available"})
  end

  test "qualified assumption proofs are included transitively in the frozen basis" do
    proof = evidence(assumptions: ["network.available"])
    network = evidence(proposition: "network.available", assumptions: ["power.available"])
    power = evidence(proposition: "power.available")
    assert {:satisfied, refs} = check(condition(), [proof, network, power])
    assert refs == Enum.sort([proof.ref, network.ref, power.ref])
  end

  test "assumption proof must satisfy the same issuer policy as the dependent fact" do
    proof = evidence(assumptions: ["network.available"])
    network = evidence(proposition: "network.available", issuer_ref: "untrusted")
    restricted = condition(parameters: %{"issuer_refs" => ["issuer"]})
    assert {{:undecidable, _}, []} = check(restricted, [proof, network])
  end

  test "explicit accepted assumptions need no manufactured supporting Evidence" do
    proof = evidence(assumptions: ["network.available"])
    condition = condition(parameters: %{"accepted_assumptions" => ["network.available"]})
    assert {:satisfied, [ref]} = check(condition, [proof])
    assert ref == proof.ref
  end

  test "an accepted assumption is still defeated by a qualified contradiction" do
    proof = evidence(assumptions: ["network.available"])
    network = evidence(proposition: "network.available", stance: :contradicts)
    condition = condition(parameters: %{"accepted_assumptions" => ["network.available"]})

    assert {{:undecidable, [{_, :insufficient_evidence, %{actual: 0}}]}, []} =
             check(condition, [proof, network])
  end

  test "cyclic assumption propositions cannot bootstrap their own truth" do
    proof = evidence(assumptions: ["network.available"])
    network = evidence(proposition: "network.available", assumptions: ["paid"])
    assert {{:undecidable, _}, []} = check(condition(), [network, proof])
  end

  test "an independent root can resolve a cyclic branch without depending on that branch" do
    proof = evidence(assumptions: ["network.available"])
    cyclic = evidence(proposition: "network.available", assumptions: ["paid"])
    root = evidence(proposition: "network.available")
    assert {:satisfied, refs} = check(condition(), [proof, cyclic, root])
    assert refs == Enum.sort([proof.ref, root.ref])
  end

  test "numeric coercion cannot invent support for an opaque assumption" do
    proof = evidence(assumptions: [%{"version" => 1}])
    wrong = evidence(proposition: %{"version" => 1.0})
    assert {{:undecidable, _}, []} = check(condition(), [proof, wrong])
    exact = evidence(proposition: %{"version" => 1})
    assert {:satisfied, refs} = check(condition(), [proof, exact])
    assert refs == Enum.sort([proof.ref, exact.ref])
  end

  test "equivalent list and indexed inputs freeze the same sorted basis" do
    first = evidence(issuer_ref: "A")
    second = evidence(issuer_ref: "B")
    records = [second, first]
    assert check(condition(), records) == check(condition(), Map.new(records, &{&1.ref, &1}))
  end

  test "unrelated observations are not included in the authority's factual basis" do
    proof = evidence()
    unrelated = evidence(proposition: "something.else")
    assert {:satisfied, [ref]} = check(condition(), [unrelated, proof])
    assert ref == proof.ref
  end

  test "declared basis cannot omit a second qualified receipt from the same issuer" do
    first = evidence()
    second = evidence(payload: "second receipt")
    assert {:satisfied, refs} = check(condition(), [first, second])

    assert {:error, {:recognition_basis_not_declared, [missing]}} =
             Recognition.validate_declared_basis(refs, [first.ref])

    assert missing == second.ref
    assert :ok = Recognition.validate_declared_basis(refs, refs)
  end

  describe "aggregate coverage" do
    test "separate receipts can establish different members of the required set" do
      condition = condition(coverage: %{"regions" => ["EU", "US"]})
      european = evidence(bindings: %{"regions" => ["EU"]})
      american = evidence(bindings: %{"regions" => ["US"]})
      assert {:satisfied, refs} = check(condition, [european, american])
      assert refs == Enum.sort([european.ref, american.ref])
      assert check(condition, [european, american]) == check(condition, [american, european])
    end

    test "meeting cardinality alone does not supply missing coverage" do
      condition = condition(coverage: %{"regions" => ["EU", "US"]})
      proof = evidence(bindings: %{"regions" => ["EU"]})

      assert {{:undecidable, [{_, :coverage_incomplete, coverage}]}, [ref]} =
               check(condition, [proof])

      assert coverage == condition.coverage
      assert ref == proof.ref
    end

    test "rejected evidence cannot fill a coverage gap" do
      condition =
        condition(
          coverage: %{"regions" => ["EU", "US"]},
          parameters: %{"issuer_refs" => ["issuer"]}
        )

      valid = evidence(bindings: %{"regions" => ["EU"]})
      untrusted = evidence(bindings: %{"regions" => ["US"]}, issuer_ref: "untrusted")

      assert {{:undecidable, [{_, :coverage_incomplete, _}]}, [ref]} =
               check(condition, [valid, untrusted])

      assert ref == valid.ref
    end

    test "a contradiction is never counted as support for missing coverage" do
      condition = condition(coverage: %{"regions" => ["EU", "US"]})
      valid = evidence(bindings: %{"regions" => ["EU"]})
      contrary = evidence(bindings: %{"regions" => ["US"]}, stance: :contradicts)

      assert {{:undecidable, [{_, :conflicting_evidence, _}]}, _} =
               check(condition, [valid, contrary])
    end

    test "repeated identical scalar facts do not destroy established coverage" do
      condition = condition(coverage: %{"account" => "A"})
      first = evidence(bindings: %{"account" => "A"})
      second = evidence(bindings: %{"account" => "A"}, payload: "another receipt")
      assert {:satisfied, [_]} = check(condition, [first])
      assert {:satisfied, refs} = check(condition, [first, second])
      assert refs == Enum.sort([first.ref, second.ref])
    end

    test "nested coverage combines proof sets without flattening their enclosing object" do
      condition = condition(coverage: %{"order" => %{"checks" => ["paid", "delivered"]}})
      first = evidence(bindings: %{"order" => %{"checks" => ["paid"]}})
      second = evidence(bindings: %{"order" => %{"checks" => ["delivered"]}})
      assert {:satisfied, _} = check(condition, [first, second])
      assert check(condition, [first, second]) == check(condition, [second, first])
    end

    test "an asserted wildcard cannot complete concrete coverage" do
      condition = condition(coverage: %{"regions" => ["EU"]})
      proof = evidence(bindings: %{"regions" => :any})
      assert {{:undecidable, [{_, :coverage_incomplete, _}]}, [_]} = check(condition, [proof])
    end
  end

  defp check(condition, evidence), do: Recognition.check_with_basis([condition], evidence, 100)

  defp assert_rejected(condition, proof, reason) do
    assert {{:undecidable, [{ref, :insufficient_evidence, details}]}, []} =
             check(condition, [proof])

    assert ref == condition.ref
    assert details.actual == 0
    assert details.rejected == [{proof.ref, reason}]
    refute Recognition.qualified?(proof, condition, [proof], 100)
  end

  defp condition(attrs \\ []) do
    {:ok, record} = Condition.new(Keyword.merge([proposition: "paid"], attrs))
    record
  end

  defp evidence(attrs \\ []) do
    {:ok, record} =
      Evidence.new(
        Keyword.merge(
          [
            proposition: "paid",
            issuer_ref: "issuer",
            source_ref: "source",
            provenance: :observed,
            observed_at: 100,
            payload: "receipt"
          ],
          attrs
        )
      )

    record
  end
end
