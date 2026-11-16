defmodule Spectre.Server.StorePageTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.Store.{Disk, Page, Port}
  alias Spectre.Server.GAM.Managed.Store, as: Memory

  for adapter <- [Memory, Disk] do
    @tag :tmp_dir
    test "#{adapter} lists only the namespace with exclusive, namespace-bound cursors", %{
      tmp_dir: path
    } do
      adapter = unquote(adapter)
      store = start_supervised!({adapter, path: Path.join(path, "store")})
      port = {adapter, store}

      for {key, value} <- [
            {{:approval, "owner", "a", "peer"}, 1},
            {{:approval, "owner", "b", "peer"}, 2},
            {{:approval, "owner", "c", "peer"}, 3},
            {{:approval, "other", "a", "peer"}, 99},
            {{:other, "owner"}, 99},
            {:unrelated, 99}
          ] do
        assert {:ok, _} = Port.put_new(port, key, value)
      end

      assert {:ok, first, cursor} = Port.list(port, {:approval, "owner"}, limit: 2)
      assert Enum.map(first, fn {_, entry} -> entry.value end) == [1, 2]

      assert {:ok, [{key, %{value: 3, revision: revision}}], nil} =
               Port.list(port, {:approval, "owner"}, after: cursor)

      assert {:error, :invalid_store_page} = Port.list(port, {:approval, "other"}, after: cursor)
      assert :ok = Port.delete(port, key, revision)
      assert {:ok, _, nil} = Port.list(port, {:approval, "owner"})
    end
  end

  test "keyset lookup touches only one page and bounds bytes before materializing more values" do
    keys = Enum.map(1..10_000, &{:approval, "owner", &1})
    index = Page.index(keys)
    Process.put(:page_reads, 0)

    fetch = fn _ ->
      Process.put(:page_reads, Process.get(:page_reads) + 1)
      %{revision: 1, value: String.duplicate("x", 100)}
    end

    assert {:ok, entries, cursor} = Page.read(index, fetch, {:approval, "owner"}, limit: 3)
    assert length(entries) == 3
    assert Process.get(:page_reads) == 3
    assert {:ok, next, _} = Page.read(index, fetch, {:approval, "owner"}, after: cursor, limit: 3)
    assert MapSet.disjoint?(MapSet.new(entries), MapSet.new(next))

    assert {:error, :store_page_entry_too_large} =
             Page.read(index, fetch, {:approval}, max_bytes: 1)

    assert {:error, :invalid_store_page} = Page.read(index, fetch, {:approval}, limit: 0)
    assert {:error, :invalid_store_page} = Page.read(index, fetch, {:approval}, after: :invented)
    assert {:ok, [], nil} = Page.read(index, fetch, {:missing}, [])
  end

  test "page boundaries bound bytes and reject malformed cursors and portable keys" do
    assert Page.upper_bound(<<1, 255>>) == <<2>>
    assert Page.upper_bound(<<255>>) == nil
    assert {:error, :invalid_store_page} = Page.options(:not_tuple, [])
    assert {:error, :invalid_store_page} = Page.options({self()}, [])
    assert {:error, :invalid_store_page} = Page.options({:a}, limit: 1, limit: 2)

    assert {:error, :invalid_store_page} =
             Page.options({:a}, after: {:store_page, 1, Page.key({:a}), <<0>>})

    index = Page.index([{:a, 1}, {:a, 2}])
    fetch = fn _ -> %{revision: 1, value: String.duplicate("x", 100)} end
    assert {:ok, [_], cursor} = Page.read(index, fetch, {:a}, max_bytes: 200)
    refute is_nil(cursor)
    assert {:ok, [_], nil} = Page.read(index, fetch, {:a}, max_bytes: 200, after: cursor)
  end

  defmodule Legacy do
    def fetch(_, _), do: :not_found
  end

  test "listing remains an optional capability" do
    assert {:error, :store_list_unavailable} = Port.list({Legacy, :reference}, {:approval})
  end
end
