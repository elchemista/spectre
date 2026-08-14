defmodule SpectreMixGeneratorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @generators [
    {Mix.Tasks.Spectre.Gen.Agent, "SpectreGenerated.Agent"},
    {Mix.Tasks.Spectre.Gen.Installable, "SpectreGenerated.Installable"},
    {Mix.Tasks.Spectre.Gen.CheckpointStore, "SpectreGenerated.CheckpointStore"}
  ]

  @tag :tmp_dir
  test "generators render deterministic code and executable public contract tests", %{
    tmp_dir: tmp
  } do
    Enum.each(@generators, fn {task, module} ->
      output = run_generator(tmp, task, [module])
      {source, test} = generated_paths(tmp, module)

      assert output =~ "create #{relative(source, tmp)}"
      assert output =~ "create #{relative(test, tmp)}"
      assert File.regular?(source)
      assert File.regular?(test)
      assert {:ok, _ast} = source |> File.read!() |> Code.string_to_quoted(file: source)
      assert {:ok, _ast} = test |> File.read!() |> Code.string_to_quoted(file: test)

      original = File.read!(source)
      output = run_generator(tmp, task, [module, "--force"])

      assert output =~ "overwrite #{relative(source, tmp)}"
      assert File.read!(source) == original
    end)

    assert_generated_tests_pass!(tmp)
  end

  @tag :tmp_dir
  test "default generation preflights every collision and force is explicit", %{tmp_dir: tmp} do
    module = "SpectreGenerated.PreflightAgent"
    {source, test} = generated_paths(tmp, module)
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "user-owned\n")

    assert_raise Mix.Error, ~r/refusing to overwrite existing files/, fn ->
      run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, [module])
    end

    assert File.read!(source) == "user-owned\n"
    refute File.exists?(test)

    output = run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, [module, "--force"])
    assert output =~ "overwrite #{relative(source, tmp)}"
    assert output =~ "create #{relative(test, tmp)}"
    refute File.read!(source) == "user-owned\n"
  end

  @tag :tmp_dir
  test "dry-run validates and reports a complete plan without writes", %{tmp_dir: tmp} do
    module = "SpectreGenerated.DryRunAgent"
    {source, test} = generated_paths(tmp, module)

    output = run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, [module, "--dry-run"])

    assert output =~ "would create #{relative(source, tmp)}"
    assert output =~ "would create #{relative(test, tmp)}"
    refute File.exists?(source)
    refute File.exists?(test)
  end

  @tag :tmp_dir
  test "module validation and parent checks keep destinations inside the project", %{
    tmp_dir: tmp
  } do
    for invalid <- ["../Outside", "lowercase.Agent", "Elixir.System", "MyApp.Bad-Name"] do
      assert_raise Mix.Error, ~r/invalid module name/, fn ->
        run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, [invalid])
      end
    end

    outside = Path.join(tmp, "outside")
    linked = Path.join([tmp, "lib", "spectre_generated"])
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.dirname(linked))
    File.ln_s!(outside, linked)

    assert_raise Mix.Error, ~r/generator parent is a symlink/, fn ->
      run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, ["SpectreGenerated.LinkedAgent"])
    end

    assert File.ls!(outside) == []
  end

  @tag :tmp_dir
  test "a dangling destination symlink is never followed or force-replaced", %{tmp_dir: tmp} do
    module = "SpectreGenerated.LinkedTargetAgent"
    {source, test} = generated_paths(tmp, module)
    outside = Path.join(tmp, "outside-agent.ex")

    File.mkdir_p!(Path.dirname(source))
    File.ln_s!(outside, source)

    assert_raise Mix.Error, ~r/refusing to overwrite existing files/, fn ->
      run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, [module])
    end

    assert_raise Mix.Error, ~r/--force only replaces regular files/, fn ->
      run_generator(tmp, Mix.Tasks.Spectre.Gen.Agent, [module, "--force"])
    end

    refute File.exists?(outside)
    refute File.exists?(test)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(source)
  end

  defp run_generator(root, task, argv) do
    capture_io(fn ->
      File.cd!(root, fn ->
        assert :ok = task.run(argv)
      end)
    end)
  end

  defp generated_paths(root, module) do
    module_path = module |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    {
      Path.join([root, "lib", module_path <> ".ex"]),
      Path.join([root, "test", module_path <> "_test.exs"])
    }
  end

  defp relative(path, root), do: Path.relative_to(path, root)

  defp assert_generated_tests_pass!(root) do
    files =
      @generators
      |> Enum.flat_map(fn {_task, module} -> Tuple.to_list(generated_paths(root, module)) end)
      |> Enum.map_join(", ", &inspect/1)

    expression = """
    ExUnit.start(autorun: false)
    Enum.each([#{files}], &Code.require_file/1)
    result = ExUnit.run()
    System.halt(if(result.failures == 0, do: 0, else: 1))
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", expression],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Result: 3 passed"
  end
end
