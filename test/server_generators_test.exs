defmodule Spectre.ServerGeneratorsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "server generator preflights three files and produces a working OTP application", %{
    tmp_dir: dir
  } do
    module = "Spectre.ServerGeneratorsTest.Demo#{System.unique_integer([:positive])}Agent"
    server = String.replace_suffix(module, "Agent", "Server")

    plan =
      capture_io(fn ->
        File.cd!(dir, fn ->
          assert :ok = Mix.Tasks.Spectre.Gen.Agent.run([module, "--server", "--dry-run"])
        end)
      end)

    assert length(String.split(plan, "would create")) == 4
    assert File.ls!(dir) == []

    capture_io(fn ->
      File.cd!(dir, fn -> assert :ok = Mix.Tasks.Spectre.Gen.Agent.run([module, "--server"]) end)
    end)

    sources = Path.wildcard(Path.join(dir, "lib/**/*.ex"))
    assert length(sources) == 2
    Enum.each(sources, &Code.compile_file/1)
    [test] = Path.wildcard(Path.join(dir, "test/**/*_test.exs"))
    assert {:ok, _ast} = test |> File.read!() |> Code.string_to_quoted()
    agent = Module.concat(String.split(module, "."))
    server_module = Module.concat(String.split(server, "."))
    assert agent.__spectre_server__() == server_module
    pid = start_supervised!({Spectre.Server, agent: agent, consumer: self()})
    assert {:ok, interaction} = Spectre.Server.input(pid, "hello")
    assert_receive {Spectre.Server, ^pid, {:response, ^interaction, "Hello!", []}}, 1_000

    human = capture_io(fn -> assert :ok = Mix.Tasks.Spectre.Routes.run([module]) end)
    assert human =~ "#{server}"
    assert human =~ "support greeting → handle_flow/3"

    json = capture_io(fn -> assert :ok = Mix.Tasks.Spectre.Routes.run([module, "--json"]) end)

    assert {:ok, [%{"intent" => "greeting", "flow_path" => ["support"], "server" => ^server}]} =
             Spectre.JSON.decode(json)

    original = Map.new(sources, &{&1, File.read!(&1)})

    assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
      capture_io(fn ->
        File.cd!(dir, fn -> Mix.Tasks.Spectre.Gen.Agent.run([module, "--server"]) end)
      end)
    end

    assert Map.new(sources, &{&1, File.read!(&1)}) == original
  end

  @tag :tmp_dir
  test "intent export preserves vectors and requires explicit unverified inclusion", %{
    tmp_dir: dir
  } do
    module = Module.concat(__MODULE__, "Dataset#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Spectre.Agent, server: MyApp.Server
      flow :support do
        on :pricing
      end
    end
    """)

    opts = [include_static_examples: false, include_training_examples: false]
    on_exit(fn -> Spectre.IntentDataset.clear(module, opts) end)

    assert {:ok, %{loaded: 2}} =
             Spectre.IntentDataset.load_snapshot(
               module,
               [
                 %{text: "verified price", label: :pricing, verified: true},
                 %{text: "collected price", label: :pricing, verified: false}
               ],
               opts
             )

    path = Path.join(dir, "verified.jsonl")

    capture_io(fn ->
      assert :ok = Mix.Tasks.Spectre.IntentDataset.Export.run([inspect(module), path])
    end)

    assert [%{"text" => "verified price", "embedding" => nil}] =
             path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Spectre.JSON.decode!/1)

    capture_io(fn ->
      assert :ok =
               Mix.Tasks.Spectre.IntentDataset.Export.run([
                 inspect(module),
                 path,
                 "--include-unverified"
               ])
    end)

    assert length(path |> File.read!() |> String.split("\n", trim: true)) == 2
  end
end
