defmodule SpectreCoreConformanceCoverageTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    server = Keyword.fetch!(opts, :server)
    load(Keyword.get(opts, :mode, :conforming), ref, server)
  end

  defp load(:always_missing, _ref, _server), do: :not_found
  defp load(:always_error, _ref, _server), do: {:error, :checkpoint_backend_unavailable}
  defp load(:missing_after_write, _ref, _server), do: :not_found

  defp load(:error_after_initial_load, _ref, server) do
    Agent.get_and_update(server, fn state ->
      reply = if state.loads == 0, do: :not_found, else: {:error, :checkpoint_read_failed}
      {reply, %{state | loads: state.loads + 1}}
    end)
  end

  defp load(:invalid_after_write, ref, server) do
    Agent.get(server, fn state ->
      if Map.has_key?(state.entries, ref.key), do: {:ok, "not-a-checkpoint"}, else: :not_found
    end)
  end

  defp load(_mode, ref, server) do
    Agent.get(server, fn state -> load_entry(Map.get(state.entries, ref.key)) end)
  end

  defp load_entry(nil), do: :not_found
  defp load_entry({_revision, checkpoint}), do: {:ok, checkpoint}

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    case {Keyword.get(opts, :mode, :conforming), revision} do
      {:reject_create, 1} ->
        {:error, :create_rejected}

      {:reject_race, 3} ->
        {:error, :contended}

      {:kill_race, 3} ->
        self()
        |> Process.info(:links)
        |> elem(1)
        |> Enum.each(&Process.unlink/1)

        Process.exit(self(), :kill)

      {:delayed_winner_error, 3} ->
        delayed_race(ref, checkpoint, expected, revision, opts, {:error, :stale_writer})

      {:delayed_winner_ambiguous, 3} ->
        delayed_race(
          ref,
          checkpoint,
          expected,
          revision,
          opts,
          {:error, {:ambiguous, :connection_lost}}
        )

      _mode_and_revision ->
        persist(ref, checkpoint, expected, revision, opts)
    end
  end

  defp delayed_race(ref, checkpoint, expected, revision, opts, loser_reply) do
    contender = self()

    outcome =
      Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
        case Map.get(state.entries, ref.key) do
          {^expected, _current} ->
            next =
              state
              |> put_in([:entries, ref.key], {revision, checkpoint})
              |> Map.put(:race_winner, contender)

            {:winner, next}

          _other ->
            {{:loser, Map.fetch!(state, :race_winner)}, state}
        end
      end)

    case outcome do
      :winner ->
        receive do
          :race_loser_observed -> :ok
        after
          5_000 -> {:error, :race_peer_timeout}
        end

      {:loser, winner} ->
        send(winner, :race_loser_observed)
        loser_reply
    end
  end

  defp persist(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
      current = Map.get(state.entries, ref.key)
      actual = if current, do: elem(current, 0), else: 0

      cond do
        current == {revision, checkpoint} ->
          {:ok, state}

        actual == expected ->
          {:ok, put_in(state, [:entries, ref.key], {revision, checkpoint})}

        true ->
          {{:error, {:stale_checkpoint, actual}}, state}
      end
    end)
  end
end

defmodule SpectreCoreConformanceCoverageTest.DefinitionStore do
  @moduledoc false
  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts) do
    case Keyword.get(opts, :mode, :conforming) do
      :changing_identity ->
        Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
          call = state.identity_calls + 1
          {"definition-store-#{call}", %{state | identity_calls: call}}
        end)

      _mode ->
        "definition-store"
    end
  end

  @impl true
  def durability(_opts), do: :volatile

  @impl true
  def get(key, opts) do
    get(Keyword.get(opts, :mode, :conforming), key, Keyword.fetch!(opts, :server))
  end

  defp get(:always_missing, _key, _server), do: :not_found
  defp get(:read_error, _key, _server), do: {:error, :definition_store_unavailable}

  defp get(_mode, key, server) do
    Agent.get(server, fn state -> fetch_entry(state.entries, key) end)
  end

  defp fetch_entry(entries, key) do
    case Map.fetch(entries, key) do
      {:ok, encoded} -> {:ok, encoded}
      :error -> :not_found
    end
  end

  @impl true
  def put(key, encoded, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
      case {Keyword.get(opts, :mode, :conforming), Map.fetch(state.entries, key)} do
        {:changing_identity, _existing} ->
          {{:ok, :created}, put_in(state, [:entries, key], encoded)}

        {_mode, :error} ->
          {{:ok, :created}, put_in(state, [:entries, key], encoded)}

        {_mode, {:ok, ^encoded}} ->
          {{:ok, :existing}, state}

        {_mode, {:ok, _different}} ->
          {{:error, :immutable_conflict}, state}
      end
    end)
  end
