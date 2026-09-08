defmodule Spectre.Core.BatchCausalityBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Duty, Evidence}
  alias Spectre.Attempt.Reconciler
  alias Spectre.Domain.{Event, Reconciliation}
  alias Spectre.GovernedAct.{Fold, Materialization}
  alias Spectre.GovernedAct.Batch.{Dispatch, Events, World}
  alias Spectre.GovernedAct.Materialization.Authority, as: AuthorityMaterialization
  alias Spectre.V04Test.{Fixture, Runtime}

  test "expiry cancellation and release are one exact ordered transaction", c do
    time = c.f.mandate.expires_at
    assert {:ok, plan} = Reconciler.repair_plan(c.pending, time)
    events = decode(plan.payloads, time)
    assert Enum.map(events, & &1.type) == ["dispatch_cancelled", "meter_released"]
    assert :ok = Dispatch.validate_expirations(c.pending, events)
    assert :ok = Dispatch.validate_expirations(c.pending, [])
    assert {:ok, _} = Fold.prepare_batch(c.pending, plan.payloads, time)

    for malformed <- [
          Enum.reverse(events),
          Enum.take(events, 1),
          Enum.drop(events, 1),
          Enum.map(events, &%{&1 | recorded_at: time - 1}),
          List.update_at(events, 1, &%{&1 | recorded_at: time + 1}),
          List.update_at(
            events,
            1,
            &%{&1 | data: Map.put(&1.data, "amounts", %{c.f.refs.meter => 99})}
          )
        ] do
      assert {:error, :dispatch_expiration_batch_mismatch} =
               Dispatch.validate_expirations(c.pending, malformed)
    end
  end

  test "missing pending Act or Mandate does not disappear from expiry repair", c do
    ref = c.act.ref
    state = c.pending
    unindexed = put_in(state.read_index.dispatch_deadlines, :gb_trees.empty())

    assert Reconciliation.next_deadline(unindexed, state.recorded_at) == c.f.mandate.expires_at

    assert Reconciliation.next_deadline(unindexed, c.f.mandate.expires_at + 1) ==
             c.f.mandate.expires_at + 1

    assert Reconciliation.next_deadline(%{unindexed | acts: %{}}, state.recorded_at) ==
             state.recorded_at

    assert {:error, {:pending_dispatch_act_not_found, ^ref}} =
             Reconciler.repair_plan(%{unindexed | acts: %{}}, c.f.mandate.expires_at)

    assert {:error, {:invalid_reconciliation_time, 1.0}} = Reconciler.repair_plan(state, 1.0)
    assert {:error, :invalid_reconciliation_projection} = Reconciler.repair_plan(%{}, 100)
  end

  test "readiness cannot be smuggled into a batch without its admission", c do
    [ready] = decode([Event.dispatch_ready(c.act)], Runtime.now())
    ref = c.act.ref

    assert {:error, {:dispatch_outside_admission_batch, ^ref}} =
             Dispatch.validate_ready([ready], ready)

    {:ok, payload} = Event.record(:act, c.act)
    [act, ready] = decode([payload, Event.dispatch_ready(c.act)], Runtime.now())
    assert :ok = Dispatch.validate_ready([act, ready], ready)
  end

  test "a single batch cannot invent the already-durable world boundary", c do
    {:ok, attempt_payload} = Event.record(:attempt, c.attempt)
    outcome = Fixture.outcome(c.f, c.act, c.attempt, :ambiguous)
    {:ok, outcome_payload} = Event.record(:outcome, outcome)
    [attempt, outcome_event] = decode([attempt_payload, outcome_payload], Runtime.now())

    assert :ok = World.validate(c.pending, [attempt])

    assert {:error, {:attempt_without_prior_durable_dispatch, _, _}} =
             World.validate(c.before, [attempt])

    assert {:error, {:outcome_without_prior_durable_attempt, _, _}} =
             World.validate(c.pending, [attempt, outcome_event])

    state = c.attempted
    assert :ok = World.validate(state, [outcome_event])

    assert {:error, {:outcome_prior_attempt_mismatch, _, _}} =
             World.validate(put_in(state.attempts[c.attempt.ref].act_ref, "foreign"), [
               outcome_event
             ])
  end

  test "a newly contested input cancels only a never-started dispatch and releases its reservation",
       c do
    {:ok, contrary} =
      Evidence.new(%{c.payment | ref: nil, stance: :contradicts, payload: "payment reversed"})

    {:ok, payload} = Event.record(:evidence, contrary)
    assert {:ok, disputed} = Fold.prepare_batch(c.pending, [payload], Runtime.now())
    assert {:ok, plan} = Reconciler.repair_plan(disputed, Runtime.now())
    events = decode(plan.payloads, Runtime.now())
    [opening, cancellation, release] = events

    assert [opening.type, cancellation.type, release.type] == [
             "duty_opened",
             "dispatch_cancelled",
             "meter_released"
           ]

    assert :ok = Dispatch.validate_disputed_duty(disputed, disputed, events, opening)
    assert :ok = Dispatch.validate_cancellation(events, cancellation)
    assert {:ok, repaired} = Fold.prepare_batch(disputed, plan.payloads, Runtime.now())
    assert repaired.meter_reservations[c.act.ref] == :released

    duty_ref = opening.identity

    assert {:error, {:disputed_dispatch_cancellation_batch_mismatch, ^duty_ref}} =
             Dispatch.validate_disputed_duty(disputed, disputed, [opening], opening)

    assert {:error, {:dispatch_cancellation_outside_duty_batch, _}} =
             Dispatch.validate_cancellation([cancellation], %{cancellation | batch_index: 0})

    for {field, value} <- [{"act_ref", "other"}, {"mandate_ref", "other"}] do
      changed = %{cancellation | data: Map.put(cancellation.data, field, value)}

      assert {:error, {:invalid_disputed_dispatch_cancellation, _}} =
               Dispatch.validate_cancellation([opening, changed, release], changed)
    end

    for {projection, reason} <- [
          {%{disputed | acts: %{}}, {:act_not_found, c.act.ref}},
          {%{disputed | acts: %{c.act.ref => nil}}, {:invalid_act, c.act.ref}}
        ] do
      assert {:error, ^reason} =
               Dispatch.validate_disputed_duty(disputed, projection, events, opening)
    end

    assert {:ok, duty} = Duty.from_canonical(opening.data)
    assert {:ok, [_, _]} = Materialization.Dispatch.cancellation(c.act, duty, :disputed_evidence)
  end

  test "cancellations need the corresponding governance cause, not an arbitrary Act", c do
    {:ok, plan} = Reconciler.repair_plan(c.pending, c.f.mandate.expires_at)
    [expired | _] = decode(plan.payloads, c.f.mandate.expires_at)
    assert :ok = Dispatch.validate_cancellation([expired], expired)

    for reason <- [:mandate_revoked, :mandate_restricted] do
      event = %{
        expired
        | data: Map.merge(expired.data, %{"reason" => reason, "cause_ref" => c.act.ref})
      }

      assert {:error, {:dispatch_cancellation_outside_governance_batch, _}} =
               Dispatch.validate_cancellation([event], event)

      assert {:error, {:invalid_dispatch_cancellation_cause, _}} =
               Dispatch.validate_authority_change(c.pending, c.pending, [event], c.act, 0)
    end

    invalid = %{expired | data: Map.put(expired.data, "reason", :operator_guess)}

    assert {:error, {:invalid_dispatch_cancellation_reason, _, :operator_guess}} =
             Dispatch.validate_cancellation([invalid], invalid)
  end

  test "authority cancellation planning fails closed on corrupt or unrelated state", c do
    # Batch validation reuses this pure planner. It must not silently discard a
    # malformed pending record or accept a world Act as an authority cause.
    assert {:error, :invalid_pending_dispatch_act} =
             AuthorityMaterialization.cancellation_events(
               [nil],
               c.act,
               :mandate_revoked
             )

    assert {:error, :dispatch_cancellation_cause_not_ledger_internal} =
             AuthorityMaterialization.cancellation_events(
               [c.act],
               c.act,
               :mandate_revoked
             )

    # A non-cascading change to another Mandate leaves this pending Act alone.
    assert {:ok, []} =
             AuthorityMaterialization.cancellation_events(
               c.pending,
               c.act,
               "mandate:unrelated",
               :mandate_revoked
             )

    corrupt_mandate = %{c.f.mandate | parent_ref: ""}

    corrupt = %{
      c.pending
      | mandates: Map.put(c.pending.mandates, c.f.mandate.ref, corrupt_mandate)
    }

    assert {:error, {:invalid_mandate_parent_ref, ""}} =
             AuthorityMaterialization.cancellation_events(
               corrupt,
               c.act,
               "mandate:unrelated",
               :mandate_restricted
             )
  end

  test "batch positional matching rejects absent, reordered and wrong-schema records", c do
    payload = Event.dispatch_ready(c.act)
    events = decode([payload], Runtime.now())
    assert Events.payload_sequence?(events, [payload], 0)
    refute Events.payload_sequence?(events, [payload], 1)
    refute Events.payload_sequence?(events, [Map.put(payload, "schema_version", 2)], 0)
    refute Events.payload_sequence?([], [payload], 0)
    refute Events.manual_at?(events, 0, "act_committed", c.act.ref, %{})
    refute Events.manual_at?(events, 1, "dispatch_ready", hd(events).identity, %{})
  end

  defp decode(payloads, time) do
    payloads
    |> Enum.with_index()
    |> Enum.map(fn {payload, index} ->
      {:ok, event} = Event.decode_payload(payload, index + 1, "test:atomic-batch", index, time)
      event
    end)
  end
end
