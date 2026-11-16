Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.CommandDurabilityBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Domain.Command.{Durability, Input}
  alias Spectre.GAM.Domain.Command.Evidence, as: EvidenceCommand
  alias Spectre.GAM.Domain.{Configuration, Event, Transaction}
  alias Spectre.GAM.Domain.Sequencer.State
  alias Spectre.GAM.Ledger.Store.Mock
  alias Spectre.GAM.V04Test.Fixture

  defmodule InvalidId do
    def generate, do: :not_an_identifier
  end

  defmodule BrokenClock do
    def now, do: raise(ArgumentError, "private clock detail")
  end

  setup c do
    mock = start_supervised!({Mock, store: c.f.store_config})

    {:ok, config} =
      Configuration.new(
        c.f.sequencer_opts
        |> Keyword.put(:store, {Mock, server: mock})
        |> Keyword.put(:projection_store, nil)
      )

    %{state: State.new(config, c.attempted), mock: mock}
  end

  test "CAS recovery hands the new prefix to planning exactly once and consumes a retry", c do
    :ok = Mock.push(c.mock, {:append, :before, {:error, :conflict}})

    assert {:ok, state, :replan} =
             append(c, 2, fn recovered, left ->
               assert left == 1
               assert recovered.projection === c.attempted
               {:ok, recovered, :replan}
             end)

    assert state.halted_reason == nil
    assert Fixture.snapshot(c.f).revision == c.attempted.revision
    assert Enum.count(Mock.calls(c.mock), &(&1.operation == :append)) == 1
  end

  test "exhausted conflicts halt, while ordinary storage rejection leaves a usable prefix", c do
    :ok = Mock.push(c.mock, {:append, :before, {:error, :disk_full}})
    assert {:error, state, :disk_full} = append(c, 0)
    assert state === c.state
    refute_received {:stop_halted, _}
    :ok = Mock.push(c.mock, {:append, :before, {:error, :conflict}})
    assert {:error, halted, :conflict_retries_exhausted} = append(c, 0)
    assert halted.halted_reason == :conflict_retries_exhausted
    assert_receive {:stop_halted, :conflict_retries_exhausted}
    assert Fixture.snapshot(c.f).revision == c.attempted.revision
  end

  test "failed recovery cannot retry using the obsolete projection", c do
    :ok =
      Mock.push(c.mock, [
        {:append, :before, {:error, :conflict}},
        {:load_from, :before, {:error, :unreadable_history}}
      ])

    assert {:error, halted, {:durable_recovery_failed, :unreadable_history}} = append(c, 1)
    assert halted.halted_reason == :unreadable_history
    assert_receive {:stop_halted, :unreadable_history}
  end

  test "identifier and preflight clock faults fail before touching storage", c do
    assert {:error, _, {:invalid_operational_identifier, :atom}} =
             append(%{c | state: %{c.state | id_source: InvalidId}}, 0)

    state = %{c.state | clock: BrokenClock}
    assert {:error, halted, {:preflight_duty_repair_failed, reason}} = Durability.preflight(state)
    assert match?({:trusted_clock_failed, _}, reason)
    assert halted.projection === c.attempted
    assert_receive {:stop_halted, {:preflight_duty_repair_failed, ^reason}}
    assert Mock.calls(c.mock) == []
  end

  test "Evidence recording preserves requested shape, deduplicates persistence and is idempotent",
       c do
    assert {:ok, next, [receipt, same]} = EvidenceCommand.record(c.state, [c.receipt, c.receipt])
    assert receipt === same
    assert receipt === c.receipt
    assert next.projection.revision == c.state.projection.revision + 1
    assert {:ok, ^next, ^receipt} = EvidenceCommand.record(next, receipt)
    assert {:ok, ^next, [^receipt]} = EvidenceCommand.record(next, [receipt])
    assert Enum.count(Mock.calls(c.mock), &(&1.operation == :append)) == 1
    assert {:error, :invalid_evidence_input} = EvidenceCommand.normalize([])
    assert {:error, :invalid_evidence_input} = EvidenceCommand.normalize(nil)
    assert {:error, _} = EvidenceCommand.normalize([receipt, %{}])

    assert {:ok, _, [^receipt]} =
             Input.record_executor_evidence(next, c.act.ref, c.attempt.ref, [receipt])
  end

  test "Evidence acquisition and Scope checks precede append", c do
    {:ok, future} =
      Spectre.GAM.Evidence.new(%{c.receipt | ref: nil, observed_at: c.act.committed_at + 1})

    assert {:error, same, {:evidence_from_future, ref, _}} =
             EvidenceCommand.record(c.state, future)

    assert ref == future.ref
    assert same === c.state
    assert {:error, ^same, _} = Input.finish_observation(c.state, nil, c.receipt)
    assert {:error, ^same, _} = Input.finish_turn(c.state, nil, c.receipt, [])

    assert {:error, ^same, _} =
             Input.record_executor_evidence(c.state, "missing-act", c.attempt.ref, [c.receipt])

    assert Mock.calls(c.mock) == []
    assert {:ok, now} = Transaction.trusted_recorded_at(c.state)
    assert now == c.act.committed_at
  end

  defp append(c, retries, on_conflict \\ fn _, _ -> flunk("unexpected replanning") end) do
    {:ok, payload} = Event.record(:evidence, c.receipt)

    Durability.append(
      c.state,
      [payload],
      c.act.committed_at,
      retries,
      fn projection -> {:ok, %{c.state | projection: projection}, :committed} end,
      on_conflict
    )
  end
end