end

defmodule SpectreCoreConformanceCoverageTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :core_conformance_coverage_agent
end

defmodule SpectreCoreConformanceCoverageTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Definition.Store.Conformance, as: DefinitionConformance
  alias Spectre.Gate.Receipt.Ref, as: GateReceiptRef
  alias Spectre.Instance.CheckpointStore.Conformance, as: CheckpointConformance
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Subject

  alias SpectreCoreConformanceCoverageTest.Agent, as: FixtureAgent
  alias SpectreCoreConformanceCoverageTest.CheckpointStore
  alias SpectreCoreConformanceCoverageTest.DefinitionStore

  @digest String.duplicate("a", 64)

  test "checkpoint conformance accepts one atomic CAS winner and restart readback" do
    store = checkpoint_store(:conforming)
    ref = instance_ref()

    assert {:ok,
            %{
              create: :committed,
              update: :committed,
              exact_retry: :accepted,
              stale_write: :rejected,
              concurrent_cas: :single_winner,
              readback: :verified,
              revision: 3
            }} = CheckpointConformance.run(store, ref)

    assert :ok = CheckpointConformance.read_after_restart(store, store, ref)
  end

  test "checkpoint conformance classifies invalid options and fixture identities" do
    store = checkpoint_store(:conforming)

    assert {:error, {:checkpoint_store_conformance_failed, :options, :invalid_ref}} =
             CheckpointConformance.run(store, :not_an_instance_ref)

    assert {:error, {:checkpoint_store_conformance_failed, :options, :invalid_ref}} =
             CheckpointConformance.read_after_restart(store, store, :not_an_instance_ref)

    assert {:error, {:checkpoint_store_conformance_failed, :configuration, :invalid}} =
             CheckpointConformance.run(false, instance_ref())

    malformed_ref = %InstanceRef{
      schema_version: InstanceRef.schema_version(),
      agent_ref: nil,
      subject: nil,
      key: self()
    }

    assert {:error, {:checkpoint_store_conformance_failed, :fixtures, :invalid_checkpoint}} =
             CheckpointConformance.run(store, malformed_ref)
  end

  test "checkpoint restart reports missing and failed durable reads" do
    ref = instance_ref()

    assert {:error,
            {:checkpoint_store_conformance_failed, :restart_before, :checkpoint_not_found}} =
             CheckpointConformance.read_after_restart(
               checkpoint_store(:always_missing),
               checkpoint_store(:always_missing),
               ref
             )

    assert {:error, {:checkpoint_store_conformance_failed, :restart_before, :load_failed}} =
             CheckpointConformance.read_after_restart(
               checkpoint_store(:always_error),
               checkpoint_store(:always_error),
               ref
             )
  end

  test "checkpoint conformance rejects create and readback failures by phase" do
    ref = instance_ref()

    assert {:error, {:checkpoint_store_conformance_failed, :create, :write_rejected}} =
             CheckpointConformance.run(checkpoint_store(:reject_create), ref)

    assert {:error, {:checkpoint_store_conformance_failed, :create, :checkpoint_not_found}} =
             CheckpointConformance.run(checkpoint_store(:missing_after_write), instance_ref())

    assert {:error, {:checkpoint_store_conformance_failed, :create, :load_failed}} =
             CheckpointConformance.run(
               checkpoint_store(:error_after_initial_load),
               instance_ref()
             )

    assert {:error, {:checkpoint_store_conformance_failed, :create, :invalid_checkpoint}} =
             CheckpointConformance.run(checkpoint_store(:invalid_after_write), instance_ref())
  end

  test "checkpoint conformance rejects every non-provable CAS race" do
    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :no_winner}} =
             CheckpointConformance.run(checkpoint_store(:reject_race), instance_ref())

    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :callback_failed}} =
             CheckpointConformance.run(checkpoint_store(:kill_race), instance_ref())

    assert {:ok, %{concurrent_cas: :single_winner}} =
             CheckpointConformance.run(
               checkpoint_store(:delayed_winner_error),
               instance_ref()
             )

    assert {:error, {:checkpoint_store_conformance_failed, :concurrent_cas, :ambiguous_loser}} =
             CheckpointConformance.run(
               checkpoint_store(:delayed_winner_ambiguous),
               instance_ref()
             )
  end

  test "Definition Store conformance verifies idempotency and restart identity" do
    store = definition_store(:conforming)
    {canonical, manifest} = definition_fixture()
    ref = canonical |> Canonical.ref() |> DefinitionRef.to_string()

    assert {:ok, %{initial_state: :not_found, duplicate: :idempotent, readback: :verified}} =
             DefinitionConformance.run(store, canonical, manifest)

    assert {:ok, %{initial_state: :existing}} =
             DefinitionConformance.run(store, canonical, manifest)

    assert :ok = DefinitionConformance.read_after_restart(store, store, ref)
  end

  test "Definition Store conformance rejects missing, failed and unstable adapters" do
    {canonical, manifest} = definition_fixture()
    ref = canonical |> Canonical.ref() |> DefinitionRef.to_string()

    assert {:error, :definition_store_missing_after_restart} =
             DefinitionConformance.read_after_restart(
               definition_store(:always_missing),
               definition_store(:always_missing),
               ref
             )

    assert {:error, :definition_store_unavailable} =
             DefinitionConformance.read_after_restart(
               definition_store(:read_error),
               definition_store(:read_error),
               ref
             )

    assert {:error, :definition_store_unavailable} =
             DefinitionConformance.run(
               definition_store(:read_error),
               canonical,
               manifest
             )

    assert {:error, :definition_store_duplicate_changed_receipt} =
             DefinitionConformance.run(
               definition_store(:changing_identity),
               canonical,
               manifest
             )
  end

  test "owner leases classify invalid outer values and reject struct metadata" do
    assert {:error, {:invalid_instance_owner_lease, :tuple}} = Lease.new({:invalid})
    assert {:error, {:invalid_instance_owner_lease, :binary}} = Lease.new("invalid")
    assert {:error, {:invalid_instance_owner_lease, :integer}} = Lease.new(42)
    assert {:error, {:invalid_instance_owner_lease, :other}} = Lease.new(self())

    assert {:error, {:invalid_owner_lease_field, :metadata, :map}} =
             Lease.new(
               owner_id: "owner:test",
               fencing_token: 1,
               issued_at: 0,
               metadata: %URI{scheme: "https"}
             )
  end

  test "gate receipt refs reject values outside the canonical lowercase namespace" do
    assert {:ok, ref} = GateReceiptRef.parse("gate:sha256:" <> @digest)
    assert GateReceiptRef.valid?(ref)
    assert GateReceiptRef.to_string(ref) == "gate:sha256:" <> @digest
    assert to_string(ref) == GateReceiptRef.to_string(ref)

    assert {:error, {:invalid_gate_receipt_ref, :invalid}} = GateReceiptRef.parse(:invalid)

    assert {:error, {:invalid_gate_receipt_ref, "receipt:sha256:" <> @digest}} =
             GateReceiptRef.parse("receipt:sha256:" <> @digest)

    refute GateReceiptRef.valid?(:invalid)
    refute GateReceiptRef.valid?(%{algorithm: :sha256, digest: @digest})
  end

  defp checkpoint_store(mode) do
    server =
      start_supervised!(%{
        id: {:checkpoint_store_state, System.unique_integer([:positive, :monotonic])},
        start: {Agent, :start_link, [fn -> %{entries: %{}, loads: 0} end]}
      })

    {CheckpointStore, server: server, mode: mode}
  end

  defp definition_store(mode) do
    server =
      start_supervised!(%{
        id: {:definition_store_state, System.unique_integer([:positive, :monotonic])},
        start: {Agent, :start_link, [fn -> %{entries: %{}, identity_calls: 0} end]}
      })

    {DefinitionStore, server: server, mode: mode}
  end

  defp instance_ref do
    id = System.unique_integer([:positive, :monotonic])

    InstanceRef.new(
      AgentRef.from_id("core-conformance-agent-#{id}"),
      Subject.new("core-conformance-subject-#{id}")
    )
  end

  defp definition_fixture do
    {Definition.canonical!(FixtureAgent), Definition.manifest!(FixtureAgent)}
  end
end
