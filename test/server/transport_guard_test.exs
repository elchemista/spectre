defmodule Spectre.Server.TransportGuardTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.Stream
  alias Spectre.Inference.ProviderEvent

  defmodule Transport do
    def capabilities(_, _), do: MapSet.new([:stream, :pull_transport])

    def open(_, opts) do
      send(opts[:observer], {:opened, self()})
      {:ok, %{observer: opts[:observer], phase: 0}, %{}}
    end

    def request_transport_item(%{phase: 0} = state) do
      send(self(), {:chunk, ProviderEvent.delta("provisional")})
      {:ok, %{state | phase: 1}}
    end

    def request_transport_item(state), do: {:ok, state}
    def handle_transport({:chunk, event}, state), do: {:ok, [event], state}
    def handle_transport(_, state), do: {:ignore, state}

    def cancel(state, _) do
      send(state.observer, {:cancelled, state.phase})
      :ok
    end
  end

  defp start_stream(timeout) do
    observer = self()

    {:ok, worker} =
      Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
        Stream.run(
          %{
            selection: %{level: :test, model: Transport},
            descriptor: %{id: "generation"},
            provider_opts: []
          },
          %{planning: false, preview: :auto},
          %{consumer: observer, runtime: observer, interaction: "input"},
          stream_adapter: {Transport, observer: observer},
          stream_stall_timeout: timeout
        )
      end)

    assert_receive {:opened, ^worker}, 2_000

    assert_receive {Spectre.Server, ^observer, {:preview, "input", "generation", "provisional"}},
                   2_000

    worker
  end

  test "killing a stream worker cancels its latest transport and invalidates provisional output" do
    worker = start_stream(30_000)
    Process.exit(worker, :kill)
    owner = self()

    assert_receive {Spectre.Server, ^owner,
                    {:preview_end, "input", "generation", {:error, :stream_interrupted}}},
                   2_000

    assert_receive {:cancelled, 1}, 2_000
    refute_receive {:cancelled, _}
  end

  test "a provider stall closes transport and reports the provisional generation as failed" do
    start_stream(50)
    owner = self()

    assert_receive {Spectre.Server, ^owner,
                    {:preview_end, "input", "generation", {:error, :provider_stall_timeout}}},
                   2_000

    assert_receive {:cancelled, 1}, 2_000
    refute_receive {:cancelled, _}
  end
end
