Code.require_file("../v0_4/support/fixture.ex", __DIR__)

defmodule Spectre.CoreTest.AuditExportTest do
  use ExUnit.Case, async: false

  alias Spectre.Audit
  alias Spectre.Audit.Export
  alias Spectre.Domain.Sequencer
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "audit-export")
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    %{fixture: fixture}
  end

  test "portable audit survives removal of the live Domain and store", %{fixture: fixture} do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)

    assert {:ok, %{act: act}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 100, evidence_refs: [payment.ref])
             )

    snapshot = Fixture.snapshot(fixture)
    assert {:ok, expected} = Audit.verify(snapshot, fixture.constitution, Runtime.now())
    export = export(fixture)
    assert {:ok, encoded} = Export.encode(export)
    assert {:ok, ^encoded} = Export.encode(export)
    Fixture.stop_domain(fixture)

    assert {:ok, ^export} = Export.decode(encoded)
    assert {:ok, ^expected} = Export.verify(encoded)
    assert {:ok, ^expected} = Export.verify(export, Runtime.now())
    assert expected.counts.acts == 1
    assert [%{act_ref: act_ref}] = expected.act_contexts
    assert act_ref == act.ref

    assert Enum.sort(Map.keys(export)) ==
             ~w(constitution exported_at format format_version ledger)
  end

  test "Genesis pins the exact Constitution, not merely valid rules", %{fixture: fixture} do
    assert {:ok, ledger} = Ledger.export_snapshot(Fixture.snapshot(fixture))
    changed = Map.put(fixture.constitution, "application_policy_revision", 2)
    assert :ok = Spectre.Constitution.validate(changed)

    assert {:error, :audit_export_constitution_mismatch} =
             Export.new(ledger, changed, Runtime.now())
  end

  test "capture time must cover every ledger entry and audit time must be valid", %{
    fixture: fixture
  } do
    assert {:ok, ledger} = Ledger.export_snapshot(Fixture.snapshot(fixture))
    now = Runtime.now()

    assert {:error, {:audit_export_time_precedes_ledger, _, ^now}} =
             Export.new(ledger, fixture.constitution, now - 1)

    for time <- [-1, "later", 1.5] do
      assert {:error, {:invalid_audit_time, ^time}} = Export.verify(export(fixture), time)
    end
  end

  test "unknown fields, missing fields and incompatible headers are rejected", %{fixture: fixture} do
    data = export(fixture)

    assert {:error, {:unknown_audit_export_fields, ["projection"]}} =
             Export.from_data(Map.put(data, "projection", %{}))

    for field <- Map.keys(data) do
      assert {:error, {:missing_audit_export_field, ^field}} =
               Export.from_data(Map.delete(data, field))
    end

    assert {:error, {:unsupported_audit_export_format, "other"}} =
             Export.from_data(%{data | "format" => "other"})

    assert {:error, {:unsupported_audit_export_version, 2}} =
             Export.from_data(%{data | "format_version" => 2})

    assert {:error, :invalid_audit_export_header} = Export.from_data(%{data | "format" => nil})
    assert {:error, :invalid_audit_export} = Export.from_data([])
    assert {:error, :invalid_audit_export} = Export.verify(nil)
    assert {:error, :invalid_audit_export_input} = Export.new(nil, %{}, 0)
  end

  test "a damaged ledger cannot be hidden by a valid export envelope", %{fixture: fixture} do
    data = export(fixture)
    damaged = put_in(data, ["ledger", "revision"], data["ledger"]["revision"] + 1)
    assert {:error, _reason} = Export.from_data(damaged)
    assert {:error, _reason} = Export.encode(damaged)
    assert {:error, _reason} = Export.decode("not a canonical export")
  end

  test "a structurally valid empty ledger is not a self-contained semantic audit" do
    assert {:ok, ledger} =
             Ledger.export_snapshot(%{
               domain_ref: "empty",
               revision: 0,
               head_digest: Entry.genesis_digest(),
               entries: []
             })

    assert {:error, :audit_export_genesis_missing} = Export.new(ledger, %{}, 0)
  end

  test "the export budget is independent of the per-record budget", %{fixture: fixture} do
    snapshot = Fixture.snapshot(fixture)
    blob = :binary.copy(<<42>>, 9 * 1_024 * 1_024)

    # A structurally valid ledger with two separately bounded records. This
    # tests the export envelope, not semantic admission of arbitrary payloads.
    expanded =
      Enum.reduce(1..2, snapshot, fn index, current ->
        assert {:ok, entry} =
                 Entry.build(
                   current.domain_ref,
                   current.revision + 1,
                   "large-export-#{index}",
                   0,
                   1,
                   Runtime.now(),
                   current.head_digest,
                   %{"blob" => blob}
                 )

        %{
          current
          | entries: current.entries ++ [entry],
            revision: entry.revision,
            head_digest: entry.digest
        }
      end)

    assert {:ok, ledger} = Ledger.export_snapshot(expanded)
    assert {:ok, data} = Export.new(ledger, fixture.constitution, Runtime.now())
    assert {:error, {:canonical_value_too_large, _, 16_777_216}} = Export.encode(data)
    assert {:ok, encoded} = Export.encode(data, max_bytes: 20 * 1_024 * 1_024)
    assert {:error, {:canonical_value_too_large, _, 16_777_216}} = Export.decode(encoded)
    assert {:ok, ^data} = Export.decode(encoded, max_bytes: 20 * 1_024 * 1_024)
  end

  defp export(fixture) do
    assert {:ok, ledger} = Ledger.export_snapshot(Fixture.snapshot(fixture))
    assert {:ok, data} = Export.new(ledger, fixture.constitution, Runtime.now())
    data
  end
end
