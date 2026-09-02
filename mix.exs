defmodule Spectre.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/elchemista/spectre"
  @homepage_url "https://spectre.elchemista.com"

  def project do
    [
      app: :spectre,
      name: "Spectre",
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_ignore_filters: [&String.contains?(&1, "/support/")],
      test_coverage: [summary: [threshold: 95]],
      description: "A durable governed-act kernel for Elixir.",
      package: package(),
      dialyzer: [plt_add_apps: [:mix], flags: [:no_opaque]],
      docs: docs(),
      source_url: @source_url,
      homepage_url: @homepage_url
    ]
  end

  def application do
    [
      mod: {Spectre.Application, []},
      extra_applications: [:logger, :crypto, :mnesia]
    ]
  end

  defp deps do
    [
      {:uuid_v7, "~> 0.6.0"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      name: "spectre",
      maintainers: ["elchemista"],
      files: ~w(lib mix.exs README.md CHANGELOG.md SECURITY.md LICENSE
           GOVERNED_ACT_MODEL.md GOVERNED_SURFACE.md),
      licenses: ["Apache-2.0"],
      links: %{
        "Website" => @homepage_url,
        "Documentation" => "https://hexdocs.pm/spectre/#{@version}",
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "GOVERNED_ACT_MODEL.md",
        "GOVERNED_SURFACE.md",
        "CHANGELOG.md",
        "SECURITY.md"
      ]
    ]
  end
end
