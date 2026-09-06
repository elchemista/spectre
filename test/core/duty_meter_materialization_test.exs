defmodule Spectre.Core.DutyMeterMaterializationTest do
  use ExUnit.Case, async: false

  alias Spectre.{Act, Duty, Portable}
  alias Spectre.Domain.{Event, Sequencer}
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.Materialization.Duty, as: Materialization
  alias Spectre.GovernedAct.Transition.Duty.Meter, as: DutyMeter
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "duty-meter-materialization")
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    {:ok, _} = Fixture.observe_payment(f, payment)

    {:ok, %{act: cause, grant: grant}} =
      Sequencer.submit(
        f.server,
        Fixture.context(f),
        Fixture.refund_candidate(f, 100, evidence_refs: [payment.ref])
      )

    {:ok, _, attempt, _} = Sequencer.consume_grant(f.server, grant)
    {:ok, _} = Sequencer.record_outcome(f.server, Fixture.outcome(f, cause, attempt, :ambiguous))
    state = Sequencer.projection(f.server)
    [duty] = Map.values(state.duties)
    %{state: state, duty: duty, cause: cause}
  end

  # Unit tests of event construction and the post-disposition invariant. The
  # independent authority admission proof is intentionally not asserted here.
  for operation <- [:settle, :release] do
    test "#{operation} materializes accounting before disposal with exact causal bindings", c do
      {disposition, act} = disposition(c, unquote(operation))
      assert {:ok, [meter, disposed]} = Materialization.events(c.state, act)
      assert meter["type"] == "meter_duty_resolved"

      assert meter["data"] == %{
               "act_ref" => c.cause.ref,
               "disposition_act_ref" => act.ref,
               "duty_ref" => c.duty.ref,
               "mandate_ref" => c.cause.mandate_ref,
               "operation" => unquote(operation),
               "amounts" => c.cause.reservations
             }

      assert disposed["type"] == "duty_disposed"
      assert {:ok, _} = Event.decode(meter)
      assert {:ok, _} = Event.decode(disposed)

      assert {:error, {:duty_meter_resolution_binding_mismatch, _}} =
               DutyMeter.validate_disposed(c.state, c.duty, disposition, act.ref)

      state = %{
        c.state
        | duty_meter_resolutions: MapSet.new([act.ref]),
          meter_reservations: %{
            c.cause.ref => unquote(if operation == :settle, do: :settled, else: :released)
          }
      }

      assert :ok = DutyMeter.validate_disposed(state, c.duty, disposition, act.ref)
    end
  end

  for {status, operation, expected} <- [
        {:suspended, :none, :duty_meter_resolution_required},
        {:reserved, :settle, :duty_meter_not_contained},
        {nil, :settle, :reservation_not_found},
        {:settled, :release, :invalid_duty_meter_resolution}
      ] do
    test "#{status} reservation cannot be disposed with #{operation}", c do
      {_disposition, act} = disposition(c, unquote(operation))
      state = %{c.state | meter_reservations: %{c.cause.ref => unquote(status)}}
      assert {:error, reason} = Materialization.events(state, act)
      assert elem(reason, 0) == unquote(expected)
    end
  end

  test "a closing Act must refer to the same open Duty and an existing cause", c do
    {_disposition, act} = disposition(c, :settle)
    assert {:error, {:duty_not_found, _}} = Materialization.events(%{c.state | duties: %{}}, act)

    assert {:error, {:duty_already_disposed, _}} =
             Materialization.events(
               put_in(
                 c.state,
                 [Access.key(:duties), c.duty.cause_key, Access.key(:status)],
                 :disposed
               ),
               act
             )

    assert {:error, {:duty_disposition_binding_mismatch, _}} =
             Materialization.events(
               put_in(
                 c.state,
                 [Access.key(:duties), c.duty.cause_key, Access.key(:ref)],
                 "other"
               ),
               act
             )

    assert {:error, {:duty_cause_act_not_found, _}} =
             Materialization.events(%{c.state | acts: %{}}, act)

    assert {:error, :invalid_duty_disposition} =
             Materialization.events(c.state, %{act | reservations: %{"meter" => 1}})
  end

  test "unmetered Duties cannot invent a reservation, resolution or accounting event", c do
    {:ok, duty} =
      Duty.new(
        class: "app.review",
        cause_key: {:review, 1},
        accountable: "owner",
        opened_at: Runtime.now()
      )

    state = %{c.state | duties: %{duty.cause_key => duty}}
    c = %{c | duty: duty, state: state}
    {none, act} = disposition(c, :none)
    assert {:ok, [%{"type" => "duty_disposed"}]} = Materialization.events(state, act)
    assert :ok = DutyMeter.validate_disposed(state, duty, none, act.ref)
    {settle, settle_act} = disposition(c, :settle)

    assert {:error, {:duty_has_no_meter_reservation, _}} =
             Materialization.events(state, settle_act)

    assert {:error, {:duty_has_no_meter_reservation, _}} =
             DutyMeter.validate_disposed(state, duty, settle, settle_act.ref)

    assert {:error, {:unexpected_duty_meter_resolution, _}} =
             DutyMeter.validate_disposed(
               %{state | duty_meter_resolutions: MapSet.new([act.ref])},
               duty,
               none,
               act.ref
             )
  end

  test "already settled or released causes need no second accounting event", c do
    {none, act} = disposition(c, :none)

    for status <- [:settled, :released] do
      state = %{c.state | meter_reservations: %{c.cause.ref => status}}
      assert {:ok, [%{"type" => "duty_disposed"}]} = Materialization.events(state, act)
      assert :ok = DutyMeter.validate_disposed(state, c.duty, none, act.ref)
    end

    assert {:error, {:duty_meter_not_resolved, _}} =
             DutyMeter.validate_disposed(c.state, c.duty, none, act.ref)
  end

  test "recontainment stays with its own causal Duty and resolves only the recoverable amounts",
       c do
    {settle, act} = disposition(c, :settle)

    record = %{
      cause_key: c.duty.cause_key,
      disposition_act_ref: nil,
      recontained: %{},
      deficits: c.cause.reservations
    }

    state = %{c.state | meter_recontainments: %{c.cause.ref => record}}
    assert {:ok, [meter, _disposed]} = Materialization.events(state, act)
    assert meter["data"]["amounts"] == %{}
    other_record = %{record | cause_key: {:other, 1}}
    state = %{state | meter_recontainments: %{c.cause.ref => other_record}}

    assert {:error, {:meter_recontainment_requires_causal_duty, _, _}} =
             Materialization.events(state, act)

    {none, none_act} = disposition(c, :none)
    assert {:ok, [%{"type" => "duty_disposed"}]} = Materialization.events(state, none_act)
    assert :ok = DutyMeter.validate_disposed(state, c.duty, none, none_act.ref)

    resolved = %{
      state
      | meter_reservations: %{c.cause.ref => :settled},
        duty_meter_resolutions: MapSet.new([act.ref])
    }

    assert {:error, {:meter_recontainment_not_resolved, _}} =
             DutyMeter.validate_disposed(resolved, c.duty, settle, act.ref)

    resolved = %{
      resolved
      | meter_recontainments: %{c.cause.ref => %{record | disposition_act_ref: act.ref}}
    }

    assert :ok = DutyMeter.validate_disposed(resolved, c.duty, settle, act.ref)
  end

  test "a metered cause cannot masquerade as unmetered after disposition", c do
    {none, act} = disposition(c, :none)
    state = put_in(c.state, [Access.key(:acts), c.cause.ref, Access.key(:reservations)], %{})
    assert {:error, {:unexpected_duty_reservation_state, _}} = Materialization.events(state, act)

    assert {:error, {:unexpected_duty_reservation_state, _}} =
             DutyMeter.validate_disposed(state, c.duty, none, act.ref)

    state = %{state | meter_reservations: %{}}
    assert {:ok, [_event]} = Materialization.events(state, act)
    assert :ok = DutyMeter.validate_disposed(state, c.duty, none, act.ref)
    {settle, settle_act} = disposition(c, :settle)

    assert {:error, {:duty_has_no_meter_reservation, _}} =
             Materialization.events(state, settle_act)

    assert {:error, {:duty_has_no_meter_reservation, _}} =
             DutyMeter.validate_disposed(state, c.duty, settle, settle_act.ref)
  end

  defp disposition(c, operation) do
    {:ok, disposition} =
      Disposition.for_duty(c.duty, :accept_loss, ["evidence:review"], operation)

    consequence = Disposition.consequence(disposition)

    {:ok, act} =
      c.cause
      |> Map.from_struct()
      |> Map.merge(%{
        ref: nil,
        class: "duty.dispose",
        row: %{govern: true},
        reservations: %{},
        observation_window_ms: 0,
        disclosure: nil,
        consequence: consequence,
        material_digest: Portable.digest!(consequence),
        target_refs: [c.duty.ref],
        evidence_refs: ["evidence:review"],
        recognition_refs: [],
        recognition_evidence_refs: [],
        executor_ref: "spectre:kernel:ledger",
        executor_contract_ref: "spectre:kernel:ledger:v1"
      })
      |> Act.new()

    {disposition, act}
  end
end
