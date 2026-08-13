defmodule SpectreStoreConformanceTest.Store do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Canonical.Validator

  @impl true
  def load(ref, opts) do
    case Agent.get(Keyword.fetch!(opts, :server), &Map.get(&1, ref.key)) do
      nil -> :not_found
      {_revision, checkpoint} -> {:ok, maybe_decode(checkpoint, opts)}
    end
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    with {:ok, %Canonical{} = canonical} <- Codec.decode(checkpoint),
         :ok <- Validator.validate(canonical, ref),
         true <- canonical.revision == revision do
      notify_attempt(opts, expected, revision)

      accept_retry? = Keyword.get(opts, :accept_retry, true)

      Agent.get_and_update(
        Keyword.fetch!(opts, :server),
        &persist(&1, ref.key, checkpoint, expected, revision, accept_retry?)
      )
    else
      _invalid -> {:error, :invalid_canonical_checkpoint}
    end
  end

  defp maybe_decode(checkpoint, opts) do
    if Keyword.get(opts, :load_as_map, false), do: Jason.decode!(checkpoint), else: checkpoint
  end

  defp notify_attempt(opts, expected, revision) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:checkpoint_store_attempt, expected, revision})
    end
  end

  defp persist(entries, key, checkpoint, expected, revision, accept_retry?) do
    current = Map.get(entries, key)
    actual = if current, do: elem(current, 0), else: 0

    cond do
      current == {revision, checkpoint} and accept_retry? ->
        {:ok, entries}

      actual == expected ->
        {:ok, Map.put(entries, key, {revision, checkpoint})}

      true ->
        {{:error, {:stale_checkpoint, actual}}, entries}
    end
  end
end

defmodule SpectreStoreConformanceTest.AcceptingStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts), do: SpectreStoreConformanceTest.Store.load(ref, opts)

  @impl true
  def compare_and_swap(ref, checkpoint, _expected, revision, opts) do
    Agent.update(Keyword.fetch!(opts, :server), &Map.put(&1, ref.key, {revision, checkpoint}))
    :ok
  end
end

defmodule SpectreStoreConformanceTest.AmbiguousLoserStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts), do: SpectreStoreConformanceTest.Store.load(ref, opts)

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    case SpectreStoreConformanceTest.Store.compare_and_swap(
           ref,
           checkpoint,
           expected,
           revision,
           opts
         ) do
      {:error, {:stale_checkpoint, _actual}} when revision == 3 ->
        {:error, {:ambiguous, :connection_lost}}

      reply ->
        reply
    end
  end
end

defmodule SpectreStoreConformanceTest.Barrier do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
  def wait(server), do: GenServer.call(server, :wait, 5_000)

  @impl true
  def init([]), do: {:ok, nil}

  @impl true
  def handle_call(:wait, from, nil), do: {:noreply, from}

  def handle_call(:wait, _from, first) do
    GenServer.reply(first, :ok)
    {:reply, :ok, nil}
  end
end

defmodule SpectreStoreConformanceTest.OrderedRace do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :empty)
  def contend(server), do: GenServer.call(server, :contend, 5_000)
  def winner_written(server), do: GenServer.call(server, :winner_written, 5_000)

  @impl true
  def init(:empty), do: {:ok, :empty}

  @impl true
  def handle_call(:contend, from, :empty), do: {:noreply, {:waiting, from}}

  def handle_call(:contend, from, {:waiting, first}) do
    GenServer.reply(first, :winner)
    {:noreply, {:winner_running, from}}
  end

  def handle_call(:winner_written, _from, {:winner_running, second}) do
    GenServer.reply(second, :loser)
    {:reply, :ok, :empty}
  end
end

defmodule SpectreStoreConformanceTest.RacyStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts), do: SpectreStoreConformanceTest.Store.load(ref, opts)

  @impl true
  def compare_and_swap(ref, checkpoint, expected, 3 = revision, opts) do
    server = Keyword.fetch!(opts, :server)
    barrier = Keyword.fetch!(opts, :barrier)

    case Agent.get(server, &Map.get(&1, ref.key)) do
      {^expected, _current} ->
        :ok = SpectreStoreConformanceTest.Barrier.wait(barrier)
        Agent.update(server, &Map.put(&1, ref.key, {revision, checkpoint}))
        :ok

      {actual, _current} ->
        {:error, {:stale_checkpoint, actual}}

      nil ->
        {:error, {:stale_checkpoint, 0}}
    end
  end

  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    SpectreStoreConformanceTest.Store.compare_and_swap(
      ref,
      checkpoint,
      expected,
      revision,
      opts
    )
  end
