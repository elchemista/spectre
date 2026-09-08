defmodule Spectre.Agents.GenAgentTaskTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Mix.Tasks.Spectre.Gen.Agent, as: Generate
  alias Spectre.Domain.Sequencer
  alias Spectre.Test.DocumentationRuntime
  alias Spectre.V04Test.Fixture

  @moduletag :tmp_dir

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "dry run has no writes; invalid names and options do not become paths", c do
    File.cd!(c.tmp_dir, fn ->
      output = capture_io(fn -> Generate.run(["Example.Hello", "--dry-run"]) end)
      assert output =~ "would create lib/example/hello/router.ex"
      assert output =~ "would create lib/example/hello/prompts/hello.txt.eex"
      assert File.ls!() == []

      for args <- [
            [],
            ["../Escape"],
            ["foo.bar"],
            ["Elixir.Example"],
            ["Bad;Code"],
            ["One", "Two"]
          ] do
        assert_raise Mix.Error, fn -> Generate.run(args) end
      end

      assert_raise OptionParser.ParseError, fn -> Generate.run(["Example.Hello", "--force"]) end
      assert File.ls!() == []
    end)
  end

  test "collision preflight protects every target, even a dangling symlink", c do
    File.cd!(c.tmp_dir, fn ->
      File.mkdir_p!("test/example")
      File.write!("test/example/hello_test.exs", "developer's existing test")
      assert_raise Mix.Error, ~r/refusing to overwrite/, fn -> Generate.run(["Example.Hello"]) end
      refute File.exists?("lib")
      assert File.read!("test/example/hello_test.exs") == "developer's existing test"

      File.mkdir_p!("lib/example/other/prompts")
      File.ln_s!("missing-target", "lib/example/other/prompts/hello.txt.eex")
      assert_raise Mix.Error, ~r/refusing to overwrite/, fn -> Generate.run(["Example.Other"]) end
      refute File.exists?("lib/example/other/router.ex")
    end)
  end

  test "the generated files compile and their own tests run in a fresh VM without Spectre startup",
       c do
    spectre_ebin = Path.expand(Mix.Project.compile_path())

    File.cd!(c.tmp_dir, fn ->
      capture_io(fn -> Generate.run(["Scaffold.Hello"]) end)

      script = """
      ExUnit.start(autorun: false)
      Code.compile_file("lib/scaffold/hello/router.ex")
      Code.compile_file("lib/scaffold/hello.ex")
      Code.require_file("test/scaffold/hello_test.exs")
      result = ExUnit.run()
      unless Process.whereis(Spectre.Domain.Registry) == nil, do: raise("Domain startup is not offline")
      System.halt(if result.failures == 0 and result.total == 2, do: 0, else: 1)
      """

      {output, status} =
        System.cmd("elixir", ["-pa", spectre_ebin, "-e", script],
          stderr_to_stdout: true,
          env: [{"ERL_FLAGS", "+S 2:2"}]
        )

      assert status == 0, output
      assert output =~ "2"

      for file <- Path.wildcard("{lib,test}/**/*.{ex,exs}") do
        text = File.read!(file)
        assert text == IO.iodata_to_binary(Code.format_string!(text)) <> "\n"
      end
    end)
  end

  test "generated greeting runs through a real authenticated Instance without granting effects",
       c do
    File.cd!(c.tmp_dir, fn ->
      capture_io(fn -> Generate.run(["Scaffold.LiveHello"]) end)

      modules =
        Code.compile_file("lib/scaffold/live_hello/router.ex") ++
          Code.compile_file("lib/scaffold/live_hello.ex")

      on_exit(fn ->
        for {module, _} <- modules do
          :code.purge(module)
          :code.delete(module)
        end
      end)

      {agent, _} = List.last(modules)
      definition = agent.definition(revision: 1, declared_at: Fixture.default_now())
      {fixture, binding} = DocumentationRuntime.activate(definition)

      {:ok, instance} =
        agent.start_link(scope: binding[:scope], definition: definition, state: %{})

      on_exit(fn -> Fixture.stop_process(instance) end)
      before = Sequencer.projection(fixture.server)
      assert {:ok, %{requests: []}} = agent.turn(instance, "hello Ada", flow: :greetings)
      assert Spectre.Instance.state(instance).value.draft == "Hello, Ada!"
      after_turn = Sequencer.projection(fixture.server)
      assert after_turn.acts == before.acts
      assert after_turn.attempts == before.attempts
      assert map_size(after_turn.evidence) > map_size(before.evidence)
      refute_received {:handler_execution, _, _, _}

      assert {:error, :unrecognized_message} =
               agent.turn(instance, "refund order 42", flow: :greetings)
    end)
  end
end
