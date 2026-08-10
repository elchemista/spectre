defmodule SpectreDefinitionStoreTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :definition_store_agent
end

defmodule SpectreDefinitionStoreTest.DurableStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts), do: Keyword.fetch!(opts, :id)

  @impl true
  def durability(_opts), do: :durable

  @impl true
  def get(key, opts) do
    case :ets.lookup(Keyword.fetch!(opts, :table), key) do
      [{^key, encoded}] -> {:ok, encoded}
      [] -> :not_found
    end
  end

  @impl true
  def put(key, encoded, opts) do
    table = Keyword.fetch!(opts, :table)

    if :ets.insert_new(table, {key, encoded}) do
      {:ok, :created}
    else
      case :ets.lookup(table, key) do
        [{^key, ^encoded}] -> {:ok, :existing}
        [{^key, _different}] -> {:error, {:immutable_conflict, key}}
      end
    end
  end
end

defmodule SpectreDefinitionStoreTest.FaultStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts) do
    case Keyword.get(opts, :mode) do
      :bad_identity -> self()
      :raise_identity -> raise "identity"
      _mode -> :fault_store
    end
  end

  @impl true
  def durability(opts), do: Keyword.get(opts, :durability, :volatile)

  @impl true
  def get(_key, opts) do
    case Keyword.get(opts, :mode) do
      :bad_get -> :unexpected
      :raise_get -> raise "get"
      :throw_get -> throw(:get)
      _mode -> :not_found
    end
  end

  @impl true
  def put(_key, _encoded, opts) do
    case Keyword.get(opts, :mode) do
      :bad_put -> :unexpected
      :raise_put -> raise "put"
      :throw_put -> throw(:put)
      _mode -> :ok
    end
  end
end

defmodule SpectreDefinitionStoreTest.MissingCallbacks do
  @moduledoc false
end

defmodule SpectreDefinitionStoreTest.CheckpointStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore
end

