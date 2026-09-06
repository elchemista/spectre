defmodule Spectre.Core.HostBoundaryContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Clock
  alias Spectre.Execution.Boundary

  defmodule Ports do
    def executor_ref, do: reply(:executor_ref, "executor:host")
    def contract_ref, do: reply(:contract_ref, "contract:host")
    def execute(_act, _attempt, _capability, _opts), do: reply(:execute, :ok)
    def ref, do: reply(:ref, "broker:host")
    def profile, do: reply(:profile, :mediated)
    def checkout(_receipt, _act, _attempt, _opts), do: reply(:checkout, :ok)
    def now, do: reply(:now, 10)

    defp reply(callback, default) do
      case Process.get({__MODULE__, callback}, {:return, default}) do
        {:return, value} -> value
        :raise -> raise "secret-credential"
        :exit -> exit("secret-credential")
        :throw -> throw("secret-credential")
      end
    end
  end

  test "normalized execution routes retain host configuration but descriptions never expose it" do
    assert {:ok, boundary} =
             Boundary.normalize([{Ports, token: "private"}], {Ports, password: "private"})

    assert boundary.routes[{"executor:host", "contract:host"}].executor_opts == [token: "private"]
    assert boundary.broker.broker_opts == [password: "private"]
    description = Boundary.describe(boundary)
    refute inspect(description) =~ "private"
    assert description.broker == %{module: Ports, ref: "broker:host", profile: :mediated}
    assert {:ok, empty} = Boundary.normalize([], nil)
    assert Boundary.describe(empty) == %{executors: [], broker: nil}
    assert {:error, :execution_broker_required} = Boundary.normalize([Ports], nil)

    assert {:error, {:duplicate_executor_route, _}} =
             Boundary.normalize([Ports, {Ports, token: "other"}], Ports)
  end

  test "profiles have an explicit strength ordering, not arbitrary atom ordering" do
    profiles = [:development, :mediated, :isolated]

    for {actual, actual_rank} <- Enum.with_index(profiles),
        {required, required_rank} <- Enum.with_index(profiles) do
      assert Boundary.profile_covers?(actual, required) == actual_rank >= required_rank
    end

    refute Boundary.profile_covers?(:unknown, :development)
    refute Boundary.profile_covers?(:isolated, :unknown)
  end

  test "runtime routes reject extra metadata and malformed callback options" do
    route = %{
      executor: Ports,
      executor_opts: [],
      broker: Ports,
      broker_opts: [],
      broker_descriptor: %{ref: "broker", profile: :mediated}
    }

    assert :ok = Boundary.validate_runtime_route(route)

    assert {:error, :invalid_execution_route} =
             Boundary.validate_runtime_route(Map.put(route, :grant, "smuggled"))

    for field <- [:executor_opts, :broker_opts],
        value <- [nil, %{}, [:invalid], [{:token, 1} | :tail]] do
      assert {:error, {:invalid_keyword_options, ^field}} =
               Boundary.validate_runtime_route(Map.put(route, field, value))
    end

    for descriptor <- [
          %{ref: "", profile: :mediated},
          %{ref: "r", profile: :other},
          %{ref: "r", profile: :mediated, secret: "x"},
          nil
        ] do
      assert {:error, :invalid_broker_descriptor} =
               Boundary.validate_broker_descriptor(descriptor)
    end
  end

  test "malformed host adapters fail at configuration rather than first execution" do
    for executors <- [
          nil,
          %{},
          [42],
          [{Ports, %{}}],
          [{Ports, [:invalid]}],
          [nil],
          [true],
          [NoSuchSpectreExecutor],
          [String],
          [Ports | :tail]
        ] do
      assert {:error, _} = Boundary.normalize(executors, Ports)
    end

    for broker <- [
          42,
          %{},
          {Ports, %{}},
          {Ports, [:invalid]},
          {nil, []},
          String,
          NoSuchSpectreBroker
        ] do
      assert {:error, _} = Boundary.normalize([Ports], broker)
    end
  end

  for {callback, boundary} <- [
        executor_ref: :executor,
        contract_ref: :executor,
        ref: :broker,
        profile: :broker
      ],
      {fault, expected} <- [raise: :exception, throw: :throw, exit: :exit] do
    test "#{callback} #{fault} fails closed without exposing callback secrets" do
      Process.put({Ports, unquote(callback)}, unquote(fault))

      assert {:error, {unquote(boundary), {unquote(callback), unquote(expected)}}} =
               Boundary.normalize([Ports], Ports)
    end
  end

  for callback <- [:executor_ref, :contract_ref, :ref, :profile] do
    test "#{callback} must return a valid stable descriptor" do
      for value <- [nil, 1, %{}, ""] do
        Process.put({Ports, unquote(callback)}, {:return, value})
        assert {:error, _} = Boundary.normalize([Ports], Ports)
      end
    end
  end

  test "executor and broker invocation classify failures without copying the payload" do
    for callback <- [:execute, :checkout],
        {fault, expected} <- [raise: :exception, throw: :throw, exit: :exit] do
      Process.put({Ports, callback}, fault)
      assert Boundary.invoke(Ports, callback, [nil, nil, nil, []]) == {:error, expected}
    end
  end

  test "trusted clocks reject floats, negative readings and invalid adapters" do
    assert {:ok, 10} = Clock.read(Ports)

    for value <- [-1, 0.0, nil, "10", %{}] do
      Process.put({Ports, :now}, {:return, value})
      assert {:error, :invalid_clock_value} = Clock.read(Ports)
    end

    for source <- [nil, true, false, "clock", %{}] do
      assert {:error, :invalid_clock_source} = Clock.read(source)
    end

    Process.put({Ports, :now}, :raise)
    assert {:error, {:adapter_callback_exception, Ports, :now, RuntimeError}} = Clock.read(Ports)
    assert {:error, _} = Clock.read(NoSuchSpectreClock)
  end
end
