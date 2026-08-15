defmodule SpectreCanonicalAgentStateTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Change
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Snapshot
  alias Spectre.Instance.Canonical.Transition

  test "canonical state starts with typed, independently revisioned sections" do
    state = Canonical.new()

    assert state.revision == 0
    assert state.schema_version == 3
    assert state.journal == []
    assert state.applied_changes == %{}

    defaults = %{
      event_admissions: %{records: [], ids: %{}},
      event_quarantine: %{records: [], ids: %{}},
      receipt_outbox: %{entries: [], ids: %{}}
    }

    for name <- Sections.names(), name != :activation do
      expected = Map.get(defaults, name, %{})
      assert {:ok, ^expected} = Canonical.fetch(state, name)
      assert {:ok, 0} = Canonical.section_revision(state, name)

      assert {:ok, %Section{revision: 0, value: ^expected}} =
               Sections.fetch(state.sections, name)

      assert Sections.valid_name?(name)
    end

    assert {:ok, nil} = Canonical.fetch(state, :activation)

    assert {:ok, %Section{revision: 0, value: nil}} =
             Sections.fetch(state.sections, :activation)

    refute Sections.valid_name?(:mission)
    assert :error = Sections.fetch(state.sections, :mission)
    assert {:error, {:unknown_canonical_section, :mission}} = Canonical.fetch(state, :mission)

    assert {:error, {:unknown_canonical_section, :mission}} =
             Canonical.section_revision(state, :mission)
  end

  test "initial values are portable and fail closed on unknown sections" do
    assert {:ok, state} = Canonical.new(work: %{phase: :queued})
    assert {:ok, %{phase: :queued}} = Canonical.fetch(state, :work)

    assert {:error, {:unknown_canonical_section, :mission}} =
             Canonical.new(%{mission: %{}})

    assert {:error, {:invalid_canonical_initial_sections, :list}} = Canonical.new([:work])
    assert {:error, {:invalid_canonical_initial_sections, :integer}} = Canonical.new(12)

    for {value, shape} <- [
          {{:work}, :tuple},
          {"work", :binary},
          {1.5, :other}
        ] do
      assert {:error, {:invalid_canonical_initial_sections, ^shape}} = Canonical.new(value)
    end

    assert {:error, {:nonportable_canonical_value, {:nonportable_run_value, _, :pid}}} =
             Canonical.new(work: %{owner: self()})
  end

  test "read-only snapshots expose only authorized copies and cannot propose a merge" do
    assert {:ok, state} = Canonical.new(work: %{phase: :reading}, vigil: %{city: "Rome"})

    assert {:ok, snapshot} =
             Canonical.snapshot(state,
               read: [:work],
               id: "snapshot-read",
               correlation_id: "turn-1"
             )

    assert Snapshot.read_only?(snapshot)
    assert {:ok, %{phase: :reading}} = Snapshot.fetch(snapshot, :work)
    assert {:error, {:snapshot_section_not_readable, :vigil}} = Snapshot.fetch(snapshot, :vigil)
    refute Snapshot.writable?(snapshot, :work)

    detached = put_in(snapshot.sections.work.phase, :changed_locally)
    assert {:ok, %{phase: :reading}} = Canonical.fetch(state, :work)
    assert detached.sections.work.phase == :changed_locally

    assert {:error, :snapshot_read_only} =
             Canonical.change(snapshot, %{work: %{phase: :done}})
  end

  test "snapshot authorization rejects invalid read and write scopes" do
    state = Canonical.new()

    assert {:error, {:snapshot_write_without_read, :vigil}} =
             Canonical.snapshot(state, read: [:work], write: [:vigil])

    assert {:error, {:unknown_snapshot_section, :read, :mission}} =
             Canonical.snapshot(state, read: [:mission])

    assert {:error, {:unknown_snapshot_section, :write, :mission}} =
             Canonical.snapshot(state, read: [:work], write: [:mission])

    assert {:error, {:duplicate_snapshot_section, :read, :work}} =
             Canonical.snapshot(state, read: [:work, :work])

    assert {:error, {:duplicate_snapshot_section, :write, :work}} =
             Canonical.snapshot(state, read: [:work], write: [:work, :work])

    assert {:error, {:invalid_snapshot_sections, :read, :atom}} =
             Canonical.snapshot(state, read: :work)

    assert {:error, {:invalid_snapshot_sections, :write, :atom}} =
             Canonical.snapshot(state, read: [:work], write: :work)

    assert {:error, {:invalid_snapshot_identifier, :snapshot, :binary}} =
             Canonical.snapshot(state, read: [], id: "")

    assert {:error, {:invalid_snapshot_identifier, :correlation, :integer}} =
             Canonical.snapshot(state, read: [], correlation_id: 7)

    assert {:error, {:invalid_snapshot_causation_id, :atom}} =
             Canonical.snapshot(state, read: [], causation_id: :turn)

    assert {:error, {:invalid_snapshot_options, :map}} = Snapshot.new(state, %{})

    for {value, shape} <- [
          {[], :list},
          {{:snapshot}, :tuple},
          {1.5, :other}
        ] do
      assert {:error, {:invalid_snapshot_identifier, :snapshot, ^shape}} =
               Canonical.snapshot(state, read: [], id: value)
    end
  end

  test "two stale-base changes on independent sections commit in completion order" do
    state = Canonical.new()

    assert {:ok, work_snapshot} =
             Canonical.snapshot(state,
               read: [:work],
               write: [:work],
               id: "snapshot-work",
               correlation_id: "turn-work"
             )

    assert {:ok, vigil_snapshot} =
             Canonical.snapshot(state,
               read: [:vigil],
               write: [:vigil],
               id: "snapshot-vigil",
               correlation_id: "turn-vigil"
             )

    assert {:ok, work_change} =
             Canonical.change(work_snapshot, %{work: %{phase: :active}},
               id: "change-work",
               provenance: %{source: :flow},
               metadata: %{attempt: 1}
             )

    assert {:ok, vigil_change} =
             Canonical.change(vigil_snapshot, %{vigil: %{city: "Rome"}}, id: "change-vigil")

    assert {:ok, revision_one, first} = Canonical.commit(state, work_change)
    assert first.status == :committed
    assert first.from_revision == 0
    assert first.to_revision == 1
    assert first.changed_sections == [:work]
    assert first.provenance == %{source: :flow}
    assert first.metadata == %{attempt: 1}

    assert {:ok, revision_two, second} = Canonical.commit(revision_one, vigil_change)
    assert second.from_revision == 1
    assert second.to_revision == 2
    assert second.base_revision == 0
    assert second.changed_sections == [:vigil]

    assert revision_two.revision == 2
    assert {:ok, 1} = Canonical.section_revision(revision_two, :work)
    assert {:ok, 2} = Canonical.section_revision(revision_two, :vigil)
    assert {:ok, %{phase: :active}} = Canonical.fetch(revision_two, :work)
    assert {:ok, %{city: "Rome"}} = Canonical.fetch(revision_two, :vigil)
    assert Enum.map(revision_two.journal, & &1.change_id) == ["change-vigil", "change-work"]
  end

  test "a stale incompatible change is rejected without mutating canonical state" do
    state = Canonical.new()
    first = writable_snapshot(state, :work, "first")
    second = writable_snapshot(state, :work, "second")
    first_change = change(first, :work, %{phase: :active}, "first-change")
    second_change = change(second, :work, %{phase: :done}, "second-change")

    assert {:ok, committed, _transition} = Canonical.commit(state, first_change)

    assert {:error, {:stale_canonical_section, :work, 0, 1, 1}} =
             Canonical.commit(committed, second_change)

    assert committed.revision == 1
    assert {:ok, %{phase: :active}} = Canonical.fetch(committed, :work)
    assert Enum.map(committed.journal, & &1.change_id) == ["first-change"]
  end

  test "a multi-section merge is atomic when one target became stale" do
    state = Canonical.new()

    assert {:ok, combined_snapshot} =
             Canonical.snapshot(state,
               read: [:work, :vigil],
               write: [:work, :vigil],
               id: "combined",
               correlation_id: "combined"
             )

    assert {:ok, combined_change} =
             Canonical.change(
               combined_snapshot,
               %{work: %{phase: :done}, vigil: %{city: "Milan"}},
               id: "combined-change"
             )

    work_snapshot = writable_snapshot(state, :work, "winner")
    winner = change(work_snapshot, :work, %{phase: :active}, "winner-change")
    assert {:ok, committed, _transition} = Canonical.commit(state, winner)

    assert {:error, {:stale_canonical_section, :work, 0, 1, 1}} =
             Canonical.commit(committed, combined_change)

    assert {:ok, %{}} = Canonical.fetch(committed, :vigil)
    assert {:ok, 0} = Canonical.section_revision(committed, :vigil)
  end

  test "change creation enforces explicit scope, portability, and metadata" do
    state = Canonical.new()
    snapshot = writable_snapshot(state, :work, "authorized")

    assert {:error, :empty_canonical_change} = Canonical.change(snapshot, %{})

    assert {:error, {:snapshot_section_not_writable, :vigil}} =
             Canonical.change(snapshot, %{vigil: %{}})

    assert {:error, {:unknown_canonical_section, :mission}} =
             Canonical.change(snapshot, %{mission: %{}})

    assert {:error, {:invalid_canonical_writes, :list}} =
             Canonical.change(snapshot, [:work])

    assert {:error, {:invalid_canonical_writes, :integer}} =
             Canonical.change(snapshot, 3)

    assert {:error, {:nonportable_canonical_change, {:nonportable_run_value, _, :pid}}} =
             Canonical.change(snapshot, %{work: %{worker: self()}})

    assert {:error, {:invalid_canonical_change_id, :binary}} =
             Canonical.change(snapshot, %{work: %{}}, id: "")

    assert {:error, {:invalid_canonical_change_field, :provenance, :atom}} =
             Canonical.change(snapshot, %{work: %{}}, provenance: :flow)

    assert {:error, {:invalid_canonical_change_field, :metadata, :list}} =
             Canonical.change(snapshot, %{work: %{}}, metadata: [])

    assert {:error, {:nonportable_canonical_change, {:nonportable_run_value, _, :pid}}} =
             Canonical.change(snapshot, %{work: %{}}, metadata: %{pid: self()})

    assert {:error, {:invalid_change_options, :map}} =
             Change.new(snapshot, %{work: %{}}, %{})

    assert {:ok, %Change{writes: %{work: %{phase: :keyword}}}} =
             Change.new(snapshot, work: %{phase: :keyword})

    for {opts, shape} <- [
          {{:invalid}, :tuple},
          {1.5, :other}
        ] do
      assert {:error, {:invalid_change_options, ^shape}} =
               Change.new(snapshot, %{work: %{}}, opts)
    end
  end

  test "change identifiers are idempotent and reject conflicting reuse" do
    state = Canonical.new()
    snapshot = writable_snapshot(state, :work, "idempotent")
    original = change(snapshot, :work, %{phase: :active}, "same-change")

    assert {:ok, committed, committed_transition} = Canonical.commit(state, original)
    assert committed_transition.status == :committed

    assert {:ok, replayed, duplicate_transition} = Canonical.commit(committed, original)
    assert replayed == committed
    assert duplicate_transition.status == :duplicate
    assert duplicate_transition.from_revision == 1
    assert duplicate_transition.to_revision == 1
    assert length(replayed.journal) == 1

    conflicting = %{original | writes: %{work: %{phase: :different}}}

    assert {:error, {:canonical_change_id_conflict, "same-change"}} =
             Canonical.commit(committed, conflicting)
  end

  test "future revisions and malformed forged changes fail closed" do
    state = Canonical.new()
    snapshot = writable_snapshot(state, :work, "forged")
    valid = change(snapshot, :work, %{phase: :active}, "forged-change")

    assert {:error, {:future_canonical_revision, 2, 0}} =
             Canonical.commit(state, %{valid | base_revision: 2})

    malformed = [
      {%{valid | schema_version: 2}, {:unsupported_canonical_change_version, 2}},
      {%{valid | id: ""}, :invalid_canonical_change_id},
      {%{valid | snapshot_id: ""}, :invalid_canonical_snapshot_id},
      {%{valid | correlation_id: ""}, :invalid_canonical_correlation_id},
      {%{valid | causation_id: :bad}, :invalid_canonical_causation_id},
      {%{valid | base_revision: -1}, {:invalid_canonical_base_revision, -1}},
      {%{valid | writes: %{}}, :empty_canonical_change},
      {%{valid | section_revisions: %{}}, :canonical_change_revision_scope_mismatch},
      {%{valid | section_revisions: %{work: -1}}, {:invalid_change_section_revision, :work, -1}},
      {%{valid | provenance: :bad}, {:invalid_canonical_field, :provenance, :atom}},
      {%{valid | metadata: []}, {:invalid_canonical_field, :metadata, :list}}
    ]

    for {change, reason} <- malformed do
      assert {:error, ^reason} = Canonical.commit(state, change)
    end
  end

  test "checkpoint round-trip preserves revisions, correlations, journal, and idempotency" do
    assert {:ok, state} = Canonical.new(flow: %{turn: 3}, work: %{phase: :queued})
    snapshot = writable_snapshot(state, :work, "checkpoint")

    assert {:ok, change} =
             Canonical.change(snapshot, %{work: %{phase: :active, cursor: {2, :next}}},
               id: "checkpoint-change",
               provenance: %{turn_id: "turn-3"},
               metadata: %{kind: :advance}
             )

    assert {:ok, committed, transition} = Canonical.commit(state, change)
    assert transition.correlation_id == "correlation-checkpoint"
    assert transition.causation_id == "cause-checkpoint"

    assert {:ok, encoded} = Codec.encode(committed)
    assert encoded["format"] == "spectre/instance-checkpoint"
    assert encoded["checkpoint_version"] == 3
    assert encoded["state_schema_version"] == 3
    assert encoded["revision"] == 1

    assert {:ok, json} = Codec.encode_json(committed)
    assert restored = Codec.decode!(json)
    assert restored == committed

    assert {:ok, replayed, duplicate} = Canonical.commit(restored, change)
    assert replayed == restored
    assert duplicate.status == :duplicate
  end

  test "a restored checkpoint still accepts an older independent snapshot" do
    state = Canonical.new()
    work_snapshot = writable_snapshot(state, :work, "restart-work")
    vigil_snapshot = writable_snapshot(state, :vigil, "restart-vigil")
    work_change = change(work_snapshot, :work, %{phase: :done}, "restart-work-change")
    vigil_change = change(vigil_snapshot, :vigil, %{city: "Turin"}, "restart-vigil-change")

    assert {:ok, committed, _transition} = Canonical.commit(state, work_change)
    assert {:ok, checkpoint} = Codec.encode_json(committed)
    assert {:ok, restored} = Codec.decode(checkpoint)
    assert {:ok, merged, transition} = Canonical.commit(restored, vigil_change)

    assert merged.revision == 2
    assert transition.base_revision == 0
    assert {:ok, %{phase: :done}} = Canonical.fetch(merged, :work)
    assert {:ok, %{city: "Turin"}} = Canonical.fetch(merged, :vigil)
  end

  test "checkpoint encoding and recovery reject corrupted or nonportable state" do
    state = Canonical.new()
    {:ok, encoded} = Codec.encode(state)

    assert {:error, {:invalid_canonical_state, :atom}} = Codec.encode(:state)
    assert {:error, {:invalid_canonical_checkpoint, :integer}} = Codec.decode(7)

    for {value, shape} <- [
          {[], :list},
          {%URI{}, :map},
          {{:checkpoint}, :tuple},
          {1.5, :other}
        ] do
      assert {:error, {:invalid_canonical_checkpoint, ^shape}} = Codec.decode(value)
    end

    assert_raise ArgumentError, ~r/invalid canonical Agent checkpoint/, fn ->
      Codec.decode!(%{})
    end

    assert {:error, {:unsupported_canonical_checkpoint, 99}} =
             encoded |> Map.put("checkpoint_version", 99) |> Codec.decode()

    assert {:error, {:missing_canonical_checkpoint_field, "checkpoint_version"}} =
             encoded |> Map.delete("checkpoint_version") |> Codec.decode()

    assert {:error, {:unsupported_canonical_checkpoint_format, "other"}} =
             encoded |> Map.put("format", "other") |> Codec.decode()

    assert {:error, {:invalid_canonical_checkpoint_format, :other}} =
             encoded |> Map.put("format", :other) |> Codec.decode()

    assert {:error, {:unsupported_canonical_version, 99}} =
             encoded |> Map.put("state_schema_version", 99) |> Codec.decode()

    assert {:error, {:invalid_canonical_checkpoint_integer, "revision", -1}} =
             encoded |> Map.put("revision", -1) |> Codec.decode()

    assert {:error, {:invalid_canonical_checkpoint_fields, :checkpoint, _, _}} =
             encoded |> Map.put("unknown", true) |> Codec.decode()

    assert {:error, {:invalid_canonical_checkpoint_key, :checkpoint, :atom}} =
             encoded |> Map.put(:revision, 0) |> Codec.decode()

    oversized = String.duplicate("x", 8_000_001)

    assert {:error, {:canonical_checkpoint_too_large, 8_000_001, 8_000_000}} =
             Codec.decode(oversized)

    {:ok, section} = Sections.fetch(state.sections, :work)
    sections = Sections.put(state.sections, :work, %{section | value: %{pid: self()}})

    assert {:error, {:nonportable_canonical_value, {:nonportable_run_value, _, :pid}}} =
             Codec.encode(%{state | sections: sections})
  end

  test "checkpoint recovery validates every nested canonical boundary" do
    state = Canonical.new()
    snapshot = writable_snapshot(state, :work, "nested-codec")
    change = change(snapshot, :work, %{phase: :active}, "nested-codec-change")
    assert {:ok, committed, _transition} = Canonical.commit(state, change)
    assert {:ok, encoded} = Codec.encode(committed)

    assert {:error, {:invalid_canonical_sections, :atom}} =
             encoded |> Map.put("sections", :bad) |> Codec.decode()

    assert {:error, {:invalid_canonical_section, :work, :atom}} =
             encoded
             |> put_in(["sections", "work"], :bad)
             |> Codec.decode()

    assert {:error, {:invalid_canonical_checkpoint_fields, {:section, :work}, _, _}} =
             encoded
             |> update_in(["sections", "work"], &Map.delete(&1, "revision"))
             |> Codec.decode()

    assert {:error, {:canonical_value_decode_failed, [:canonical, :work], _}} =
             encoded
             |> put_in(["sections", "work", "value"], %{"$spectre" => "unknown"})
             |> Codec.decode()

    assert {:error, {:invalid_canonical_journal, :atom}} =
             encoded |> Map.put("journal", :bad) |> Codec.decode()

    assert {:error, {:invalid_canonical_transition, :integer}} =
             encoded |> Map.put("journal", [1]) |> Codec.decode()

    [transition] = encoded["journal"]

    transition_cases = [
      {Map.put(transition, "schema_version", 3), {:unsupported_canonical_transition_version, 3}},
      {Map.put(transition, "status", "duplicate"),
       {:invalid_canonical_transition_status, "duplicate"}},
      {Map.put(transition, "id", ""), {:invalid_canonical_checkpoint_binary, "id", :binary}},
      {Map.put(transition, "causation_id", 3),
       {:invalid_canonical_checkpoint_optional_binary, :integer}},
      {Map.put(transition, "changed_sections", ["work", "work"]),
       {:duplicate_canonical_transition_section, :work}},
      {Map.put(transition, "changed_sections", ["mission"]),
       {:unknown_canonical_transition_section, "mission"}},
      {Map.put(transition, "changed_sections", :bad),
       {:invalid_canonical_transition_sections, :atom}}
    ]

    for {bad_transition, reason} <- transition_cases do
      assert {:error, ^reason} = encoded |> Map.put("journal", [bad_transition]) |> Codec.decode()
    end

    assert {:error, {:invalid_applied_canonical_changes, :atom}} =
             encoded |> Map.put("applied_changes", :bad) |> Codec.decode()

    applied_cases = [
      {%{"nested-codec-change" => :bad},
       {:invalid_applied_canonical_change, "nested-codec-change", :atom}},
      {%{7 => %{"revision" => 1, "digest" => "digest"}},
       {:invalid_applied_canonical_change_id, :integer}}
    ]

    for {bad_changes, reason} <- applied_cases do
      assert {:error, ^reason} =
               encoded |> Map.put("applied_changes", bad_changes) |> Codec.decode()
    end

    assert {:error,
            {:invalid_canonical_checkpoint_fields, {:applied_change, "nested-codec-change"}, _, _}} =
             encoded
             |> Map.put("applied_changes", %{"nested-codec-change" => %{"revision" => 1}})
             |> Codec.decode()
  end

  test "canonical validation rejects corrupted revisions, journal, and deduplication state" do
    state = Canonical.new()

    invalid = [
      {%{state | schema_version: 5}, {:unsupported_canonical_version, 5}},
      {%{state | revision: -1}, {:invalid_revision, :canonical_revision, -1}},
      {%{state | sections: :bad}, {:invalid_canonical_sections, :atom}},
      {%{state | journal: :bad}, {:invalid_canonical_journal, :atom}},
      {%{state | journal: [:bad]}, {:invalid_canonical_transition, :atom}},
      {%{state | journal: List.duplicate(%Transition{}, 513)},
       {:canonical_journal_too_large, 513, 512}},
      {%{state | applied_changes: :bad}, {:invalid_applied_canonical_changes, :atom}},
      {%{state | applied_changes: %{"bad" => %{revision: 0, digest: "digest"}}},
       {:invalid_applied_canonical_change, "bad", :map}}
    ]

    for {invalid_state, reason} <- invalid do
      assert {:error, ^reason} = Canonical.validate(invalid_state)
    end

    {:ok, work} = Sections.fetch(state.sections, :work)
    future_sections = Sections.put(state.sections, :work, %{work | revision: 1})

    assert {:error, {:invalid_canonical_section_revision, :work, 1, 0}} =
             Canonical.validate(%{state | sections: future_sections})

    broken_sections = %{state.sections | work: :bad}

    assert {:error, {:invalid_canonical_section, :work}} =
             Canonical.validate(%{state | sections: broken_sections})
  end

  test "state digesting and previews fail closed for forged canonical values" do
    state = Canonical.new()

    assert {:error, :unknown_canonical_preview_section} =
             Canonical.preview_state_digest(state, %{mission: %{phase: :unknown}})

    {:ok, work} = Sections.fetch(state.sections, :work)
    sections = Sections.put(state.sections, :work, %{work | value: %{owner: self()}})
    forged = %{state | sections: sections}

    assert {:error,
            {:canonical_section_digest_failed, :work,
             {:nonportable_run_value, [:value, :owner], :pid}}} = Canonical.state_digest(forged)

    assert_raise ArgumentError, ~r/cannot digest canonical state/, fn ->
      Canonical.state_digest!(forged)
    end

    snapshot = writable_snapshot(state, :work, "forged-section")
    valid_change = change(snapshot, :work, %{phase: :active}, "forged-section-change")

    forged_change = %{
      valid_change
      | writes: %{mission: %{}},
        section_revisions: %{mission: 0}
    }

    assert {:error, {:unknown_canonical_section, :mission}} =
             Canonical.commit(state, forged_change)
  end

  test "transition validation rejects persisted duplicate and malformed transition state" do
    state = Canonical.new()
    snapshot = writable_snapshot(state, :work, "transition")
    change = change(snapshot, :work, %{phase: :active}, "transition-change")
    assert {:ok, committed, transition} = Canonical.commit(state, change)

    malformed = [
      {%{transition | schema_version: 3}, {:unsupported_canonical_transition_version, 3}},
      {%{transition | status: :duplicate}, {:invalid_persisted_transition_status, :duplicate}},
      {%{transition | from_revision: -1}, {:invalid_transition_revision, :from, -1}},
      {%{transition | to_revision: 3}, {:invalid_transition_revision, :to, 3}},
      {%{transition | base_revision: 2}, {:invalid_transition_revision, :base, 2}},
      {%{transition | changed_sections: [:mission]}, :invalid_transition_sections},
      {%{transition | pre_state_digest: :invalid}, :invalid_canonical_transition_state_digest},
      {%{transition | schema_version: 1}, :invalid_canonical_transition_state_digest},
      {%{transition | provenance: :bad}, {:invalid_canonical_field, :provenance, :atom}},
      {%{transition | metadata: []}, {:invalid_canonical_field, :metadata, :list}}
    ]

    for {bad_transition, reason} <- malformed do
      assert {:error, ^reason} = Canonical.validate(%{committed | journal: [bad_transition]})
    end

    future = %{transition | from_revision: 1, to_revision: 2}

    assert {:error, {:future_transition_revision, 2, 1}} =
             Canonical.validate(%{committed | journal: [future]})
  end

  test "journal validation rejects duplicate transition identities" do
    state = Canonical.new()
    first_snapshot = writable_snapshot(state, :work, "journal-first")
    first_change = change(first_snapshot, :work, %{phase: :active}, "journal-first-change")
    assert {:ok, first_state, first_transition} = Canonical.commit(state, first_change)

    second_snapshot = writable_snapshot(first_state, :vigil, "journal-second")
    second_change = change(second_snapshot, :vigil, %{phase: :watching}, "journal-second-change")
    assert {:ok, second_state, second_transition} = Canonical.commit(first_state, second_change)

    duplicate_id = %{first_transition | id: second_transition.id}

    assert {:error, :duplicate_canonical_transition_id} =
             Canonical.validate(%{second_state | journal: [second_transition, duplicate_id]})
  end

  defp writable_snapshot(state, section, suffix) do
    assert {:ok, snapshot} =
             Canonical.snapshot(state,
               read: [section],
               write: [section],
               id: "snapshot-#{suffix}",
               correlation_id: "correlation-#{suffix}",
               causation_id: "cause-#{suffix}"
             )

    snapshot
  end

  defp change(snapshot, section, value, id) do
    assert {:ok, change} = Canonical.change(snapshot, %{section => value}, id: id)
    change
  end
end
