defmodule Spectre.Core.AgentsDutyTest do
  use Spectre.Test.FullAgentCase, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Duty.EvidenceCause
  alias Spectre.Instance
  alias Spectre.V04Test.{Executor, Fixture, Ingress}

  describe "application Duty markers from complete agent turns" do
    @describetag duty_rules: %{
                   "app.missing_receipt" => %{
                     "cause_source_refs" => [Ingress.ref()],
                     "disposition_authority_refs" => [Executor.executor_ref()],
                     "containment" => %{"retry" => :forbidden}
                   }
                 }

    test "a configured observation opens a visible Duty without granting an Act", c do
      before = projection(c)
      assert {:ok, %{candidates: [], evidence: [evidence]}} = marker_turn(c)
      assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
      assert duty.class == "app.missing_receipt"
      assert duty.accountable == c.fixture.refs.accountable
      assert duty.mandate_ref == c.fixture.mandate.ref
      assert duty.evidence_refs == [evidence.ref]
      assert duty.disposition_authority_refs == [Executor.executor_ref()]
      assert duty.containment == %{"retry" => :forbidden}
      assert projection(c).acts == before.acts
      assert projection(c).meters == before.meters
      assert Instance.state(c.instance) == %{value: 1, revision: 1}
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "replaying the same application marker does not manufacture another obligation", c do
      assert {:ok, _} = marker_turn(c)
      before = projection(c)
      assert {:ok, _} = marker_turn(c)
      assert projection(c) == before
      assert map_size(before.duties) == 1
      assert Instance.state(c.instance) == %{value: 2, revision: 2}
      assert_replay(c)
    end

    test "the agent cannot give itself disposition authority inside a marker payload", c do
      input = marker_input(c)
      forged = put_in(input, [:payload, "disposition_authority_refs"], [c.fixture.refs.proposer])
      before = projection(c)
      assert {:error, _} = Instance.turn(c.instance, forged, mind_opts: mind_options(c, []))
      assert projection(c) == before
      assert Instance.state(c.instance) == %{value: 0, revision: 0}
      refute_received {:deliberation, _, _, _}
      assert_replay(c)
    end

    test "authorization of one application Duty class does not permit another", c do
      before = projection(c)
      input = put_in(marker_input(c), [:payload, "class"], "app.unconfigured")
      assert {:error, _} = Instance.turn(c.instance, input, mind_opts: mind_options(c, []))
      assert projection(c) == before
      assert Instance.state(c.instance) == %{value: 0, revision: 0}
      assert_replay(c)
    end

    test "stopping the agent cannot erase an application Duty", c do
      assert {:ok, _} = marker_turn(c)
      before = projection(c)
      GenServer.stop(c.instance, :normal)
      assert projection(c) == before
      assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
      assert duty.class == "app.missing_receipt"
      assert_replay(c)
    end

    test "recovery preserves a no-Act Duty linked to a causal Mandate", c do
      assert {:ok, _} = marker_turn(c)
      before = projection(c)
      assert [duty] = Map.values(before.duties)
      assert duty.act_ref == nil
      assert c.fixture.mandate.ref in duty.conflict_refs
      GenServer.stop(c.fixture.server)
      recovered = Fixture.restart_domain(c.fixture, generation: 8)
      on_exit(fn -> Fixture.stop_process(recovered.server) end)
      assert Sequencer.projection(recovered.server) == before
      assert_replay(%{c | fixture: recovered})
    end

    test "an application marker need not invent a causal Mandate", c do
      input = put_in(marker_input(c), [:payload, "mandate_ref"], nil)
      assert {:ok, _} = Instance.turn(c.instance, input, mind_opts: mind_options(c, []))
      assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
      assert duty.mandate_ref == nil
      assert duty.act_ref == nil
      assert duty.conflict_refs == [c.fixture.refs.accountable]
      assert_replay(c)
    end
  end

  defp marker_turn(c),
    do: Instance.turn(c.instance, marker_input(c), mind_opts: mind_options(c, []))

  defp marker_input(c) do
    {:ok, cause} =
      EvidenceCause.new(%{
        class: "app.missing_receipt",
        accountable_ref: c.fixture.refs.accountable,
        mandate_ref: c.fixture.mandate.ref,
        missing: [%{"receipt" => "not received"}]
      })

    Map.merge(input(c, "idle"), %{
      proposition: EvidenceCause.proposition(),
      payload: EvidenceCause.canonical(cause)
    })
  end
end
