defmodule Spectre.Stack.ToolsTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.{Conformance, Definition, Installable, Installation, Tools}

  defmodule Package do
    use Spectre.Stack.Installable,
      id: :registered_tools,
      version: "0.1.0",
      spectre: "~> 0.4.0"

    @impl true
    def compile(opts, nil, _caller), do: {:ok, %{binding: Keyword.get(opts, :bind, :save)}}

    @impl true
    def tools(config) do
      %{
        notes: %{
          contract: 1,
          adapter: NotYetCompiled.PackageAdapter,
          default: :read,
          operations: %{
            read: %{path: :cognitive, retry: :safe, max_bytes: 1024},
            save: %{path: :governed, operation: config.binding, max_bytes: 1024}
          }
        }
      }
    end
  end

  defmodule LegacyPackage do
    use Spectre.Stack.Installable,
      id: :legacy_tools,
      version: "0.1.0",
      spectre: "~> 0.4.0"
  end

  defmodule LateBoundPackage do
    def manifest, do: [id: :late_bound, version: "0.1.0", spectre: "~> 0.4.0"]
    def tools(_config), do: Spectre.Stack.ToolsTest.Package.tools(%{binding: :save})
  end

  defmodule CrashingPackage do
    def manifest, do: [id: :crashing_tools, version: "0.1.0", spectre: "~> 0.4.0"]
    def tools(_config), do: raise("broken declaration")
  end

  defmodule ThrowingPackage do
    def manifest, do: [id: :throwing_tools, version: "0.1.0", spectre: "~> 0.4.0"]
    def tools(_config), do: throw(:broken_declaration)
  end

  defmodule EmptyPackage do
    use Spectre.Stack.Installable,
      id: :empty_tools,
      version: "0.1.0",
      spectre: "~> 0.4.0"

    @impl true
    def tools(_config), do: %{}
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package, as: :my_notes, bind: :save_report)
    install(LegacyPackage)
  end

  test "compiler calls tools with compiled config and preserves the helper name under as" do
    definition = Definition.fetch!(Stack)
    assert {:ok, installation} = Definition.installation(definition, :my_notes)
    assert installation.adapters.tools.notes.operations.save.operation == :save_report

    assert %{notes: %{installation_id: :my_notes, descriptor: descriptor, digest: digest}} =
             Tools.table!(definition.installations)

    assert descriptor == installation.adapters.tools.notes
    assert is_binary(digest)
    assert byte_size(digest) == 64
    assert Installation.rebuild!(installation) == installation
    assert Definition.validate(definition) == {:ok, definition}
    refute Code.ensure_loaded?(NotYetCompiled.PackageAdapter)
  end

  test "absent or empty optional callback preserves the old adapter representation" do
    for package <- [LegacyPackage, EmptyPackage] do
      installation = Installation.compile!(package, [], nil, __ENV__)
      assert installation.adapters == %{}
      assert Installation.rebuild!(installation) == installation
    end

    assert Installable.tools!(LegacyPackage, %{}) == %{}
    assert Tools.validate!(%{}) == %{}
  end

  test "late-bound packages can declare tools without use or behaviour" do
    installation = Installation.compile!(LateBoundPackage, [], nil, __ENV__)
    assert installation.adapters.tools == Package.tools(%{binding: :save})
  end

  test "tool callback failures retain package identity and callback name" do
    assert_raise ArgumentError, ~r/CrashingPackage.*stack_callback_exception.*tools/, fn ->
      Installation.compile!(CrashingPackage, [], nil, __ENV__)
    end

    assert_raise ArgumentError, ~r/ThrowingPackage.*stack_callback_failure.*tools/, fn ->
      Installation.compile!(ThrowingPackage, [], nil, __ENV__)
    end
  end

  test "descriptor changes invalidate installation and Stack digests" do
    original = Installation.compile!(Package, [], nil, __ENV__)
    tools = put_in(original.adapters.tools, [:notes, :operations, :read, :retry], :never)
    changed = Installation.rebuild!(%{original | adapters: %{tools: tools}})
    refute original.digest == changed.digest
    refute definition([original]).digest == definition([changed]).digest

    assert {:error, :stack_definition_integrity_mismatch} =
             Definition.validate(%{definition([original]) | installations: [changed]})
  end

  test "serialized installation rebuild revalidates descriptor shape" do
    installation = Installation.compile!(Package, [], nil, __ENV__)
    tools = put_in(installation.adapters.tools, [:notes, :operations, :read, :retry], :always)

    assert_raise ArgumentError, ~r/retry must be/, fn ->
      Installation.rebuild!(%{installation | adapters: %{tools: tools}})
    end
  end

  test "different packages cannot register the same helper, including with installation aliases" do
    first = Installation.compile!(Package, [as: :first], nil, __ENV__)
    second = Installation.compile!(LateBoundPackage, [as: :second], nil, __ENV__)

    assert_raise ArgumentError, ~r/duplicate helper :notes/, fn ->
      definition([first, second])
    end
  end

  test "whole-Stack conformance checks tool collisions for executable package entries" do
    assert {:error, {:stack_conformance_failed, reason}} =
             Conformance.run([Package, LateBoundPackage],
               configs: %{registered_tools: %{binding: :save}}
             )

    assert reason =~ "duplicate helper :notes"

    assert {:ok, first} =
             Conformance.run([Package], configs: %{registered_tools: %{binding: :save}})

    assert {:ok, changed} =
             Conformance.run([Package], configs: %{registered_tools: %{binding: :save_report}})

    refute first.stack_digest == changed.stack_digest
  end

  test "raw manifest conformance never invokes tools or depends on whether the module is loaded" do
    assert {:ok, _report} =
             Conformance.run([{CrashingPackage, CrashingPackage.manifest()}])

    assert {:error, {:stack_conformance_failed, reason}} = Conformance.run([CrashingPackage])
    assert reason =~ "stack_callback_exception"
  end

  test "declarations reject unknown keys, incomplete contracts and non-data descriptors" do
    descriptor = descriptor()

    invalid = [
      [],
      nil,
      %{notes: []},
      %{notes: Map.delete(descriptor, :contract)},
      %{notes: Map.put(descriptor, :invoke, fn -> :unsafe end)},
      %{notes: %{descriptor | contract: 2}},
      %{notes: %{descriptor | adapter: nil}},
      %{notes: %{descriptor | adapter: "Module"}},
      %{notes: %{descriptor | default: :missing}},
      %{notes: %{descriptor | operations: %{}}},
      %{notes: %{descriptor | operations: []}},
      %{notes: %{descriptor | operations: %{nil => read()}}},
      %{notes: %{descriptor | operations: %{"read" => read()}}}
    ]

    for value <- invalid do
      assert_raise ArgumentError, ~r/invalid Stack tools/, fn -> Tools.validate!(value) end
    end
  end

  test "helper names are valid identifiers and do not create atoms from input" do
    for name <- ["notes", nil, true, false, :__private, :"bad-name", :MixedCase, :case, :fn] do
      assert_raise ArgumentError, ~r/invalid Stack tools/, fn ->
        Tools.validate!(%{name => descriptor()})
      end
    end

    for name <- [:notes, :recall?, :remember!] do
      assert Tools.validate!(%{name => descriptor()}) == %{name => descriptor()}
    end
  end

  test "operations have disjoint cognitive and governed contracts" do
    invalid = [
      nil,
      [],
      %{path: :unknown},
      %{path: :cognitive, retry: :always, max_bytes: 100},
      %{path: :cognitive, retry: :safe, max_bytes: 100, operation: :save},
      %{path: :governed, operation: :save, max_bytes: 100, retry: :safe},
      %{path: :governed, operation: nil, max_bytes: 100},
      %{path: :governed, operation: "", max_bytes: 100},
      %{path: :governed, operation: {}, max_bytes: 100},
      %{path: :governed, operation: {:save, self()}, max_bytes: 100},
      %{path: :governed, operation: {:save, %URI{}}, max_bytes: 100}
    ]

    for operation <- invalid do
      assert_raise ArgumentError, ~r/invalid Stack tools/, fn ->
        Tools.validate!(%{notes: %{descriptor() | default: nil, operations: %{op: operation}}})
      end
    end

    for host_operation <- [:save, "save", {:account, :save}] do
      operation = %{path: :governed, operation: host_operation, max_bytes: 1024}
      valid = %{notes: %{descriptor() | default: nil, operations: %{op: operation}}}
      assert Tools.validate!(valid) == valid
    end
  end

  test "byte budgets must fit the core canonical codec" do
    for size <- [
          nil,
          0,
          -1,
          1.5,
          "100",
          Spectre.Server.Checkpoint.max_bytes() + 1,
          16 * 1_024 * 1_024
        ] do
      tools = put_in(%{notes: descriptor()}, [:notes, :operations, :read, :max_bytes], size)
      assert_raise ArgumentError, ~r/max_bytes must be/, fn -> Tools.validate!(tools) end
    end

    for size <- [1, Spectre.Server.Checkpoint.max_bytes()] do
      tools = put_in(%{notes: descriptor()}, [:notes, :operations, :read, :max_bytes], size)
      assert Tools.validate!(tools) == tools
    end
  end

  defp descriptor, do: Package.tools(%{binding: :save}).notes
  defp read, do: %{path: :cognitive, retry: :safe, max_bytes: 1024}

  defp definition(installations),
    do: Definition.new!(id: :test, owner: __MODULE__, installations: installations)
end
