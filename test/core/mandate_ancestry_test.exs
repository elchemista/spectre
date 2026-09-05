defmodule Spectre.Core.MandateAncestryTest do
  use ExUnit.Case, async: true

  alias Spectre.Mandate
  alias Spectre.Mandate.{Ancestry, Revocation}

  setup do
    root = mandate("root", nil, :cascade)
    child = mandate("child", root.ref, :cascade)
    leaf = mandate("leaf", child.ref, :cascade)
    other = mandate("other", nil, :cascade)

    %{
      root: root,
      child: child,
      leaf: leaf,
      other: other,
      index: Map.new([root, child, leaf, other], &{&1.ref, &1})
    }
  end

  test "lineage is ordered from the exact leaf to its root", c do
    assert {:ok, [leaf, child, root]} = Ancestry.lineage(c.index, c.leaf)
    assert [leaf, child, root] == [c.leaf, c.child, c.root]
  end

  test "an unrelated malformed branch cannot poison a valid lineage", c do
    index = Map.put(c.index, c.other.ref, :corrupt)
    assert {:ok, [_, _, _]} = Ancestry.lineage(index, c.leaf)
    assert {:ok, :current} = Ancestry.status(index, %{}, c.leaf, 100)
  end

  test "a missing ancestor is a history error, not a revocation decision", c do
    index = Map.delete(c.index, c.child.ref)
    assert {:error, {:mandate_ancestor_missing, ref}} = Ancestry.status(index, %{}, c.leaf, 100)
    assert ref == c.child.ref
  end

  test "canonical maps are not silently decoded inside the typed lineage algebra", c do
    index = Map.put(c.index, c.child.ref, Mandate.canonical(c.child))
    assert {:error, {:invalid_mandate_ancestor, ref}} = Ancestry.lineage(index, c.leaf)
    assert ref == c.child.ref
  end

  test "an index entry cannot impersonate the requested ancestor's reference", c do
    index = Map.put(c.index, c.child.ref, c.other)
    assert {:error, {:invalid_mandate_ancestor, ref}} = Ancestry.lineage(index, c.leaf)
    assert ref == c.child.ref
  end

  test "a self-cycle is rejected instead of being treated as revoked", c do
    # Corrupt disposable state deliberately: no content-addressed constructor
    # can manufacture a genuine cyclic chain. This is the corruption boundary.
    leaf = %{c.leaf | parent_ref: c.leaf.ref}
    index = Map.put(c.index, leaf.ref, leaf)
    assert {:error, {:mandate_ancestry_cycle, ref}} = Ancestry.status(index, %{}, leaf, 100)
    assert ref == leaf.ref
  end

  test "a multi-node cycle is detected even when a revocation exists on the cycle", c do
    child = %{c.child | parent_ref: c.leaf.ref}
    index = Map.put(c.index, child.ref, child)
    revoked = revocations(child, 100)
    assert {:error, {:mandate_ancestry_cycle, _}} = Ancestry.status(index, revoked, c.leaf, 100)
  end

  test "an invalid parent coordinate cannot terminate a chain as a root", c do
    for invalid <- ["", 0, false] do
      leaf = %{c.leaf | parent_ref: invalid}
      assert {:error, {:invalid_mandate_parent_ref, ^invalid}} = Ancestry.lineage(c.index, leaf)
    end
  end

  test "direct revocation identifies the leaf itself", c do
    assert {:ok, {:revoked, :direct, ref}} =
             Ancestry.status(c.index, revocations(c.leaf, 100), c.leaf, 100)

    assert ref == c.leaf.ref
  end

  test "cascading revocation identifies the closest effective ancestor", c do
    revoked = Map.merge(revocations(c.root, 100), revocations(c.child, 100))
    assert {:ok, {:revoked, :ancestor, ref}} = Ancestry.status(c.index, revoked, c.leaf, 100)
    assert ref == c.child.ref
  end

  test "direct revocation takes precedence over inherited revocation", c do
    revoked = Map.merge(revocations(c.root, 100), revocations(c.leaf, 100))
    assert {:ok, {:revoked, :direct, ref}} = Ancestry.status(c.index, revoked, c.leaf, 100)
    assert ref == c.leaf.ref
  end

  test "a root cascade reaches grandchildren", c do
    assert {:ok, {:revoked, :ancestor, ref}} =
             Ancestry.status(c.index, revocations(c.root, 100), c.leaf, 100)

    assert ref == c.root.ref
    assert {:ok, true} = Ancestry.revoked?(c.index, revocations(c.root, 100), c.leaf, 100)
  end

  test "retained-controller revocation of a parent is not an implicit cascade" do
    root = mandate("root", nil, :retained_controller)
    child = mandate("child", root.ref, :retained_controller)
    index = Map.new([root, child], &{&1.ref, &1})

    assert {:ok, {:revoked, :direct, _}} =
             Ancestry.status(index, revocations(root, 100), root, 100)

    assert {:ok, :current} = Ancestry.status(index, revocations(root, 100), child, 100)
  end

  test "a non-cascading intermediate does not hide a higher ancestor's cascade", c do
    child = mandate("retained-child", c.root.ref, :retained_controller)
    leaf = mandate("retained-leaf", child.ref, :retained_controller)
    index = Map.new([c.root, child, leaf], &{&1.ref, &1})
    revoked = Map.merge(revocations(c.root, 100), revocations(child, 100))
    assert {:ok, {:revoked, :ancestor, ref}} = Ancestry.status(index, revoked, leaf, 100)
    assert ref == c.root.ref
  end

  test "future revocation becomes effective exactly at its recorded instant", c do
    revoked = revocations(c.root, 101)
    assert {:ok, :current} = Ancestry.status(c.index, revoked, c.leaf, 100)
    assert {:ok, {:revoked, :ancestor, _}} = Ancestry.status(c.index, revoked, c.leaf, 101)
  end

  test "an unrelated revocation does not affect the leaf", c do
    assert {:ok, :current} = Ancestry.status(c.index, revocations(c.other, 100), c.leaf, 100)
  end

  test "local revocation checks do not inherit an ancestor's status", c do
    revoked = revocations(c.root, 100)
    assert {:ok, false} = Ancestry.directly_revoked?(revoked, c.leaf, 100)
    assert {:ok, true} = Ancestry.revoked?(c.index, revoked, c.leaf, 100)
  end

  test "unrestored revocation maps are rejected rather than interpreted", c do
    revoked = %{c.root.ref => %{"effective_at" => 100, "mode" => :cascade}}

    assert {:error, {:invalid_mandate_revocation, ref}} =
             Ancestry.status(c.index, revoked, c.leaf, 100)

    assert ref == c.root.ref
  end

  test "terminal status includes the exclusive expiration boundary", c do
    assert {:ok, false} = Ancestry.terminal?(c.index, %{}, c.leaf, 199)
    assert {:ok, true} = Ancestry.terminal?(c.index, %{}, c.leaf, 200)
  end

  test "a current Mandate becomes terminal on effective revocation", c do
    assert {:ok, true} = Ancestry.terminal?(c.index, revocations(c.leaf, 100), c.leaf, 100)
  end

  test "descendant relation is reflexive and transitive but not symmetric", c do
    assert {:ok, true} = Ancestry.descendant?(c.index, c.leaf.ref, c.leaf.ref)
    assert {:ok, true} = Ancestry.descendant?(c.index, c.leaf.ref, c.root.ref)
    assert {:ok, false} = Ancestry.descendant?(c.index, c.root.ref, c.leaf.ref)
    assert {:ok, false} = Ancestry.descendant?(c.index, c.leaf.ref, c.other.ref)
  end

  test "a non-cascading authority change only affects its exact target", c do
    assert {:ok, true} = Ancestry.affected_by?(c.index, c.root.ref, c.root.ref, false)
    assert {:ok, false} = Ancestry.affected_by?(c.index, c.leaf.ref, c.root.ref, false)
    assert {:ok, true} = Ancestry.affected_by?(c.index, c.leaf.ref, c.root.ref, true)
  end

  test "descendant traversal rejects a reference aliased to another Mandate", c do
    index = Map.put(c.index, c.leaf.ref, %{c.other | parent_ref: c.root.ref})

    assert {:error, {:invalid_mandate_ancestor, ref}} =
             Ancestry.descendant?(index, c.leaf.ref, c.root.ref)

    assert ref == c.leaf.ref
  end

  test "descendant traversal cannot spin on a cycle that excludes the target", c do
    child = %{c.child | parent_ref: c.leaf.ref}
    index = Map.put(c.index, child.ref, child)

    assert {:error, {:mandate_ancestry_cycle, _}} =
             Ancestry.descendant?(index, c.leaf.ref, c.other.ref)
  end

  test "a missing visited Mandate is not proof of an unrelated root", c do
    index = Map.delete(c.index, c.child.ref)

    assert {:error, {:mandate_not_found, ref}} =
             Ancestry.descendant?(index, c.leaf.ref, c.other.ref)

    assert ref == c.child.ref
  end

  defp revocations(mandate, time) do
    %{
      mandate.ref => %Revocation{
        identity: "revocation:#{mandate.ref}",
        effective_at: time,
        mode: mandate.revocation["mode"]
      }
    }
  end

  defp mandate(name, parent, mode) do
    {:ok, mandate} =
      Mandate.new(%{
        grantor_ref: "grantor",
        holder_ref: name,
        accountable_ref: "owner",
        executor_refs: ["executor"],
        executor_contract_refs: ["contract"],
        scope_refs: ["scope"],
        classes: ["app.read"],
        ceiling: %{read: true},
        purpose_ref: "purpose",
        purpose_params: %{},
        not_before: 90,
        expires_at: 200,
        parent_ref: parent,
        revocation: %{"mode" => mode, "controller_refs" => ["grantor"]},
        source_ref: "source:#{name}"
      })

    mandate
  end
end
