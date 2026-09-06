defmodule Spectre.Core.ErasureLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Governance, Ledger, Portable, Row}
  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.Domain.{Event, Projection, Sequencer}
  alias Spectre.Erasure.Analysis
  alias Spectre.GovernedAct.Transition.Information
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Payloads do
    @behaviour Spectre.Payload.Store
    @impl true
    def verify(ref, opts) do
      case :ets.lookup(opts[:table], ref) do
        [{^ref, value}] ->
          if Portable.content_ref!(:payload, value) == ref,
            do: :ok,
            else: {:error, :digest_mismatch}

        [] ->
          {:error, :not_found}
      end
    end
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
      :ets.delete(opts[:table], act.consequence["erasure_request"]["target_ref"])

      {:ok, receipt} =
        ExecutorAPI.outcome_evidence(act, attempt, :succeeded, Runtime.now(), payload: "deleted")

      {:ok, %{evidence: [receipt], details_ref: "receipt:deleted"}}
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "erasure-lifecycle-#{System.unique_integer([:positive])}"
    payload_ref = Portable.content_ref!(:payload, "private bytes stored by host")
    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, {payload_ref, "private bytes stored by host"})
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
        executors: [{Executor, table: table, observer: self()}],
        payload_store: {Payloads, table: table},
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

    %{f: f, scope: scope, evidence: evidence, payload_ref: payload_ref}
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
  end
end
