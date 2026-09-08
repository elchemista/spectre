defmodule Spectre.IntrinsicConsequenceBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Governance, Row}
  alias Spectre.GovernedAct.Materialization

  # Each well-shaped command is paired with an insufficient effect Row and an
  # invalid body under the correct Row. Neither may emit a partial fact suffix.
  for {class, consequence, dimensions, error} <- [
        {"principal.register", %{"principal_registration" => %{}}, [:govern],
         :invalid_principal_registration},
        {"mandate.delegate", %{"mandate_issue" => %{}}, [:delegate, :govern],
         :invalid_delegated_mandate_issue},
        {"mandate.devolve",
         %{"mandate_devolve" => %{"child_mandate_ref" => "child", "amounts" => %{}}},
         [:delegate, :govern], :invalid_meter_devolution},
        {"mandate.restrict",
         %{"mandate_restrict" => %{"predecessor_ref" => "previous", "successor" => %{}}},
         [:govern], :invalid_mandate_restriction},
        {"surface.revise",
         %{"surface_revision" => %{"previous_ref" => "previous", "surface" => %{}}}, [:govern],
         :invalid_surface_revision},
        {"host_profile.revise",
         %{"host_profile_revision" => %{"previous_ref" => "previous", "host_profile" => %{}}},
         [:govern], :invalid_host_profile_revision},
        {"definition.revise",
         %{"definition_revision" => %{"previous_ref" => "previous", "definition" => %{}}},
         [:govern], :invalid_definition_revision},
        {"data.declassify", %{"evidence_declassification" => %{}}, [:write, :govern],
         :invalid_evidence_declassification},
        {"data.erase", %{"erasure_request" => %{}}, [:attempt, :write, :govern],
         :invalid_erasure_request},
        {"scope.open", %{"scope_open" => %{}}, [:write, :govern], :invalid_governed_scope_opening}
      ] do
    test "#{class} cannot materialize with the wrong authority Row or an incomplete body", c do
      act = %{
        c.act
        | class: unquote(class),
          consequence: unquote(Macro.escape(consequence)),
          reservations: %{}
      }

      assert {:error, unquote(error)} = Materialization.intrinsic_events(act)
      {:ok, row} = Row.new(Map.new(unquote(dimensions), &{&1, true}))

      act = %{
        act
        | row: row,
          observation_window_ms: 0,
          executor_ref: Governance.kernel_executor_ref(),
          executor_contract_ref: Governance.kernel_contract_ref()
      }

      assert {:error, _} = Materialization.intrinsic_events(act)
      assert {:error, _} = Materialization.events(c.before, act)
    end
  end

  test "devolution records the exact child and amount, and rejects a reservation on the governing Act",
       c do
    {:ok, row} = Row.new(%{delegate: true, govern: true})

    consequence = %{
      "mandate_devolve" => %{"child_mandate_ref" => "child", "amounts" => %{c.f.refs.meter => 40}}
    }

    act = %{
      c.act
      | ref: nil,
        row: row,
        class: "mandate.devolve",
        consequence: consequence,
        reservations: %{},
        disclosure: nil
    }

    assert {:ok, act} = Spectre.Act.new(act)
    assert {:ok, [event]} = Materialization.intrinsic_events(act)
    assert event["type"] == "meter_devolved"
    assert event["data"]["child_mandate_ref"] == "child"
    assert event["data"]["amounts"] == %{c.f.refs.meter => 40}

    assert {:error, :invalid_meter_devolution} =
             Materialization.intrinsic_events(%{act | reservations: c.act.reservations})
  end

  test "revocation cannot be hidden inside an ordinary external effect", c do
    consequence = %{"mandate_revoke" => %{"mandate_ref" => c.f.mandate.ref}}
    act = %{c.act | class: "mandate.revoke", consequence: consequence}
    assert {:error, :invalid_mandate_revocation} = Materialization.intrinsic_events(act)
    {:ok, row} = Row.new(%{govern: true})

    assert {:error, :invalid_mandate_revocation} =
             Materialization.intrinsic_events(%{act | row: row})

    assert {:error, :unknown_governance_consequence} =
             Materialization.intrinsic_events(%{act | row: row, class: "app.unknown"})

    {:ok, row} = Row.new(%{delegate: true})

    assert {:error, :invalid_delegation_consequence} =
             Materialization.intrinsic_events(%{act | row: row, class: "app.unknown"})

    assert {:ok, []} = Materialization.intrinsic_events(c.act)
  end
end
