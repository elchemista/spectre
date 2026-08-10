defmodule SpectreDefinitionManifestV2Test.Package do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :manifest_runtime,
    version: "0.2.2",
    contract: 1,
    spectre: ">= 0.2.0 and < 0.3.0",
    operations: [:lookup],
    actions: [:notify],
    resources: [:knowledge_base]
end

defmodule SpectreDefinitionManifestV2Test.Stack do
  @moduledoc false

  use Spectre.Stack, id: :manifest_stack
  install(SpectreDefinitionManifestV2Test.Package)
end

defmodule SpectreDefinitionManifestV2Test.Agent do
  @moduledoc false

  use Spectre.Agent,
    id: :manifest_agent,
    stack: SpectreDefinitionManifestV2Test.Stack
end

defmodule SpectreDefinitionManifestV2Test.Validator do
  @moduledoc false

  def accept(_component), do: :ok
  def reject(_component), do: {:error, :rejected_for_test}
  def malformed(_component), do: :unexpected
  def raises(_component), do: raise("validator failure")
  def throws(_component), do: throw(:validator_failure)
end

defmodule SpectreDefinitionManifestV2Test do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Manifest
  alias Spectre.Execution.Closure
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Contract.V2

  alias SpectreDefinitionManifestV2Test.Agent
  alias SpectreDefinitionManifestV2Test.Stack
  alias SpectreDefinitionManifestV2Test.Validator

  @digest String.duplicate("a", 64)
  @other_digest String.duplicate("b", 64)

  test "authority requests are intersected with host ceilings" do
    requested = %{
      operations: [:read, :delete],
      actions: [:notify],
      state_reads: [:profile],
      state_writes: [:profile],
      limits: %{max_cost: 10, max_duration_ms: 5_000, max_risk: :high}
    }

    ceiling = %{
      operations: [:read],
      state_reads: [:profile],
      limits: %{max_cost: 3, max_duration_ms: 10_000, max_risk: :low}
    }

    assert {:ok, authority} = Envelope.compose(requested, ceiling)
    assert authority.operations == [:read]
    assert authority.actions == []
    assert authority.state_reads == [:profile]
    assert authority.state_writes == []
    assert authority.limits == %{max_cost: 3, max_duration_ms: 5_000, max_risk: :low}
    assert Envelope.allows?(authority, :operations, :read)
    refute Envelope.allows?(authority, :operations, :delete)
    refute Envelope.allows?(authority, :unknown, :read)

    assert authority == authority |> Envelope.to_data() |> Envelope.from_data() |> elem(1)
    assert byte_size(Envelope.digest(authority)) == 64
  end

  test "authority envelopes reject open fields, malformed grants and limits" do
    assert {:error, {:unknown_authority_fields, [:root]}} = Envelope.new(%{root: true})

    assert {:error, {:invalid_authority_grants, :operations, :other}} =
             Envelope.new(%{operations: :read})

    assert {:error, {:invalid_authority_grant, :operations, _reason}} =
             Envelope.new(%{operations: [self()]})

    assert {:error, {:unknown_authority_limits, [:unbounded]}} =
             Envelope.new(%{limits: %{unbounded: true}})

    assert_raise ArgumentError, ~r/invalid authority envelope/, fn ->
      Envelope.new!(operations: :read)
    end
  end

  test "execution closure requires every dependency class and reports build drift" do
    assert {:error, {:incomplete_execution_closure, :stack_ref}} = Closure.new(%{})

    closure = closure()

    assert {:ok, :matched} =
             Closure.compare_builds(closure, %{"beam:Agent" => @digest})

    assert {:drift, [%{reason: :changed, observed: @other_digest, policy: :block}]} =
             Closure.compare_builds(closure, %{"beam:Agent" => @other_digest})

    assert {:drift, [%{reason: :missing, observed: nil}]} =
             Closure.compare_builds(closure, %{})

    assert {:error, :invalid_observed_build_fingerprints} =
             Closure.compare_builds(closure, %{"beam:Agent" => "bad"})

    assert closure == closure |> Closure.to_data() |> Closure.from_data() |> elem(1)
    assert byte_size(Closure.digest(closure)) == 64
  end

  test "execution closure build and load boundaries reject malformed dependency evidence" do
    closure = closure()
    attrs = Map.from_struct(closure)
    data = Closure.to_data(closure)

    assert Closure.schema_version() == 1
    assert {:ok, ^closure} = attrs |> Map.to_list() |> Closure.new()
    assert {:ok, ^closure} = Closure.from_data(closure)

    assert {:error, {:invalid_execution_closure, :list}} = Closure.new([:invalid])
    assert {:error, {:invalid_execution_closure, :other}} = Closure.new(:invalid)

    assert_raise ArgumentError, ~r/invalid execution closure/, fn ->
      Closure.new!(%{})
    end

    assert {:error, {:unknown_execution_closure_fields, [:unknown]}} =
             attrs |> Map.put(:unknown, true) |> Closure.new()

    assert {:error, {:unsupported_execution_closure_schema, 2}} =
             attrs |> Map.put(:schema_version, 2) |> Closure.new()

    assert {:error, {:invalid_execution_closure_list, :package_refs, :other}} =
             attrs |> Map.put(:package_refs, :invalid) |> Closure.new()

    assert {:error, {:invalid_execution_closure_list, :package_refs}} =
             attrs |> Map.put(:package_refs, [""]) |> Closure.new()

    assert {:error, :incomplete_projection_generators} =
             attrs |> Map.put(:projection_generators, []) |> Closure.new()

    assert {:error, :invalid_projection_generators} =
             attrs |> Map.put(:projection_generators, [%{}]) |> Closure.new()

    duplicate_fingerprint = hd(closure.build_fingerprints)

    assert {:error, {:duplicate_build_fingerprint, "beam:Agent"}} =
             attrs
             |> Map.put(:build_fingerprints, [duplicate_fingerprint, duplicate_fingerprint])
             |> Closure.new()

    assert {:error, :incomplete_build_fingerprints} =
             attrs |> Map.put(:build_fingerprints, []) |> Closure.new()

    assert {:error, :invalid_build_fingerprints} =
             attrs |> Map.put(:build_fingerprints, [%{}]) |> Closure.new()

    assert {:error, {:invalid_execution_closure_ref, :stack_ref, ""}} =
             attrs |> Map.put(:stack_ref, "") |> Closure.new()

    assert {:error, {:invalid_execution_closure_digest, "invalid"}} =
             attrs |> Map.put(:evaluation_corpus_digest, "invalid") |> Closure.new()

    assert {:error, {:invalid_execution_compatibility_mode, :future}} =
             attrs |> Map.put(:compatibility_mode, :future) |> Closure.new()

    assert {:error, {:unknown_execution_closure_data_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> Closure.from_data()

    assert {:error, {:incomplete_execution_closure_data, "stack_ref"}} =
             data |> Map.delete("stack_ref") |> Closure.from_data()

    assert {:error, :invalid_projection_generators} =
             data |> Map.put("projection_generators", [%{}]) |> Closure.from_data()

    assert {:error, :invalid_build_fingerprints} =
             data |> Map.put("build_fingerprints", %{}) |> Closure.from_data()

    assert {:error, {:invalid_build_drift_policy, "future"}} =
             data
             |> put_in(["build_fingerprints", Access.at(0), "drift_policy"], "future")
             |> Closure.from_data()

    assert {:error, {:invalid_execution_compatibility_mode, "future"}} =
             data |> Map.put("compatibility_mode", "future") |> Closure.from_data()

    assert {:error, {:invalid_execution_closure_data, :tuple}} =
             Closure.from_data({:invalid, :closure})

    assert {:error, {:invalid_observed_build_fingerprints, :list}} =
             Closure.compare_builds(closure, [])

    assert {:error, {:object_code_unavailable, :spectre_missing_closure_module}} =
             Closure.fingerprint(:spectre_missing_closure_module)
  end

  test "loaded BEAM modules can be fingerprinted only by trusted composition code" do
    assert {:ok, digest} = Closure.fingerprint(Agent)
    assert byte_size(digest) == 64

    assert {:ok, %{ref: "beam:test", digest: ^digest, drift_policy: :report}} =
             Closure.fingerprint_entry("beam:test", Agent, :report)

    assert {:error, {:invalid_fingerprint_module, "Agent"}} = Closure.fingerprint("Agent")

    assert {:error, {:invalid_build_fingerprint_entry, "", Agent, :block}} =
             Closure.fingerprint_entry("", Agent)
  end

  test "component registry fails closed only for unknown critical semantics" do
    canonical = Definition.canonical!(Agent)
    registry = ContractRegistry.default()
    assert :ok = ContractRegistry.validate(registry, canonical)

    must_understand =
      Component.new!(
        component_type: :future_authority,
        schema_ref: "spectre.future.authority/1",
        criticality: :must_understand,
        payload: %{}
      )

    canonical_with_must = %{canonical | components: [must_understand | canonical.components]}

    assert {:error, {:unknown_must_understand_component, "spectre.future.authority/1"}} =
             ContractRegistry.validate(registry, canonical_with_must)

    descriptive = %{must_understand | criticality: :descriptive}
    canonical_with_description = %{canonical | components: [descriptive | canonical.components]}

    assert {:ok, snapshot} = ContractRegistry.snapshot(registry, canonical_with_description)

    assert %{status: :opaque, contract_version: nil} =
             Enum.find(snapshot, &(&1.schema_ref == "spectre.future.authority/1"))
  end

  test "trusted validators are registered out of band and failure-safe" do
    component =
      Component.new!(
        component_type: :reviewed,
        schema_ref: "example.reviewed/1",
        criticality: :must_understand,
        payload: %{value: 1}
      )

    canonical = canonical_with_only(component)

    for {function, expected} <- [
          accept: :ok,
          reject:
            {:error, {:component_contract_rejected, "example.reviewed/1", :rejected_for_test}},
          malformed:
            {:error, {:invalid_component_contract_reply, "example.reviewed/1", :unexpected}},
          raises: {:error, {:component_contract_exception, "example.reviewed/1", RuntimeError}},
          throws:
            {:error,
             {:component_contract_failure, "example.reviewed/1", :throw, :validator_failure}}
        ] do
      registry =
        ContractRegistry.new!([
          %{
            component_type: :reviewed,
            schema_ref: "example.reviewed/1",
            criticalities: [:must_understand],
            version: 1,
            validator: {Validator, function}
          }
        ])

      assert ContractRegistry.validate(registry, canonical) == expected
    end
  end

  test "Manifest V2 round-trips and binds Definition, authority, closure and contracts" do
    canonical = Definition.canonical!(Agent)
    authority = Envelope.new!(operations: [:lookup])
    closure = closure()

    manifest =
      Manifest.new!(canonical, authority, closure,
        publisher_ref: "publisher:local",
        provenance_refs: ["git:abc"],
        receipt_refs: ["eval:green"]
      )

    assert manifest.contract_version == 2
    assert :ok = Manifest.verify(manifest, canonical)
    assert {:ok, ^manifest} = manifest |> Manifest.encode!() |> Manifest.decode()
    assert byte_size(Manifest.digest(manifest)) == 64

    other = %{canonical | declared_version: 99}

    assert {:error, {:definition_ref_mismatch, _expected, _actual}} =
             Manifest.verify(manifest, other)
  end

  test "Stack V1 adapter is read-only and grants only the explicit ceiling" do
    stack_before = Spectre.Stack.definition(Stack)
    compiled = Definition.fetch!(Agent)
    canonical = Canonical.lower!(compiled)

    assert {:ok, contract} =
             V2.from_compiled(compiled, canonical,
               authority_ceiling: %{
                 operations: [:lookup, :not_requested],
                 actions: [:notify],
                 external_data_refs: [:knowledge_base]
               }
             )

    assert contract.contract_version == 2
    assert contract.source_contract == :adapted_v1
    assert contract.authority.operations == [:lookup]
    assert contract.authority.actions == [:notify]
    refute Envelope.allows?(contract.authority, :operations, :not_requested)
    assert contract.execution_closure.compatibility_mode == :adapted_v1
    assert contract.execution_closure.build_fingerprints != []
    assert Spectre.Stack.definition(Stack) == stack_before

    assert {:ok, no_grants} = V1.to_v2(Stack)
    assert no_grants.authority == Envelope.empty()

    manifest = Definition.manifest!(Agent, authority_ceiling: %{operations: [:lookup]})
    assert manifest.authority.operations == [:lookup]
  end

  test "native V2 refuses a closure still marked as adapted V1" do
    assert {:error, {:execution_closure_mode_mismatch, :native_v2, :adapted_v1}} =
             V2.new(Envelope.empty(), closure())

    native = %{closure() | compatibility_mode: :native_v2}
    assert {:ok, %{source_contract: :native_v2}} = V2.new(Envelope.empty(), native)
  end

  defp closure do
    Closure.new!(%{
      stack_ref: "spectre.stack:test",
      package_refs: [],
      contract_refs: ["spectre.operation:lookup"],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/1",
      state_codec_ref: "spectre.instance.canonical.codec/1",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{"beam:Agent" => @digest},
      evaluation_corpus_digest: nil,
      compatibility_mode: :adapted_v1
    })
  end

  defp canonical_with_only(component) do
    Canonical.new!(%{
      kind: :agent,
      id: :registry_test,
      declared_version: 1,
      origin: :runtime,
      components: [component]
    })
  end
end
