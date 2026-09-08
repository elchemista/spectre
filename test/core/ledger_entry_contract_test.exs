defmodule Spectre.Core.LedgerEntryContractTest do
  use ExUnit.Case, async: true
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Support

  setup do
    payloads = [
      %{"event" => "read requested", "target" => "order:42"},
      %{"event" => "read admitted", "target" => "order:42"}
    ]

    {:ok, entries} =
      Entry.build_batch("domain", "batch", payloads, 0, 100, Entry.genesis_digest())

    %{entries: entries, first: hd(entries), payloads: payloads}
  end

  test "all construction forms preserve exact entry identity, while the wire form stays strict",
       c do
    assert Entry.schema_version() === c.first.schema_version
    assert {:ok, first} = Entry.new(c.first)
    assert first === c.first
    assert {:ok, ^first} = Entry.new(Map.to_list(Map.from_struct(first)))
    assert {:ok, %{entries: entries, domain_ref: "domain"}} = Entry.verify_chain(c.entries)
    assert entries === c.entries
    assert {:error, :noncanonical_ledger_entry} = Entry.from_data(Map.from_struct(first))

    for invalid <- [nil, "entry", 1] do
      assert {:error, :invalid_ledger_entry} = Entry.new(invalid)
      assert {:error, :invalid_ledger_entry} = Entry.verify(invalid)
      assert {:error, :invalid_ledger_entry_data} = Entry.from_data(invalid)
      assert {:error, :invalid_ledger_entry} = Entry.verify_chain([invalid])
    end

    assert {:error, :invalid_ledger_entry_encoding} = Entry.decode(%{})
    assert {:error, :invalid_ledger_entry_attributes} = Entry.new(revision: 1, revision: 2)
  end

  test "field validation precedes digest comparison for corrupt coordinates", c do
    for {field, value, reason} <- [
          {:schema_version, 2, {:unsupported_ledger_entry_schema, 2}},
          {:revision, 0, {:invalid_ledger_entry_field, :revision}},
          {:recorded_at, 1.0, {:invalid_ledger_entry_field, :recorded_at}},
          {:prev_digest, "short", {:invalid_ledger_entry_field, :prev_digest}}
        ] do
      assert {:error, ^reason} = Entry.verify(Map.replace!(c.first, field, value))
    end

    assert {:error, {:nonportable_ledger_payload, _}} =
             Entry.verify(%{c.first | payload: %{"capability" => self()}})

    assert {:error, :invalid_ledger_entries} = Entry.verify_chain(%{})
    assert {:error, :invalid_ledger_entries} = Entry.verify_chain([c.first | :truncated])

    assert {:error, :invalid_ledger_batch_payloads} =
             Entry.batch_identity("domain", "batch", %{}, 0)
  end

  test "storage-neutral installation retains earlier entries and both retry identities", c do
    empty = Support.empty_domain()
    {:ok, identity} = Entry.batch_identity("domain", "batch", c.payloads, 0)
    assert :new = Support.append_status(empty, "batch", identity, 0, nil)
    {first_domain, last} = Support.install_batch(empty, "batch", identity, 0, c.entries)
    assert {:existing, 2} = Support.append_status(first_domain, "batch", identity, 0, nil)

    assert {:error, {:batch_identity_conflict, "batch"}} =
             Support.append_status(first_domain, "batch", String.duplicate("f", 64), 0, nil)

    assert {:error, :conflict} = Support.append_status(first_domain, "next", identity, 0, nil)

    assert {:error, :ambiguous} =
             Support.append_status(first_domain, "next", identity, 2, :before_commit)

    {:ok, next} =
      Entry.build_batch("domain", "next", [%{"event" => "outcome"}], 2, 101, last.digest)

    {:ok, next_identity} = Entry.batch_identity("domain", "next", [%{"event" => "outcome"}], 2)
    {domain, _last} = Support.install_batch(first_domain, "next", next_identity, 2, next)
    snapshot = Support.snapshot("domain", domain)
    assert snapshot.entries === c.entries ++ next
    assert snapshot.revision === 3
    assert {:ok, ^snapshot} = Ledger.verify_snapshot(snapshot)
    assert Map.keys(domain.batches) |> Enum.sort() == ["batch", "next"]
    assert first_domain.revision === 2
  end

  test "batch derivation refuses malformed elements and cannot guess a missing acquisition time",
       c do
    assert {:error, :empty_ledger_batch} = Support.derive_batch_info("domain", [])
    assert {:error, :invalid_ledger_batch_entries} = Support.derive_batch_info("domain", [nil])

    for entries <- [[], nil, [c.first, nil]] do
      assert {:error, :ledger_batch_coordinates_mismatch} =
               Support.validate_batch_coordinates(entries, "domain", "batch")
    end

    assert {:error, :ledger_recorded_at_required} = Support.recorded_at([])
    assert {:error, :ledger_recorded_at_required} = Support.recorded_at(recorded_at: 1.0)

    assert {:error, :invalid_options} =
             Support.validate_options(%{}, [], :invalid_options, :unknown_options)
  end
end
