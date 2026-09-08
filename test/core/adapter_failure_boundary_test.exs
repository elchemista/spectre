defmodule Spectre.CoreTest.AdapterFailureBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Adapter

  defmodule UnsafeException do
    defexception [:recipient]
    @impl true
    def message(exception) do
      send(exception.recipient, :exception_formatted)
      "secret provider response"
    end
  end

  defmodule Callback do
    def fail(recipient), do: raise(UnsafeException, recipient: recipient)
    def throw_private(data), do: throw(data)
    def exit_private(data), do: exit(data)
    def return_reason(reason), do: {:error, reason}
  end

  test "callback exceptions are identified without invoking message formatting" do
    assert Adapter.invoke(Callback, :fail, [self()]) ===
             {:error, {:adapter_callback_exception, Callback, :fail, UnsafeException}}

    refute_receive :exception_formatted
  end

  test "exit and throw details do not cross the adapter boundary" do
    private = %{token: "PRIVATE", transcript: :binary.copy("x", 100_000)}

    assert Adapter.invoke(Callback, :throw_private, [private]) ===
             {:error, {:adapter_callback_failure, Callback, :throw_private, :throw}}

    assert Adapter.invoke(Callback, :exit_private, [private]) ===
             {:error, {:adapter_callback_failure, Callback, :exit_private, :exit}}
  end

  test "ordinary structured errors remain data for the domain-specific boundary" do
    reason = {:conflict, %{expected: 3, actual: 4}}
    assert Adapter.invoke(Callback, :return_reason, [reason]) === {:ok, {:error, reason}}
  end
end
