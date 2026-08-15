defmodule Spectre.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/elchemista/spectre"
  @homepage_url "https://spectre.elchemista.com"
  @docs_extras [
    "docs/START_HERE.md",
    "README.md",
    "docs/INSTALLATION.md",
    "docs/GETTING_STARTED.md",
    "docs/ARCHITECTURE.md",
    "docs/EXAMPLES.md",
    "SYSTEM.md",
    "docs/CANONICAL_DEFINITIONS.md",
    "docs/ROUTING.md",
    "docs/ACTIONS.md",
    "docs/SKILLS.md",
    "docs/MEMORY.md",
    "docs/STREAMING_INFERENCE.md",
    "docs/RECEIPTS.md",
    "docs/RUNS.md",
    "docs/INSTANCES.md",
    "docs/OPERATIONS.md",
    "docs/DEFINITION_STORE.md",
    "docs/IDENTITY_ACTIVATION.md",
    "docs/EVENT_LIFECYCLE.md",
    "docs/SKILL_STATE.md",
    "docs/JOURNAL.md",
    "docs/PRODUCTION.md",
    "docs/TESTING.md",
    "docs/PROVIDERS.md",
    "docs/EVALUATION.md",
    "docs/TRAINING.md",
    "docs/FOUNDATION_CONFORMANCE.md",
    "SECURITY.md",
    "docs/INTEGRATIONS.md",
    "docs/STACK.md",
    "docs/RUNTIME_SKILLS.md",
    "docs/DATA_DRIVEN_EXECUTION.md",
    "docs/GOVERNANCE.md",
    "docs/REFLECTIVE_RUNTIME.md",
    "docs/DSL.md",
    "docs/API.md",
    "docs/PUBLIC_API.md",
    "docs/adr/0001-inference-runtime-ownership.md",
    "docs/adr/0002-stream-delivery-and-restart.md",
    "docs/adr/0003-steering-replaces-a-stream-attempt.md",
    "docs/adr/0004-observer-lane-is-post-commit.md",
    "docs/adr/0005-receipts-and-replay-claims.md",
    "docs/adr/0006-inference-security-boundaries.md",
    "docs/MIGRATING_TO_0_2.md",
    "docs/MIGRATING_TO_0_2_3.md",
    "docs/MIGRATING_TO_0_2_4.md",
    "docs/MIGRATING_TO_0_2_5.md",
    "docs/MIGRATING_TO_0_2_6.md",
    "docs/MIGRATING_TO_0_2_7.md",
    "docs/MIGRATING_TO_0_2_8.md",
    "docs/MIGRATING_TO_0_2_9.md",
    "docs/MIGRATING_TO_0_3.md",
    "docs/MIGRATING_TO_RUN_V3.md",
    "docs/MIGRATING_TO_INSTANCE_CHECKPOINT_V3.md",
    "CHANGELOG.md",
    "docs/ROADMAP.md",
    "LLMS.md",
    "CONTRIBUTING.md",
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
      test_coverage: [summary: [threshold: 95]],
      description: description(),
      package: package(),
      dialyzer: [
        plt_add_apps: [:mix],
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
      extra_applications: [:logger, :eex, :crypto]
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
        ~w(lib priv docs mix.exs .formatter.exs README.md LLMS.md SYSTEM.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{
        "Website" => @homepage_url,
        "Documentation" => "https://hexdocs.pm/spectre/#{@version}",
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/#{@version}/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:vettore, "~> 0.3.3"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: :test, runtime: false}
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
      main: "start_here",
      source_ref: @version,
      extras: @docs_extras,
      groups_for_extras: [
        "Start here": [
          "docs/START_HERE.md",
          "README.md",
          "docs/INSTALLATION.md",
          "docs/GETTING_STARTED.md",
          "docs/ARCHITECTURE.md"
        ],
        Tutorials: [
          "docs/EXAMPLES.md"
        ],
        "Core concepts": [
          "SYSTEM.md",
          "docs/CANONICAL_DEFINITIONS.md",
          "docs/ROUTING.md",
          "docs/ACTIONS.md",
          "docs/SKILLS.md",
          "docs/MEMORY.md",
          "docs/STREAMING_INFERENCE.md",
          "docs/RECEIPTS.md"
        ],
        "Runtime and durability": [
          "docs/INSTANCES.md",
          "docs/RUNS.md",
          "docs/OPERATIONS.md",
          "docs/DEFINITION_STORE.md",
          "docs/IDENTITY_ACTIVATION.md",
          "docs/EVENT_LIFECYCLE.md",
          "docs/SKILL_STATE.md",
          "docs/JOURNAL.md"
        ],
        Operations: [
          "docs/PRODUCTION.md",
          "docs/TESTING.md",
          "docs/PROVIDERS.md",
          "docs/EVALUATION.md",
          "docs/TRAINING.md",
          "docs/FOUNDATION_CONFORMANCE.md",
          "SECURITY.md"
        ],
        "Extensions and integration": [
          "docs/INTEGRATIONS.md",
          "docs/STACK.md",
          "docs/RUNTIME_SKILLS.md",
          "docs/DATA_DRIVEN_EXECUTION.md",
          "docs/GOVERNANCE.md",
          "docs/REFLECTIVE_RUNTIME.md"
        ],
        Reference: [
          "docs/DSL.md",
          "docs/API.md",
          "docs/PUBLIC_API.md"
        ],
        "Architecture decisions": [
          "docs/adr/0001-inference-runtime-ownership.md",
          "docs/adr/0002-stream-delivery-and-restart.md",
          "docs/adr/0003-steering-replaces-a-stream-attempt.md",
          "docs/adr/0004-observer-lane-is-post-commit.md",
          "docs/adr/0005-receipts-and-replay-claims.md",
          "docs/adr/0006-inference-security-boundaries.md"
        ],
        "Migration and history": [
          "docs/MIGRATING_TO_0_2.md",
          "docs/MIGRATING_TO_0_2_3.md",
          "docs/MIGRATING_TO_0_2_4.md",
          "docs/MIGRATING_TO_0_2_5.md",
          "docs/MIGRATING_TO_0_2_6.md",
          "docs/MIGRATING_TO_0_2_7.md",
          "docs/MIGRATING_TO_0_2_8.md",
          "docs/MIGRATING_TO_0_2_9.md",
          "docs/MIGRATING_TO_0_3.md",
          "docs/MIGRATING_TO_RUN_V3.md",
          "docs/MIGRATING_TO_INSTANCE_CHECKPOINT_V3.md",
          "CHANGELOG.md",
          "docs/ROADMAP.md"
        ],
        "LLM and coding agents": [
          "LLMS.md"
        ],
        Project: [
          "CONTRIBUTING.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
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
          Spectre.Instance,
          Spectre.Instance.Activation,
          Spectre.Event.Envelope,
          Spectre.Instance.Owner,
          Spectre.Instance.Owner.Lease,
          Spectre.Instance.Owner.Local,
          Spectre.Instance.Ref,
          Spectre.Instance.Registry,
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
          Spectre.Instance.CheckpointStore
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
          Spectre.Monitor,
          Spectre.Telemetry
        ],
        "Mix tasks": ~r/^Mix.Tasks.Spectre/,
        "Supporting API": ~r/^Spectre\./
      ]
    ]
  end
end
