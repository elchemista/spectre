defmodule Spectre.Server.ToolCompilerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  defmodule Package do
    use Spectre.Stack.Installable, id: :compiler_tool, version: "0.1.0", spectre: "~> 0.4.0"

    @impl true
    def tools(config) do
      name = Keyword.get(config, :name, :sample)

      %{
        name => %{
          contract: 1,
          adapter: AdapterNotCompiledYet,
          default: :read,
          operations: %{read: %{path: :cognitive, retry: :safe, max_bytes: 1024}}
        }
      }
    end
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  test "unused generated helpers compile without warnings and keep a pinned snapshot" do
    module = fresh_module()

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Spectre.Server, tools: #{inspect(Stack)}
        end
        """)
      end)

    assert output == ""

    assert %{sample: %{installation_id: :compiler_tool, installation_digest: hash}} =
             module.__spectre_server_tools__()

    assert is_binary(hash)
    refute function_exported?(module, :sample, 3)
    refute Code.ensure_loaded?(AdapterNotCompiledYet)
  end

  test "helper calls create commands without invoking or loading the adapter" do
    module = fresh_module()

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Spectre.Server, tools: #{inspect(Stack)}
      def handle_flow(:unmatched, input, ctx), do: sample(ctx, input, on_result: :result)
    end
    """)

    ctx = %Spectre.Server.Context{}
    returned = module.handle_flow(:unmatched, "input", ctx)
    assert [%Spectre.Server.Command{kind: :tool}] = returned.commands
    refute Code.ensure_loaded?(AdapterNotCompiledYet)
  end

  test "local public or private definitions cannot shadow either generated arity" do
    for definition <- ["def sample(_, _), do: :shadow", "defp sample(_, _, _), do: :shadow"] do
      assert_raise ArgumentError, ~r/conflicts with a Server/, fn ->
        Code.compile_string("""
        defmodule #{inspect(fresh_module())} do
          use Spectre.Server, tools: #{inspect(Stack)}
          #{definition}
        end
        """)
      end
    end
  end

  test "core helper, imported macro and callback names cannot be installed as helpers" do
    for name <- [:generate, :handle_flow, :format_status, :is_map_key] do
      stack = fresh_module()

      Code.compile_string("""
      defmodule #{inspect(stack)} do
        use Spectre.Stack
        install #{inspect(Package)}, name: #{inspect(name)}
      end
      """)

      assert_raise ArgumentError, ~r/conflicts with a Server/, fn ->
        Code.compile_string("""
        defmodule #{inspect(fresh_module())} do
          use Spectre.Server, tools: #{inspect(stack)}
        end
        """)
      end
    end
  end

  test "tools must be a compile-time Stack module rather than a runtime expression" do
    assert_raise ArgumentError, ~r/literal Stack module/, fn ->
      Code.compile_string("""
      defmodule #{inspect(fresh_module())} do
        use Spectre.Server, tools: Enum.at([], 0)
      end
      """)
    end
  end

  defp fresh_module do
    Module.concat(__MODULE__, "Generated#{System.unique_integer([:positive])}")
  end
end
