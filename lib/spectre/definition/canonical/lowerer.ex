defmodule Spectre.Definition.Canonical.Lowerer do
  @moduledoc false

  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Canonical.Data
  alias Spectre.Definition.Canonical.PromptLowerer
  alias Spectre.Definition.Component
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Expression
  alias Spectre.Execution.Program
  alias Spectre.Skill.Applicability
  alias Spectre.Skill.Mount
  alias Spectre.Skill.PromptBudget

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
  @execution_component {:execution, "spectre.definition.execution/1", :must_understand}

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
    with {:ok, execution} <- execution_programs(definition),
         {:ok, identity} <- identity_payload(definition),
         {:ok, metadata} <- metadata_payload(definition),
         {:ok, applicability} <- applicability_payload(definition),
         {:ok, routing} <- routing_payload(definition, execution.by_module),
         {:ok, policies} <-
           Data.lower(definition.policies, owner: definition.owner, path: [:policies]),
         {:ok, prompts} <- PromptLowerer.lower(definition, opts),
         {:ok, prompt_fragments} <- prompt_fragments_payload(definition, prompts),
         {:ok, requirements} <- requirements_payload(definition, execution.programs),
         {:ok, skills} <- skills_payload(definition, opts),
         {:ok, compiled_runtime} <- compiled_runtime_payload(definition),
         {:ok, projection} <- projection_payload(execution.programs) do
      payloads = %{
        identity: identity,
        metadata: metadata,
        applicability: applicability,
        routing: routing,
        policies: %{declarations: policies},
        prompt_fragments: prompt_fragments,
        requirements: requirements,
        skills: %{mounts: skills},
        compiled_runtime: compiled_runtime,
        projection: projection
      }

      payloads =
        if execution.programs == [] do
          payloads
        else
          Map.put(payloads, :execution, %{
            schema_version: 1,
            programs: Enum.map(execution.programs, &Program.to_data/1)
          })
        end

      {:ok, payloads}
    end
  end

  @spec execution_programs(Definition.t()) ::
          {:ok, %{by_module: map(), programs: [Program.t()]}} | {:error, term()}
  defp execution_programs(definition) do
    definition.rules
    |> Enum.map(&Map.get(&1, :handler))
    |> Enum.flat_map(fn
      {:work, controller, _opts} when is_atom(controller) -> [controller]
      _handler -> []
    end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}, %{}}, &collect_execution_program/2)
    |> case do
      {:ok, by_module, by_id} ->
        {:ok, %{by_module: by_module, programs: by_id |> Map.values() |> Enum.sort_by(& &1.id)}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec collect_execution_program(module(), {:ok, map(), map()}) ::
          {:cont, {:ok, map(), map()}} | {:halt, {:error, term()}}
  defp collect_execution_program(controller, {:ok, by_module, by_id}) do
    case compiled_execution_program(controller) do
      :skip ->
        {:cont, {:ok, by_module, by_id}}

      {:ok, program} ->
        merge_execution_program(controller, program, by_module, by_id)

      {:error, reason} ->
        {:halt, {:error, {:invalid_compiled_execution_program, controller, reason}}}
    end
  end

  @spec compiled_execution_program(module()) :: :skip | {:ok, Program.t()} | {:error, term()}
  defp compiled_execution_program(controller) do
    if data_work_module?(controller), do: Program.from_compiled(controller), else: :skip
  end

  @spec merge_execution_program(module(), Program.t(), map(), map()) ::
          {:cont, {:ok, map(), map()}} | {:halt, {:error, term()}}
  defp merge_execution_program(controller, program, by_module, by_id) do
    case Map.fetch(by_id, program.id) do
      {:ok, %Program{digest: digest}} when digest != program.digest ->
        {:halt, {:error, {:conflicting_compiled_execution_program, program.id}}}

      _existing ->
        {:cont,
         {:ok, Map.put(by_module, controller, program), Map.put(by_id, program.id, program)}}
    end
  end

  @spec data_work_module?(module()) :: boolean()
  defp data_work_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__spectre_execution_program__, 0)
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

    with :ok <- validate_skill_applicability(definition.kind, declared),
         {:ok, declared} <-
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

  @spec validate_skill_applicability(Definition.kind(), term()) :: :ok | {:error, term()}
  defp validate_skill_applicability(:agent, _declared), do: :ok

  defp validate_skill_applicability(:skill, declared) do
    case Applicability.new(declared) do
      {:ok, _applicability} -> :ok
      {:error, reason} -> {:error, {:invalid_compiled_skill_applicability, reason}}
    end
  end

  @spec prompt_fragments_payload(Definition.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  defp prompt_fragments_payload(%Definition{kind: :agent}, prompts),
    do: {:ok, %{fragments: prompts}}

  defp prompt_fragments_payload(%Definition{kind: :skill} = definition, prompts) do
    cap = Keyword.get(definition.config, :prompt_budget, 512)

    case PromptBudget.new(prompts, token_cap: cap) do
      {:ok, budget} -> {:ok, %{fragments: prompts, budget: PromptBudget.to_data(budget)}}
      {:error, reason} -> {:error, {:invalid_compiled_skill_prompt_budget, reason}}
    end
  end

  @spec routing_payload(Definition.t(), map()) :: {:ok, map()} | {:error, term()}
  defp routing_payload(definition, programs) do
    with {:ok, router} <-
           Data.lower(definition.router, owner: definition.owner, path: [:routing, :router]),
         {:ok, rules} <- lower_rules(definition.rules, definition.owner, programs) do
      {:ok, %{router: router, rules: rules}}
    end
  end

  @spec lower_rules([map()], module(), map()) :: {:ok, [map()]} | {:error, term()}
  defp lower_rules(rules, owner, programs) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, index}, {:ok, lowered} ->
      case lower_rule(rule, owner, index, programs) do
        {:ok, rule} -> {:cont, {:ok, [rule | lowered]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  @spec lower_rule(map(), module(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  defp lower_rule(rule, owner, index, programs) do
    handler = Map.get(rule, :handler)

    rule_data =
      rule
      |> Map.drop([:handler, :injections, :definition_injections])
      |> Map.put(:prompt_fragment_scopes, prompt_fragment_scopes(rule))

    with {:ok, handler} <- lower_handler(handler, owner, index, programs),
         {:ok, rule_data} <-
           Data.lower(rule_data, owner: owner, path: [:routing, :rules, index]) do
      {:ok, Map.put(rule_data, :handler, handler)}
    end
  end

  @spec lower_handler(term(), module(), non_neg_integer(), map()) ::
          {:ok, term()} | {:error, term()}
  defp lower_handler({:run, function, opts}, owner, index, _programs)
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

  defp lower_handler({:work, controller, opts}, owner, index, programs)
       when is_atom(controller) and is_list(opts) do
    case Map.fetch(programs, controller) do
      {:ok, program} ->
        input = Keyword.get(opts, :input, :input)

        with {:ok, input} <- data_work_input(input),
             {:ok, opts} <-
               opts |> Keyword.delete(:input) |> lower_handler_opts(owner, index) do
          {:ok, %{kind: :work, work_ref: program.id, input: input, opts: opts}}
        end

      :error ->
        with {:ok, opts} <- lower_handler_opts(opts, owner, index) do
          {:ok, %{kind: :work, controller_ref: Data.module_ref(controller), opts: opts}}
        end
    end
  end

  defp lower_handler({kind, prompt, opts}, owner, index, _programs)
       when kind in [:ask, :reason, :act, :reply] and is_list(opts) do
    with {:ok, prompt} <-
           Data.structural(prompt, owner: owner, path: [:routing, :rules, index, :prompt]),
         {:ok, opts} <- lower_handler_opts(opts, owner, index) do
      {:ok, %{kind: kind, prompt: prompt, opts: opts}}
    end
  end

  defp lower_handler({:action, action, opts}, owner, index, _programs) when is_list(opts) do
    with {:ok, action} <-
           Data.structural(action, owner: owner, path: [:routing, :rules, index, :action]),
         {:ok, opts} <- lower_handler_opts(opts, owner, index) do
      {:ok, %{kind: :action, action: action, opts: opts}}
    end
  end

  defp lower_handler({:operation, operation, opts}, owner, index, _programs)
       when is_list(opts) do
    input = Keyword.get(opts, :input, :input)

    with {:ok, operation} <-
           Data.structural(operation,
             owner: owner,
             path: [:routing, :rules, index, :operation]
           ),
         {:ok, input} <-
           Data.structural(input,
             owner: owner,
             path: [:routing, :rules, index, :operation_input]
           ),
         {:ok, opts} <-
           opts
           |> Keyword.delete(:input)
           |> lower_handler_opts(owner, index) do
      {:ok, %{kind: :operation, operation_ref: operation, input: input, opts: opts}}
    end
  end

  defp lower_handler(handler, owner, index, _programs),
    do: Data.lower(handler, owner: owner, path: [:routing, :rules, index, :handler])

  @spec data_work_input(term()) :: {:ok, term()} | {:error, term()}
  defp data_work_input(value) when value in [:input, :text], do: {:ok, value}

  defp data_work_input({:fixed, value}) do
    with {:ok, _expression} <- Expression.normalize({:fixed, value}), do: {:ok, {:fixed, value}}
  end

  defp data_work_input(value) do
    with {:ok, _expression} <- Expression.normalize({:fixed, value}), do: {:ok, {:fixed, value}}
  end

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

  @spec requirements_payload(Definition.t(), [Program.t()]) :: {:ok, map()} | {:error, term()}
  defp requirements_payload(definition, programs) do
    requirements = merge_execution_requirements(definition.requirements, programs)

    with {:ok, requirements} <-
           Data.structural(requirements,
             owner: definition.owner,
             path: [:requirements]
           ) do
      {:ok, %{requested: requirements, grants: []}}
    end
  end

  @spec merge_execution_requirements([term()], [Program.t()]) :: [term()]
  defp merge_execution_requirements(requirements, programs) do
    programs
    |> Enum.flat_map(&Program.operation_refs/1)
    |> Enum.reduce(requirements, fn ref, merged ->
      if Enum.any?(merged, &execution_requirement?(&1, ref)) do
        merged
      else
        merged ++ [%{kind: :operation, name: ref, mode: :read, opts: []}]
      end
    end)
  end

  @spec execution_requirement?(term(), term()) :: boolean()
  defp execution_requirement?(requirement, ref) do
    requirement_kind(requirement) == :operation and
      same_name?(requirement_name(requirement), ref)
  end

  defp requirement_kind(requirement) when is_map(requirement),
    do: Map.get(requirement, :kind, Map.get(requirement, "kind"))

  defp requirement_kind(_requirement), do: nil

  defp requirement_name(requirement) when is_map(requirement),
    do: Map.get(requirement, :name, Map.get(requirement, "name"))

  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right), do: left == right

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
      Keyword.drop(definition.config, [
        :description,
        :metadata,
        :applicability,
        :prompt_root,
        :prompt_budget
      ])

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

  @spec projection_payload([Program.t()]) :: {:ok, map()}
  defp projection_payload(programs) do
    generators = [
      %{
        id: "spectre.projection.audit",
        version: 1,
        contract_ref: "spectre.projection/1"
      },
      %{
        id: "spectre.projection.routing",
        version: 1,
        contract_ref: "spectre.projection/1"
      }
    ]

    generators =
      if programs == [] do
        generators
      else
        generators ++
          [
            %{
              id: "spectre.projection.execution",
              version: 1,
              contract_ref: "spectre.projection/1"
            }
          ]
      end

    {:ok, %{generators: generators}}
  end

  @spec build_components(map()) :: {:ok, [Component.t()]} | {:error, term()}
  defp build_components(payloads) do
    specs =
      if Map.has_key?(payloads, :execution),
        do: @component_specs ++ [@execution_component],
        else: @component_specs

    Enum.reduce_while(specs, {:ok, []}, fn {type, schema_ref, criticality}, {:ok, components} ->
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
