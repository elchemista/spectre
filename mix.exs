defmodule Spectre.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/elchemista/spectre"
  @homepage_url "https://spectre.elchemista.com"
  @guides ~w(docs/architecture.md docs/host-setup.md docs/agents-and-dsl.md
             docs/integration-and-streaming.md docs/storage-and-recovery.md
             docs/capabilities.md docs/testing-and-release.md)

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
      dialyzer: [plt_add_apps: [:mix]],
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
      {:vettore, "~> 0.3.5"},
      {:benchee, "~> 1.5", only: :dev, runtime: false},
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
      files: ~w(lib mix.exs README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md LICENSE
           GOVERNED_ACT_MODEL.md GOVERNED_SURFACE.md) ++ @guides,
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
      extras:
        ["README.md"] ++
          @guides ++
          [
            "GOVERNED_ACT_MODEL.md",
            "GOVERNED_SURFACE.md",
            "CHANGELOG.md",
            "SECURITY.md",
            "CONTRIBUTING.md"
          ],
      groups_for_extras: [
        Guides: ~r/^docs\//,
        "Model and trust": ["GOVERNED_ACT_MODEL.md", "GOVERNED_SURFACE.md"]
      ],
      groups_for_modules: [
        "Application API": [
          Spectre,
          Spectre.Domain,
          Spectre.Scope,
          Spectre.Instance,
          Spectre.Foundation,
          Spectre.Error
        ],
        "Authoring and integration":
          ~r/^Spectre\.(Agent|Skill|Definition|Extension|Morph|Mind|Prompt|Router|Input|Ingress|Proposal|Fallback)(\.|$)/,
        "GAM records": [
          Spectre.Act,
          Spectre.Attempt,
          Spectre.Candidate,
          Spectre.Condition,
          Spectre.Constitution,
          Spectre.Consent,
          Spectre.Decision,
          Spectre.Declassification,
          Spectre.Disclosure,
          Spectre.Duty,
          Spectre.Erasure,
          Spectre.Evidence,
          Spectre.Genesis,
          Spectre.HostProfile,
          Spectre.Label,
          Spectre.Mandate,
          Spectre.Outcome,
          Spectre.Presentation,
          Spectre.Principal,
          Spectre.Row,
          Spectre.SubmissionContext,
          Spectre.Surface
        ],
        "Admission and authority":
          ~r/^Spectre\.(Kernel|Mandate|Authority|Consequence|Governance)(\.|$)/,
        "Pure semantics and indexes":
          ~r/^Spectre\.(GovernedAct|Duty|Erasure|Presentation|Evidence|Outcome)(\.|$)/,
        "Execution boundary": ~r/^Spectre\.(Attempt|Execution|Secret)(\.|$)/,
        "Persistence and audit": ~r/^Spectre\.(Ledger|Store|Payload|Audit|Canonical)(\.|$)/,
        "Runtime and support": ~r/^Spectre\./
      ]
    ]
  end
end
