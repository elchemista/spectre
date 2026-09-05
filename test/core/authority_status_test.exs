defmodule Spectre.Core.AuthorityStatusTest do
  use ExUnit.Case, async: true

  alias Spectre.Kernel.Authority.{Facts, Status}
  alias Spectre.Mandate
  alias Spectre.Mandate.Revocation

  setup do
    root = mandate("root", nil)
    child = mandate("child", root.ref)
    leaf = mandate("leaf", child.ref)

    facts = %Facts{
      mandates: Map.new([root, child, leaf], &{&1.ref, &1}),
      mandate_successors: %{},
      revocations: %{},
      blocked_mandate_refs: MapSet.new(),
      blocked_effect_digests: MapSet.new()
    }

    %{root: root, child: child, leaf: leaf, facts: facts}
  end

  test "a pinned current lineage has no status blockers", c do
    assert :ok = Status.exact_snapshot(c.leaf, c.facts)
    assert {:ok, []} = Status.blockers(c.leaf, c.facts, 100)
    assert :ok = Status.standing(c.leaf, c.facts)
  end

  test "an unregistered exact-looking Mandate is not a pinned snapshot", c do
    facts = %{c.facts | mandates: Map.delete(c.facts.mandates, c.leaf.ref)}
    assert {:error, :mandate_not_in_authority_view} = Status.exact_snapshot(c.leaf, facts)
  end

  test "a same-reference changed snapshot cannot impersonate the pinned record", c do
    forged = %{c.leaf | purpose_ref: "another-purpose"}
    assert {:error, :mandate_snapshot_not_pinned} = Status.exact_snapshot(forged, c.facts)
  end

  test "validity starts inclusively", c do
    assert {:error, :mandate_not_yet_valid} = Status.current_at(c.leaf, 89)
    assert :ok = Status.current_at(c.leaf, 90)
    assert {:ok, [:not_yet_valid]} = Status.blockers(c.leaf, c.facts, 89)
  end

  test "expiry is exclusive", c do
    assert :ok = Status.current_at(c.leaf, 199)
    assert {:error, :mandate_expired} = Status.current_at(c.leaf, 200)
    assert {:ok, [:expired]} = Status.blockers(c.leaf, c.facts, 200)
  end

  for {location, field, error} <- [
        {:leaf, :meter_debt, :mandate_meter_debt},
        {:child, :ancestor_meter_debt, :mandate_ancestor_meter_debt},
        {:root, :ancestor_meter_debt, :mandate_ancestor_meter_debt}
      ] do
    test "Meter debt on #{location} blocks descendants without lending authority", c do
      blocked = Map.fetch!(c, unquote(location))
      facts = %{c.facts | blocked_mandate_refs: MapSet.new([blocked.ref])}
      assert {:ok, [unquote(field)]} = Status.blockers(c.leaf, facts, 100)
      assert {:error, unquote(error)} = Status.meter_debt(c.leaf, facts)
      assert {:error, unquote(error)} = Status.standing(c.leaf, facts)
    end
  end

  for {location, field, error} <- [
        {:leaf, :superseded, :mandate_superseded},
        {:child, :ancestor_superseded, :mandate_ancestor_superseded},
        {:root, :ancestor_superseded, :mandate_ancestor_superseded}
      ] do
    test "a successor to #{location} prevents reusing that lineage's old authority", c do
      superseded = Map.fetch!(c, unquote(location))
      facts = %{c.facts | mandate_successors: %{superseded.ref => "successor"}}
      assert {:ok, [unquote(field)]} = Status.blockers(c.leaf, facts, 100)
      assert {:error, unquote(error)} = Status.restriction(c.leaf, facts)
      assert {:error, unquote(error)} = Status.standing(c.leaf, facts)
    end
  end

  test "direct revocation appears as a direct status blocker", c do
    facts = revoke(c.facts, c.leaf)
    assert {:ok, [:revoked]} = Status.blockers(c.leaf, facts, 100)
    assert {:error, :mandate_revoked} = Status.not_revoked(c.leaf, facts, 100)
    assert {:error, :mandate_revoked} = Status.not_directly_revoked(c.leaf, facts, 100)
  end

  test "an ancestor cascade is distinct from direct revocation", c do
    facts = revoke(c.facts, c.root)
    assert {:ok, [:ancestor_revoked]} = Status.blockers(c.leaf, facts, 100)
    assert {:error, :mandate_ancestor_revoked} = Status.not_revoked(c.leaf, facts, 100)
    assert :ok = Status.not_directly_revoked(c.leaf, facts, 100)
  end

  test "all independent blockers are reported, not only the first", c do
    facts = revoke(c.facts, c.leaf)

    facts = %{
      facts
      | mandate_successors: %{c.leaf.ref => "successor"},
        blocked_mandate_refs: MapSet.new([c.root.ref])
    }

    assert {:ok, [:expired, :revoked, :superseded, :ancestor_meter_debt]} =
             Status.blockers(c.leaf, facts, 200)
  end

  test "direct control eligibility does not inherit descendant execution blockers", c do
    facts = %{
      c.facts
      | mandate_successors: %{c.root.ref => "successor"},
        blocked_mandate_refs: MapSet.new([c.root.ref])
    }

    facts = revoke(facts, c.root)
    assert {:ok, []} = Status.direct_blockers(c.leaf, facts, 100)

    assert {:ok, [:ancestor_revoked, :ancestor_superseded, :ancestor_meter_debt]} =
             Status.blockers(c.leaf, facts, 100)
  end

  test "direct control still reports its own expiry and revocation", c do
    assert {:ok, [:expired, :already_revoked]} =
             Status.direct_blockers(c.leaf, revoke(c.facts, c.leaf), 200)
  end

  test "blocking an unrelated Mandate does not block this lineage", c do
    facts = %{
      c.facts
      | mandate_successors: %{"unrelated" => "successor"},
        blocked_mandate_refs: MapSet.new(["unrelated"])
    }

    assert {:ok, []} = Status.blockers(c.leaf, facts, 100)
  end

  test "a missing ancestor is an error instead of an empty blocker list", c do
    facts = %{c.facts | mandates: Map.delete(c.facts.mandates, c.child.ref)}
    assert {:error, {:mandate_ancestor_missing, ref}} = Status.blockers(c.leaf, facts, 100)
    assert ref == c.child.ref
  end

  test "cycle errors are stable across the status facade", c do
    child = %{c.child | parent_ref: c.leaf.ref}
    facts = %{c.facts | mandates: Map.put(c.facts.mandates, child.ref, child)}
    assert {:error, :mandate_ancestry_cycle} = Status.blockers(c.leaf, facts, 100)
    assert {:error, :mandate_ancestry_cycle} = Status.standing(c.leaf, facts)
  end

  defp revoke(facts, mandate) do
    revocation = %Revocation{identity: "revocation", effective_at: 100, mode: :cascade}
    %{facts | revocations: Map.put(facts.revocations, mandate.ref, revocation)}
  end

  defp mandate(name, parent) do
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
        source_ref: "source:#{name}"
      })

    mandate
  end
end
