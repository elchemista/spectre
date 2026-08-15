defmodule SpectreFoundationConformanceTest.ProviderPackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :foundation_provider,
    version: "1.0.0",
    contract: 1,
    spectre: ">= 0.3.0 and < 0.4.0",
    provides: [{:contract, :foundation_search}],
    operations: [:foundation_search]
end

defmodule SpectreFoundationConformanceTest.ConsumerPackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :foundation_consumer,
    version: "1.1.0",
    contract: 1,
    spectre: ">= 0.3.0 and < 0.4.0",
    requires: [{:contract, :foundation_search}]
end

defmodule SpectreFoundationConformanceTest.Skill do
  @moduledoc false

  use Spectre.Skill,
    id: :foundation_skill,
    version: 1,
    description: "Compiled Skill included in the foundation golden path",
    applicability: %{scopes: [:foundation], positive: ["foundation"]}

  flow :foundation do
    on :FOUNDATION, regex: ~r/^foundation$/iu do
      reply(:foundation_ready)
    end
  end
end

defmodule SpectreFoundationConformanceTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :foundation_agent, version: 1

  skill(SpectreFoundationConformanceTest.Skill, as: :foundation)

  flow :root do
    on :READY, regex: ~r/^ready$/iu do
      reply(:ready)
    end
  end
end

defmodule SpectreFoundationConformanceTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition
  alias Spectre.Foundation.Conformance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: InstanceCodec
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Stack.Conformance, as: StackConformance
  alias Spectre.State
  alias Spectre.Subject

  alias SpectreFoundationConformanceTest.Agent
  alias SpectreFoundationConformanceTest.ConsumerPackage
  alias SpectreFoundationConformanceTest.ProviderPackage

  @fixtures Path.expand("fixtures/compatibility", __DIR__)
  @gate_fixture Path.join(@fixtures, "0.2.6/foundation-conformance-v1.json")

  @fixture_atoms [
    :a,
    :active_branch,
    :advisory,
    :alpha,
    :authenticated?,
    :b,
    :baseline,
    :beam,
    :branches,
    :captured_at,
    :checkpoint,
    :compatibility,
    :confirm_publish,
    :created_at,
    :dsl,
    :event,
    :fixture,
    :ids,
    :instance_key,
    :local,
    :locale,
    :loop_boundary,
    :memory,
    :nested,
    :ok,
    :operation_scheduler,
    :policy_opened,
    :prompt,
    :publish,
    :publishing,
    :records,
    :ready,
    :request,
    :role,
    :run_id,
    :runtime,
    :sha256,
    :skill,
    :source,
    :telegram,
    :via,
    :waiting,
    :zeta
  ]

  test "the 0.2.6 golden fixture pins every earlier recovery artifact" do
    _fixture_atoms = @fixture_atoms
    fixture = @gate_fixture |> File.read!() |> Jason.decode!()

    assert fixture["schema_version"] == 1
    assert fixture["release"] == "0.2.6"
    assert fixture["foundation_contract"] == Conformance.contract_version()

    Enum.each(fixture["files"], fn entry ->
      bytes = File.read!(Path.join(@fixtures, entry["path"]))
      assert sha256(bytes) == entry["sha256"]
    end)

    matrix = Conformance.matrix()

    assert fixture["durable_formats"]["state"] == stringify(matrix.durable_formats.state)

    assert fixture["durable_formats"]["run"] == %{
             "writer" => 2,
             "readers" => [1, 2]
           }

    assert fixture["durable_formats"]["instance"] == %{
             "writer" => 4,
             "readers" => [1, 2, 3, 4]
           }

    assert stringify(matrix.durable_formats.run) == %{"writer" => 3, "readers" => [1, 2, 3]}
    assert stringify(matrix.durable_formats.instance) == %{"writer" => 3, "readers" => [2, 3]}
    assert fixture["definition"] == stringify(matrix.definition)
    assert fixture["stack"] == stringify(matrix.stack)
  end

  test "one executable gate migrates supported State and Run but rejects retired Instance schemas" do
    _fixture_atoms = @fixture_atoms
    load_checkpoint_types!()

    assert {:ok, %{source_version: 5, writer_version: 5, revision: 12}} =
             Conformance.verify_state(File.read!(fixture("0.1.6/state-v5.json")))

    assert {:ok, %{source_version: 1, writer_version: 3, run_id: "run-0.1.6-ready"}} =
             Conformance.verify_run(read_base64("0.1.6/run-v1.checkpoint.base64"))

    for {path, source_version} <- [
          {"0.2.0/canonical-v1.json.base64", 1},
          {"0.2.3/identity-activation-canonical-v2.json.base64", 2},
          {"0.2.4/event-lifecycle-canonical-v3.json.base64", 3},
          {"0.2.5/skill-state-canonical-v4.json.base64", 4}
        ] do
      expected =
        if source_version in [2, 3],
          do: {:invalid_canonical_checkpoint_format, nil},
          else: {:unsupported_canonical_checkpoint, source_version}

      assert {:error, ^expected} = Conformance.verify_checkpoint(read_base64(path))
    end
  end

  test "fixture and compiled module-first Definitions share the same verification path" do
    _fixture_atoms = @fixture_atoms

    assert {:ok, fixture_report} =
             Conformance.verify_definition(
               read_base64("0.2.1/definition-canonical-v1.base64"),
               read_base64("0.2.2/definition-manifest-v2.base64")
             )

    canonical = Definition.canonical!(Agent)
    manifest = Definition.manifest!(Agent)

    assert {:ok, compiled_report} = Conformance.verify_definition(canonical, manifest)
    assert fixture_report.format == :definition
    assert compiled_report.format == :definition
    assert fixture_report.manifest_contract == 2
    assert compiled_report.manifest_contract == 2
    assert compiled_report.definition_ref =~ "sha256:"
  end

  test "the Instance checkpoint gate binds either a full Ref or its opaque key" do
    ref = InstanceRef.new(Agent, Subject.new("foundation-checkpoint-subject"))
    checkpoint = instance_checkpoint!(ref, "host-defined-state-scope")

    assert {:ok, ref_report} =
             Conformance.verify_instance_checkpoint(checkpoint, ref)

    assert {:ok, key_report} =
             Conformance.verify_instance_checkpoint(checkpoint, ref.key)

    assert ref_report == key_report
    assert ref_report.format == :instance

    wrong_ref = InstanceRef.new(Agent, Subject.new("another-foundation-subject"))

    assert {:error, :canonical_checkpoint_instance_mismatch} =
             Conformance.verify_instance_checkpoint(checkpoint, wrong_ref)

    assert {:error, :canonical_checkpoint_instance_mismatch} =
             Conformance.verify_instance_checkpoint(checkpoint, "another-instance-key")

    assert {:error, {:invalid_foundation_instance_identity, :binary}} =
             Conformance.verify_instance_checkpoint(checkpoint, "")
  end

  test "the Stack matrix validates compatibility, ordering, and cross-package ownership" do
    assert {:ok, report} =
             StackConformance.run([ConsumerPackage, ProviderPackage],
               configs: %{foundation_consumer: %{mode: :strict}}
             )

    assert report.contract_version == 1
    assert report.module_input_contract == 1
    assert report.sealed_runtime_contract == 2
    assert report.package_count == 2
    assert Enum.map(report.packages, & &1.id) == [:foundation_provider, :foundation_consumer]
    assert byte_size(report.stack_digest) == 64
    assert byte_size(report.digest) == 64
  end

  test "the gates reject corruption, incompatible packages, and ambiguous ownership" do
    state = fixture("0.1.6/state-v5.json") |> File.read!() |> Jason.decode!()
    assert {:error, _reason} = state |> Map.put("unknown", true) |> Conformance.verify_state()

    run = read_base64("0.1.6/run-v1.checkpoint.base64")
    run_envelope = :erlang.binary_to_term(run, [:safe])
    corrupted_run = :erlang.term_to_binary(%{run_envelope | "version" => 99}, [:deterministic])
    assert {:error, _reason} = Conformance.verify_run(corrupted_run)

    checkpoint = read_base64("0.2.5/skill-state-canonical-v4.json.base64")
    corrupted = checkpoint |> Jason.decode!() |> Map.put("checkpoint_version", 99)

    assert {:error, {:unsupported_canonical_checkpoint, 99}} =
             Conformance.verify_checkpoint(corrupted)

    assert {:error, :empty_stack_conformance_matrix} = StackConformance.run([])

    assert {:error, :invalid_stack_conformance_options} =
             StackConformance.run([ProviderPackage], [:bad])

    first =
      {ProviderPackage,
       package(:first_collision, "1.0.0", provides: [{:service, :shared_service}])}

    second =
      {ConsumerPackage,
       package(:second_collision, "1.0.0", provides: [{:service, :shared_service}])}

    assert {:error, {:stack_conformance_failed, message}} =
             StackConformance.run([first, second])

    assert message =~ "duplicate Stack service ownership"

    incompatible =
      {ProviderPackage, package(:incompatible, "1.0.0", spectre: ">= 0.1.0 and < 0.2.0")}

    assert {:error, {:stack_conformance_failed, incompatible_message}} =
             StackConformance.run([incompatible])

    assert incompatible_message =~ "requires Spectre"
  end

  test "foundation and Stack public boundaries return stable errors for malformed shapes" do
    _fixture_atoms = @fixture_atoms

    state = fixture("0.1.6/state-v5.json") |> File.read!() |> Jason.decode!()
    assert {:ok, %{format: :state, source_version: 5}} = Conformance.verify_state(state)

    for {value, shape} <- [
          {%{}, :map},
          {[], :list},
          {:invalid, :atom},
          {{:invalid}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_foundation_run_checkpoint, ^shape}} =
               Conformance.verify_run(value)
    end

    canonical = Definition.canonical!(Agent)
    manifest = Definition.manifest!(Agent)

    for {value, shape} <- [
          {URI.parse("/"), :map},
          {[], :list},
          {:invalid, :atom},
          {{:invalid}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_foundation_definition, ^shape}} =
               Conformance.verify_definition(value, manifest)
    end

    assert {:error, {:invalid_foundation_manifest, :tuple}} =
             Conformance.verify_definition(canonical, {:invalid})

    assert StackConformance.contract_version() == 1

    for {entries, opts, entries_shape, opts_shape} <- [
          {%{}, [], :map, :list},
          {[], %{}, :list, :map},
          {:invalid, :invalid, :atom, :atom},
          {{:invalid}, 42, :tuple, :other}
        ] do
      assert {:error, {:invalid_stack_conformance_matrix, ^entries_shape, ^opts_shape}} =
               StackConformance.run(entries, opts)
    end

    assert {:error, {:unknown_stack_conformance_options, [:unknown]}} =
             StackConformance.run([ProviderPackage], unknown: true)

    assert {:error, {:invalid_stack_conformance_configs, :map}} =
             StackConformance.run([ProviderPackage], configs: URI.parse("/"))

    for {entry, shape} <- [
          {%{}, :map},
          {nil, :atom},
          {{:invalid}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_stack_conformance_entry, ^shape}} =
               StackConformance.run([ProviderPackage, entry])
    end
  end

  defp package(id, version, overrides) do
    %{
      id: id,
      version: version,
      contract: 1,
      spectre: ">= 0.3.0 and < 0.4.0"
    }
    |> Map.merge(Map.new(overrides))
  end

  defp load_checkpoint_types! do
    for module <- [
          Spectre.Event.Envelope,
          Spectre.Instance.Activation,
          Spectre.Instance.Lifecycle,
          Spectre.Operation.Control,
          Spectre.Operation.Event,
          Spectre.Operation.Loop,
          Spectre.Operation.View,
          Spectre.Operation.Wait,
          Spectre.Skill.StateBinding
        ] do
      Code.ensure_loaded!(module)
    end
  end

  defp instance_checkpoint!(ref, state_conversation_id) do
    {:ok, canonical} =
      Canonical.new(%{
        flow: %State{conversation_id: state_conversation_id},
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}}
      })

    {:ok, checkpoint} = InstanceCodec.encode_json(canonical)
    checkpoint
  end

  defp fixture(path), do: Path.join(@fixtures, path)

  defp read_base64(path) do
    decoded =
      path
      |> fixture()
      |> File.read!()
      |> String.replace(~r/\s+/, "")
      |> Base.decode64!()

    # Canonical checkpoints never create atoms while decoding. These are
    # trusted, hash-pinned release fixtures, so the test preloads their finite
    # atom vocabulary before exercising the production-safe reader.
    case Jason.decode(decoded) do
      {:ok, json} -> preload_fixture_atoms(json)
      {:error, _reason} -> :ok
    end

    decoded
  end

  defp preload_fixture_atoms(%{"$spectre" => "atom", "value" => value})
       when is_binary(value) do
    _atom = String.to_atom(value)
    :ok
  end

  defp preload_fixture_atoms(value) when is_map(value) do
    Enum.each(value, fn {key, entry} ->
      preload_fixture_atoms(key)
      preload_fixture_atoms(entry)
    end)
  end

  defp preload_fixture_atoms(value) when is_list(value),
    do: Enum.each(value, &preload_fixture_atoms/1)

  defp preload_fixture_atoms(_value), do: :ok

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()
end
