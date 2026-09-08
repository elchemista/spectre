defmodule Spectre.Core.RoutedAgentsLifecycleTest do
  use Spectre.Test.RoutedAgentCase, async: false

  alias Spectre.Instance
  alias Spectre.Store.Memory, as: ApplicationStore
  alias Spectre.Test.RoutedAgentCase.CheckpointStore
  alias Spectre.V04Test.Fixture

  test "a checkpoint restores Mind state without replaying the previous external effect", c do
    store = start_supervised!(Spectre.Store.Memory)
    config = {Spectre.Store.Memory, server: store}
    {result, _route, candidate} = prepare(c, "refund 37")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 37)
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    before = projection(c)
    GenServer.stop(c.instance)

    assert {:ok, restored} =
             Instance.start_link(
               scope: c.scope,
               definition_ref: c.definition.ref,
               checkpoint: {config, "mind"}
             )

    on_exit(fn -> Fixture.stop_process(restored) end)
    assert Instance.state(restored) == %{revision: 1, value: 1}
    assert projection(c) == before
    assert {:ok, _} = Instance.propose(restored, candidate)
    assert executions(c) == 1
    assert {:error, :conflict} = Instance.checkpoint(restored, config, "mind", 0)
    assert {:ok, 2} = Instance.checkpoint(restored, config, "mind", 1)
  end

  test "a checkpoint committed before a lost acknowledgement is never written twice implicitly",
       c do
    store = start_supervised!(ApplicationStore)
    config = {CheckpointStore, server: store, observer: self(), lose_ack: true}
    {result, _route, candidate} = prepare(c, "refund 29")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 29)
    before = projection(c)

    assert {:error,
            {:ambiguous,
             {:adapter_callback_exception, CheckpointStore, :compare_and_swap, RuntimeError}}} =
             Instance.checkpoint(c.instance, config, "mind", 0)

    assert_receive {:checkpoint_written, "mind", {:ok, 1}}
    refute_receive {:checkpoint_written, _, _}
    assert {:ok, 1, record} = Spectre.Store.get({ApplicationStore, server: store}, "mind")
    assert record["state_revision"] == 1 and record["value"] == 1
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert projection(c) == before
    assert executions(c) == 1
  end

  test "restoring a checkpoint cannot silently override an explicit host state", c do
    store = start_supervised!(ApplicationStore)
    config = {CheckpointStore, server: store, observer: self()}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    assert_receive {:checkpoint_written, "mind", {:ok, 1}}

    assert {:error, {:instance_state_checkpoint_collision, _child}} =
             start_supervised(
               {Instance,
                scope: c.scope,
                definition_ref: c.definition.ref,
                state: 9,
                checkpoint: {config, "mind"}},
               id: :invalid_checkpoint
             )

    refute_receive {:checkpoint_read, _}
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert executions(c) == 0
  end

  test "a live revised Definition cannot silently inherit the old Definition's checkpoint", c do
    store = start_supervised!(ApplicationStore)
    config = {ApplicationStore, server: store}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
    before = projection(c)

    assert {:error, {:instance_checkpoint_binding_mismatch, _child}} =
             start_supervised(
               {Instance,
                scope: c.scope, definition_ref: c.successor.ref, checkpoint: {config, "mind"}},
               id: :invalid_checkpoint
             )

    assert {:ok, fresh} =
             Instance.start_link(scope: c.scope, definition_ref: c.successor.ref, state: 0)

    assert {:ok, definition} = Instance.definition(fresh)
    assert definition.ref == c.successor.ref
    GenServer.stop(fresh)
    assert projection(c) == before
    assert executions(c) == 0
  end

  @tag status: :ambiguous
  test "restoring Mind state cannot extinguish an ambiguous effect or release suspended Meter",
       c do
    {_result, _route, candidate} = prepare(c, "refund 31")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.outcome.status == :ambiguous
    assert_receive {:executed, _, _, _, _}
    assert account(c).suspended == 31
    assert Enum.any?(projection(c).duties, fn {_ref, duty} -> duty.status == :open end)

    store = start_supervised!(ApplicationStore)
    config = {ApplicationStore, server: store}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    before = projection(c)
    GenServer.stop(c.instance)

    assert {:ok, restored} =
             Instance.start_link(
               scope: c.scope,
               definition_ref: c.definition.ref,
               checkpoint: {config, "mind"}
             )

    assert {:ok, ^proposal} = Instance.propose(restored, candidate)
    assert projection(c) == before
    assert Instance.state(restored) == %{revision: 1, value: 1}
    assert executions(c) == 1 and account(c).suspended == 31
    GenServer.stop(restored)
    assert_history(c)
  end

  test "Morph activates a new Definition but preserves the running agent's exact routing configuration",
       c do
    {prepared, _, candidate} = prepare(c, "refund 101")
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
    assert {:ok, definition} = Instance.definition(c.instance)
    assert definition == c.definition
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, prepared.turn, proposal, 101)
    {_next, route, _candidate} = prepare(c, "refund 102", identity: "after-morph")
    assert route.template == "support/billing/refund"
    assert_history(c)
  end

  test "old and new Instances route through their pinned Definitions while sharing the same Meter",
       c do
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)

    updated =
      start_supervised!({Instance, scope: c.scope, definition_ref: c.successor.ref, state: 40},
        id: :updated
      )

    updated_c = %{c | instance: updated}
    {first, old_route, old_candidate} = prepare(c, "money back", identity: "old")
    {second, new_route, new_candidate} = prepare(updated_c, "money back", identity: "new")
    assert old_route.template == "retention/refund"
    assert new_route.template == "revised_refund"
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert Instance.state(updated) == %{revision: 1, value: 41}
    assert {:ok, proposal} = Instance.propose(c.instance, old_candidate)
    assert_completed(c, first.turn, proposal, 100)
    assert {:ok, proposal} = Instance.propose(updated, new_candidate)
    assert_completed(c, second.turn, proposal, 200)
    assert_history(c)
  end

  test "a routing agent cannot approve its own Morph by knowing the governance Mandate ref", c do
    before = projection(c)

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             revise(%{c | admin: c.scope}, c.successor)

    assert projection(c).catalog == before.catalog
    {result, route, candidate} = prepare(c, "money back")
    assert route.template == "retention/refund"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  @tag status: :paused
  test "concurrent retry from a second Instance observes the live Attempt without executing twice",
       c do
    {_result, _, candidate} = prepare(c, "refund 23")

    other =
      start_supervised!({Instance, scope: c.scope, definition_ref: c.definition.ref, state: 0},
        id: :concurrent
      )

    first = Task.async(fn -> Instance.propose(c.instance, candidate) end)

    # The provider blocks after checkout. This is a deterministic interleaving,
    # not a sleep hoping that two calls happen to race in the right window.
    assert_receive {:executed, act, attempt, capability, snapshot}
    assert_receive {:execution_worker, worker}
    refute worker == c.instance
    assert Instance.state(c.instance, 1_000) == %{revision: 1, value: 1}
    assert Instance.info(c.instance, 1_000).definition_ref == c.definition.ref
    assert {:ok, definition} = Instance.definition(c.instance, 1_000)
    assert definition == c.definition
    assert capability == c.capability
    assert event_revision(snapshot, "attempt_started", attempt.ref) > 0
    assert {:ok, pending} = Instance.propose(other, candidate)
    assert pending.primary.act == act and pending.primary.attempt == attempt
    assert pending.primary.outcome == nil
    assert executions(c) == 1
    assert account(c).reserved == 23 and account(c).spent == 0
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.attempts == [attempt] and view.outcomes == []
    assert_history(c)

    send(worker, :complete_execution)
    assert {:ok, completed} = Task.await(first, 5_000)
    assert completed.primary.outcome.status == :succeeded
    assert {:ok, ^completed} = Instance.propose(other, candidate)
    assert executions(c) == 1
    assert account(c).reserved == 0 and account(c).spent == 23
    assert_history(c)
  end

  @tag status: :paused
  test "killing an Instance worker after checkout retains the Attempt and never retries the effect",
       c do
    {_result, _, candidate} = prepare(c, "refund 23")
    caller = Task.async(fn -> Instance.propose(c.instance, candidate) end)
    assert_receive {:executed, act, attempt, _capability, _snapshot}
    assert_receive {:execution_worker, worker}
    assert executions(c) == 1

    Process.exit(worker, :kill)
    assert {:error, {:instance_operation_stopped, :propose}} = Task.await(caller)
    assert Process.alive?(c.instance)
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert account(c).reserved == 23
    assert account(c).spent == 0

    # Re-submitting the same occurrence reads the durable Attempt. Losing its
    # worker did not produce a no-effect receipt, release money or mint again.
    assert {:ok, pending} = Instance.propose(c.instance, candidate)
    assert pending.primary.act == act
    assert pending.primary.attempt == attempt
    assert pending.primary.outcome == nil
    assert executions(c) == 1
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.attempts == [attempt]
    assert view.outcomes == []
    assert_history(c)
  end
end
