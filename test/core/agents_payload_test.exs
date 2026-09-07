defmodule Spectre.Core.AgentsPayloadTest do
  use Spectre.Test.FullAgentCase, async: false

  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Erasure.Analysis
  alias Spectre.{Instance, Ledger, Portable}
  alias Spectre.V04Test.{Fixture, Runtime}

  describe "agents using host-managed external payloads" do
    @describetag external_payloads: true

    test "erasure closure preserves the dependency of a refused Decision without an Act", c do
      independent_decisions = Map.keys(projection(c).decisions)
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [evidence]} = Spectre.observe(c.scope, input)
      Runtime.set_time(Runtime.now() + 1)

      assert {:ok, %{candidates: [candidate]}} =
               turn(c, "refund", context: [evidence.ref], amount: 10_001)

      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert result.primary.decision.outcome == :refused
      assert result.primary.act == nil
      assert evidence.ref in result.primary.decision.recognition_evidence_refs
      assert {:ok, affected} = Analysis.affected_refs(projection(c), ref)
      assert result.primary.decision.ref in affected
      refute Enum.any?(independent_decisions, &(&1 in affected))
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "a Skill-backed agent executes with a verified external receipt in its basis", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [evidence]} = Spectre.observe(c.scope, input)
      Runtime.set_time(Runtime.now() + 1)
      assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", context: [evidence.ref])
      assert evidence.ref in candidate.evidence_refs
      assert {:ok, result} = Instance.propose(c.instance, candidate)
      assert_success(c, result)
    end

    test "missing external input is rejected before deliberation or local state changes", c do
      {ref, input} = external_input(c)
      before = projection(c)

      assert {:error, {:payload_not_found, ^ref}} =
               Instance.turn(c.instance, input, mind_opts: mind_options(c, []))

      assert projection(c) == before
      assert Instance.state(c.instance) == %{value: 0, revision: 0}
      refute_received {:deliberation, _, _, _}
      refute_received {:execution, _}
      assert_replay(c)
    end

    test "wrong bytes under the claimed digest cannot enter an agent's context", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "forged receipt"})
      before = projection(c)

      assert {:error, {:payload_verification_failed, ^ref, :digest_mismatch}} =
               Spectre.observe(c.scope, input)

      assert projection(c) == before
      assert_replay(c)
    end

    for change <- [:delete, :corrupt] do
      test "#{change} after deliberation prevents capability release", c do
        {ref, input} = external_input(c)
        :ets.insert(c.payload_table, {ref, "external receipt"})
        assert {:ok, [evidence]} = Spectre.observe(c.scope, input)
        Runtime.set_time(Runtime.now() + 1)
        assert {:ok, %{candidates: [candidate]}} = turn(c, "refund", context: [evidence.ref])

        before = projection(c)
        assert Instance.state(c.instance) == %{value: 1, revision: 1}
        Process.unlink(c.fixture.server)
        domain_monitor = Process.monitor(c.fixture.server)

        case unquote(change) do
          :delete -> :ets.delete(c.payload_table, ref)
          :corrupt -> :ets.insert(c.payload_table, {ref, "substituted receipt"})
        end

        assert {:error, _reason} = Instance.propose(c.instance, candidate)

        assert_receive {:DOWN, ^domain_monitor, :process, _,
                        {:shutdown, {:sequencer_halted, _reason}}}

        assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
        assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
        assert replayed.evidence == before.evidence
        assert map_size(replayed.acts) == map_size(before.acts) + 1
        [admitted] = Enum.reject(Map.values(replayed.acts), &Map.has_key?(before.acts, &1.ref))
        assert admitted.candidate_identity_key == candidate.identity_key
        assert admitted.material_digest == candidate.material_digest
        assert MapSet.member?(replayed.pending_dispatches, admitted.ref)
        account = replayed.meters[c.fixture.mandate.ref][c.fixture.refs.meter]
        assert account.reserved == 100
        assert account.spent == 0
        assert replayed.attempts == %{}
        refute_received {:execution, _}

        # Repair belongs to the host. Restoring the exact bytes permits verified
        # recovery; the old agent must not silently adopt the new generation.
        :ets.insert(c.payload_table, {ref, "external receipt"})
        recovered = Fixture.restart_domain(c.fixture, generation: 8)
        on_exit(fn -> Fixture.stop_process(recovered.server) end)
        assert Sequencer.projection(recovered.server) == replayed
        assert_replay(%{c | fixture: recovered})
      end
    end

    test "restart revalidates live content without duplicating evidence or admissions", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [_evidence]} = Spectre.observe(c.scope, input)
      before = projection(c)
      GenServer.stop(c.fixture.server)
      recovered = Fixture.restart_domain(c.fixture, generation: 8)
      on_exit(fn -> Fixture.stop_process(recovered.server) end)
      assert Sequencer.projection(recovered.server) == before
      assert_replay(%{c | fixture: recovered})
    end

    test "recovery refuses an unexplained loss of a live receipt", c do
      {ref, input} = external_input(c)
      :ets.insert(c.payload_table, {ref, "external receipt"})
      assert {:ok, [_evidence]} = Spectre.observe(c.scope, input)
      GenServer.stop(c.fixture.server)
      :ets.delete(c.payload_table, ref)
      # start/1 keeps this deliberately failed recovery from killing the caller.
      assert {:error, {:unexpected_missing_payload, ^ref}} =
               GenServer.start(Sequencer, Keyword.put(c.fixture.sequencer_opts, :generation, 8))
    end
  end

  test "an agent without a configured payload adapter cannot introduce external references", c do
    {ref, input} = external_input(c)
    before = projection(c)
    assert {:error, {:payload_store_required, ^ref}} = Spectre.observe(c.scope, input)
    assert projection(c) == before
    assert_replay(c)
  end

  defp external_input(c) do
    ref = Portable.content_ref!(:payload, "external receipt")
    {ref, Map.merge(input(c, "idle"), %{payload: nil, payload_ref: ref})}
  end
end
