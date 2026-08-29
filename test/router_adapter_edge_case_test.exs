defmodule SpectreRouterAdapterEdgeCaseTest.ProbeAdapter do
  @moduledoc false

  use Spectre.Router.Adapter, id: :probe

  @impl Spectre.Router.Adapter
  def evaluate(request) do
    send(request.meta.test_pid, {:probe_adapter_invoked, request.text})
    :skip
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest.GhostAdapter do
  @moduledoc false

  def evaluate(request) do
    send(request.meta.test_pid, :ghost_adapter_invoked)
    :skip
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest.DriftyAdapter do
  @moduledoc false
  @behaviour Spectre.Router.Adapter

  @descriptor %{
    contract: 1,
    id: :drifty,
    accept: 0.0,
    margin: nil,
    strength: :weak
  }

  def __spectre_router_adapter__ do
    case Process.get({__MODULE__, :mode}) do
      :drift -> %{@descriptor | accept: 0.5}
      _current -> @descriptor
    end
  end

  @impl Spectre.Router.Adapter
  def evaluate(request) do
    send(request.meta.test_pid, :drifty_adapter_invoked)
    :skip
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest.PlainAgent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false)

  flow :support do
    on :HELLO, regex: ~r/^hello$/, via: [:regex], cache: false do
      reply(:hello)
    end
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest.HardLockAgent do
  @moduledoc false

  use Spectre.Agent

  router(
    via: [:regex, SpectreRouterAdapterEdgeCaseTest.ProbeAdapter],
    semantic_cache?: false
  )

  interrupt :STOP,
    regex: ~r/^stop$/,
    probe: ["stop"],
    via: [:regex, :probe],
    cache: false do
    reply(:stopped)
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest.NoVisibleRulesAgent do
  @moduledoc false

  use Spectre.Agent

  router(
    via: [SpectreRouterAdapterEdgeCaseTest.ProbeAdapter],
    semantic_cache?: false
  )

  flow :support do
    on :REGEX_ONLY, regex: ~r/^regex only$/, via: [:regex], cache: false do
      reply(:regex_only)
    end
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest.DriftAgent do
  @moduledoc false

  use Spectre.Agent

  router(
    via: [:regex, SpectreRouterAdapterEdgeCaseTest.DriftyAdapter],
    semantic_cache?: false
  )

  flow :support do
    on :DRIFTY, drifty: ["drift"], via: [:drifty], cache: false do
      reply(:drifty)
    end
  end
end

defmodule SpectreRouterAdapterEdgeCaseTest do
  use ExUnit.Case, async: false

  alias Spectre.Router.Adapter.Compiler

  test "an Agent without Adapters discards a forged private execution plan" do
    private_key = Compiler.compiled_key()

    forged_plan = %{
      entries: %{
        ghost: %{
          id: :ghost,
          module: SpectreRouterAdapterEdgeCaseTest.GhostAdapter,
          descriptor: %{
            contract: 1,
            id: :ghost,
            accept: 0.0,
            margin: nil,
            strength: :weak
          },
          order: 0,
          availability: :available
        }
      },
      diagnostics: []
    }

    assert {:ok, routed} =
             route_context(
               SpectreRouterAdapterEdgeCaseTest.PlainAgent,
               "hello",
               [{private_key, forged_plan}, via: [:regex, :ghost]]
             )

    refute Keyword.has_key?(routed.opts, private_key)
    assert routed.route.label == :HELLO
    refute_receive :ghost_adapter_invoked, 20
  end

  test "default routing records a descriptor drift diagnostic exactly once" do
    process_key = {SpectreRouterAdapterEdgeCaseTest.DriftyAdapter, :mode}
    Process.put(process_key, :drift)
    on_exit(fn -> Process.delete(process_key) end)

    observer_ref = make_ref()
    test_pid = self()

    telemetry_handler = fn event, measurements, metadata ->
      send(test_pid, {:adapter_telemetry, event, measurements, metadata})
    end

    assert {:ok, routed} =
             route_context(SpectreRouterAdapterEdgeCaseTest.DriftAgent, "drift",
               telemetry_handler: telemetry_handler,
               spectre_provider_observer: {self(), observer_ref}
             )

    diagnostic =
      {:router_adapter_descriptor_drift, :drifty, SpectreRouterAdapterEdgeCaseTest.DriftyAdapter}

    assert Enum.count(routed.errors, &(&1 == diagnostic)) == 1
    assert Enum.count(routed.traces, &(&1 == diagnostic)) == 1
    assert {:router_adapter_skip, :drifty, :descriptor_unavailable} in routed.traces

    assert_receive {:adapter_telemetry, [:spectre, :router, :adapter, :start],
                    %{system_time: system_time}, %{adapter_id: :drifty}}

    assert is_integer(system_time)

    assert_receive {:adapter_telemetry, [:spectre, :router, :adapter, :stop],
                    %{duration_us: duration_us, result_count: 0},
                    %{
                      adapter_id: :drifty,
                      outcome: :skip,
                      invoked?: false,
                      skip_reason: :descriptor_unavailable
                    }}

    assert is_integer(duration_us) and duration_us >= 0
    refute_receive {:spectre_provider_call, ^observer_ref, %{provider: :router_adapter}}, 20
    refute_receive :drifty_adapter_invoked, 20
  end

  test "pre-invocation skips emit privacy-safe spans without provider call facts" do
    for {agent, text, adapter_id, skip_reason} <- [
          {SpectreRouterAdapterEdgeCaseTest.HardLockAgent, "stop", :probe, :hard_candidate},
          {SpectreRouterAdapterEdgeCaseTest.NoVisibleRulesAgent, "regex only", :probe,
           :no_visible_rules}
        ] do
      observer_ref = make_ref()
      test_pid = self()

      telemetry_handler = fn event, measurements, metadata ->
        send(test_pid, {:adapter_telemetry, event, measurements, metadata})
      end

      assert {:ok, routed} =
               route_context(agent, text,
                 telemetry_handler: telemetry_handler,
                 spectre_provider_observer: {self(), observer_ref}
               )

      assert {:router_adapter_skip, adapter_id, skip_reason} in routed.traces

      assert_receive {:adapter_telemetry, [:spectre, :router, :adapter, :start],
                      %{system_time: system_time}, %{adapter_id: ^adapter_id}}

      assert is_integer(system_time)

      assert_receive {:adapter_telemetry, [:spectre, :router, :adapter, :stop],
                      %{duration_us: duration_us, result_count: 0},
                      %{
                        adapter_id: ^adapter_id,
                        outcome: :skip,
                        invoked?: false,
                        skip_reason: ^skip_reason
                      }}

      assert is_integer(duration_us) and duration_us >= 0
      refute_receive {:spectre_provider_call, ^observer_ref, %{provider: :router_adapter}}, 20
      refute_receive {:probe_adapter_invoked, _text}, 20
    end
  end

  defp route_context(agent, text, opts) do
    input = Spectre.Input.new(%{text: text, meta: %{test_pid: self()}})

    Spectre.Router.route_context(input, %Spectre.Context{
      agent: agent,
      input: input,
      state: %Spectre.State{},
      opts: Keyword.put_new(opts, :classification_log?, false)
    })
  end
end