defmodule SpectreDefinitionStoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Conformance
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure

  alias SpectreDefinitionStoreTest.Agent
  alias SpectreDefinitionStoreTest.CheckpointStore
  alias SpectreDefinitionStoreTest.DurableStore
  alias SpectreDefinitionStoreTest.FaultStore
  alias SpectreDefinitionStoreTest.MissingCallbacks

  @digest String.duplicate("c", 64)
  @other_digest String.duplicate("d", 64)

  test "memory reference Store publishes immutably and resolves idempotently" do
    store = memory_store()
    {canonical, manifest} = fixture()
    ref = Canonical.ref(canonical)

    assert :not_found = Store.fetch(store, ref)
    assert {:ok, first} = Store.publish(store, canonical, manifest)
    assert {:ok, second} = Store.publish(store, canonical, manifest)
    assert first == second
    assert Memory.count(store_server(store)) == 1

    assert {:ok, artifact} = Store.fetch(store, Ref.to_string(ref))
    assert artifact.definition == canonical
    assert artifact.manifest == manifest
    assert artifact.receipt == first

    assert {:ok, resolution} = Resolver.resolve(store, ref)
    assert resolution.definition_ref == ref
    assert resolution.drift == %{status: :unobserved, drifts: []}
  end

  test "Store conformance covers duplicate publication and verified read-back" do
    store = memory_store()
    {canonical, manifest} = fixture()

    assert {:ok,
            %{
              initial_state: :not_found,
              duplicate: :idempotent,
              readback: :verified
            }} = Conformance.run(store, canonical, manifest)

    assert {:ok, %{initial_state: :existing}} =
             Conformance.run(store, canonical, manifest)
  end

  test "durable adapters remain resolvable across adapter restart" do
    store = durable_store("restart-store")
    {canonical, manifest} = fixture()
    ref = canonical |> Canonical.ref() |> Ref.to_string()

    assert {:ok, %{durability: :durable}} = Store.publish(store, canonical, manifest)

    restarted = durable_store_config(store)
    assert :ok = Conformance.read_after_restart(store, restarted, ref)

    assert {:ok, _resolution} =
             Resolver.resolve_for_activation(restarted, ref, checkpoint_store: CheckpointStore)
  end

  test "durable checkpoint plus volatile Definition Store is rejected" do
    store = memory_store()
    {canonical, manifest} = fixture()

    assert {:error, :durable_checkpoint_requires_durable_definition_store} =
             Store.validate_durability_pair(CheckpointStore, store)

    assert {:error, :durable_checkpoint_requires_durable_definition_store} =
             Store.publish(store, canonical, manifest, checkpoint_store: CheckpointStore)

    assert {:error, :durable_checkpoint_requires_durable_definition_store} =
             Resolver.resolve_for_activation(store, Canonical.ref(canonical),
               checkpoint_store: CheckpointStore
             )

    assert :not_found = Resolver.resolve_for_activation(store, Canonical.ref(canonical))
  end

  test "publish before activation survives a crash as an orphan artifact only" do
    store = durable_store("orphan-store")
    {canonical, manifest} = fixture()
    ref = Canonical.ref(canonical)

    assert {:ok, receipt} = Store.publish(store, canonical, manifest)
    assert receipt.definition_ref == Ref.to_string(ref)

    # Simulates a process dying here, before the future activation CAS exists.
    assert {:ok, resolution} = Resolver.resolve(store, ref)
    assert resolution.publication_receipt == receipt
  end

  test "parents must resolve before a child can be published" do
    store = durable_store("lineage-store")
    {parent, parent_manifest} = fixture()
    child = Canonical.new!(%{parent | id: :definition_store_child, declared_version: 2})

    child_manifest =
      Manifest.new!(child, Envelope.empty(), closure(), parent_refs: [Canonical.ref(parent)])

    assert {:error, {:missing_definition_parent, parent_ref}} =
             Store.publish(store, child, child_manifest)

    assert parent_ref == Ref.to_string(Canonical.ref(parent))
    assert {:ok, _receipt} = Store.publish(store, parent, parent_manifest)
    assert {:ok, _receipt} = Store.publish(store, child, child_manifest)
  end

  test "different Manifest bytes cannot replace an existing Definition Ref" do
    store = durable_store("immutable-store")
    {canonical, manifest} = fixture()
    altered = %{manifest | publisher_ref: "publisher:different"}

    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)
    assert {:error, {:immutable_conflict, _key}} = Store.publish(store, canonical, altered)
    assert {:ok, %{manifest: ^manifest}} = Store.fetch(store, Canonical.ref(canonical))
  end

  test "tampered Definition bytes and stale receipts never resolve" do
    store = durable_store("tamper-store")
    {canonical, manifest} = fixture()
    ref = Canonical.ref(canonical)
    key = Ref.to_string(ref)

    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)

    tamper_artifact(store, key, fn artifact ->
      put_in(artifact, ["receipt", "manifest_digest"], @other_digest)
    end)

    assert {:error,
            {:definition_store_artifact_invalid,
             {:stale_definition_publication_receipt, _actual, _expected}}} =
             Store.fetch(store, ref)

    {:ok, other} = Ref.parse("sha256:" <> @other_digest)
    copy_artifact(store, key, Ref.to_string(other))

    assert {:error,
            {:definition_store_artifact_invalid,
             {:definition_store_lookup_mismatch, _expected, _stored}}} =
             Store.fetch(store, other)
  end

  test "Resolver reports, matches or rejects code drift explicitly" do
    store = durable_store("drift-store")
    {canonical, manifest} = fixture()
    ref = Canonical.ref(canonical)
    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)

    assert {:ok, %{drift: %{status: :matched}}} =
             Resolver.resolve(store, ref, observed_builds: %{"beam:Agent" => @digest})

    assert {:error, {:definition_code_drift, [%{reason: :changed}]}} =
             Resolver.resolve(store, ref, observed_builds: %{"beam:Agent" => @other_digest})

    assert {:ok, %{drift: %{status: :drifted, drifts: [%{reason: :changed}]}}} =
             Resolver.resolve(store, ref,
               observed_builds: %{"beam:Agent" => @other_digest},
               on_drift: :report
             )

    assert {:error, {:invalid_definition_drift_policy, :ignore}} =
             Resolver.resolve(store, ref,
               observed_builds: %{"beam:Agent" => @digest},
               on_drift: :ignore
             )
  end

  test "Store rejects malformed adapters, replies, identities and configurations" do
    assert {:error, {:invalid_definition_store, "bad"}} = Store.normalize("bad")

    assert {:error, {:invalid_definition_store, {FaultStore, :non_keyword_options}}} =
             Store.normalize({FaultStore, [:not_keyword]})

    assert {:error, {:definition_store_callback_missing, MissingCallbacks, :identity, 1}} =
             Store.durability(MissingCallbacks)

    assert {:error, :invalid_definition_store_durability} =
             Store.durability({FaultStore, durability: :unknown})

    assert {:error, {:invalid_definition_store_identity, _reason}} =
             Store.identity({FaultStore, mode: :bad_identity})

    assert {:error, {:definition_store_exception, FaultStore, :identity, RuntimeError}} =
             Store.identity({FaultStore, mode: :raise_identity})

    {canonical, manifest} = fixture()

    assert {:error, {:invalid_definition_store_put_reply, FaultStore, :unexpected}} =
             Store.publish({FaultStore, mode: :bad_put}, canonical, manifest)

    assert {:error, {:definition_store_exception, FaultStore, :put, RuntimeError}} =
             Store.publish({FaultStore, mode: :raise_put}, canonical, manifest)

    assert {:error, {:definition_store_failure, FaultStore, :put, :throw, :put}} =
             Store.publish({FaultStore, mode: :throw_put}, canonical, manifest)

    assert {:error, {:invalid_definition_store_get_reply, FaultStore, :unexpected}} =
             Store.fetch({FaultStore, mode: :bad_get}, Canonical.ref(canonical))

    assert {:error, {:definition_store_exception, FaultStore, :get, RuntimeError}} =
             Store.fetch({FaultStore, mode: :raise_get}, Canonical.ref(canonical))

    assert {:error, {:definition_store_failure, FaultStore, :get, :throw, :get}} =
             Store.fetch({FaultStore, mode: :throw_get}, Canonical.ref(canonical))
  end

  test "Memory adapter rejects different bytes and requires an explicit server" do
    store = memory_store()
    server = store_server(store)

    assert {:ok, :created} = Memory.put("key", "first", server: server)
    assert {:ok, :existing} = Memory.put("key", "first", server: server)

    assert {:error, {:immutable_conflict, "key"}} =
             Memory.put("key", "second", server: server)

    assert {:ok, "first"} = Memory.get("key", server: server)
    assert :not_found = Memory.get("missing", server: server)

    assert_raise ArgumentError, ~r/requires the :server option/, fn ->
      Memory.identity([])
    end
  end

  defp fixture do
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    {canonical, manifest}
  end

  defp closure do
    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/1",
      state_codec_ref: "spectre.instance.canonical.codec/1",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{"beam:Agent" => @digest},
      evaluation_corpus_digest: nil,
      compatibility_mode: :adapted_v1
    })
  end

  defp memory_store do
    id = {:memory_store, System.unique_integer([:positive])}
    server = start_supervised!({Memory, id: id})
    {Memory, server: server}
  end

  defp store_server({Memory, opts}), do: Keyword.fetch!(opts, :server)

  defp durable_store(id) do
    table = :ets.new(:definition_store, [:set, :public])
    {DurableStore, table: table, id: id}
  end

  defp durable_store_config({DurableStore, opts}) do
    {DurableStore, table: Keyword.fetch!(opts, :table), id: Keyword.fetch!(opts, :id)}
  end

  defp tamper_artifact({DurableStore, opts}, key, tamper) do
    table = Keyword.fetch!(opts, :table)
    [{^key, encoded}] = :ets.lookup(table, key)
    {:ok, artifact} = Value.decode(encoded)
    :ets.insert(table, {key, artifact |> tamper.() |> Value.encode!()})
  end

  defp copy_artifact({DurableStore, opts}, source, destination) do
    table = Keyword.fetch!(opts, :table)
    [{^source, encoded}] = :ets.lookup(table, source)
    :ets.insert(table, {destination, encoded})
  end
end
