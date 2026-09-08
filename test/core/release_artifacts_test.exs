defmodule Spectre.CoreTest.ReleaseArtifactsTest do
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @guide_modules [
    Guide.OrderSkill,
    Guide.SupportAgent,
    Guide.BinaryMatcher,
    Guide.RejectEmpty,
    Guide.StatefulMind,
    Guide.FlowAgent,
    Guide.VerifiedAgent
  ]

  test "package and HexDocs declarations reference files present in this checkout" do
    project = Mix.Project.config()
    package_files = project[:package][:files]
    extras = project[:docs][:extras]

    assert "GOVERNED_SURFACE.md" in package_files
    assert "GOVERNED_SURFACE.md" in extras

    for path <- package_files do
      assert File.exists?(Path.join(@root, path)), "missing package entry: #{path}"
    end

    for path <- extras do
      assert path in package_files, "HexDocs extra absent from package: #{path}"
      assert File.regular?(Path.join(@root, path)), "missing HexDocs extra: #{path}"
    end
  end

  test "current release guides do not link to deleted local documentation" do
    package_files = Mix.Project.config()[:package][:files]

    for source <- Mix.Project.config()[:docs][:extras] do
      links = Regex.scan(~r/\[[^\]]*\]\(([^)]+)\)/, File.read!(Path.join(@root, source)))

      for [_match, target] <- links,
          not String.starts_with?(target, ["https://", "http://", "#"]) do
        path =
          target
          |> String.split("#", parts: 2)
          |> hd()
          |> Path.expand(Path.dirname(Path.join(@root, source)))
          |> Path.relative_to(@root)

        assert path in package_files, "#{source} links outside package: #{path}"
        assert File.regular?(Path.join(@root, path)), "#{source} has a broken link: #{target}"
      end
    end
  end

  test "published self-contained guide examples execute against the current public API" do
    on_exit(fn ->
      for module <- @guide_modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    examples =
      for source <- Mix.Project.config()[:docs][:extras],
          [_match, name, code] <-
            Regex.scan(
              ~r/<!-- spectre:example (\w+) -->\n```elixir\n(.*?)\n```/s,
              File.read!(Path.join(@root, source))
            ) do
        Code.eval_string(code, [], file: source)
        name
      end

    assert Enum.sort(examples) ===
             ~w(application_store input_pipeline)
  end

  test "README handler declaration compiles with explicit publication metadata" do
    snippet =
      ~r/```elixir\n(.*?)```/s
      |> Regex.scan(File.read!(Path.join(@root, "README.md")))
      |> Enum.map(fn [_match, code] -> code end)
      |> Enum.find(&String.contains?(&1, "use Spectre.Agent"))

    assert is_binary(snippet)
    {_result, binding} = Code.eval_string(snippet, [published_at: 0], file: "README.md")

    on_exit(fn ->
      :code.purge(MyApp.Orders)
      :code.delete(MyApp.Orders)
    end)

    definition = Keyword.fetch!(binding, :definition)
    assert {:ok, _, _} = Spectre.Agent.verify_definition(MyApp.Orders, definition)
  end

  test "complete example publishes Skills and reusable Worker/Vigil without startup" do
    modules = Code.compile_file(Path.join(@root, "examples/authoring.exs"))

    on_exit(fn ->
      for {module, _} <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    definitions = Spectre.Example.Publication.definitions(0)

    assert {:ok, _, children} =
             Spectre.Agent.verify_definition(Spectre.Example.Support, definitions.agent)

    assert children["faq"] == Spectre.Example.Faq.definition(revision: 1, declared_at: 0)

    assert {:ok, _, _} =
             Spectre.Agent.verify_definition(Spectre.Example.OrderWorker, definitions.worker)

    assert {:ok, _, _} =
             Spectre.Agent.verify_definition(Spectre.Example.QueueVigil, definitions.vigil)
  end
end
