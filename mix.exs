defmodule Spectre.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/elchemista/spectre"
  @homepage_url "https://spectre.elchemista.com"
  @docs_extras [
    "README.md",
    "docs/START_HERE.md",
    "docs/INSTALLATION.md",
    "docs/GETTING_STARTED.md",
    "docs/ARCHITECTURE.md",
    "docs/AGENT_SERVER.md",
    "docs/GAM.md",
    "docs/MANAGED_GAM.md",
    "docs/STACK_TOOLS.md",
    "docs/SKILLS.md",
    "docs/DOMAIN_STORAGE.md",
    "docs/PAYLOAD_STORAGE.md",
    "docs/EXTERNAL_APPROVALS.md",
    "docs/ACTIONS.md",
    "docs/API.md",
    "docs/COMPATIBILITY.md",
    "docs/DEMO.md",
    "docs/DIAGNOSTICS.md",
    "docs/DSL.md",
    "docs/EVALUATION.md",
    "docs/EXAMPLES.md",
    "docs/INTEGRATIONS.md",
    "docs/MEMORY.md",
    "docs/MIGRATING_TO_0_4.md",
    "docs/OTP_PROFILE_0_4.md",
    "docs/PENDING_LIFECYCLE.md",
    "docs/PRODUCTION.md",
    "docs/PROVIDERS.md",
    "docs/PUBLIC_API.md",
    "docs/RELEASE_0_4.md",
    "docs/ROADMAP.md",
    "docs/ROUTING.md",
    "docs/BEHAVIOURS.md",
    "docs/SERVER_CONTRACTS.md",
    "docs/STACK.md",
    "docs/STREAMING_INFERENCE.md",
    "docs/TESTING.md",
    "docs/TRAINING.md",
    "SYSTEM.md",
    "LLMS.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CHANGELOG.md",
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
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [
        &String.contains?(&1, "/support/"),
        &String.ends_with?(&1, "/helper.exs")
      ],
      test_coverage: [summary: [threshold: 95]],
      description: description(),
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix],
        # The application is analyzed below, not cached as its own dependency.
        plt_ignore_apps: [:spectre],
        flags: [:no_opaque]
      ],
      docs: docs(),
      source_url: @source_url,
      homepage_url: @homepage_url
    ]
  end

  def application do
    [
      mod: {Spectre.Application, []},
      extra_applications: [:logger, :eex, :crypto, :mnesia]
    ]
  end

  defp description do
    "OTP-native conversational and operational runtime for Elixir agents."
  end

  defp package do
    [
      name: "spectre",
      maintainers: ["elchemista"],
      files:
        ~w(lib/**/*.ex priv docs/assets mix.exs .formatter.exs docs/examples/routing-eval.jsonl docs/examples/agent_server_quickstart.exs docs/examples/outreach_agent.exs docs/examples/external_approval.exs) ++
          @docs_extras,
      licenses: ["Apache-2.0"],
      links: %{
        "Website" => @homepage_url,
        "Documentation" => "#{@source_url}/blob/#{@version}/docs/START_HERE.md",
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/#{@version}/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      {:uuid_v7, "~> 0.6.0"},
      {:vettore, "~> 0.3.6"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: :test, runtime: false}
    ] ++ real_embedding_test_deps()
  end

  defp elixirc_paths(:test) do
    if System.get_env("SPECTRE_PERF_TESTS") in ["1", "true"] do
      ["lib", "test/support"]
    else
      ["lib"]
    end
  end

  defp elixirc_paths(_env), do: ["lib"]

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
      # README and guide image paths retain their GitHub-relative layout.
      assets: %{"docs/assets" => "docs/assets", "./docs/assets" => "assets"},
      main: "start_here",
      source_ref: @version,
      extras: @docs_extras,
      groups_for_extras: [
        "Start here": [
          "docs/START_HERE.md",
          "README.md",
          "docs/INSTALLATION.md",
          "docs/GETTING_STARTED.md",
          "docs/ARCHITECTURE.md",
          "SYSTEM.md"
        ],
        "Application development": [
          "docs/AGENT_SERVER.md",
          "docs/ROUTING.md",
          "docs/BEHAVIOURS.md",
          "docs/DSL.md",
          "docs/STACK.md",
          "docs/STACK_TOOLS.md",
          "docs/SKILLS.md",
          "docs/ACTIONS.md",
          "docs/PENDING_LIFECYCLE.md",
          "docs/MEMORY.md",
          "docs/STREAMING_INFERENCE.md",
          "docs/TRAINING.md",
          "docs/EVALUATION.md",
          "docs/INTEGRATIONS.md",
          "docs/EXAMPLES.md",
          "docs/DEMO.md"
        ],
        "Governance and persistence": [
          "docs/GAM.md",
          "docs/MANAGED_GAM.md",
          "docs/EXTERNAL_APPROVALS.md",
          "docs/DOMAIN_STORAGE.md",
          "docs/PAYLOAD_STORAGE.md"
        ],
        "Operations and verification": [
          "docs/PRODUCTION.md",
          "docs/PROVIDERS.md",
          "docs/DIAGNOSTICS.md",
          "docs/SERVER_CONTRACTS.md",
          "docs/TESTING.md",
          "docs/OTP_PROFILE_0_4.md",
          "docs/RELEASE_0_4.md"
        ],
        "Reference and migration": [
          "docs/API.md",
          "docs/PUBLIC_API.md",
          "docs/MIGRATING_TO_0_4.md",
          "docs/COMPATIBILITY.md",
          "LLMS.md"
        ],
        Project: [
          "CONTRIBUTING.md",
          "SECURITY.md",
          "CHANGELOG.md",
          "docs/ROADMAP.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        AgentServer: ~r/^Spectre\.Server(?:\.|$)/,
        "Governed Act Model": ~r/^Spectre\.GAM(?:\.|$)/,
        "Intent datasets": ~r/^Spectre\.IntentDataset(?:\.|$)/,
        "Canonical definitions and projections": [
          Spectre.Authority.Envelope,
          Spectre.Canonical.Value,
          Spectre.Definition.Candidate,
          Spectre.Definition.Candidate.Ref,
          Spectre.Definition.Canonical,
          Spectre.Definition.Component,
          Spectre.Definition.ContractRegistry,
          Spectre.Definition.Manifest,
          Spectre.Definition.Ref,
          Spectre.Definition.Resolver,
          Spectre.Definition.Store,
          Spectre.Definition.Store.Conformance,
          Spectre.Definition.Store.Memory,
          Spectre.Foundation.Conformance,
          Spectre.Execution.Closure,
          Spectre.Projection,
          Spectre.Projection.Audit,
          Spectre.Projection.Reflection
        ],
        "Core API": [
          Spectre,
          Spectre.Stack,
          Spectre.Stack.Conformance,
          Spectre.Agent,
          Spectre.Turn.Handler,
          Spectre.Turn.Handler.Request,
          Spectre.Turn.Handler.Reply,
          Spectre.Turn.Dispatcher,
          Spectre.Reply.Sanitizer,
          Spectre.Skill,
          Spectre.Turn,
          Spectre.Run,
          Spectre.Run.Ref,
          Spectre.Run.Boundary,
          Spectre.Run.Request,
          Spectre.Run.StartContinuation,
          Spectre.Run.InferenceContinuation,
          Spectre.Invocation,
          Spectre.Runtime,
          Spectre.AgentRef,
          Spectre.Subject,
          Spectre.ExternalIdentity,
          Spectre.LinkIntent,
          Spectre.SubjectLink,
          Spectre.Subject.Registry,
          Spectre.Event.Envelope,
          Spectre.Instance,
          Spectre.Instance.Activation,
          Spectre.Instance.Erasure.Proof,
          Spectre.Instance.Erasure.Request,
          Spectre.Instance.Erasure.Status,
          Spectre.Instance.Owner,
          Spectre.Instance.Owner.Conformance,
          Spectre.Instance.Owner.Lease,
          Spectre.Instance.Owner.Local,
          Spectre.Instance.Ref,
          Spectre.Instance.Registry,
          Spectre.Privacy,
          Spectre.Privacy.ErasurePlan,
          Spectre.Session,
          Spectre.Supervisor
        ],
        "Lifecycle and state": [
          Spectre.Instance.Lifecycle,
          Spectre.Skill.StateBinding,
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
        Governance: [
          Spectre.Morph,
          Spectre.Morph.Change,
          Spectre.Morph.DSL,
          Spectre.Morph.Surface,
          Spectre.Governance.ChangeSet,
          Spectre.Governance.ChangeSet.Operation,
          Spectre.Governance.ChangeSet.Handler,
          Spectre.Governance.ChangeSet.Registry,
          Spectre.Governance.Composition,
          Spectre.Governance.Composer,
          Spectre.Governance.CandidateState,
          Spectre.Gate.Receipt,
          Spectre.Gate.Receipt.Ref,
          Spectre.Governance.EvaluationDelta,
          Spectre.Governance.Review,
          Spectre.Governance.Approval,
          Spectre.Governance.Approval.Policy,
          Spectre.Projection.HumanReport,
          Spectre.Governance.GC,
          Spectre.Governance.GC.Plan
        ],
        "Reflection and Forge": [
          Spectre.Experience,
          Spectre.Experience.Evidence,
          Spectre.Experience.Evidence.Ref,
          Spectre.Experience.Redactor,
          Spectre.Experience.Store,
          Spectre.Experience.Store.Memory,
          Spectre.Reflection,
          Spectre.Reflection.Policy,
          Spectre.Reflection.Operation,
          Spectre.Forge,
          Spectre.Forge.Critic,
          Spectre.Forge.Critique,
          Spectre.Forge.OracleApproval,
          Spectre.Forge.Proposal
        ],
        Routing: [
          Spectre.Router,
          Spectre.Router.Adapter,
          Spectre.Router.Adapter.Conformance,
          Spectre.Router.Adapter.Request,
          Spectre.Router.Adapter.RuleView,
          Spectre.Router.Arbitration,
          Spectre.Router.Arbitrator,
          Spectre.Router.Candidate,
          Spectre.Router.Context,
          Spectre.Router.Receipt,
          Spectre.Router.SemanticCache,
          Spectre.Router.SemanticCache.Learned,
          Spectre.Router.SemanticCache.Owner
        ],
        "Prompts and providers": [
          Spectre.LLM,
          Spectre.Prompt,
          Spectre.Prompt.Fragment,
          Spectre.Prompt.Operation,
          Spectre.Prompt.Plan,
          Spectre.Prompt.Value,
          Spectre.Provider.Call,
          Spectre.Provider.Failure
        ],
        "Inference and boundary evidence": [
          Spectre.Inference,
          Spectre.Inference.Budget,
          Spectre.Inference.BudgetSnapshot,
          Spectre.Inference.Descriptor,
          Spectre.Inference.Event,
          Spectre.Inference.Events,
          Spectre.Inference.FrozenSelection,
          Spectre.Inference.Profile,
          Spectre.Inference.Prepared,
          Spectre.Inference.Progress,
          Spectre.Inference.ProviderEvent,
          Spectre.Inference.Request,
          Spectre.Inference.Response,
          Spectre.Inference.Selection,
          Spectre.Inference.Selector,
          Spectre.Inference.Stream,
          Spectre.Inference.StreamAdapter,
          Spectre.Inference.StreamAdapter.Conformance,
          Spectre.Inference.StreamEvent,
          Spectre.Inference.Usage,
          Spectre.Receipt.Envelope,
          Spectre.Receipt.Sink,
          Spectre.Receipt.Sink.Conformance,
          Spectre.Receipt.Sink.Memory,
          Spectre.Determinism,
          Spectre.Determinism.Source
        ],
        Actions: [
          Spectre.Action,
          Spectre.Action.Schema,
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
        "Operational loops": [
          Spectre.Execution.Expression,
          Spectre.Execution.Program,
          Spectre.Execution.Work,
          Spectre.Execution.Materialization,
          Spectre.Execution.Materializer,
          Spectre.Execution.Runtime,
          Spectre.Execution.Handoff,
          Spectre.Execution.Migration,
          Spectre.Execution.Migration.Receipt,
          Spectre.Execution.Rehearsal,
          Spectre.Execution.Rehearsal.Report,
          Spectre.Projection.Execution,
          Spectre.Prompt.Materializer,
          Spectre.Prompt.Receipt,
          Spectre.Work,
          Spectre.Vigil,
          Spectre.Operation.Controller,
          Spectre.Operation.Definition,
          Spectre.Operation.Spec,
          Spectre.Operation.Registry,
          Spectre.Operation.Runtime,
          Spectre.Operation.Loop,
          Spectre.Operation.Ref,
          Spectre.Operation.View,
          Spectre.Operation.Request,
          Spectre.Operation.Wait,
          Spectre.Operation.Attempt,
          Spectre.Operation.Result,
          Spectre.Operation.Progress,
          Spectre.Operation.Execution,
          Spectre.Operation.ExecutionContext,
          Spectre.Operation.Executor,
          Spectre.Operation.Runner,
          Spectre.Operation.RunnerSupervisor,
          Spectre.Operation.Monitor,
          Spectre.Operation.Control,
          Spectre.Operation.Control.Command,
          Spectre.Operation.Budget,
          Spectre.Operation.Retry,
          Spectre.Operation.Outcome,
          Spectre.Operation.Update,
          Spectre.Operation.Artifact,
          Spectre.Operation.Event,
          Spectre.Operation.Events,
          Spectre.Operation.Memory,
          Spectre.Operation.Policy,
          Spectre.Operation.Validator,
          Spectre.Operation.Delivery,
          Spectre.Operation.Delivery.Consent,
          Spectre.Operation.Delivery.Policy,
          Spectre.Operation.Delivery.Receipt,
          Spectre.Instance.CheckpointStore,
          Spectre.Instance.CheckpointStore.Conformance,
          Spectre.Instance.CheckpointStore.ErasureConformance
        ],
        Extensions: [
          Spectre.Extension,
          Spectre.Stack.Contract.V1,
          Spectre.Stack.Contract.V2,
          Spectre.Stack.Definition,
          Spectre.Stack.Installable,
          Spectre.Stack.Installation,
          Spectre.Stack.Package,
          Spectre.Stack.Ref,
          Spectre.Stack.Runtime
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
          Spectre.Journal,
          Spectre.Journal.Buffer,
          Spectre.Journal.Record,
          Spectre.Journal.Recorder,
          Spectre.Journal.Store,
          Spectre.Journal.Store.ErasureConformance,
          Spectre.Monitor,
          Spectre.Telemetry
        ],
        "Mix tasks": ~r/^Mix.Tasks.Spectre/,
        "Supporting API": ~r/^Spectre\./
      ]
    ]
  end
end
