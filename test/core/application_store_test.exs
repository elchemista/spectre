defmodule Spectre.Core.ApplicationStoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Canonical.Value
  alias Spectre.{Definition, Store}
  alias Spectre.Definition.Store, as: Definitions
  alias Spectre.Instance.Checkpoint
  alias Spectre.Store.Memory

  defmodule ForgedStore do
    @behaviour Spectre.Store
    @impl true
    def get(_key, opts), do: opts[:reply]
    @impl true
    def compare_and_swap(_key, _revision, _value, opts), do: opts[:write_reply]
  end

  defmodule CrashingStore do
    @behaviour Spectre.Store
    @impl true
    def get(_key, _opts), do: raise("private backend connection")
    @impl true
    def compare_and_swap(_key, _revision, _value, _opts), do: raise("maybe committed")
  end

  setup do
    pid = start_supervised!(Memory)
    %{store: {Memory, server: pid}}
  end

  test "an application adapter stores exact canonical values and advances one revision", %{
    store: store
  } do
    assert :not_found = Store.get(store, "state:a")
    assert {:ok, 1} = Store.compare_and_swap(store, "state:a", 0, %{"turns" => 1})
    assert {:ok, 1, %{"turns" => 1}} = Store.get(store, "state:a")
    assert {:error, :conflict} = Store.compare_and_swap(store, "state:a", 0, :lost)
    assert {:ok, 2} = Store.compare_and_swap(store, "state:a", 1, %{"turns" => 2})
    assert {:ok, 2, %{"turns" => 2}} = Store.get(store, "state:a")
  end

  test "concurrent writers have exactly one successful CAS", %{store: store} do
    results =
      1..32
      |> Task.async_stream(&Store.compare_and_swap(store, "race", 0, &1), max_concurrency: 32)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, 1})) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 31
    assert {:ok, 1, value} = Store.get(store, "race")
    assert value in 1..32
  end

  test "deletion cannot reset the fence for a stale writer", %{store: store} do
    assert {:ok, 1} = Store.compare_and_swap(store, "state", 0, "private")
    assert {:ok, 2} = Store.delete(store, "state", 1)
    assert {:deleted, 2} = Store.get(store, "state")
    assert {:error, :conflict} = Store.compare_and_swap(store, "state", 0, "stale")
    assert {:error, :conflict} = Store.compare_and_swap(store, "state", 1, "stale")
    assert {:ok, 3} = Store.compare_and_swap(store, "state", 2, "explicit new value")
  end

  test "immutable publication is idempotent but exact, not numeric-equivalent", %{store: store} do
    assert :ok = Store.put_new(store, "asset", %{value: 1})
    assert :ok = Store.put_new(store, "asset", %{value: 1})
    assert {:error, :immutable_store_conflict} = Store.put_new(store, "asset", %{value: 1.0})
    assert {:ok, 1, %{value: 1}} = Store.get(store, "asset")
  end

  test "immutable publication never resurrects a deleted key", %{store: store} do
    assert :ok = Store.put_new(store, "asset", "original")
    assert {:ok, 2} = Store.delete(store, "asset", 1)
    assert {:error, :immutable_store_conflict} = Store.put_new(store, "asset", "original")
  end

  test "portable boundary refuses capabilities and malformed revisions before writing", %{
    store: store
  } do
    for value <- [self(), make_ref(), fn -> :ok end, [1 | :invalid]] do
      assert {:error, _} = Store.compare_and_swap(store, "state", 0, value)
    end

    for revision <- [0.0, -1, nil, "0"] do
      assert {:error, :invalid_store_revision} =
               Store.compare_and_swap(store, "state", revision, "data")
    end

    assert :not_found = Store.get(store, "state")
  end

  test "backend floating revisions and malformed bytes cannot reach callers" do
    for reply <- [
          {:ok, 1.0, Value.encode!("data")},
          {:ok, 0, Value.encode!("data")},
          {:ok, 1, "bad bytes"},
          {:ok, 1.0, :deleted},
          {:ok, 1, self()}
        ] do
      assert {:error, _} = Store.get({ForgedStore, reply: reply}, "key")
    end
  end

  test "malformed success or a crashing write is ambiguous, never retried" do
    for reply <- [:ok, {:ok, 1.0}, {:ok, 2}, nil] do
      assert {:error, {:ambiguous, :invalid_store_write_reply}} =
               Store.compare_and_swap({ForgedStore, write_reply: reply}, "key", 0, "data")
    end

    assert {:error,
            {:ambiguous,
             {:adapter_callback_exception, CrashingStore, :compare_and_swap, RuntimeError}}} =
             Store.compare_and_swap(CrashingStore, "key", 0, "data")
  end

  test "read failures stay read failures without leaking connection details" do
    assert {:error, {:adapter_callback_exception, CrashingStore, :get, RuntimeError}} =
             Store.get(CrashingStore, "key")

    assert {:error, :offline} = Store.get({ForgedStore, reply: {:error, :offline}}, "key")
  end

  test "a stopped volatile store reports failure instead of recreating lost state", %{
    store: {Memory, opts} = store
  } do
    assert :ok = Store.put_new(store, "asset", "data")
    GenServer.stop(opts[:server])
    assert {:error, {:adapter_callback_failure, Memory, :get, :exit}} = Store.get(store, "asset")
  end

  test "Definition publication is independently verified and does not activate anything", %{
    store: store
  } do
    definition = definition()
    assert {:ok, ref} = Definitions.publish(store, definition)
    assert ref == definition.ref
    assert {:ok, ^ref} = Definitions.publish(store, definition)
    assert {:ok, ^definition} = Definitions.fetch(store, ref)
    assert {:ok, revised} = Definition.revise(definition, %{"new" => "body"}, 1)
    assert :not_found = Definitions.fetch(store, revised.ref)
    assert {:ok, _} = Definitions.publish(store, revised)
    assert {:ok, ^definition} = Definitions.fetch(store, ref)
    assert {:ok, ^revised} = Definitions.fetch(store, revised.ref)
  end

  test "a valid Definition returned under a different reference is rejected" do
    original = definition()
    {:ok, revised} = Definition.revise(original, %{}, 1)
    adapter = {ForgedStore, reply: {:ok, 1, Value.encode!(Definition.canonical(revised))}}
    assert {:error, :definition_store_lookup_mismatch} = Definitions.fetch(adapter, original.ref)
  end

  test "forged digest and invisible acknowledged publication both fail" do
    original = definition()
    tampered = original |> Definition.canonical() |> Map.put("name", "forged")

    assert {:error, _} =
             Definitions.fetch(
               {ForgedStore, reply: {:ok, 1, Value.encode!(tampered)}},
               original.ref
             )

    assert {:error, :definition_store_write_not_visible} =
             Definitions.publish(
               {ForgedStore, write_reply: {:ok, 1}, reply: :not_found},
               original
             )
  end

  test "invalid keys and store options do not invoke a backend", %{store: store} do
    for key <- [nil, "", String.duplicate("x", 1025)] do
      assert {:error, :invalid_store_key} = Store.get(store, key)
    end

    assert {:error, :invalid_store_options} = Store.normalize({Memory, [:invalid]})
    assert {:error, _} = Store.normalize(String)
  end

  test "checkpoints preserve local state revision separately from the CAS fence", %{store: store} do
    definition = definition()

    assert {:ok, 1} =
             Checkpoint.save(store, "mind", 0, "domain", definition.ref, %{
               revision: 7,
               value: %{turns: 9}
             })

    assert {:ok, %{revision: 7, value: %{turns: 9}}} =
             Checkpoint.load(store, "mind", "domain", definition.ref)

    assert {:error, :conflict} =
             Checkpoint.save(store, "mind", 0, "domain", definition.ref, %{
               revision: 8,
               value: %{}
             })
  end

  test "checkpoint cannot transplant state into another Domain or Definition", %{store: store} do
    definition = definition()
    {:ok, revised} = Definition.revise(definition, %{}, 1)

    assert {:ok, 1} =
             Checkpoint.save(store, "mind", 0, "domain", definition.ref, %{
               revision: 1,
               value: "state"
             })

    assert {:error, :instance_checkpoint_binding_mismatch} =
             Checkpoint.load(store, "mind", "other-domain", definition.ref)

    assert {:error, :instance_checkpoint_binding_mismatch} =
             Checkpoint.load(store, "mind", "domain", revised.ref)
  end

  test "extra checkpoint fields and floating local revisions cannot restore authority", %{
    store: store
  } do
    definition = definition()

    assert {:ok, 1} =
             Checkpoint.save(store, "mind", 0, "domain", definition.ref, %{
               revision: 1,
               value: "state"
             })

    assert {:ok, 1, record} = Store.get(store, "mind")
    assert {:ok, 2} = Store.compare_and_swap(store, "mind", 1, Map.put(record, "scope", "forged"))

    assert {:error, :instance_checkpoint_binding_mismatch} =
             Checkpoint.load(store, "mind", "domain", definition.ref)

    assert {:ok, 3} =
             Store.compare_and_swap(store, "mind", 2, Map.put(record, "state_revision", 1.0))

    assert {:error, :invalid_checkpoint_state_revision} =
             Checkpoint.load(store, "mind", "domain", definition.ref)
  end

  test "missing or deleted checkpoints do not silently manufacture initial state", %{store: store} do
    ref = definition().ref

    assert {:error, :instance_checkpoint_not_found} =
             Checkpoint.load(store, "mind", "domain", ref)

    assert {:ok, 1} =
             Checkpoint.save(store, "mind", 0, "domain", ref, %{revision: 1, value: "state"})

    assert {:ok, 2} = Store.delete(store, "mind", 1)

    assert {:error, :instance_checkpoint_not_found} =
             Checkpoint.load(store, "mind", "domain", ref)
  end

  defp definition do
    {:ok, definition} =
      Definition.new(namespace: "store-test", name: "agent", revision: 1, declared_at: 0)

    definition
  end
end
