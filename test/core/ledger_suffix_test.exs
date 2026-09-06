defmodule Spectre.Core.LedgerSuffixTest.FullReadAdapter do
  defdelegate load(domain, opts), to: Spectre.Ledger.Store.ETS
end

defmodule Spectre.Core.LedgerSuffixTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger
  alias Spectre.Ledger.{Entry, Store}
  alias Spectre.Ledger.Store.{Disk, ETS, Mock}

  @moduletag :tmp_dir

  for adapter <- [ETS, Disk] do
    describe "#{inspect(adapter)} suffix" do
      setup %{tmp_dir: directory} do
        adapter = unquote(adapter)
        opts = store_options(adapter, directory)
        server = start_supervised!({adapter, opts})
        store = {adapter, server: server}

        assert {:ok, 2} =
                 Store.append(store, "domain", "first", [%{"n" => 1}, %{"n" => 2}], 0,
                   recorded_at: 100
                 )

        assert {:ok, prefix} = Ledger.load(store, "domain")

        assert {:ok, 4} =
                 Store.append(store, "domain", "second", [%{"n" => 3}, %{"n" => 4}], 2,
                   recorded_at: 101
                 )

        %{store: store, prefix: Map.take(prefix, [:revision, :head_digest])}
      end

      test "reads only the suffix, with the same captured head as a full read", ctx do
        assert {:ok, full} = Ledger.load(ctx.store, "domain")
        assert {:ok, suffix} = Ledger.load_from(ctx.store, "domain", ctx.prefix)
        assert suffix.entries === Enum.drop(full.entries, 2)
        assert suffix.head_digest === full.head_digest
        assert suffix.revision === 4
        assert {:ok, %{entries: [], revision: 4}} = Ledger.load_from(ctx.store, "domain", suffix)

        assert {:ok, ^full} =
                 Ledger.load_from(ctx.store, "domain", %{
                   revision: 0,
                   head_digest: Entry.genesis_digest()
                 })
      end

      test "neither a forged predecessor nor a cursor inside an atomic batch is accepted", ctx do
        assert {:error, {:ledger_chain_mismatch, 3}} =
                 Ledger.load_from(ctx.store, "domain", %{
                   ctx.prefix
                   | head_digest: Entry.genesis_digest()
                 })

        assert {:ok, snapshot} = Ledger.load(ctx.store, "domain")
        first = hd(snapshot.entries)

        assert {:error, _} =
                 Ledger.load_from(ctx.store, "domain", %{revision: 1, head_digest: first.digest})

        assert {:error, :ledger_cursor_ahead_of_head} =
                 Ledger.load_from(ctx.store, "domain", %{ctx.prefix | revision: 5})
      end

      test "unknown Domain and invalid cursor cannot leak a different history", ctx do
        assert :not_found = Ledger.load_from(ctx.store, "missing", ctx.prefix)

        for cursor <- [
              nil,
              %{},
              %{ctx.prefix | revision: 2.0},
              %{ctx.prefix | revision: -1},
              %{ctx.prefix | head_digest: "bad"}
            ] do
          assert {:error, :invalid_ledger_cursor} = Ledger.load_from(ctx.store, "domain", cursor)
        end
      end
    end
  end

  test "older adapters have a verified full-read fallback" do
    server = start_supervised!({ETS, []})
    store = {ETS, server: server}
    assert {:ok, 1} = Store.append(store, "domain", "a", [%{"n" => 1}], 0, recorded_at: 1)
    assert {:ok, prefix} = Ledger.load(store, "domain")
    assert {:ok, 2} = Store.append(store, "domain", "b", [%{"n" => 2}], 1, recorded_at: 2)

    assert {:ok, %{entries: [%Entry{revision: 2}]}} =
             Ledger.load_from({__MODULE__.FullReadAdapter, server: server}, "domain", prefix)
  end

  test "a scripted store cannot omit or alter suffix entries or forge its head" do
    server = start_supervised!({ETS, []})
    store = {ETS, server: server}
    assert {:ok, 1} = Store.append(store, "domain", "a", [%{"n" => 1}], 0, recorded_at: 1)
    assert {:ok, prefix} = Ledger.load(store, "domain")

    assert {:ok, 3} =
             Store.append(store, "domain", "b", [%{"n" => 2}, %{"n" => 3}], 1, recorded_at: 2)

    assert {:ok, suffix} = Ledger.load_from(store, "domain", prefix)
    [first, last] = suffix.entries
    mock = start_supervised!({Mock, store: store})

    for corrupt <- [
          %{suffix | entries: [last]},
          %{suffix | entries: [first]},
          %{suffix | entries: [%{first | payload: %{"n" => "forged"}}, last]},
          %{suffix | entries: []},
          %{suffix | domain_ref: "foreign"},
          %{suffix | revision: 3.0},
          %{suffix | head_digest: prefix.head_digest}
        ] do
      assert :ok = Mock.push(mock, {:load_from, :before, {:ok, corrupt}})
      assert {:error, _} = Ledger.load_from({Mock, server: mock}, "domain", prefix)
    end
  end

  defp store_options(Disk, directory), do: [path: directory]
  defp store_options(ETS, _directory), do: []
end
