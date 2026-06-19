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
    * `actions/2`, `state/1`, and `memory/1` keep side effects at explicit
      runtime boundaries.

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
    config = default_config(opts)
    router = default_router(opts)

    quote bind_quoted: [config: config, router: router] do
      import Spectre.Agent

      # Metadata is accumulated at compile time so runtime routing can inspect
      # a compact immutable description instead of re-evaluating DSL blocks.
      Module.register_attribute(__MODULE__, :spectre_config, persist: false)
      Module.register_attribute(__MODULE__, :spectre_rules, accumulate: true, persist: false)
      Module.register_attribute(__MODULE__, :spectre_policies, accumulate: true, persist: false)

      Module.register_attribute(__MODULE__, :spectre_after_actions,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_protections,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_router, persist: false)

      @spectre_config config
      @spectre_router router
      @before_compile Spectre.Agent
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
  """
  defmacro history(limit) do
    quote bind_quoted: [limit: limit] do
      @spectre_config Keyword.put(@spectre_config, :history, limit)
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
  dangerous action can be produced by DSL handlers or by AL extracted from an
  LLM reply, and it must still pass the same policy.

      protect :delete_account, with: :delete_account_confirmation
  """
  defmacro protect(action_or_opts, opts \\ []) do
    {action, opts} = normalize_protect_args(action_or_opts, opts)
    protection = %{action: action, policy: Keyword.fetch!(opts, :with)}

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
    opts = eval_opts(opts, __CALLER__)
    hook = after_action_hook(action, opts)

    quote do
      @spectre_after_actions unquote(Macro.escape(hook))
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
  """
  defmacro flow(name, do: block) do
    rules = parse_flow_rules(name, block, __CALLER__)

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
    rule = build_rule(label, nil, opts, block, __CALLER__, global?: true)

    quote do
      @spectre_rules unquote(Macro.escape(rule))
    end
  end

  @doc """
  Declares a global route using the compact keyword `do:` form.
  """
  defmacro interrupt(label, opts) do
    {opts, block} = split_do!(opts)
    rule = build_rule(label, nil, opts, block, __CALLER__, global?: true)

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
  Creates a handler that renders a prompt, calls the LLM, and stages AL actions.

      on :support_question do
        ask :support_answer
      end
  """
  defmacro ask(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :ask, unquote(prompt), unquote(opts)}
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

  defmacro __before_compile__(env) do
    metadata = compile_metadata(env.module)

    quote do
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
      def __spectre_prompt_root__ do
        Keyword.get(__spectre_config__(), :prompt_root, "priv/spectre/prompts")
      end
    end
  end

  @spec compile_metadata(module()) :: map()
  defp compile_metadata(module) do
    %{
      config: Module.get_attribute(module, :spectre_config) || [],
      router: Module.get_attribute(module, :spectre_router) || [],
      rules: module |> Module.get_attribute(:spectre_rules) |> Enum.reverse(),
      policies: module |> Module.get_attribute(:spectre_policies) |> policy_map(),
      after_actions: Module.get_attribute(module, :spectre_after_actions) || [],
      protections: Module.get_attribute(module, :spectre_protections) || []
    }
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
                         no_decision: :clarify
                       ]}

  @spec default_config(keyword()) :: keyword()
  defp default_config(opts) do
    opts
    |> Keyword.drop([:arbitrator])
    |> Keyword.put_new(:shutdown, @default_shutdown)
    |> Keyword.put_new(:history, @default_history)
    |> Keyword.update(:fail, @default_fail, &normalize_fail/1)
  end

  @spec default_router(keyword()) :: keyword()
  defp default_router(opts) do
    []
    |> Keyword.put(
      :arbitrator,
      normalize_arbitrator(Keyword.get(opts, :arbitrator, @default_arbitrator))
    )
  end

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
    :local,
    :classify,
    :artifact_dir,
    :local_accept_threshold,
    :local_margin_threshold,
    :local_high_confidence_threshold
  ]

  @local_classifier_keys [
    :artifact_dir,
    :local_accept_threshold,
    :local_margin_threshold,
    :local_high_confidence_threshold
  ]

  @spec normalize_classifier(module(), keyword()) :: keyword()
  defp normalize_classifier(adapter, opts) do
    function = Keyword.get(opts, :function, Keyword.get(opts, :with, :complete))

    [
      adapter: {adapter, function, Keyword.drop(opts, @classifier_config_keys)}
    ]
    |> maybe_put_classifier_option(:prompt, Keyword.get(opts, :prompt))
    |> maybe_put_classifier_option(:llm_opts, Keyword.get(opts, :llm_opts))
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
    policies
    |> Enum.reverse()
    |> Map.new(fn policy -> {policy.name, policy} end)
  end

  @spec parse_flow_rules(atom(), Macro.t(), Macro.Env.t()) :: [map()]
  defp parse_flow_rules(flow, block, caller) do
    block
    |> calls()
    |> Enum.map(fn
      {:on, _meta, [label, opts]} ->
        {opts, block} = split_do!(opts)
        build_rule(label, flow, opts, block, caller, global?: false)

      {:on, _meta, [label, opts, [do: block]]} ->
        build_rule(label, flow, opts, block, caller, global?: false)

      other ->
        raise ArgumentError, "invalid flow declaration: #{Macro.to_string(other)}"
    end)
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

  @spec build_rule(atom(), atom() | nil, Macro.t(), Macro.t(), Macro.Env.t(), keyword()) :: map()
  defp build_rule(label, flow, opts_ast, block, caller, extra) do
    opts = eval_opts(opts_ast, caller)
    reject_training_opts!(opts)

    %{
      label: label,
      flow: flow,
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

  defp parse_handler({:run, _meta, [function]}, _caller), do: {:run, function, []}

  defp parse_handler({:run, _meta, [function, opts]}, caller),
    do: {:run, function, eval_opts(opts, caller)}

  defp parse_handler({:reply, _meta, [prompt]}, _caller), do: {:reply, prompt, []}

  defp parse_handler({:reply, _meta, [prompt, opts]}, caller),
    do: {:reply, prompt, eval_opts(opts, caller)}

  defp parse_handler({:action, _meta, [action]}, _caller), do: {:action, action, []}

  defp parse_handler({:action, _meta, [action, [do: block]]}, caller),
    do: {:action, action, parse_action_block(action, block, caller)}

  defp parse_handler({:action, _meta, [action, opts, [do: block]]}, caller) do
    opts =
      opts
      |> eval_opts(caller)
      |> Keyword.merge(parse_action_block(action, block, caller))

    {:action, action, opts}
  end

  defp parse_handler({:action, _meta, [action, opts]}, caller),
    do: {:action, action, eval_opts(opts, caller)}

  defp parse_handler({:__block__, _meta, [one]}, caller), do: parse_handler(one, caller)

  defp parse_handler(other, _caller) do
    raise ArgumentError, "expected ask/run/reply/action handler, got: #{Macro.to_string(other)}"
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

  @spec parse_action_block(atom(), Macro.t(), Macro.Env.t()) :: keyword()
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
        hook = after_action_hook(Macro.expand(action, caller), eval_opts(opts, caller))
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
    %{action: action, policy: Keyword.fetch!(opts, :with)}
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
  defp eval_action_arg(arg, caller) when is_list(arg), do: eval_opts(arg, caller)
  defp eval_action_arg(arg, caller), do: Macro.expand(arg, caller)

  @spec eval_opts(term(), Macro.Env.t()) :: term()
  defp eval_opts(opts, caller) when is_list(opts) do
    opts = Macro.prewalk(opts, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(opts, [], caller)
    value
  end

  defp eval_opts(opts, caller), do: Macro.expand(opts, caller)

  @spec normalize_protect_args(term(), keyword()) :: {term(), keyword()}
  defp normalize_protect_args(action_or_opts, []) when is_list(action_or_opts) do
    {with, rest} = Keyword.pop(action_or_opts, :with)

    action =
      cond do
        Keyword.has_key?(rest, :al) -> {:al, Keyword.fetch!(rest, :al)}
        Keyword.has_key?(rest, :function) -> {:function, Keyword.fetch!(rest, :function)}
        true -> rest
      end

    {action, [with: with]}
  end

  defp normalize_protect_args(action, opts), do: {action, opts}
end
