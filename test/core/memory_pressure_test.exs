Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)

defmodule Spectre.Core.MemoryPressureTest do
  use ExUnit.Case, async: false

  alias Spectre.Bench.P1.Fixture
  alias Spectre.Canonical.Value
  alias Spectre.Domain.Sequencer
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.ETS
  alias Spectre.Portable

  # Build hostile terms INSIDE monitored workers. The heap ceiling is a GC
  # safeguard, not an OS/RSS quota; binary sharing is included where supported
  # by the supported OTP runtime. Inputs are also independently size-bounded:
  # even an encoder that ignores every limit cannot expand past 64 MiB here.
  @heap_words 262_144
  @timeout 5_000

  setup do
    assert {:ok, _} = Value.encode(nil)
    :ok
  end

  test "deep input hits the depth limit without exhausting an isolated worker" do
    result =
      isolated(fn ->
        nested = Enum.reduce(1..10_000, nil, fn _, value -> [value] end)
        Value.encode(nested)
      end)

    assert {:returned, {:error, {:canonical_depth_exceeded, path, 128}}} = result
    assert length(path) == 129
  end

  test "oversized collections stop under the configured collection bound" do
    for build <- [
          fn -> List.duplicate(nil, 10_001) end,
          fn -> List.to_tuple(List.duplicate(nil, 10_001)) end,
          fn -> Map.new(1..10_001, &{&1, nil}) end
        ] do
      assert {:returned, {:error, {:canonical_collection_too_large, [], count, 1_000}}} =
               isolated(fn -> Value.encode(build.(), max_collection_size: 1_000) end)

      assert count > 1_000
    end
  end

  test "tiny wire inputs cannot force allocation from forged collection lengths" do
    for tag <- [0x20, 0x21, 0x22] do
      assert {:returned,
              {:error, {:canonical_collection_too_large, [], 4_294_967_295, 1_000_000}}} =
               isolated(fn -> Value.decode(<<"SPCV", 1, tag, 4_294_967_295::32>>) end)
    end

    for tag <- [0x10, 0x12, 0x13] do
      assert {:returned, {:error, {:truncated_canonical_value, _kind}}} =
               isolated(fn -> Value.decode(<<"SPCV", 1, tag, 4_294_967_295::32>>) end)
    end
  end

  test "decode checks the total wire size before expanding the value" do
    assert {:returned, {:error, {:canonical_value_too_large, 4_096, 1_024}}} =
             isolated(fn -> Value.decode(:binary.copy(<<0>>, 4_096), max_bytes: 1_024) end)
  end

  test "unknown atom names do not fill the VM-wide non-collectable atom table" do
    prefix = "spectre_memory_attack_#{System.unique_integer([:positive])}_"
    warmup = prefix <> "warmup"
    assert {:error, {:unknown_canonical_atom, [], ^warmup}} = Value.decode(atom_wire(warmup))
    before = :erlang.system_info(:atom_count)

    for index <- 1..1_000 do
      name = prefix <> Integer.to_string(index)
      assert {:error, {:unknown_canonical_atom, [], ^name}} = Value.decode(atom_wire(name))
    end

    assert :erlang.system_info(:atom_count) == before
  end

  test "oversized batch count leaves the store usable and publishes no partial prefix" do
    server = start_supervised!(ETS)
    store = {ETS, server: server}
    payloads = List.duplicate(%{"value" => true}, Entry.max_batch_entries() + 1)

    assert {:error, {:ledger_batch_too_large, 10_001, 10_000}} =
             ETS.append("pressure", "oversized", payloads, 0, server: server, recorded_at: 1)

    assert :not_found = Ledger.load(store, "pressure")
    assert :not_found = Ledger.lookup_batch(store, "pressure", "oversized")

    assert {:ok, 1} =
             ETS.append("pressure", "valid", [%{"value" => true}], 0,
               server: server,
               recorded_at: 1
             )

    assert {:ok, %{revision: 1, entries: [_]}} = Ledger.load(store, "pressure")
  end

  test "an imposed heap kill during ingress cannot publish partial Evidence or invent an Act" do
    namespace = "memory-pressure-#{System.unique_integer([:positive])}"
    fixture = Fixture.start(:ets, namespace, 3, 8, 1)
    on_exit(fn -> Fixture.stop(fixture) end)
    before = Sequencer.projection(fixture.server)
    assert {:ok, snapshot} = Ledger.load(fixture.store_config, fixture.refs.domain)
    Process.unlink(fixture.server)
    monitor = Process.monitor(fixture.server)

    # Fault injection only: production does not currently impose this budget.
    # Keep the trusted ledger in another process so recovery can be checked.
    :sys.replace_state(fixture.server, fn state ->
      Process.flag(:max_heap_size, heap_limit())
      state
    end)

    assert Sequencer.projection(fixture.server) == before
    shared = :binary.copy(<<42>>, 65_536)

    assert catch_exit(
             Sequencer.observe(
               fixture.server,
               fixture.context,
               %{proposition: "pressure", payload: List.duplicate(shared, 1_024)},
               timeout: @timeout
             )
           )

    assert_receive {:DOWN, ^monitor, :process, _, :killed}, @timeout
    assert {:ok, ^snapshot} = Ledger.load(fixture.store_config, fixture.refs.domain)
    restarted = Fixture.restart(fixture)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert Sequencer.projection(restarted) == before

    assert {:ok, %{decision: %{outcome: :admitted}, act: act}} =
             Sequencer.submit(restarted, fixture.context, Fixture.candidate(fixture, 1))

    projection = Sequencer.projection(restarted)
    assert projection.acts == %{act.ref => act}
    assert projection.attempts == %{}
  end

  test "max_bytes rejects shared expansion before exhausting the worker heap" do
    # Positive control: loading/calling the codec fits comfortably in the same
    # budget. The attack input below is ~80 KiB with shared binaries, but its
    # encoded representation is 64 MiB despite the requested 1 KiB limit.
    assert {:returned, {:ok, _encoded}} = isolated(fn -> Value.encode(["small"]) end)

    result =
      isolated(fn ->
        shared = :binary.copy(<<42>>, 65_536)
        Value.encode(List.duplicate(shared, 1_024), max_bytes: 1_024)
      end)

    assert {:returned, {:error, {:canonical_value_too_large, _size, 1_024}}} = result
  end

  test "the budget is cumulative across many individually small nested values" do
    for container <- [
          fn values -> values end,
          &List.to_tuple/1,
          fn values -> values |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end) end
        ] do
      assert {:returned, {:error, {:canonical_value_too_large, _, 1_024}}} =
               isolated(fn ->
                 values = List.duplicate([:binary.copy(<<42>>, 256)], 1_024)
                 Value.encode(container.(values), max_bytes: 1_024)
               end)
    end
  end

  test "portable entry points reject depth before traversing an exponentially shared tree" do
    for operation <- [
          &Portable.validate/1,
          &Portable.canonical_map(%{"tree" => &1}),
          &Portable.canonical_value/1,
          &Portable.digest/1,
          &Portable.stringify_atom_keys/1
        ] do
      assert {:returned, {:error, {:canonical_depth_exceeded, _, 128}}} =
               isolated(fn ->
                 nested = Enum.reduce(1..200, nil, fn _, value -> [value, value] end)
                 operation.(nested)
               end)
    end
  end

  test "oversized integers respect the wire limit under an isolated worker budget" do
    for sign <- [1, -1] do
      assert {:returned, {:error, {:canonical_value_too_large, used, 1_024}}} =
               isolated(fn ->
                 integer = sign * :binary.decode_unsigned(:binary.copy(<<255>>, 131_072))
                 Value.encode(integer, max_bytes: 1_024)
               end)

      assert used > 1_024
    end
  end

  defp isolated(work) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(parent, {token, work.()}) end,
        [
          :monitor,
          {:max_heap_size, heap_limit()}
        ]
      )

    try do
      receive do
        {^token, result} ->
          assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
          {:returned, result}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:terminated, reason}
      after
        @timeout ->
          Process.exit(pid, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @timeout
          {:terminated, :timeout}
      end
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp heap_limit do
    %{
      size: @heap_words,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    }
  end

  defp atom_wire(name), do: <<"SPCV", 1, 0x13, byte_size(name)::32, name::binary>>
end
