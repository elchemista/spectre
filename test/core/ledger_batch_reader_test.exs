defmodule Spectre.CoreTest.LedgerBatchReaderTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger
  alias Spectre.Ledger.{Entry, Reader, Store}
  alias Spectre.Ledger.Store.ETS

  defmodule Scripted do
    def head(_domain, opts), do: {:ok, Keyword.fetch!(opts, :head)}

    def read_batch(_domain, revision, opts) do
      send(self(), {:read_batch, revision})
      Keyword.fetch!(opts, :read).(revision)
    end
  end

  setup do
    server = start_supervised!({ETS, compressed: true})
    store = {ETS, server: server}

    for n <- 0..4 do
      assert {:ok, _} =
               Store.append(store, "domain", "b#{n}", [%{"n" => n}, %{"n" => n}], n * 2,
                 recorded_at: n
               )
    end

    {:ok, snapshot} = Ledger.load(store, "domain")
    %{store: store, snapshot: snapshot, zero: %{revision: 0, head_digest: Entry.genesis_digest()}}
  end

  test "indexed batches reproduce exactly the independent full read", ctx do
    assert {:ok, actual} =
             Reader.reduce(ctx.store, "domain", ctx.zero, [], fn batch, acc ->
               {:ok, acc ++ batch}
             end)

    assert actual === ctx.snapshot.entries
    assert Store.batch_reads?(ctx.store)
    assert {:ok, %{entries: entries, revision: 4}} = Store.read_batch(ctx.store, "domain", 3)
    assert Enum.map(entries, & &1.revision) === [3, 4]
    assert {:error, :ledger_cursor_inside_batch} = Store.read_batch(ctx.store, "domain", 2)
  end

  test "concurrent append does not extend the captured prefix", ctx do
    assert {:ok, 10} =
             Reader.reduce(ctx.store, "domain", ctx.zero, 0, fn batch, count ->
               if count == 0 do
                 assert {:ok, 11} =
                          Store.append(ctx.store, "domain", "later", [%{"later" => true}], 10,
                            recorded_at: 9
                          )
               end

               {:ok, count + length(batch)}
             end)

    assert {:ok, %{revision: 11}} = Store.head(ctx.store, "domain")
  end

  test "resume does not ask the adapter for any earlier batch", ctx do
    predecessor = Enum.at(ctx.snapshot.entries, 3)
    prefix = %{revision: 4, head_digest: predecessor.digest}
    store = scripted(ctx, fn revision -> Store.read_batch(ctx.store, "domain", revision) end)

    assert {:ok, 6} =
             Reader.reduce(store, "domain", prefix, 0, fn batch, count ->
               {:ok, count + length(batch)}
             end)

    assert_received {:read_batch, 5}
    assert_received {:read_batch, 7}
    assert_received {:read_batch, 9}
    refute_received {:read_batch, 1}
    refute_received {:read_batch, 3}
  end

  test "a missing page is not a shorter successful recovery", ctx do
    store =
      scripted(ctx, fn
        3 -> :not_found
        revision -> Store.read_batch(ctx.store, "domain", revision)
      end)

    assert {:error, {:ledger_read_missing_batch, 3}} =
             Reader.reduce(store, "domain", ctx.zero, 0, fn batch, n ->
               {:ok, n + length(batch)}
             end)
  end

  test "a forged or empty page never reaches the reducer", ctx do
    {:ok, original} = Store.read_batch(ctx.store, "domain", 1)
    [first, last] = original.entries

    for page <- [
          %{original | entries: []},
          %{original | entries: [first]},
          %{original | entries: [%{first | payload: %{"tampered" => true}}, last]},
          %{original | domain_ref: "foreign"},
          %{original | revision: 2.0},
          %{original | head_digest: Entry.genesis_digest()}
        ] do
      store = scripted(ctx, fn _ -> {:ok, page} end)

      assert {:error, _} =
               Reader.reduce(store, "domain", ctx.zero, nil, fn _, _ ->
                 flunk("unverified data reached the reducer")
               end)
    end
  end

  test "final digest must match the captured head, even if every page verifies", ctx do
    store =
      {Scripted,
       head: %{revision: 10, head_digest: Entry.genesis_digest()},
       read: fn n -> Store.read_batch(ctx.store, "domain", n) end}

    assert {:error, :ledger_read_head_mismatch} =
             Reader.reduce(store, "domain", ctx.zero, nil, fn _, acc -> {:ok, acc} end)
  end

  test "future history and multiple batches are rejected before reduction", ctx do
    store = scripted(ctx, fn _ -> {:ok, ctx.snapshot} end)

    assert {:error, :ledger_read_multiple_batches} =
             Reader.reduce(store, "domain", ctx.zero, nil, fn _, _ ->
               flunk("oversized page reached reducer")
             end)
  end

  test "adapter failures and reducer rejection stop traversal", ctx do
    store = scripted(ctx, fn _ -> {:error, :offline} end)

    assert {:error, :offline} =
             Reader.reduce(store, "domain", ctx.zero, nil, fn _, x -> {:ok, x} end)

    assert {:error, :semantic_rejection} =
             Reader.reduce(ctx.store, "domain", ctx.zero, nil, fn _, _ ->
               {:error, :semantic_rejection}
             end)
  end

  test "individually valid pages cannot hide a clock regression between batches", ctx do
    {:ok, first} =
      Entry.build_batch("domain", "first", [%{"x" => 1}], 0, 100, Entry.genesis_digest())

    {:ok, second} = Entry.build_batch("domain", "second", [%{"x" => 2}], 1, 99, hd(first).digest)

    pages =
      Map.new([first, second], fn [entry] = entries ->
        {entry.revision,
         %{
           domain_ref: "domain",
           revision: entry.revision,
           head_digest: entry.digest,
           entries: entries,
           recovery: nil
         }}
      end)

    store =
      {Scripted,
       head: %{revision: 2, head_digest: hd(second).digest},
       read: fn revision -> {:ok, Map.fetch!(pages, revision)} end}

    assert {:error, {:ledger_time_regression, 99, 100}} =
             Reader.reduce(store, "domain", ctx.zero, nil, fn _, acc -> {:ok, acc} end)
  end

  defp scripted(ctx, read) do
    {Scripted, head: Map.take(ctx.snapshot, [:revision, :head_digest]), read: read}
  end
end