end

defmodule SpectreStoreConformanceTest.OverwritingLoserStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts), do: SpectreStoreConformanceTest.Store.load(ref, opts)

  @impl true
  def compare_and_swap(ref, checkpoint, 2, 3 = revision, opts) do
    server = Keyword.fetch!(opts, :server)
    race = Keyword.fetch!(opts, :ordered_race)

    case SpectreStoreConformanceTest.OrderedRace.contend(race) do
      :winner ->
        Agent.update(server, &Map.put(&1, ref.key, {revision, checkpoint}))
        :ok = SpectreStoreConformanceTest.OrderedRace.winner_written(race)

      :loser ->
        Agent.update(server, &Map.put(&1, ref.key, {revision, checkpoint}))
        {:error, {:stale_checkpoint, revision}}
    end
  end

  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    SpectreStoreConformanceTest.Store.compare_and_swap(
      ref,
      checkpoint,
      expected,
      revision,
      opts
    )
  end
end

defmodule SpectreStoreConformanceTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Instance.CheckpointStore.Conformance
  alias Spectre.Instance.Ref
  alias Spectre.Subject

  test "proves canonical CAS, retry reconciliation, stale rejection, and semantic readback" do
    server = start_supervised!({Agent, fn -> %{} end})
    ref = isolated_ref()

    assert {:ok, report} =
             Conformance.run(
               {SpectreStoreConformanceTest.Store,
                server: server, accept_retry: false, load_as_map: true, test_pid: self()},
               ref
             )

    assert report == %{
             create: :committed,
             update: :committed,
             exact_retry: :readback_verified,
             stale_write: :rejected,
             concurrent_cas: :single_winner,
             readback: :verified,
             revision: 3,
             checkpoint_digest: report.checkpoint_digest
           }

    assert byte_size(report.checkpoint_digest) == 64
    refute inspect(report) =~ ref.key

    assert_received {:checkpoint_store_attempt, 0, 1}
    assert_received {:checkpoint_store_attempt, 0, 1}
    assert_received {:checkpoint_store_attempt, 1, 2}
    assert_received {:checkpoint_store_attempt, 1, 2}
    assert_received {:checkpoint_store_attempt, 2, 3}
    assert_received {:checkpoint_store_attempt, 2, 3}

    assert :ok =
             Conformance.read_after_restart(
               {SpectreStoreConformanceTest.Store, server: server},
               {SpectreStoreConformanceTest.Store, server: server, load_as_map: true},
               ref
             )
  end

  test "rejects stale acceptance, invalid fixtures, and reused references with stable errors" do
    server = start_supervised!({Agent, fn -> %{} end})

    assert {:error, {:checkpoint_store_conformance_failed, :stale_write, :accepted}} =
             Conformance.run(
               {SpectreStoreConformanceTest.AcceptingStore, server: server},
               isolated_ref()
             )

    ref = isolated_ref()

    assert {:ok, _report} =
             Conformance.run(
               {SpectreStoreConformanceTest.Store, server: server},
               ref
             )

    assert {:error, {:checkpoint_store_conformance_failed, :initial_load, :reference_not_empty}} =
             Conformance.run(
               {SpectreStoreConformanceTest.Store, server: server},
               ref
             )
  end

  test "rejects a non-atomic check-then-write implementation" do
    server = start_supervised!({Agent, fn -> %{} end})
    barrier = start_supervised!(SpectreStoreConformanceTest.Barrier)

    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :multiple_winners}} =
             Conformance.run(
               {SpectreStoreConformanceTest.RacyStore, server: server, barrier: barrier},
               isolated_ref()
             )
  end

  test "rejects an ambiguous outcome from the losing concurrent writer" do
    server = start_supervised!({Agent, fn -> %{} end})

    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :ambiguous_loser}} =
             Conformance.run(
               {SpectreStoreConformanceTest.AmbiguousLoserStore, server: server},
               isolated_ref()
             )
  end

  test "verifies that the declared winner is the durable concurrent head" do
    server = start_supervised!({Agent, fn -> %{} end})
    race = start_supervised!(SpectreStoreConformanceTest.OrderedRace)

    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :readback_mismatch}} =
             Conformance.run(
               {SpectreStoreConformanceTest.OverwritingLoserStore,
                server: server, ordered_race: race},
               isolated_ref()
             )
  end

  defp isolated_ref do
    id = System.unique_integer([:positive, :monotonic])

    Ref.new(
      AgentRef.from_id("store-conformance-agent-#{id}"),
      Subject.new("store-conformance-subject-#{id}")
    )
  end
end
