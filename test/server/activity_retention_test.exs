defmodule Spectre.Server.ActivityRetentionTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.Activities

  defmodule Worker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, Keyword.take(opts, [:name]))

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_info({:spectre_activity, :activate, _ref}, state), do: {:noreply, state}
  end

  defmodule Unavailable do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    def start_link(_opts), do: {:error, :fixture_unavailable}
  end

  test "terminal retention evicts the oldest command and keeps active reservations" do
    owner = start_supervised!({Activities, terminal_limit: 1})
    worker = {Worker, []}
    unavailable = {Unavailable, []}

    assert {:ok, reserved} = Activities.reserve(owner, "reserved", worker)
    assert {:ok, running} = Activities.start(owner, "running", worker)
    assert {:ok, failed} = Activities.reserve(owner, "failed", unavailable)
    assert {:ok, completed} = Activities.start(owner, "completed", worker)
    assert {:ok, %{pid: child}} = Activities.lookup(owner, completed)
    assert :ok = GenServer.stop(child)
    assert_completed(owner, completed, System.monotonic_time(:millisecond) + 2_000)

    assert {:error, :fixture_unavailable} = Activities.resume(owner, failed)
    assert {:ok, %{status: :failed}} = Activities.lookup(owner, failed)
    assert {:error, :fixture_unavailable} = Activities.start(owner, "failed", unavailable)

    assert {:error, :unknown_activity} = Activities.lookup(owner, completed)
    assert {:error, :unknown_activity} = Activities.resume(owner, completed)
    assert {:ok, replacement} = Activities.reserve(owner, "completed", worker)
    refute replacement == completed

    assert {:ok, ^reserved} = Activities.reserve(owner, "reserved", worker)
    assert {:ok, %{status: :reserved}} = Activities.lookup(owner, reserved)
    assert {:ok, ^running} = Activities.start(owner, "running", worker)
    assert {:ok, %{status: :running, pid: running_child}} = Activities.lookup(owner, running)
    assert Process.alive?(running_child)
  end

  test "zero terminal retention still delivers the outcome of a rejected start" do
    owner = start_supervised!({Activities, terminal_limit: 0})
    specification = {Unavailable, []}

    assert {:ok, ref} = Activities.reserve(owner, "rejected", specification)
    assert {:error, :fixture_unavailable} = Activities.resume(owner, ref)
    assert {:error, :unknown_activity} = Activities.lookup(owner, ref)
    assert {:ok, replacement} = Activities.reserve(owner, "rejected", specification)
    refute replacement == ref
  end

  defp assert_completed(owner, ref, deadline) do
    case Activities.lookup(owner, ref) do
      {:ok, %{status: :completed}} ->
        :ok

      status ->
        assert System.monotonic_time(:millisecond) < deadline,
               "activity did not complete: #{inspect(status)}"

        :erlang.yield()
        assert_completed(owner, ref, deadline)
    end
  end
end
