defmodule Spectre.Agents.InstanceWaitTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Instance

  @moduletag gated: true, capture_log: true

  for ending <- [:completed, :worker_crash] do
    test "#{ending} cancels its long wait timer instead of retaining it until expiry", c do
      {_turn, request} = prepare(c, "refund 20")
      submission = Task.async(fn -> Instance.advance(c.instance, request, wait: 60_000) end)
      assert_receive {:handler_execution, executor, _act, _attempt}, 1_000

      # Inspect ownership only; no fabricated state or guessed sleeps. The
      # executor barrier keeps the real operation and its reply timer alive.
      timer = :sys.get_state(c.instance).operations[request.ref].timer
      assert is_reference(timer)
      assert is_integer(Process.read_timer(timer))

      if unquote(ending) == :completed do
        send(executor, :release)
        assert {:ok, %{result: %{status: :done}}} = Task.await(submission)
      else
        Process.exit(executor, :kill)
        assert {:error, {:instance_operation_stopped, :advance}} = Task.await(submission)
      end

      assert Process.read_timer(timer) == false
      refute Instance.info(c.instance).busy?
      refute_received {:handler_execution, _, _, _}
      assert_replay(c)
    end
  end

  test "an unsupported timer value rejects the call without killing the owner or reserving its ticket",
       c do
    {_turn, request} = prepare(c, "refund 20")
    before = Instance.state(c.instance)

    reply =
      try do
        Instance.advance(c.instance, request, wait: Integer.pow(2, 100))
      catch
        :exit, reason -> {:caller_exit, reason}
      end

    assert reply == {:error, :invalid_instance_advance_options}
    assert Process.alive?(c.instance)
    assert Instance.state(c.instance) === before
    assert Instance.current_turn(c.instance).requests == [request]
    refute_received {:handler_execution, _, _, _}

    submission = Task.async(fn -> Instance.advance(c.instance, request, wait: :infinity) end)
    assert_receive {:handler_execution, executor, _act, _attempt}, 1_000
    send(executor, :release)
    assert {:ok, %{result: %{status: :done}}} = Task.await(submission)
    assert_replay(c)
  end
end
