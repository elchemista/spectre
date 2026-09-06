defmodule Spectre.Core.ExecutionTransitionBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.{Attempt, Outcome, Portable, Row}
  alias Spectre.Domain.{Event, Sequencer}
  alias Spectre.GovernedAct.{Completeness, DispatchState}
  alias Spectre.GovernedAct.Transition.Execution
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "execution-transition")
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    {:ok, _} = Fixture.observe_payment(f, payment)

    {:ok, %{act: act, grant: grant}} =
      Sequencer.submit(
        f.server,
        Fixture.context(f),
        Fixture.refund_candidate(f, 100, evidence_refs: [payment.ref])
      )

    pending = Sequencer.projection(f.server)
    {:ok, _, attempt, _} = Sequencer.consume_grant(f.server, grant)
    attempted = Sequencer.projection(f.server)
    {:ok, attempt_event} = Event.record(:attempt, attempt)
    {:ok, attempt_event} = Event.decode(attempt_event)
    ready = Event.dispatch_ready(act)
    {:ok, ready} = Event.decode(ready)

    %{
      f: f,
      act: act,
      attempt: attempt,
      pending: pending,
      attempted: attempted,
      attempt_event: attempt_event,
      ready: ready
    }
  end

  for {field, value, reason} <- [
        {"executor_ref", "other", :dispatch_executor_mismatch},
        {"executor_contract_ref", "other", :dispatch_contract_mismatch}
      ] do
    test "dispatch readiness binds exact #{field}", c do
      state = %{c.pending | pending_dispatches: MapSet.new()}
      assert {:ok, _} = Execution.apply(state, c.ready, nil)
      changed = %{c.ready | data: Map.put(c.ready.data, unquote(field), unquote(value))}
      assert {:error, reason} = Execution.apply(state, changed, nil)
      assert elem(reason, 0) == unquote(reason)
    end
  end

  test "readiness is neither repeatable nor restorable after consumption or cancellation", c do
    assert {:error, {:duplicate_dispatch_ready, _}} = Execution.apply(c.pending, c.ready, nil)
    assert {:error, {:act_already_attempted, _}} = Execution.apply(c.attempted, c.ready, nil)

    cancelled =
      DispatchState.mark_cancelled(c.pending, c.act.ref, %{
        cause_ref: "cause",
        reason: :mandate_expired,
        cancelled_at: Runtime.now()
      })

    assert {:error, {:dispatch_already_cancelled, _}} = Execution.apply(cancelled, c.ready, nil)
    state = %{c.pending | pending_dispatches: MapSet.new(), meter_reservations: %{}}
    assert {:error, {:act_reservation_not_ready, _}} = Execution.apply(state, c.ready, nil)

    internal =
      update_in(
        state.acts[c.act.ref],
        &%{
          &1
          | class: "mandate.revoke",
            row: %Row{govern: true},
            executor_ref: "spectre:kernel:ledger",
            executor_contract_ref: "spectre:kernel:ledger:v1"
        }
      )

    assert {:error, {:act_not_executor_mediated, _}} = Execution.apply(internal, c.ready, nil)
  end

  test "Attempt replay cannot consume absent readiness, a released reservation or a used nonce",
       c do
    assert {:ok, rebuilt} = Execution.apply(c.pending, c.attempt_event, nil)
    assert rebuilt.attempts == c.attempted.attempts

    assert {:error, {:act_not_dispatch_ready, _}} =
             Execution.apply(
               %{c.pending | pending_dispatches: MapSet.new()},
               c.attempt_event,
               nil
             )

    assert {:error, {:act_reservation_not_attemptable, _}} =
             Execution.apply(
               %{c.pending | meter_reservations: %{c.act.ref => :released}},
               c.attempt_event,
               nil
             )

    assert {:error, {:grant_nonce_already_consumed, _}} =
             Execution.apply(
               %{c.pending | consumed_nonces: MapSet.new([c.attempt.grant_nonce_digest])},
               c.attempt_event,
               nil
             )

    assert {:error, {:act_already_attempted, _, _}} =
             Execution.apply(%{c.attempted | attempts: %{}}, c.attempt_event, nil)
  end

  for {field, value, reason} <- [
        {:executor_ref, "other", :attempt_executor_mismatch},
        {:material_digest, String.duplicate("a", 64), :attempt_material_mismatch},
        {:started_at, 999_999, :attempt_precedes_act}
      ] do
    test "a validly encoded Attempt cannot change #{field} from its admitted Act", c do
      {:ok, attempt} =
        c.attempt |> Map.from_struct() |> Map.put(unquote(field), unquote(value)) |> Attempt.new()

      {:ok, event} = Event.record(:attempt, attempt)
      {:ok, event} = Event.decode(event)
      assert {:error, reason} = Execution.apply(c.pending, event, nil)
      assert elem(reason, 0) == unquote(reason)
    end
  end

  test "expiry cancellation requires the exact integer expiry and matching Mandate", c do
    event = cancellation(c)
    assert {:ok, cancelled} = Execution.apply(c.pending, event, nil)
    assert DispatchState.cancelled?(cancelled, c.act.ref)

    assert {:error, {:duplicate_dispatch_cancellation, _}} =
             Execution.apply(cancelled, event, nil)

    assert {:error, {:dispatch_cancellation_after_attempt, _}} =
             Execution.apply(c.attempted, event, nil)

    assert {:error, {:dispatch_cancellation_not_pending, _}} =
             Execution.apply(%{c.pending | pending_dispatches: MapSet.new()}, event, nil)

    for {field, value} <- [
          {"cause_ref", "other"},
          {"cancelled_at", c.f.mandate.expires_at + 1},
          {"cancelled_at", c.f.mandate.expires_at * 1.0}
        ] do
      assert {:error, {:invalid_dispatch_expiration, _}} =
               Execution.apply(c.pending, %{event | data: Map.put(event.data, field, value)}, nil)
    end

    assert {:error, {:dispatch_cancellation_mandate_mismatch, _}} =
             Execution.apply(
               c.pending,
               %{event | data: Map.put(event.data, "mandate_ref", "other")},
               nil
             )

    assert {:error, {:invalid_dispatch_cancellation_reason, _, :invented}} =
             Execution.apply(
               c.pending,
               %{event | data: Map.put(event.data, "reason", :invented)},
               nil
             )

    assert {:error, {:dispatch_cancellation_reservation_not_pending, _}} =
             Execution.apply(%{c.pending | meter_reservations: %{}}, event, nil)
  end

  test "Outcome acquisition cannot precede its Attempt or escape the consumption index", c do
    outcome = Fixture.outcome(c.f, c.act, c.attempt, :ambiguous)
    {:ok, payload} = Event.record(:outcome, outcome)
    {:ok, event} = Event.decode(payload)
    assert {:ok, _} = Execution.apply(c.attempted, event, nil)

    assert {:error, {:outcome_attempt_index_mismatch, _, _}} =
             Execution.apply(%{c.attempted | terminal_dispatches: %{}}, event, nil)

    {:ok, early} =
      outcome
      |> Map.from_struct()
      |> Map.merge(%{ref: nil, observed_at: c.attempt.started_at - 1})
      |> Outcome.new()

    {:ok, payload} = Event.record(:outcome, early)
    {:ok, event} = Event.decode(payload)
    assert {:error, {:outcome_precedes_attempt, _, _}} = Execution.apply(c.attempted, event, nil)
  end

  test "complete prefixes detect missing or contradictory indexes even when individual records decode",
       c do
    assert :ok = Completeness.validate(c.pending)
    assert :ok = Completeness.validate(c.attempted)
    assert {:error, :invalid_governed_fold} = Completeness.validate(%{})

    for {field, value, expected} <- [
          {:admissions, %{}, :admission_index_size_mismatch},
          {:acts, %{}, :admission_act_size_mismatch},
          {:meter_reservations, %{}, :act_reservation_not_recorded},
          {:meter_reservations, %{c.act.ref => :invented}, :invalid_meter_reservation},
          {:pending_dispatches, MapSet.new(["other", c.act.ref]), :dispatch_act_not_found},
          {:pending_dispatches, MapSet.new(), :invalid_act_dispatch_state},
          {:meter_reservations, %{c.act.ref => :suspended}, :suspended_reservation_without_duty},
          {:meters, %{}, :mandate_meter_ownership_incomplete},
          {:mandate_successors, %{"missing" => "successor"}, :mandate_restriction_links_mismatch},
          {:mandate_successors, %{"a" => "c", "b" => "c"}, :mandate_already_has_predecessor}
        ] do
      assert {:error, reason} = Completeness.validate(Map.replace!(c.pending, field, value))
      assert error_tag(reason) == expected
    end

    ghost = %{c.attempt | ref: "01900000-0000-7000-8000-000000000001"}

    assert {:error, {:attempt_dispatch_binding_mismatch, _}} =
             Completeness.validate(%{
               c.attempted
               | attempts: Map.put(c.attempted.attempts, ghost.ref, ghost)
             })

    assert Portable.sha256_digest?(c.pending.head_digest)
  end

  defp cancellation(c),
    do: %Event{
      type: "dispatch_cancelled",
      identity: "dispatch_cancelled:" <> c.act.ref,
      data: %{
        "act_ref" => c.act.ref,
        "mandate_ref" => c.act.mandate_ref,
        "cause_ref" => c.f.mandate.ref,
        "reason" => :mandate_expired,
        "cancelled_at" => c.f.mandate.expires_at
      }
    }

  defp error_tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp error_tag(reason), do: reason
end
