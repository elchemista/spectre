defmodule Spectre.Core.MeterStateBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.GovernedAct.MeterState
  alias Spectre.Kernel.Meter
  alias Spectre.Kernel.Meter.Account
  alias Spectre.{Mandate, Outcome, Row}
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "meter-state-boundary", delegation_allowed: true)
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    {:ok, _} = Fixture.observe_payment(f, payment)

    {:ok, %{act: act, grant: grant}} =
      Sequencer.submit(
        f.server,
        Fixture.context(f),
        Fixture.refund_candidate(f, 100, evidence_refs: [payment.ref])
      )

    state = Sequencer.projection(f.server)
    {:ok, _, attempt, _} = Sequencer.consume_grant(f.server, grant)

    data = %{
      "act_ref" => act.ref,
      "mandate_ref" => act.mandate_ref,
      "amounts" => act.reservations
    }

    %{f: f, state: state, act: act, attempt: attempt, data: data}
  end

  test "a reservation cannot be repeated, rebound or fabricated for a missing Act", c do
    assert {:error, {:reservation_already_exists, _, :reserved}} =
             MeterState.reserve(c.state, c.data)

    for data <- [Map.put(c.data, "mandate_ref", "other"), Map.put(c.data, "amounts", %{})] do
      assert {:error, {:meter_act_binding_mismatch, _, _}} = MeterState.reserve(c.state, data)
    end

    assert {:error, {:act, :not_found, "missing"}} =
             MeterState.reserve(c.state, Map.put(c.data, "act_ref", "missing"))

    assert {:error, _} =
             MeterState.reserve(c.state, Map.put(c.data, "amounts", %{"meter" => 1.0}))
  end

  test "disposable reservation indexes cannot impersonate missing or unmetered Acts", c do
    ref = c.act.ref

    assert {:error, {:reservation_not_found, "missing"}} =
             MeterState.reservation(c.state, "missing")

    broken = %{c.state | meter_reservations: %{ref => :invented}}
    assert {:error, {:invalid_reservation, ^ref}} = MeterState.reservation(broken, ref)
    assert MeterState.reservation_status(broken, ref) == nil

    assert {:error, {:reservation_act_not_found, ^ref}} =
             MeterState.reservation(%{c.state | acts: %{}}, ref)

    broken = put_in(c.state, [Access.key(:acts), ref, Access.key(:reservations)], %{})
    assert {:error, {:invalid_reservation_act, ^ref}} = MeterState.reservation(broken, ref)
  end

  for operation <- [:settle, :release, :suspend] do
    test "#{operation} needs world-side evidence, not merely a reserved account", c do
      assert {:error, {:reservation_disposition_not_evidenced, _, unquote(operation)}} =
               MeterState.transition(c.state, c.data, unquote(operation))
    end
  end

  for {status, {operation, bucket}} <- [
        succeeded: {:settle, :spent},
        definitive_no_effect: {:release, :available},
        ambiguous: {:suspend, :suspended}
      ] do
    test "#{status} authorizes only its accounting disposition and never a second one", c do
      outcome = outcome(c, unquote(status))
      state = %{c.state | outcomes: %{outcome.ref => outcome}}
      assert {:ok, next} = MeterState.transition(state, c.data, unquote(operation))
      account = next.meters[c.act.mandate_ref][c.f.refs.meter]
      assert account.reserved == 0

      assert Map.fetch!(account, unquote(bucket)) ==
               if(unquote(bucket) == :available, do: 10_000, else: 100)

      assert :ok = Account.validate(account)

      assert {:error, {:invalid_reservation_transition, _, _, _}} =
               MeterState.transition(next, c.data, unquote(operation))
    end
  end

  for {operation, status} <- [settle: :succeeded, release: :definitive_no_effect] do
    test "a later #{status} receipt can resolve suspended quantity exactly once", c do
      ambiguous = Fixture.outcome(c.f, c.act, c.attempt, :ambiguous)
      state = %{c.state | outcomes: %{ambiguous.ref => ambiguous}}
      {:ok, suspended} = MeterState.transition(state, c.data, :suspend)
      final = outcome(c, unquote(status))
      suspended = %{suspended | outcomes: Map.put(suspended.outcomes, final.ref, final)}
      assert {:ok, resolved} = MeterState.transition(suspended, c.data, unquote(operation))
      assert resolved.meters[c.act.mandate_ref][c.f.refs.meter].suspended == 0
      assert {:error, _} = MeterState.transition(resolved, c.data, unquote(operation))
    end
  end

  test "physical aliases share a balance but a dangling alias cannot create an allocation", c do
    ref = c.act.mandate_ref
    state = %{c.state | meter_owner_aliases: %{"successor" => ref, "broken" => "missing"}}
    assert MeterState.accounts(state, "successor") == MeterState.accounts(state, ref)
    assert {:error, {:meter_mandate_not_found, "broken"}} = MeterState.accounts(state, "broken")
    assert {:error, {:meter_owner_not_found, "unknown"}} = MeterState.owner(state, "unknown")
    {:ok, accounts} = MeterState.accounts(state, ref)
    assert {:ok, changed} = MeterState.put_accounts(state, "successor", accounts)
    assert changed.meters == state.meters
    refute Map.has_key?(changed.meters, "successor")
    assert {:error, _} = MeterState.put_accounts(state, "unknown", accounts)
  end

  test "account lookup rejects mismatched identities and malformed values", c do
    meter = c.f.refs.meter
    account = c.state.meters[c.act.mandate_ref][meter]

    assert {:error, {:meter_account_ref_mismatch, "other", ^meter}} =
             MeterState.account(%{"other" => account}, "other")

    assert {:error, {:invalid_meter_account, ^meter}} = MeterState.account(%{meter => %{}}, meter)
    assert {:error, {:meter_not_found, ^meter}} = MeterState.account(%{}, meter)
    assert {:error, _} = MeterState.transition_accounts(%{}, %{meter => 1}, :reserve, :unreserved)

    assert {:error, _} =
             MeterState.transition_accounts(
               %{meter => account},
               %{meter => 20_000},
               :reserve,
               :unreserved
             )
  end

  test "contradiction recontainment validates the correction and exact partition", c do
    no_effect = outcome(c, :definitive_no_effect)

    {:ok, released} =
      MeterState.transition(
        %{c.state | outcomes: %{no_effect.ref => no_effect}},
        c.data,
        :release
      )

    {:ok, correction} =
      outcome(c, :succeeded)
      |> Map.from_struct()
      |> Map.merge(%{ref: nil, contradicts_outcome_ref: no_effect.ref})
      |> Outcome.new()

    state = %{released | outcomes: Map.put(released.outcomes, correction.ref, correction)}

    data =
      Map.merge(c.data, %{
        "outcome_ref" => correction.ref,
        "recontained" => c.act.reservations,
        "deficits" => %{}
      })

    assert {:ok, restored} = MeterState.recontain(state, data)
    assert restored.meters[c.act.mandate_ref][c.f.refs.meter].suspended == 100
    assert restored.meter_recontainments[c.act.ref].outcome_ref == correction.ref

    for {changed, reason} <- [
          {Map.put(data, "outcome_ref", "missing"), :recontainment_outcome_not_found},
          {Map.put(data, "outcome_ref", no_effect.ref),
           :meter_recontainment_outcome_not_correction},
          {Map.put(data, "recontained", %{}), :invalid_meter_recontainment_partition},
          {Map.merge(data, %{"recontained" => %{}, "deficits" => c.act.reservations}),
           :meter_recontainment_balance_mismatch}
        ] do
      assert {:error, actual} = MeterState.recontain(state, changed)
      assert if(is_tuple(actual), do: elem(actual, 0), else: actual) == reason
    end

    assert {:error, {:meter_recontainment_requires_released_reservation, _, :reserved}} =
             MeterState.recontain(c.state, data)

    assert {:error, {:meter_recontainment_already_recorded, _}} =
             MeterState.recontain(
               %{state | meter_recontainments: restored.meter_recontainments},
               data
             )
  end

  test "terminal child devolution returns only its free quantity and cannot run twice", c do
    {state, data, child} = devolution(c)
    assert {:ok, next} = MeterState.devolve(state, data)
    assert next.meters[child.ref][c.f.refs.meter].available == 0
    assert next.meters[c.f.mandate.ref][c.f.refs.meter].available == 10_000
    assert {:error, {:meter_devolution_already_applied, _}} = MeterState.devolve(next, data)

    assert {:error, {:mandate_not_terminal_for_devolution, _}} =
             MeterState.devolve(
               put_in(state.acts[c.act.ref].committed_at, child.expires_at - 1),
               data
             )

    assert {:error, {:root_mandate_cannot_devolve, _}} =
             MeterState.devolve(state, Map.put(data, "child_mandate_ref", c.f.mandate.ref))

    assert {:error, :empty_meter_devolution} =
             MeterState.devolve(state, Map.put(data, "amounts", %{}))
  end

  for {field, value, reason} <- [
        {:class, "refund.issue", :meter_devolution_act_class_mismatch},
        {:row, %Row{}, :meter_devolution_act_row_mismatch},
        {:reservations, %{"meter" => 1}, :meter_devolution_act_has_reservations},
        {:target_refs, [], :meter_devolution_target_missing},
        {:consequence, %{}, :meter_devolution_consequence_mismatch}
      ] do
    test "devolution rejects a mismatched authorizing #{field}", c do
      {state, data, _child} = devolution(c)

      state =
        update_in(
          state.acts[c.act.ref],
          &Map.replace!(&1, unquote(field), unquote(Macro.escape(value)))
        )

      assert {:error, reason} = MeterState.devolve(state, data)
      assert elem(reason, 0) == unquote(reason)
    end
  end

  defp devolution(c) do
    {:ok, child} =
      c.f.mandate
      |> Map.from_struct()
      |> Map.merge(%{
        ref: nil,
        parent_ref: c.f.mandate.ref,
        grantor_ref: c.f.mandate.holder_ref,
        source_ref: "act:delegate",
        meters: %{c.f.refs.meter => 100}
      })
      |> Mandate.new()

    {:ok, parent_account, child_account} =
      Meter.delegate(Account.root(c.f.refs.meter, 10_000), Account.child(c.f.refs.meter), 100)

    amounts = %{c.f.refs.meter => 100}

    act = %{
      c.act
      | class: "mandate.devolve",
        row: %Row{delegate: true, govern: true},
        reservations: %{},
        committed_at: child.expires_at,
        target_refs: [child.ref],
        consequence: %{
          "mandate_devolve" => %{"child_mandate_ref" => child.ref, "amounts" => amounts}
        }
    }

    state = %{
      c.state
      | acts: %{act.ref => act},
        mandates: Map.put(c.state.mandates, child.ref, child),
        meters: %{
          c.f.mandate.ref => %{c.f.refs.meter => parent_account},
          child.ref => %{c.f.refs.meter => child_account}
        }
    }

    {state, %{"act_ref" => act.ref, "child_mandate_ref" => child.ref, "amounts" => amounts},
     child}
  end

  defp outcome(c, status),
    do: Fixture.outcome(c.f, c.act, c.attempt, status, ["evidence:receipt"])
end
