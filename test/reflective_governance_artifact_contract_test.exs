defmodule SpectreReflectiveGovernanceArtifactContractTest.BoundaryStore do
  @moduledoc false
  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts) do
    case Keyword.get(opts, :identity, "boundary-store") do
      :raise -> raise "identity failed"
      :throw -> throw(:identity_failed)
      value -> value
    end
  end

  @impl true
  def durability(opts) do
    case Keyword.get(opts, :durability, :volatile) do
      :raise -> raise "durability failed"
      :throw -> throw(:durability_failed)
      value -> value
    end
  end

  @impl true
  def get(key, opts) do
    case Keyword.get(opts, :get, :stored) do
      :stored -> Process.get({__MODULE__, key}, :not_found)
      :raise -> raise "get failed"
      :throw -> throw(:get_failed)
      value -> value
    end
  end

  @impl true
  def put(key, encoded, opts) do
    case Keyword.get(opts, :put, :store) do
      :store ->
        Process.put({__MODULE__, key}, {:ok, encoded})
        :ok

      :created ->
        Process.put({__MODULE__, key}, {:ok, encoded})
        {:ok, :created}

      :existing ->
        Process.put({__MODULE__, key}, {:ok, encoded})
        {:ok, :existing}

      :invisible ->
        :ok

      :conflict ->
        Process.put({__MODULE__, key}, {:ok, encoded <> "changed"})
        :ok

      :raise ->
        raise "put failed"

      :throw ->
        throw(:put_failed)

      value ->
        value
    end
  end
end

defmodule SpectreReflectiveGovernanceArtifactContractTest.MissingCallbacks do
  @moduledoc false
end

