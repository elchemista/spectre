Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.RecoveryPolicyTest.HostPolicy do
  @behaviour Spectre.GAM.Domain.Recovery.Policy

  @impl true
  def check(context, opts) do
    send(Keyword.fetch!(opts, :owner), {:recovery_check, context, self()})
    Keyword.fetch!(opts, :check).(context)
  end

  @impl true
  def failed(incident, opts) do
    send(Keyword.fetch!(opts, :owner), {:recovery_failed, incident})
    Keyword.get(opts, :failed, fn -> :ok end).()
  end

  @impl true
  def recover(_incident, opts), do: Keyword.fetch!(opts, :recover).()
end

defmodule Spectre.GAM.Core.RecoveryPolicyTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.Core.RecoveryPolicyTest.HostPolicy
  alias Spectre.GAM.Domain.{Bootstrap, Configuration, Event, Recovery, Sequencer, Startup}
  alias Spectre.GAM.Domain.Recovery.Policy
  alias Spectre.GAM.{Evidence, Ledger}
  alias Spectre.GAM.Ledger.Entry
  alias Spectre.GAM.Ledger.Store.Mock
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(projection_store: nil, mock_store: true)
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    assert {:ok, ^payment} = Fixture.observe_payment(f, payment)
    snapshot = Fixture.snapshot(f)
    %{f: f, snapshot: snapshot, head: Map.take(snapshot, [:revision, :head_digest])}
  end

  test "only explicit supported recovery decisions can request a lifecycle change" do
    incident = %{
      domain_ref: "policy-boundary",
      phase: :runtime,
      reason: :offline,
      last_verified: nil
    }

    assert :wait = Policy.recover(nil, incident, 100)

    for decision <- [:wait, :memory, {:retry, 0}, {:retry, 86_400_000}] do
      assert Policy.recover({HostPolicy, recover: fn -> decision end}, incident, 100) == decision
    end

    for invalid <- [:ok, {:ok, :memory}, {:retry, -1}, {:retry, 86_400_001}, {:retry, 1.0}] do
      assert :wait = Policy.recover({HostPolicy, recover: fn -> invalid end}, incident, 100)
    end

    assert :wait = Policy.recover({HostPolicy, recover: fn -> raise "offline" end}, incident, 100)
  end

  test "a recovery callback timeout terminates the callback and cannot select RAM" do
    owner = self()

    callback = fn ->
      send(owner, {:policy_worker, self()})

      receive do
        :never -> :memory
      end
    end

    assert :wait = Policy.recover({HostPolicy, recover: callback}, %{}, 5)
    assert_receive {:policy_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "corrupt recovered bytes cannot be accepted by an incident handler", c do
    Fixture.stop_process(c.f.server)
    [first | rest] = c.snapshot.entries
    corrupt = %{c.snapshot | entries: [%{first | payload: %{"tampered" => true}} | rest]}

    for reply <- [:ok, {:ok, :replacement_projection}, :retry] do
      config =
        config(c, fn _ -> flunk("check must follow core verification") end,
          failed: fn -> reply end
        )

      assert :ok = Mock.push(c.f.mock, {:load, :before, {:ok, corrupt}})
      assert {:error, reason} = Startup.load(config)
      assert_receive {:recovery_failed, %{phase: :startup, reason: ^reason, last_verified: nil}}
      refute_receive {:recovery_check, _, _}, 0
      assert Fixture.snapshot(c.f) === c.snapshot
    end
  end

  test "valid hashes cannot make a semantically incomplete admission recoverable", c do
    assert {:ok, %{grant: grant}} =
             Sequencer.submit(c.f.server, Fixture.context(c.f), Fixture.refund_candidate(c.f, 10))

    refute is_nil(grant)
    snapshot = Fixture.snapshot(c.f)
    Fixture.stop_process(c.f.server)
    batch = Enum.drop(snapshot.entries, c.snapshot.revision)
    assert List.last(batch).payload["type"] === "dispatch_ready"
    forged = replace_tail(c.snapshot, Enum.map(Enum.drop(batch, -1), & &1.payload), hd(batch))
    assert {:ok, _} = Ledger.verify_snapshot(forged)
    assert :ok = Mock.push(c.f.mock, {:load, :before, {:ok, forged}})

    assert {:error, _} = Startup.load(config(c, fn _ -> :ok end))
    assert_receive {:recovery_failed, %{phase: :startup}}
    refute_receive {:recovery_check, _, _}, 0
    assert Fixture.snapshot(c.f) === snapshot
  end

  test "a coherent rollback needs an external witness, not just chain verification", c do
    unrelated = Fixture.paid_evidence(c.f, %{proposition: "unrelated"})
    assert {:ok, ^unrelated} = Fixture.observe_payment(c.f, unrelated)
    full = Fixture.snapshot(c.f)
    Fixture.stop_process(c.f.server)
    assert {:ok, plain} = Configuration.new(c.f.sequencer_opts)

    # A complete older prefix is internally valid. The core cannot invent the
    # missing knowledge that a later head was durably witnessed elsewhere.
    assert :ok = Mock.push(c.f.mock, {:load, :before, {:ok, c.snapshot}})
    assert {:ok, old} = Startup.load(plain)
    assert old.revision === c.snapshot.revision

    expected = Map.take(full, [:revision, :head_digest])
    anchored = config(c, &expect_head(&1, expected))
    assert :ok = Mock.push(c.f.mock, {:load, :before, {:ok, c.snapshot}})
    assert {:error, {:recovery_policy_rejected, :witness_mismatch}} = Startup.load(anchored)
    assert_receive {:recovery_failed, %{phase: :startup}}
    assert {:ok, recovered} = Startup.load(anchored)
    assert recovered.head_digest === full.head_digest
  end

  test "a fully rehashed valid rewrite is rejected by an independently pinned head", c do
    unrelated = Fixture.paid_evidence(c.f, %{proposition: "external.note", payload: "original"})
    assert {:ok, ^unrelated} = Fixture.observe_payment(c.f, unrelated)
    full = Fixture.snapshot(c.f)
    Fixture.stop_process(c.f.server)

    assert {:ok, changed} =
             unrelated
             |> Map.from_struct()
             |> Map.delete(:ref)
             |> Map.put(:payload, "rewritten")
             |> Evidence.new()

    assert {:ok, event} = Event.record(:evidence, changed)
    forged = replace_tail(c.snapshot, [event], List.last(full.entries))
    assert forged.revision === full.revision
    refute forged.head_digest === full.head_digest
    assert {:ok, _} = Ledger.verify_snapshot(forged)
    assert :ok = Mock.push(c.f.mock, {:load, :before, {:ok, forged}})
    assert {:ok, _} = Recovery.recover(c.f.store_config, c.f.refs.domain, c.f.constitution, [])

    expected = Map.take(full, [:revision, :head_digest])
    assert :ok = Mock.push(c.f.mock, {:load, :before, {:ok, forged}})

    assert {:error, {:recovery_policy_rejected, :witness_mismatch}} =
             Startup.load(config(c, &expect_head(&1, expected)))
  end

  test "an expected Domain cannot silently bootstrap when the store reports it missing", c do
    Fixture.stop_process(c.f.server)
    assert :ok = Mock.push(c.f.mock, {:load, :before, :not_found})

    assert {:error, {:recovery_policy_rejected, :witness_mismatch}} =
             Startup.load(config(c, &expect_head(&1, c.head)))

    assert_receive {:recovery_check, %{head: nil}, _}
    assert Fixture.snapshot(c.f) === c.snapshot
  end

  test "public startup stays unavailable until repaired data passes the same checks", c do
    Fixture.stop_process(c.f.server)
    config = config(c, &expect_head(&1, c.head))

    opts =
      c.f.sequencer_opts
      |> Keyword.drop([:domain_ref, :store])
      |> Keyword.put(:recovery_policy, config.recovery_policy)

    assert :ok = Mock.push(c.f.mock, {:load, :before, {:error, :damaged_storage}})
    assert {:error, _} = Spectre.GAM.start_domain(c.f.refs.domain, c.f.store_config, opts)
    assert Spectre.GAM.Domain.whereis(c.f.refs.domain) === nil
    assert_receive {:recovery_failed, %{reason: :damaged_storage}}

    # The host restores a valid source (the real store here); no repair return
    # value or cached projection is used to bypass the second recovery.
    assert {:ok, domain} = Spectre.GAM.start_domain(c.f.refs.domain, c.f.store_config, opts)
    pid = Spectre.GAM.Domain.whereis(c.f.refs.domain)
    on_exit(fn -> DynamicSupervisor.terminate_child(Spectre.GAM.Domain.Supervisor, pid) end)
    assert {:ok, recovered} = Sequencer.head(domain.server)
    assert Map.take(recovered, [:revision, :head_digest]) === c.head
  end

  @tag capture_log: true
  test "runtime ambiguity notifies the host once and stops without returning a Grant", c do
    context = Fixture.context(c.f)
    state = :sys.get_state(c.f.server)
    policy = {HostPolicy, owner: self(), check: fn _ -> :ok end, failed: fn -> :ok end}
    :sys.replace_state(c.f.server, &%{&1 | recovery_policy: policy})
    Process.unlink(c.f.server)
    monitor = Process.monitor(c.f.server)

    assert :ok =
             Mock.push(c.f.mock, List.duplicate({:append, :before, {:error, :ambiguous}}, 3))

    assert {:error, :ambiguous_commit_unresolved} =
             Sequencer.submit(c.f.server, context, Fixture.refund_candidate(c.f, 10))

    expected = Map.take(state.projection, [:revision, :head_digest])

    assert_receive {:recovery_failed,
                    %{
                      phase: :runtime,
                      reason: :ambiguous_commit_unresolved,
                      last_verified: ^expected
                    }}

    assert_receive {:DOWN, ^monitor, :process, _, _}
    refute_receive {:recovery_failed, _}, 0
    assert Fixture.snapshot(c.f) === c.snapshot
  end

  test "policy exceptions, invalid results and timeouts fail closed in isolated workers", c do
    for callback <- [
          fn _ -> raise "do not leak credentials" end,
          fn _ -> exit(:shutdown) end,
          fn _ -> {:ok, :unverified_state} end,
          fn _ ->
            receive do
              :never -> :ok
            end
          end
        ] do
      policy = {HostPolicy, owner: self(), check: callback}
      assert {:error, _} = Policy.check(policy, c.f.refs.domain, c.head, 20)
      assert_receive {:recovery_check, _, worker}
      refute worker === self()
      refute Process.alive?(worker)
      refute_receive {:DOWN, _, _, _, _}, 0
    end
  end

  @tag capture_log: true
  test "a blocked runtime incident callback cannot delay the failure reply or Domain termination",
       c do
    context = Fixture.context(c.f)
    owner = self()

    callback = fn ->
      send(owner, {:incident_worker, self()})

      receive do
        :release -> :ok
      end
    end

    policy = {HostPolicy, owner: owner, check: fn _ -> :ok end, failed: callback}
    :sys.replace_state(c.f.server, &%{&1 | recovery_policy: policy, recovery_timeout: 5_000})
    Process.unlink(c.f.server)
    monitor = Process.monitor(c.f.server)
    assert :ok = Mock.push(c.f.mock, List.duplicate({:append, :before, {:error, :ambiguous}}, 3))

    task =
      Task.async(fn ->
        Sequencer.submit(c.f.server, context, Fixture.refund_candidate(c.f, 10))
      end)

    assert_receive {:incident_worker, worker}, 1_000

    try do
      assert {:ok, {:error, :ambiguous_commit_unresolved}} = Task.yield(task, 1_000)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      assert Process.alive?(worker)
      assert Fixture.snapshot(c.f) === c.snapshot
    after
      send(worker, :release)
    end
  end

  test "detached incident workers still have a bounded lifetime", c do
    owner = self()

    callback = fn ->
      send(owner, {:incident_worker, self()})

      receive do
        :never -> :ok
      end
    end

    policy = {HostPolicy, owner: owner, failed: callback}

    incident = %{
      domain_ref: c.f.refs.domain,
      phase: :runtime,
      reason: :broken,
      last_verified: c.head
    }

    assert :ok = Policy.notify_failed(policy, incident, 100)
    assert_receive {:incident_worker, worker}, 1_000
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    refute Process.alive?(worker)
  end

  test "broken incident handlers cannot replace the original startup error", c do
    Fixture.stop_process(c.f.server)

    for callback <- [
          fn -> raise "broken" end,
          fn ->
            receive do
              :never -> :ok
            end
          end
        ] do
      config = %{config(c, fn _ -> :ok end, failed: callback) | recovery_timeout: 20}
      assert :ok = Mock.push(c.f.mock, {:load, :before, {:error, :original_error}})
      assert {:error, :original_error} = Startup.load(config)
      assert_receive {:recovery_failed, %{reason: :original_error}}
    end
  end

  test "invalid adapter wiring is rejected before recovery", c do
    for policy <- [false, {}, {HostPolicy, [:invalid]}, {String, []}] do
      assert {:error, _} =
               Configuration.new(Keyword.put(c.f.sequencer_opts, :recovery_policy, policy))
    end

    for timeout <- [0, -1, 1.0, :infinity] do
      assert {:error, _} =
               Configuration.new(Keyword.put(c.f.sequencer_opts, :recovery_timeout, timeout))
    end
  end

  test "incremental verification cannot substitute the verified Domain foundation", c do
    prefix = Sequencer.projection(c.f.server)
    assert {:ok, config} = Configuration.new(c.f.sequencer_opts)
    opts = Configuration.verification_opts(config)
    assert :ok = Bootstrap.verify_extension(prefix, prefix, opts)

    for changed <- [
          %{prefix | domain_ref: "different-domain"},
          %{prefix | constitution: %{}},
          put_in(prefix.catalog.genesis.ref, "different-genesis")
        ] do
      assert {:error, :verified_domain_foundation_changed} =
               Bootstrap.verify_extension(prefix, changed, opts)
    end

    rejected = [genesis_verifier: {Spectre.GAM.Genesis.Verifier.Allowlist, attestation_refs: []}]
    assert {:error, reason} = Bootstrap.verify_projection(prefix, rejected)
    assert {:error, ^reason} = Bootstrap.verify_extension(prefix, prefix, rejected)
  end

  defp config(c, check, opts \\ []) do
    policy = {HostPolicy, Keyword.merge([owner: self(), check: check], opts)}

    assert {:ok, config} =
             Configuration.new(Keyword.put(c.f.sequencer_opts, :recovery_policy, policy))

    config
  end

  defp expect_head(%{head: actual}, expected) do
    if actual === expected, do: :ok, else: {:error, :witness_mismatch}
  end

  defp replace_tail(prefix, payloads, original) do
    assert {:ok, entries} =
             Entry.build_batch(
               prefix.domain_ref,
               original.batch_id,
               payloads,
               prefix.revision,
               original.recorded_at,
               prefix.head_digest
             )

    %{
      prefix
      | entries: prefix.entries ++ entries,
        revision: List.last(entries).revision,
        head_digest: List.last(entries).digest
    }
  end
end
