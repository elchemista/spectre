defmodule Spectre.Server.ManagedStoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.GAM.Managed.Store

  test "CAS unwraps stored values, rejects stale writers and never reuses revisions" do
    store = start_supervised!({Store, []})
    assert :not_found = Store.fetch(store, :command)
    assert {:ok, first} = Store.put_new(store, :command, %{status: :new})
    assert {:error, :exists} = Store.put_new(store, :command, %{status: :duplicate})

    assert {:ok, second} = Store.compare_and_swap(store, :command, first, %{status: :shown})
    assert second > first
    assert {:error, :conflict} = Store.compare_and_swap(store, :command, first, %{status: :stale})
    assert {:ok, %{revision: ^second, value: %{status: :shown}}} = Store.fetch(store, :command)
    assert {:error, :conflict} = Store.delete(store, :command, first)
    assert :ok = Store.delete(store, :command, second)
    assert :not_found = Store.fetch(store, :command)
    assert {:ok, third} = Store.put_new(store, :command, %{status: :fresh})
    assert third > second

    assert {:error, :conflict} =
             Store.compare_and_swap(store, :command, second, %{status: :stale})
  end

  test "presentation nil is rejected at startup even when confirmation is dynamic" do
    alias Spectre.Server.GAM.Managed.Binding
    effects = %{mail: %{settings: [confirm: false], effect: %{schema_hash: "reviewed"}}}

    assert {:error, {:invalid_managed_bindings, _}} =
             Binding.validate_overrides(effects, %{mail: %{presentation: nil}})
  end

  test "managed overrides cannot remove confirmation or replace a registered schema" do
    alias Spectre.Server.GAM.Managed.Binding
    effects = %{mail: %{settings: [confirm: true], effect: %{schema_hash: "reviewed"}}}
    assert :ok = Binding.validate_overrides!(effects, %{})

    for overrides <- [
          %{unknown: %{}},
          %{mail: %{presentation: nil}},
          %{mail: %{schema_hash: "different"}},
          %{mail: %{candidate: fn -> :ok end}},
          %{mail: %{executor: {Kernel, :apply}}}
        ] do
      assert_raise ArgumentError, fn -> Binding.validate_overrides!(effects, overrides) end
    end
  end
end
