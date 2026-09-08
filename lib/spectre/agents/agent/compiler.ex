defmodule Spectre.Agent.Compiler do
  @moduledoc false

  alias Spectre.Agent.{Declaration, DSL, Publication, RequestBuilder}
  alias Spectre.{Portable, Router}
  alias Spectre.Router.Rule

  @sections [
    :flows,
    :requests,
    :asks,
    :prompts,
    :ports,
    :settings,
    :components,
    :jobs,
    :extensions
  ]
  @reserved [:no_match, :ambiguous, :halted, :unrouted, :error]

  # One grammar and collision policy for inline declarations, extracted Routers
  # and Stack presets. This plan contains no running resource or GAM authority.
  defmacro __using__(opts) do
    quote do
      import unquote(DSL)
      unquote(__MODULE__).setup!(__MODULE__, unquote(opts), __ENV__)
      @before_compile unquote(__MODULE__)
    end
  end

  @doc false
  def setup!(module, opts, env) do
    attrs = attrs!(opts, [:kind, :namespace, :name, :stack], env)
    kind = Map.fetch!(attrs, :kind)

    if kind in [:agent, :skill, :worker, :vigil] do
      Enum.each([:namespace, :name], fn field ->
        unwrap_ok!(Portable.validate_non_empty_binary(attrs[field], field), env)
      end)
    end

    plan =
      @sections
      |> Map.new(&{&1, %{}})
      |> Map.merge(%{
        kind: kind,
        identity: Map.take(attrs, [:namespace, :name]),
        injections: []
      })

    Module.put_attribute(module, :spectre_plan, plan)
    Module.put_attribute(module, :spectre_flow, nil)
    Module.put_attribute(module, :spectre_sources, %{})
    Module.put_attribute(module, :spectre_prompt_root, File.cwd!())
    if attrs[:stack], do: merge!(module, attrs.stack, :stack, env)
  end

  @doc false
  def flow!(module, name, env) do
    name!(name, env)
    if Module.get_attribute(module, :spectre_flow), do: fail!(env, :nested_flow_not_supported)
    flow = %{local: name, pipelines: [], routing: nil, routes: %{}, injections: [], binding: %{}}
    put!(module, :flows, key(name), flow, false, env)
    Module.put_attribute(module, :spectre_flow, key(name))
  end

  @doc false
  def end_flow!(module), do: Module.put_attribute(module, :spectre_flow, nil)

  @doc false
  def router!(module, value, env) when is_atom(value), do: merge!(module, value, :router, env)

  def router!(module, opts, env) do
    attrs = attrs!(opts, [:via, :accept, :margin, :cache, :classifier], env)
    config = unwrap!(Router.configuration(Map.drop(attrs, [:cache, :classifier])), env)
    binding = Map.take(attrs, [:cache, :classifier])
    Enum.each(Map.values(binding), &name!(&1, env))

    update_flow!(module, env, fn flow ->
      if flow.routing, do: fail!(env, :duplicate_router_configuration)
      %{flow | routing: config, binding: binding}
    end)
  end

  @doc false
  def route!(module, name, opts, env) do
    name!(name, env)
    if name in @reserved, do: fail!(env, {:reserved_route_name, name})
    attrs = attrs!(opts, [:match, :cache, :classify, :inject], env)
    match = Map.get(attrs, :match, [])
    unless is_map(match) or Portable.keyword?(match), do: fail!(env, :invalid_route_match)
    match = Map.new(match)

    match =
      Enum.reduce(
        [cache: :semantic_cache, classify: :local_classifier, classify: :llm_classifier],
        match,
        fn {flag, method}, acc ->
          enabled = Map.get(attrs, flag, false)
          unless is_boolean(enabled), do: fail!(env, {:invalid_route_flag, flag})
          if Map.has_key?(acc, method), do: fail!(env, {:reserved_matcher_configuration, method})
          if enabled, do: Map.put(acc, method, true), else: acc
        end
      )

    rule = unwrap!(Rule.new(key(name), to: key(name), match: match), env)
    injections = if attrs[:inject], do: [injection!(attrs.inject, [], env)], else: []
    source!(module, {:route, Module.get_attribute(module, :spectre_flow), key(name)}, env, nil)

    update_flow!(module, env, fn flow ->
      if Map.has_key?(flow.routes, key(name)), do: fail!(env, {:duplicate_route, name})
      entry = %{local: name, rule: Rule.canonical(rule), injections: injections}
      %{flow | routes: Map.put(flow.routes, key(name), entry)}
    end)
  end

  @doc false
  def pipelines!(module, names, env) do
    names = List.wrap(names)
    Enum.each(names, &name!(&1, env))
    names = Enum.map(names, &key/1)
    unwrap_ok!(Declaration.pipeline_names(names), env)

    update_flow!(module, env, fn flow ->
      if flow.pipelines != [], do: fail!(env, :duplicate_flow_pipeline_configuration)
      %{flow | pipelines: names}
    end)
  end

  @doc false
  def prompt_root!(module, path, _env) when is_binary(path),
    do: Module.put_attribute(module, :spectre_prompt_root, Path.expand(path, File.cwd!()))

  def prompt_root!(_module, _path, env), do: fail!(env, :invalid_prompt_root)

  @doc false
  def prompt!(module, name, value, env) do
    root!(module, env)
    name!(name, env)
    {text, file} = prompt_source!(module, value, env)
    unwrap_ok!(Portable.validate(text), env)
    if byte_size(text) > 65_536, do: fail!(env, {:prompt_too_large, name})
    put!(module, :prompts, key(name), %{text: text, file: file}, false, env)
  end

  @doc false
  def inject!(module, name, opts, env) do
    entry = injection!(name, opts, env)

    case Module.get_attribute(module, :spectre_flow) do
      nil -> update!(module, &%{&1 | injections: &1.injections ++ [entry]})
      _flow -> update_flow!(module, env, &%{&1 | injections: &1.injections ++ [entry]})
    end
  end

  @doc false
  def request!(module, name, opts, env) do
    root!(module, env)
    name!(name, env)

    put!(
      module,
      :requests,
      key(name),
      unwrap!(RequestBuilder.template(opts), env),
      false,
      env
    )
  end

  @doc false
  def declaration!(module, kind, name, opts, env) do
    root!(module, env)
    name!(name, env)
    unless Portable.keyword?(opts), do: fail!(env, {:invalid_declaration_options, kind})
    {override, opts} = Keyword.pop(opts, :override, false)
    unless is_boolean(override), do: fail!(env, :invalid_override)
    unwrap_ok!(Portable.validate(opts), env)

    if kind == :semantic_cache do
      attrs = attrs!(opts, [:learn], env)

      unless Map.get(attrs, :learn, false) in [false, :review],
        do: fail!(env, :invalid_cache_learning_policy)
    end

    if kind == :ask do
      put!(module, :asks, key(name), Map.new(opts), override, env)
    else
      put!(module, :settings, key(kind) <> "/" <> key(name), Map.new(opts), override, env)

      if opts[:adapter],
        do:
          adapter!(
            module,
            kind,
            name,
            opts[:adapter],
            Keyword.drop(opts, [:adapter, :keep, :max_bytes, :limit]) ++ [override: override],
            env
          )
    end
  end

  @doc false
  def adapter!(module, kind, name, adapter, opts, env) do
    root!(module, env)
    Enum.each([kind, name], &name!(&1, env))

    unless is_atom(adapter) and adapter not in [nil, true, false],
      do: fail!(env, :invalid_adapter_module)

    unless Portable.keyword?(opts), do: fail!(env, :invalid_adapter_options)
    {override, opts} = Keyword.pop(opts, :override, false)
    unwrap_ok!(Portable.validate(opts), env)
    port = %{kind: kind, module: adapter, options: opts, origin: module}
    put!(module, :ports, key(kind) <> "/" <> key(name), port, override, env)
  end

  @doc false
  def skill!(module, component, opts, env) do
    attrs = attrs!(opts, [:as], env)
    component!(module, :skill, attrs[:as], component, env)
  end

  @doc false
  def component!(module, kind, name, component, env) do
    root!(module, env)
    name!(name, env)
    child = plan!(component, kind, env)
    section = if kind == :skill, do: :components, else: :jobs
    put!(module, section, key(name), %{kind: kind, module: component, plan: child}, false, env)
  end

  @doc false
  def merge!(module, source, kind, env) do
    root!(module, env)
    source_plan = plan!(source, kind, env)

    sources =
      Map.merge(source.__spectre_sources__(), Module.get_attribute(module, :spectre_sources))

    Module.put_attribute(module, :spectre_sources, sources)

    for section <- @sections,
        {name, value} <- source_plan[section],
        do: put!(module, section, name, value, false, env, source)

    update!(module, &%{&1 | injections: &1.injections ++ source_plan.injections})
  end

  @doc false
  def extension!(module, extension, options, env) do
    root!(module, env)
    unless Portable.keyword?(options), do: fail!(env, :invalid_extension_options)
    unwrap_ok!(Portable.validate(options), env)

    case Code.ensure_compiled(extension) do
      {:module, ^extension} -> :ok
      _error -> fail!(env, {:extension_unavailable, extension})
    end

    # Track the actual package, not only this generic invoker. Recompiling an
    # Extension must rebuild its consumers just like changing an inline block.
    Macro.compile_apply(extension, :__info__, [:module], env)
    attrs = unwrap!(Spectre.Extension.configure(extension, options), env)
    put!(module, :extensions, Atom.to_string(extension), attrs[:data], false, env)

    Enum.each(Map.get(attrs, :ports, %{}), fn
      {{kind, name}, {adapter, opts}} -> adapter!(module, kind, name, adapter, opts, env)
      _invalid -> fail!(env, :invalid_extension_port)
    end)
  end

  @doc false
  defmacro __before_compile__(env) do
    plan = Module.get_attribute(env.module, :spectre_plan)
    sources = Module.get_attribute(env.module, :spectre_sources)
    # Paths are build inputs, not durable prompt identities.
    renderers = Enum.map(plan.prompts, &renderer(&1, env))

    plan = %{
      plan
      | prompts: Map.new(plan.prompts, fn {name, p} -> {name, Map.delete(p, :file)} end)
    }

    if plan.kind in [:agent, :skill, :worker, :vigil], do: validate_prompts!(plan, env)

    quote do
      @doc false
      def __spectre_plan__, do: unquote(Macro.escape(plan))
      @doc false
      def __spectre_sources__, do: unquote(Macro.escape(sources))
      unquote_splicing(renderers)
      @doc false
      def __spectre_render__(name, _assigns), do: {:error, {:unknown_prompt, name}}
      @doc "Returns named adapter declarations without starting host resources."
      @spec ports() :: map()
      def ports, do: unquote(Publication).ports(__MODULE__)

      unquote(
        if plan.kind in [:agent, :skill, :worker, :vigil] do
          quote do
            @doc "Builds an immutable Definition from explicit revision/time and component bindings."
            @spec definition(keyword()) :: Spectre.Definition.t()
            def definition(opts), do: unquote(Publication).definition!(__MODULE__, opts)
          end
        end
      )
    end
  end

  defp renderer({name, %{text: text} = prompt}, env) do
    ast = EEx.compile_string(text, engine: EEx.SmartEngine, file: prompt[:file] || env.file)
    assigns = prompt_assigns(ast)

    quote do
      @doc false
      def __spectre_render__(unquote(name), var!(assigns)) do
        # EEx's default exception includes the entire map. Report only the
        # declared missing key, never the caller's private context.
        case Enum.find(unquote(assigns), &(not Map.has_key?(var!(assigns), &1))) do
          nil -> unquote(ast)
          key -> {:error, {:missing_prompt_assign, unquote(name), key}}
        end
      end
    end
  end

  defp prompt_assigns(ast) do
    {_ast, assigns} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:EEx, :Engine]}, :fetch_assign!]}, _, [_assigns, name]} =
            node,
        found
        when is_atom(name) ->
          {node, [name | found]}

        node, found ->
          {node, found}
      end)

    Enum.uniq(assigns)
  end

  defp validate_prompts!(plan, env) do
    injections =
      plan.injections ++
        Enum.flat_map(plan.flows, fn {_name, flow} ->
          flow.injections ++ Enum.flat_map(flow.routes, fn {_name, route} -> route.injections end)
        end)

    names =
      Enum.flat_map(plan.asks, fn {_name, ask} ->
        Enum.reject([ask[:prompt], ask[:task]], &is_nil/1)
      end)

    names =
      names ++
        Enum.flat_map(injections, &Enum.reject([&1.prompt, &1.into], fn n -> is_nil(n) end))

    Enum.each(names, fn name ->
      unless Map.has_key?(plan.prompts, key(name)), do: fail!(env, {:unknown_prompt, name})
    end)
  end

  defp injection!(name, opts, env) do
    name!(name, env)
    attrs = attrs!(opts, [:into, :position], env)
    if attrs[:into], do: name!(attrs.into, env)
    position = Map.get(attrs, :position, :end)
    unless position in [:start, :end], do: fail!(env, :invalid_injection_position)
    %{prompt: name, into: attrs[:into], position: position}
  end

  defp prompt_source!(_module, text, _env) when is_binary(text), do: {text, nil}

  defp prompt_source!(module, value, env) do
    attrs = attrs!(value, [:file], env)
    root = Module.get_attribute(module, :spectre_prompt_root)
    file = attrs[:file]

    unless is_binary(file) and String.ends_with?(file, [".text.eex", ".txt.eex"]),
      do: fail!(env, :prompt_requires_eex_file)

    path = Path.expand(file, root)
    unless String.starts_with?(path, root <> "/"), do: fail!(env, :prompt_outside_root)

    case File.read(path) do
      {:ok, text} ->
        Module.put_attribute(module, :external_resource, path)
        {text, path}

      {:error, reason} ->
        fail!(env, {:prompt_file, file, reason})
    end
  end

  defp put!(module, section, name, value, override, env, inherited \\ nil) do
    update!(module, fn plan ->
      existing = Map.get(plan[section], name)
      origins = Module.get_attribute(module, :spectre_inherited) || %{}
      source = Map.get(origins, {section, name})

      cond do
        existing && not (override === true and not is_nil(source)) ->
          fail!(env, {:duplicate_declaration, section, name})

        override === true and is_nil(source) ->
          fail!(env, {:nothing_to_override, section, name})

        true ->
          :ok
      end

      origins =
        if inherited,
          do: Map.put(origins, {section, name}, inherited),
          else: Map.delete(origins, {section, name})

      Module.put_attribute(module, :spectre_inherited, origins)
      source!(module, {section, name}, env, inherited)
      Map.update!(plan, section, &Map.put(&1, name, value))
    end)
  end

  defp source!(module, key, env, inherited) do
    source = %{module: env.module, file: Path.relative_to_cwd(env.file), line: env.line}

    source =
      if not is_nil(inherited) and function_exported?(inherited, :__spectre_sources__, 0),
        do: Map.get(inherited.__spectre_sources__(), key, source),
        else: source

    sources = Module.get_attribute(module, :spectre_sources) || %{}
    Module.put_attribute(module, :spectre_sources, Map.put(sources, key, source))
  end

  defp update_flow!(module, env, update) do
    case Module.get_attribute(module, :spectre_flow) do
      nil ->
        fail!(env, :declaration_requires_flow)

      name ->
        update!(
          module,
          &Map.update!(&1, :flows, fn flows -> Map.update!(flows, name, update) end)
        )
    end
  end

  defp update!(module, update),
    do:
      Module.put_attribute(
        module,
        :spectre_plan,
        update.(Module.get_attribute(module, :spectre_plan))
      )

  defp root!(module, env) do
    if Module.get_attribute(module, :spectre_flow), do: fail!(env, :declaration_requires_root)
  end

  defp plan!(module, kind, env) do
    with true <- is_atom(module) and module not in [nil, true, false],
         {:module, ^module} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :__spectre_plan__, 0),
         %{kind: ^kind} = plan <- Macro.compile_apply(module, :__spectre_plan__, [], env) do
      plan
    else
      _invalid -> fail!(env, {:invalid_authoring_component, kind, module})
    end
  end

  defp attrs!(value, allowed, env),
    do: unwrap!(Portable.normalize_attrs(value, allowed, :authoring), env)

  # '/' belongs to mounted paths, not local names. Otherwise a root flow
  # :"orders/lookup" could overwrite Skill :orders' :lookup during flattening.
  defp name!(name, env) when is_atom(name) and name not in [nil, true, false],
    do: unwrap_ok!(Rule.local_name(Atom.to_string(name)), env)

  defp name!(name, env), do: fail!(env, {:local_name_must_be_atom, name})
  defp key(name) when is_atom(name), do: Atom.to_string(name)
  defp key(name) when is_binary(name), do: name
  defp unwrap!({:ok, value}, _env), do: value
  defp unwrap!({:error, reason}, env), do: fail!(env, reason)
  defp unwrap_ok!(:ok, _env), do: :ok
  defp unwrap_ok!({:error, reason}, env), do: fail!(env, reason)

  defp fail!(env, reason),
    do:
      raise(CompileError,
        file: env.file,
        line: env.line,
        description: "invalid Spectre declaration: #{inspect(reason)}"
      )
end
