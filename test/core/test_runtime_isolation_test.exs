defmodule Spectre.CoreTest.TestRuntimeIsolationTest do
  use ExUnit.Case, async: false

  alias Spectre.V04Test.{Fixture, Runtime}

  test "resetting fixture time never reissues an occurrence identifier" do
    Runtime.reset(Fixture.default_now())
    first = Runtime.next_id()
    Runtime.reset(Fixture.default_now())
    second = Runtime.next_id()
    assert Spectre.Id.valid?(first)
    assert Spectre.Id.valid?(second)
    refute first == second
  end

  test "clock reset remains readable by concurrent reconciliation and identifier callers" do
    now = Fixture.default_now()
    Runtime.reset(now)

    resetter = Task.async(fn -> repeat(fn -> Runtime.reset(now) end) end)

    readers =
      for _reader <- 1..4 do
        Task.async(fn ->
          repeat(fn ->
            assert Runtime.now() == now
            assert Spectre.Id.valid?(Runtime.next_id())
          end)
        end)
      end

    for task <- [resetter | readers], do: send(task.pid, :start)
    for task <- [resetter | readers], do: Task.await(task)
  end

  defp repeat(callback) do
    receive do: (:start -> :ok)
    for _iteration <- 1..2_000, do: callback.()
    :ok
  end
end
