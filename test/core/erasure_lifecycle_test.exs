defmodule Spectre.Core.ErasureLifecycleTest.FullReadAdapter do
  defdelegate load(domain, opts), to: Spectre.Ledger.Store.ETS
end

defmodule Spectre.Core.ErasureLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.{Audit, Governance, Ledger, Portable, Row}
  alias Spectre.Domain.{Event, Projection, Recovery, Sequencer}
  alias Spectre.Erasure.Analysis
  alias Spectre.GovernedAct.Transition.Information
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Disk
  alias Spectre.Payload.Retention
  alias Spectre.Payload.Store, as: PayloadStore
  alias Spectre.Test.DutyFrontierAssertions
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Payloads do
    @behaviour Spectre.Payload.Store
    @impl true
    def verify(ref, opts) do
      case File.read(path(opts[:root], ref)) do
        {:ok, value} ->
          if Portable.content_ref!(:payload, value) == ref,
            do: :ok,
            else: {:error, :digest_mismatch}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def path(root, "payload:" <> digest), do: Path.join(root, digest)
  end

  defmodule Executor do
    @behaviour Spectre.Attempt.Executor
    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor
    @impl true
    def execute(act, attempt, _capability, opts) do
      send(opts[:observer], {:delete_requested, act, attempt})
      status = Keyword.get(opts, :status, :succeeded)

      if status != :definitive_no_effect do
        File.rm!(Payloads.path(opts[:root], act.consequence["erasure_request"]["target_ref"]))
      end

      {:ok, receipt} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(),
          payload: "deletion receipt"
        )

      result = %{evidence: [receipt], details_ref: "receipt:deletion"}
      if status == :succeeded, do: {:ok, result}, else: {:error, status, result}
    end
  end

  setup context do
    Runtime.reset(Fixture.default_now())
    namespace = "erasure-lifecycle-#{System.unique_integer([:positive])}"

    root =
      Path.join(
        System.tmp_dir!(),
        namespace <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    personal_data = "private person: synthetic@example.invalid; external-only document"
    payload_ref = Portable.content_ref!(:payload, personal_data)
    File.write!(Payloads.path(root, payload_ref), personal_data)
    {:ok, store} = Disk.start_link(path: Path.join(root, "ledger"), compressed: true)
    row = %Row{attempt: true, write: true, govern: true}

    f =
      Fixture.start_domain(
        namespace: namespace,
        governance_allowed: true,
        governance_classes: ["data.erase"],
        governance_ceiling: row,
        governance_declarations: %{"data.erase" => row},
        governance_targets: [payload_ref],
        governance_executor_refs: [Executor.executor_ref()],
        governance_executor_contract_refs: [Executor.contract_ref()],
        executors: [
          {Executor,
           root: root, observer: self(), status: Map.get(context, :deletion_status, :succeeded)}
        ],
        payload_store: {Payloads, root: root},
        store: {Disk, server: store},
        name: {:via, Registry, {Spectre.Domain.Registry, "v0.4:#{namespace}:domain"}}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, domain} = Spectre.lookup_domain(f.refs.domain)

    {:ok, scope} =
      Spectre.resume_scope(
        domain,
        Fixture.context(f, authenticated_principal_ref: f.refs.grantor)
      )

    {:ok, [evidence]} =
      Spectre.observe(scope, %{
        proposition: "private-document",
        provenance: :observed,
        issuer_ref: f.refs.grantor,
        bindings: %{},
        payload_ref: payload_ref
      })

    %{
      f: f,
      scope: scope,
      evidence: evidence,
      payload_ref: payload_ref,
      root: root,
      personal_data: personal_data
    }
  end

  test "executor-mediated deletion preserves the tombstone and creates verification debt", c do
    before = Sequencer.projection(c.f.server)
    assert {:ok, result} = erase(c)
    assert result.primary.decision.outcome == :admitted, inspect(result)
    assert result.primary.outcome.status == :succeeded, inspect(result)
    assert_receive {:delete_requested, act, attempt}
    assert act == result.primary.act
    assert attempt == result.primary.attempt
    assert {:ok, [erasure]} = Spectre.erasures(c.scope)
    assert erasure.source_act_ref == act.ref
    assert c.evidence.ref in erasure.affected_refs
    assert erasure.reduces_verifiability
    state = Sequencer.projection(c.f.server)
    assert state.evidence[c.evidence.ref] == c.evidence
    refute Map.has_key?(Analysis.available_evidence(state), c.evidence.ref)
    assert Enum.any?(Map.values(state.duties), &(&1.class == :erasure_reduces_verifiability))
    suffix = Fixture.snapshot(c.f).entries |> Enum.drop(before.revision)

    assert Enum.find_index(suffix, &(&1.payload["type"] == "erasure_requested")) <
             Enum.find_index(suffix, &(&1.payload["type"] == "attempt_started"))

    assert_replay(c)
    assert {:error, _} = erase(c, "second")
    refute_received {:delete_requested, _, _}
  end

  test "retention planning crosses the same governed erasure path and preserves causal records",
       c do
    before = Sequencer.projection(c.f.server)
    last_use = %{recorded_at: before.recorded_at, revision: before.revision}
    assert :retain = Retention.request(c.payload_ref, last_use, last_use, after_ms: 1)
    refute_received {:delete_requested, _, _}

    assert {:ok, request} = Retention.request(c.payload_ref, last_use, last_use, after_events: 0)
    assert {:ok, result} = Spectre.request_erasure(c.scope, request, attrs(c, "retention"))
    assert result.primary.decision.outcome === :admitted
    assert result.primary.outcome.status === :succeeded
    assert_receive {:delete_requested, _, _}
    after_state = Sequencer.projection(c.f.server)
    assert after_state.evidence[c.evidence.ref] === c.evidence

    assert Enum.any?(after_state.duties, fn {_, duty} ->
             duty.class === :erasure_reduces_verifiability
           end)

    assert_replay(c)
  end

  test "a delayed erasure receipt materializes the original verification debt without halting",
       c do
    before = Sequencer.projection(c.f.server)

    {:ok, candidate} =
      Governance.request_erasure(c.scope, before, request(c), attrs(c, "delayed"))

    {:ok, %{act: act, grant: grant}} = Sequencer.submit(c.f.server, c.scope.context, candidate)
    {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(c.f.server, grant)
    observed_at = Runtime.now()

    {:ok, result} =
      Executor.execute(act, attempt, nil, c.f.sequencer_opts[:executors] |> hd() |> elem(1))

    [evidence] = result.evidence

    {:ok, [^evidence]} =
      Sequencer.record_executor_evidence(c.f.server, act.ref, attempt.ref, evidence)

    {:ok, outcome} =
      Spectre.Outcome.new(%{
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        status: :succeeded,
        evidence_refs: [evidence.ref],
        observed_at: observed_at,
        details_ref: result.details_ref
      })

    Runtime.set_time(observed_at + 10)
    assert {:ok, ^outcome} = Sequencer.record_outcome(c.f.server, outcome)
    state = Sequencer.projection(c.f.server)

    [duty] =
      state.duties |> Map.values() |> Enum.filter(&(&1.class === :erasure_reduces_verifiability))

    assert duty.opened_at === observed_at
    assert state.event_metadata[outcome.ref].recorded_at === observed_at + 10
    assert state.event_metadata[duty.ref].recorded_at === observed_at + 10
    assert_replay(c)
  end

  test "catch-up checks payloads against the final erasure state, not intermediate prefixes", c do
    snapshot = Fixture.snapshot(c.f)

    evidence_batch =
      Enum.find(snapshot.entries, &(&1.payload["identity"] == c.evidence.ref)).batch_id

    earlier = Enum.take_while(snapshot.entries, &(&1.batch_id != evidence_batch))
    last = List.last(earlier)

    prefix_snapshot = %{
      snapshot
      | entries: earlier,
        revision: last.revision,
        head_digest: last.digest
    }

    assert {:ok, prefix} = Projection.replay(prefix_snapshot, c.f.constitution)
    assert {:ok, result} = erase(c, "catch-up-erasure")
    assert result.primary.outcome.status === :succeeded
    final = Sequencer.projection(c.f.server)
    state = :sys.get_state(c.f.server)

    for store <- [c.f.store_config, {__MODULE__.FullReadAdapter, server: c.f.store}] do
      assert {:ok, ^final} =
               Recovery.resume(store, prefix, [], fn recovered, refs ->
                 assert c.payload_ref in refs
                 assert recovered.head_digest === final.head_digest
                 PayloadStore.verify_references(state.payload_store, recovered, refs)
               end)
    end
  end

  test "building a request derives the closure but does not perform deletion", c do
    before = Sequencer.projection(c.f.server)

    assert {:ok, candidate} =
             Governance.request_erasure(c.scope, before, request(c), attrs(c, "draft"))

    assert candidate.row == %Row{attempt: true, write: true, govern: true}
    assert candidate.consequence["erasure_request"]["affected_refs"] == [c.evidence.ref]
    assert Sequencer.projection(c.f.server) == before
    refute_received {:delete_requested, _, _}

    assert {:error, _} =
             Spectre.request_erasure(
               c.scope,
               request(c),
               Keyword.delete(attrs(c, "missing"), :executor_ref)
             )

    assert {:error, _} =
             Spectre.request_erasure(
               c.scope,
               Map.put(request(c), :target_ref, "evidence:not-payload"),
               attrs(c, "bad")
             )

    assert {:error, _} =
             Spectre.request_erasure(c.scope, Map.put(request(c), :reason, ""), attrs(c, "empty"))
  end

  test "external personal bytes are deleted while the ledger retains only causal records", c do
    path = Payloads.path(c.root, c.payload_ref)
    assert File.read!(path) === c.personal_data
    assert {:ok, result} = erase(c)
    assert result.primary.outcome.status === :succeeded
    refute File.exists?(path)

    snapshot = Fixture.snapshot(c.f)

    canonical =
      Enum.map_join(snapshot.entries, fn entry ->
        {:ok, bytes} = Entry.encode(entry)
        bytes
      end)

    refute String.contains?(canonical, c.personal_data)
    assert String.contains?(canonical, c.payload_ref)
    assert_replay(c)

    # A fresh process recovers from the actual file ledger, not a saved heap.
    Fixture.stop_process(c.f.server)
    restored = Fixture.restart_domain(c.f, generation: Fixture.generation(c.f) + 1)
    on_exit(fn -> Fixture.stop_process(restored.server) end)

    assert {:ok, :erased} =
             Analysis.execution_state(Sequencer.projection(restored.server), c.payload_ref)

    refute File.exists?(path)
  end

  test "shared payload erasure affects every reference and cannot be resurrected by restoring bytes",
       c do
    {:ok, [other]} =
      Spectre.observe(c.scope, %{
        proposition: "second-document-use",
        provenance: :observed,
        issuer_ref: c.f.refs.grantor,
        bindings: %{},
        payload_ref: c.payload_ref
      })

    assert {:ok, result} = erase(c)
    assert result.primary.outcome.status === :succeeded
    assert {:ok, [erasure]} = Spectre.erasures(c.scope)
    assert Enum.sort(erasure.affected_refs) === Enum.sort([c.evidence.ref, other.ref])
    state = Sequencer.projection(c.f.server)
    available = Analysis.available_evidence(state)
    refute Map.has_key?(available, c.evidence.ref)
    refute Map.has_key?(available, other.ref)

    File.write!(Payloads.path(c.root, c.payload_ref), c.personal_data)

    assert {:error, {:payload_redacted, _}} =
             PayloadStore.verify_usable({Payloads, root: c.root}, state, [c.payload_ref])

    assert {:error, _} =
             Spectre.observe(c.scope, %{
               proposition: "restored-copy",
               provenance: :observed,
               issuer_ref: c.f.refs.grantor,
               bindings: %{},
               payload_ref: c.payload_ref
             })

    assert Sequencer.projection(c.f.server) === state
  end

  test "a tombstone does not erase copies held outside the configured executor", c do
    backup = Path.join(c.root, "host-backup")
    File.write!(backup, c.personal_data)
    assert {:ok, result} = erase(c)
    assert result.primary.outcome.status === :succeeded
    refute File.exists?(Payloads.path(c.root, c.payload_ref))
    assert File.read!(backup) === c.personal_data
    # The application must govern deletion of this copy too; the kernel cannot
    # infer storage locations or make a global GDPR-compliance claim.
  end

  @tag deletion_status: :definitive_no_effect
  test "storage rejection leaves bytes live and does not claim erasure or retry the executor",
       c do
    assert {:ok, result} = erase(c)
    assert result.primary.outcome.status === :definitive_no_effect
    assert File.read!(Payloads.path(c.root, c.payload_ref)) === c.personal_data
    state = Sequencer.projection(c.f.server)
    assert {:ok, :live} = Analysis.execution_state(state, c.payload_ref)

    refute Enum.any?(state.duties, fn {_, duty} ->
             duty.class === :erasure_reduces_verifiability
           end)

    assert_receive {:delete_requested, _, _}
    refute_received {:delete_requested, _, _}
    assert_replay(c)
  end

  @tag deletion_status: :ambiguous
  test "lost deletion confirmation remains contained until a late receipt without automatic retry",
       c do
    assert {:ok, result} = erase(c)
    assert result.primary.outcome.status === :ambiguous
    act = result.primary.act
    attempt = result.primary.attempt
    refute File.exists?(Payloads.path(c.root, c.payload_ref))
    state = Sequencer.projection(c.f.server)
    assert {:ok, :possibly_absent} = Analysis.execution_state(state, c.payload_ref)

    assert {:error, {:payload_temporarily_unavailable, _}} =
             PayloadStore.verify_usable({Payloads, root: c.root}, state, [c.payload_ref])

    assert Enum.any?(state.duties, fn {_, duty} -> duty.class === :ambiguous_outcome end)

    refute Enum.any?(state.duties, fn {_, duty} ->
             duty.class === :erasure_reduces_verifiability
           end)

    assert_replay(c)

    Runtime.set_time(Runtime.now() + 10)

    {:ok, receipt} =
      ExecutorAPI.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
        payload: "late deletion confirmation"
      )

    assert {:ok, [^receipt]} =
             Sequencer.record_executor_evidence(c.f.server, act.ref, attempt.ref, receipt)

    {:ok, outcome} =
      Spectre.Outcome.new(%{
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        status: :succeeded,
        evidence_refs: [receipt.ref],
        observed_at: Runtime.now(),
        details_ref: "receipt:late"
      })

    assert {:ok, ^outcome} = Sequencer.record_outcome(c.f.server, outcome)
    final = Sequencer.projection(c.f.server)
    assert {:ok, :erased} = Analysis.execution_state(final, c.payload_ref)
    assert Enum.all?(final.duties, fn {_, duty} -> duty.status === :open end)

    assert Enum.any?(final.duties, fn {_, duty} ->
             duty.class === :erasure_reduces_verifiability
           end)

    assert_receive {:delete_requested, _, _}
    refute_received {:delete_requested, _, _}
    assert_replay(c)
  end

  for {field, value, expected} <- [
        {:class, "refund.issue", :erasure_act_class_mismatch},
        {:row, %Row{govern: true}, :erasure_act_row_mismatch},
        {:consequence, %{}, :erasure_consequence_mismatch},
        {:scope_ref, "other-scope", :erasure_scope_mismatch},
        {:target_refs, [], :erasure_target_not_bound_to_act},
        {:committed_at, 999_999, :erasure_request_from_future}
      ] do
    test "erasure transition rejects a mismatched #{field}", c do
      before = Sequencer.projection(c.f.server)
      {:ok, result} = erase(c)
      act = result.primary.act
      assert act != nil

      entry =
        Enum.find(Fixture.snapshot(c.f).entries, &(&1.payload["type"] == "erasure_requested"))

      {:ok, event} = Event.decode_entry(entry)
      prefix = %{before | acts: %{act.ref => act}}
      assert {:ok, _} = Information.apply(prefix, event, event.revision)

      changed =
        update_in(
          prefix.acts[act.ref],
          &Map.replace!(&1, unquote(field), unquote(Macro.escape(value)))
        )

      assert {:error, reason} = Information.apply(changed, event, event.revision)
      assert elem(reason, 0) == unquote(expected)
    end
  end

  defp erase(c, identity \\ "erase"),
    do: Spectre.request_erasure(c.scope, request(c), attrs(c, identity))

  defp request(c),
    do: %{target_ref: c.payload_ref, reason: "retention expired", requested_at: Runtime.now()}

  defp attrs(c, identity),
    do: [
      identity_key: identity,
      requested_mandate_ref: c.f.governance_mandate.ref,
      accountable_ref: c.f.refs.accountable,
      purpose_ref: c.f.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      executor_ref: Executor.executor_ref(),
      executor_contract_ref: Executor.contract_ref(),
      observation_window_ms: 100
    ]

  defp assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.f.store_config, c.f.refs.domain)
    assert {:ok, rebuilt} = Projection.replay(snapshot, c.f.constitution)
    assert rebuilt == Sequencer.projection(c.f.server)
    assert {:ok, _} = Audit.verify(snapshot, c.f.constitution, Runtime.now())
    DutyFrontierAssertions.assert_prefixes(snapshot, c.f.constitution)
  end
end
