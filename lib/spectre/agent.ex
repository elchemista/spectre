defmodule Spectre.Agent do
  @moduledoc """
  Declarative DSL for building Spectre agents.

  The DSL is intentionally a control plane, not a place to hide application
  logic. It describes the agent boundary: how input is normalized, how routes
  are selected, which prompts/actions run, and which actions must pass a policy
  gate before side effects can execute. The actual domain work should stay in
  ordinary Elixir modules and be called through `run/2`, `action/2`, adapters,
  or lifecycle hooks.

  This split keeps complex agents understandable:

    * `flow/2` declares conversation intents and handlers.
    * `router/1` declares which evidence providers produce candidates.
    * `policy/2` declares approval/rejection gates for dangerous actions.
    * `protect/2` attaches an action name to a policy independently from the
      prompt or handler that produced the action.
    * `actions/2` and `action_provider/3` keep side effects behind registered
      providers.
    * `action_planner/2` accepts provider-neutral plans without coupling the
      runtime to a planning library.
    * `state/1` and `memory/1` keep persistence at explicit runtime boundaries.

      defmodule MyApp.ProjectAgent do
        use Spectre.Agent, prompt_root: "priv/agents/project/prompts"

        model MyApp.LLM
        actions MyApp.ProjectActions
        state MyApp.AgentStateStore
        memory MyApp.AgentMemory
        input_pipeline do
          plug Spectre.Input.Plugs.NormalizeText, case: :downcase
        end
        shutdown 600_000
        fail :agent_failure_reply

        router via: [:regex, :semantic_cache, :classifier, :llm_classifier]

        protect :create_project, with: :terms

        policy :terms do
          request :accept_terms
          accept :accepted_terms, regex: ~r/^accetto$/i
          reject :rejected_terms, regex: ~r/^no$/i
          otherwise ask: :accept_terms_retry
          attempts 3, then: :cancel_pending
        end

        flow :project_create do
          on :wants_project_create, regex: ~r/crea.*progetto/i do
            ask :project_create
          end
        end
      end

  In a larger agent, keep this module as the readable map of the system and
  move business decisions into named functions or modules:

      defmodule MyApp.BillingAgent do
        use Spectre.Agent

        actions MyApp.BillingActions
        router via: [:regex, :classifier, :embedding, :llm_classifier]

        protect :issue_refund, with: :refund_confirmation

        flow :billing do
          on :refund_request do
            run :prepare_refund_case
          end

          on :confirm_refund, regex: ~r/^refund now$/i do
            action :issue_refund
          end
        end

        def prepare_refund_case(input, ctx) do
          MyApp.Billing.PrepareRefund.call(input, ctx)
        end
      end
  """

  alias Spectre.Definition
  alias Spectre.Definition.Validator
  alias Spectre.Extension
  alias Spectre.Prompt.Operation
  alias Spectre.Skill.Mount
  alias Spectre.Stack.Binding

  @doc """
  Imports the DSL and initializes compile-time metadata for an agent module.

  Options are stored as runtime configuration and are later exposed through
  generated `__spectre_*__` functions. This is why the DSL can stay
  declarative: all route and policy data is compiled once, then interpreted by
  the runtime.

      defmodule MyApp.SupportAgent do
        use Spectre.Agent,
          prompt_root: "priv/agents/support/prompts",
          history: 20
      end
  """
  defmacro __using__(opts) do
    opts = eval_opts(opts, __CALLER__)
    kind = Keyword.get(opts, :__spectre_kind__, :agent)
    id = Keyword.get(opts, :id, __CALLER__.module)
    version = Keyword.get(opts, :version, 1)
    config = default_config(opts, kind)
    router = default_router(opts, kind)

    if kind == :skill and Keyword.has_key?(opts, :arbitrator) do
      raise ArgumentError, "Skills inherit the Agent router and cannot configure :arbitrator"
    end

    setup_module!(__CALLER__.module, config, router, kind, id, version)

    quote do
      import Spectre.Agent
      import Spectre.Morph.DSL, only: [morph: 1]
      @before_compile Spectre.Agent
    end
  end

  @spec setup_module!(module(), keyword(), keyword(), atom(), term(), pos_integer()) :: :ok
  defp setup_module!(module, config, router, kind, definition_id, definition_version) do
    # Register eagerly while `use Spectre.Agent` expands. Stack extensions are
    # then visible to Flow handler parsing in the same module, while Agent
    # remains the only owner of the eventual before-compile pass.
    Module.register_attribute(module, :spectre_config, persist: false)
    Module.register_attribute(module, :spectre_rules, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_policies, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_after_actions, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_before_actions, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_protections, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_router, persist: false)
    Module.register_attribute(module, :spectre_injections, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_skills, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_requirements, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_extensions, accumulate: true, persist: false)
    Module.register_attribute(module, :spectre_stack_refs, persist: false)
    Module.register_attribute(module, :spectre_kind, persist: false)
    Module.register_attribute(module, :spectre_definition_id, persist: false)
    Module.register_attribute(module, :spectre_definition_version, persist: false)
    Module.register_attribute(module, :spectre_change_surface, persist: false)

    Module.put_attribute(module, :spectre_config, config)
    Module.put_attribute(module, :spectre_router, router)
    Module.put_attribute(module, :spectre_kind, kind)
    Module.put_attribute(module, :spectre_definition_id, definition_id)
    Module.put_attribute(module, :spectre_definition_version, definition_version)

    if kind == :agent do
      Binding.setup_agent!(module, Keyword.get(config, :stack))
    else
      Module.put_attribute(module, :spectre_stack_refs, [])
    end

    :ok
  end

  @doc """
  Mounts a reusable `Spectre.Skill` inside an Agent.

  `as:` assigns the local scope identifier. `bind:` maps logical Skill action
  requirements to concrete actions owned by the Agent.

      skill MyApp.Skills.Research,
        as: :research,
        bind: [search: :web_search, publish: :publish_report]
  """
  defmacro skill(module, opts \\ []) do
    caller = __CALLER__
    module = Macro.expand(module, caller)
    opts = eval_opts(opts, caller)
    definition = Definition.fetch!(module)

    if definition.kind != :skill do
      raise ArgumentError,
            "skill expects a module using Spectre.Skill, got: #{inspect(module)}"
    end

    mount = Mount.new(module, definition, opts)

    quote do
      @spectre_skills unquote(Macro.escape(mount))
    end
  end

  @doc """
  Adds a typed prompt fragment to the current Agent or Skill scope.

      inject :company_identity, into: :instructions, position: :start
  """
  defmacro inject(id, opts \\ []) do
    opts =
      opts
      |> eval_opts(__CALLER__)
      |> Keyword.put_new(:source_line, __CALLER__.line)

    operation = Operation.new(Macro.expand(id, __CALLER__), opts)

    quote do
      @spectre_injections unquote(Macro.escape(operation))
    end
  end

  @doc """
  Declares a logical action that must be bound when a reusable Skill is
  mounted.

      requires_action :search, mode: :read
  """
  defmacro requires_action(name, opts \\ []) do
    name = Macro.expand(name, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    requirement = %{
      name: name,
      mode: Keyword.get(opts, :mode, :read),
      opts: Keyword.drop(opts, [:mode])
    }

    quote do
      @spectre_requirements unquote(Macro.escape(requirement))
    end
  end

  @doc """
  Alias for `requires_action/2` using tool-oriented terminology.
  """
  defmacro requires_tool(name, opts \\ []) do
    name = Macro.expand(name, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    requirement = %{
      name: name,
      mode: Keyword.get(opts, :mode, :read),
      opts: Keyword.drop(opts, [:mode])
    }

    quote do
      @spectre_requirements unquote(Macro.escape(requirement))
    end
  end

  @doc """
  Declares an immutable Agent operation required by a reusable Skill.

  Operations are resolved from the host Agent registry. A Skill can reference
  their stable identifiers, but cannot register executors or inject executable
  callbacks.

      requires_operation :read_logs
  """
  defmacro requires_operation(name, opts \\ []) do
    name = Macro.expand(name, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    requirement = %{
      kind: :operation,
      name: name,
      mode: :read,
      opts: opts
    }

    quote do
      @spectre_requirements unquote(Macro.escape(requirement))
    end
  end

  @doc """
  Configures the action adapter and optional action-level protections/hooks.

  Use the block form when the action module should be declared next to its
  lifecycle policy. This keeps side-effect boundaries visible in the agent file
  while the actual implementation remains in the action module.

      actions MyApp.ProjectActions do
        protect :delete_project, with: :confirm_delete
        after_action :delete_project, on: :delivered, run: :audit_delete
      end
  """
  defmacro actions(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    {block, opts} = Keyword.pop(opts, :do)
    opts = eval_opts(opts, __CALLER__)

    if block do
      %{protections: protections, after_actions: after_actions} =
        parse_actions_config_block(block, __CALLER__)

      quote do
        @spectre_config Keyword.put(
                          @spectre_config,
                          :actions,
                          {unquote(module), unquote(Macro.escape(opts))}
                        )

        Enum.each(
          unquote(Macro.escape(protections)),
          &Module.put_attribute(__MODULE__, :spectre_protections, &1)
        )

        Enum.each(
          unquote(Macro.escape(after_actions)),
          &Module.put_attribute(__MODULE__, :spectre_after_actions, &1)
        )
      end
    else
      quote bind_quoted: [module: module, opts: opts] do
        @spectre_config Keyword.put(@spectre_config, :actions, {module, opts})
      end
    end
  end

  @doc """
  Block-form variant for `actions/2`.
  """
  defmacro actions(module, opts, do: block) do
    module = Macro.expand(module, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    %{protections: protections, after_actions: after_actions} =
      parse_actions_config_block(block, __CALLER__)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :actions,
                        {unquote(module), unquote(Macro.escape(opts))}
                      )

      Enum.each(
        unquote(Macro.escape(protections)),
        &Module.put_attribute(__MODULE__, :spectre_protections, &1)
      )

      Enum.each(
        unquote(Macro.escape(after_actions)),
        &Module.put_attribute(__MODULE__, :spectre_after_actions, &1)
      )
    end
  end

  @doc """
  Registers an action provider under a stable identifier.

  This is the low-level port used by optional Spectre libraries. Applications
  using an ordinary Elixir module can keep the shorter `actions/2` DSL.

      action_provider :browser, MyApp.BrowserProvider
      action_provider {:mcp, :github}, MyApp.GitHubProvider
  """
  defmacro action_provider(id, module, opts \\ []) do
    id = eval_action_arg(id, __CALLER__)
    module = Macro.expand(module, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    mount = Spectre.Action.Provider.Mount.new(id, module, opts)

    quote do
      providers = Keyword.get(@spectre_config, :action_providers, [])

      @spectre_config Keyword.put(
                        @spectre_config,
                        :action_providers,
                        providers ++ [unquote(Macro.escape(mount))]
                      )
    end
  end

  @doc """
  Registers an application operation for Work, Vigil and external controllers.

  The executor is a stable module or `{module, function}` reference. Runtime
  inputs and outputs are validated against this immutable registry entry;
  models and planners cannot inject executable modules or arbitrary MFAs.

      operation :read_logs, {MyApp.Operations, :read_logs},
        input: :map,
        output: :map,
        side_effect: :none,
        timeout: 15_000
  """
  defmacro operation(id, executor, opts \\ []) do
    id = eval_action_arg(id, __CALLER__)
    executor = eval_action_arg(executor, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    spec =
      opts
      |> Map.new()
      |> Map.put(:id, id)
      |> Map.put_new(:kind, :function)
      |> Map.put(:executor, executor)
      |> Spectre.Operation.Spec.new()

    quote do
      operations = Keyword.get(@spectre_config, :operations, [])

      if Enum.any?(operations, &(&1.id == unquote(Macro.escape(id)))) do
        raise ArgumentError, "duplicate Spectre operation: #{inspect(unquote(Macro.escape(id)))}"
      end

      @spectre_config Keyword.put(
                        @spectre_config,
                        :operations,
                        operations ++ [unquote(Macro.escape(spec))]
                      )
    end
  end

  @doc """
  Configures which committed operational events re-enter the normal Flow router.

  Use `:all`, a list of event types, or `false`. Events are converted to
  `Spectre.Input` values and still need to match ordinary `on` rules; this does
  not install a second event matcher.

      route_operation_events [:completed, :blocked, :observation_significant]
  """
  defmacro route_operation_events(types \\ :all) do
    types = eval_action_arg(types, __CALLER__)

    unless types in [:all, false] or
             (is_list(types) and Enum.all?(types, &(is_atom(&1) and not is_nil(&1)))) do
      raise ArgumentError, "route_operation_events expects :all, false, or event atoms"
    end

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :route_operation_events,
                        unquote(Macro.escape(types))
                      )
    end
  end

  @doc "Configures the canonical checkpoint adapter used by Agent Instances."
  defmacro checkpoint_store(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :checkpoint_store,
                        {unquote(module), unquote(Macro.escape(opts))}
                      )
    end
  end

  @doc """
  Configures the provider-neutral action planner port.

  Optional libraries normally mount this through their own DSL, for example
  `use Spectre.Kinetic`. The explicit form is useful for application-specific
  planners.
  """
  defmacro action_planner(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    unless is_atom(module) and not is_nil(module),
      do: raise(ArgumentError, "action planner must be a module")

    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "action planner options must be a keyword list")

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :action_planner,
                        {unquote(module), unquote(Macro.escape(opts))}
                      )
    end
  end

  @doc """
  Configures the LLM adapter used by `ask/2`.

  By default Spectre calls `complete(prompt, opts)` on the adapter. Use
  `with:` or `function:` when the adapter exposes a different function name.

      model MyApp.OpenAIAdapter, with: :complete_chat, model: "gpt-4.1-mini"
  """
  defmacro model(adapter, opts \\ []) do
    adapter = Macro.expand(adapter, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    function = Keyword.get(opts, :function, Keyword.get(opts, :with, :complete))
    model = {adapter, function, Keyword.drop(opts, [:function, :with])}

    quote do
      @spectre_config Keyword.put(@spectre_config, :model, unquote(Macro.escape(model)))
    end
  end

  @doc """
  Configures classifier adapters.

  The first argument is the LLM adapter used only by `:llm_classifier`
  arbitration. `local:` configures the local classifier adapter used by the
  `:classifier` router strategy.

      classifier MyApp.SmallLLM,
        model: "small",
        prompt: &MyApp.ClassifierPrompt.build/1,
        llm_opts: [temperature: 0.0, max_tokens: 8],
        local: MyApp.LocalClassifier,
        artifact_dir: "priv/spectre/support"
  """
  defmacro classifier(adapter, opts \\ []) do
    adapter = Macro.expand(adapter, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    classifier = normalize_classifier(adapter, opts)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :classifier,
                        unquote(Macro.escape(classifier))
                      )
    end
  end

  @doc """
  Configures a structured agent journal store.

  Journaling is opt-in and excludes input/reply content by default. The
  monitoring default is asynchronous warning mode; use synchronous error mode
  only when a failed append must fail the turn.

      journal MyApp.SpectreJournal,
        events: [:routing, :arbitration],
        mode: :async,
        on_error: :warn,
        include_input: false

  `journal(false)` explicitly disables an application-level default for this
  agent.
  """
  defmacro journal(store, opts \\ [])

  defmacro journal(false, _opts) do
    quote do
      @spectre_config Keyword.put(@spectre_config, :journal, false)
    end
  end

  defmacro journal(store, opts) do
    store = Macro.expand(store, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :journal,
                        {unquote(store), unquote(Macro.escape(opts))}
                      )
    end
  end

  @doc """
  Configures a state adapter used to load and persist conversation state.

  State adapters keep storage outside the domain runtime. They may implement
  `load/3` and `persist/4` for agent-aware calls, or the smaller `load/2` and
  `persist/2` callbacks for simpler applications.

      state MyApp.AgentStateStore
  """
  defmacro state(module) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module] do
      @spectre_config Keyword.put(@spectre_config, :state, module)
    end
  end

  @doc """
  Configures a memory adapter used to recall and remember conversation context.

  Memory is intentionally separate from state: state is the authoritative
  machine state for routing and policies, while memory is contextual material
  that prompts or adapters may use.

      memory MyApp.AgentMemory
  """
  defmacro memory(module) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module] do
      @spectre_config Keyword.put(@spectre_config, :memory, module)
    end
  end

  @doc """
  Appends an optional handler to the pre-route turn pipeline.

  Handlers run in declaration order after an already-open Spectre policy and
  before ordinary routing. They return `:cont` to preserve the pipeline or a
  typed reply to own the turn. This is a dependency-free integration point for
  external runtimes; memory, actions, prompts, input, and telemetry retain
  their narrower dedicated boundaries.

      turn_handler MyApp.ActiveWorkflow, namespace: :support
  """
  defmacro turn_handler(handler, opts \\ []) do
    handler = Macro.expand(handler, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    handler_spec = {handler, opts}

    quote bind_quoted: [handler_spec: handler_spec] do
      handlers =
        case Keyword.get(@spectre_config, :turn_handlers, []) do
          current when is_list(current) -> current ++ [handler_spec]
          _disabled_or_invalid -> [handler_spec]
        end

      @spectre_config Keyword.put(@spectre_config, :turn_handlers, handlers)
    end
  end

  @doc """
  Replaces the complete turn-handler pipeline or disables it with `false`.

      turn_handlers [
        MyApp.FirstIntegration,
        {MyApp.SecondIntegration, namespace: :support}
      ]

      turn_handlers false
  """
  defmacro turn_handlers(handlers) do
    handlers = eval_opts(handlers, __CALLER__)

    quote bind_quoted: [handlers: handlers] do
      @spectre_config Keyword.put(@spectre_config, :turn_handlers, handlers)
    end
  end

  @doc """
  Declares an input normalization pipeline using plug syntax.

  Input plugs run before state, routing, and policy handling. This makes
  downstream decisions work with one normalized internal shape rather than each
  router plug parsing raw host input differently.

      input_pipeline do
        plug Spectre.Input.Plugs.NormalizeText, trim?: true, case: :downcase
      end

  You can also pass an already-built plug spec list:

      input_pipeline [
        {Spectre.Input.Plugs.NormalizeText, trim?: true}
      ]
  """
  defmacro input_pipeline(do: block) do
    specs = parse_input_pipeline(block, __CALLER__)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :input_pipeline,
                        unquote(Macro.escape(specs))
                      )
    end
  end

  defmacro input_pipeline(specs) do
    specs = eval_opts(specs, __CALLER__)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :input_pipeline,
                        unquote(Macro.escape(specs))
                      )
    end
  end

  @doc """
  Configures the maximum lifetime for a supervised session.

      shutdown :timer.minutes(30)
  """
  defmacro shutdown(timeout) do
    quote bind_quoted: [timeout: timeout] do
      @spectre_config Keyword.put(@spectre_config, :shutdown, timeout)
    end
  end

  @doc """
  Configures idle timeout for a supervised session.

      idle :timer.minutes(5)
  """
  defmacro idle(timeout) do
    quote bind_quoted: [timeout: timeout] do
      @spectre_config Keyword.put(@spectre_config, :idle, timeout)
    end
  end

  @doc """
  Configures how many completed turns are stored in chat history.

      history 50

  With `summary:`, turns evicted from the window are folded into a rolling
  summary kept under `state.data.chat_summary` instead of being dropped. The
  summarizer receives `(current_summary_or_nil, evicted_entries)` and returns
  the new summary string; on error the previous summary is kept and the
  entries are dropped as before.

      history 50, summary: {MyApp.Chat, :compact}
  """
  defmacro history(limit, opts \\ []) do
    opts = eval_opts(opts, __CALLER__)

    quote bind_quoted: [limit: limit, opts: opts] do
      @spectre_config Keyword.put(@spectre_config, :history, limit)

      if summary = Keyword.get(opts, :summary) do
        @spectre_config Keyword.put(@spectre_config, :history_summary, summary)
      end
    end
  end

  @doc """
  Configures the prompt used by `Spectre.Monitor` failure fallback text.

      fail :agent_failure_reply
  """
  defmacro fail(prompt, opts \\ []) do
    prompt = Macro.expand(prompt, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote bind_quoted: [prompt: prompt, opts: opts] do
      @spectre_config Keyword.put(@spectre_config, :fail, {prompt, opts})
    end
  end

  @doc """
  Configures the deterministic reply returned when another protected action is
  requested while an externally resolved approval is still open.

      approval_pending_reply :approval_pending
  """
  defmacro approval_pending_reply(prompt, opts \\ []) do
    prompt = Macro.expand(prompt, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote bind_quoted: [prompt: prompt, opts: opts] do
      @spectre_config Keyword.put(@spectre_config, :approval_pending_reply, {prompt, opts})
    end
  end

  @doc """
  Configures router behavior for the agent.

  `via:` is the common path: it expands into router plugs and then appends the
  arbitration and terminalization steps. Use `pipeline:` only when the agent
  needs a fully custom router pipeline.

      router via: [:regex, :semantic_cache, :classifier, :embedding, :llm_classifier]
  """
  defmacro router(opts) do
    quote bind_quoted: [opts: opts] do
      @spectre_router Keyword.merge(@spectre_router, opts)
    end
  end

  @doc """
  Replaces the default evidence arbitrator.

  The arbitrator receives all candidate routes from the pipeline and decides
  whether to accept one, ask the LLM classifier, clarify, or fail.

      arbitrator MyApp.Router.Arbitrator, conflict: :llm
  """
  defmacro arbitrator(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote do
      @spectre_router Keyword.put(
                        @spectre_router,
                        :arbitrator,
                        {unquote(module), unquote(Macro.escape(opts))}
                      )
    end
  end

  @doc """
  Configures the embedding adapter used by embedding-based router strategies.

      embedding MyApp.Embeddings, model: "text-embedding-3-small"
  """
  defmacro embedding(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote do
      @spectre_config Keyword.put(
                        @spectre_config,
                        :embedding,
                        {unquote(module), unquote(Macro.escape(opts))}
                      )
    end
  end

  @doc """
  Attaches an action to a policy gate.

  Protection is action-centric rather than prompt-centric on purpose: the same
  dangerous action can be produced by DSL handlers or by an optional planner
  inspecting an LLM reply, and it must still pass the same policy.

      protect :delete_account, with: :delete_account_confirmation
  """
  defmacro protect(action_or_opts, opts \\ []) do
    action_or_opts = eval_action_arg(action_or_opts, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    {action, opts} = normalize_protect_args(action_or_opts, opts)
    protection = build_protection(action, opts)

    quote do
      @spectre_protections unquote(Macro.escape(protection))
    end
  end

  @doc """
  Registers an action lifecycle hook.

  Hooks run after the action execution result is available, which makes them a
  good place for audit trails, delivery acknowledgements, and integration
  events that should not affect route selection.

      after_action :delete_account, on: :delivered, run: :audit_delete_account
  """
  defmacro after_action(action, opts) do
    action = eval_action_arg(action, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    hook = after_action_hook(action, opts)

    quote do
      @spectre_after_actions unquote(Macro.escape(hook))
    end
  end

  @doc """
  Registers a pre-execution guard for an action effect.

  Guards run right before the capability is invoked, after routing, planning,
  and any policy approval. A guard returning `:allow` lets execution proceed;
  `{:suppress, reply_text}` cancels the pending effect without invoking the
  capability and returns a normal reply result carrying that text. Use guards
  for host-state vetoes that no route or policy can see, such as "this user
  already has an open draft".

      before_action :create_project, run: {MyApp.Guards, :no_duplicate_draft}

  The guard receives `(action, ctx)` — also accepted as arity 1 (`action`) or
  a local agent function via an atom. `:all` matches every action.
  """
  defmacro before_action(action, opts) do
    action = eval_action_arg(action, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    guard = before_action_guard(action, opts)

    quote do
      @spectre_before_actions unquote(Macro.escape(guard))
    end
  end

  @doc """
  Declares route rules that belong to a conversation flow.

  Flow names are stored on routes and can be used by stateful applications to
  prioritize current-flow rules before general fallback rules.

      flow :project_create do
        on :wants_project_create,
          regex: ~r/create.*project/i do
          ask :project_create
        end
      end

  Flows nest. A nested flow is a taxonomy grouping: each rule keeps the full
  path in `flow_path` while `flow` stays the innermost name. `inject`
  declarations and flow options are inherited by nested flows.

      flow :checkout do
        on :PAY_CARD, embedding: ["pay by card"] do
          act :pay_card
        end

        flow :shipping do
          on :TRACK_PARCEL, embedding: ["where is my parcel?"] do
            reason :track_parcel
          end
        end
      end
  """
  defmacro flow(name, do: block) do
    rules = parse_flow_rules([name], [], block, __CALLER__, [])

    quote do
      unquote(Macro.escape(rules))
      |> Enum.each(&Module.put_attribute(__MODULE__, :spectre_rules, &1))
    end
  end

  @doc """
  Declares a flow with extension-owned namespaced options.

  Mounted extensions consume their own options during the Agent's single
  compile pass. Unknown or unconsumed options fail compilation. Nested flows
  inherit the options of their ancestors; their own options win on conflict.
  """
  defmacro flow(name, opts, do: block) do
    opts = eval_opts(opts, __CALLER__)
    rules = parse_flow_rules([name], opts, block, __CALLER__, [])

    quote do
      unquote(Macro.escape(rules))
      |> Enum.each(&Module.put_attribute(__MODULE__, :spectre_rules, &1))
    end
  end

  @doc """
  Declares a global route that is checked before normal flow rules.

  Interrupts are useful for cancel, help, handoff, and other commands that
  should work regardless of the current flow.

      interrupt :cancel, regex: ~r/^cancel$/i do
        run :cancel_current
      end
  """
  defmacro interrupt(label, opts, do: block) do
    rule = build_rule(label, [], opts, block, __CALLER__, global?: true)

    quote do
      @spectre_rules unquote(Macro.escape(rule))
    end
  end

  @doc """
  Declares a global route using the compact keyword `do:` form.
  """
  defmacro interrupt(label, opts) do
    {opts, block} = split_do!(opts)
    rule = build_rule(label, [], opts, block, __CALLER__, global?: true)

    quote do
      @spectre_rules unquote(Macro.escape(rule))
    end
  end

  @doc """
  Declares a policy gate for a pending action effect.

  A policy is a small deterministic router used only while an action effect is
  waiting for approval. It bypasses normal routing so a confirmation such as
  "yes" is interpreted as a policy response instead of a generic user intent.

      policy :delete_account_confirmation do
        request :confirm_delete_account
        accept :delete_confirmed, regex: ~r/^yes, delete$/i
        reject :delete_rejected, regex: ~r/^no$/i
        otherwise ask: :confirm_delete_account_retry
        attempts 3, then: :cancel_pending
      end
  """
  defmacro policy(name, do: block) do
    policy = parse_policy(name, block, __CALLER__)

    quote do
      @spectre_policies unquote(Macro.escape(policy))
    end
  end

  @doc """
  Creates a handler that renders a prompt, calls the LLM, and lets the
  configured planner stage provider-neutral actions.

      on :support_question do
        ask :support_answer
      end
  """
  defmacro ask(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :ask, unquote(prompt), unquote(opts)}
    end
  end

  @doc "Calls the configured model without permitting action planning."
  defmacro reason(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :reason, unquote(prompt), unquote(opts)}
    end
  end

  @doc "Calls the configured model and permits the closed action planner."
  defmacro act(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :act, unquote(prompt), unquote(opts)}
    end
  end

  @doc """
  Creates a handler that calls an agent-local function.

  Use `run/2` when the next step is normal Elixir orchestration rather than an
  LLM prompt or a protected action boundary.

      on :refund_request do
        run :prepare_refund_case
      end
  """
  defmacro run(function, opts \\ []) do
    quote do
      {:__spectre_handler__, :run, unquote(function), unquote(opts)}
    end
  end

  @doc """
  Creates a deterministic reply handler without calling the LLM.

      on :healthcheck, regex: ~r/^ping$/i do
        reply :pong
      end
  """
  defmacro reply(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :reply, unquote(prompt), unquote(opts)}
    end
  end

  @doc "Starts a separate precise Work owned by the current Agent Instance."
  defmacro work(controller, opts \\ []) do
    quote do
      {:__spectre_handler__, :work, unquote(controller), unquote(opts)}
    end
  end

  @doc """
  Creates a deterministic action handler.

  If the action is protected, Spectre stores it as pending and asks the policy
  prompt. If it is not protected, the action is staged for execution by the host
  boundary.

      on :delete_account, regex: ~r/^delete my account$/i do
        action :delete_account
      end
  """
  defmacro action(action, opts \\ []) do
    quote do
      {:__spectre_handler__, :action, unquote(action), unquote(opts)}
    end
  end

  @doc """
  Creates a declarative handler that requests a registered Agent operation.

  The handler records only the operation identifier and portable input policy;
  execution remains an explicit host boundary.

      on :lookup, check: {:text, "lookup"} do
        call_operation :lookup, input: :text
      end
  """
  defmacro call_operation(operation, opts \\ []) do
    quote do
      {:__spectre_handler__, :operation, unquote(operation), unquote(opts)}
    end
  end

  # DSL callback generation necessarily contains several definition clauses.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(env) do
    metadata = compile_metadata(env.module)
    definition = compile_definition(env.module, metadata)

    quote do
      @doc false
      def __spectre_definition__, do: unquote(Macro.escape(definition))

      @doc false
      def __spectre_config__, do: unquote(Macro.escape(metadata.config))

      @doc false
      def __spectre_router__, do: unquote(Macro.escape(metadata.router))

      @doc false
      def __spectre_rules__, do: unquote(Macro.escape(metadata.rules))

      @doc false
      def __spectre_policies__, do: unquote(Macro.escape(metadata.policies))

      @doc false
      def __spectre_protections__, do: unquote(Macro.escape(metadata.protections))

      @doc false
      def __spectre_after_actions__, do: unquote(Macro.escape(metadata.after_actions))

      @doc false
      def __spectre_before_actions__, do: unquote(Macro.escape(metadata.before_actions))

      @doc false
      def __spectre_injections__, do: unquote(Macro.escape(metadata.injections))

      @doc false
      def __spectre_skills__, do: unquote(Macro.escape(metadata.skills))

      @doc false
      def __spectre_requirements__, do: unquote(Macro.escape(metadata.requirements))

      @doc false
      def __spectre_extensions__, do: unquote(Macro.escape(metadata.extensions))

      @doc false
      def __spectre_stack_refs__, do: unquote(Macro.escape(metadata.stack_refs))

      @doc false
      def __spectre_change_surface__, do: unquote(Macro.escape(metadata.change_surface))

      @doc false
      def __spectre_prompt_root__ do
        Keyword.get(__spectre_config__(), :prompt_root, "priv/spectre/prompts")
      end
    end
  end

  @spec compile_metadata(module()) :: map()
  defp compile_metadata(module) do
    extensions =
      module
      |> Module.get_attribute(:spectre_extensions)
      |> reverse_attribute()
      |> then(&Extension.compile_all!(module, &1))

    rules =
      module
      |> Module.get_attribute(:spectre_rules)
      |> Enum.reverse()
      |> Enum.map(&compile_rule_constraints!(&1, extensions))

    base_config = Module.get_attribute(module, :spectre_config) || []
    config = Extension.merge_agent_config(base_config, extensions)

    %{
      config: config,
      router: Module.get_attribute(module, :spectre_router) || [],
      rules: rules,
      policies: module |> Module.get_attribute(:spectre_policies) |> policy_map(),
      after_actions:
        module |> Module.get_attribute(:spectre_after_actions) |> reverse_attribute(),
      before_actions:
        module |> Module.get_attribute(:spectre_before_actions) |> reverse_attribute(),
      protections: module |> Module.get_attribute(:spectre_protections) |> reverse_attribute(),
      injections: module |> Module.get_attribute(:spectre_injections) |> reverse_attribute(),
      skills: module |> Module.get_attribute(:spectre_skills) |> reverse_attribute(),
      requirements: module |> Module.get_attribute(:spectre_requirements) |> reverse_attribute(),
      extensions: extensions,
      stack_refs: Module.get_attribute(module, :spectre_stack_refs) || [],
      kind: Module.get_attribute(module, :spectre_kind) || :agent,
      id: Module.get_attribute(module, :spectre_definition_id) || module,
      version: Module.get_attribute(module, :spectre_definition_version) || 1,
      change_surface: Module.get_attribute(module, :spectre_change_surface)
    }
  end

  @spec compile_definition(module(), map()) :: Definition.t()
  defp compile_definition(module, metadata) do
    %{
      kind: metadata.kind,
      id: metadata.id,
      version: metadata.version,
      owner: module,
      prompt_root: Keyword.get(metadata.config, :prompt_root, "priv/spectre/prompts"),
      config: metadata.config,
      router: metadata.router,
      rules: metadata.rules,
      policies: metadata.policies,
      protections: metadata.protections,
      after_actions: metadata.after_actions,
      before_actions: metadata.before_actions,
      injections: metadata.injections,
      requirements: metadata.requirements,
      skills: metadata.skills,
      extensions: metadata.extensions,
      stack_refs: metadata.stack_refs,
      stack: Keyword.get(metadata.config, :stack),
      change_surface: metadata.change_surface
    }
    |> Definition.new()
    |> Validator.validate!()
  end

  @default_shutdown :timer.minutes(10)
  @default_history 50
  @default_fail {:agent_failure_reply, []}
  @default_arbitrator {Spectre.Router.Arbitrators.Default,
                       [
                         classifier_accept: 0.93,
                         classifier_margin: 0.08,
                         embedding_accept: 0.84,
                         bag_accept: 0.72,
                         conflict: :llm,
                         no_decision: :llm
                       ]}

  @spec default_config(keyword(), :agent | :skill) :: keyword()
  defp default_config(opts, :agent) do
    opts
    |> Keyword.drop([:arbitrator, :id, :version, :__spectre_kind__])
    |> Keyword.put_new(:shutdown, @default_shutdown)
    |> Keyword.put_new(:history, @default_history)
    |> Keyword.update(:fail, @default_fail, &normalize_fail/1)
  end

  defp default_config(opts, :skill) do
    Keyword.drop(opts, [:arbitrator, :id, :version, :__spectre_kind__])
  end

  @spec default_router(keyword(), :agent | :skill) :: keyword()
  defp default_router(opts, :agent) do
    []
    |> Keyword.put(
      :arbitrator,
      normalize_arbitrator(Keyword.get(opts, :arbitrator, @default_arbitrator))
    )
  end

  defp default_router(_opts, :skill), do: []

  @spec normalize_fail(term()) :: {term(), keyword()}
  defp normalize_fail({prompt, fail_opts}) when is_list(fail_opts), do: {prompt, fail_opts}
  defp normalize_fail(prompt), do: {prompt, []}

  @spec normalize_arbitrator(module() | {module(), keyword()}) :: {module(), keyword()}
  defp normalize_arbitrator({module, arbitrator_opts})
       when is_atom(module) and is_list(arbitrator_opts) do
    {module, arbitrator_opts}
  end

  defp normalize_arbitrator(module) when is_atom(module), do: {module, []}

  @classifier_config_keys [
    :function,
    :with,
    :prompt,
    :llm_opts,
    :context,
    :label_examples,
    :local,
    :classify,
    :artifact_dir,
    :local_accept_threshold,
    :local_margin_threshold,
    :local_high_confidence_threshold,
    :local_classifier_timeout,
    :classifier_timeout
  ]

  @local_classifier_keys [
    :artifact_dir,
    :local_accept_threshold,
    :local_margin_threshold,
    :local_high_confidence_threshold,
    :local_classifier_timeout,
    :classifier_timeout
  ]

  @spec normalize_classifier(module(), keyword()) :: keyword()
  defp normalize_classifier(adapter, opts) do
    function = Keyword.get(opts, :function, Keyword.get(opts, :with, :complete))

    [
      adapter: {adapter, function, Keyword.drop(opts, @classifier_config_keys)}
    ]
    |> maybe_put_classifier_option(:prompt, Keyword.get(opts, :prompt))
    |> maybe_put_classifier_option(:llm_opts, Keyword.get(opts, :llm_opts))
    |> maybe_put_classifier_option(:context, Keyword.get(opts, :context))
    |> maybe_put_classifier_option(:label_examples, Keyword.get(opts, :label_examples))
    |> maybe_put_classifier_option(:local, Keyword.get(opts, :local))
    |> maybe_put_classifier_option(:local_opts, Keyword.take(opts, @local_classifier_keys))
  end

  @spec maybe_put_classifier_option(keyword(), atom(), term()) :: keyword()
  defp maybe_put_classifier_option(opts, _key, nil), do: opts
  defp maybe_put_classifier_option(opts, :local_opts, []), do: opts
  defp maybe_put_classifier_option(opts, key, value), do: Keyword.put(opts, key, value)

  @spec policy_map([map()] | nil) :: map()
  defp policy_map(nil), do: %{}

  defp policy_map(policies) do
    policies = Enum.reverse(policies)
    names = Enum.map(policies, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> Map.new(policies, fn policy -> {policy.name, policy} end)
      [duplicate | _rest] -> raise ArgumentError, "duplicate policy #{inspect(duplicate)}"
    end
  end

  @spec compile_rule_constraints!(map(), [Spectre.Extension.Mount.t()]) :: map()
  defp compile_rule_constraints!(rule, extensions) do
    {constraints, remaining} =
      rule
      |> Map.get(:flow_opts, [])
      |> Extension.flow_constraints(extensions)

    case remaining do
      [] ->
        rule
        |> Map.delete(:flow_opts)
        |> Map.put(:constraints, constraints)

      unknown ->
        raise ArgumentError,
              "unknown flow options for #{inspect(rule.flow)}: #{inspect(Keyword.keys(unknown))}"
    end
  end

  @spec parse_flow_rules([atom()], keyword(), Macro.t(), Macro.Env.t(), [Operation.t()]) ::
          [map()]
  defp parse_flow_rules(path, flow_opts, block, caller, inherited_injections) do
    {injection_calls, rule_calls} =
      block
      |> calls()
      |> Enum.split_with(&injection_call?/1)

    injections =
      inherited_injections ++ Enum.map(injection_calls, &parse_flow_injection(&1, caller, path))

    Enum.flat_map(rule_calls, fn
      {:on, _meta, [label, opts]} ->
        {opts, block} = split_do!(opts)
        [flow_rule(label, path, opts, block, caller, injections, flow_opts)]

      {:on, _meta, [label, opts, [do: block]]} ->
        [flow_rule(label, path, opts, block, caller, injections, flow_opts)]

      {:flow, _meta, [name, opts]} when is_atom(name) ->
        {opts, nested_block} = split_do!(opts)
        nested_opts = Keyword.merge(flow_opts, eval_opts(opts, caller))
        parse_flow_rules(path ++ [name], nested_opts, nested_block, caller, injections)

      {:flow, _meta, [name, opts, [do: nested_block]]} when is_atom(name) ->
        nested_opts = Keyword.merge(flow_opts, eval_opts(opts, caller))
        parse_flow_rules(path ++ [name], nested_opts, nested_block, caller, injections)

      other ->
        raise ArgumentError, "invalid flow declaration: #{Macro.to_string(other)}"
    end)
  end

  @spec flow_rule(
          atom(),
          [atom()],
          Macro.t(),
          Macro.t(),
          Macro.Env.t(),
          [Operation.t()],
          keyword()
        ) ::
          map()
  defp flow_rule(label, path, opts, block, caller, injections, flow_opts) do
    label
    |> build_rule(path, opts, block, caller, global?: false)
    |> Map.put(:injections, injections)
    |> Map.put(:flow_opts, flow_opts)
  end

  @spec injection_call?(Macro.t()) :: boolean()
  defp injection_call?({:inject, _meta, _args}), do: true
  defp injection_call?(_call), do: false

  @spec parse_flow_injection(Macro.t(), Macro.Env.t(), [atom()]) :: Operation.t()
  defp parse_flow_injection({:inject, meta, [id]}, caller, path) do
    operation_opts = [source_line: Keyword.get(meta, :line, caller.line)]
    Operation.new(Macro.expand(id, caller), operation_opts, {:flow_path, path})
  end

  defp parse_flow_injection({:inject, meta, [id, opts]}, caller, path) do
    operation_opts =
      opts
      |> eval_opts(caller)
      |> Keyword.put_new(:source_line, Keyword.get(meta, :line, caller.line))

    Operation.new(Macro.expand(id, caller), operation_opts, {:flow_path, path})
  end

  @spec parse_policy(atom(), Macro.t(), Macro.Env.t()) :: map()
  defp parse_policy(name, block, caller) do
    base = %{
      name: name,
      request: nil,
      accepts: [],
      rejects: [],
      otherwise: nil,
      max_attempts: nil,
      then: nil
    }

    block
    |> calls()
    |> Enum.reduce(base, fn
      {:request, _meta, [prompt]}, acc ->
        %{acc | request: prompt}

      {:accept, _meta, [label, opts]}, acc ->
        %{acc | accepts: acc.accepts ++ [policy_branch(label, opts, caller)]}

      {:reject, _meta, [label, opts]}, acc ->
        %{acc | rejects: acc.rejects ++ [policy_branch(label, opts, caller)]}

      {:otherwise, _meta, [opts]}, acc ->
        opts = eval_opts(opts, caller)
        %{acc | otherwise: {:ask, Keyword.fetch!(opts, :ask)}}

      {:attempts, _meta, [max, opts]}, acc ->
        opts = eval_opts(opts, caller)
        %{acc | max_attempts: max, then: Keyword.get(opts, :then)}

      other, _acc ->
        raise ArgumentError, "invalid policy declaration: #{Macro.to_string(other)}"
    end)
  end

  @spec policy_branch(atom(), Macro.t(), Macro.Env.t()) :: map()
  defp policy_branch(label, opts_ast, caller) do
    opts = eval_opts(opts_ast, caller)
    reject_training_opts!(opts)

    %{
      label: label,
      regex: List.wrap(Keyword.get(opts, :regex, []))
    }
  end

  @spec build_rule(atom(), [atom()], Macro.t(), Macro.t(), Macro.Env.t(), keyword()) :: map()
  defp build_rule(label, flow_path, opts_ast, block, caller, extra) do
    opts = eval_opts(opts_ast, caller)
    reject_training_opts!(opts)

    %{
      label: label,
      flow: List.last(flow_path),
      flow_path: flow_path,
      handler: parse_handler(block, caller),
      regex: List.wrap(Keyword.get(opts, :regex, [])),
      bag: examples_from_opts(opts, :bag),
      jaro: examples_from_opts(opts, :jaro),
      embedding: examples_from_opts(opts, :embedding),
      cache: cache_enabled?(opts),
      learn: Keyword.get(opts, :learn, false),
      checks: rule_checks(opts),
      via: route_via(opts),
      global?: Keyword.fetch!(extra, :global?),
      injections: [],
      opts:
        Keyword.drop(opts, [
          :regex,
          :bag,
          :jaro,
          :embedding,
          :train,
          :training,
          :cache,
          :learn,
          :check,
          :checks,
          :via
        ])
    }
  end

  @spec examples_from_opts(keyword(), atom()) :: [term()]
  defp examples_from_opts(opts, key) do
    opts
    |> Keyword.get(key, [])
    |> case do
      examples when is_list(examples) ->
        Keyword.get(examples, :examples, examples)

      example ->
        List.wrap(example)
    end
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_handler(Macro.t(), Macro.Env.t()) :: Spectre.Rule.handler()
  defp parse_handler({:ask, _meta, [prompt]}, _caller), do: {:ask, prompt, []}

  defp parse_handler({:ask, _meta, [prompt, opts]}, caller),
    do: {:ask, prompt, eval_opts(opts, caller)}

  defp parse_handler({:reason, _meta, [prompt]}, _caller), do: {:reason, prompt, []}

  defp parse_handler({:reason, _meta, [prompt, opts]}, caller),
    do: {:reason, prompt, eval_opts(opts, caller)}

  defp parse_handler({:act, _meta, [prompt]}, _caller), do: {:act, prompt, []}

  defp parse_handler({:act, _meta, [prompt, opts]}, caller),
    do: {:act, prompt, eval_opts(opts, caller)}

  defp parse_handler({:run, _meta, [function]}, _caller), do: {:run, function, []}

  defp parse_handler({:run, _meta, [function, opts]}, caller),
    do: {:run, function, eval_opts(opts, caller)}

  defp parse_handler({:reply, _meta, [prompt]}, _caller), do: {:reply, prompt, []}

  defp parse_handler({:reply, _meta, [prompt, opts]}, caller),
    do: {:reply, prompt, eval_opts(opts, caller)}

  defp parse_handler({:work, _meta, [controller]}, caller),
    do: {:work, Macro.expand(controller, caller), []}

  defp parse_handler({:work, _meta, [controller, opts]}, caller),
    do: {:work, Macro.expand(controller, caller), eval_opts(opts, caller)}

  defp parse_handler({:action, _meta, [action]}, caller),
    do: {:action, eval_action_arg(action, caller), []}

  defp parse_handler({:action, _meta, [action, [do: block]]}, caller) do
    action = eval_action_arg(action, caller)
    {:action, action, parse_action_block(action, block, caller)}
  end

  defp parse_handler({:action, _meta, [action, opts, [do: block]]}, caller) do
    action = eval_action_arg(action, caller)

    opts =
      opts
      |> eval_opts(caller)
      |> Keyword.merge(parse_action_block(action, block, caller))

    {:action, action, opts}
  end

  defp parse_handler({:action, _meta, [action, opts]}, caller),
    do: {:action, eval_action_arg(action, caller), eval_opts(opts, caller)}

  defp parse_handler({:call_operation, _meta, [operation]}, caller),
    do: {:operation, eval_action_arg(operation, caller), []}

  defp parse_handler({:call_operation, _meta, [operation, opts]}, caller),
    do: {:operation, eval_action_arg(operation, caller), eval_opts(opts, caller)}

  defp parse_handler({:__block__, _meta, [one]}, caller), do: parse_handler(one, caller)

  defp parse_handler(other, caller) do
    case Extension.expand_handler(caller.module, other, caller) do
      {:ok, expanded} when expanded != other ->
        parse_handler(expanded, caller)

      {:ok, ^other} ->
        raise ArgumentError,
              "Spectre extension returned the unchanged handler: #{Macro.to_string(other)}"

      :ignore ->
        case Macro.expand_once(other, caller) do
          ^other ->
            raise ArgumentError,
                  "expected ask/run/reply/action handler, call_operation, or reason/act/work handler, got: #{Macro.to_string(other)}"

          expanded ->
            parse_handler(expanded, caller)
        end
    end
  end

  @spec reject_training_opts!(keyword()) :: :ok
  defp reject_training_opts!(opts) do
    cond do
      Keyword.has_key?(opts, :train) ->
        raise ArgumentError, "train: is not supported; keep examples in labeled dataset files"

      Keyword.has_key?(opts, :training) ->
        raise ArgumentError, "training: is not supported; keep examples in labeled dataset files"

      true ->
        :ok
    end
  end

  @spec cache_enabled?(keyword()) :: boolean()
  defp cache_enabled?(opts) do
    case Keyword.get(opts, :cache, true) do
      value when value in [true, false] ->
        value

      value ->
        raise ArgumentError, "cache: accepts only true or false, got: #{inspect(value)}"
    end
  end

  @spec route_via(keyword()) :: [atom()]
  defp route_via(opts) do
    List.wrap(Keyword.get(opts, :via, []))
  end

  @spec rule_checks(keyword()) :: [term()]
  defp rule_checks(opts) do
    []
    |> Kernel.++(List.wrap(Keyword.get(opts, :check, [])))
    |> Kernel.++(List.wrap(Keyword.get(opts, :checks, [])))
  end

  @spec parse_action_block(Spectre.Action.ref(), Macro.t(), Macro.Env.t()) :: keyword()
  defp parse_action_block(action, block, caller) do
    block
    |> calls()
    |> Enum.reduce([], fn
      {:reply, _meta, [prompt]}, acc ->
        Keyword.put(acc, :reply, prompt)

      {:reply, _meta, [prompt, opts]}, acc ->
        opts = eval_opts(opts, caller)
        acc |> Keyword.put(:reply, prompt) |> Keyword.merge(opts)

      {:after_action, _meta, [opts]}, acc ->
        hook = opts |> eval_opts(caller) |> then(&after_action_hook(action, &1))
        Keyword.update(acc, :hooks, [hook], &[hook | &1])

      {:after_action, _meta, [hook_action, opts]}, acc ->
        hook_action = eval_action_arg(hook_action, caller)
        hook = opts |> eval_opts(caller) |> then(&after_action_hook(hook_action, &1))
        Keyword.update(acc, :hooks, [hook], &[hook | &1])

      other, _acc ->
        raise ArgumentError, "invalid action declaration: #{Macro.to_string(other)}"
    end)
  end

  @spec parse_actions_config_block(Macro.t(), Macro.Env.t()) :: %{
          protections: [map()],
          after_actions: [map()]
        }
  defp parse_actions_config_block(block, caller) do
    block
    |> calls()
    |> Enum.reduce(%{protections: [], after_actions: []}, fn
      {:protect, _meta, [action_or_opts]}, acc ->
        protection = protection_from_ast(action_or_opts, [], caller)
        %{acc | protections: acc.protections ++ [protection]}

      {:protect, _meta, [action_or_opts, opts]}, acc ->
        protection = protection_from_ast(action_or_opts, opts, caller)
        %{acc | protections: acc.protections ++ [protection]}

      {:after_action, _meta, [action, opts]}, acc ->
        hook = after_action_hook(eval_action_arg(action, caller), eval_opts(opts, caller))
        %{acc | after_actions: acc.after_actions ++ [hook]}

      other, _acc ->
        raise ArgumentError, "invalid actions declaration: #{Macro.to_string(other)}"
    end)
  end

  @spec protection_from_ast(Macro.t(), Macro.t() | keyword(), Macro.Env.t()) :: map()
  defp protection_from_ast(action_or_opts, opts, caller) do
    action_or_opts = eval_action_arg(action_or_opts, caller)
    opts = eval_opts(opts, caller)
    {action, opts} = normalize_protect_args(action_or_opts, opts)
    build_protection(action, opts)
  end

  @spec build_protection(term(), keyword()) :: map()
  defp build_protection(action, opts) do
    resolver = Keyword.get(opts, :resolver, :conversation)
    protection = %{action: action, policy: Keyword.fetch!(opts, :with)}

    # Omitting the established default keeps existing compiled Definitions and
    # their canonical digests byte-for-byte stable.
    if resolver == :conversation,
      do: protection,
      else: Map.put(protection, :resolver, resolver)
  end

  @spec parse_input_pipeline(Macro.t(), Macro.Env.t()) :: [module() | {module(), keyword()}]
  defp parse_input_pipeline(block, caller) do
    block
    |> calls()
    |> Enum.map(fn
      {:plug, _meta, [module]} ->
        Macro.expand(module, caller)

      {:plug, _meta, [module, opts]} ->
        {Macro.expand(module, caller), eval_opts(opts, caller)}

      other ->
        raise ArgumentError, "invalid input pipeline declaration: #{Macro.to_string(other)}"
    end)
  end

  @spec after_action_hook(term(), keyword()) :: map()
  defp after_action_hook(action, opts) when is_list(opts) do
    %{
      action: action,
      on: Keyword.fetch!(opts, :on),
      run: Keyword.fetch!(opts, :run),
      opts: Keyword.drop(opts, [:on, :run])
    }
  end

  @spec before_action_guard(term(), keyword()) :: map()
  defp before_action_guard(action, opts) when is_list(opts) do
    %{
      action: action,
      run: Keyword.fetch!(opts, :run),
      opts: Keyword.drop(opts, [:run])
    }
  end

  @spec split_do!(term()) :: {keyword(), Macro.t()} | no_return()
  defp split_do!(opts_ast) when is_list(opts_ast) do
    {block, opts} = Keyword.pop(opts_ast, :do)

    if is_nil(block) do
      raise ArgumentError, "expected do block"
    end

    {opts, block}
  end

  defp split_do!(other),
    do: raise(ArgumentError, "expected keyword options with do block, got: #{inspect(other)}")

  @spec calls(Macro.t()) :: [Macro.t()]
  defp calls({:__block__, _meta, calls}), do: calls
  defp calls(one), do: [one]

  @spec eval_action_arg(term(), Macro.Env.t()) :: term()
  defp eval_action_arg(arg, caller) do
    expanded = Macro.prewalk(arg, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(expanded, [], caller)
    value
  end

  @spec eval_opts(term(), Macro.Env.t()) :: term()
  defp eval_opts(opts, caller) when is_list(opts) do
    opts = Macro.prewalk(opts, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(opts, [], caller)
    value
  end

  defp eval_opts(opts, caller), do: Macro.expand(opts, caller)

  @spec reverse_attribute(list() | nil) :: list()
  defp reverse_attribute(nil), do: []
  defp reverse_attribute(values), do: Enum.reverse(values)

  @spec normalize_protect_args(term(), keyword()) :: {term(), keyword()}
  defp normalize_protect_args(action_or_opts, []) when is_list(action_or_opts) do
    {with, rest} = Keyword.pop(action_or_opts, :with)
    {resolver, rest} = Keyword.pop(rest, :resolver, :conversation)

    action =
      cond do
        Keyword.has_key?(rest, :al) -> {:al, Keyword.fetch!(rest, :al)}
        Keyword.has_key?(rest, :function) -> {:function, Keyword.fetch!(rest, :function)}
        true -> rest
      end

    {action, [with: with, resolver: resolver]}
  end

  defp normalize_protect_args(action, opts), do: {action, opts}
end
