Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.ExecutionTransitionBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Act, Attempt, Duty, Governance, Outcome, Row}
  alias Spectre.GAM.Domain.Event
  alias Spectre.GAM.Duty.Disposition
  alias Spectre.GAM.GovernedAct.Batch.Effect
  alias Spectre.GAM.GovernedAct.{DispatchState, Execution}
  alias Spectre.GAM.GovernedAct.Transition.Execution, as: Transition

  test "ledger-only effects cannot be dispatched or converted to executor Attempts", c do
    internal = %{
      c.act
      | class: "save",
        row: %Row{write: true},
        reservations: %{},
        disclosure: nil,
        executor_ref: Governance.kernel_executor_ref(),
        executor_contract_ref: Governance.kernel_contract_ref(),
        observation_window_ms: 0
    }

    state = put_in(c.pending, [Access.key(:acts), c.act.ref], internal)
    assert Execution.ledger_internal?(internal)
    assert {:error, {:act_not_executor_mediated, _}} = record(state, :attempt, c.attempt)

    assert {:error, {:dispatch_cancellation_act_not_executor_mediated, _}} =
             cancel(state, c.act, %{})

    refute Execution.ledger_internal?(nil)
    refute Execution.metered_ledger_internal?(internal)
    assert {:error, :invalid_governance_execution_boundary} = Execution.mode(nil)
    assert {:error, :invalid_governance_execution_boundary} = Execution.validate(nil)

    for changed <- [
          %{c.act | executor_ref: Governance.kernel_executor_ref()},
          %{c.act | executor_contract_ref: Governance.kernel_contract_ref()}
        ] do
      assert {:error, :invalid_ledger_internal_application_act} = Execution.mode(changed)
    end
  end

  test "the executor can start only while the Mandate is current, never from cached admission",
       c do
    {:ok, attempt} = Spectre.GAM.Attempt.new(%{c.attempt | started_at: c.f.mandate.expires_at})
    assert {:error, {:act_without_current_authority, _, _}} = record(c.pending, :attempt, attempt)

    assert {:error, {:act_without_current_authority, _, {:mandate_not_found, _}}} =
             record(%{c.pending | mandates: %{}}, :attempt, c.attempt)

    assert {:error, :invalid_domain_event_identity_binding} =
             Transition.apply(
               c.pending,
               %Event{type: "dispatch_cancelled", identity: "invalid", data: %{"act_ref" => nil}},
               nil
             )
  end

  test "dispatch readiness is bound to the exact executor and remains one-shot", c do
    event = decode(Event.dispatch_ready(c.act))
    undispatched = %{c.pending | pending_dispatches: MapSet.new()}

    internal = %{
      c.act
      | row: %Row{write: true},
        reservations: %{},
        disclosure: nil,
        executor_ref: Governance.kernel_executor_ref(),
        executor_contract_ref: Governance.kernel_contract_ref(),
        observation_window_ms: 0
    }

    internal_state = %{undispatched | acts: Map.put(undispatched.acts, c.act.ref, internal)}

    assert {:error, {:act_not_executor_mediated, _}} =
             Transition.apply(internal_state, event, nil)

    assert {:error, {:dispatch_executor_mismatch, _}} =
             Transition.apply(
               undispatched,
               %{event | data: Map.put(event.data, "executor_ref", "executor:other")},
               nil
             )

    assert {:error, {:dispatch_contract_mismatch, _}} =
             Transition.apply(
               undispatched,
               %{
                 event
                 | data: Map.put(event.data, "executor_contract_ref", "contract:other")
               },
               nil
             )

    cancelled =
      DispatchState.mark_cancelled(undispatched, c.act.ref, %{
        cause_ref: c.act.mandate_ref,
        reason: :mandate_expired,
        cancelled_at: c.f.mandate.expires_at
      })

    assert {:error, {:dispatch_already_cancelled, _}} =
             Transition.apply(cancelled, event, nil)

    assert {:error, {:act_already_attempted, _}} =
             Transition.apply(c.attempted, event, nil)
  end

  test "an Attempt cannot cross any durable Act or reservation binding", c do
    undispatched = %{c.pending | pending_dispatches: MapSet.new()}

    assert {:error, {:act_not_dispatch_ready, _}} =
             record(undispatched, :attempt, c.attempt)

    unavailable = %{
      c.pending
      | meter_reservations: Map.put(c.pending.meter_reservations, c.act.ref, :released)
    }

    assert {:error, {:act_reservation_not_attemptable, _}} =
             record(unavailable, :attempt, c.attempt)

    alias_ref = "act:alias"
    aliased = %{c.pending | acts: Map.put(c.pending.acts, alias_ref, c.act)}

    assert {:error, {:attempt_act_mismatch, _, _}} =
             record(aliased, :attempt, change_attempt(c.attempt, act_ref: alias_ref))

    assert {:error, {:attempt_executor_mismatch, _, _}} =
             record(
               c.pending,
               :attempt,
               change_attempt(c.attempt, executor_ref: "executor:other")
             )

    assert {:error, {:attempt_material_mismatch, _, _}} =
             record(
               c.pending,
               :attempt,
               change_attempt(c.attempt, material_digest: String.duplicate("0", 64))
             )

    assert {:error, {:attempt_precedes_act, _, _}} =
             record(
               c.pending,
               :attempt,
               change_attempt(c.attempt, started_at: c.act.committed_at - 1)
             )
  end

  test "an Outcome cannot refer to an Attempt on a different admitted Act", c do
    {:ok, other} = Act.new(%{c.act | ref: nil, candidate_identity_key: "other"})
    state = put_in(c.attempted, [Access.key(:acts), other.ref], other)

    {:ok, outcome} =
      Outcome.new(
        act_ref: other.ref,
        attempt_ref: c.attempt.ref,
        status: :ambiguous,
        observed_at: c.act.committed_at,
        details_ref: "receipt:ambiguous"
      )

    assert {:error, {:outcome_act_mismatch, _, _}} = record(state, :outcome, outcome)
  end

  test "an Outcome requires the indexed Attempt and cannot predate it", c do
    {:ok, outcome} =
      Outcome.new(
        act_ref: c.act.ref,
        attempt_ref: c.attempt.ref,
        status: :ambiguous,
        observed_at: c.attempt.started_at,
        details_ref: "receipt:ambiguous"
      )

    wrong_index = %{
      c.attempted
      | terminal_dispatches:
          Map.put(c.attempted.terminal_dispatches, c.act.ref, {:attempt, "attempt:other"})
    }

    assert {:error, {:outcome_attempt_index_mismatch, _, _}} =
             record(wrong_index, :outcome, outcome)

    {:ok, early} =
      outcome
      |> Map.from_struct()
      |> Map.put(:ref, nil)
      |> Map.put(:observed_at, c.attempt.started_at - 1)
      |> Outcome.new()

    assert {:error, {:outcome_precedes_attempt, _, _}} =
             record(c.attempted, :outcome, early)
  end

  test "a disputed pending Act cannot regain readiness, and cancellation must cite its exact Duty",
       c do
    {:ok, duty} =
      Duty.new(
        class: :disputed_evidence,
        cause_key: {:dispute, c.act.ref},
        accountable: c.act.accountable_ref,
        act_ref: c.act.ref,
        mandate_ref: c.act.mandate_ref,
        opened_at: c.act.committed_at
      )

    state = %{c.pending | duties: %{duty.cause_key => duty}, pending_dispatches: MapSet.new()}
    state = put_in(state.read_index.duties.by_ref[duty.ref], duty.cause_key)
    payload = Event.dispatch_ready(c.act)
    {:ok, event} = Event.decode(payload)

    assert {:error, {:act_dispatch_blocked_by_disputed_evidence, _}} =
             Transition.apply(state, event, nil)

    state = DispatchState.mark_pending(state, c.act.ref)

    valid = %{
      "cause_ref" => duty.ref,
      "reason" => :disputed_evidence,
      "cancelled_at" => duty.opened_at
    }

    assert {:ok, cancelled} = cancel(state, c.act, valid)
    assert DispatchState.cancelled?(cancelled, c.act.ref)

    assert {:error, {:invalid_disputed_dispatch_cancellation, _}} =
             cancel(state, c.act, %{valid | "cancelled_at" => duty.opened_at / 1})

    assert {:error, {:duty_not_found, "missing"}} =
             cancel(state, c.act, %{valid | "cause_ref" => "missing"})

    assert {:error, {:mandate_not_found, _}} =
             cancel(%{c.pending | mandates: %{}}, c.act, %{
               "cause_ref" => c.act.mandate_ref,
               "reason" => :mandate_expired,
               "cancelled_at" => c.f.mandate.expires_at
             })
  end

  test "dispatch cancellation is exact, terminal and causally typed", c do
    valid_expiry = %{
      "cause_ref" => c.act.mandate_ref,
      "reason" => :mandate_expired,
      "cancelled_at" => c.f.mandate.expires_at
    }

    assert {:error, {:dispatch_cancellation_after_attempt, _}} =
             cancel(c.attempted, c.act, valid_expiry)

    cancelled =
      DispatchState.mark_cancelled(c.pending, c.act.ref, %{
        cause_ref: c.act.mandate_ref,
        reason: :mandate_expired,
        cancelled_at: c.f.mandate.expires_at
      })

    assert {:error, {:duplicate_dispatch_cancellation, _}} =
             cancel(cancelled, c.act, valid_expiry)

    assert {:error, {:dispatch_cancellation_not_pending, _}} =
             cancel(%{c.pending | pending_dispatches: MapSet.new()}, c.act, valid_expiry)

    assert {:error, {:dispatch_cancellation_mandate_mismatch, _}} =
             cancel(c.pending, c.act, Map.put(valid_expiry, "mandate_ref", "mandate:other"))

    unavailable = %{
      c.pending
      | meter_reservations: Map.put(c.pending.meter_reservations, c.act.ref, :released)
    }

    assert {:error, {:dispatch_cancellation_reservation_not_pending, _}} =
             cancel(unavailable, c.act, valid_expiry)

    assert {:error, {:invalid_dispatch_expiration, _}} =
             cancel(
               c.pending,
               c.act,
               Map.put(valid_expiry, "cancelled_at", c.f.mandate.expires_at - 1)
             )

    assert {:error, {:invalid_dispatch_cancellation_reason, _, :operator_guess}} =
             cancel(c.pending, c.act, %{
               "cause_ref" => c.act.mandate_ref,
               "reason" => :operator_guess,
               "cancelled_at" => c.f.mandate.expires_at
             })
  end

  test "batch effects require the exact disposition suffix, not merely an Act named duty.dispose",
       c do
    assert Effect.exact?([], c.act, 0)
    assert :unsupported = Effect.exact?([], %{c.act | row: %Row{govern: true}}, 0)

    refute Effect.exact?(
             [],
             %{c.act | class: "mandate.revoke", row: %Row{govern: true}, consequence: %{}},
             0
           )

    refute Effect.exact?([], %{c.act | class: "duty.dispose", consequence: %{}}, 0)

    {:ok, disposition} =
      Disposition.new(
        kind: :accept_loss,
        duty_ref: "duty",
        opening_digest: String.duplicate("a", 64),
        cause_key: {:review, 1},
        supporting_refs: [c.payment.ref],
        meter_resolution: :none
      )

    {:ok, act} =
      Act.new(%{
        c.act
        | ref: nil,
          class: "duty.dispose",
          consequence: Disposition.consequence(disposition),
          row: %Row{govern: true},
          reservations: %{},
          disclosure: nil,
          executor_ref: Governance.kernel_executor_ref(),
          executor_contract_ref: Governance.kernel_contract_ref(),
          observation_window_ms: 0
      })

    {:ok, payload} = Event.duty_disposed(act, disposition.cause_key)
    {:ok, event} = Event.decode(payload)
    events = [%Event{type: "act_committed", identity: act.ref, data: %{}}, event]
    assert Effect.exact?(events, act, 0)
    refute Effect.exact?(Enum.reverse(events), act, 0)

    settle = %{
      act
      | consequence: Disposition.consequence(%{disposition | meter_resolution: :settle})
    }

    refute Effect.exact?(events, settle, 0)
  end

  defp record(state, kind, record) do
    {:ok, payload} = Event.record(kind, record)
    {:ok, event} = Event.decode(payload)
    Transition.apply(state, event, nil)
  end

  defp decode(payload) do
    {:ok, event} = Event.decode(payload)
    event
  end

  defp change_attempt(attempt, attrs) do
    {:ok, changed} =
      attempt
      |> Map.from_struct()
      |> Map.merge(Map.new(attrs))
      |> Attempt.new()

    changed
  end

  defp cancel(state, act, attrs) do
    data = Map.merge(%{"act_ref" => act.ref, "mandate_ref" => act.mandate_ref}, attrs)

    Transition.apply(
      state,
      %Event{type: "dispatch_cancelled", identity: "dispatch_cancelled:" <> act.ref, data: data},
      nil
    )
  end
end
