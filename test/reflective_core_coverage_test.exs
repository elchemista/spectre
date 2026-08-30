defmodule SpectreReflectiveCoreCoverageTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :reflective_core_coverage_agent
end

defmodule SpectreReflectiveCoreCoverageTest.OwnerAdapter do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  @impl true
  def claim(ref, opts) do
    case Keyword.get(opts, :claim, :ok) do
      :ok ->
        Lease.new(
          owner_id: "owner:" <> ref.key,
          fencing_token: Keyword.get(opts, :token, 7),
          issued_at: 10,
          expires_at: 100,
          metadata: %{instance_key: ref.key}
        )

      :error ->
        {:error, :lease_denied}

      :invalid ->
        :not_a_claim_reply

      :malformed_lease ->
        {:ok,
         %Lease{
           schema_version: 1,
           owner_id: "owner",
           fencing_token: 0,
           issued_at: 10,
           expires_at: 100,
           metadata: %{}
         }}

      :raise ->
        raise "claim failed"

      :throw ->
        throw(:claim_failed)
    end
  end

  @impl true
  def validate(_ref, _lease, opts) do
    case Keyword.get(opts, :validate, :ok) do
      :ok -> :ok
      :error -> {:error, :lease_superseded}
      :invalid -> :not_a_validation_reply
      :raise -> raise "validation failed"
      :throw -> throw(:validation_failed)
    end
  end

  @impl true
  def release(_ref, _lease, opts) do
    case Keyword.get(opts, :release, :ok) do
      :ok -> :ok
      :error -> {:error, :release_failed}
      :invalid -> :not_a_release_reply
      :raise -> raise "release failed"
      :throw -> throw(:release_failed)
    end
  end
end

defmodule SpectreReflectiveCoreCoverageTest.OwnerWithoutRelease do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  @impl true
  def claim(ref, _opts) do
    Spectre.Instance.Owner.Lease.new(
      owner_id: "owner:" <> ref.key,
      fencing_token: 9,
      issued_at: 1,
      metadata: %{instance_key: ref.key}
    )
  end

  @impl true
  def validate(_ref, _lease, _opts), do: :ok
end

defmodule SpectreReflectiveCoreCoverageTest.OwnerMissingValidate do
  @moduledoc false

  def claim(_ref, _opts), do: {:error, :unused}
end

defmodule SpectreReflectiveCoreCoverageTest.ExperienceAdapter do
  @moduledoc false

  @behaviour Spectre.Experience.Store

  @impl true
  def identity(opts) do
    case Keyword.get(opts, :identity, :test_store) do
      :raise -> raise "identity failed"
      :throw -> throw(:identity_failed)
      value -> value
    end
  end

  @impl true
  def durability(opts), do: Keyword.get(opts, :durability, :volatile)

  @impl true
  def get(_key, opts) do
    case Keyword.get(opts, :get, :not_found) do
      :raise -> raise "get failed"
      :throw -> throw(:get_failed)
      value -> value
    end
  end

  @impl true
  def put(_key, _encoded, opts) do
    case Keyword.get(opts, :put, :ok) do
      :raise -> raise "put failed"
      :throw -> throw(:put_failed)
      value -> value
    end
  end

  @impl true
  def list(opts) do
    case Keyword.get(opts, :list, {:ok, []}) do
      :raise -> raise "list failed"
      :throw -> throw(:list_failed)
      value -> value
    end
  end

  @impl true
  def delete(_key, opts) do
    case Keyword.get(opts, :delete, :ok) do
      :raise -> raise "delete failed"
      :throw -> throw(:delete_failed)
      value -> value
    end
  end
end

defmodule SpectreReflectiveCoreCoverageTest.ContractValidator do
  @moduledoc false

  def accept(_component), do: :ok
  def reject(_component), do: {:error, :payload_rejected}
  def invalid_reply(_component), do: :accepted
  def raise_error(_component), do: raise("validator failed")
  def throw_error(_component), do: throw(:validator_failed)
end

defmodule SpectreReflectiveCoreCoverageTest.InvalidVersionProjection do
  @moduledoc false
  @behaviour Spectre.Projection

  @impl true
  def id, do: "spectre.projection.invalid-version"

  @impl true
  def version, do: 0

  @impl true
  def project(_canonical, _opts), do: {:ok, %{}}
end

defmodule SpectreReflectiveCoreCoverageTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Canonical.Data, as: CanonicalData
  alias Spectre.Definition.Component
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory, as: DefinitionMemory
  alias Spectre.Experience
  alias Spectre.Experience.Evidence
  alias Spectre.Experience.Evidence.Ref, as: EvidenceRef
  alias Spectre.Experience.Redactor
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Experience.Store.Memory, as: ExperienceMemory
  alias Spectre.Execution.Closure
  alias Spectre.Forge.Critique
  alias Spectre.Forge.OracleApproval
  alias Spectre.Forge.Proposal
  alias Spectre.Gate.Receipt.Ref, as: GateReceiptRef
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Operation, as: ChangeOperation
  alias Spectre.Governance.Data, as: GovernanceData
  alias Spectre.Instance.Owner
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Projection
  alias Spectre.Run

  alias SpectreReflectiveCoreCoverageTest.Agent
  alias SpectreReflectiveCoreCoverageTest.ContractValidator
  alias SpectreReflectiveCoreCoverageTest.ExperienceAdapter
  alias SpectreReflectiveCoreCoverageTest.OwnerAdapter
  alias SpectreReflectiveCoreCoverageTest.OwnerMissingValidate
  alias SpectreReflectiveCoreCoverageTest.OwnerWithoutRelease
  alias SpectreReflectiveCoreCoverageTest.InvalidVersionProjection

  @digest_a String.duplicate("a", 64)
  @digest_b String.duplicate("b", 64)

  test "owner boundary claims, fences, validates and releases a real lease" do
    ref = InstanceRef.new(Agent, "subject:owner")

    assert {:ok, {OwnerAdapter, []}, %Lease{fencing_token: 7} = lease} =
             Owner.claim(OwnerAdapter, ref)

    assert :ok = Owner.validate(OwnerAdapter, ref, lease)
    assert :ok = Owner.assert_current(OwnerAdapter, ref, lease, :effect_dispatch)
    assert :ok = Owner.release(OwnerAdapter, ref, lease)

    assert {:ok, {OwnerAdapter, opts}} = Owner.normalize({OwnerAdapter, token: 12})
    assert opts == [token: 12]

    assert {:ok, {OwnerWithoutRelease, []}, %Lease{} = no_release_lease} =
             Owner.claim(OwnerWithoutRelease, ref)

    assert :ok = Owner.release(OwnerWithoutRelease, ref, no_release_lease)

    assert {:error, {:owner_fence_lost, :state_commit, :lease_superseded}} =
             Owner.assert_current(
               {OwnerAdapter, validate: :error},
               ref,
               lease,
               :state_commit
             )
  end

  test "owner boundary contains malformed adapters, failures and non-monotonic tokens" do
    ref = InstanceRef.new(Agent, "subject:owner-errors")
    lease = Lease.new!(owner_id: "owner", fencing_token: 7, issued_at: 1, metadata: %{})

    assert {:error, {:invalid_instance_owner, "bad"}} = Owner.normalize("bad")

    assert {:error, {:invalid_instance_owner, {OwnerAdapter, :non_keyword_options}}} =
             Owner.normalize({OwnerAdapter, [:not_keyword]})

    assert {:error, {:instance_owner_callback_missing, OwnerMissingValidate, :validate, 3}} =
             Owner.validate(OwnerMissingValidate, ref, lease)

    missing = SpectreReflectiveCoreCoverageTest.NotLoadedOwner

    assert {:error, {:instance_owner_not_loaded, ^missing}} = Owner.claim(missing, ref)

    assert {:error, :lease_denied} = Owner.claim({OwnerAdapter, claim: :error}, ref)

    assert {:error, {:invalid_instance_owner_claim, :not_a_claim_reply}} =
             Owner.claim({OwnerAdapter, claim: :invalid}, ref)

    assert {:error, {:invalid_owner_lease_field, :fencing_token, 0}} =
             Owner.claim({OwnerAdapter, claim: :malformed_lease}, ref)

    assert {:error, {:owner_fencing_token_not_monotonic, 7, 7}} =
             Owner.claim(OwnerAdapter, ref, minimum_fencing_token: 7)

    assert {:error, {:instance_owner_exception, OwnerAdapter, :claim, RuntimeError}} =
             Owner.claim({OwnerAdapter, claim: :raise}, ref)

    assert {:error, {:instance_owner_failure, OwnerAdapter, :claim, :throw, :claim_failed}} =
             Owner.claim({OwnerAdapter, claim: :throw}, ref)

    assert {:error, {:invalid_instance_owner_reply, OwnerAdapter, :not_a_validation_reply}} =
             Owner.validate({OwnerAdapter, validate: :invalid}, ref, lease)

    assert {:error, {:instance_owner_exception, OwnerAdapter, :validate, RuntimeError}} =
             Owner.validate({OwnerAdapter, validate: :raise}, ref, lease)

    assert {:error,
            {:instance_owner_failure, OwnerAdapter, :validate, :throw, :validation_failed}} =
             Owner.validate({OwnerAdapter, validate: :throw}, ref, lease)

    assert {:error, {:invalid_instance_owner_reply, OwnerAdapter, :not_a_release_reply}} =
             Owner.release({OwnerAdapter, release: :invalid}, ref, lease)

    assert {:error, {:instance_owner_exception, OwnerAdapter, :release, RuntimeError}} =
             Owner.release({OwnerAdapter, release: :raise}, ref, lease)

    assert {:error, {:instance_owner_failure, OwnerAdapter, :release, :throw, :release_failed}} =
             Owner.release({OwnerAdapter, release: :throw}, ref, lease)
  end

  test "canonical lowering preserves data shape but never treats code as structural data" do
    callback = fn value -> String.trim(value) end

    input = %{
      regex: ~r/^safe$/iu,
      struct: %URI{scheme: "https", host: "example.test"},
      callback: callback,
      callback_pair: {String, :trim},
      callback_with_arguments: {String, :trim, [" value "]},
      ordinary_tuple: {:not_a_module, :value, [1, 2]},
      module: String
    }

    assert {:ok, lowered} = CanonicalData.lower(input, owner: Agent, path: [:root])
    assert get_in(lowered, [:regex, "$spectre_type"]) == "regex"
    assert get_in(lowered, [:struct, "$spectre_type"]) == "struct"
    assert get_in(lowered, [:callback, "$spectre_type"]) == "code_ref"
    assert get_in(lowered, [:callback_pair, "kind"]) == "callback"
    assert get_in(lowered, [:callback_with_arguments, "arguments"]) == [" value "]
    assert lowered.ordinary_tuple == {:not_a_module, :value, [1, 2]}

    assert {:error, {:executable_structural_value, [:payload]}} =
             CanonicalData.structural(%{nested: [{String, :trim}]}, path: [:payload])

    assert {:ok, %{safe: [1, {"two", false}]}} =
             CanonicalData.structural(%{safe: [1, {"two", false}]})
  end

  test "canonical lowering rejects deep, improper and VM-local values without raising" do
    deep = Enum.reduce(1..130, :leaf, fn _index, nested -> [nested] end)

    assert {:error, {:compiled_definition_depth_exceeded, path}} = CanonicalData.lower(deep)
    assert length(path) > 128

    assert {:error, {:improper_compiled_definition_list, [{:tail, 1}]}} =
             CanonicalData.lower([:head | :tail])

    assert {:error, {:nonportable_compiled_definition_value, [], :pid}} =
             CanonicalData.lower(self())

    assert {:error, {:nonportable_compiled_definition_value, [], :reference}} =
             CanonicalData.lower(make_ref())

    assert {:error, {:nonportable_compiled_definition_value, [], :bitstring}} =
             CanonicalData.lower(<<1::1>>)

    port = Port.open({:spawn, "true"}, [])

    assert {:error, {:nonportable_compiled_definition_value, [], :port}} =
             CanonicalData.lower(port)

    if Port.info(port), do: Port.close(port)
  end

  test "components round-trip exactly and reject secrets, AST and ambiguous fields" do
    assert {:ok, component} =
             Component.new(
               component_type: :audit_note,
               schema_ref: "spectre.test/audit-note/1",
               criticality: :descriptive,
               payload: %{"facts" => [1, true, "safe"]}
             )

    assert {:ok, ^component} = component |> Component.to_data() |> Component.from_data()

    assert {:error, {:invalid_definition_component_fields, ["extra"]}} =
             component
             |> Component.to_data()
             |> Map.put("extra", true)
             |> Component.from_data()

    assert {:error, {:invalid_definition_component_data, :list}} = Component.from_data([])
    assert {:error, {:invalid_definition_component, :tuple}} = Component.new({:bad})

    assert {:error, {:invalid_component_schema_ref, ""}} =
             Component.new(
               component_type: :audit_note,
               schema_ref: "",
               criticality: :descriptive,
               payload: %{}
             )

    assert {:error, {:secret_component_payload, ["nested", "auth_token"]}} =
             Component.new(
               component_type: :audit_note,
               schema_ref: "spectre.test/audit-note/1",
               criticality: :descriptive,
               payload: %{"nested" => %{"auth_token" => "private"}}
             )

    ast = {:remote_call, [line: 1], [:argument]}

    assert {:error, {:executable_component_ast, ["nested", 0]}} =
             Component.new(
               component_type: :audit_note,
               schema_ref: "spectre.test/audit-note/1",
               criticality: :descriptive,
               payload: %{"nested" => [ast]}
             )

    assert {:error, {:nonportable_component_payload, _reason}} =
             Component.new(
               component_type: :audit_note,
               schema_ref: "spectre.test/audit-note/1",
               criticality: :descriptive,
               payload: [1 | 2]
             )

    assert_raise ArgumentError, ~r/invalid Definition component/, fn -> Component.new!(%{}) end
  end

  test "manifest and resolver perform publish-readback-bootstrap with exact identities" do
    store = definition_store()
    {canonical, manifest} = definition_fixture()
    definition_ref = Canonical.ref(canonical)

    assert {:ok, receipt} = Store.publish(store, canonical, manifest)
    assert receipt.definition_ref == DefinitionRef.to_string(definition_ref)

    assert resolution = Resolver.resolve!(store, definition_ref)
    assert resolution.definition == canonical
    assert resolution.manifest == manifest

    assert {:ok, candidate_ref} =
             Resolver.bootstrap_candidate(store, definition_ref, created_at: 100)

    assert CandidateRef.valid?(candidate_ref)

    assert {:ok, %{candidate: candidate, resolution: resolved_again}} =
             Resolver.resolve_candidate_for_activation(store, candidate_ref)

    assert candidate.definition_ref == definition_ref
    assert resolved_again.definition_ref == definition_ref
    assert :ok = CandidateRef.verify(candidate_ref, candidate)

    assert {:ok, ^candidate_ref} =
             candidate_ref |> CandidateRef.to_string() |> CandidateRef.parse()

    assert to_string(candidate_ref) == CandidateRef.to_string(candidate_ref)

    assert_raise ArgumentError, ~r/Definition does not resolve/, fn ->
      Resolver.resolve!(store, "sha256:" <> @digest_b)
    end

    assert_raise ArgumentError, ~r/invalid Definition resolution/, fn ->
      Resolver.resolve!(store, definition_ref,
        observed_builds: %{},
        on_drift: :ignore
      )
    end
  end

  test "candidate refs and manifests reject byte-level and normalization tampering" do
    {canonical, manifest} = definition_fixture()

    assert {:error, {:invalid_candidate_ref, :bad}} = CandidateRef.parse(:bad)
    refute CandidateRef.valid?(:bad)

    bad_digest = String.duplicate("g", 64)
    uppercase_digest = String.upcase(@digest_a)

    assert {:error, {:invalid_candidate_ref, ^bad_digest}} =
             CandidateRef.parse("candidate:sha256:" <> bad_digest)

    assert {:error, {:invalid_candidate_ref, ^uppercase_digest}} =
             CandidateRef.parse("candidate:sha256:" <> uppercase_digest)

    assert {:error, {:invalid_gate_receipt_ref, ^uppercase_digest}} =
             GateReceiptRef.parse("gate:sha256:" <> uppercase_digest)

    assert {:error, {:invalid_candidate_ref, @digest_a <> "0"}} =
             CandidateRef.parse("candidate:sha256:" <> @digest_a <> "0")

    assert {:ok, encoded} = Manifest.encode(manifest)
    assert Manifest.encode!(manifest) == encoded
    assert {:ok, ^manifest} = Manifest.decode(encoded)

    data = Manifest.to_data(manifest)

    assert {:error, {:invalid_definition_manifest_data_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> Manifest.from_data()

    assert {:error, {:invalid_definition_manifest_data, :binary}} =
             Manifest.from_data("bad")

    assert {:error, {:invalid_definition_manifest_binary, :tuple}} = Manifest.decode({:bad})

    assert {:error, :invalid_component_contract_snapshot} =
             data
             |> put_in(["component_contracts"], [%{"bad" => true}])
             |> Manifest.from_data()

    contract = hd(manifest.component_contracts)

    assert {:ok, binary_type_manifest} =
             Manifest.new(%{
               manifest
               | component_contracts: [%{contract | component_type: "agent_core"}]
             })

    assert hd(binary_type_manifest.component_contracts).component_type == "agent_core"

    assert {:error, :invalid_component_contract_snapshot} =
             Manifest.new(%{
               manifest
               | component_contracts: [%{contract | component_type: 42}]
             })

    assert {:error, :invalid_component_contract_snapshot} =
             Manifest.new(%{
               manifest
               | component_contracts: [%{contract | status: :invented, contract_version: 1}]
             })

    assert {:error, {:invalid_component_criticality, "unknown"}} =
             data
             |> update_in(["component_contracts", Access.at(0)], fn contract ->
               Map.put(contract, "criticality", "unknown")
             end)
             |> Manifest.from_data()

    assert {:error, {:invalid_definition_ref, "bad"}} =
             data
             |> Map.put("parent_refs", ["bad"])
             |> Manifest.from_data()

    non_normalized = %{manifest | provenance_refs: ["z", "a"]}

    assert {:error, {:definition_manifest_integrity_mismatch, _before, _after}} =
             Manifest.verify(non_normalized, canonical)

    assert_raise ArgumentError, ~r/invalid Definition Manifest/, fn ->
      Manifest.new!(canonical, Envelope.empty(), closure(), publisher_ref: "")
    end
  end

  test "Experience records redacted evidence, snapshots exact refs and purges by retention" do
    store = experience_store()
    {canonical, _manifest} = definition_fixture()
    definition_ref = Canonical.ref(canonical)

    attrs = %{
      definition_ref: definition_ref,
      activation_generation: 2,
      kind: :turn_observed,
      source_ref: "turn:one",
      observed_at: 10,
      expires_at: 20,
      retention: :bounded,
      facts: %{"answer" => "ok", "auth_token" => "secret"},
      provenance: %{"trace" => [%{"api_key" => "private"}]}
    }

    assert {:error, :experience_recording_not_enabled} = Experience.record(store, attrs)

    assert {:ok, evidence_ref} = Experience.record(store, attrs, enabled?: true)
    assert {:ok, evidence} = Experience.fetch(store, evidence_ref)
    assert evidence.facts["auth_token"] == "[REDACTED]"
    assert get_in(evidence.provenance, ["trace", Access.at(0), "api_key"]) == "[REDACTED]"
    assert EvidenceRef.to_string(evidence_ref) == to_string(evidence_ref)
    assert :ok = EvidenceRef.verify(evidence_ref, evidence)

    assert {:ok, [^evidence]} = Experience.list(store, definition_ref, as_of: 15)
    assert {:ok, snapshot} = Experience.snapshot(store, definition_ref, as_of: 15)
    assert :ok = ExperienceStore.verify_snapshot(snapshot)

    assert {:ok, snapshot_data} = ExperienceStore.snapshot_to_data(snapshot)
    assert {:ok, ^snapshot} = ExperienceStore.snapshot_from_data(snapshot_data)
    assert {:ok, snapshot_bytes} = ExperienceStore.encode_snapshot(snapshot)
    assert {:ok, ^snapshot} = ExperienceStore.decode_snapshot(snapshot_bytes)

    assert {:error, :experience_purge_confirmation_required} =
             Experience.purge_expired(store, 20)

    assert {:ok, [deleted]} = Experience.purge_expired(store, 20, confirm?: true)
    assert deleted == EvidenceRef.to_string(evidence_ref)
    assert :not_found = Experience.fetch(store, evidence_ref)
  end

  test "Experience rejects ambiguous input and corrupted snapshots rather than trusting shape" do
    store = experience_store()
    {canonical, _manifest} = definition_fixture()
    definition_ref = Canonical.ref(canonical)

    assert {:error, :invalid_experience_record_options} =
             Experience.record(store, [], enabled?: true, enabled?: false)

    assert {:error, {:invalid_experience_record, :list}} =
             Experience.record(store, [facts: %{}, facts: %{}], enabled?: true)

    assert {:error, {:ambiguous_experience_record_fields, [:facts]}} =
             Experience.record(
               store,
               %{"facts" => %{}, facts: %{}},
               enabled?: true
             )

    assert {:error, {:invalid_experience_record_data, :list}} =
             Experience.record(store, %{facts: [], provenance: %{}}, enabled?: true)

    assert {:error, {:invalid_experience_record, :binary, :tuple}} =
             Experience.record(store, "bad", {:bad})

    assert {:ok, empty} = ExperienceStore.empty_snapshot(definition_ref, 10)
    assert :ok = ExperienceStore.verify_snapshot(empty)

    assert {:error, :invalid_experience_snapshot_evidence} =
             ExperienceStore.verify_snapshot(%{empty | evidence: [:not_evidence]})

    evidence = evidence(definition_ref, 11, 20)
    ref = Evidence.ref(evidence)

    wrong_definition = Canonical.new!(%{canonical | id: :other_experience_definition})

    assert {:error, :experience_snapshot_definition_mismatch} =
             ExperienceStore.verify_snapshot(%{
               empty
               | evidence: [%{evidence | definition_ref: Canonical.ref(wrong_definition)}]
             })

    assert {:error, :experience_snapshot_future_evidence} =
             ExperienceStore.verify_snapshot(%{empty | evidence: [evidence]})

    assert {:error, {:invalid_experience_evidence_ref, %EvidenceRef{}}} =
             ExperienceStore.fetch(store, %EvidenceRef{algorithm: :sha256, digest: "bad"})

    assert {:error, {:experience_evidence_ref_mismatch, _expected, _actual}} =
             EvidenceRef.verify(ref, %{evidence | source_ref: "changed"})

    assert {:error, {:invalid_experience_evidence_ref, :bad}} = EvidenceRef.parse(:bad)
    refute EvidenceRef.valid?(%EvidenceRef{algorithm: :sha256, digest: String.upcase(@digest_a)})
  end

  test "Experience adapter failures and artifact tampering are classified at the boundary" do
    {canonical, _manifest} = definition_fixture()
    definition_ref = Canonical.ref(canonical)
    evidence = evidence(definition_ref, 10, 20)
    ref = Evidence.ref(evidence)

    assert {:error, {:unsupported_canonical_value, [], :pid}} =
             ExperienceStore.identity({ExperienceAdapter, identity: self()})

    assert {:error, {:experience_store_exception, ExperienceAdapter, :identity, RuntimeError}} =
             ExperienceStore.identity({ExperienceAdapter, identity: :raise})

    assert {:error,
            {:experience_store_failure, ExperienceAdapter, :identity, :throw, :identity_failed}} =
             ExperienceStore.identity({ExperienceAdapter, identity: :throw})

    assert {:error, :store_down} =
             ExperienceStore.fetch({ExperienceAdapter, get: {:error, :store_down}}, ref)

    assert {:error, {:invalid_experience_store_get_reply, :bad}} =
             ExperienceStore.fetch({ExperienceAdapter, get: :bad}, ref)

    assert {:error, {:experience_store_exception, ExperienceAdapter, :get, RuntimeError}} =
             ExperienceStore.fetch({ExperienceAdapter, get: :raise}, ref)

    assert {:error, {:experience_store_failure, ExperienceAdapter, :get, :throw, :get_failed}} =
             ExperienceStore.fetch({ExperienceAdapter, get: :throw}, ref)

    invalid_artifact = Value.encode!(%{"artifact_schema" => 1, "unexpected" => true})

    assert {:error, :invalid_experience_artifact} =
             ExperienceStore.fetch({ExperienceAdapter, get: {:ok, invalid_artifact}}, ref)

    mismatched =
      Value.encode!(%{
        "artifact_schema" => 1,
        "ref" => "experience:sha256:" <> @digest_b,
        "evidence" => Evidence.to_data(evidence)
      })

    assert {:error, :experience_artifact_ref_mismatch} =
             ExperienceStore.fetch({ExperienceAdapter, get: {:ok, mismatched}}, ref)

    assert {:error, :delete_failed} =
             ExperienceStore.purge_expired(
               {ExperienceAdapter,
                list: {:ok, [{EvidenceRef.to_string(ref), artifact(ref, evidence)}]},
                delete: {:error, :delete_failed}},
               20,
               confirm?: true
             )

    assert {:error, {:invalid_experience_store_delete_reply, :bad}} =
             ExperienceStore.purge_expired(
               {ExperienceAdapter,
                list: {:ok, [{EvidenceRef.to_string(ref), artifact(ref, evidence)}]}, delete: :bad},
               20,
               confirm?: true
             )
  end

  test "Experience evidence rejects every non-canonical field and detects struct drift" do
    {canonical, _manifest} = definition_fixture()
    definition_ref = Canonical.ref(canonical)
    evidence = evidence(definition_ref, 10, 20)

    assert {:error, {:invalid_experience_evidence_field, :kind, nil}} =
             evidence |> Evidence.to_data() |> Map.put("kind", nil) |> Evidence.from_data()

    assert {:error, {:invalid_experience_evidence_field, :source_ref, ""}} =
             evidence |> Evidence.to_data() |> Map.put("source_ref", "") |> Evidence.from_data()

    assert {:error, {:invalid_experience_evidence_field, :generation, -1}} =
             evidence
             |> Evidence.to_data()
             |> Map.put("activation_generation", -1)
             |> Evidence.from_data()

    assert {:error, {:invalid_experience_evidence_retention, "forever"}} =
             evidence
             |> Evidence.to_data()
             |> Map.put("retention", "forever")
             |> Evidence.from_data()

    for {value, shape} <- [
          {%URI{}, :map},
          {[:bad], :list},
          {"bad", :binary},
          {{:bad}, :tuple},
          {self(), :pid},
          {make_ref(), :reference}
        ] do
      assert {:error, {:invalid_experience_evidence, ^shape}} = Evidence.new(value)
    end

    assert {:error, :experience_evidence_integrity_mismatch} =
             Evidence.verify(%{evidence | kind: :turn_observed})

    assert {:error, {:invalid_experience_evidence_field, :source_ref, nil}} =
             Evidence.verify(%{evidence | source_ref: nil})
  end

  test "Forge critique and oracle artifacts bind exact case, evidence and transport bytes" do
    critique = critique()
    case_digest = Critique.case_digest(critique)

    assert :ok = Critique.verify(critique)
    assert {:ok, ^critique} = critique |> Critique.to_data() |> Critique.from_data()

    approval =
      OracleApproval.new!(%{
        case_digest: case_digest,
        oracle_ref: critique.oracle_ref,
        approver_ref: "host:reviewer",
        approved_at: 20,
        provenance: %{"ticket" => "review-1"}
      })

    assert :ok = OracleApproval.verify(approval)
    assert OracleApproval.approves?(approval, case_digest, critique.oracle_ref)
    refute OracleApproval.approves?(approval, @digest_b, critique.oracle_ref)

    assert {:error, :forge_critique_digest_mismatch} =
             critique
             |> Critique.to_data()
             |> Map.put("digest", @digest_b)
             |> Critique.from_data()

    assert {:error, :forge_critique_digest_mismatch} =
             Critique.verify(%{critique | digest: @digest_b})

    assert {:error, :forge_oracle_approval_digest_mismatch} =
             approval
             |> OracleApproval.to_data()
             |> Map.put("digest", @digest_b)
             |> OracleApproval.from_data()

    assert {:error, :forge_oracle_approval_digest_mismatch} =
             OracleApproval.verify(%{approval | digest: @digest_b})

    assert {:error, :forge_eval_case_requires_oracle} =
             critique_attrs() |> Map.put(:oracle_ref, nil) |> Critique.new()

    assert {:error, :forge_oracle_requires_eval_case} =
             critique_attrs() |> Map.put(:eval_case, nil) |> Critique.new()

    assert {:error, :forge_code_reference_forbidden} =
             critique_attrs() |> Map.put(:profile_ref, "Elixir.System") |> Critique.new()

    assert {:error, {:invalid_forge_critique_field, :critic_id, nil}} =
             critique_attrs() |> Map.put(:critic_id, nil) |> Critique.new()

    assert {:error, {:invalid_forge_critique_field, :profile_ref, 42}} =
             critique_attrs() |> Map.put(:profile_ref, 42) |> Critique.new()

    assert {:error, {:nonportable_forge_critique_field, :provenance, _reason}} =
             critique_attrs()
             |> Map.put(:provenance, %{"runtime" => self()})
             |> Critique.new()

    assert {:error, {:sensitive_forge_provenance, ["auth_token"]}} =
             critique_attrs()
             |> Map.put(:provenance, %{"auth_token" => "private"})
             |> Critique.new()

    assert {:error, {:sensitive_forge_provenance, ["items", 0, "auth_token"]}} =
             critique_attrs()
             |> Map.put(:provenance, %{"items" => [%{"auth_token" => "private"}]})
             |> Critique.new()

    assert {:error, {:nonportable_forge_oracle_provenance, _reason}} =
             OracleApproval.new(%{
               case_digest: case_digest,
               oracle_ref: critique.oracle_ref,
               approver_ref: "host:reviewer",
               approved_at: 20,
               provenance: %{"runtime" => self()}
             })

    assert {:error, {:sensitive_forge_provenance, ["items", 0, "auth_token"]}} =
             OracleApproval.new(%{
               case_digest: case_digest,
               oracle_ref: critique.oracle_ref,
               approver_ref: "host:reviewer",
               approved_at: 20,
               provenance: %{"items" => [%{"auth_token" => "private"}]}
             })

    assert_raise ArgumentError, ~r/invalid Forge oracle approval/, fn ->
      OracleApproval.new!(%{})
    end
  end

  test "Forge Proposal admits typed changes but rejects altered provenance and operations" do
    proposal = proposal()

    assert :ok = Proposal.verify(proposal)
    assert Proposal.ref(proposal) == "forge-proposal:sha256:" <> proposal.digest
    assert {:ok, bytes} = Proposal.encode(proposal)
    assert {:ok, ^proposal} = Proposal.decode(bytes)

    assert {:ok, ^proposal} = proposal |> Map.from_struct() |> Map.to_list() |> Proposal.new()

    assert {:error, {:invalid_forge_proposal_struct, FunctionClauseError}} =
             Proposal.new(%{proposal | change_set: nil})

    assert {:error, {:invalid_forge_proposal, :binary}} =
             proposal
             |> Proposal.to_data()
             |> Map.put("schema_version", "one")
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    assert {:error, :forge_proposal_digest_mismatch} =
             proposal
             |> Proposal.to_data()
             |> Map.put("digest", @digest_b)
             |> Proposal.from_data()

    assert {:error, :forge_proposal_digest_mismatch} =
             Proposal.verify(%{proposal | digest: @digest_b})

    assert {:error, :forge_proposal_provenance_mismatch} =
             proposal
             |> Proposal.to_data()
             |> update_in(["change_set", "provenance", "forge", "reflection_digest"], fn _ ->
               @digest_b
             end)
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    unauthorized =
      proposal
      |> Proposal.to_data()
      |> put_in(["change_set", "operations"], [
        %{"type" => "update_authority", "payload" => %{}}
      ])
      |> Map.put("digest", nil)

    assert {:error, {:forge_operation_not_allowed, "update_authority"}} =
             Proposal.from_data(unauthorized)

    assert {:error, :invalid_forge_trusted_oracle_refs} =
             proposal
             |> Proposal.to_data()
             |> Map.put("trusted_oracle_refs", :not_a_list)
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    assert {:error, {:invalid_forge_lineage_item, 0, _reason}} =
             proposal
             |> Proposal.to_data()
             |> Map.put("critiques", [%{}])
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    assert {:error, :forge_eval_case_lineage_mismatch} =
             proposal
             |> Proposal.to_data()
             |> put_in(["change_set", "operations"], [
               %{
                 "type" => "add_eval_case",
                 "payload" => %{"case" => %{"id" => "unapproved-case"}}
               }
             ])
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    assert {:error, :invalid_forge_eval_case} =
             proposal
             |> Proposal.to_data()
             |> put_in(["change_set", "operations"], [
               %{"type" => "add_eval_case", "payload" => %{"case" => %{"missing" => "id"}}}
             ])
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    assert {:error, {:forge_critique_limit_exceeded, 17, 16}} =
             proposal
             |> Proposal.to_data()
             |> Map.put("critiques", List.duplicate(%{}, 17))
             |> Map.put("digest", nil)
             |> Proposal.from_data()

    assert {:error, {:invalid_forge_proposal_binary, :tuple}} = Proposal.decode({:bad})
    assert {:error, {:invalid_forge_proposal, :tuple}} = Proposal.new({:bad})
  end

  test "component contracts enforce exact type, criticality and trusted validator replies" do
    {canonical, _manifest} = definition_fixture()

    entry = %{
      component_type: :coverage_contract,
      schema_ref: "spectre.test/coverage-contract/1",
      criticalities: [:must_understand],
      version: 1,
      validator: {ContractValidator, :accept}
    }

    registry = ContractRegistry.new!([Map.to_list(entry)])

    component =
      Component.new!(
        component_type: :coverage_contract,
        schema_ref: entry.schema_ref,
        criticality: :must_understand,
        payload: %{"claim" => "checked"}
      )

    definition = %{canonical | components: [component]}
    assert :ok = ContractRegistry.validate(registry, definition)
    assert {:ok, [snapshot]} = ContractRegistry.snapshot(registry, definition)
    assert snapshot.status == :understood
    assert snapshot.contract_version == 1
    assert :ok = ContractRegistry.verify_snapshot(registry, definition, [snapshot])

    assert {:error, {:component_contract_snapshot_mismatch, [], [_]}} =
             ContractRegistry.verify_snapshot(registry, definition, [])

    wrong_type = %{component | component_type: :different_contract}

    assert {:error,
            {:component_contract_type_mismatch, "spectre.test/coverage-contract/1",
             :coverage_contract, :different_contract}} =
             ContractRegistry.validate(registry, %{definition | components: [wrong_type]})

    wrong_criticality = %{component | criticality: :advisory}

    assert {:error,
            {:component_contract_criticality_mismatch, "spectre.test/coverage-contract/1",
             :advisory}} =
             ContractRegistry.validate(registry, %{definition | components: [wrong_criticality]})

    for {callback, expected} <- [
          {:reject,
           {:component_contract_rejected, "spectre.test/coverage-contract/1", :payload_rejected}},
          {:invalid_reply,
           {:invalid_component_contract_reply, "spectre.test/coverage-contract/1", :accepted}},
          {:raise_error,
           {:component_contract_exception, "spectre.test/coverage-contract/1", RuntimeError}},
          {:throw_error,
           {:component_contract_failure, "spectre.test/coverage-contract/1", :throw,
            :validator_failed}}
        ] do
      callback_registry =
        ContractRegistry.new!([%{entry | validator: {ContractValidator, callback}}])

      assert {:error, ^expected} = ContractRegistry.validate(callback_registry, definition)
    end

    unknown_advisory =
      Component.new!(
        component_type: :future_contract,
        schema_ref: "spectre.future/advisory/1",
        criticality: :advisory,
        payload: %{"opaque" => true}
      )

    assert {:ok, [%{status: :opaque, contract_version: nil}]} =
             ContractRegistry.snapshot(registry, %{definition | components: [unknown_advisory]})

    unknown_required = %{unknown_advisory | criticality: :must_understand}

    assert {:error, {:unknown_must_understand_component, "spectre.future/advisory/1"}} =
             ContractRegistry.validate(registry, %{definition | components: [unknown_required]})
  end

  test "component registry construction fails closed on malformed and duplicate contracts" do
    valid = [
      component_type: :coverage_contract,
      schema_ref: "spectre.test/registry/1",
      criticalities: [:advisory],
      version: 1
    ]

    assert {:ok, registry} = ContractRegistry.new([valid])
    assert {:ok, entry} = ContractRegistry.fetch(registry, "spectre.test/registry/1")
    assert entry.validator == nil

    assert {:error, {:duplicate_component_contract, "spectre.test/registry/1"}} =
             ContractRegistry.register(registry, valid)

    assert {:error, {:invalid_component_contract_ref, nil}} =
             ContractRegistry.new([valid, %{Map.new(valid) | schema_ref: nil}])

    for {attrs, expected} <- [
          {%{Map.new(valid) | component_type: {}}, {:invalid_component_contract_type, {}}},
          {%{Map.new(valid) | schema_ref: ""}, {:invalid_component_contract_ref, ""}},
          {%{Map.new(valid) | criticalities: []},
           {:invalid_component_contract_criticalities, []}},
          {%{Map.new(valid) | criticalities: [:invented]},
           {:invalid_component_contract_criticalities, [:invented]}},
          {%{Map.new(valid) | version: 0}, {:invalid_component_contract_version, 0}},
          {Map.put(Map.new(valid), :validator, :dynamic),
           {:invalid_component_contract_validator, :dynamic}}
        ] do
      assert {:error, ^expected} = ContractRegistry.register(registry, attrs)
    end

    for {value, shape} <- [
          {%{}, :map},
          {{:bad}, :tuple},
          {"bad", :binary},
          {:bad, :other}
        ] do
      assert {:error, {:invalid_component_contract_registry, ^shape}} =
               ContractRegistry.new(value)
    end

    for {value, shape} <- [{{:bad}, :tuple}, {"bad", :binary}, {:bad, :other}] do
      assert {:error, {:invalid_component_contract, ^shape}} =
               ContractRegistry.register(registry, value)
    end

    assert {:error, {:invalid_component_contract_snapshot, :binary}} =
             ContractRegistry.verify_snapshot(registry, definition_fixture() |> elem(0), "bad")

    assert_raise ArgumentError, ~r/invalid component registry/, fn ->
      ContractRegistry.new!([%{}])
    end
  end

  test "authority composition keeps the strict intersection and transports limit identities" do
    requested =
      Envelope.new!(
        operations: [:read, :write],
        effects: [%{"kind" => "lookup"}],
        limits: %{max_tokens: 80, max_pages: 4}
      )

    ceiling =
      Envelope.new!(
        operations: [:read, :admin],
        effects: [%{"kind" => "lookup"}],
        limits: %{max_tokens: 50, max_cost: 2.5}
      )

    effective = Envelope.compose!(requested, ceiling)
    assert effective.operations == [:read]
    assert effective.effects == [%{"kind" => "lookup"}]
    assert effective.limits == %{max_tokens: 50, max_pages: 4, max_cost: 2.5}
    assert Envelope.allows?(effective, :operations, :read)
    refute Envelope.allows?(effective, :operations, :write)
    refute Envelope.allows?(effective, :operations, self())
    refute Envelope.allows?(effective, :invented, :read)

    assert {:ok, ^effective} = effective |> Envelope.to_data() |> Envelope.from_data()

    atom_limit_data = %{"schema_version" => 1, "limits" => %{max_tokens: 12}}
    assert {:ok, %Envelope{limits: %{max_tokens: 12}}} = Envelope.from_data(atom_limit_data)

    assert {:error, {:unknown_authority_limits, ["unknown"]}} =
             Envelope.from_data(%{"schema_version" => 1, "limits" => %{"unknown" => 1}})

    assert {:error, {:invalid_authority_limits, :list}} =
             Envelope.from_data(%{"schema_version" => 1, "limits" => []})

    for {value, shape} <- [
          {%{}, :map},
          {{:bad}, :tuple},
          {"bad", :binary},
          {:bad, :other}
        ] do
      assert {:error, {:invalid_authority_envelope_data, ^shape}} = Envelope.from_data(value)
    end

    for {value, shape} <- [{{:bad}, :tuple}, {"bad", :binary}, {:bad, :other}] do
      assert {:error, {:invalid_authority_envelope, ^shape}} = Envelope.new(value)
    end

    assert_raise ArgumentError, ~r/cannot compose authority/, fn ->
      Envelope.compose!([:not_keyword], %{})
    end
  end

  test "ChangeSet ingestion validates every durable observation before governance" do
    change_set = proposal().change_set
    data = ChangeSet.to_data(change_set)

    keyword = change_set |> Map.from_struct() |> Map.to_list()
    assert {:ok, ^change_set} = ChangeSet.new(keyword)

    assert {:error, {:invalid_governance_change_set_struct, Protocol.UndefinedError}} =
             ChangeSet.new(%{change_set | operations: nil})

    assert {:error, {:invalid_governance_change_set, :binary}} = ChangeSet.new("bad")

    assert_raise ArgumentError, ~r/invalid governance ChangeSet/, fn ->
      ChangeSet.new!(%{})
    end

    assert {:error, {:unsupported_governance_change_set_schema, 2}} =
             data |> Map.put("schema_version", 2) |> ChangeSet.from_data()

    assert {:error, {:invalid_governance_base_candidate_ref, 42}} =
             data |> Map.put("base_candidate_ref", 42) |> ChangeSet.from_data()

    assert {:error, {:invalid_governance_observed_definition_ref, 42}} =
             data |> Map.put("observed_definition_ref", 42) |> ChangeSet.from_data()

    assert {:error, {:invalid_governance_change_set_field, :author_ref, ""}} =
             data |> Map.put("author_ref", "") |> ChangeSet.from_data()

    assert {:error, {:invalid_governance_change_set_field, :created_at, -1}} =
             data |> Map.put("created_at", -1) |> ChangeSet.from_data()

    assert {:error, {:invalid_governance_change_set_digest, :observed_evidence_digest, "bad"}} =
             data |> Map.put("observed_evidence_digest", "bad") |> ChangeSet.from_data()

    uppercase = String.upcase(@digest_a)

    assert {:error, {:invalid_governance_change_set_digest, ^uppercase}} =
             data |> Map.put("observed_evidence_digest", uppercase) |> ChangeSet.from_data()

    assert {:error, {:invalid_governance_change_set_field, :provenance, :list}} =
             data |> Map.put("provenance", []) |> ChangeSet.from_data()

    assert {:error, {:nonportable_governance_change_set_field, :provenance, _reason}} =
             data |> Map.put("provenance", %{"pid" => self()}) |> ChangeSet.from_data()

    assert {:error, :governance_change_set_requires_activation} =
             ChangeSet.verify_base(change_set, nil)

    assert {:error, {:invalid_governance_activation, :binary}} =
             ChangeSet.verify_base(change_set, "not-an-activation")

    for {value, shape} <- [
          {%URI{}, :map},
          {self(), :pid},
          {make_ref(), :reference},
          {{:bad}, :tuple},
          {7, :other}
        ] do
      assert {:error, {:invalid_governance_operation, ^shape}} = ChangeOperation.new(value)
    end
  end

  test "AgentRef transport preserves logical identity and never interns unknown modules" do
    assert AgentRef.schema_version() == 2

    ref = AgentRef.from_id("agent:portable")
    data = AgentRef.to_data(ref)
    assert data["source"] == nil
    assert {:ok, ^ref} = AgentRef.from_data(data)
    assert {:error, :legacy_agent_ref_source_unavailable} = AgentRef.legacy_key(ref)

    assert {:error, {:invalid_agent_ref_id, ""}} =
             AgentRef.from_data(%{"schema_version" => 2, "id" => "", "source" => nil})

    assert {:error, {:unsupported_agent_ref_schema, 1}} =
             AgentRef.from_data(%{"schema_version" => 1})

    missing_module = "Elixir.SpectreReflectiveCoreCoverageTest.UnknownAgentSource"

    assert {:error, {:unknown_agent_ref_source, ^missing_module}} =
             AgentRef.from_data(%{
               "schema_version" => 2,
               "id" => "agent:portable",
               "source" => %{
                 "module" => missing_module,
                 "declared_version" => 1,
                 "stack_digest" => nil
               }
             })

    for {source, shape} <- [
          {%{}, :map},
          {[], :list},
          {"bad", :binary},
          {{:bad}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_agent_ref_source, ^shape}} =
               AgentRef.from_data(%{
                 "schema_version" => 2,
                 "id" => "agent:portable",
                 "source" => source
               })
    end

    for {value, shape} <- [
          {%{}, :map},
          {[], :list},
          {"bad", :binary},
          {{:bad}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_agent_ref_data, ^shape}} = AgentRef.from_data(value)
    end

    assert {:error, {:unsupported_agent_ref_schema, 3}} =
             AgentRef.validate(%{ref | schema_version: 3})

    assert {:error, {:invalid_agent_ref_definition, "Elixir.Agent"}} =
             AgentRef.validate(%{ref | definition: "Elixir.Agent"})

    assert {:error, :agent_ref_source_module_missing} =
             AgentRef.validate(%{ref | version: 1})

    assert {:error, :agent_ref_source_version_missing} =
             AgentRef.validate(%{ref | definition: Agent})
  end

  test "Run options pin exact Definition identity and reject nonportable continuation state" do
    {canonical, _manifest} = definition_fixture()
    definition_ref = Canonical.ref(canonical)
    encoded_ref = DefinitionRef.to_string(definition_ref)

    assert Run.definition_ref(Agent, definition_ref: encoded_ref) == definition_ref
    assert :ok = Run.validate_options(definition_ref: encoded_ref)
    assert :ok = Run.validate_options(deployment_requirement: %{"region" => "eu"})

    assert {:error, {:invalid_run_option, :definition_ref, _reason}} =
             Run.validate_options(definition_ref: "sha256:not-a-digest")

    assert {:error, {:invalid_run_option, :definition_ref, 42}} =
             Run.validate_options(definition_ref: 42)

    assert {:error, {:invalid_run_option, :activation_generation, -1}} =
             Run.validate_options(activation_generation: -1)

    assert {:error, {:invalid_run_option, :closure_digest, nil}} =
             Run.validate_options(closure_digest: nil)

    assert {:error, {:invalid_run_option, :deployment_requirement, _reason}} =
             Run.validate_options(deployment_requirement: self())

    assert_raise ArgumentError, ~r/invalid Run Definition Ref/, fn ->
      Run.definition_ref(Agent, definition_ref: "sha256:not-a-digest")
    end

    assert_raise ArgumentError, ~r/invalid Run Definition Ref/, fn ->
      Run.definition_ref(Agent, definition_ref: 42)
    end

    {:ok, other_ref} = DefinitionRef.parse("sha256:" <> @digest_a)

    assert_raise ArgumentError, ~r/Definition Ref does not match/, fn ->
      Run.default_closure_digest(Agent, other_ref)
    end

    assert_raise ArgumentError, ~r/invalid Run closure digest/, fn ->
      Run.new(Agent, Spectre.Input.new("hello"), Spectre.State.new(nil), closure_digest: 42)
    end
  end

  test "projections bind generator, evidence and Definition and reject every tampered axis" do
    {canonical, _manifest} = definition_fixture()

    assert {:ok, projection} =
             Projection.generate(canonical, Spectre.Projection.Audit,
               evidence: %{"turn" => "turn:coverage", "revision" => 3}
             )

    assert :ok = Projection.verify(projection, canonical)
    refute is_nil(projection.input_evidence_digest)

    assert {:error, {:invalid_projection_generator, String}} =
             Projection.generate(canonical, String)

    assert {:error, {:invalid_projection_generator_version, InvalidVersionProjection, 0}} =
             Projection.generate(canonical, InvalidVersionProjection)

    assert {:error, {:invalid_projection_generator, :not_a_generator}} =
             Projection.generate(:not_a_canonical_definition, :not_a_generator, [])

    definition_ref = Canonical.ref(canonical)
    bad_definition_ref = %{definition_ref | digest: "bad"}

    assert {:error, :invalid_projection_definition_ref} =
             Projection.verify_ref(projection, bad_definition_ref)

    assert {:error, :invalid_projection_generator_id} =
             Projection.verify_ref(%{projection | generator_id: ""}, definition_ref)

    assert {:error, :invalid_projection_generator_version} =
             Projection.verify_ref(%{projection | generator_version: 0}, definition_ref)

    assert {:error, :invalid_projection_input_evidence_digest} =
             Projection.verify_ref(%{projection | input_evidence_digest: "bad"}, definition_ref)

    assert {:error, :invalid_projection_digest} =
             Projection.verify_ref(%{projection | digest: "bad"}, definition_ref)

    assert {:error, {:nonportable_projection, _reason}} =
             Projection.verify_ref(%{projection | content: self()}, definition_ref)

    another = Canonical.new!(%{canonical | id: :projection_other_definition})
    assert {:error, :projection_definition_mismatch} = Projection.verify(projection, another)

    assert {:error, :projection_digest_mismatch} =
             Projection.verify_ref(%{projection | content: %{"changed" => true}}, definition_ref)

    for {value, shape} <- [
          {%{}, :map},
          {"bad", :binary},
          {[], :list},
          {{:bad}, :tuple},
          {:bad, :atom},
          {self(), :other}
        ] do
      assert {:error, {:invalid_projection, ^shape, :map}} =
               Projection.verify_ref(value, definition_ref)
    end
  end

  test "experience redaction stops at the first nonportable value and reports exact paths" do
    assert {:ok, redacted, paths} =
             Redactor.redact(
               %{
                 tenant_secret: "private",
                 nested: [%{"authorization" => "bearer"}, %{"safe" => true}]
               },
               keys: [:tenant_secret]
             )

    assert redacted["tenant_secret"] == "[REDACTED]"
    assert get_in(redacted, ["nested", Access.at(0), "authorization"]) == "[REDACTED]"
    assert ["nested", 0, "authorization"] in paths
    assert ["tenant_secret"] in paths

    assert {:error, {:nonportable_experience_value, ["items", 1], :pid}} =
             Redactor.redact(%{"items" => ["safe", self()]})

    assert {:error, {:invalid_experience_redaction_key, 42}} =
             Redactor.redact(%{}, keys: [42])

    assert {:error, {:invalid_experience_redaction_keys, :bad}} =
             Redactor.redact(%{}, keys: :bad)

    for {value, shape} <- [
          {%URI{}, :map},
          {"bad", :binary},
          {self(), :pid},
          {make_ref(), :reference},
          {{:bad}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_experience_redaction_input, ^shape, :list}} =
               Redactor.redact(value)
    end

    assert {:error, {:invalid_experience_redaction_input, :map, :tuple}} =
             Redactor.redact(%{}, {:bad})

    assert {:error, {:invalid_portable_redaction_options, :tuple}} =
             Redactor.redact_portable(%{}, {:bad})

    assert {:ok, {1, "safe"}, []} = Redactor.redact_portable({1, "safe"})

    assert {:error, {:nonportable_redaction_value, [0], :pid}} =
             Redactor.redact_portable([self()])

    assert {:error, {:nonportable_redaction_value, [1], :pid}} =
             Redactor.redact_portable({:safe, self()})

    assert {:error, {:nonportable_redaction_value, [:key], :pid}} =
             Redactor.redact_portable(%{{:complex, :key} => self()})

    too_deep_portable = Enum.reduce(1..66, :leaf, fn _index, nested -> [nested] end)

    assert {:error, {:portable_redaction_depth_exceeded, _path, 64}} =
             Redactor.redact_portable(too_deep_portable)
  end

  test "governance data normalization rejects ambiguous, oversized and process-local evidence" do
    assert {:error, {:nonportable_governance_data, [1], :pid}} =
             GovernanceData.normalize(["safe", self()])

    assert {:error, {:duplicate_governance_data_key, "route"}} =
             GovernanceData.normalize(%{:route => "one", "route" => "two"})

    oversized = Map.new(0..10_000, fn index -> {Integer.to_string(index), index} end)

    assert {:error, {:governance_data_collection_too_large, [], 10_001}} =
             GovernanceData.normalize(oversized)

    for {value, shape} <- [
          {%URI{}, :map},
          {"bad", :binary},
          {self(), :pid},
          {make_ref(), :reference},
          {{:bad}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:governance_data_map_required, ^shape}} =
               GovernanceData.normalize_map(value)
    end
  end

  defp definition_fixture do
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    {canonical, manifest}
  end

  defp closure do
    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/1",
      state_codec_ref: "spectre.instance.canonical.codec/1",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{"beam:Agent" => @digest_a},
      evaluation_corpus_digest: nil,
      compatibility_mode: :adapted_v1
    })
  end

  defp definition_store do
    id = {:reflective_core_definition_store, System.unique_integer([:positive])}
    server = start_supervised!({DefinitionMemory, id: id})
    {DefinitionMemory, server: server}
  end

  defp experience_store do
    id = {:reflective_core_experience_store, System.unique_integer([:positive])}
    server = start_supervised!({ExperienceMemory, id: id})
    {ExperienceMemory, server: server}
  end

  defp evidence(definition_ref, observed_at, expires_at) do
    Evidence.new!(%{
      definition_ref: definition_ref,
      activation_generation: 1,
      kind: :turn_observed,
      source_ref: "turn:test",
      observed_at: observed_at,
      expires_at: expires_at,
      retention: :bounded,
      facts: %{"answer" => "safe"},
      provenance: %{},
      redactions: []
    })
  end

  defp artifact(ref, evidence) do
    Value.encode!(%{
      "artifact_schema" => ExperienceStore.artifact_schema_version(),
      "ref" => EvidenceRef.to_string(ref),
      "evidence" => Evidence.to_data(evidence)
    })
  end

  defp critique_attrs do
    %{
      critic_id: "critic.contract",
      critic_version: 1,
      profile_ref: "profile:deterministic",
      reflection_digest: @digest_a,
      experience_snapshot_digest: @digest_b,
      opinion: "This behavior needs a falsifiable refund case.",
      eval_case: %{
        id: "refund-case",
        input: "refund",
        expected_outcome: :route,
        expected_route: :refund
      },
      oracle_ref: "oracle:refund",
      provenance: %{"model" => "deterministic-test"}
    }
  end

  defp critique do
    {:ok, critique} = critique_attrs() |> Critique.new()
    critique
  end

  defp proposal do
    {:ok, candidate_ref} = CandidateRef.parse("candidate:sha256:" <> @digest_a)

    {:ok, definition_ref} =
      DefinitionRef.parse("sha256:" <> @digest_b,
        canonicalization_version: 1,
        contract_version: 1
      )

    forge_provenance = %{
      "reflection_digest" => @digest_a,
      "experience_snapshot_digest" => @digest_b,
      "critique_digests" => [],
      "oracle_approval_refs" => [],
      "trusted_oracle_refs" => [],
      "parent_proposal_digest" => nil
    }

    change_set =
      ChangeSet.new!(%{
        base_activation_receipt: "activation:one",
        base_candidate_ref: candidate_ref,
        observed_definition_ref: definition_ref,
        observed_authority_epoch: 0,
        observed_evidence_digest: @digest_a,
        operations: [
          %{"type" => "disable_skill", "payload" => %{"mount_id" => "skill:test"}}
        ],
        author_ref: "forge:test",
        provenance: %{"forge" => forge_provenance},
        reason: "Disable the stale capability",
        created_at: 10
      })

    {:ok, proposal} =
      Proposal.new(%{
        change_set: change_set,
        reflection_digest: @digest_a,
        experience_snapshot_digest: @digest_b,
        critiques: [],
        oracle_approvals: [],
        trusted_oracle_refs: [],
        parent_proposal_digest: nil
      })

    proposal
  end
end
