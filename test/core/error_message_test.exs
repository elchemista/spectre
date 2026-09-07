defmodule Spectre.CoreTest.ErrorMessageTest do
  use ExUnit.Case, async: true

  alias Spectre.Error

  defmodule UnsafeException do
    defexception [:recipient]
    @impl true
    def message(exception) do
      send(exception.recipient, :exception_formatted)
      "secret provider response"
    end
  end

  test "common reasons have useful descriptions without altering the original terms" do
    reason = {:candidate_template_override, [:executor_ref, :row]}
    assert Error.message(reason) == Error.message({:error, reason})
    assert Error.message(reason) =~ "override"
    assert reason === {:candidate_template_override, [:executor_ref, :row]}
    assert Error.message(:instance_busy) =~ "queue"
    assert Error.message(:ambiguous) =~ "Do not assume no effect"
    assert Error.message({:instance_operation_stopped, :propose}) =~ "does not prove"
  end

  test "nested errors, credentials and attacker-controlled reason tags are never rendered" do
    secret = "SUPER-PRIVATE-CREDENTIAL"

    for reason <- [
          {:genesis_verifier_failed, secret},
          {:unknown, %{token: secret}},
          {secret, :failed},
          {:error, {:unknown, [secret]}},
          secret,
          %{payload: secret},
          fn -> secret end
        ] do
      text = Error.message(reason)
      assert is_binary(text)
      refute text =~ secret
      assert byte_size(text) < 200
    end
  end

  test "formatting does not invoke exception protocols or inspect callback data" do
    exception = %UnsafeException{recipient: self()}
    assert Error.message(exception) == Error.message(%{})
    assert Error.message({:ingress_worker_failed, exception}) =~ "ingress worker"
    refute_receive :exception_formatted
  end

  test "unknown structures get one bounded fallback, not a recursively expanded diagnostic" do
    nested = Enum.reduce(1..1000, :secret, fn _, value -> {:error, value} end)
    fallback = Error.message(:unrecognized)
    assert Error.message(nested) == fallback
    assert Error.message({}) == fallback
    assert Error.message({%{secret: :binary.copy("x", 100_000)}, :unknown}) == fallback
  end
end
