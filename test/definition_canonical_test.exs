defmodule SpectreDefinitionCanonicalTest.Skill do
  @moduledoc false

  use Spectre.Skill,
    id: :canonical_skill,
    description: "Reusable search behavior",
    applicability: %{scopes: [:support], positive: ["find a document"]},
    prompt_root: "test/fixtures/canonical_prompts"

  inject(:context,
    into: :context,
    visibility: :agent,
    priority: :low,
    budget_class: :small,
    token_cap: 64
  )

  requires_action(:search, mode: :read)

  flow :search do
    on :SEARCH, regex: ~r/^search\s+/iu do
      action(:search)
    end
  end
end

defmodule SpectreDefinitionCanonicalTest.Agent do
  @moduledoc false

  use Spectre.Agent,
    id: :canonical_agent,
    version: 7,
    description: "Routes governed support requests",
    metadata: %{team: "runtime"},
    applicability: %{scopes: [:support], negative: ["billing"]},
    prompt_root: "test/fixtures/canonical_prompts"

  skill(SpectreDefinitionCanonicalTest.Skill, as: :search, bind: [search: :search])
  inject(:context, into: :context, budget_class: :small, token_cap: 32)

  flow :support do
    on :SAFE, regex: ~r/^safe$/ do
      reply(:safe)
    end

    on :LOCAL, regex: ~r/^local$/ do
      run(:local_reply)
    end
  end

  def local_reply(_input, _ctx), do: "local"
end

defmodule SpectreDefinitionCanonicalTest.UnsafePromptAgent do
  @moduledoc false
  use Spectre.Agent, prompt_root: "test/fixtures/canonical_prompts"
  inject(:unsafe, into: :instructions)
end

defmodule SpectreDefinitionCanonicalTest.AuditV2 do
  @moduledoc false
  @behaviour Spectre.Projection

  alias Spectre.Definition.Canonical

  @impl true
  def id, do: "spectre.projection.audit"

  @impl true
  def version, do: 2

  @impl true
  def project(canonical, _opts), do: {:ok, Canonical.to_data(canonical)}
end

defmodule SpectreDefinitionCanonicalTest.InvalidProjection do
  @moduledoc false
  def id, do: :invalid
  def version, do: 0
  def project(_canonical, _opts), do: {:ok, self()}
end

defmodule SpectreDefinitionCanonicalTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.Ref
  alias Spectre.Projection
  alias Spectre.Projection.Audit
  alias Spectre.Prompt.Fragment
  alias SpectreDefinitionCanonicalTest.Agent
  alias SpectreDefinitionCanonicalTest.AuditV2
  alias SpectreDefinitionCanonicalTest.InvalidProjection
  alias SpectreDefinitionCanonicalTest.UnsafePromptAgent

  test "release identifies the complete reflective runtime" do
    assert Spectre.version() == "0.3.2"
  end

  test "compiled Agent and mounted Skill lower into one portable canonical envelope" do
    assert {:ok, canonical} = Canonical.lower(Agent)
    assert Definition.canonical!(Agent) == canonical
    assert Definition.canonical(Agent) == {:ok, canonical}
    assert canonical.kind == :agent
    assert canonical.id == :canonical_agent
    assert canonical.declared_version == 7
    assert canonical.origin == :compiled
    assert canonical.canonicalization_version == 1
    assert canonical.contract_version == 1
    assert canonical.digest_algorithm == :sha256

    assert {:ok, identity} = Canonical.fetch_component(canonical, :identity)
    assert identity.criticality == :must_understand

    assert identity.payload.owner_ref == %{
             "$spectre_type" => "code_ref",
             "kind" => "module",
             "mode" => "compiled_only",
             "module" => "Elixir.SpectreDefinitionCanonicalTest.Agent"
           }

    assert {:ok, metadata} = Canonical.fetch_component(canonical, :metadata)
    assert metadata.criticality == :descriptive
    assert metadata.payload.description == "Routes governed support requests"
    assert metadata.payload.authored == %{team: "runtime"}

    assert {:ok, applicability} = Canonical.fetch_component(canonical, :applicability)
    assert applicability.payload.declared == %{scopes: [:support], negative: ["billing"]}
    assert applicability.payload.inferred.labels == [:SAFE, :LOCAL]

    assert {:ok, skills} = Canonical.fetch_component(canonical, :skills)

    assert [%{id: :search, definition_ref: "sha256:" <> skill_digest} = mount] =
             skills.payload.mounts

    assert byte_size(skill_digest) == 64
    assert mount.definition["kind"] == :skill
    assert mount.bindings == %{search: :search}

    assert {:ok, runtime} = Canonical.fetch_component(canonical, :compiled_runtime)
    refute inspect(runtime.payload) =~ "prompt_root"
    refute inspect(runtime.payload) =~ "Routes governed support requests"
    refute contains_runtime_value?(Canonical.to_data(canonical))
  end

  test "routing callbacks and regexes lower to explicit closed references" do
    canonical = Canonical.lower!(Agent)
    {:ok, routing} = Canonical.fetch_component(canonical, :routing)

    safe = Enum.find(routing.payload.rules, &(&1.label == :SAFE))
    local = Enum.find(routing.payload.rules, &(&1.label == :LOCAL))

    assert [%{"$spectre_type" => "regex", "source" => "^safe$"}] = safe.regex

    assert local.handler.callback_ref == %{
             "$spectre_type" => "code_ref",
             "kind" => "callback",
             "module" => "Elixir.SpectreDefinitionCanonicalTest.Agent",
             "function" => "local_reply",
             "arities" => [2],
             "mode" => "compiled_only"
           }

    assert local.handler.kind == :run
  end

  test "compiled prompt assets become closed snapshots with provenance and budgets" do
    canonical = Canonical.lower!(Agent)
    {:ok, prompts} = Canonical.fetch_component(canonical, :prompt_fragments)

    safe =
      Enum.find(prompts.payload.fragments, &String.contains?(&1.content || "", "Canonical task"))

    assert safe.content == "Canonical task for {{input.text}}\n"
    refute safe.content =~ "<%"

    assert safe.placeholders == %{
             "input.text" => %{
               path: ["input", "text"],
               renderer_ref: "spectre.renderer.text/1"
             }
           }

    assert safe.provenance.status == :snapshotted
    assert safe.provenance.logical_path == "safe.text.heex"
    assert byte_size(safe.provenance.source_digest) == 64
    assert byte_size(safe.digest) == 64

    context =
      Enum.find(prompts.payload.fragments, &(&1.source.logical_path == "context.text.heex"))

    assert context.target == :context
    assert context.trust == :data
    assert context.budget_class == :small
    assert context.token_cap == 32
  end

  test "arbitrary EEx and sensitive or VM-local Definition values fail closed" do
    assert {:error, {:executable_compiled_prompt, "unsafe.text.heex"}} =
             Canonical.lower(UnsafePromptAgent)

    secret = %Definition{
      id: :secret_definition,
      owner: Agent,
      config: [secret: "must-not-enter-canon"]
    }

    assert {:error,
            {:secret_compiled_definition_value, [:compiled_runtime, {:value, 0}, 0, :secret]}} =
             Canonical.lower(secret)

    local = %Definition{id: :local_definition, owner: Agent, config: [worker: self()]}

    assert {:error,
            {:nonportable_compiled_definition_value, [:compiled_runtime, {:value, 0}, 0, 1], :pid}} =
             Canonical.lower(local)
  end

  test "canonical bytes and Definition Refs round-trip and detect tampering" do
    first = Canonical.lower!(Agent)
    second = Canonical.lower!(Agent)

    assert Canonical.digest(first) == Canonical.digest(second)
    assert Canonical.encode!(first) == Canonical.encode!(second)
    assert {:ok, ^first} = first |> Canonical.encode!() |> Canonical.decode()

    ref = Canonical.ref(first)
    assert Ref.valid?(ref)
    assert Ref.to_string(ref) == "sha256:" <> Canonical.digest(first)
    assert to_string(ref) == Ref.to_string(ref)
    assert :ok = Ref.verify(ref, first)

    assert {:ok, parsed} =
             Ref.parse(Ref.to_string(ref),
               canonicalization_version: first.canonicalization_version,
               contract_version: first.contract_version
             )

    assert parsed == ref
    assert {:error, {:invalid_definition_ref, _value}} = Ref.parse("sha256:not-a-digest")

    changed =
      Canonical.new!(
        kind: first.kind,
        id: first.id,
        declared_version: 8,
        origin: first.origin,
        components: first.components
      )

    assert {:error, {:definition_ref_mismatch, _, _}} = Ref.verify(ref, changed)
  end

  test "component and envelope constructors enforce schema, criticality and uniqueness" do
    component =
      Component.new!(
        component_type: :sample,
        schema_ref: "spectre.sample/1",
        criticality: :advisory,
        payload: %{value: :ok}
      )

    assert {:ok, ^component} = component |> Component.to_data() |> Component.from_data()

    assert {:error, {:invalid_component_criticality, :optional}} =
             Component.new(
               component_type: :sample,
               schema_ref: "spectre.sample/1",
               criticality: :optional,
               payload: %{}
             )

    assert {:error, {:secret_component_payload, [:api_key]}} =
             Component.new(
               component_type: :sample,
               schema_ref: "spectre.sample/1",
               criticality: :must_understand,
               payload: %{api_key: "not-canonical"}
             )

    quoted = quote(do: System.get_env("SECRET"))

    assert {:error, {:executable_component_ast, []}} =
             Component.new(
               component_type: :sample,
               schema_ref: "spectre.sample/1",
               criticality: :must_understand,
               payload: quoted
             )

    assert_raise ArgumentError, ~r/invalid Definition component/, fn ->
      Component.new!(component_type: nil, schema_ref: "", criticality: :advisory, payload: %{})
    end

    assert {:error, {:duplicate_definition_component, :sample}} =
             Canonical.new(
               kind: :agent,
               id: :duplicate,
               declared_version: 1,
               origin: :runtime,
               components: [component, component]
             )

    assert {:error, {:unknown_definition_component, :missing}} =
             Canonical.fetch_component(Canonical.lower!(Agent), :missing)
  end

  test "canonical prompt fragments enforce the closed template schema" do
    assert {:ok, closed, placeholders} = Fragment.close_template("Hello <%= @input.text %>")

    fragment =
      Fragment.canonical!(%{
        id: :welcome,
        content: closed,
        scope: :agent,
        target: :task,
        position: :end,
        source: %{kind: :snapshot},
        trust: :instruction,
        placeholders: placeholders,
        provenance: %{publisher: :compiled},
        visibility: :agent,
        requested_priority: :normal,
        granted_priority: :normal,
        budget_class: :standard,
        token_cap: 128
      })

    assert byte_size(fragment.digest) == 64

    assert {:ok, "State {{state.data}}", inspect_placeholders} =
             Fragment.close_template("State <%= inspect(@state.data) %>")

    assert inspect_placeholders["state.data"].renderer_ref ==
             "spectre.renderer.inspect/1"

    assert {:error, :ambiguous_prompt_placeholder_renderer} =
             Fragment.close_template("<%= @state.data %> <%= inspect(@state.data) %>")

    assert {:error, :executable_prompt_template} =
             Fragment.close_template("<%= System.system_time() %>")

    assert {:error, {:prompt_placeholder_schema_mismatch, [], ["input.text"]}} =
             Fragment.canonical(%{
               id: :missing_schema,
               content: "{{input.text}}",
               scope: :agent,
               target: :task,
               position: :end,
               source: %{},
               trust: :instruction
             })

    assert {:error, :invalid_prompt_placeholder_schema} =
             Fragment.canonical(%{
               id: :unknown_renderer,
               content: "{{input.text}}",
               scope: :agent,
               target: :task,
               position: :end,
               source: %{},
               trust: :instruction,
               placeholders: %{
                 "input.text" => %{
                   path: ["input", "text"],
                   renderer_ref: "host.callback/1"
                 }
               }
             })

    assert {:ok, dynamic} =
             Fragment.canonical(%{
               id: :provider,
               content: nil,
               scope: :agent,
               target: :context,
               position: :end,
               source: %{kind: :provider},
               trust: :data
             })

    assert dynamic.digest

    assert {:error, :dynamic_prompt_fragment_must_target_context} =
             Fragment.canonical(%{
               id: :bad_provider,
               content: nil,
               scope: :agent,
               target: :task,
               position: :end,
               source: %{},
               trust: :data
             })
  end

  test "Audit projection is exact and generator identity participates in its digest" do
    canonical = Canonical.lower!(Agent)

    assert {:ok, audit} = Projection.generate(canonical)
    assert audit.content == Canonical.to_data(canonical)
    assert audit.generator_id == Audit.id()
    assert audit.generator_version == Audit.version()
    assert audit.definition_ref == Canonical.ref(canonical)
    assert :ok = Projection.verify(audit, canonical)

    assert {:ok, with_evidence} = Projection.generate(canonical, Audit, evidence: %{case: 1})
    assert with_evidence.input_evidence_digest
    refute with_evidence.digest == audit.digest

    assert {:ok, changed_generator} = Projection.generate(canonical, AuditV2)
    assert changed_generator.content == audit.content
    refute changed_generator.digest == audit.digest

    tampered = %{audit | digest: String.duplicate("0", 64)}
    assert {:error, :projection_digest_mismatch} = Projection.verify(tampered, canonical)

    assert {:error, {:invalid_projection_generator_id, InvalidProjection, :invalid}} =
             Projection.generate(canonical, InvalidProjection)

    assert {:error, {:invalid_projection_generator, String}} =
             Projection.generate(canonical, String)
  end

  defp contains_runtime_value?(value)

  defp contains_runtime_value?(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: true

  defp contains_runtime_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_runtime_value?(key) or contains_runtime_value?(item)
    end)
  end

  defp contains_runtime_value?(value) when is_list(value),
    do: Enum.any?(value, &contains_runtime_value?/1)

  defp contains_runtime_value?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_runtime_value?/1)

  defp contains_runtime_value?(_value), do: false
end
