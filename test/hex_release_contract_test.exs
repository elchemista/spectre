defmodule SpectreHexReleaseContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @release "0.3.3"
  @workflow Path.join(@root, ".github/workflows/ci.yml")
  @satellite_apps ~w(
    spectre_history
    spectre_mnemonic
    spectre_pulse
    spectre_beam
    spectre_directive
    spectre_ledger
    spectre_lab
    spectre_kinetic
    spectre_prism
    spectre_lens
    spectre_ecosystem
  )a
  @satellite_components ~w(
    History
    Mnemonic
    Pulse
    Beam
    Directive
    Ledger
    Lab
    Kinetic
    Prism
    Lens
    Ecosystem
  )a
  @generator_templates ~w(
    priv/templates/spectre.gen.agent/agent.ex.eex
    priv/templates/spectre.gen.agent/agent_test.exs.eex
    priv/templates/spectre.gen.checkpoint_store/checkpoint_store.ex.eex
    priv/templates/spectre.gen.checkpoint_store/checkpoint_store_test.exs.eex
    priv/templates/spectre.gen.installable/installable.ex.eex
    priv/templates/spectre.gen.installable/installable_test.exs.eex
  )
  @public_package_assets ~w(
    docs/examples/routing-eval.jsonl
  )
  @excluded_package_paths ~w(
    docs/adr
    lib/spectre/instance/README.md
    test
    scripts
    .github
  )
  @v030_fixture_digests %{
    "test/fixtures/compatibility/0.3.0/instance-v2.json" =>
      "3453904230c641c12a5b099a8448454642bdf8729c29f9914d60142977268375",
    "test/fixtures/compatibility/0.3.0/instance-v2-advanced.json" =>
      "df82780db44d93011f3064e0132263396c6a1e2c1481d08e4419fc9cfe68bfe9",
    "test/fixtures/compatibility/0.3.0/reflective-runtime-v1.json" =>
      "d7d7d505b3a86696ab211bf64e61f5c6bf94e54e2bc7e3c989325b499ac34e9a"
  }
  @documentation_files [
                         "README.md",
                         "LLMS.md",
                         "SYSTEM.md",
                         "CHANGELOG.md",
                         "CONTRIBUTING.md",
                         "SECURITY.md"
                       ] ++ Path.wildcard("docs/*.md", match_dot: true)

  test "Hex package metadata describes the stable 0.3.3 release" do
    config = Mix.Project.config()
    package = Keyword.fetch!(config, :package)
    docs = Keyword.fetch!(config, :docs)

    assert config[:app] == :spectre
    assert config[:version] == @release
    assert config[:elixir] == "~> 1.19"
    assert Spectre.version() == @release
    assert Application.spec(:spectre, :vsn) |> to_string() == @release
    assert config[:homepage_url] == "https://spectre.elchemista.com"
    assert docs[:source_ref] == @release
    assert package[:licenses] == ["Apache-2.0"]
    assert "LLMS.md" in package[:files]
    assert "priv" in package[:files]
    assert "lib/**/*.ex" in package[:files]
    refute "lib" in package[:files]
    refute "docs" in package[:files]

    assert MapSet.subset?(MapSet.new(docs[:extras]), MapSet.new(package[:files]))

    for asset <- @public_package_assets do
      assert asset in package[:files]
    end

    assert package[:links] == %{
             "Website" => "https://spectre.elchemista.com",
             "Documentation" => "https://hexdocs.pm/spectre/#{@release}",
             "GitHub" => "https://github.com/elchemista/spectre",
             "Changelog" => "https://github.com/elchemista/spectre/blob/#{@release}/CHANGELOG.md"
           }

    assert {:ex_doc, "~> 0.40.3", ex_doc_opts} =
             Enum.find(config[:deps], &match?({:ex_doc, _, _}, &1))

    assert ex_doc_opts[:only] == :dev
    assert ex_doc_opts[:runtime] == false

    assert {:vettore, "~> 0.3.3"} =
             Enum.find(config[:deps], &match?({:vettore, _requirement}, &1))
  end

  test "the source package owns every executable generator contract" do
    packaged_templates =
      @root
      |> Path.join("priv/templates/**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.sort()

    assert packaged_templates == Enum.sort(@generator_templates)

    for template <- @generator_templates do
      assert File.stat!(Path.join(@root, template)).size > 0
    end
  end

  test "release CI covers the supported BEAM matrix and can never publish" do
    workflow = File.read!(@workflow)

    assert workflow =~
             ~r/elixir: "1\.19\.x"\s+otp: "28\.x"\s+test_args: ""/u

    assert workflow =~
             ~r/elixir: "1\.20\.x"\s+otp: "29\.x"\s+test_args: "--cover"/u

    assert workflow =~ "mix compile --warnings-as-errors"
    assert workflow =~ "mix docs --warnings-as-errors"
    assert workflow =~ "MIX_BUILD_PATH: _build/quality"
    assert workflow =~ ~s(mix hex.build --unpack --output "$RUNNER_TEMP/hex-package")

    for template <- @generator_templates do
      assert workflow =~ ~s(test -f "$RUNNER_TEMP/hex-package/#{template}")
    end

    for asset <- @public_package_assets do
      assert workflow =~ ~s(test -f "$RUNNER_TEMP/hex-package/#{asset}")
    end

    for excluded <- @excluded_package_paths do
      assert workflow =~ ~s(test ! -e "$RUNNER_TEMP/hex-package/#{excluded}")
    end

    workflow_sources =
      [".github/workflows/*.yml", ".github/workflows/*.yaml"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.map_join("\n", &File.read!/1)

    refute workflow_sources =~ "HEX_API_KEY"
    refute workflow_sources =~ ~r/\bmix\s+hex\.publish\b/u
  end

  test "0.3.0 compatibility fixtures remain byte-for-byte immutable" do
    for {relative_path, expected_digest} <- @v030_fixture_digests do
      fixture = File.read!(Path.join(@root, relative_path))

      assert Base.encode16(:crypto.hash(:sha256, fixture), case: :lower) == expected_digest,
             "#{relative_path} no longer matches its frozen 0.3.0 release bytes"
    end
  end

  test "the core has no satellite dependency or implementation coupling" do
    dependency_apps =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.map(&elem(&1, 0))

    satellite_dependencies = Enum.filter(dependency_apps, &(&1 in @satellite_apps))

    assert satellite_dependencies == []

    for source_path <- Path.wildcard(Path.join(@root, "lib/**/*.ex")) do
      source = File.read!(source_path)

      assert forbidden_satellite_aliases(source) == [],
             "#{Path.relative_to(source_path, @root)} couples core code to a satellite module"
    end

    refute File.read!(Path.join(@root, "CHANGELOG.md")) =~ ~r/^## 0\.4\.0\b/mu
  end

  defp forbidden_satellite_aliases(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:__aliases__, _metadata, [:Spectre, component | _rest]} = node, acc
      when component in @satellite_components ->
        {node, [component | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
    |> Enum.sort()
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
    changelog = File.read!(Path.join(@root, "CHANGELOG.md"))

    assert readme =~ ~s({:spectre, "~> 0.3.3"})
    assert installation =~ ~s({:spectre, "~> 0.3.3"})
    assert llm_guide =~ ~s({:spectre, "~> 0.3.3"})
    assert changelog =~ "## 0.3.3 — 2026-08-23"
    assert installation =~ ~s({:spectre, github: "elchemista/spectre", ref: "COMMIT_SHA"})

    refute readme =~ ~r/{:spectre,\s+github:.*tag:/
    refute installation =~ ~r/{:spectre,\s+github:.*tag:/
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
