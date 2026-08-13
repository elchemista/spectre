defmodule SpectreStoreConformanceTest.Store do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    case Agent.get(Keyword.fetch!(opts, :server), &Map.get(&1, ref.key)) do
      nil -> :not_found
      {_revision, checkpoint} -> {:ok, maybe_decode(checkpoint, opts)}
    end
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      current = Map.get(entries, ref.key)
      actual = if current, do: elem(current, 0), else: 0

      cond do
        current == {revision, checkpoint} and Keyword.get(opts, :accept_retry, true) ->
          {:ok, entries}

        actual == expected ->
          {:ok, Map.put(entries, ref.key, {revision, checkpoint})}

        true ->
          {{:error, {:stale_checkpoint, actual}}, entries}
      end
    end)
  end

  defp maybe_decode(checkpoint, opts) do
    if Keyword.get(opts, :load_as_map, false), do: Jason.decode!(checkpoint), else: checkpoint
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
        Agent.update(barrier, &(&1 + 1))
        await_contenders(barrier, 100)
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

  defp await_contenders(_barrier, 0), do: :ok

  defp await_contenders(barrier, remaining) do
    if Agent.get(barrier, & &1) >= 2 do
      :ok
    else
      Process.sleep(1)
      await_contenders(barrier, remaining - 1)
    end
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
                server: server, accept_retry: false, load_as_map: true},
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

    barrier =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> 0 end}, id: :conformance_race_barrier)
      )

    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :multiple_winners}} =
             Conformance.run(
               {SpectreStoreConformanceTest.RacyStore, server: server, barrier: barrier},
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
