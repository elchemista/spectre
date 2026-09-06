defmodule Spectre.Core.RestrictionLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Ledger, Mandate, Row}
  alias Spectre.Domain.{Event, Projection, Sequencer}
  alias Spectre.GovernedAct.{AuthorityChange, MeterState}
  alias Spectre.GovernedAct.Transition.Authority
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())

    f =
      Fixture.start_domain(
        namespace: "restriction-lifecycle",
        governance_allowed: true,
        governance_classes: ["mandate.restrict"],
        name: {:via, Registry, {Spectre.Domain.Registry, "v0.4:restriction-lifecycle:domain"}}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, domain} = Spectre.lookup_domain(f.refs.domain)

    {:ok, scope} =
      Spectre.resume_scope(
        domain,
        Fixture.context(f, authenticated_principal_ref: f.refs.grantor)
      )

    {:ok, successor} =
      f.mandate
      |> Map.from_struct()
      |> Map.merge(%{ref: nil, revision: 2, expires_at: f.mandate.expires_at - 1})
      |> Mandate.new()

    %{f: f, scope: scope, successor: successor}
  end

  test "restriction cancels pending dispatch and shares rather than duplicates its physical Meter",
       c do
    {act, grant} = pending(c)
    before = Sequencer.projection(c.f.server)
    assert {:ok, result} = restrict(c)
    assert result.primary.decision.outcome == :admitted, inspect(result)
    assert result.primary.attempt == nil
    after_commit = Sequencer.projection(c.f.server)
    ref = after_commit.mandate_successors[c.f.mandate.ref]
    successor = after_commit.mandates[ref]
    assert successor.source_ref == result.primary.act.ref
    assert successor.revision == 2
    assert after_commit.mandates[c.f.mandate.ref] == c.f.mandate
    assert {:ok, owner} = MeterState.owner(after_commit, ref)
    assert owner == c.f.mandate.ref
    refute Map.has_key?(after_commit.meters, ref)
    assert after_commit.meters[owner][c.f.refs.meter].available == 10_000
    assert after_commit.meter_reservations[act.ref] == :released
    assert {:error, _} = Sequencer.consume_grant(c.f.server, grant)
    suffix = Fixture.snapshot(c.f).entries |> Enum.drop(before.revision)

    assert Enum.map(suffix, & &1.payload["type"]) == [
             "decision_recorded",
             "act_committed",
             "mandate_restricted",
             "dispatch_cancelled",
             "meter_released"
           ]

    assert length(Enum.uniq_by(suffix, & &1.batch_id)) == 1
    assert_replay(c)
  end

  test "restriction cannot widen authority or repeatedly replace an inactive predecessor", c do
    {:ok, expanded} =
      c.successor
      |> Map.from_struct()
      |> Map.merge(%{ref: nil, expires_at: c.f.mandate.expires_at + 1})
      |> Mandate.new()

    assert {:ok, rejected} =
             Spectre.restrict_mandate(c.scope, c.f.mandate.ref, expanded, attrs(c, "expanded"))

    assert rejected.primary.decision.outcome == :refused
    assert rejected.primary.act == nil
    assert {:ok, result} = restrict(c)
    assert result.primary.decision.outcome == :admitted
    before = Sequencer.projection(c.f.server)

    assert {:ok, repeated} =
             Spectre.restrict_mandate(c.scope, c.f.mandate.ref, c.successor, attrs(c, "again"))

    assert repeated.primary.decision.outcome == :refused
    assert Sequencer.projection(c.f.server).mandate_successors == before.mandate_successors
    assert_replay(c)
  end

  for {field, value, error} <- [
        {:class, "refund.issue", :mandate_restriction_act_class_mismatch},
        {:row, %Row{}, :mandate_restriction_act_row_mismatch},
        {:reservations, %{"meter" => 1}, :mandate_restriction_act_has_reservations},
        {:executor_ref, "external", :mandate_restriction_act_not_ledger_internal},
        {:target_refs, [], :mandate_restriction_act_target_missing},
        {:consequence, %{}, :mandate_restriction_consequence_mismatch}
      ] do
    test "restriction transition rejects altered #{field} independently of admission", c do
      before = Sequencer.projection(c.f.server)
      {:ok, result} = restrict(c)
      act = result.primary.act
      assert act != nil
      {:ok, event} = Fixture.snapshot(c.f).entries |> List.last() |> Event.decode_entry()
      prefix = %{before | acts: %{act.ref => act}}
      assert {:ok, _} = Authority.apply(prefix, event, event.revision)

      prefix =
        update_in(
          prefix.acts[act.ref],
          &Map.replace!(&1, unquote(field), unquote(Macro.escape(value)))
        )

      assert {:error, reason} = Authority.apply(prefix, event, event.revision)
      assert elem(reason, 0) == unquote(error)
    end
  end

  test "authority-change lookup requires the actual materialized successor, not a forged index",
       c do
    {:ok, result} = restrict(c)
    act = result.primary.act
    state = Sequencer.projection(c.f.server)
    predecessor = c.f.mandate.ref
    successor = state.mandate_successors[predecessor]
    assert {:ok, ^predecessor, true} = AuthorityChange.resolve(state, act, :mandate_restricted)

    assert {:error, {:dispatch_cancellation_restriction_not_recorded, _}} =
             AuthorityChange.resolve(%{state | mandate_successors: %{}}, act, :mandate_restricted)

    assert {:error, {:mandate_not_found, ^successor}} =
             AuthorityChange.resolve(
               %{state | mandates: Map.delete(state.mandates, successor)},
               act,
               :mandate_restricted
             )

    changed = put_in(state.mandates[successor].source_ref, "different-act")

    assert {:error, {:dispatch_cancellation_restriction_mismatch, _}} =
             AuthorityChange.resolve(changed, act, :mandate_restricted)

    assert {:error, {:invalid_mandate, ^successor}} =
             AuthorityChange.resolve(
               %{state | mandates: %{successor => nil}},
               act,
               :mandate_restricted
             )
  end

  defp pending(c) do
    payment = Fixture.paid_evidence(c.f)
    {:ok, _} = Fixture.observe_payment(c.f, payment)

    {:ok, %{act: act, grant: grant}} =
      Sequencer.submit(
        c.f.server,
        Fixture.context(c.f),
        Fixture.refund_candidate(c.f, 100, evidence_refs: [payment.ref])
      )

    {act, grant}
  end

  defp restrict(c),
    do: Spectre.restrict_mandate(c.scope, c.f.mandate.ref, c.successor, attrs(c, "restrict"))

  defp attrs(c, identity),
    do: [
      identity_key: identity,
      requested_mandate_ref: c.f.governance_mandate.ref,
      accountable_ref: c.f.refs.accountable,
      purpose_ref: c.f.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    ]

  defp assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.f.store_config, c.f.refs.domain)
    assert {:ok, rebuilt} = Projection.replay(snapshot, c.f.constitution)
    assert rebuilt == Sequencer.projection(c.f.server)
    assert {:ok, _} = Audit.verify(snapshot, c.f.constitution, Runtime.now())
  end
end
