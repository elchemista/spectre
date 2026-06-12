defmodule Spectre.Agent do
  @moduledoc """
  Small DSL for declaring Spectre agents.

      defmodule MyApp.ProjectAgent do
        use Spectre.Agent, prompt_root: "priv/agents/project/prompts"

        complete MyApp.LLM
        actions MyApp.ProjectActions
        state MyApp.AgentStateStore
        memory MyApp.AgentMemory
        shutdown 600_000

        router via: [:regex, :semantic_cache, :classifier, :llm]

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
    quote bind_quoted: [opts: opts] do
      import Spectre.Agent

      Module.register_attribute(__MODULE__, :spectre_config, persist: false)
      Module.register_attribute(__MODULE__, :spectre_rules, accumulate: true, persist: false)
      Module.register_attribute(__MODULE__, :spectre_policies, accumulate: true, persist: false)

      Module.register_attribute(__MODULE__, :spectre_protections,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_router, persist: false)

      @spectre_config opts
      @spectre_router []
      @before_compile Spectre.Agent
    end
  end

  defmacro actions(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module, opts: opts] do
      @spectre_config Keyword.put(@spectre_config, :actions, {module, opts})
    end
  end

  defmacro complete(adapter, opts \\ []) do
    adapter = Macro.expand(adapter, __CALLER__)
    opts = eval_opts(opts, __CALLER__)
    function = Keyword.get(opts, :function, Keyword.get(opts, :with, :complete))
    complete = {adapter, function, Keyword.drop(opts, [:function, :with])}

    quote do
      @spectre_config Keyword.put(@spectre_config, :complete, unquote(Macro.escape(complete)))
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

  defmacro router(opts) do
    quote bind_quoted: [opts: opts] do
      @spectre_router opts
    end
  end

  defmacro protect(action_or_opts, opts \\ []) do
    {action, opts} = normalize_protect_args(action_or_opts, opts)
    protection = %{action: action, policy: Keyword.fetch!(opts, :with)}

    quote do
      @spectre_protections unquote(Macro.escape(protection))
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
      protections: Module.get_attribute(module, :spectre_protections) || []
    }
  end

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
      training: List.wrap(Keyword.get(opts, :train, Keyword.get(opts, :training, [])))
    }
  end

  defp build_rule(label, flow, opts_ast, block, caller, extra) do
    opts = eval_opts(opts_ast, caller)

    %{
      label: label,
      flow: flow,
      handler: parse_handler(block, caller),
      regex: List.wrap(Keyword.get(opts, :regex, [])),
      training: List.wrap(Keyword.get(opts, :train, Keyword.get(opts, :training, []))),
      via: List.wrap(Keyword.get(opts, :via, [])),
      global?: Keyword.fetch!(extra, :global?),
      opts: Keyword.drop(opts, [:regex, :train, :training, :via])
    }
  end

  defp parse_handler({:ask, _meta, [prompt]}, _caller), do: {:ask, prompt, []}

  defp parse_handler({:ask, _meta, [prompt, opts]}, caller),
    do: {:ask, prompt, eval_opts(opts, caller)}

  defp parse_handler({:run, _meta, [function]}, _caller), do: {:run, function, []}

  defp parse_handler({:run, _meta, [function, opts]}, caller),
    do: {:run, function, eval_opts(opts, caller)}

  defp parse_handler({:__block__, _meta, [one]}, caller), do: parse_handler(one, caller)

  defp parse_handler(other, _caller) do
    raise ArgumentError, "expected ask/run handler, got: #{Macro.to_string(other)}"
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

  defp eval_opts(opts, caller) when is_list(opts) do
    {value, _binding} = Code.eval_quoted(opts, [], caller)
    value
  end

  defp eval_opts(opts, _caller), do: opts

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
