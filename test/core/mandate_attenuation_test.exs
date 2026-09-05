defmodule Spectre.Core.MandateAttenuationTest do
  use ExUnit.Case, async: true

  alias Spectre.{Candidate, Condition, Label, Mandate, Row}
  alias Spectre.Kernel.Authority.{Attenuation, Coverage}

  setup do
    {:ok, condition} = Condition.new(proposition: "paid", freshness_ms: 100)
    {:ok, label} = Label.new(owner_ref: "owner", value: "private")
    {:ok, row} = Row.new(read: true, write: true, govern: true, delegate: true)

    {:ok, parent} =
      Mandate.new(%{
        grantor_ref: "root",
        holder_ref: "team",
        accountable_ref: "owner",
        executor_refs: ["executor:a", "executor:b"],
        executor_contract_refs: ["contract:a", "contract:b"],
        scope_refs: ["scope:a", "scope:b"],
        subject_refs: ["subject:a", "subject:b"],
        target_refs: ["target:a", "target:b"],
        classes: ["app.read", "app.write"],
        ceiling: row,
        disclosable_labels: [label],
        purpose_ref: "purpose",
        purpose_params: %{"revision" => 1},
        conditions: [condition],
        not_before: 90,
        expires_at: 200,
        meters: %{"meter" => 100},
        delegation: %{"allowed" => true, "max_depth" => 2},
        revocation: %{"mode" => :cascade, "controller_refs" => ["root"]},
        source_ref: "genesis"
      })

    child =
      change(parent,
        parent_ref: parent.ref,
        grantor_ref: parent.holder_ref,
        holder_ref: "worker",
        meters: %{"meter" => 30},
        delegation: %{"allowed" => true, "max_depth" => 1},
        source_ref: "act:delegate"
      )

    successor = change(parent, revision: 2, target_refs: ["target:a"], source_ref: "act:restrict")
    assert :ok = Attenuation.delegation_within?(parent, child, 100)
    assert :ok = Attenuation.restriction_within?(parent, successor, 100)
    %{parent: parent, child: child, successor: successor, condition: condition}
  end

  for {operation, target} <- [delegation: :child, restriction: :successor],
      {field, outside} <- [
        executor_refs: ["executor:outside"],
        executor_contract_refs: ["contract:outside"],
        scope_refs: ["scope:outside"],
        subject_refs: ["subject:outside"],
        target_refs: ["target:outside"],
        classes: ["app.admin"]
      ] do
    test "#{operation} cannot expand #{field}", c do
      narrowed = change(Map.fetch!(c, unquote(target)), [{unquote(field), unquote(outside)}])

      assert {:error, {:delegation_expanded, unquote(field)}} =
               check(unquote(operation), c.parent, narrowed)
    end
  end

  for {operation, target} <- [delegation: :child, restriction: :successor] do
    test "#{operation} cannot gain a new Row power", c do
      {:ok, expanded} =
        Row.new(read: true, write: true, govern: true, delegate: true, spend: true)

      narrowed = change(Map.fetch!(c, unquote(target)), ceiling: expanded)

      assert {:error, {:delegation_expanded, :ceiling}} =
               check(unquote(operation), c.parent, narrowed)
    end

    test "#{operation} cannot authorize another owner's label", c do
      {:ok, label} = Label.new(owner_ref: "other-owner", value: "private")
      narrowed = change(Map.fetch!(c, unquote(target)), disclosable_labels: [label])

      assert {:error, {:delegation_expanded, :disclosable_labels}} =
               check(unquote(operation), c.parent, narrowed)
    end

    test "#{operation} cannot remove the parent's Condition", c do
      narrowed = change(Map.fetch!(c, unquote(target)), conditions: [])

      assert {:error, {:delegation_expanded, :conditions, ref}} =
               check(unquote(operation), c.parent, narrowed)

      assert ref == c.condition.ref
    end

    test "#{operation} cannot weaken a matched Condition's freshness", c do
      {:ok, weak} = Condition.new(proposition: "paid", freshness_ms: 101)
      narrowed = change(Map.fetch!(c, unquote(target)), conditions: [weak])

      assert {:error,
              {:delegation_expanded, :conditions, ref, {:condition_weakened, :freshness_ms}}} =
               check(unquote(operation), c.parent, narrowed)

      assert ref == c.condition.ref
    end

    test "#{operation} preserves the exact opaque purpose parameters", c do
      narrowed = change(Map.fetch!(c, unquote(target)), purpose_params: %{"revision" => 1.0})

      assert {:error, {:delegation_expanded, :purpose}} =
               check(unquote(operation), c.parent, narrowed)
    end

    test "#{operation} cannot extend expiry", c do
      narrowed = change(Map.fetch!(c, unquote(target)), expires_at: 201)

      assert {:error, {:delegation_expanded, :time_window}} =
               check(unquote(operation), c.parent, narrowed)
    end

    test "#{operation} cannot backdate its start", c do
      narrowed = change(Map.fetch!(c, unquote(target)), not_before: 89)

      assert {:error, {:delegation_expanded, :time_window}} =
               check(unquote(operation), c.parent, narrowed)
    end

    test "#{operation} may require additional independent facts", c do
      {:ok, extra} = Condition.new(proposition: "delivered")
      narrowed = change(Map.fetch!(c, unquote(target)), conditions: [c.condition, extra])
      assert :ok = check(unquote(operation), c.parent, narrowed)
    end
  end

  test "delegation is denied when the parent did not permit delegation", c do
    parent = change(c.parent, delegation: %{"allowed" => false, "max_depth" => 0})
    child = change(c.child, parent_ref: parent.ref)
    assert {:error, :delegation_not_allowed} = check(:delegation, parent, child)
  end

  test "a child must consume one delegation depth", c do
    child = change(c.child, delegation: %{"allowed" => true, "max_depth" => 2})
    assert {:error, :delegation_depth_expanded} = check(:delegation, c.parent, child)
  end

  test "delegation cannot substitute another parent", c do
    child = change(c.child, parent_ref: "different-parent")
    assert {:error, :delegation_parent_mismatch} = check(:delegation, c.parent, child)
  end

  test "only the parent holder can be the child's grantor", c do
    child = change(c.child, grantor_ref: c.parent.grantor_ref)
    assert {:error, :delegation_grantor_mismatch} = check(:delegation, c.parent, child)
  end

  test "delegation cannot transfer accountability", c do
    child = change(c.child, accountable_ref: "another-owner")
    assert {:error, :delegation_accountable_expanded} = check(:delegation, c.parent, child)
  end

  test "a child cannot receive more than the parent's quantitative ceiling", c do
    child = change(c.child, meters: %{"meter" => 101})

    assert {:error, {:delegation_expanded, :meters, {"meter", 101}}} =
             check(:delegation, c.parent, child)
  end

  test "an unknown Meter cannot be allocated even with a zero ceiling", c do
    child = change(c.child, meters: %{"unknown-meter" => 0})

    assert {:error, {:delegation_expanded, :meters, {"unknown-meter", 0}}} =
             check(:delegation, c.parent, child)
  end

  test "delegation cannot change revocation mode or replace controllers", c do
    for revocation <- [
          %{"mode" => :retained_controller, "controller_refs" => ["root"]},
          %{"mode" => :cascade, "controller_refs" => ["team"]}
        ] do
      child = change(c.child, revocation: revocation)
      assert {:error, {:delegation_expanded, :revocation}} = check(:delegation, c.parent, child)
    end
  end

  test "restriction requires the immediate next revision", c do
    successor = change(c.successor, revision: 3)

    assert {:error, :restriction_revision_not_sequential} =
             check(:restriction, c.parent, successor)
  end

  test "restriction cannot silently become a delegated child", c do
    successor = change(c.successor, parent_ref: c.parent.ref)
    assert {:error, :restriction_lineage_changed} = check(:restriction, c.parent, successor)
  end

  for role <- [:grantor_ref, :holder_ref, :accountable_ref] do
    test "restriction cannot change #{role}", c do
      successor = change(c.successor, [{unquote(role), "other"}])

      assert {:error, {:restriction_role_changed, unquote(role)}} =
               check(:restriction, c.parent, successor)
    end
  end

  test "restriction cannot increase delegation depth", c do
    successor = change(c.successor, delegation: %{"allowed" => true, "max_depth" => 3})

    assert {:error, {:delegation_expanded, :delegation}} =
             check(:restriction, c.parent, successor)
  end

  test "restriction may remove delegation completely", c do
    successor = change(c.successor, delegation: %{"allowed" => false, "max_depth" => 0})
    assert :ok = check(:restriction, c.parent, successor)
  end

  test "restriction cannot change Meter accounting, even by reducing an amount", c do
    for amount <- [0, 99, 101] do
      successor = change(c.successor, meters: %{"meter" => amount})
      assert {:error, {:restriction_changed, :meters}} = check(:restriction, c.parent, successor)
    end
  end

  test "restriction cannot change the revocation policy", c do
    successor =
      change(c.successor,
        revocation: %{"mode" => :retained_controller, "controller_refs" => ["root"]}
      )

    assert {:error, {:restriction_changed, :revocation}} =
             check(:restriction, c.parent, successor)
  end

  test "a new revision and source Act alone are not a strict restriction", c do
    successor = change(c.parent, revision: 2, source_ref: "act:cosmetic")

    assert {:error, :mandate_restriction_must_be_strict} =
             check(:restriction, c.parent, successor)
  end

  test "canonical parent and child inputs enforce the same authority boundary", c do
    assert :ok =
             Attenuation.delegation_within?(
               Mandate.canonical(c.parent),
               Mandate.canonical(c.child),
               100
             )

    assert :ok =
             Attenuation.restriction_within?(
               Mandate.canonical(c.parent),
               Mandate.canonical(c.successor),
               100
             )
  end

  test "delegation cannot use a parent before validity or at its expiry", c do
    assert {:error, :mandate_not_yet_valid} =
             Attenuation.delegation_within?(c.parent, c.child, 89)

    assert :ok = Attenuation.delegation_within?(c.parent, c.child, 90)
    assert {:error, :mandate_expired} = Attenuation.delegation_within?(c.parent, c.child, 200)
  end

  test "restriction cannot activate a successor which is not yet valid", c do
    successor = change(c.successor, not_before: 101)
    assert {:error, :mandate_not_yet_valid} = check(:restriction, c.parent, successor)
    assert :ok = Attenuation.restriction_within?(c.parent, successor, 101)
  end

  test "Candidate purpose parameters cannot bypass the same exact-value boundary", c do
    {:ok, row} = Row.new(read: true)

    attrs = %{
      identity_key: "read",
      class: "app.read",
      row: row,
      consequence: %{"read" => "document"},
      proposer_ref: "team",
      executor_ref: "executor:a",
      executor_contract_ref: "contract:a",
      accountable_ref: "owner",
      scope_ref: "scope:a",
      purpose_ref: "purpose",
      purpose_params: %{"revision" => 1},
      observation_window_ms: 0
    }

    assert {:ok, exact} = Candidate.new(attrs)
    assert :ok = Coverage.covered_purpose(exact, c.parent)
    assert {:ok, changed} = Candidate.new(%{attrs | purpose_params: %{"revision" => 1.0}})

    assert {:error, :purpose_parameters_outside_mandate} =
             Coverage.covered_purpose(changed, c.parent)
  end

  defp check(:delegation, parent, child), do: Attenuation.delegation_within?(parent, child, 100)
  defp check(:restriction, parent, child), do: Attenuation.restriction_within?(parent, child, 100)

  defp change(mandate, attrs) do
    {:ok, changed} =
      mandate
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.merge(Map.new(attrs))
      |> Mandate.new()

    changed
  end
end
