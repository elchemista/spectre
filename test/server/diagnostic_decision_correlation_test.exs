defmodule Spectre.Server.DiagnosticDecisionCorrelationTest do
  use ExUnit.Case, async: true
  alias Spectre.GAM.{Decision, Evidence}
  alias Spectre.GAM.GovernedAct.{Catalog, State}
  alias Spectre.GAM.Scope.{Diagnostics, Opening}

  test "interaction correlation matches exact action and presentation identities" do
    scope = "scope"

    evidence =
      struct(Evidence,
        ref: "evidence",
        proposition: {:spectre_agent_invocation, "work"},
        bindings: %{"scope_ref" => scope},
        payload: %{command_id: "work", interaction: "i1"}
      )

    decisions =
      for {ref, key} <- [
            {"action", "spectre:managed:work"},
            {"presentation", "spectre:managed:show:work"},
            {"different-command", "spectre:managed:work-suffix"},
            {"different-prefix", "unrelated:work"}
          ],
          into: %{} do
        {ref,
         struct(Decision,
           ref: ref,
           scope_ref: scope,
           candidate_identity_key: key,
           reasons: [],
           outcome: :refused
         )}
      end

    projection = %State{
      domain_ref: "domain",
      revision: 1,
      catalog: %Catalog{scopes: %{scope => struct(Opening, ref: scope)}},
      evidence: %{evidence.ref => evidence},
      decisions: decisions
    }

    assert {:ok, %{records: records}} = Diagnostics.page(projection, scope, interaction: "i1")

    assert records |> Enum.filter(&(&1.kind == :decision)) |> Enum.map(& &1.ref) |> Enum.sort() ==
             ["action", "presentation"]

    assert {:ok, %{total: 0}} = Diagnostics.page(projection, scope, interaction: "unrelated")
  end

  test "lifecycle correlation and reason codes redact private values and reject foreign cursors" do
    scope = "scope"

    evidence =
      struct(Evidence,
        ref: "lifecycle",
        proposition: {:spectre_server_lifecycle, "event"},
        bindings: %{"scope_ref" => scope},
        payload: %{event: %{origin_id: "i1", phase: :closed, reason: "PRIVATE", input: "PRIVATE"}}
      )

    decision =
      struct(Decision,
        ref: "decision",
        scope_ref: scope,
        candidate_identity_key: "unrelated",
        reasons: [:expired, {:unavailable, "PRIVATE"}, {"PRIVATE", :unknown}, "PRIVATE", %{}],
        outcome: :refused,
        candidate_class: %{private: "PRIVATE"}
      )

    projection = %State{
      domain_ref: "domain",
      revision: 1,
      catalog: %Catalog{scopes: %{scope => struct(Opening, ref: scope)}},
      evidence: %{evidence.ref => evidence},
      decisions: %{decision.ref => decision}
    }

    assert {:ok, %{records: records}} = Diagnostics.page(projection, scope, [])

    assert %{
             reason_codes: [:expired, :unavailable, :redacted, :redacted, :redacted],
             candidate_class: nil
           } =
             Enum.find(records, &(&1.kind == :decision))

    assert %{lifecycle: %{phase: :closed, reason: nil}} =
             Enum.find(records, &(&1.kind == :evidence))

    refute inspect(records) =~ "PRIVATE"
    assert {:ok, %{total: 1}} = Diagnostics.page(projection, scope, interaction: "i1")
    assert {:ok, %{total: 0}} = Diagnostics.page(projection, scope, interaction: "other")

    assert {:error, :invalid_cursor} =
             Diagnostics.page(projection, scope, cursor: {1, 1, "foreign", nil, 0})

    assert {:error, :invalid_diagnostic_options} = Diagnostics.page(projection, scope, :invalid)
  end
end
