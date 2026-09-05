defmodule Spectre.CoreTest.ValidationTest do
  use ExUnit.Case, async: true

  alias Spectre.Validation

  test "empty and successful enumerables validate without changing values" do
    assert :ok = Validation.all([], fn _ -> flunk("must not run") end)

    assert :ok =
             Validation.all(1..3, fn value ->
               send(self(), {:validated, value})
               :ok
             end)

    assert_receive {:validated, 1}
    assert_receive {:validated, 2}
    assert_receive {:validated, 3}
  end

  test "halts a lazy enumerable at the first error and preserves the error" do
    items =
      Stream.map(1..10, fn value ->
        send(self(), {:enumerated, value})
        value
      end)

    assert {:error, {:invalid, 2}} =
             Validation.all(items, fn
               2 -> {:error, {:invalid, 2}}
               _ -> :ok
             end)

    assert_receive {:enumerated, 1}
    assert_receive {:enumerated, 2}
    refute_received {:enumerated, 3}
  end
end
