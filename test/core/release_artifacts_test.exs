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

  test "CI references existing scripts, tests and lockfile inputs" do
    workflow = File.read!(Path.join(@root, ".github/workflows/ci.yml"))

    paths = Regex.scan(~r/\b(?:test|bench|scripts)\/[^\s"']+\.exs\b/, workflow)

    assert ["bench/suite.exs"] in paths
    assert ["scripts/check_package.exs"] in paths
    assert ["scripts/check_optional_runtime.exs"] in paths
    assert ["scripts/check_documentation_links.exs"] in paths

    for [path] <- paths do
      assert File.regular?(Path.join(@root, path)), "missing CI entry point: #{path}"
    end

    for [_, arguments] <- Regex.scan(~r/hashFiles\(([^)]+)\)/, workflow),
        [_, pattern] <- Regex.scan(~r/'([^']+)'/, arguments) do
      assert Path.wildcard(Path.join(@root, pattern)) != [], "empty CI cache input: #{pattern}"
    end

    refute workflow =~ "mix.real_embeddings.lock"
    refute workflow =~ "repository: elchemista/ex_fastembed"
    assert workflow =~ "MIX_ENV: prod"
  end

  test "guide links with fragments point to existing Markdown sections" do
    for source <- Mix.Project.config()[:docs][:extras] do
      markdown = File.read!(Path.join(@root, source))

      for [_, target] <- Regex.scan(~r/\[[^\]]*\]\(([^)]+)\)/, markdown),
          not String.starts_with?(target, ["https://", "http://"]),
          [file, anchor] <- [String.split(target, "#", parts: 2)],
          anchor != "" do
        path =
          if file == "",
            do: Path.join(@root, source),
            else: Path.expand(file, Path.dirname(Path.join(@root, source)))

        assert URI.decode(anchor) in heading_ids(File.read!(path)),
               "#{source} links to a missing section: #{target}"
      end
    end
  end

  test "complete example publishes Skills and reusable Worker/Vigil without startup" do
    modules = Code.compile_file(Path.join(@root, "examples/authoring.exs"))

    on_exit(fn ->
      for {module, _} <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    # These modules exist only after the example is compiled above. Resolve
    # from that result instead of statically calling an unavailable module.
    compiled = Map.new(modules, fn {module, _bytecode} -> {inspect(module), module} end)
    publication = Map.fetch!(compiled, "Spectre.Example.Publication")
    definitions = publication.definitions(0)

    assert {:ok, _, children} =
             Spectre.Agent.verify_definition(Spectre.Example.Support, definitions.agent)

    faq = Map.fetch!(compiled, "Spectre.Example.Faq")
    assert children["faq"] == faq.definition(revision: 1, declared_at: 0)

    assert {:ok, _, _} =
             Spectre.Agent.verify_definition(Spectre.Example.OrderWorker, definitions.worker)

    assert {:ok, _, _} =
             Spectre.Agent.verify_definition(Spectre.Example.QueueVigil, definitions.vigil)
  end

  @tag :tmp_dir
  test "rendered-link check catches missing source files and fragments", %{tmp_dir: directory} do
    source = Path.join(directory, "index.html")
    target = Path.join(directory, "example.html")
    File.write!(target, ~s(<section id="known"></section>))
    File.write!(source, ~s(<a href="example.html#known">Example</a>))
    script = Path.join(@root, "scripts/check_documentation_links.exs")
    elixir = System.find_executable("elixir")
    assert {_, 0} = System.cmd(elixir, [script, directory], stderr_to_stdout: true)

    for href <- ["example.html#absent", "examples/authoring.exs"] do
      File.write!(source, ~s(<a href="#{href}">Broken example</a>))
      assert {output, 1} = System.cmd(elixir, [script, directory], stderr_to_stdout: true)
      assert output =~ "index.html -> #{href}"
    end
  end

  # Published guides use ordinary ATX headings. Ignore headings inside examples;
  # the resulting IDs follow GitHub's punctuation-removal rule, not URL guesses.
  defp heading_ids(markdown) do
    prose = Regex.replace(~r/^```[^\n]*\n.*?^```\s*$/ms, markdown, "")

    for [_, heading] <- Regex.scan(~r/^\#{1,6}\s+(.+?)\s*\#*$/m, prose) do
      heading
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}_\-\s]/u, "")
      |> String.replace(" ", "-")
    end
  end
end
