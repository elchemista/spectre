defmodule Spectre.Core.AgentsGovernanceTest do
  use Spectre.Test.FullAgentCase, async: false

  alias Spectre.Instance
  alias Spectre.V04Test.Runtime

  describe "governed Definition changes with live agents" do
    test "activation does not silently repin an existing Instance", c do
      activate_successor(c)
      assert {:ok, definition} = Instance.definition(c.instance)
      assert definition == c.definition
      assert {:ok, %{candidates: [candidate], turn: turn}} = turn(c, "refund")
      assert_receive {:deliberation, _, ^turn, opts}
      assert opts[:definition_ref] == c.definition.ref
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert_success(c, result)
    end

    test "a fresh Instance can use the successor's template without changing the old one", c do
      activate_successor(c)

      updated =
        start_supervised!({Instance, scope: c.scope, definition_ref: c.successor.ref, state: 20},
          id: :updated
        )

      configured = %{c | instance: updated, definition: c.successor, template: "updated/refund"}
      assert {:ok, %{candidates: [candidate], turn: turn}} = turn(configured, "refund")
      assert_receive {:deliberation, worker, ^turn, opts}
      refute worker == updated
      refute worker == c.fixture.server
      assert opts[:definition_ref] == c.successor.ref
      assert opts[:state_revision] == 0
      assert Instance.state(updated) == %{revision: 1, value: 21}
      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert {:ok, result} = Instance.propose(updated, candidate)
      assert_success(c, result)
    end

    test "a Candidate prepared before activation still needs and uses its original authority",
         c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      activate_successor(c)
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.act.mandate_ref == c.fixture.mandate.ref
      assert_success(c, result)
    end

    test "changing Definition leaves spent budget and historical outcomes untouched", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", amount: 700)
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert_success(c, result)
      before = projection(c)
      activate_successor(c)
      after_activation = projection(c)
      assert after_activation.meters == before.meters
      assert after_activation.outcomes == before.outcomes
      assert after_activation.attempts == before.attempts
      assert after_activation.acts[result.primary.act.ref] == result.primary.act
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "a valid successor does not authorize an agent to activate itself", c do
      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Spectre.revise_definition(c.scope, c.successor, revision_attrs(c))

      assert projection(c).catalog == before.catalog
      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert {:ok, definition} = Instance.definition(c.instance)
      assert definition == c.definition
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "a removed template fails locally without altering application state", c do
      activate_successor(c)
      before = projection(c)
      configured = %{c | definition: c.successor}

      assert {:error, {:unknown_candidate_template, "payment/refund"}} =
               turn(configured, "refund")

      assert Instance.state(c.instance) == %{revision: 0, value: 0}
      assert projection(c).acts == before.acts
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  describe "retained control over a live agent's Mandate" do
    @describetag revocation_mode: :retained_controller

    test "the controller can revoke without satisfying the agent's payment Condition", c do
      before = projection(c)
      assert before.evidence == %{}

      assert {:ok, %{primary: primary}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      assert primary.decision.outcome == :admitted
      assert primary.act.class == "mandate.revoke"
      assert primary.act.mandate_ref == c.fixture.mandate.ref
      assert primary.attempt == nil
      assert projection(c).meters == before.meters
      assert Map.has_key?(projection(c).revocations, c.fixture.mandate.ref)
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "revocation fences a previously prepared Skill Candidate before any effect", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert projection(c).acts == before.acts
      assert projection(c).attempts == %{}
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "the agent cannot acquire controller authority by naming its own Mandate", c do
      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Spectre.revoke_mandate(c.scope, c.fixture.mandate.ref,
                 identity_key: "agent-revoke"
               )

      assert projection(c).revocations == %{}
      assert projection(c).acts == before.acts

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      refute_received {:execution, _}
      assert_replay(c)
    end

    @tag executor: :raise
    test "revocation cannot erase an ambiguous execution or release its suspended funds", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

      assert {:ok, %{primary: %{outcome: %{status: :ambiguous}}}} =
               Instance.propose(c.instance, candidate)

      assert_receive {:execution, %{attempt_durable: true}}
      before = projection(c)
      assert map_size(before.duties) == 1
      assert balance(c).suspended == 100

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revoke_mandate(c.admin, c.fixture.mandate.ref,
                 identity_key: "controller-revoke"
               )

      assert projection(c).duties == before.duties
      assert projection(c).outcomes == before.outcomes
      assert projection(c).attempts == before.attempts
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  defp activate_successor(c) do
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(c.admin, c.successor, revision_attrs(c))

    key = {c.definition.namespace, c.definition.name}
    assert projection(c).catalog.definition_heads[key] == c.successor.ref
  end

  describe "an explicitly bounded emergency agent" do
    @describetag emergency_mandate: true,
                 constitution_overrides: %{"emergency_max_duration_ms" => 601_000}

    test "emergency authority is visible in Genesis and still uses ordinary admission", c do
      assert projection(c).catalog.genesis.emergency_mandate_ref == c.fixture.mandate.ref
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.act.mandate_ref == c.fixture.mandate.ref
      assert_success(c, result)
    end

    test "emergency designation does not bypass its payment Evidence Condition", c do
      forged_input = Map.put(input(c, "refund"), :proposition, "payment.unverified")

      assert {:ok, %{candidates: [candidate]}} =
               Instance.turn(c.instance, forged_input, mind_opts: mind_options(c, []))

      before = projection(c)

      assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert projection(c).acts == before.acts
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "emergency designation does not bypass its quantitative ceiling", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", amount: 10_001)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert balance(c).available == 10_000
      assert projection(c).attempts == %{}
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "an expired emergency Mandate cannot dispatch a previously prepared Candidate", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")
      Runtime.set_time(c.fixture.mandate.expires_at)

      assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
               Instance.propose(c.instance, candidate)

      assert projection(c).attempts == %{}
      assert balance(c).available == 10_000
      refute_received {:execution, _}
      assert_replay(c)
    end

    @tag executor: :raise
    test "an ambiguous emergency effect leaves the same durable debt as an ordinary effect", c do
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund")

      assert {:ok, %{primary: %{outcome: %{status: :ambiguous}}}} =
               Instance.propose(c.instance, candidate)

      assert_receive {:execution, %{attempt_durable: true}}
      assert balance(c).suspended == 100
      assert [duty] = Map.values(projection(c).duties)
      assert duty.class == :ambiguous_outcome
      assert duty.status == :open
      assert_replay(c)
    end
  end

  defp revision_attrs(c) do
    [
      identity_key: "activate-successor",
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    ]
  end
end
