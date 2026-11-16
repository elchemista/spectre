Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.LedgerEnvelopeBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.GAM.Domain.Event
  alias Spectre.GAM.Ledger
  alias Spectre.GAM.Ledger.Entry
  alias Spectre.GAM.Ledger.Store.{ETS, Mock}

  setup do
    {:ok, entries} =
      Entry.build_batch(
        "domain",
        "first",
        [%{"operation" => "save"}],
        0,
        100,
        Entry.genesis_digest()
      )

    {:ok, snapshot} = Entry.verify_chain(entries)
    {:ok, export} = Ledger.export_snapshot(snapshot)
    %{entry: hd(entries), snapshot: snapshot, export: export}
  end

  test "store failures and absent exports remain distinguishable from corrupt history", c do
    server = start_supervised!(ETS)
    store = {ETS, server: server}
    assert :not_found = Ledger.verify_store(store, "domain")

    assert {:ok, 1} =
             ETS.append("domain", "first", [c.entry.payload], 0, server: server, recorded_at: 100)

    assert {:ok, verified} = Ledger.verify_store(store, "domain")
    assert verified.entries == [c.entry]
    mock = start_supervised!({Mock, store: store})
    assert :ok = Mock.push(mock, {:export, :before, {:error, :storage_unavailable}})
    assert {:error, :storage_unavailable} = Ledger.verify_store({Mock, server: mock}, "domain")
    assert :ok = Mock.push(mock, {:load, :before, {:error, :storage_unavailable}})
    assert {:error, :storage_unavailable} = Ledger.load({Mock, server: mock}, "domain")
    assert {:ok, recovered} = Ledger.verify_store({Mock, server: mock}, "domain")
    assert recovered === verified
  end

  test "missing entries are not an empty verified ledger", c do
    for invalid <- [nil, false, %{}, "entries"] do
      assert {:error, :invalid_ledger_export_entries} =
               Ledger.verify(Map.put(c.export, "entries", invalid))

      assert {:error, :invalid_ledger_snapshot_entries} =
               Ledger.verify_snapshot(%{c.snapshot | entries: invalid})

      assert {:error, :invalid_ledger_snapshot_entries} =
               Ledger.verify_suffix(%{c.snapshot | entries: invalid}, "domain", %{
                 revision: 0,
                 head_digest: Entry.genesis_digest()
               })
    end

    assert {:error, :invalid_ledger_export} = Ledger.verify(nil)
    assert {:error, :invalid_ledger_snapshot} = Ledger.verify_snapshot(nil)
    assert {:error, :invalid_ledger_snapshot} = Ledger.verify_suffix(nil, "domain", %{})

    assert {:error, :invalid_ledger_recovery_metadata} =
             Ledger.verify_snapshot(Map.put(c.snapshot, :recovery, []))

    assert {:error, {:unsupported_ledger_export, "spectre-domain-ledger", 2}} =
             Ledger.verify(Map.put(c.export, "format_version", 2))
  end

  test "a rehashed chain cannot conceal backward time or reuse a completed batch identity", c do
    {:ok, regressed} =
      Entry.build_batch("domain", "second", [%{"operation" => "observe"}], 1, 99, c.entry.digest)

    assert {:error, {:ledger_recorded_at_regressed, 2, 100, 99}} =
             Ledger.verify_snapshot(snapshot([c.entry | regressed]))

    {:ok, reused} =
      Entry.build_batch("domain", "first", [%{"operation" => "observe"}], 1, 101, c.entry.digest)

    assert {:error, {:duplicate_ledger_batch, "first"}} =
             Ledger.verify_snapshot(snapshot([c.entry | reused]))

    {:ok, batch} =
      Entry.build_batch("domain", "multiple", [%{}, %{}], 0, 100, Entry.genesis_digest())

    assert {:error, {:incomplete_ledger_batch, "multiple"}} =
             Ledger.verify_snapshot(snapshot([hd(batch)]))

    # The prefix is well hashed; batch completeness is a separate property.
    assert {:ok, _} = Entry.verify_chain([hd(batch)])
  end

  test "Domain envelopes reject unversioned, mistyped and extra data before semantic replay" do
    payload = Event.envelope("evidence_recorded", "evidence", %{"observed_at" => 100})
    assert {:ok, event} = Event.decode(payload)
    assert {:error, :missing_event_metadata} = Event.metadata(event)
    assert {:error, :invalid_domain_event} = Event.decode(nil)
    assert {:error, :invalid_domain_event_entry} = Event.decode_entry(nil)

    assert {:error, :invalid_domain_event_metadata} =
             Event.decode_payload(payload, 1.0, "batch", 0, 100)

    for {key, value, reason} <- [
          {"schema_version", 2, {:unsupported_domain_event_schema_version, 2}},
          {"schema_version", 1.0, :invalid_domain_event_schema_version},
          {"type", "authority.created", {:unknown_domain_event, "authority.created"}},
          {"identity", "", :invalid_domain_event_identity},
          {"data", [], :invalid_domain_event_data}
        ] do
      assert {:error, ^reason} = Event.decode(Map.put(payload, key, value))
    end

    assert {:error, {:unknown_fields, :domain_event, ["authority"]}} =
             Event.decode(Map.put(payload, "authority", "root"))

    bad_act =
      Event.envelope("dispatch_ready", "dispatch_ready:nil", %{
        "act_ref" => nil,
        "executor_ref" => "executor",
        "executor_contract_ref" => "contract"
      })

    assert {:error, {:invalid_domain_event_act_ref, nil}} = Event.decode(bad_act)

    nested =
      Event.envelope("host_profile_revised", "revision", %{
        "act_ref" => "act",
        "previous_ref" => "old",
        "host_profile" => nil
      })

    assert {:error, {:event_from_future, "host_profile_revised", "declared_at", nil, 100}} =
             Event.decode_payload(nested, 1, "batch", 0, 100)
  end

  defp snapshot(entries) do
    last = List.last(entries)
    %{domain_ref: "domain", revision: last.revision, head_digest: last.digest, entries: entries}
  end
end
