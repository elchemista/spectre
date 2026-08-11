defmodule SpectreHexReleaseContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @documentation_files [
                         "README.md",
                         "LLMS.md",
                         "SYSTEM.md",
                         "CHANGELOG.md",
                         "CONTRIBUTING.md",
                         "SECURITY.md"
                       ] ++ Path.wildcard("docs/*.md", match_dot: true)

  test "Hex package metadata describes the stable 0.3.0 release" do
    config = Mix.Project.config()
    package = Keyword.fetch!(config, :package)

    assert config[:version] == "0.3.0"
    assert config[:homepage_url] == "https://spectre.elchemista.com"
    assert package[:licenses] == ["Apache-2.0"]
    assert "LLMS.md" in package[:files]

    assert package[:links] == %{
             "Website" => "https://spectre.elchemista.com",
             "Documentation" => "https://hexdocs.pm/spectre/0.3.0",
             "GitHub" => "https://github.com/elchemista/spectre",
             "Changelog" => "https://github.com/elchemista/spectre/blob/0.3.0/CHANGELOG.md"
           }

    assert {:ex_doc, "~> 0.40.3", ex_doc_opts} =
             Enum.find(config[:deps], &match?({:ex_doc, _, _}, &1))

    assert ex_doc_opts[:only] == :dev
    assert ex_doc_opts[:runtime] == false
  end

  test "all Markdown guides are part of ExDoc and every local link resolves" do
    extras = Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:extras)

    assert MapSet.subset?(
             MapSet.new(Path.wildcard("docs/*.md", match_dot: true)),
             MapSet.new(extras)
           )

    assert "LLMS.md" in extras

    for relative_file <- @documentation_files,
        target <- markdown_targets(relative_file),
        local_target?(target) do
      assert_local_target!(relative_file, target)
    end
  end

  test "current installation examples use Hex while snapshots require an exact ref" do
    readme = File.read!(Path.join(@root, "README.md"))
    installation = File.read!(Path.join(@root, "docs/INSTALLATION.md"))
    llm_guide = File.read!(Path.join(@root, "LLMS.md"))

    assert readme =~ ~s({:spectre, "~> 0.3.0"})
    assert installation =~ ~s({:spectre, "~> 0.3.0"})
    assert llm_guide =~ ~s({:spectre, "~> 0.3.0"})
    assert installation =~ ~s({:spectre, github: "elchemista/spectre", ref: "COMMIT_SHA"})

    refute readme =~ ~r/{:spectre,\s+github:.*tag:\s*"0\.3\.0"/
    refute installation =~ ~r/{:spectre,\s+github:.*tag:\s*"0\.3\.0"/
    refute Enum.any?(@documentation_files, &(File.read!(Path.join(@root, &1)) =~ "0.3.0-rs"))
  end

  @spec markdown_targets(String.t()) :: [String.t()]
  defp markdown_targets(relative_file) do
    relative_file
    |> then(&Path.join(@root, &1))
    |> File.read!()
    |> then(&Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/u, &1, capture: :all_but_first))
    |> List.flatten()
  end

  @spec local_target?(String.t()) :: boolean()
  defp local_target?(target) do
    not String.starts_with?(target, ["#", "http://", "https://", "mailto:"])
  end

  @spec assert_local_target!(String.t(), String.t()) :: true
  defp assert_local_target!(relative_file, target) do
    path =
      target
      |> String.split("#", parts: 2)
      |> hd()
      |> then(&Path.expand(&1, Path.dirname(Path.join(@root, relative_file))))

    assert File.exists?(path),
           "#{relative_file} links to missing local documentation target #{inspect(target)}"
  end
end
