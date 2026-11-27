defmodule Spectre.Server.DiskStoreCompatibilityTest do
  use ExUnit.Case, async: false

  alias ExGAM.Canonical.Value
  alias Spectre.Server.Store.Disk

  @tag :tmp_dir
  test "a version-one checkpoint snapshot upgrades without losing its revision fence", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "legacy.snapshot")

    write_snapshot(path, %{
      version: 1,
      entries: %{"agent" => %{revision: 7, value: "saved checkpoint"}}
    })

    store = start_supervised!({Disk, path: path})
    assert {:ok, %{revision: 7, value: "saved checkpoint"}} = Disk.fetch(store, "agent")
    assert {:ok, 8} = Disk.compare_and_swap(store, "agent", 7, "upgraded checkpoint")
    assert {:error, :conflict} = Disk.compare_and_swap(store, "agent", 7, "stale writer")
  end

  @tag :tmp_dir
  test "unknown versions and malformed legacy entries do not become empty state", %{
    tmp_dir: directory
  } do
    Process.flag(:trap_exit, true)

    for {name, snapshot} <- [
          {"unknown", %{version: 99, entries: %{}}},
          {"not-map", %{version: 1, entries: []}},
          {"invalid-revision",
           %{version: 1, entries: %{"agent" => %{revision: -1, value: "saved"}}}}
        ] do
      path = Path.join(directory, name)
      write_snapshot(path, snapshot)
      assert {:error, :invalid_store_snapshot} = Disk.start_link(path: path)
    end

    directory_path = Path.join(directory, "not-a-file")
    File.mkdir_p!(directory_path)
    assert {:error, :invalid_store_snapshot} = Disk.start_link(path: directory_path)
  end

  @tag :tmp_dir
  test "a disappeared storage directory fails the write and stops the owner", %{
    tmp_dir: directory
  } do
    Process.flag(:trap_exit, true)
    parent = Path.join(directory, "storage")
    {:ok, store} = Disk.start_link(path: Path.join(parent, "state.snapshot"))
    monitor = Process.monitor(store)
    File.rmdir!(parent)
    assert {:error, :enoent} = Disk.put_new(store, "agent", "checkpoint")
    assert_receive {:DOWN, ^monitor, :process, ^store, {:store_write_failed, :enoent}}, 1_000
  end

  # Version-one is an import fixture: current writes use version two. A valid
  # checksum alone must not turn an unsupported or malformed schema into state.
  defp write_snapshot(path, value) do
    bytes = Value.encode!(value)
    File.write!(path, "SPSS1" <> :crypto.hash(:sha256, bytes) <> bytes)
  end
end
