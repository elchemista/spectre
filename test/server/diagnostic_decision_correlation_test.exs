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
end