defmodule SpectreReflectiveGovernanceArtifactContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Governance.GC.Plan
  alias Spectre.Projection.HumanReport

  alias SpectreReflectiveGovernanceArtifactContractTest.BoundaryStore
  alias SpectreReflectiveGovernanceArtifactContractTest.MissingCallbacks

  @digest String.duplicate("a", 64)
  @other_digest String.duplicate("b", 64)

  test "Manifest is a sealed binding, and every malformed transport boundary fails closed" do
    canonical = canonical("parent", "before")
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())

    assert Manifest.schema_version() == 1
    assert Manifest.contract_version() == 2
    assert :ok = Manifest.verify(manifest, canonical)
    assert {:ok, ^manifest} = Manifest.new(Map.to_list(Map.from_struct(manifest)))
    assert {:ok, encoded} = Manifest.encode(manifest)
    assert {:ok, ^manifest} = Manifest.decode(encoded)

    changed = canonical("parent", "after")

    assert {:error, {:definition_ref_mismatch, _expected, _actual}} =
             Manifest.verify(manifest, changed)

    assert {:error, {:invalid_definition_manifest, :other}} = Manifest.new(:invalid)
    assert {:error, {:invalid_definition_manifest_data, :list}} = Manifest.from_data([])
    assert {:error, {:invalid_definition_manifest_binary, :tuple}} = Manifest.decode({})

    attrs = Map.from_struct(manifest)

    invalid_attrs = [
      {Map.put(attrs, :unknown, true), {:unknown_definition_manifest_fields, [:unknown]}},
      {Map.put(attrs, :schema_version, 9), {:unsupported_definition_manifest_schema, 9}},
      {Map.put(attrs, :contract_version, 9), {:unsupported_definition_manifest_contract, 9}},
      {Map.put(attrs, :definition_ref, nil), {:invalid_manifest_definition_ref, nil}},
      {Map.put(attrs, :authority, %{}), {:invalid_manifest_authority, :map}},
      {Map.put(attrs, :execution_closure, []), {:invalid_manifest_execution_closure, :list}},
      {Map.put(attrs, :component_contracts, []), :incomplete_component_contract_snapshot},
      {Map.put(attrs, :component_contracts, [%{}]), :invalid_component_contract_snapshot},
      {Map.put(attrs, :parent_refs, :invalid), {:invalid_definition_parent_refs, :other}},
      {Map.put(attrs, :publisher_ref, ""), {:invalid_manifest_ref, :publisher_ref, ""}},
      {Map.put(attrs, :provenance_refs, [""]), :invalid_manifest_refs},
      {Map.put(attrs, :receipt_refs, :invalid), {:invalid_manifest_refs, :receipt_refs, :other}}
    ]

    Enum.each(invalid_attrs, fn {mutation, reason} ->
      assert {:error, ^reason} = Manifest.new(mutation)
    end)

    data = Manifest.to_data(manifest)

    assert {:error, {:invalid_component_contract_snapshot, :map}} =
             data |> Map.put("component_contracts", %{}) |> Manifest.from_data()

    assert {:error, :invalid_component_contract_snapshot} =
             data |> Map.put("component_contracts", [%{}]) |> Manifest.from_data()

    assert {:error, {:invalid_component_criticality, "kernel"}} =
             data
             |> put_in(["component_contracts", Access.at(0), "criticality"], "kernel")
             |> Manifest.from_data()

    assert {:error, {:invalid_component_contract_status, "trusted"}} =
             data
             |> put_in(["component_contracts", Access.at(0), "status"], "trusted")
             |> Manifest.from_data()

    assert {:error, {:invalid_definition_parent_refs, :map}} =
             data |> Map.put("parent_refs", %{}) |> Manifest.from_data()
  end

  test "HumanReport proves the exact diff and rejects independently mutated evidence" do
    parent = canonical("report", "before")
    candidate = canonical("report", "after")
    delta = evaluation_delta()
    lineage = ["candidate:sha256:" <> @digest]
    receipts = ["gate:sha256:" <> @other_digest]

    assert {:ok, report} =
             HumanReport.project(parent, candidate,
               evaluation_delta: delta,
               lineage_refs: lineage,
               gate_receipt_refs: receipts
             )

    assert :ok = HumanReport.verify(report)

    assert [%{"change" => "changed", "before" => "before", "after" => "after"}] =
             Enum.filter(
               report.textual_changes,
               &(&1["path"] == ["components", 0, "payload", "text"])
             )

    assert {:ok, ^report} = report |> HumanReport.encode() |> elem(1) |> HumanReport.decode()
    data = HumanReport.to_data(report)

    mutations = [
      {Map.put(data, "generator_id", "forged"), {:unsupported_human_report_generator, "forged"}},
      {Map.put(data, "generator_version", 2), {:unsupported_human_report_version, 2}},
      {Map.put(data, "parent_definition_ref", "bad"), :invalid_human_report_reference},
      {Map.put(data, "input_evidence_digest", "bad"), {:invalid_human_report_digest, "bad"}},
      {Map.put(data, "lineage_refs", :invalid), {:invalid_human_report_refs, :other}},
      {Map.put(data, "structural_changes", %{}), {:invalid_human_report_changes, :map}},
      {Map.put(data, "textual_changes", []), :human_report_textual_diff_mismatch},
      {Map.put(data, "unknown", true), {:invalid_human_report_fields, ["unknown"]}}
    ]

    Enum.each(mutations, fn {mutation, reason} ->
      assert {:error, ^reason} = HumanReport.from_data(mutation)
    end)

    duplicate_path = [hd(report.structural_changes), hd(report.structural_changes)]

    assert {:error, {:invalid_human_report_change_shape, :structural}} =
             data
             |> Map.put("structural_changes", duplicate_path)
             |> HumanReport.from_data()

    forged_evidence = Map.put(data, "gate_receipt_refs", ["gate:sha256:" <> @digest])

    assert {:error, {:human_report_evidence_digest_mismatch, _supplied, _actual}} =
             HumanReport.from_data(forged_evidence)

    assert {:error, {:human_report_digest_mismatch, _, _}} =
             HumanReport.verify(%{report | digest: @digest})

    assert {:error, {:invalid_human_report_input, :other}} =
             HumanReport.project(parent, candidate, evaluation_delta: :forged)
  end

  test "GC plan evidence cannot turn a retained durable object into an eligible deletion" do
    attrs = gc_attrs()
    assert {:ok, plan} = Plan.build(attrs)
    assert :ok = Plan.verify(plan)
    assert {:ok, ^plan} = plan |> Plan.encode() |> elem(1) |> Plan.decode()

    candidate_ref = hd(attrs.candidate_inventory)
    definition_ref = hd(attrs.definition_inventory)

    unsafe_candidate =
      update_in(attrs.candidate_decisions, fn [decision] ->
        [%{decision | "decision" => "eligible", "reasons" => []}]
      end)

    assert {:error, {:unsafe_governance_gc_decision, ^candidate_ref}} =
             Plan.build(unsafe_candidate)

    unsafe_definition =
      update_in(attrs.definition_decisions, fn [decision] ->
        [%{decision | "reasons" => ["inventory_not_complete"]}]
      end)

    assert {:error, {:unsafe_governance_gc_decision, ^definition_ref}} =
             Plan.build(unsafe_definition)

    invalid = [
      {Map.delete(attrs, :store_identity), :incomplete_governance_gc_plan},
      {Map.put(attrs, :store_identity, self()),
       {:nonportable_governance_data, ["store_identity"], :pid}},
      {Map.put(attrs, :inventory_complete, 1), :invalid_governance_gc_plan_shape},
      {Map.put(attrs, :inventory_snapshot_digest, @digest),
       :invalid_governance_gc_inventory_snapshot_digest},
      {Map.put(attrs, :evidence_digest, "bad"), :invalid_governance_gc_evidence_digest},
      {Map.put(attrs, :candidate_inventory, "invalid"),
       {:invalid_governance_gc_ref_list, "candidate:sha256:"}},
      {Map.put(attrs, :protected_candidate_refs, ["candidate:sha256:" <> @other_digest]),
       {:governance_gc_refs_outside_inventory, :protected_candidates,
        ["candidate:sha256:" <> @other_digest]}},
      {Map.put(attrs, :candidate_decisions, "invalid"),
       :invalid_governance_gc_candidate_decisions},
      {Map.put(attrs, :definition_decisions, "invalid"),
       :invalid_governance_gc_definition_decisions}
    ]

    Enum.each(invalid, fn {mutation, reason} ->
      assert {:error, ^reason} = Plan.build(mutation)
    end)

    data = Plan.to_data(plan)

    assert {:error, {:unsupported_governance_gc_plan_schema, 9}} =
             data |> Map.put("schema_version", 9) |> Plan.from_data()

    assert {:error, {:invalid_governance_gc_plan_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> Plan.from_data()

    assert {:error, :governance_gc_plan_integrity_mismatch} =
             data |> Map.put("digest", @other_digest) |> Plan.from_data()

    assert {:error, {:governance_gc_plan_digest_mismatch, _, _}} =
             Plan.verify(%{plan | digest: @other_digest})

    assert {:error, {:invalid_governance_gc_plan_data, :list}} = Plan.from_data([])
    assert {:error, {:invalid_governance_gc_plan_binary, :tuple}} = Plan.decode({})
  end

  test "Definition Store contains bad adapters, stale writes and malformed artifacts" do
    assert Store.artifact_schema_version() == 1
    assert Store.receipt_schema_version() == 1
    assert Store.candidate_artifact_schema_version() == 1
    assert Store.gate_receipt_artifact_schema_version() == 1

    assert {:error, {:invalid_definition_store, {BoundaryStore, :non_keyword_options}}} =
             Store.normalize({BoundaryStore, [:bad]})

    assert {:error, {:invalid_definition_store, 42}} = Store.normalize(42)

    assert {:error, {:definition_store_callback_missing, MissingCallbacks, :identity, 1}} =
             Store.identity(MissingCallbacks)

    assert {:error, {:definition_store_not_loaded, Spectre.NotARealStore}} =
             Store.durability(Spectre.NotARealStore)

    assert {:error, :invalid_definition_store_durability} =
             Store.durability({BoundaryStore, durability: :replicated})

    assert {:error, {:definition_store_exception, BoundaryStore, :durability, RuntimeError}} =
             Store.durability({BoundaryStore, durability: :raise})

    assert {:error,
            {:definition_store_failure, BoundaryStore, :durability, :throw, :durability_failed}} =
             Store.durability({BoundaryStore, durability: :throw})

    assert {:error, {:invalid_definition_store_identity, _reason}} =
             Store.identity({BoundaryStore, identity: self()})

    canonical = canonical("store", "value")
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    ref = Canonical.ref(canonical)
    key = Ref.to_string(ref)

    for put_mode <- [:store, :created, :existing] do
      assert {:ok, receipt} = Store.publish({BoundaryStore, put: put_mode}, canonical, manifest)
      assert receipt.definition_ref == key

      assert {:ok, %{definition: ^canonical, manifest: ^manifest}} =
               Store.fetch({BoundaryStore, put: put_mode}, ref)

      Process.delete({BoundaryStore, key})
    end

    assert {:error, {:definition_store_write_not_visible, ^key}} =
             Store.publish({BoundaryStore, put: :invisible}, canonical, manifest)

    assert {:error, {:definition_store_immutable_conflict, ^key}} =
             Store.publish({BoundaryStore, put: :conflict}, canonical, manifest)

    assert {:error, {:invalid_definition_store_put_reply, BoundaryStore, :bad}} =
             Store.publish({BoundaryStore, put: :bad}, canonical, manifest)

    assert {:error, {:definition_store_exception, BoundaryStore, :put, RuntimeError}} =
             Store.publish({BoundaryStore, put: :raise}, canonical, manifest)

    assert {:error, {:definition_store_failure, BoundaryStore, :put, :throw, :put_failed}} =
             Store.publish({BoundaryStore, put: :throw}, canonical, manifest)

    assert :not_found = Store.fetch({BoundaryStore, get: :not_found}, ref)

    assert {:error, {:invalid_definition_store_get_reply, BoundaryStore, :bad}} =
             Store.fetch({BoundaryStore, get: :bad}, ref)

    assert {:error, {:definition_store_exception, BoundaryStore, :get, RuntimeError}} =
             Store.fetch({BoundaryStore, get: :raise}, ref)

    assert {:error, {:definition_store_failure, BoundaryStore, :get, :throw, :get_failed}} =
             Store.fetch({BoundaryStore, get: :throw}, ref)

    invalid_artifact = Value.encode!(%{"schema_version" => 9})

    assert {:error,
            {:definition_store_artifact_invalid, {:invalid_definition_store_artifact, :map}}} =
             Store.fetch({BoundaryStore, get: {:ok, invalid_artifact}}, ref)

    assert {:error, {:invalid_definition_store_ref, :invalid}} =
             Store.fetch(BoundaryStore, :invalid)

    assert {:error, {:invalid_candidate_store_ref, :invalid}} =
             Store.fetch_candidate(BoundaryStore, :invalid)

    assert {:error, {:invalid_gate_receipt_store_ref, :invalid}} =
             Store.fetch_gate_receipt(BoundaryStore, :invalid)
  end

  defp canonical(id, text) do
    Canonical.new!(
      kind: :agent,
      id: id,
      declared_version: 1,
      origin: :runtime,
      components: [
        Component.new!(
          component_type: :metadata,
          schema_ref: "spectre.definition.metadata/1",
          criticality: :descriptive,
          payload: %{"text" => text}
        )
      ]
    )
  end

  defp closure do
    Closure.new!(%{
      stack_ref: "spectre.stack:test",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/4",
      state_codec_ref: "spectre.instance.canonical.codec/4",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{"beam:test" => @digest},
      evaluation_corpus_digest: nil,
      compatibility_mode: :native_v2
    })
  end

  defp evaluation_delta do
    protected = [%{"id" => "protected", "input" => "lookup"}]

    EvaluationDelta.new!(
      [%{case_id: "protected", passed: true, score: 1.0}],
      [%{case_id: "protected", passed: true, score: 1.0}],
      protected_cases: protected
    )
  end

  defp gc_attrs do
    candidate_ref = "candidate:sha256:" <> @digest
    definition_ref = "sha256:" <> @other_digest

    %{
      store_identity: "store:test",
      inventory_complete: false,
      candidate_inventory: [candidate_ref],
      definition_inventory: [definition_ref],
      candidate_decisions: [
        %{
          "ref" => candidate_ref,
          "definition_ref" => definition_ref,
          "decision" => "retained",
          "reasons" => ["inventory_not_complete"]
        }
      ],
      definition_decisions: [
        %{
          "ref" => definition_ref,
          "decision" => "retained",
          "reasons" => ["inventory_not_complete", "retained_candidate_reference"]
        }
      ],
      protected_candidate_refs: [],
      protected_definition_refs: [],
      candidate_lineage_refs: [],
      definition_lineage_refs: [],
      requested_candidate_refs: [candidate_ref],
      requested_definition_refs: [definition_ref],
      inventory_snapshot_digest: nil,
      evidence_digest: @digest
    }
  end
end
