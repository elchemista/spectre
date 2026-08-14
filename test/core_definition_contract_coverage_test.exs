defmodule SpectreCoreDefinitionContractCoverageTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :core_definition_contract_coverage

  operation(:impure_condition, {__MODULE__, :impure_condition},
    input: :any,
    output: :any,
    side_effect: :none
  )

  operation(:pure_condition, {__MODULE__, :pure_condition},
    input: :any,
    output: :boolean,
    side_effect: :none
  )

  def impure_condition(_input), do: true
  def pure_condition(_input), do: true
end

defmodule SpectreCoreDefinitionContractCoverageTest.RawStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  @impl true
  def identity(_opts), do: :core_definition_contract_coverage_store

  @impl true
  def durability(_opts), do: :volatile

  @impl true
  def get(key, opts) do
    case Keyword.fetch!(opts, :reply) do
      reply when is_function(reply, 1) -> reply.(key)
      reply -> reply
    end
  end

  @impl true
  def put(_key, _encoded, _opts), do: :ok
end

defmodule SpectreCoreDefinitionContractCoverageTest.BadWork do
  @moduledoc false

  def __spectre_execution_program__, do: %{}
end

defmodule SpectreCoreDefinitionContractCoverageTest.WorkA do
  @moduledoc false

  use Spectre.Execution.Work,
    id: :shared_contract_work,
    entry: :call,
    budget: %{steps: 2, attempts: 2}

  step(:call, operation: :lookup, next: :done)
  finish(:done)
end

defmodule SpectreCoreDefinitionContractCoverageTest.WorkB do
  @moduledoc false

  use Spectre.Execution.Work,
    id: :shared_contract_work,
    entry: :done,
    budget: %{steps: 1, attempts: 1}

  finish(:done, output: {:fixed, :different})
end

