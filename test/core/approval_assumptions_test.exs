defmodule Spectre.CoreTest.ApprovalAssumptionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.{Evidence, Presentation}
  alias Spectre.Presentation.Approval.Assumptions

  # These tests exercise the pure graph contract with validated records. Live
  # ingestion, show/approval ordering and replay are covered in FullAgentsTest.
  setup do
    assert {:ok, presentation} =
             Presentation.new(%{
               candidate_binding_ref: "candidate-binding",
               scope_ref: "scope",
               recipient_refs: ["recipient"],
               approval_source_refs: ["ingress"],
               data: %{},
               cost: 0,
               purpose_ref: "purpose",
               purpose_params: %{},
               risk: "low",
               reversibility: false,
               alternatives: [],
               renderer_ref: "renderer",
               rendered_payload: "Please approve",
               prepared_at: 80
             })

    %{
      presentation: presentation,
      approval: evidence("approval", assumptions: ["fee-known"], observed_at: 100)
    }
  end

  test "approval without assumptions requires no invented witness", c do
    approval = evidence("approval", observed_at: 100)
    assert {:ok, []} = recognize(c, approval, [])
  end

  test "a declared assumption with no supporting record is not silently accepted", c do
    assert {:error, {:unrecognized_presentation_approval_assumption, "fee-known"}} =
             recognize(c, c.approval, [])
  end

  test "a valid supporting observation contributes its exact ref", c do
    witness = evidence("fee-known")
    assert {:ok, [ref]} = recognize(c, c.approval, [witness])
    assert ref === witness.ref
  end

  for {name, attrs} <- [
        {"another issuer", [issuer_ref: "other-person"]},
        {"an unconfigured source", [source_ref: "model"]},
        {"a missing authenticated issuer", [bindings: %{}]},
        {"a mismatched authenticated issuer",
         [bindings: %{"authenticated_principal_ref" => "other-person"}]},
        {"provisional input", [provisional: true, valid_until: 200]},
        {"generated claims", [provenance: :generated, parent_refs: ["untrusted-parent"]]},
        {"derived claims", [provenance: :derived, parent_refs: ["untrusted-parent"]]},
        {"evidence first observed after approval", [observed_at: 101]},
        {"evidence beyond its freshness budget", [freshness_ms: 19]},
        {"evidence expired exactly at evaluation", [valid_until: 110]},
        {"evidence not valid yet", [valid_from: 111]}
      ] do
    test "#{name} cannot discharge a consent assumption", c do
      witness = evidence("fee-known", unquote(Macro.escape(attrs)))

      assert {:error, {:unrecognized_presentation_approval_assumption, "fee-known"}} =
               recognize(c, c.approval, [witness])
    end
  end

  test "freshness remains inclusive at its exact budget", c do
    witness = evidence("fee-known", freshness_ms: 20)
    assert {:ok, [ref]} = recognize(c, c.approval, [witness])
    assert ref === witness.ref
  end

  test "a qualified later contradiction invalidates an earlier assumption", c do
    support = evidence("fee-known")
    contradiction = evidence("fee-known", stance: :contradicts, observed_at: 105)
    assert {:error, _} = recognize(c, c.approval, [support, contradiction])
  end

  test "an untrusted contradiction cannot veto a qualified support", c do
    support = evidence("fee-known")
    contradiction = evidence("fee-known", stance: :contradicts, source_ref: "untrusted")
    assert {:ok, refs} = recognize(c, c.approval, [support, contradiction])
    assert refs === [support.ref]
  end

  test "a contradiction whose own assumption lacks proof cannot veto consent", c do
    support = evidence("fee-known")
    contradiction = evidence("fee-known", stance: :contradicts, assumptions: ["unproven"])
    assert {:ok, [ref]} = recognize(c, c.approval, [support, contradiction])
    assert ref === support.ref
  end

  test "a qualified nested contradiction contributes its whole basis", c do
    leaf = evidence("fee-disputed")
    contradiction = evidence("fee-known", stance: :contradicts, assumptions: [leaf.proposition])
    index = Assumptions.index([leaf, contradiction])

    assert {:ok, refs} =
             Assumptions.contradiction_basis(
               contradiction,
               c.approval,
               c.presentation,
               index,
               110
             )

    assert refs === Enum.sort([leaf.ref, contradiction.ref])
  end

  test "support cannot enter the contradiction lane", c do
    support = evidence("fee-known")

    assert {:error, _} =
             Assumptions.contradiction_basis(support, c.approval, c.presentation, %{}, 110)
  end

  test "self-referential support cannot bootstrap its own truth", c do
    cyclic = evidence("fee-known", assumptions: ["fee-known"])
    assert {:error, _} = recognize(c, c.approval, [cyclic])
  end

  test "a two-node cycle without a grounded witness cannot satisfy consent", c do
    fee = evidence("fee-known", assumptions: ["terms-known"])
    terms = evidence("terms-known", assumptions: ["fee-known"])
    assert {:error, _} = recognize(c, c.approval, [fee, terms])
  end

  test "an independent witness remains usable in the presence of a cyclic branch", c do
    grounded = evidence("fee-known")
    cyclic = evidence("fee-known", assumptions: ["missing-cycle"])
    back = evidence("missing-cycle", assumptions: ["missing-cycle"])
    assert {:ok, refs} = recognize(c, c.approval, [cyclic, back, grounded])
    assert refs === [grounded.ref]
  end

  test "the approval itself cannot supply an assumption of that approval", c do
    approval = evidence("approval", assumptions: ["approval"], observed_at: 100)
    assert {:error, _} = recognize(c, approval, [approval])
  end

  test "a shared leaf in a diamond is not mistaken for a cycle and is retained once", c do
    leaf = evidence("terms-known")
    left = evidence("fee-known", assumptions: [leaf.proposition])
    right = evidence("risk-known", assumptions: [leaf.proposition])

    approval =
      evidence("approval", assumptions: [left.proposition, right.proposition], observed_at: 100)

    assert {:ok, refs} = recognize(c, approval, [right, leaf, left])
    assert refs === Enum.sort([leaf.ref, left.ref, right.ref])
  end

  test "numeric equivalence does not merge distinct canonical propositions", c do
    approval = evidence("approval", assumptions: [%{"fee" => 1}], observed_at: 100)
    wrong = evidence(%{"fee" => 1.0})
    exact = evidence(%{"fee" => 1})
    assert {:error, _} = recognize(c, approval, [wrong])
    assert {:ok, refs} = recognize(c, approval, [wrong, exact])
    assert refs === [exact.ref]
  end

  property "nested support preserves its entire basis independent of input order", c do
    check all(depth <- integer(1..30), rotation <- integer(0..29), max_runs: 40) do
      chain =
        Enum.map(1..depth, fn i ->
          evidence({:premise, i}, assumptions: if(i == 1, do: [], else: [{:premise, i - 1}]))
        end)

      approval = evidence("approval", assumptions: [{:premise, depth}], observed_at: 100)
      {left, right} = Enum.split(chain, rem(rotation, depth))
      expected = Enum.sort(Enum.map(chain, & &1.ref))
      assert {:ok, ^expected} = recognize(c, approval, right ++ left)
      assert {:ok, ^expected} = recognize(c, approval, Enum.reverse(chain))
      assert {:error, _} = recognize(c, approval, tl(chain))
    end
  end

  defp recognize(c, approval, evidence),
    do: Assumptions.recognize(approval, c.presentation, Assumptions.index(evidence), 110)

  defp evidence(proposition, opts \\ []) do
    attrs = %{
      proposition: proposition,
      issuer_ref: "recipient",
      source_ref: "ingress",
      provenance: :observed,
      observed_at: 90,
      bindings: %{"authenticated_principal_ref" => "recipient"},
      payload: "observation"
    }

    assert {:ok, item} = Evidence.new(Map.merge(attrs, Map.new(opts)))
    item
  end
end
