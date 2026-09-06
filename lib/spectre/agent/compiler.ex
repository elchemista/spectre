defmodule Spectre.Agent.Compiler do
  @moduledoc false

  alias Spectre.Agent.Declaration
  alias Spectre.Candidate.Template
  alias Spectre.{Definition, Extension, Portable, Router}
  alias Spectre.Router.Rule

  def candidate!(module, name, attrs, env) do
    case local_name(name) do
      :ok -> put_template!(module, name, attrs, env)
      {:error, reason} -> fail!(env, reason)
    end
  end

  def install!(module, component, opts, env) do
    with {:ok, %{as: prefix}} <- Portable.normalize_attrs(opts, [:as], :skill_install),
         :ok <- local_name(prefix),
         {:ok, definition} <- component_definition(component),
         {:ok, ports} <- component_ports(component) do
      install_definition!(module, definition, ports, prefix, env)
    else
      {:error, reason} -> fail!(env, reason)
      _missing -> fail!(env, :skill_namespace_required)
    end
  end

  def extend!(module, extension, opts, env) do
    with {:ok, %{as: prefix} = opts} <-
           Portable.normalize_attrs(opts, [:as, :options], :extension_install),
         :ok <- local_name(prefix),
         {:module, ^extension} <- Code.ensure_compiled(extension),
         {:ok, definition, ports} <- Extension.compile(extension, Map.get(opts, :options, [])) do
      install_definition!(module, definition, ports, prefix, env)
    else
      {:error, reason} -> fail!(env, reason)
      _missing -> fail!(env, :invalid_extension_install)
    end
  end

  def route!(module, name, attrs, env) do
    with :ok <- local_name(name), {:ok, rule} <- Rule.new(name, attrs) do
      put_unique!(module, :spectre_routes, name, Rule.canonical(rule), env)
    else
      {:error, reason} -> fail!(env, reason)
    end
  end

  def router!(module, opts, env) do
    if Module.get_attribute(module, :spectre_router) != nil,
      do: fail!(env, :duplicate_router_configuration)

    case Router.configuration(opts) do
      {:ok, config} -> Module.put_attribute(module, :spectre_router, config)
      {:error, reason} -> fail!(env, reason)
    end
  end

  def asset!(module, name, value, env) do
    with :ok <- local_name(name), :ok <- Portable.validate(value) do
      put_unique!(module, :spectre_assets, name, value, env)
    else
      {:error, reason} -> fail!(env, reason)
    end
  end

  defp install_definition!(module, definition, ports, prefix, env) do
    case Declaration.read(definition) do
      {:ok, declaration} ->
        put_unique!(module, :spectre_components, prefix, definition.ref, env)
        put_namespaced!(module, :spectre_components, declaration.components, prefix, env)
        put_namespaced!(module, :spectre_templates, declaration.templates, prefix, env)
        put_namespaced!(module, :spectre_assets, declaration.assets, prefix, env)
        put_namespaced!(module, :spectre_ports, ports, prefix, env)

        routes =
          Map.new(declaration.routes, fn {name, rule} ->
            {name, Map.update!(rule, "to", &(prefix <> "/" <> &1))}
          end)

        put_namespaced!(module, :spectre_routes, routes, prefix, env)

      {:error, reason} ->
        fail!(env, reason)
    end
  end

  defp put_namespaced!(module, attribute, values, prefix, env) do
    Enum.each(values, fn {name, value} ->
      put_unique!(module, attribute, prefix <> "/" <> name, value, env)
    end)
  end

  defmacro __before_compile__(env) do
    attrs = Module.get_attribute(env.module, :spectre_definition_attrs)
    templates = Module.get_attribute(env.module, :spectre_templates)
    components = Module.get_attribute(env.module, :spectre_components)

    body =
      Declaration.body(
        templates,
        components,
        Module.get_attribute(env.module, :spectre_routes),
        Module.get_attribute(env.module, :spectre_router),
        Module.get_attribute(env.module, :spectre_assets)
      )

    definition = build_definition!(attrs, body, env)
    ports = Module.get_attribute(env.module, :spectre_ports)

    quote do
      @impl Spectre.Agent
      @spec definition() :: Spectre.Definition.t()
      def definition, do: unquote(Macro.escape(definition))

      @doc "Returns named host adapter ports, separate from the portable Definition."
      def ports, do: unquote(Macro.escape(ports))

      @doc "Compiles the declared routes with explicit host adapter implementations."
      def router(opts \\ []), do: Spectre.Agent.router(definition(), opts)

      @doc "Materializes one declared template without submitting or executing it."
      @spec candidate(String.t(), Spectre.Mind.Turn.t(), map() | keyword()) ::
              {:ok, Spectre.Candidate.t()} | {:error, term()}
      def candidate(name, turn, attrs) do
        Spectre.Agent.candidate(definition(), name, turn, attrs)
      end
    end
  end

  defp build_definition!(attrs, body, env) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             attrs,
             [:namespace, :name, :revision, :previous_ref, :declared_at],
             :agent_definition
           ),
         {:ok, definition} <-
           attrs
           |> Map.put(:body, body)
           |> Definition.new(),
         {:ok, _} <- Declaration.read(definition) do
      definition
    else
      {:error, reason} -> fail!(env, reason)
    end
  end

  defp component_definition(module) when is_atom(module) and module not in [nil, true, false] do
    with {:module, ^module} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :definition, 0) do
      Definition.new(module.definition())
    else
      _unavailable -> {:error, {:invalid_skill_module, module}}
    end
  end

  defp component_definition(_module), do: {:error, :invalid_skill_module}

  defp component_ports(module) do
    if function_exported?(module, :ports, 0),
      do: Extension.validate_ports(module.ports()),
      else: {:ok, %{}}
  end

  defp local_name(name) when is_binary(name) and name != "" do
    if String.contains?(name, "/"), do: {:error, {:invalid_declaration_name, name}}, else: :ok
  end

  defp local_name(name), do: {:error, {:invalid_declaration_name, name}}

  defp put_template!(module, name, attrs, env) do
    case Template.new(attrs) do
      {:ok, template} -> put_unique!(module, :spectre_templates, name, template, env)
      {:error, reason} -> fail!(env, reason)
    end
  end

  defp put_unique!(module, attribute, name, value, env) do
    entries = Module.get_attribute(module, attribute)

    if Map.has_key?(entries, name), do: fail!(env, {:duplicate_declaration, name})
    Module.put_attribute(module, attribute, Map.put(entries, name, value))
  end

  defp fail!(env, reason) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "invalid Spectre declaration: #{inspect(reason)}"
  end
end
