defmodule Spectre.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elchemista/spectre"
  @docs_extras [
    "README.md",
    "docs/GETTING_STARTED.md",
    "docs/DSL.md",
    "docs/ROUTING.md",
    "docs/TRAINING.md",
    "docs/ACTIONS.md",
    "docs/MEMORY.md",
    "docs/JOURNAL.md",
    "docs/API.md",
    "docs/INSTALLATION.md",
    "docs/ROADMAP.md"
  ]

  def project do
    [
      app: :spectre,
      name: "Spectre",
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      docs: [
        main: "readme",
        extras: @docs_extras
      ],
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      mod: {Spectre.Application, []},
      extra_applications: [:logger, :eex, :crypto]
    ]
  end

  defp description do
    "OTP-native conversational runtime for Elixir agents."
  end

  defp package do
    [
      name: "spectre",
      maintainers: ["elchemista"],
      files: ~w(lib docs mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:vettore, "~> 0.3.1"},
      {:ex_fastembed, github: "elchemista/ex_fastembed", branch: "master", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
