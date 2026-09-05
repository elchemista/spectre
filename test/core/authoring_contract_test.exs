defmodule Spectre.Core.AuthoringContractTest do
  use ExUnit.Case, async: true

  alias Spectre.{Agent, Definition}
  alias Spectre.Candidate.Template

  # Adapted from main@9fad62e: agent_dsl_contract_test,
  # definition_canonical_test and runtime_skill_definition_test. These preserve
  # authoring contracts, not the old runtime's policy/activation semantics.
  defmodule Lookup do
    use Spectre.Skill, namespace: "contracts", name: "lookup", revision: 1, declared_at: 0
    candidate("lookup", class: "document.lookup", row: %{read: true})
  end

  defmodule NonAgentDefinition do
    def definition do
      {:ok, definition} =
        Definition.new(namespace: "contracts", name: "plain", revision: 1, declared_at: 0)

      definition
    end
  end

  defmodule MalformedComponent do
    def definition do
      original = Lookup.definition()
      body = Map.put(original.body, "components", %{42 => original.ref})
      {:ok, revised} = Definition.revise(original, body, 1)
      revised
    end
  end

  test "compiled and data-authored declarations have the same exact Definition" do
    assert {:ok, template} =
             Template.new(%{"class" => "document.lookup", "row" => %{"read" => true}})

    assert {:ok, authored} =
             Definition.new(
               namespace: "contracts",
               name: "lookup",
               revision: 1,
               declared_at: 0,
               body: %{
                 "format" => "spectre-agent-declaration-v1",
                 "candidates" => %{"lookup" => template},
                 "components" => %{}
               }
             )

    assert authored === Lookup.definition()
    assert {:ok, ^authored} = authored |> Definition.canonical() |> Definition.from_canonical()
  end

  test "installed component references participate in the Definition digest" do
    module =
      compile_declaration(
        quote do
          install(unquote(Lookup), as: "documents")
        end
      )

    original = module.definition()
    assert {:ok, _, %{"documents" => ref}} = Agent.declarations(original)
    assert ref == Lookup.definition().ref

    tampered =
      original
      |> Definition.canonical()
      |> put_in(["body", "components", "documents"], "definition:forged")

    assert {:error, _} = Definition.from_canonical(tampered)
    assert {:ok, changed} = tampered |> Map.delete("ref") |> Definition.new()
    refute changed.ref == original.ref
  end

  test "duplicate installs and invalid namespaces fail before runtime startup" do
    assert_raise CompileError, ~r/duplicate_declaration/, fn ->
      compile_declaration(
        quote do
          install(unquote(Lookup), as: "same")
          install(unquote(Lookup), as: "same")
        end
      )
    end

    for name <- [nil, true, 42, "", "nested/path"] do
      assert_raise CompileError, ~r/invalid_declaration_name/, fn ->
        compile_declaration(
          quote do
            install(unquote(Lookup), as: unquote(name))
          end
        )
      end
    end
  end

  test "invalid install options and non-declaration modules fail explicitly" do
    for options <- [[], [:invalid], %{unknown: true}, [as: "one", as: "two"]] do
      assert_raise CompileError, fn ->
        compile_declaration(
          quote do
            install(unquote(Lookup), unquote(Macro.escape(options)))
          end
        )
      end
    end

    for component <- [nil, "Elixir.Unknown", String, NonAgentDefinition] do
      assert_raise CompileError, fn ->
        compile_declaration(
          quote do
            install(unquote(component), as: "invalid")
          end
        )
      end
    end
  end

  test "VM-local values cannot enter compiled Candidate declarations" do
    for expression <- [quote(do: self()), quote(do: make_ref()), quote(do: fn -> :ok end)] do
      assert_raise CompileError, ~r/invalid Spectre declaration/, fn ->
        compile_declaration(
          quote do
            candidate("unsafe", consequence: %{"value" => unquote(expression)})
          end
        )
      end
    end
  end

  test "unknown data-authored keys never become runtime atoms" do
    unknown = "unknown-template-field-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, _} = Template.new(%{unknown => "ignored?"})
    assert {:error, _} = Template.bind(%{"class" => "document.lookup"}, %{unknown => true})
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "transported declarations reject malformed nested component names and references" do
    for components <- [
          %{"" => "ref"},
          %{1 => "ref"},
          %{"bad//path" => "ref"},
          %{"valid" => nil},
          %{"valid" => 42}
        ] do
      assert {:ok, definition} =
               Definition.revise(
                 Lookup.definition(),
                 Map.put(Lookup.definition().body, "components", components),
                 1
               )

      assert {:error, _} = Agent.declarations(definition)
    end
  end

  test "transported declarations reject malformed and noncanonical templates" do
    for templates <- [
          %{1 => %{}},
          %{"" => %{}},
          %{"unsafe" => %{"identity_key" => "fixed"}},
          %{"unsafe" => 42},
          %{"unsafe" => %{"row" => %{"read" => true}}}
        ] do
      assert {:ok, definition} =
               Definition.revise(
                 Lookup.definition(),
                 Map.put(Lookup.definition().body, "candidates", templates),
                 1
               )

      assert {:error, _} = Agent.declarations(definition)
    end
  end

  test "a custom component provider cannot bypass declaration validation during installation" do
    assert_raise CompileError, ~r/invalid_declaration_path/, fn ->
      compile_declaration(
        quote do
          install(unquote(MalformedComponent), as: "custom")
        end
      )
    end
  end

  test "an unknown format or discarded envelope fields cannot masquerade as Agent declarations" do
    original = Lookup.definition()

    for body <- [
          Map.put(original.body, "format", "spectre-agent-declaration-v999"),
          Map.put(original.body, "ignored", "authority?"),
          Map.put(original.body, "components", nil),
          Map.delete(original.body, "candidates")
        ] do
      assert {:ok, revised} = Definition.revise(original, body, 1)
      assert {:error, :not_an_agent_declaration} = Agent.declarations(revised)
    end
  end

  defp compile_declaration(body) do
    module = Module.concat(__MODULE__, "Compiled#{System.unique_integer([:positive])}")

    {:module, ^module, _binary, _value} =
      Module.create(
        module,
        quote do
          use Spectre.Agent,
            namespace: "contracts",
            name: "composed",
            revision: 1,
            declared_at: 0

          unquote(body)
        end,
        Macro.Env.location(__ENV__)
      )

    module
  end
end
