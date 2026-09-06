defmodule Spectre.CoreTest.ReleaseArtifactsTest do
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)

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

    for source <- ~w(README.md GOVERNED_SURFACE.md SECURITY.md) do
      links = Regex.scan(~r/\[[^\]]*\]\(([^)]+)\)/, File.read!(Path.join(@root, source)))

      for [_match, target] <- links,
          not String.starts_with?(target, ["https://", "http://", "#"]) do
        path = target |> String.split("#", parts: 2) |> hd()
        assert path in package_files, "#{source} links outside package: #{path}"
        assert File.regular?(Path.join(@root, path)), "#{source} has a broken link: #{target}"
      end
    end
  end

  test "the actual README Agent and Skill example compiles into pinned declarations" do
    snippet =
      ~r/```elixir\n(.*?)```/s
      |> Regex.scan(File.read!(Path.join(@root, "README.md")))
      |> Enum.map(fn [_match, code] -> code end)
      |> Enum.find(&String.contains?(&1, "use Spectre.Skill"))

    assert is_binary(snippet), "README must contain its Agent/Skill example"
    modules = Code.compile_string(snippet, "README.md")

    on_exit(fn ->
      for {module, _binary} <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    definitions =
      Map.new(modules, fn {module, _binary} -> {module, module.definition()} end)

    agent = Map.fetch!(definitions, MyApp.SupportAgent)
    skill = Map.fetch!(definitions, MyApp.LookupSkill)
    assert {:ok, ^agent} = Spectre.Definition.new(agent)
    assert agent.body["components"] === %{"lookup" => skill.ref}
    assert agent.body["candidates"] === %{"lookup/order" => skill.body["candidates"]["order"]}
  end
end
