defmodule SpectreReflectiveCanonicalSecurityContractTest.Validator do
  @moduledoc false

  def validate(%{payload: %{"mode" => "ok"}}), do: :ok
  def validate(%{payload: %{"mode" => "reject"}}), do: {:error, :rejected}
  def validate(%{payload: %{"mode" => "bad-reply"}}), do: :accepted
  def validate(%{payload: %{"mode" => "raise"}}), do: raise("validator failed")
  def validate(%{payload: %{"mode" => "throw"}}), do: throw(:validator_failed)
end

defmodule SpectreReflectiveCanonicalSecurityContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Prompt.Fragment
  alias Spectre.SensitiveData

  alias SpectreReflectiveCanonicalSecurityContractTest.Validator

  test "canonical component ingress rejects secrets, executable AST and discarded fields" do
    assert {:ok, component} =
             Component.new(
               component_type: :metadata,
               schema_ref: "spectre.definition.metadata/1",
               criticality: :descriptive,
               payload: %{"description" => "safe"}
             )

    assert {:ok, ^component} = Component.new(component)
    assert {:ok, ^component} = component |> Component.to_data() |> Component.from_data()
    assert {:error, {:invalid_definition_component, :list}} = Component.new([:invalid])

    assert {:error, {:unknown_definition_component_fields, [:ignored]}} =
             component |> Map.from_struct() |> Map.put(:ignored, true) |> Component.new()

    assert {:error, {:invalid_definition_component_fields, ["ignored"]}} =
             component |> Component.to_data() |> Map.put("ignored", true) |> Component.from_data()

    assert {:error, {:invalid_definition_component_fields, ["payload"]}} =
             component |> Component.to_data() |> Map.delete("payload") |> Component.from_data()

    for key <- [
          "auth_token",
          "secret_key",
          "api_secret",
          "x-api-key",
          "session_key",
          "signing_key"
        ] do
      assert SensitiveData.sensitive_key?(key)

      assert {:error, {:secret_component_payload, [^key]}} =
               Component.new(
                 component_type: :metadata,
                 schema_ref: "spectre.definition.metadata/1",
                 criticality: :descriptive,
                 payload: %{key => "must-not-cross-boundary"}
               )
    end

    quoted = quote(do: System.cmd("echo", ["unsafe"]))

    assert {:error, {:executable_component_ast, ["nested"]}} =
             Component.new(
               component_type: :metadata,
               schema_ref: "spectre.definition.metadata/1",
               criticality: :descriptive,
               payload: %{"nested" => quoted}
             )

    assert {:error, {:nonportable_component_payload, _reason}} =
             Component.new(
               component_type: :metadata,
               schema_ref: "spectre.definition.metadata/1",
               criticality: :descriptive,
               payload: %{"pid" => self()}
             )
  end

  test "canonical Definition has one accepted field set and one transport identity" do
    metadata = component(:metadata, "spectre.definition.metadata/1", :descriptive, %{"v" => 1})
    projection = component(:projection, "spectre.definition.projection/1", :advisory, %{})

    canonical =
      Canonical.new!(
        kind: :agent,
        id: "agent:strict",
        declared_version: 3,
        origin: :runtime,
        components: [projection, metadata]
      )

    assert Canonical.canonicalization_version() == 1
    assert Canonical.contract_version() == 1
    assert Enum.map(canonical.components, & &1.component_type) == [:metadata, :projection]
    assert {:ok, ^canonical} = Canonical.new(canonical)
    assert {:ok, ^metadata} = Canonical.fetch_component(canonical, :metadata)

    assert {:error, {:unknown_definition_component, :missing}} =
             Canonical.fetch_component(canonical, :missing)

    assert {:ok, encoded} = Canonical.encode(canonical)
    assert {:ok, ^canonical} = Canonical.decode(encoded)

    assert {:error, {:invalid_canonical_definition, :list}} = Canonical.new([:invalid])

    assert {:error, {:unknown_canonical_definition_fields, [:ignored]}} =
             canonical |> Map.from_struct() |> Map.put(:ignored, true) |> Canonical.new()

    data = Canonical.to_data(canonical)

    assert {:error, {:invalid_canonical_definition_fields, ["ignored"]}} =
             data |> Map.put("ignored", true) |> Canonical.from_data()

    assert {:error, {:invalid_canonical_definition_fields, ["origin"]}} =
             data |> Map.delete("origin") |> Canonical.from_data()

    assert {:error, {:invalid_canonical_definition_fields, ["ignored"]}} =
             data |> Map.put("ignored", true) |> Value.encode!() |> Canonical.decode()

    invalid = [
      {%{canonical | canonicalization_version: 2},
       {:unsupported_definition_canonicalization_version, 2}},
      {%{canonical | contract_version: 2}, {:unsupported_definition_contract_version, 2}},
      {%{canonical | digest_algorithm: :md5}, {:unsupported_definition_digest_algorithm, :md5}},
      {%{canonical | kind: :operation}, {:invalid_canonical_definition_kind, :operation}},
      {%{canonical | id: nil}, :missing_canonical_definition_id},
      {%{canonical | declared_version: nil}, :missing_canonical_definition_version},
      {%{canonical | origin: :network}, {:invalid_canonical_definition_origin, :network}},
      {%{canonical | components: :invalid}, {:invalid_canonical_definition_components, :other}},
      {%{canonical | components: [metadata, metadata]},
       {:duplicate_definition_component, :metadata}}
    ]

    Enum.each(invalid, fn {mutation, reason} ->
      assert {:error, ^reason} = Canonical.new(mutation)
    end)

    assert {:error, {:nonportable_canonical_definition, _reason}} =
             canonical |> Map.from_struct() |> Map.put(:id, self()) |> Canonical.new()
  end

  test "authority composition can only narrow grants and limits" do
    assert Envelope.schema_version() == 1
    assert {:error, {:invalid_authority_envelope, :list}} = Envelope.new([:invalid])

    requested =
      Envelope.new!(
        operations: [:read, :write],
        actions: [:notify],
        limits: %{max_cost: 12.5, max_pages: 20, max_risk: :high, max_tokens: 1_000}
      )

    ceiling =
      Envelope.new!(
        operations: [:read],
        actions: [],
        limits: %{max_cost: 4.0, max_pages: 5, max_risk: :medium, max_tokens: 200}
      )

    assert {:ok, effective} = Envelope.compose(requested, ceiling)
    assert effective.operations == [:read]
    assert effective.actions == []
    assert effective.limits == %{max_cost: 4.0, max_pages: 5, max_risk: :medium, max_tokens: 200}
    assert Envelope.allows?(effective, :operations, :read)
    refute Envelope.allows?(effective, :operations, :write)
    refute Envelope.allows?(effective, :unknown, :read)
    assert {:ok, ^effective} = effective |> Envelope.to_data() |> Envelope.from_data()

    invalid = [
      {%{unknown: []}, {:unknown_authority_fields, [:unknown]}},
      {%{schema_version: 2}, {:unsupported_authority_envelope_schema, 2}},
      {%{operations: :read}, {:invalid_authority_grants, :operations, :other}},
      {%{operations: [self()]}, :nonportable_grant},
      {%{limits: []}, {:invalid_authority_limits, :list}},
      {%{limits: %{max_pages: 1.5}}, {:invalid_authority_limit, :max_pages, 1.5}},
      {%{limits: %{max_risk: :unbounded}}, {:invalid_authority_limit, :max_risk, :unbounded}}
    ]

    Enum.each(invalid, fn
      {%{operations: [_pid]} = attrs, :nonportable_grant} ->
        assert {:error, {:invalid_authority_grant, :operations, _reason}} = Envelope.new(attrs)

      {attrs, reason} ->
        assert {:error, ^reason} = Envelope.new(attrs)
    end)
  end

  test "component registry preserves opaque descriptive data and blocks unknown semantics" do
    descriptive = component("future", "vendor.future/1", :descriptive, %{"value" => 1})
    advisory = component("future-advice", "vendor.advice/1", :advisory, %{})
    critical = component("future-critical", "vendor.critical/1", :must_understand, %{})

    opaque = canonical_with([descriptive, advisory])
    assert :ok = ContractRegistry.validate(ContractRegistry.default(), opaque)
    assert {:ok, snapshot} = ContractRegistry.snapshot(ContractRegistry.default(), opaque)
    assert Enum.all?(snapshot, &(&1.status == :opaque and is_nil(&1.contract_version)))

    assert {:error, {:unknown_must_understand_component, "vendor.critical/1"}} =
             ContractRegistry.validate(ContractRegistry.default(), canonical_with([critical]))

    registry =
      ContractRegistry.new!([
        %{
          component_type: "validated",
          schema_ref: "vendor.validated/1",
          criticalities: [:must_understand],
          version: 1,
          validator: {Validator, :validate}
        }
      ])

    assert :ok = ContractRegistry.validate(registry, canonical_with([validated("ok")]))

    assert {:error, {:component_contract_rejected, "vendor.validated/1", :rejected}} =
             ContractRegistry.validate(registry, canonical_with([validated("reject")]))

    assert {:error, {:invalid_component_contract_reply, "vendor.validated/1", :accepted}} =
             ContractRegistry.validate(registry, canonical_with([validated("bad-reply")]))

    assert {:error, {:component_contract_exception, "vendor.validated/1", RuntimeError}} =
             ContractRegistry.validate(registry, canonical_with([validated("raise")]))

    assert {:error,
            {:component_contract_failure, "vendor.validated/1", :throw, :validator_failed}} =
             ContractRegistry.validate(registry, canonical_with([validated("throw")]))

    assert {:error, {:invalid_component_contract_snapshot, :map}} =
             ContractRegistry.verify_snapshot(registry, canonical_with([validated("ok")]), %{})
  end

  test "prompt fragments close templates and enforce placement, conditions and exact fields" do
    assert {:ok, "Hello {{input.text}}", placeholders} =
             Fragment.close_template("Hello <%= @input.text %>")

    assert {:ok, fragment} =
             Fragment.canonical(%{
               id: :welcome,
               content: "Hello {{input.text}}",
               scope: :agent,
               target: :task,
               position: :end,
               source: %{"kind" => "snapshot"},
               trust: :instruction,
               placeholders: placeholders,
               condition_ref: %{"predicate_ref" => "prompt.allowed"},
               token_cap: 32
             })

    assert {:ok, ^fragment} = Fragment.canonical(fragment)

    assert Fragment.canonical_data(fragment).condition_ref == %{
             "predicate_ref" => "prompt.allowed"
           }

    assert {:error, {:invalid_canonical_prompt_fragment, :list}} = Fragment.canonical([:invalid])
    assert {:error, {:invalid_prompt_template, :list}} = Fragment.close_template([])

    assert {:error, {:unknown_prompt_fragment_fields, [:ignored]}} =
             fragment |> Map.from_struct() |> Map.put(:ignored, true) |> Fragment.canonical()

    base = fragment |> Map.from_struct() |> Map.put(:digest, nil)

    invalid = [
      {Map.put(base, :schema_version, 2), {:unsupported_prompt_fragment_schema, 2}},
      {Map.put(base, :id, nil), :missing_prompt_fragment_id},
      {Map.put(base, :scope, nil), :missing_prompt_fragment_scope},
      {Map.put(base, :target, :system), {:invalid_prompt_fragment_target, :system}},
      {Map.put(base, :position, :middle), {:invalid_prompt_fragment_position, :middle}},
      {Map.put(base, :trust, :trusted), {:invalid_prompt_fragment_trust, :trusted}},
      {Map.put(base, :visibility, :secret), {:invalid_prompt_fragment_visibility, :secret}},
      {Map.put(base, :token_cap, 0), {:invalid_prompt_fragment_token_cap, 0}},
      {Map.put(base, :condition_ref, %{"predicate_ref" => "", "extra" => true}),
       {:invalid_prompt_fragment_condition_ref, %{"predicate_ref" => "", "extra" => true}}},
      {Map.put(base, :content, 42), {:invalid_prompt_fragment_content, :other}},
      {Map.put(base, :content, "<%= System.system_time() %>"), :executable_prompt_template}
    ]

    Enum.each(invalid, fn {attrs, reason} ->
      assert {:error, ^reason} = Fragment.canonical(attrs)
    end)

    assert {:error, :dynamic_prompt_fragment_must_be_data} =
             base
             |> Map.merge(%{
               content: nil,
               target: :context,
               trust: :instruction,
               placeholders: %{}
             })
             |> Fragment.canonical()

    assert {:error, :dynamic_prompt_fragment_has_placeholders} =
             base
             |> Map.merge(%{content: nil, target: :context, trust: :data})
             |> Fragment.canonical()
  end

  defp component(type, schema_ref, criticality, payload) do
    Component.new!(
      component_type: type,
      schema_ref: schema_ref,
      criticality: criticality,
      payload: payload
    )
  end

  defp canonical_with(components) do
    Canonical.new!(
      kind: :agent,
      id: "agent:registry",
      declared_version: 1,
      origin: :runtime,
      components: components
    )
  end

  defp validated(mode),
    do: component("validated", "vendor.validated/1", :must_understand, %{"mode" => mode})
end
