defmodule Spectre.Core.LedgerStoreBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger
  alias Spectre.Ledger.Store
  alias Spectre.Ledger.Store.ETS

  defmodule HostStore do
    @behaviour Spectre.Ledger.Store

    @impl true
    def append(domain, batch, payloads, revision, opts) do
      if Keyword.get(opts, :commit_first, false) do
        {:ok, _} =
          ETS.append(domain, batch, payloads, revision, Keyword.fetch!(opts, :backing_opts))
      end

      respond(:append, opts)
    end

    @impl true
    def load(_domain, opts), do: respond(:load, opts)
    @impl true
    def lookup_batch(_domain, _batch, opts), do: respond(:lookup_batch, opts)
    @impl true
    def export(_domain, opts), do: respond(:export, opts)

    defp respond(operation, opts) do
      send(Keyword.fetch!(opts, :observer), {:store_callback, operation, opts})

      case Keyword.fetch!(opts, :response) do
        :raise -> raise "private database credentials"
        :throw -> throw({:private, "database credentials"})
        :exit -> exit({:private, "database credentials"})
        {:reply, reply} -> reply
      end
    end
  end

  setup do
    server = start_supervised!({ETS, []})
    backing = {ETS, server: server}
    payloads = [%{"event" => "first"}, %{"event" => "second"}]
    assert {:ok, 2} = Store.append(backing, "tenant-A", "batch-A", payloads, 0, recorded_at: 1)

    assert {:ok, 1} =
             Store.append(backing, "tenant-B", "batch-B", [%{"other" => true}], 0, recorded_at: 1)

    {:ok, snapshot} = Ledger.load(backing, "tenant-A")
    {:ok, exported} = Ledger.export(backing, "tenant-A")

    %{
      backing: backing,
      server: server,
      payloads: payloads,
      snapshot: snapshot,
      exported: exported
    }
  end

  test "normalization preserves host options without executing callbacks" do
    config = host(:raise, timeout: 123)
    assert Store.normalize(config) == {:ok, config}
    assert Store.normalize(HostStore) == {:ok, {HostStore, []}}
    refute_received {:store_callback, _, _}
  end

  test "malformed adapter options are rejected before callback invocation" do
    for options <- [["bad"], %{}, nil] do
      assert {:error, _} = Store.normalize({HostStore, options})

      assert {:error, :invalid_ledger_store_options} =
               Store.load(host(:raise), "tenant-A", options)
    end

    refute_received {:store_callback, _, _}
  end

  test "missing callbacks are configuration errors, not uncertain commits" do
    assert {:error, {:ledger_store_callback_missing, __MODULE__, :append, 5}} =
             Store.append(__MODULE__, "tenant-A", "batch", [%{}], 0, [])
  end

  test "an unavailable module is detected before attempting I/O" do
    assert {:error, {:ledger_store_not_loaded, NotAnExistingLedgerAdapter}} =
             Store.load(NotAnExistingLedgerAdapter, "tenant-A", [])
  end

  test "call-specific options override adapter defaults without dropping private host configuration" do
    assert :not_found =
             Store.load(host({:reply, :not_found}, timeout: 10, private: :handle), "tenant-A",
               timeout: 20
             )

    assert_receive {:store_callback, :load, opts}
    assert opts[:timeout] == 20
    assert opts[:private] == :handle
  end

  for kind <- [:raise, :throw, :exit] do
    test "#{kind} after a real append is ambiguous and the complete batch remains recoverable",
         c do
      config =
        host(unquote(kind), commit_first: true, backing_opts: [server: c.server, recorded_at: 2])

      assert {:error, :ambiguous} =
               Store.append(config, "tenant-A", "batch-next", [%{"next" => 3}], 2, [])

      assert {:ok, snapshot} = Ledger.load(c.backing, "tenant-A")
      assert snapshot.revision == 3
      assert Enum.map(snapshot.entries, & &1.payload) == c.payloads ++ [%{"next" => 3}]
      assert {:ok, %{last_revision: 3}} = Ledger.lookup_batch(c.backing, "tenant-A", "batch-next")

      assert {:ok, 3} =
               Store.append(c.backing, "tenant-A", "batch-next", [%{"next" => 3}], 2,
                 recorded_at: 2
               )

      assert Ledger.load(c.backing, "tenant-A") == {:ok, snapshot}
    end
  end

  test "a malformed append acknowledgment cannot be promoted to success", c do
    for reply <- [:ok, nil, true, {:ok, -1}, {:ok, 1.0}, {:ok, %{revision: 3}}] do
      assert Store.append(host({:reply, reply}), "tenant-A", "batch-next", [%{}], 2, []) ==
               {:error, :ambiguous}
    end

    assert Ledger.load(c.backing, "tenant-A") == {:ok, c.snapshot}
  end

  test "an explicit CAS conflict remains distinguishable from uncertainty" do
    assert Store.append(host({:reply, {:error, :conflict}}), "tenant-A", "batch", [%{}], 2, []) ==
             {:error, :conflict}
  end

  test "an explicit storage rejection is not converted into a false success" do
    assert Store.append(host({:reply, {:error, :disk_full}}), "tenant-A", "batch", [%{}], 2, []) ==
             {:error, :disk_full}
  end

  for operation <- [:load, :lookup_batch, :export] do
    test "#{operation} distinguishes not-found from backend failure" do
      assert invoke(unquote(operation), host({:reply, :not_found})) == :not_found
      assert invoke(unquote(operation), host({:reply, {:error, :offline}})) == {:error, :offline}
    end

    test "#{operation} contains exceptions without exposing private diagnostic text" do
      assert invoke(unquote(operation), host(:raise)) ==
               {:error, {:ledger_store_exception, HostStore, unquote(operation), RuntimeError}}
    end

    test "#{operation} contains throws and exits without exposing private terms" do
      for kind <- [:throw, :exit] do
        assert invoke(unquote(operation), host(kind)) ==
                 {:error, {:ledger_store_failure, HostStore, unquote(operation), kind}}
      end
    end

    test "#{operation} rejects non-map success replies" do
      for value <- [nil, true, [], 1, "snapshot"] do
        assert invoke(unquote(operation), host({:reply, {:ok, value}})) ==
                 {:error, {:invalid_ledger_store_reply, HostStore, unquote(operation)}}
      end
    end
  end

  test "public load verifies a valid snapshot returned by a host adapter", c do
    assert Ledger.load(host({:reply, {:ok, c.snapshot}}), "tenant-A") == {:ok, c.snapshot}
  end

  test "public load rejects another tenant's otherwise valid snapshot", c do
    {:ok, other} = Ledger.load(c.backing, "tenant-B")

    assert {:error, :ledger_domain_mismatch} =
             Ledger.load(host({:reply, {:ok, other}}), "tenant-A")
  end

  test "public export rejects another tenant's otherwise valid export", c do
    {:ok, other} = Ledger.export(c.backing, "tenant-B")

    assert {:error, :ledger_domain_mismatch} =
             Ledger.export(host({:reply, {:ok, other}}), "tenant-A")

    assert Ledger.export(host({:reply, {:ok, c.exported}}), "tenant-A") == {:ok, c.exported}
  end

  test "public load checks entry digests instead of trusting snapshot shape", c do
    [entry | rest] = c.snapshot.entries
    altered = %{entry | payload: %{"forged" => true}}
    snapshot = %{c.snapshot | entries: [altered | rest]}

    assert {:error, {:ledger_entry_digest_mismatch, 1}} =
             Ledger.load(host({:reply, {:ok, snapshot}}), "tenant-A")
  end

  test "public export checks entry digests instead of trusting a successful adapter response",
       c do
    [entry | rest] = c.exported["entries"]

    exported =
      Map.put(c.exported, "entries", [Map.put(entry, "payload", %{"forged" => true}) | rest])

    assert {:error, {:ledger_entry_digest_mismatch, 1}} =
             Ledger.export(host({:reply, {:ok, exported}}), "tenant-A")
  end

  test "a snapshot summary cannot hide a truncated atomic batch", c do
    [first | _] = c.snapshot.entries
    snapshot = %{c.snapshot | entries: [first], revision: 1, head_digest: first.digest}

    assert {:error, {:incomplete_ledger_batch, "batch-A"}} =
             Ledger.load(host({:reply, {:ok, snapshot}}), "tenant-A")
  end

  test "invalid domain identifiers never reach the adapter" do
    for domain <- [nil, 1, ""] do
      assert {:error, _} = Ledger.load(host(:raise), domain)
      assert {:error, _} = Ledger.export(host(:raise), domain)
      assert {:error, _} = Ledger.lookup_batch(host(:raise), domain, "batch")
    end

    refute_received {:store_callback, _, _}
  end

  test "invalid lookup batch identifiers never reach the adapter" do
    for batch <- [nil, 1, ""] do
      assert {:error, _} = Ledger.lookup_batch(host(:raise), "tenant-A", batch)
    end

    refute_received {:store_callback, _, _}
  end

  defp host(response, opts \\ []),
    do: {HostStore, Keyword.merge([observer: self(), response: response], opts)}

  defp invoke(:load, store), do: Store.load(store, "tenant-A", [])
  defp invoke(:lookup_batch, store), do: Store.lookup_batch(store, "tenant-A", "batch-A", [])
  defp invoke(:export, store), do: Store.export(store, "tenant-A", [])
end
