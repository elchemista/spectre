Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.DutyMeterMaterializationTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.{Act, Duty, Outcome, Portable, Principal}
  alias Spectre.GAM.Attempt.Executor
  alias Spectre.GAM.Domain.{Event, Sequencer}
  alias Spectre.GAM.Duty.Disposition
  alias Spectre.GAM.GovernedAct.Catalog
  alias Spectre.GAM.GovernedAct.Materialization.Duty, as: Materialization
  alias Spectre.GAM.GovernedAct.Transition.Duty.Meter, as: DutyMeter
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

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
    %{f: f, state: state, duty: duty, cause: cause, attempt: attempt, payment: payment}
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

  test "the folded accounting transition settles an authorized suspended reservation", c do
    c = with_independent_reviewer(c)
    {_disposition, act} = disposition(c, :settle, [c.payment.ref])
    assert {:ok, [payload, _disposed]} = Materialization.events(c.state, act)
    assert {:ok, event} = Event.decode(payload)
    state = %{c.state | acts: Map.put(c.state.acts, act.ref, act)}

    assert {:ok, resolved} = DutyMeter.resolve(state, event.data)
    assert MapSet.member?(resolved.duty_meter_resolutions, act.ref)
    assert resolved.meter_reservations[c.cause.ref] == :settled

    assert {:error, {:duplicate_duty_meter_resolution, ref}} =
             DutyMeter.resolve(resolved, event.data)

    assert ref == act.ref
  end

  test "recontained quantities retain their causal Duty until accounting resolves them", c do
    c = with_independent_reviewer(c)
    {_disposition, act} = disposition(c, :settle, [c.payment.ref])

    record = %{
      cause_key: c.duty.cause_key,
      outcome_ref: c.state.outcomes |> Map.keys() |> hd(),
      disposition_act_ref: nil,
      recontained: c.cause.reservations,
      deficits: %{}
    }

    state = %{
      c.state
      | acts: Map.put(c.state.acts, act.ref, act),
        meter_recontainments: %{c.cause.ref => record}
    }

    assert {:ok, [payload, _disposed]} = Materialization.events(state, act)
    assert {:ok, event} = Event.decode(payload)
    assert {:ok, resolved} = DutyMeter.resolve(state, event.data)
    assert resolved.meter_recontainments[c.cause.ref].disposition_act_ref == act.ref
  end

  test "the accounting fold rejects every stale or malformed causal binding", c do
    c = with_independent_reviewer(c)
    {_disposition, act} = disposition(c, :settle, [c.payment.ref])
    act_ref = act.ref
    cause_ref = c.cause.ref
    cause_key = c.duty.cause_key
    assert {:ok, [payload, _disposed]} = Materialization.events(c.state, act)
    assert {:ok, event} = Event.decode(payload)
    state = %{c.state | acts: Map.put(c.state.acts, act.ref, act)}

    for data <- [
          Map.put(event.data, "operation", :none),
          Map.put(event.data, "amounts", %{}),
          Map.put(event.data, "mandate_ref", "mandate:other")
        ] do
      assert {:error, {:invalid_duty_meter_resolution_event, ^act_ref}} =
               DutyMeter.resolve(state, data)
    end

    reserved = %{state | meter_reservations: %{c.cause.ref => :reserved}}

    assert {:error, {:duty_meter_resolution_requires_suspension, ^cause_ref, :reserved}} =
             DutyMeter.resolve(reserved, event.data)

    resolved_record = %{disposition_act_ref: "act:earlier"}

    assert {:error, {:meter_recontainment_already_resolved, ^cause_ref, "act:earlier"}} =
             DutyMeter.resolve(
               %{state | meter_recontainments: %{c.cause.ref => resolved_record}},
               event.data
             )

    assert {:error, {:invalid_meter_recontainment, ^cause_ref}} =
             DutyMeter.resolve(
               %{state | meter_recontainments: %{c.cause.ref => :corrupt}},
               event.data
             )

    disposed = %{c.duty | status: :disposed, disposition_act_ref: act.ref}
    duties = %{c.duty.cause_key => disposed}

    assert {:error, {:duty_disposed, ^cause_key}} =
             DutyMeter.resolve(%{state | duties: duties}, event.data)
  end

  test "release requires and accepts an exact uncorrected no-effect receipt", c do
    c = with_independent_reviewer(c)

    {:ok, no_effect_evidence} =
      Executor.outcome_evidence(
        c.cause,
        c.attempt,
        :definitive_no_effect,
        Runtime.now(),
        payload: %{"receipt" => "provider-confirms-no-effect"}
      )

    {:ok, no_effect} =
      Outcome.new(%{
        Fixture.outcome(
          c.f,
          c.cause,
          c.attempt,
          :definitive_no_effect,
          [no_effect_evidence.ref]
        )
        | ref: nil
      })

    state = %{
      c.state
      | evidence: Map.put(c.state.evidence, no_effect_evidence.ref, no_effect_evidence),
        outcomes: Map.put(c.state.outcomes, no_effect.ref, no_effect)
    }

    c = %{c | state: state}
    {_disposition, act} = disposition(c, :release, [no_effect.ref])
    state = %{state | acts: Map.put(state.acts, act.ref, act)}
    assert {:ok, [payload, _disposed]} = Materialization.events(state, act)
    assert {:ok, event} = Event.decode(payload)
    assert {:ok, resolved} = DutyMeter.resolve(state, event.data)
    assert resolved.meter_reservations[c.cause.ref] == :released

    {_disposition, unsupported} = disposition(c, :release, [c.payment.ref])
    unsupported_state = %{state | acts: Map.put(state.acts, unsupported.ref, unsupported)}
    assert {:ok, [payload, _disposed]} = Materialization.events(unsupported_state, unsupported)
    assert {:ok, event} = Event.decode(payload)

    assert {:error, :duty_meter_release_not_proven} =
             DutyMeter.resolve(unsupported_state, event.data)
  end

  defp disposition(c, operation, supporting_refs \\ ["evidence:review"]) do
    {:ok, disposition} =
      Disposition.for_duty(c.duty, :accept_loss, supporting_refs, operation)

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
        evidence_refs: supporting_refs,
        recognition_refs: [],
        recognition_evidence_refs: [],
        executor_ref: "spectre:kernel:ledger",
        executor_contract_ref: "spectre:kernel:ledger:v1"
      })
      |> Map.merge(disposition_actor(c))
      |> Act.new()

    {disposition, act}
  end

  defp disposition_actor(%{review_mandate: mandate}) do
    %{
      mandate_ref: mandate.ref,
      proposer_ref: mandate.holder_ref,
      authenticated_principal_ref: mandate.holder_ref,
      authorizer_ref: mandate.ref,
      accountable_ref: mandate.accountable_ref
    }
  end

  defp disposition_actor(_c), do: %{}

  defp with_independent_reviewer(c) do
    {:ok, reviewer} = Principal.new(%{kind: :human, attributes: %{"role" => "meter-reviewer"}})

    {:ok, duty} =
      c.duty
      |> Map.from_struct()
      |> Map.put(:disposition_authority_refs, [reviewer.ref])
      |> Duty.new()

    {:ok, mandate} =
      c.f.mandate
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.merge(%{
        holder_ref: reviewer.ref,
        grantor_ref: reviewer.ref,
        accountable_ref: reviewer.ref,
        target_refs: [duty.ref],
        revocation: %{"mode" => :cascade, "controller_refs" => [reviewer.ref]}
      })
      |> Spectre.GAM.Mandate.new()

    state = %{
      c.state
      | catalog: Catalog.put_principal(c.state.catalog, reviewer),
        duties: Map.put(c.state.duties, duty.cause_key, duty),
        mandates: Map.put(c.state.mandates, mandate.ref, mandate)
    }

    c |> Map.merge(%{duty: duty, state: state}) |> Map.put(:review_mandate, mandate)
  end
end
