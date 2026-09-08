defmodule Spectre.Core.AuthoringContractTest do
  use ExUnit.Case, async: true

  alias Spectre.{Agent, Definition}
  alias Spectre.Agent.RequestBuilder
  alias Spectre.Candidate.Template

  defmodule Lookup do
    use Spectre.Skill, namespace: "contracts", name: "lookup"
    use Spectre.Test.Authoring
    request(:lookup, class: "document.lookup")
  end

  test "publication metadata is explicit and round trips with exact code binding" do
    assert_raise ArgumentError, fn -> Lookup.definition([]) end
    original = Lookup.definition()
    assert {:ok, ^original} = original |> Definition.canonical() |> Definition.from_canonical()
    assert {:ok, _, _} = Agent.verify_definition(Lookup, original)
    assert original.body["format"] == "spectre-agent-declaration-v3"
    assert is_binary(original.body["authoring"]["code_ref"])
  end

  test "mounted components are independently published and pinned in the parent digest" do
    module = compile_declaration(quote do: skill(unquote(Lookup), as: :documents))
    assert_raise ArgumentError, fn -> module.definition(revision: 1, declared_at: 0) end
    original = module.definition()
    assert {:ok, templates, %{"documents" => ref}} = Agent.declarations(original)
    assert Map.keys(templates) == ["documents/lookup"]
    assert ref == Lookup.definition().ref

    body =
      put_in(original.body, ["authoring", "component_definitions", "documents", "ref"], "forged")

    assert {:error, _} = Agent.declarations(%{original | body: body})
    assert {:ok, changed} = Definition.revise(original, body, 1)
    assert {:error, _} = Agent.verify_definition(module, changed)
    assert {:error, _} = Agent.declarations(changed)
  end

  test "two mounts share code but retain distinct names and required bindings" do
    module =
      compile_declaration(
        quote do
          skill(unquote(Lookup), as: :primary)
          skill(unquote(Lookup), as: :secondary)
        end
      )

    assert {:ok, templates, components} = Agent.declarations(module.definition())
    assert Enum.sort(Map.keys(templates)) == ["primary/lookup", "secondary/lookup"]
    assert components["primary"] == components["secondary"]
  end

  test "duplicate mounts and invalid names fail at declaration, before any runtime starts" do
    assert_raise CompileError, fn ->
      compile_declaration(
        quote do
          skill(unquote(Lookup), as: :same)
          skill(unquote(Lookup), as: :same)
        end
      )
    end

    for name <- [nil, true, 42, "", "nested/path"] do
      assert_raise CompileError, fn ->
        compile_declaration(quote do: skill(unquote(Lookup), as: unquote(name)))
      end
    end
  end

  test "mount options cannot hide duplicates or undeclared keys" do
    for opts <- [[], [:invalid], %{unknown: true}, [as: :a, as: :b], [as: :a, start: true]] do
      assert_raise CompileError, fn ->
        compile_declaration(quote do: skill(unquote(Lookup), unquote(Macro.escape(opts))))
      end
    end
  end

  test "unsupported component modules are not loaded as data-authored executable code" do
    for component <- [nil, "Elixir.Unknown", String] do
      assert_raise CompileError, fn ->
        compile_declaration(quote do: skill(unquote(component), as: :invalid))
      end
    end
  end

  test "VM-local values and authority defaults cannot enter request declarations" do
    for expression <- [quote(do: self()), quote(do: make_ref()), quote(do: fn -> :ok end)] do
      assert_raise CompileError, fn ->
        compile_declaration(
          quote do
            request(:unsafe, consequence: %{"value" => unquote(expression)})
          end
        )
      end
    end

    for attrs <- [[identity_key: "frozen"], [row: %{read: true}], [proposer_ref: "admin"]] do
      assert {:error, _} = RequestBuilder.template(attrs)
    end
  end

  test "unknown data keys never create runtime atoms" do
    unknown = "unknown-template-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, _} = RequestBuilder.template(%{unknown => "ignored?"})
    assert {:error, _} = Template.bind(%{"class" => "document.lookup"}, %{unknown => true})
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "transported child records and names are validated without evaluating handlers" do
    for components <- [%{"" => "ref"}, %{1 => "ref"}, %{"bad//path" => "ref"}, %{"valid" => nil}] do
      original = Lookup.definition()
      body = put_in(original.body, ["authoring", "component_definitions"], components)
      assert {:ok, changed} = Definition.revise(original, body, 1)
      assert {:error, _} = Agent.declarations(changed)
    end
  end

  test "transported requests reject noncanonical or executable fields" do
    for requests <- [
          %{1 => %{}},
          %{"" => %{}},
          %{"unsafe" => 42},
          %{"unsafe" => %{"identity_key" => "frozen"}},
          %{"unsafe" => %{"row" => %{"read" => true}}}
        ] do
      original = Lookup.definition()
      body = put_in(original.body, ["authoring", "plan", :requests], requests)
      assert {:ok, changed} = Definition.revise(original, body, 1)
      assert {:error, _} = Agent.declarations(changed)
    end
  end

  test "unknown formats, discarded envelope fields and forged refs do not pass as declarations" do
    original = Lookup.definition()

    for body <- [
          Map.put(original.body, "format", "unknown"),
          Map.put(original.body, "ignored", "authority?"),
          Map.delete(original.body, "authoring")
        ] do
      assert {:ok, changed} = Definition.revise(original, body, 1)
      assert {:error, _} = Agent.declarations(changed)
    end

    assert {:error, _} = Agent.declarations(%{original | ref: "forged"})
  end

  defp compile_declaration(body) do
    module = Module.concat(__MODULE__, "Compiled#{System.unique_integer([:positive])}")

    {:module, ^module, _, _} =
      Module.create(
        module,
        quote do
          use Spectre.Agent, namespace: "contracts", name: "composed"
          use Spectre.Test.Authoring
          unquote(body)
        end,
        Macro.Env.location(__ENV__)
      )

    module
  end
end
