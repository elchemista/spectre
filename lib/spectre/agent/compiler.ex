defmodule Spectre.Agent.Compiler do
  @moduledoc false

  alias Spectre.{Agent, Definition, Portable}
  alias Spectre.Candidate.Template

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
         {:ok, templates, components} <- Agent.declarations(definition) do
      put_unique!(module, :spectre_components, prefix, definition.ref, env)

      Enum.each(components, fn {name, ref} ->
        put_unique!(module, :spectre_components, prefix <> "/" <> name, ref, env)
      end)

      Enum.each(templates, fn {name, template} ->
        put_template!(module, prefix <> "/" <> name, template, env)
      end)
    else
      {:error, reason} -> fail!(env, reason)
      _missing -> fail!(env, :skill_namespace_required)
    end
  end

  defmacro __before_compile__(env) do
    attrs = Module.get_attribute(env.module, :spectre_definition_attrs)
    templates = Module.get_attribute(env.module, :spectre_templates)
    components = Module.get_attribute(env.module, :spectre_components)

    definition = build_definition!(attrs, templates, components, env)

    quote do
      @impl Spectre.Agent
      @spec definition() :: Spectre.Definition.t()
      def definition, do: unquote(Macro.escape(definition))

      @doc "Materializes one declared template without submitting or executing it."
      @spec candidate(String.t(), Spectre.Mind.Turn.t(), map() | keyword()) ::
              {:ok, Spectre.Candidate.t()} | {:error, term()}
      def candidate(name, turn, attrs) do
        Spectre.Agent.candidate(definition(), name, turn, attrs)
      end
    end
  end

  defp build_definition!(attrs, templates, components, env) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             attrs,
             [:namespace, :name, :revision, :previous_ref, :declared_at],
             :agent_definition
           ),
         {:ok, definition} <-
           attrs
           |> Map.put(:body, %{
             "format" => "spectre-agent-declaration-v1",
             "candidates" => templates,
             "components" => components
           })
           |> Definition.new() do
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
