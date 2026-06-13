defmodule Spectre.Agent do
  @moduledoc """
  Small DSL for declaring Spectre agents.

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
  """

  defmacro __using__(opts) do
    opts = eval_opts(opts, __CALLER__)
    config = default_config(opts)
    router = default_router(opts)

    quote bind_quoted: [config: config, router: router] do
      import Spectre.Agent

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

  defmacro model(adapter, opts \\ []) do
    adapter = Macro.expand(adapter, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    function = Keyword.get(opts, :function, Keyword.get(opts, :with, :complete))
    model = {adapter, function, Keyword.drop(opts, [:function, :with])}

    quote do
      @spectre_config Keyword.put(@spectre_config, :model, unquote(Macro.escape(model)))
    end
  end

  defmacro state(module) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module] do
      @spectre_config Keyword.put(@spectre_config, :state, module)
    end
  end

  defmacro memory(module) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module] do
      @spectre_config Keyword.put(@spectre_config, :memory, module)
    end
  end

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

  defmacro shutdown(timeout) do
    quote bind_quoted: [timeout: timeout] do
      @spectre_config Keyword.put(@spectre_config, :shutdown, timeout)
    end
  end

  defmacro idle(timeout) do
    quote bind_quoted: [timeout: timeout] do
      @spectre_config Keyword.put(@spectre_config, :idle, timeout)
    end
  end

  defmacro history(limit) do
    quote bind_quoted: [limit: limit] do
      @spectre_config Keyword.put(@spectre_config, :history, limit)
    end
  end

  defmacro fail(prompt, opts \\ []) do
    prompt = Macro.expand(prompt, __CALLER__)
    opts = eval_opts(opts, __CALLER__)

    quote bind_quoted: [prompt: prompt, opts: opts] do
      @spectre_config Keyword.put(@spectre_config, :fail, {prompt, opts})
    end
  end

  defmacro router(opts) do
    quote bind_quoted: [opts: opts] do
      @spectre_router Keyword.merge(@spectre_router, opts)
    end
  end

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

  defmacro protect(action_or_opts, opts \\ []) do
    {action, opts} = normalize_protect_args(action_or_opts, opts)
    protection = %{action: action, policy: Keyword.fetch!(opts, :with)}

    quote do
      @spectre_protections unquote(Macro.escape(protection))
    end
  end

  defmacro after_action(action, opts) do
    opts = eval_opts(opts, __CALLER__)
    hook = after_action_hook(action, opts)

    quote do
      @spectre_after_actions unquote(Macro.escape(hook))
    end
  end

  defmacro flow(name, do: block) do
    rules = parse_flow_rules(name, block, __CALLER__)

    quote do
      unquote(Macro.escape(rules))
      |> Enum.each(&Module.put_attribute(__MODULE__, :spectre_rules, &1))
    end
  end

  defmacro interrupt(label, opts, do: block) do
    rule = build_rule(label, nil, opts, block, __CALLER__, global?: true)

    quote do
      @spectre_rules unquote(Macro.escape(rule))
    end
  end

  defmacro interrupt(label, opts) do
    {opts, block} = split_do!(opts)
    rule = build_rule(label, nil, opts, block, __CALLER__, global?: true)

    quote do
      @spectre_rules unquote(Macro.escape(rule))
    end
  end

  defmacro policy(name, do: block) do
    policy = parse_policy(name, block, __CALLER__)

    quote do
      @spectre_policies unquote(Macro.escape(policy))
    end
  end

  defmacro ask(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :ask, unquote(prompt), unquote(opts)}
    end
  end

  defmacro run(function, opts \\ []) do
    quote do
      {:__spectre_handler__, :run, unquote(function), unquote(opts)}
    end
  end

  defmacro reply(prompt, opts \\ []) do
    quote do
      {:__spectre_handler__, :reply, unquote(prompt), unquote(opts)}
    end
  end

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

  defp normalize_fail({prompt, fail_opts}) when is_list(fail_opts), do: {prompt, fail_opts}
  defp normalize_fail(prompt), do: {prompt, []}

  defp normalize_arbitrator({module, arbitrator_opts})
       when is_atom(module) and is_list(arbitrator_opts) do
    {module, arbitrator_opts}
  end

  defp normalize_arbitrator(module) when is_atom(module), do: {module, []}

  @spec policy_map([map()] | nil) :: map()
  defp policy_map(nil), do: %{}

  defp policy_map(policies) do
    policies
    |> Enum.reverse()
    |> Map.new(fn policy -> {policy.name, policy} end)
  end

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

  defp policy_branch(label, opts_ast, caller) do
    opts = eval_opts(opts_ast, caller)

    %{
      label: label,
      regex: List.wrap(Keyword.get(opts, :regex, [])),
      training: training_entries(opts)
    }
  end

  defp build_rule(label, flow, opts_ast, block, caller, extra) do
    opts = eval_opts(opts_ast, caller)

    %{
      label: label,
      flow: flow,
      handler: parse_handler(block, caller),
      regex: List.wrap(Keyword.get(opts, :regex, [])),
      bag: examples_from_opts(opts, :bag),
      jaro: examples_from_opts(opts, :jaro),
      embedding: examples_from_opts(opts, :embedding),
      training: training_entries(opts),
      checks: rule_checks(opts),
      via: List.wrap(Keyword.get(opts, :via, [])),
      global?: Keyword.fetch!(extra, :global?),
      opts:
        Keyword.drop(opts, [
          :regex,
          :bag,
          :jaro,
          :embedding,
          :train,
          :training,
          :check,
          :checks,
          :via
        ])
    }
  end

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

  defp training_entries(opts) do
    opts
    |> Keyword.get(:train, Keyword.get(opts, :training, []))
    |> normalize_training_entries()
  end

  defp normalize_training_entries(true), do: [true]
  defp normalize_training_entries(false), do: []
  defp normalize_training_entries(nil), do: []
  defp normalize_training_entries(entries) when is_list(entries), do: entries
  defp normalize_training_entries(entry), do: [entry]

  defp rule_checks(opts) do
    []
    |> Kernel.++(List.wrap(Keyword.get(opts, :check, [])))
    |> Kernel.++(List.wrap(Keyword.get(opts, :checks, [])))
  end

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

  defp protection_from_ast(action_or_opts, opts, caller) do
    action_or_opts = eval_action_arg(action_or_opts, caller)
    opts = eval_opts(opts, caller)
    {action, opts} = normalize_protect_args(action_or_opts, opts)
    %{action: action, policy: Keyword.fetch!(opts, :with)}
  end

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

  defp after_action_hook(action, opts) when is_list(opts) do
    %{
      action: action,
      on: Keyword.fetch!(opts, :on),
      run: Keyword.fetch!(opts, :run),
      opts: Keyword.drop(opts, [:on, :run])
    }
  end

  defp split_do!(opts_ast) when is_list(opts_ast) do
    {block, opts} = Keyword.pop(opts_ast, :do)

    if is_nil(block) do
      raise ArgumentError, "expected do block"
    end

    {opts, block}
  end

  defp split_do!(other),
    do: raise(ArgumentError, "expected keyword options with do block, got: #{inspect(other)}")

  defp calls({:__block__, _meta, calls}), do: calls
  defp calls(one), do: [one]

  defp eval_action_arg(arg, caller) when is_list(arg), do: eval_opts(arg, caller)
  defp eval_action_arg(arg, caller), do: Macro.expand(arg, caller)

  defp eval_opts(opts, caller) when is_list(opts) do
    opts = Macro.prewalk(opts, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(opts, [], caller)
    value
  end

  defp eval_opts(opts, caller), do: Macro.expand(opts, caller)

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
