defmodule Spectre.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elchemista/spectre"
  @docs_extras [
    "README.md",
    "CHANGELOG.md",
    "docs/GETTING_STARTED.md",
    "docs/ARCHITECTURE.md",
    "docs/INTEGRATIONS.md",
    "docs/DSL.md",
    "docs/SKILLS.md",
    "docs/ROUTING.md",
    "docs/EVALUATION.md",
    "docs/PROVIDERS.md",
    "docs/TRAINING.md",
    "docs/ACTIONS.md",
    "docs/MEMORY.md",
    "docs/JOURNAL.md",
    "docs/PRODUCTION.md",
    "docs/TESTING.md",
    "docs/API.md",
    "docs/INSTALLATION.md",
    "docs/ROADMAP.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "LICENSE"
  ]

  def project do
    [
      app: :spectre,
      name: "Spectre",
      version: @version,
      lockfile: lockfile(),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      docs: docs(),
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
      files: ~w(lib docs mix.exs README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:vettore, "~> 0.3.2"},
      {:spectre_kinetic,
       github: "elchemista/spectre_kinetic",
       branch: "agent/generic-action-separation",
       only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ] ++ real_embedding_test_deps()
  end

  defp real_embedding_test_deps do
    case real_embedding_test_path() do
      path when is_binary(path) ->
        [{:ex_fastembed, path: Path.expand(path), only: :test, runtime: false}]

      _other ->
        []
    end
  end

  defp lockfile do
    if real_embedding_test_path(),
      do: "mix.real_embeddings.lock",
      else: "mix.lock"
  end

  defp real_embedding_test_path do
    case {Mix.env(), System.get_env("SPECTRE_EX_FASTEMBED_PATH")} do
      {:test, path} when is_binary(path) and path != "" -> path
      _other -> nil
    end
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: @docs_extras,
      groups_for_extras: [
        "Start here": [
          "README.md",
          "docs/GETTING_STARTED.md",
          "docs/INSTALLATION.md"
        ],
        "Core concepts": [
          "docs/ARCHITECTURE.md",
          "docs/INTEGRATIONS.md",
          "docs/DSL.md",
          "docs/SKILLS.md",
          "docs/API.md"
        ],
        "Runtime guides": [
          "docs/ROUTING.md",
          "docs/ACTIONS.md",
          "docs/MEMORY.md",
          "docs/JOURNAL.md",
          "docs/PROVIDERS.md",
          "docs/TRAINING.md",
          "docs/EVALUATION.md"
        ],
        Operations: [
          "docs/PRODUCTION.md",
          "docs/TESTING.md",
          "SECURITY.md"
        ],
        Project: [
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "docs/ROADMAP.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          Spectre,
          Spectre.Agent,
          Spectre.Turn.Handler,
          Spectre.Turn.Handler.Request,
          Spectre.Turn.Handler.Reply,
          Spectre.Skill,
          Spectre.Turn,
          Spectre.Session,
          Spectre.Supervisor
        ],
        "Lifecycle and state": [
          Spectre.Lifecycle,
          Spectre.Transition,
          Spectre.State,
          Spectre.State.Codec,
          Spectre.State.Store,
          Spectre.Result,
          Spectre.Effect,
          Spectre.Awaitable,
          Spectre.Policy,
          Spectre.Policy.Matcher,
          Spectre.Policy.Resolution
        ],
        Routing: [
          Spectre.Router,
          Spectre.Router.Arbitration,
          Spectre.Router.Arbitrator,
          Spectre.Router.Candidate,
          Spectre.Router.Context,
          Spectre.Router.Receipt,
          Spectre.Router.SemanticCache
        ],
        "Prompts and providers": [
          Spectre.LLM,
          Spectre.Prompt,
          Spectre.Prompt.Fragment,
          Spectre.Prompt.Operation,
          Spectre.Prompt.Plan,
          Spectre.Provider.Call,
          Spectre.Provider.Failure
        ],
        Actions: [
          Spectre.Action,
          Spectre.Action.Spec,
          Spectre.Action.Provider,
          Spectre.Action.Provider.Local,
          Spectre.Action.Planner,
          Spectre.ActionConfig,
          Spectre.ActionDispatcher,
          Spectre.ActionExecutor,
          Spectre.ActionHooks,
          Spectre.ActionPlanner,
          Spectre.ActionProtection,
          Spectre.Execution
        ],
        Extensions: [
          Spectre.Extension
        ],
        "Classifiers and evaluation": [
          Spectre.Classifier,
          Spectre.Classifier.Embedding,
          Spectre.Classifier.Encoder,
          Spectre.Classifier.Trainer,
          Spectre.Eval,
          Spectre.Eval.Case,
          Spectre.Eval.Report,
          Spectre.Eval.Result,
          Spectre.Training.Dataset
        ],
        "Journal and operations": [
          Spectre.Journal.Record,
          Spectre.Journal.Recorder,
          Spectre.Journal.Store,
          Spectre.Monitor,
          Spectre.Telemetry
        ]
      ]
    ]
  end
end
