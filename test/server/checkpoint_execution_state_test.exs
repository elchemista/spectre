defmodule Spectre.Server.CheckpointExecutionStateTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.{Checkpoint, Command}

  defmodule App do
    use Spectre.Server
  end

  defmodule Agent do
    use Spectre.Agent, server: App
  end

  @governed [:confirm_pending, :reject_pending, :explain_pending, :resume_pending]

  @tag :tmp_dir
  test "only known unstarted consent commands avoid conservative recovery uncertainty", c do
    entries =
      for kind <- @governed,
          {marker, started, expected} <- [
            {:started, true, :uncertain},
            {:unstarted, false, :suspended},
            {:legacy, :missing, :uncertain}
          ] do
        id = "#{kind}:#{marker}"
        entry = command(kind, id)

        entry =
          if started == :missing, do: entry, else: Map.put(entry, :execution_started, started)

        {id, pending(id, :consent), entry, expected}
      end

    {saved, restored} = roundtrip(c.tmp_dir, entries)

    for {id, original, _entry, expected} <- entries do
      assert restored.pending[id].status == expected
      assert Map.drop(restored.pending[id], [:status]) == Map.drop(original, [:status])
    end

    assert restored.foreground == nil
    assert restored.outbox == saved.outbox
    assert Enum.count(restored.pending, fn {_id, p} -> p.status == :uncertain end) == 8
  end

  @tag :tmp_dir
  test "lifecycle phases, blocked continuations and local reply resumes do not claim an external attempt",
       c do
    wrappers =
      for stage <- [:requested, :report] do
        id = "wrapper:#{stage}"
        entry = command(:resume_pending, id) |> Map.put(:lifecycle, %{stage: stage})
        {id, pending(id, :consent), entry, :suspended}
      end

    blocked =
      {"blocked", pending("blocked", :consent),
       command(:explain_pending, "blocked") |> Map.put(:blocked_by, "wrapper:requested"),
       :suspended}

    replies =
      for started <- [true, false, :missing] do
        id = "reply:#{started}"
        entry = command(:resume_pending, id)

        entry =
          if started == :missing, do: entry, else: Map.put(entry, :execution_started, started)

        {id, pending(id, :reply), entry, :suspended}
      end

    {saved, restored} = roundtrip(c.tmp_dir, wrappers ++ [blocked | replies])
    assert Enum.all?(restored.pending, fn {_id, p} -> p.status == :suspended end)
    assert restored.foreground == nil
    assert restored.outbox == saved.outbox
  end

  @tag :tmp_dir
  test "an actual started command keeps a shared pending uncertain despite other unstarted commands",
       c do
    {store, base} = store_state(c.tmp_dir)
    item = pending("shared", :consent)
    started = command(:confirm_pending, item.id) |> Map.put(:execution_started, true)
    unstarted = command(:resume_pending, item.id) |> Map.put(:execution_started, false)

    saved = %{
      base
      | pending: %{item.id => item},
        outbox: %{"started" => started, "next" => unstarted}
    }

    Checkpoint.save(saved)
    restored = Checkpoint.load(state(store))
    assert restored.pending[item.id].status == :uncertain
    assert restored.outbox == saved.outbox
    assert restored.pending[item.id].close_schedule == item.close_schedule
  end

  # These fixtures exercise only portable coordination projection. They carry
  # no GAM proof and never submit a Candidate or fabricate an authorized Act.
  defp pending(id, kind) do
    %{
      id: id,
      kind: kind,
      status: :resolving,
      origin: nil,
      revision: 3,
      close_schedule: %{
        command_id: "original-schedule",
        revision: 3,
        deadline: 9_999_999_999_999,
        reason: :idle_timeout,
        timer_owner: :runtime
      }
    }
  end

  defp command(kind, id), do: %{command: %Command{kind: kind, args: [id]}, event: nil}

  defp roundtrip(directory, entries) do
    {store, base} = store_state(directory)
    pending = Map.new(entries, fn {id, item, _entry, _expected} -> {id, item} end)
    outbox = Map.new(entries, fn {id, _item, entry, _expected} -> {id, entry} end)
    saved = %{base | pending: pending, outbox: outbox}
    Checkpoint.save(saved)
    {saved, Checkpoint.load(state(store))}
  end

  defp store_state(directory) do
    store =
      start_supervised!({Spectre.Server.Store.Disk, path: Path.join(directory, "state.snapshot")})

    {store, state(store)}
  end

  defp state(store) do
    %{
      agent: Agent,
      server: App,
      identity: %{},
      assigns: %{},
      opts: [checkpoint: {store, "execution"}],
      pending: %{},
      outbox: %{},
      inbox: %{},
      seen_events: %{},
      seen_event_order: [],
      operations: %{},
      dead_letters: %{},
      sequence: 1,
      history: [],
      current_flow: nil,
      current_scope: nil,
      current: nil,
      queue: :queue.new(),
      foreground: nil,
      checkpoint_revision: nil
    }
  end
end