defmodule SpectreCoreDefinitionContractCoverageTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Canonical.Lowerer
  alias Spectre.Definition.Canonical.PromptLowerer
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Definition.Validator
  alias Spectre.Execution.Closure
  alias Spectre.Execution.Program
  alias Spectre.Extension.Mount, as: ExtensionMount
  alias Spectre.Gate.Receipt.Ref, as: GateReceiptRef
  alias Spectre.Governance.CandidateState
  alias Spectre.Prompt.Operation
  alias Spectre.Skill.Definition, as: SkillDefinition

  alias SpectreCoreDefinitionContractCoverageTest.Agent
  alias SpectreCoreDefinitionContractCoverageTest.BadWork
  alias SpectreCoreDefinitionContractCoverageTest.RawStore
  alias SpectreCoreDefinitionContractCoverageTest.WorkA
  alias SpectreCoreDefinitionContractCoverageTest.WorkB

  @digest String.duplicate("a", 64)

  test "Definition Store rejects malformed candidate and gate artifacts at the trust boundary" do
    candidate_ref = "candidate:sha256:" <> @digest
    gate_ref = "gate:sha256:" <> @digest

    assert :not_found = Store.fetch_candidate(raw_store(:not_found), candidate_ref)

    candidate_mismatch = %{
      "schema_version" => 1,
      "candidate_ref" => "candidate:sha256:" <> String.duplicate("b", 64),
      "candidate" => "unused"
    }

    assert {:error, :candidate_store_lookup_mismatch} =
             Store.fetch_candidate(raw_encoded(candidate_mismatch), candidate_ref)

    assert {:error, {:unsupported_candidate_store_artifact_schema, 2}} =
             Store.fetch_candidate(raw_encoded(%{"schema_version" => 2}), candidate_ref)

    for {value, shape} <- [
          {"scalar", :binary},
          {[], :list},
          {%{}, :map},
          {{:tuple}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_candidate_store_artifact, ^shape}} =
               Store.fetch_candidate(raw_encoded(value), candidate_ref)
    end

    assert {:error, {:candidate_store_artifact_invalid, _reason}} =
             Store.fetch_candidate(raw_store({:ok, <<255>>}), candidate_ref)

    gate_mismatch = %{
      "schema_version" => 1,
      "gate_receipt_ref" => "gate:sha256:" <> String.duplicate("b", 64),
      "gate_receipt" => "unused"
    }

    assert {:error, :gate_receipt_store_lookup_mismatch} =
             Store.fetch_gate_receipt(raw_encoded(gate_mismatch), gate_ref)

    assert {:error, {:unsupported_gate_receipt_store_artifact_schema, 2}} =
             Store.fetch_gate_receipt(raw_encoded(%{"schema_version" => 2}), gate_ref)

    assert {:error, {:invalid_gate_receipt_store_artifact, :map}} =
             Store.fetch_gate_receipt(raw_encoded(%{}), gate_ref)

    assert {:error, {:gate_receipt_store_artifact_invalid, _reason}} =
             Store.fetch_gate_receipt(raw_store({:ok, <<255>>}), gate_ref)
  end

  test "Definition Store validates publication headers and receipts after durable read-back" do
    store = memory_store()
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    ref = Canonical.ref(canonical)

    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)
    {:ok, encoded} = Memory.get(Ref.to_string(ref), memory_opts(store))
    {:ok, artifact} = Value.decode(encoded)

    unsupported = artifact |> Map.put("schema_version", 2) |> Value.encode!()

    assert {:error,
            {:definition_store_artifact_invalid,
             {:unsupported_definition_store_artifact_schema, 2}}} =
             Store.fetch(raw_store({:ok, unsupported}), ref)

    invalid_receipt = artifact |> put_in(["receipt", "schema_version"], 2) |> Value.encode!()

    assert {:error,
            {:definition_store_artifact_invalid,
             {:invalid_definition_publication_receipt, %{schema_version: 2}}}} =
             Store.fetch(raw_store({:ok, invalid_receipt}), ref)

    receipt_with_wrong_shape = artifact |> Map.put("receipt", 42) |> Value.encode!()

    assert {:error,
            {:definition_store_artifact_invalid,
             {:invalid_definition_publication_receipt, :other}}} =
             Store.fetch(raw_store({:ok, receipt_with_wrong_shape}), ref)
  end

  test "Candidate publication never trusts an unresolved or unreadable Definition binding" do
    {:ok, definition_ref} = Ref.parse("sha256:" <> @digest)

    candidate =
      Candidate.new!(
        definition_ref: definition_ref,
        manifest_digest: @digest,
        publication_id: "publication:missing",
        created_at: 0
      )

    assert {:error, {:candidate_definition_not_found, "sha256:" <> @digest}} =
             Store.publish_candidate(raw_store(:not_found), candidate)

    assert {:error, {:invalid_definition_store_get_reply, RawStore, :unexpected}} =
             Store.publish_candidate(raw_store(:unexpected), candidate)
  end

  test "Definition and Candidate ancestry propagate Store failures without partial publication" do
    store = memory_store()
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    ref = Canonical.ref(canonical)

    assert {:ok, receipt} = Store.publish(store, canonical, manifest)

    {:ok, missing_parent} =
      Spectre.Definition.Candidate.Ref.parse("candidate:sha256:" <> @digest)

    child_candidate =
      Candidate.new!(
        definition_ref: ref,
        manifest_digest: Manifest.digest(manifest),
        publication_id: receipt.publication_id,
        parent_ref: missing_parent,
        created_at: 0
      )

    artifacts_before = memory_count(store)

    assert {:error, {:missing_candidate_parent, "candidate:sha256:" <> @digest}} =
             Store.publish_candidate(store, child_candidate)

    assert memory_count(store) == artifacts_before

    parent_key = "candidate/" <> to_string(missing_parent)
    assert {:ok, :created} = Memory.put(parent_key, <<255>>, memory_opts(store))
    artifacts_with_parent = memory_count(store)

    assert {:error, {:candidate_store_artifact_invalid, _reason}} =
             Store.publish_candidate(store, child_candidate)

    assert memory_count(store) == artifacts_with_parent

    child = Canonical.new!(%{canonical | id: :definition_child, declared_version: 2})
    child_manifest = Manifest.new!(child, Envelope.empty(), closure(), parent_refs: [ref])

    assert {:error, {:invalid_definition_store_get_reply, RawStore, :unexpected}} =
             Store.publish(raw_store(:unexpected), child, child_manifest)

    assert {:error, {:invalid_definition_store_get_reply, RawStore, :unexpected}} =
             Store.publish(raw_store(:unexpected), canonical, manifest)

    invalid_gate_ref = %GateReceiptRef{algorithm: :sha256, digest: "bad"}

    assert {:error, {:invalid_gate_receipt_store_ref, ^invalid_gate_ref}} =
             Store.fetch_gate_receipt(raw_store(:not_found), invalid_gate_ref)
  end

  test "governed Candidate publication re-reads every declared gate receipt" do
    store = memory_store()
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    definition_ref = canonical |> Canonical.ref() |> Ref.to_string()
    gate_ref = "gate:sha256:" <> @digest

    assert {:ok, receipt} = Store.publish(store, canonical, manifest)

    governance =
      CandidateState.new!(%{
        change_set_digest: @digest,
        base_activation_receipt: "activation:base",
        base_candidate_ref: "candidate:sha256:" <> @digest,
        parent_definition_ref: definition_ref,
        candidate_definition_ref: definition_ref,
        observed_authority_epoch: 0,
        observed_evidence_digest: @digest,
        closure_digest: @digest,
        evaluation_cases_digest: @digest,
        protected_cases_digest: @digest,
        risk: :low,
        required_gates: CandidateState.constitutional_gates(:low),
        state: :composed,
        gate_receipt_refs: [gate_ref]
      })

    candidate =
      Candidate.new!(
        definition_ref: Canonical.ref(canonical),
        manifest_digest: Manifest.digest(manifest),
        publication_id: receipt.publication_id,
        source: :governed_host,
        governance: governance,
        created_at: 0
      )

    assert {:error, {:candidate_gate_receipt_not_found, ^gate_ref}} =
             Store.publish_candidate(store, candidate)

    gate_key = "gate-receipt/" <> gate_ref
    assert {:ok, :created} = Memory.put(gate_key, <<255>>, memory_opts(store))

    assert {:error, {:gate_receipt_store_artifact_invalid, _reason}} =
             Store.publish_candidate(store, candidate)
  end

  test "Canonical public constructors return stable errors for malformed transport data" do
    assert {:error, {:invalid_canonical_definition, :binary}} = Canonical.new("bad")
    assert {:error, {:invalid_canonical_definition, :list}} = Canonical.new([:bad])
    assert {:error, {:invalid_canonical_definition, :tuple}} = Canonical.new({:bad})

    assert_raise ArgumentError, ~r/invalid canonical Definition/, fn ->
      Canonical.new!(%{})
    end

    assert_raise ArgumentError, ~r/cannot lower Definition/, fn ->
      Canonical.lower!(:not_a_spectre_definition)
    end

    assert {:error, {:invalid_canonical_definition_data, :map}} =
             Canonical.from_data(URI.parse("/not-canonical"))

    assert {:error, {:invalid_canonical_definition_data, :list}} = Canonical.from_data([])

    assert {:error, {:invalid_canonical_definition_binary, :other}} = Canonical.decode(42)

    valid = Canonical.new!(kind: :agent, id: :transport, declared_version: 1, origin: :runtime)
    data = Canonical.to_data(valid)

    assert {:error, {:invalid_canonical_definition_components, :other}} =
             data |> Map.put("components", :bad) |> Canonical.from_data()

    assert {:error, {:invalid_definition_component_data, :other}} =
             data |> Map.put("components", [42]) |> Canonical.from_data()

    assert {:error, :invalid_canonical_definition_component} =
             Canonical.new(
               kind: :agent,
               id: :transport,
               declared_version: 1,
               origin: :runtime,
               components: [%{}]
             )
  end

  test "compiled lowering fails closed for invalid and conflicting Work programs" do
    invalid = definition(rules: [%{label: :bad, handler: {:work, BadWork, []}}])

    assert {:error, {:invalid_compiled_execution_program, BadWork, _reason}} =
             Lowerer.lower(invalid)

    conflicting =
      definition(
        rules: [
          %{label: :first, handler: {:work, WorkA, []}},
          %{label: :second, handler: {:work, WorkB, []}}
        ]
      )

    assert {:error, {:conflicting_compiled_execution_program, "shared_contract_work"}} =
             Lowerer.lower(conflicting)

    requirement = %{kind: :operation, name: :lookup, mode: :read, opts: []}

    fixed_input =
      definition(
        requirements: [42, requirement],
        rules: [%{label: :fixed, handler: {:work, WorkA, input: {:fixed, %{safe: true}}}}]
      )

    assert {:ok, _canonical} = Lowerer.lower(fixed_input)

    implicit_fixed =
      definition(
        requirements: [requirement],
        rules: [%{label: :implicit, handler: {:work, WorkA, input: %{safe: true}}}]
      )

    assert {:ok, _canonical} = Lowerer.lower(implicit_fixed)
  end

  test "compiled prompt lowering rejects executable and unregistered conditions" do
    invalid_inject =
      definition(rules: [%{label: :ask, handler: {:ask, :missing, inject: 42}}])

    assert {:error, {:invalid_compiled_prompt, message}} = PromptLowerer.lower(invalid_inject)
    assert message =~ "invalid inject specification"

    unsupported = prompt_operation(:unsupported, {:provider, Agent, :impure_condition}, :task)

    assert {:error, {:unsupported_compiled_prompt_source, :unsupported, _source}} =
             PromptLowerer.lower(definition(injections: [unsupported]))

    anonymous =
      prompt_operation(:anonymous, {:provider, Agent, :impure_condition}, :context,
        condition: fn _value -> true end
      )

    assert {:error, :anonymous_prompt_condition_not_registered} =
             PromptLowerer.lower(definition(injections: [anonymous]))

    invalid_condition =
      prompt_operation(:invalid, {:provider, Agent, :impure_condition}, :context,
        condition: :invalid
      )

    assert {:error, {:invalid_compiled_prompt_condition, :invalid}} =
             PromptLowerer.lower(definition(injections: [invalid_condition]))

    impure =
      prompt_operation(:impure, {:provider, Agent, :impure_condition}, :context,
        condition: {:predicate, :impure_condition}
      )

    assert {:error, {:prompt_condition_not_pure_boolean, :impure_condition}} =
             PromptLowerer.lower(definition(injections: [impure]))

    pure =
      prompt_operation(:pure, {:provider, Agent, :pure_condition}, :context,
        condition: {:predicate, :pure_condition},
        trust: :data
      )

    assert {:ok, [_fragment]} = PromptLowerer.lower(definition(injections: [pure]))

    unknown =
      prompt_operation(:unknown, {:provider, Agent, :pure_condition}, :context,
        condition: {:predicate, :missing_condition}
      )

    assert {:error, {:operation_not_registered, :missing_condition}} =
             PromptLowerer.lower(definition(injections: [unknown]))

    outside = prompt_operation(:outside, {:prompt, "../outside.text.heex"}, :task)

    assert {:error, {:compiled_prompt_resolution_failed, :outside, {:prompt_outside_root, _, _}}} =
             PromptLowerer.lower(definition(injections: [outside]))
  end

  test "Definition Validator reports malformed infrastructure at the declaration boundary" do
    assert Validator.validate!(definition(config: [history: nil]))

    assert Validator.validate!(
             definition(config: [history_summary: fn _history, _opts -> :summary end])
           )

    assert_invalid(definition(config: [history_summary: :bad]), "invalid_history_summarizer")
    assert_invalid(definition(stack_refs: [:orphan]), "stack_refs_without_stack")
    assert_invalid(definition(stack: __MODULE__.MissingStack), "unknown_stack")
    assert_invalid(definition(stack: "bad"), "invalid_stack")

    assert Validator.validate!(definition(config: [turn_handlers: [:handler]]))

    assert_invalid(
      definition(config: [turn_handlers: [:handler, 42]]),
      "invalid_turn_handler"
    )

    assert_invalid(
      definition(kind: :skill, change_surface: %{}),
      "skill_cannot_declare_morph_surface"
    )

    extension = %ExtensionMount{id: :duplicate, module: __MODULE__}

    assert_invalid(
      definition(extensions: [extension, extension]),
      "duplicate_extension"
    )

    assert_invalid(definition(extensions: :bad), "invalid_extensions")

    assert_invalid(
      definition(kind: :skill, extensions: [extension]),
      "skills_cannot_mount_extensions"
    )

    action_requirement = %{kind: :action, name: :lookup, mode: :read}

    assert Validator.validate!(definition(kind: :skill, requirements: [action_requirement]))

    operation_rule = %{label: :LOOKUP, handler: {:operation, :lookup, []}}

    assert_invalid(
      definition(kind: :skill, rules: [operation_rule]),
      "Skill operation :lookup must be declared"
    )

    assert_invalid(
      definition(before_actions: [%{action: :lookup}]),
      "invalid_before_action"
    )
  end

  test "runtime Skill canonical loading rejects forged execution contracts" do
    definition = execution_skill()
    canonical = SkillDefinition.canonical(definition)

    assert {:error, {:unknown_skill_work, :missing}} =
             SkillDefinition.work(definition, :missing)

    assert {:error, {:unknown_skill_work, 42}} = SkillDefinition.work(definition, 42)

    assert {:error, {:invalid_runtime_works, :other}} =
             SkillDefinition.new(%{id: :invalid_works, publisher_ref: "host:test", works: :bad})

    [program] = SkillDefinition.works(definition)

    assert {:error, {:duplicate_runtime_work, "contract_work"}} =
             SkillDefinition.new(%{
               id: :duplicate_works,
               publisher_ref: "host:test",
               works: [Program.to_data(program), Program.to_data(program)]
             })

    for {update, expected} <- [
          {&%{&1 | schema_ref: "spectre.definition.execution/999"},
           {:invalid_skill_execution_schema_ref, "spectre.definition.execution/999"}},
          {&%{&1 | criticality: :advisory}, {:invalid_skill_execution_criticality, :advisory}},
          {&%{&1 | payload: []}, {:invalid_skill_execution_payload, :list}},
          {&%{&1 | payload: Map.put(&1.payload, :extra, true)},
           :unknown_skill_execution_payload_fields}
        ] do
      forged = rewrite_component(canonical, :execution, update)
      assert {:error, ^expected} = SkillDefinition.from_canonical(forged)
    end

    undeclared_operation =
      rewrite_component(canonical, :requirements, fn component ->
        %{component | payload: %{component.payload | requested: []}}
      end)

    assert {:error, {:undeclared_execution_operation_ref, "contract_work", "lookup"}} =
             SkillDefinition.from_canonical(undeclared_operation)

    unsupported_handler =
      rewrite_component(canonical, :routing, fn component ->
        rule = %{
          label: :unsupported,
          flow_path: [:runtime],
          checks: [{:text, "run"}],
          regex: [],
          bag: [],
          jaro: [],
          embedding: [],
          handler: %{kind: :custom}
        }

        %{component | payload: %{component.payload | rules: [rule]}}
      end)

    assert {:error, {:invalid_skill_handler, 0, {:unsupported_runtime_skill_handler, :custom}}} =
             SkillDefinition.from_canonical(unsupported_handler)

    invalid_applicability =
      rewrite_component(canonical, :applicability, fn component ->
        %{component | payload: %{component.payload | declared: []}}
      end)

    assert {:error, {:invalid_canonical_skill_applicability, []}} =
             SkillDefinition.from_canonical(invalid_applicability)
  end

  test "runtime Skill revalidates prompt evidence referenced by Work programs" do
    canonical = inference_skill() |> SkillDefinition.canonical()

    renamed_prompt =
      rewrite_component(canonical, :prompt_fragments, fn component ->
        [fragment] = component.payload.fragments
        %{component | payload: %{component.payload | fragments: [%{fragment | id: :renamed}]}}
      end)

    assert {:error, {:unknown_execution_prompt_ref, "prompt_contract_work", "prompt"}} =
             SkillDefinition.from_canonical(renamed_prompt)

    invalid_enum =
      rewrite_component(canonical, :prompt_fragments, fn component ->
        [fragment] = component.payload.fragments
        %{component | payload: %{component.payload | fragments: [%{fragment | visibility: 42}]}}
      end)

    assert {:error,
            {:invalid_canonical_skill_prompt_fragment, 0,
             {:invalid_runtime_skill_enum, 42, _allowed}}} =
             SkillDefinition.from_canonical(invalid_enum)
  end

  test "runtime Skill routes reject code-shaped and nonportable Work references" do
    attrs = execution_skill_attrs()
    [flow] = attrs.flows
    [route] = flow.routes

    for {work, expected} <- [
          {__MODULE__, {:runtime_skill_code_reference_forbidden, :work_ref}},
          {nil, {:invalid_runtime_skill_name, :work_ref, nil}},
          {:missing, {:unknown_runtime_skill_work, :missing}}
        ] do
      forged_route = %{route | handler: {:work, work}}

      assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_route, 0, ^expected}}} =
               attrs
               |> Map.put(:flows, [%{flow | routes: [forged_route]}])
               |> SkillDefinition.new()
    end

    operation_route = %{route | handler: {:operation, self()}}

    assert {:error,
            {:invalid_runtime_flow, 0,
             {:invalid_runtime_route, 0, {:undeclared_runtime_skill_operation, _pid}}}} =
             attrs
             |> Map.put(:flows, [%{flow | routes: [operation_route]}])
             |> SkillDefinition.new()
  end

  defp raw_store(reply), do: {RawStore, reply: reply}
  defp raw_encoded(value), do: value |> Value.encode!() |> then(&raw_store({:ok, &1}))

  defp memory_store do
    id = {:definition_contract_coverage, System.unique_integer([:positive])}
    server = start_supervised!({Memory, id: id})
    {Memory, server: server}
  end

  defp memory_opts({Memory, opts}), do: opts

  defp memory_count({Memory, opts}) do
    opts |> Keyword.fetch!(:server) |> Memory.count()
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
      build_fingerprints: %{"beam:Agent" => @digest},
      evaluation_corpus_digest: nil,
      compatibility_mode: :adapted_v1
    })
  end

  defp definition(overrides) do
    overrides
    |> Map.new()
    |> then(&struct(%Definition{id: :coverage_definition, owner: Agent}, &1))
  end

  defp prompt_operation(id, source, target, opts \\ []) do
    %Operation{
      id: id,
      source: source,
      scope: :definition,
      target: target,
      position: :end,
      condition: Keyword.get(opts, :condition),
      required?: true,
      trust: Keyword.get(opts, :trust, :instruction),
      opts: []
    }
  end

  defp assert_invalid(definition, expected) do
    error = assert_raise ArgumentError, fn -> Validator.validate!(definition) end
    assert Exception.message(error) =~ expected
  end

  defp execution_program do
    Program.new!(%{
      id: :contract_work,
      entry: :call,
      budget: %{steps: 2, attempts: 2},
      nodes: [
        %{id: :call, kind: :step, operation: :lookup, next: :done},
        %{id: :done, kind: :complete, output: :state}
      ]
    })
  end

  defp execution_skill_attrs do
    %{
      id: :contract_skill,
      publisher_ref: "host:contract-coverage",
      operation_refs: [:lookup],
      works: [Program.to_data(execution_program())],
      flows: [
        %{
          id: :runtime,
          routes: [
            %{
              label: :RUN,
              match: {:exact, "run"},
              handler: {:work, :contract_work},
              input: :input
            }
          ]
        }
      ]
    }
  end

  defp execution_skill, do: execution_skill_attrs() |> SkillDefinition.new!()

  defp inference_skill do
    program =
      Program.new!(%{
        id: :prompt_contract_work,
        entry: :infer,
        budget: %{steps: 2, attempts: 2},
        nodes: [
          %{
            id: :infer,
            kind: :infer,
            operation: :infer,
            prompt: :prompt,
            profile_ref: :balanced,
            next: :done
          },
          %{id: :done, kind: :complete, output: :state}
        ]
      })

    SkillDefinition.new!(%{
      id: :prompt_contract_skill,
      publisher_ref: "host:contract-coverage",
      prompt_budget: 32,
      prompt_fragments: [%{id: :prompt, content: "Safe {{input.text}}", token_cap: 8}],
      works: [Program.to_data(program)]
    })
  end

  defp rewrite_component(canonical, type, update) do
    components =
      Enum.map(canonical.components, fn component ->
        if component.component_type == type, do: update.(component), else: component
      end)

    canonical
    |> Map.from_struct()
    |> Map.put(:components, components)
    |> Canonical.new!()
  end
end
