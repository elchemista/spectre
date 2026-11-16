defmodule Spectre.Server.DiskStoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.Store.Disk

  @tag :tmp_dir
  test "checkpoint and inbox persist atomically with revision fencing", %{tmp_dir: directory} do
    path = Path.join(directory, "server.snapshot")
    store = start_supervised!({Disk, path: path}, id: :store)
    assert :not_found = Disk.fetch(store, "agent:1")
    initial = %{checkpoint: %{assigns: %{}}, inbox: []}
    assert {:ok, 1} = Disk.put_new(store, "agent:1", initial)
    assert {:error, :exists} = Disk.put_new(store, "agent:1", initial)
    updated = %{checkpoint: %{assigns: %{deleted: true}}, inbox: ["event:1"]}
    assert {:ok, 2} = Disk.compare_and_swap(store, "agent:1", 1, updated)
    assert {:error, :conflict} = Disk.compare_and_swap(store, "agent:1", 1, initial)
    :ok = stop_supervised(:store)
    store = start_supervised!({Disk, path: path}, id: :store)
    assert {:ok, %{revision: 2, value: ^updated}} = Disk.fetch(store, "agent:1")
  end

  @tag :tmp_dir
  test "rejects volatile authority and detects snapshot corruption", %{tmp_dir: directory} do
    Process.flag(:trap_exit, true)
    path = Path.join(directory, "server.snapshot")
    store = start_supervised!({Disk, path: path}, id: :store)
    assert {:error, {:nonportable_store_value, _}} = Disk.put_new(store, "bad", self())
    assert :not_found = Disk.fetch(store, "bad")
    assert {:ok, 1} = Disk.put_new(store, "good", %{inbox: ["event:1"]})
    :ok = stop_supervised(:store)
    bytes = File.read!(path)
    <<first, rest::binary>> = bytes
    File.write!(path, <<Bitwise.bxor(first, 1), rest::binary>>)
    assert {:error, :invalid_store_snapshot} = Disk.start_link(path: path)
  end

  @tag :tmp_dir
  test "a second writer cannot own the same local file", %{tmp_dir: directory} do
    Process.flag(:trap_exit, true)
    path = Path.join(directory, "server.snapshot")
    start_supervised!({Disk, path: path})
    assert {:error, :store_path_in_use} = Disk.start_link(path: path)
  end

  @tag :tmp_dir
  test "directory symlink aliases cannot start a second writer", %{tmp_dir: directory} do
    Process.flag(:trap_exit, true)
    physical = Path.join(directory, "physical")
    alias_path = Path.join(directory, "alias")
    File.mkdir_p!(physical)
    File.ln_s!(physical, alias_path)
    store = start_supervised!({Disk, path: Path.join(physical, "server.snapshot")})
    assert {:ok, 1} = Disk.put_new(store, "checkpoint", %{inbox: ["event:1"]})

    assert {:error, :store_path_in_use} =
             Disk.start_link(path: Path.join(alias_path, "server.snapshot"))

    assert {:ok, 2} =
             Disk.compare_and_swap(store, "checkpoint", 1, %{inbox: ["event:1", "event:2"]})
  end

  @tag :tmp_dir
  test "capacity is distinct from portability and CAS deletion frees acquired metadata", %{
    tmp_dir: directory
  } do
    store =
      start_supervised!({Disk, path: Path.join(directory, "bounded.snapshot"), max_bytes: 512})

    {:ok, revision} = Disk.put_new(store, "journal", String.duplicate("x", 100))

    assert {:error, :store_capacity_exceeded} =
             Disk.put_new(store, "too-large", String.duplicate("x", 1_024))

    assert {:error, :conflict} = Disk.delete(store, "journal", revision + 1)
    assert :ok = Disk.delete(store, "journal", revision)
    assert :not_found = Disk.fetch(store, "journal")
    assert {:ok, _} = Disk.put_new(store, "checkpoint", String.duplicate("y", 100))
  end

  @tag :tmp_dir
  test "deletion and re-creation never reuse an old CAS revision across restart", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "fenced-delete.snapshot")
    store = start_supervised!({Disk, path: path}, id: :store)
    {:ok, first} = Disk.put_new(store, "operation", "old")
    assert :ok = Disk.delete(store, "operation", first)
    :ok = stop_supervised(:store)
    store = start_supervised!({Disk, path: path}, id: :store)
    {:ok, second} = Disk.put_new(store, "operation", "new")
    assert second > first
    assert {:error, :conflict} = Disk.compare_and_swap(store, "operation", first, "stale writer")
    assert {:ok, %{value: "new"}} = Disk.fetch(store, "operation")
  end
end
