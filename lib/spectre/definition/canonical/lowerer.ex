defmodule Spectre.Definition.Canonical.Lowerer do
  @moduledoc false

  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Canonical.Data
  alias Spectre.Definition.Canonical.PromptLowerer
  alias Spectre.Definition.Component
  alias Spectre.Definition.Ref
  alias Spectre.Skill.Mount

  @component_specs [
    {:identity, "spectre.definition.identity/1", :must_understand},
    {:metadata, "spectre.definition.metadata/1", :descriptive},
    {:applicability, "spectre.definition.applicability/1", :must_understand},
    {:routing, "spectre.definition.routing/1", :must_understand},
    {:policies, "spectre.definition.policies/1", :must_understand},
    {:prompt_fragments, "spectre.prompt.fragments/1", :must_understand},
    {:requirements, "spectre.definition.requirements/1", :must_understand},
    {:skills, "spectre.definition.skills/1", :must_understand},
    {:compiled_runtime, "spectre.definition.compiled-runtime/1", :must_understand},
    {:projection, "spectre.definition.projection/1", :advisory}
  ]

  @doc false
  @spec lower(module() | Definition.t(), keyword()) :: {:ok, Canonical.t()} | {:error, term()}
  def lower(source, opts \\ [])

  def lower(module, opts) when is_atom(module) and not is_nil(module) and is_list(opts) do
    with :ok <- reject_cycle(module, opts),
         {:ok, definition} <- Definition.fetch(module) do
      lower_definition(definition, Keyword.update(opts, :ancestors, [module], &[module | &1]))
    end
  end

  def lower(%Definition{} = definition, opts) when is_list(opts) do
    lower_definition(definition, opts)
  end

  def lower(source, _opts), do: {:error, {:invalid_compiled_definition_source, shape(source)}}

  @spec lower_definition(Definition.t(), keyword()) ::
          {:ok, Canonical.t()} | {:error, term()}
  defp lower_definition(%Definition{} = definition, opts) do
    with {:ok, canonical_id} <-
           Data.lower(definition.id, owner: definition.owner, path: [:identity, :id]),
         {:ok, declared_version} <-
           Data.structural(definition.version,
             owner: definition.owner,
             path: [:identity, :declared_version]
           ),
         {:ok, payloads} <- component_payloads(definition, opts),
         {:ok, components} <- build_components(payloads) do
      Canonical.new(%{
        kind: definition.kind,
        id: canonical_id,
        declared_version: declared_version,
        origin: :compiled,
        components: components
      })
    end
  end

  @spec component_payloads(Definition.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp component_payloads(definition, opts) do
    with {:ok, identity} <- identity_payload(definition),
         {:ok, metadata} <- metadata_payload(definition),
         {:ok, applicability} <- applicability_payload(definition),
         {:ok, routing} <- routing_payload(definition),
         {:ok, policies} <-
           Data.lower(definition.policies, owner: definition.owner, path: [:policies]),
         {:ok, prompts} <- PromptLowerer.lower(definition, opts),
         {:ok, requirements} <- requirements_payload(definition),
         {:ok, skills} <- skills_payload(definition, opts),
         {:ok, compiled_runtime} <- compiled_runtime_payload(definition),
         {:ok, projection} <- projection_payload() do
      {:ok,
       %{
         identity: identity,
         metadata: metadata,
         applicability: applicability,
         routing: routing,
         policies: %{declarations: policies},
         prompt_fragments: %{fragments: prompts},
         requirements: requirements,
         skills: %{mounts: skills},
         compiled_runtime: compiled_runtime,
         projection: projection
       }}
    end
  end

  @spec identity_payload(Definition.t()) :: {:ok, map()} | {:error, term()}
  defp identity_payload(definition) do
    Data.lower(
      %{
        owner_ref: Data.module_ref(definition.owner),
        source_kind: definition.kind,
        source_schema_version: definition.version
      },
      owner: definition.owner,
      path: [:identity]
    )
  end

  @spec metadata_payload(Definition.t()) :: {:ok, map()} | {:error, term()}
  defp metadata_payload(definition) do
    description = Keyword.get(definition.config, :description)
    authored_metadata = Keyword.get(definition.config, :metadata, %{})

    if not is_nil(description) and not is_binary(description) do
      {:error, {:invalid_definition_description, description}}
    else
      with {:ok, metadata} <-
             Data.structural(authored_metadata,
               owner: definition.owner,
               path: [:metadata, :authored]
             ) do
        {:ok, %{description: description, authored: metadata}}
      end
    end
  end

  @spec applicability_payload(Definition.t()) :: {:ok, map()} | {:error, term()}
  defp applicability_payload(definition) do
    declared = Keyword.get(definition.config, :applicability, %{})

    inferred = %{
      scope: definition.kind,
      labels: Enum.map(definition.rules, &Map.get(&1, :label)),
      flow_paths:
        definition.rules
        |> Enum.map(&Map.get(&1, :flow_path, []))
        |> Enum.uniq()
    }

    with {:ok, declared} <-
           Data.structural(declared,
             owner: definition.owner,
             path: [:applicability, :declared]
           ),
         {:ok, inferred} <-
           Data.structural(inferred,
             owner: definition.owner,
             path: [:applicability, :inferred]
           ) do
      {:ok, %{declared: declared, inferred: inferred}}
    end
  end

  @spec routing_payload(Definition.t()) :: {:ok, map()} | {:error, term()}
  defp routing_payload(definition) do
    with {:ok, router} <-
           Data.lower(definition.router, owner: definition.owner, path: [:routing, :router]),
         {:ok, rules} <- lower_rules(definition.rules, definition.owner) do
      {:ok, %{router: router, rules: rules}}
    end
  end

  @spec lower_rules([map()], module()) :: {:ok, [map()]} | {:error, term()}
  defp lower_rules(rules, owner) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, index}, {:ok, lowered} ->
      case lower_rule(rule, owner, index) do
        {:ok, rule} -> {:cont, {:ok, [rule | lowered]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  @spec lower_rule(map(), module(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  defp lower_rule(rule, owner, index) do
    handler = Map.get(rule, :handler)

    rule_data =
      rule
      |> Map.drop([:handler, :injections, :definition_injections])
      |> Map.put(:prompt_fragment_scopes, prompt_fragment_scopes(rule))

    with {:ok, handler} <- lower_handler(handler, owner, index),
         {:ok, rule_data} <-
           Data.lower(rule_data, owner: owner, path: [:routing, :rules, index]) do
      {:ok, Map.put(rule_data, :handler, handler)}
    end
  end

  @spec lower_handler(term(), module(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  defp lower_handler({:run, function, opts}, owner, index)
       when is_atom(function) and is_list(opts) do
    with {:ok, opts} <- lower_handler_opts(opts, owner, index) do
      {:ok,
       %{
         kind: :run,
         callback_ref: Data.callback_ref(owner, function, [2]),
         opts: opts
       }}
    end
  end

  defp lower_handler({:work, controller, opts}, owner, index)
       when is_atom(controller) and is_list(opts) do
    with {:ok, opts} <- lower_handler_opts(opts, owner, index) do
      {:ok, %{kind: :work, controller_ref: Data.module_ref(controller), opts: opts}}
    end
  end

  defp lower_handler({kind, prompt, opts}, owner, index)
       when kind in [:ask, :reason, :act, :reply] and is_list(opts) do
    with {:ok, prompt} <-
           Data.structural(prompt, owner: owner, path: [:routing, :rules, index, :prompt]),
         {:ok, opts} <- lower_handler_opts(opts, owner, index) do
      {:ok, %{kind: kind, prompt: prompt, opts: opts}}
    end
  end

  defp lower_handler({:action, action, opts}, owner, index) when is_list(opts) do
    with {:ok, action} <-
           Data.structural(action, owner: owner, path: [:routing, :rules, index, :action]),
         {:ok, opts} <- lower_handler_opts(opts, owner, index) do
      {:ok, %{kind: :action, action: action, opts: opts}}
    end
  end

  defp lower_handler(handler, owner, index),
    do: Data.lower(handler, owner: owner, path: [:routing, :rules, index, :handler])

  @spec lower_handler_opts(keyword(), module(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  defp lower_handler_opts(opts, owner, index) do
    opts
    |> Keyword.delete(:inject)
    |> Data.lower(owner: owner, path: [:routing, :rules, index, :handler_opts])
  end

  @spec prompt_fragment_scopes(map()) :: [term()]
  defp prompt_fragment_scopes(rule) do
    flow_scopes = Enum.map(Map.get(rule, :injections, []), & &1.scope)

    handler_scopes =
      case Map.get(rule, :handler) do
        {_kind, _value, opts} when is_list(opts) ->
          if Keyword.has_key?(opts, :inject), do: [{:handler, Map.get(rule, :label)}], else: []

        _handler ->
          []
      end

    Enum.uniq(flow_scopes ++ handler_scopes)
  end

  @spec requirements_payload(Definition.t()) :: {:ok, map()} | {:error, term()}
  defp requirements_payload(definition) do
    with {:ok, requirements} <-
           Data.structural(definition.requirements,
             owner: definition.owner,
             path: [:requirements]
           ) do
      {:ok, %{requested: requirements, grants: []}}
    end
  end

  @spec skills_payload(Definition.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp skills_payload(definition, opts) do
    definition.skills
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {mount, index}, {:ok, lowered} ->
      case lower_mount(mount, definition.owner, opts, index) do
        {:ok, mount} -> {:cont, {:ok, [mount | lowered]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  @spec lower_mount(Mount.t(), module(), keyword(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp lower_mount(%Mount{} = mount, owner, opts, index) do
    with {:ok, canonical} <- lower(mount.module, opts),
         {:ok, mount_id} <-
           Data.lower(mount.id, owner: owner, path: [:skills, index, :id]),
         {:ok, bindings} <-
           Data.lower(mount.bindings, owner: owner, path: [:skills, index, :bindings]),
         {:ok, mount_opts} <-
           Data.lower(mount.opts, owner: owner, path: [:skills, index, :opts]) do
      {:ok,
       %{
         id: mount_id,
         module_ref: Data.module_ref(mount.module),
         definition_ref: canonical |> Canonical.ref() |> Ref.to_string(),
         definition: Canonical.to_data(canonical),
         bindings: bindings,
         opts: mount_opts
       }}
    end
  end

  defp lower_mount(mount, _owner, _opts, index),
    do: {:error, {:invalid_compiled_skill_mount, index, shape(mount)}}

  @spec compiled_runtime_payload(Definition.t()) :: {:ok, map()} | {:error, term()}
  defp compiled_runtime_payload(definition) do
    config =
      Keyword.drop(definition.config, [:description, :metadata, :applicability, :prompt_root])

    Data.lower(
      %{
        config: config,
        prompt_assets: :snapshotted_in_prompt_fragments,
        protections: definition.protections,
        before_actions: definition.before_actions,
        after_actions: definition.after_actions,
        stack_ref: optional_module_ref(definition.stack),
        stack_bindings: definition.stack_refs,
        extensions: definition.extensions
      },
      owner: definition.owner,
      path: [:compiled_runtime]
    )
  end

  @spec projection_payload() :: {:ok, map()}
  defp projection_payload do
    {:ok,
     %{
       generators: [
         %{
           id: "spectre.projection.audit",
           version: 1,
           contract_ref: "spectre.projection/1"
         }
       ]
     }}
  end

  @spec build_components(map()) :: {:ok, [Component.t()]} | {:error, term()}
  defp build_components(payloads) do
    Enum.reduce_while(@component_specs, {:ok, []}, fn {type, schema_ref, criticality},
                                                      {:ok, components} ->
      attrs = [
        component_type: type,
        schema_ref: schema_ref,
        criticality: criticality,
        payload: Map.fetch!(payloads, type)
      ]

      case Component.new(attrs) do
        {:ok, component} -> {:cont, {:ok, [component | components]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  @spec optional_module_ref(module() | nil) :: map() | nil
  defp optional_module_ref(nil), do: nil
  defp optional_module_ref(module), do: Data.module_ref(module)

  @spec reject_cycle(module(), keyword()) :: :ok | {:error, term()}
  defp reject_cycle(module, opts) do
    if module in Keyword.get(opts, :ancestors, []),
      do: {:error, {:recursive_compiled_definition, module}},
      else: :ok
  end

  @spec reverse_result({:ok, [term()]} | {:error, term()}) ::
          {:ok, [term()]} | {:error, term()}
  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
