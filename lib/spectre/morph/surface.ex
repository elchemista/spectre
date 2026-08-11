defmodule Spectre.Morph.Surface do
  @moduledoc """
  Canonical, closed declaration of the changes an Agent is willing to review.

  A surface is a ceiling over proposals, never an authority grant. The
  Composer still intersects it with the active Manifest authority and the
  host governance policy. Runtime data cannot add operation types or widen
  scopes after the Definition has been published.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Governance.Constraints
  alias Spectre.Prompt.Materializer
  alias Spectre.Skill.Applicability
  alias Spectre.Skill.Definition, as: SkillDefinition

  @schema_version 1
  @schema_ref "spectre.definition.change-surface/1"
  @operation_types ~w(disable_skill mount_skill replace_skill)
  @approval_requirements ~w(host_policy human)
  @fields ~w(schema_version operation_types scope_ceiling prompt_token_ceiling approval_requirement)
  @atom_fields [
    :schema_version,
    :operation_types,
    :scope_ceiling,
    :prompt_token_ceiling,
    :approval_requirement
  ]

  @enforce_keys [
    :schema_version,
    :operation_types,
    :scope_ceiling,
    :prompt_token_ceiling,
    :approval_requirement
  ]
  defstruct schema_version: @schema_version,
            operation_types: [],
            scope_ceiling: [],
            prompt_token_ceiling: nil,
            approval_requirement: :host_policy

  @type approval_requirement :: :host_policy | :human
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          operation_types: [String.t()],
          scope_ceiling: [String.t()],
          prompt_token_ceiling: pos_integer(),
          approval_requirement: approval_requirement()
        }

  @doc "Returns the stable component schema Ref."
  @spec schema_ref() :: String.t()
  def schema_ref, do: @schema_ref

  @doc "Returns the closed proposal vocabulary supported by Morph."
  @spec operation_types() :: [String.t()]
  def operation_types, do: @operation_types

  @doc "Builds and normalizes a change surface."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = surface), do: surface |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_morph_surface, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         @schema_version <- value(attrs, "schema_version", @schema_version),
         {:ok, operations} <- operations(value(attrs, "operation_types")),
         {:ok, scopes} <- scopes(value(attrs, "scope_ceiling")),
         {:ok, prompt_tokens} <- prompt_tokens(value(attrs, "prompt_token_ceiling")),
         {:ok, approval} <- approval(value(attrs, "approval_requirement", "host_policy")) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         operation_types: operations,
         scope_ceiling: scopes,
         prompt_token_ceiling: prompt_tokens,
         approval_requirement: approval
       }}
    else
      version when is_integer(version) -> {:error, {:unsupported_morph_surface_schema, version}}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_morph_surface}
    end
  end

  def new(value), do: {:error, {:invalid_morph_surface, shape(value)}}

  @doc "Builds a surface or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, surface} -> surface
      {:error, reason} -> raise ArgumentError, "invalid Morph surface: #{inspect(reason)}"
    end
  end

  @doc "Returns the transport-stable representation sealed into Definition identity."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = surface) do
    %{
      "schema_version" => surface.schema_version,
      "operation_types" => surface.operation_types,
      "scope_ceiling" => surface.scope_ceiling,
      "prompt_token_ceiling" => surface.prompt_token_ceiling,
      "approval_requirement" => Atom.to_string(surface.approval_requirement)
    }
  end

  @doc "Restores a surface from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Reads the immutable change surface from a canonical Agent Definition."
  @spec from_canonical(Canonical.t()) :: {:ok, t()} | {:error, term()}
  def from_canonical(%Canonical{kind: :agent} = canonical) do
    with {:ok, component} <- Canonical.fetch_component(canonical, :change_surface),
         :ok <- validate_component(component) do
      from_data(component.payload)
    else
      {:error, {:unknown_definition_component, :change_surface}} ->
        {:error, :morph_surface_not_declared}

      {:error, _reason} = error ->
        error
    end
  end

  def from_canonical(%Canonical{kind: kind}),
    do: {:error, {:morph_surface_requires_agent, kind}}

  @doc false
  @spec validate_component(Component.t()) :: :ok | {:error, term()}
  def validate_component(%Component{} = component) do
    cond do
      component.component_type != :change_surface ->
        {:error, {:invalid_morph_surface_component_type, component.component_type}}

      component.schema_ref != @schema_ref ->
        {:error, {:invalid_morph_surface_schema_ref, component.schema_ref}}

      component.criticality != :must_understand ->
        {:error, {:invalid_morph_surface_criticality, component.criticality}}

      true ->
        with {:ok, _surface} <- from_data(component.payload), do: :ok
    end
  end

  @doc "Returns whether this Definition permits proposing the core operation type."
  @spec allows?(t(), atom() | String.t()) :: boolean()
  def allows?(%__MODULE__{operation_types: allowed}, operation) do
    case operation_name(operation) do
      {:ok, name} -> name in allowed
      {:error, _reason} -> false
    end
  end

  @doc "Builds exact applicability ceilings for the affected mount ids."
  @spec applicability_ceilings(t(), [String.t()]) :: map()
  def applicability_ceilings(%__MODULE__{} = surface, mount_ids) when is_list(mount_ids) do
    mount_ids
    |> Enum.uniq()
    |> Map.new(fn mount_id ->
      {mount_id,
       %{
         scopes: surface.scope_ceiling,
         required_tags: [],
         forbidden_tags: [],
         positive: [],
         negative: [],
         conflicts: []
       }}
    end)
  end

  @doc false
  @spec constrain(Canonical.t(), [struct()], keyword()) :: {:ok, keyword()} | {:error, term()}
  def constrain(%Canonical{} = parent, operations, opts)
      when is_list(operations) and is_list(opts) do
    case from_canonical(parent) do
      {:ok, surface} ->
        with :ok <- permitted_operations(surface, operations),
             {:ok, mount_ids} <- changed_mount_ids(surface, operations),
             {:ok, ceilings} <-
               meet_ceilings(
                 surface,
                 mount_ids,
                 Keyword.get(opts, :applicability_ceilings, %{})
               ),
             {:ok, prompt_ceiling} <-
               meet_prompt_ceiling(
                 surface.prompt_token_ceiling,
                 Keyword.get(opts, :prompt_token_ceiling)
               ) do
          {:ok,
           opts
           |> Keyword.put(:applicability_ceilings, ceilings)
           |> Keyword.put(:prompt_token_ceiling, prompt_ceiling)}
        end

      {:error, :morph_surface_not_declared} ->
        {:ok, opts}

      {:error, _reason} = error ->
        error
    end
  end

  def constrain(%Canonical{}, _operations, opts),
    do: {:error, {:invalid_morph_constraint_options, shape(opts)}}

  @doc false
  @spec verify_candidate(Canonical.t(), Canonical.t(), number() | nil, term()) ::
          :ok | {:error, term()}
  def verify_candidate(%Canonical{} = parent, %Canonical{} = candidate, prompt_ceiling, ceilings) do
    case from_canonical(parent) do
      {:ok, surface} ->
        with {:ok, candidate_surface} <- from_canonical(candidate),
             true <- candidate_surface == surface,
             :ok <- unchanged_non_skill_components(parent, candidate),
             {:ok, mutations} <- skill_mutations(parent, candidate),
             :ok <- permitted_mutations(surface, mutations),
             :ok <- persisted_prompt_ceiling(surface, prompt_ceiling),
             :ok <- persisted_applicability_ceilings(surface, mutations, ceilings) do
          :ok
        else
          false -> {:error, :governance_change_surface_is_immutable}
          {:error, _reason} = error -> error
        end

      {:error, :morph_surface_not_declared} ->
        case from_canonical(candidate) do
          {:error, :morph_surface_not_declared} -> :ok
          _value -> {:error, :governance_change_surface_is_immutable}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec verify_evaluation_obligations(Canonical.t(), Canonical.t(), [map()]) ::
          :ok | {:error, term()}
  def verify_evaluation_obligations(
        %Canonical{} = parent,
        %Canonical{} = candidate,
        cases
      )
      when is_list(cases) do
    case from_canonical(parent) do
      {:ok, surface} ->
        with {:ok, mutations} <- skill_mutations(parent, candidate),
             {:ok, required} <- required_cases(surface, parent, candidate, mutations),
             {:ok, supplied} <- canonical_cases(cases) do
          require_cases(required, supplied)
        end

      {:error, :morph_surface_not_declared} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def verify_evaluation_obligations(%Canonical{}, %Canonical{}, cases),
    do: {:error, {:invalid_morph_evaluation_obligations, shape(cases)}}

  @doc false
  @spec evaluation_case_id(term(), term(), String.t()) :: String.t()
  def evaluation_case_id(mount_id, scope, purpose) do
    digest =
      Value.digest!(%{
        "mount" => mount_id,
        "scope" => scope,
        "purpose" => purpose
      })

    "morph:" <> binary_part(digest, 0, 24)
  end

  @doc "Returns the canonical surface digest used in audit evidence."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = surface), do: surface |> to_data() |> Value.digest!()

  defp permitted_operations(surface, operations) do
    case Enum.find(operations, fn operation ->
           type = Map.get(operation, :type)
           type != "add_eval_case" and not allows?(surface, type)
         end) do
      nil -> :ok
      operation -> {:error, {:morph_operation_outside_surface, Map.get(operation, :type)}}
    end
  end

  defp changed_mount_ids(surface, operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, ids} ->
      case changed_mount_id(surface, operation) do
        :skip -> {:cont, {:ok, ids}}
        {:ok, mount_id} -> {:cont, {:ok, [mount_id | ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      {:error, _reason} = error -> error
    end)
  end

  defp changed_mount_id(surface, operation) do
    type = Map.get(operation, :type)
    mount_id = operation |> Map.get(:payload, %{}) |> Map.get("mount_id")

    cond do
      type == "add_eval_case" ->
        :skip

      not allows?(surface, type) ->
        {:error, {:morph_operation_outside_surface, type}}

      is_binary(mount_id) and mount_id != "" and
          not String.starts_with?(mount_id, "Elixir.") ->
        {:ok, mount_id}

      true ->
        {:error, {:invalid_morph_surface_mount_id, mount_id}}
    end
  end

  defp meet_prompt_ceiling(declared, nil), do: {:ok, declared}

  defp meet_prompt_ceiling(declared, configured)
       when is_number(configured) and configured >= 0,
       do: {:ok, min(declared, configured)}

  defp meet_prompt_ceiling(_declared, configured),
    do: {:error, {:invalid_morph_prompt_ceiling, configured}}

  defp meet_ceilings(surface, mount_ids, configured) do
    case Constraints.normalize_applicability_ceilings(configured) do
      {:ok, configured} -> reduce_declared_ceilings(surface, mount_ids, configured)
      {:error, _reason} = error -> error
    end
  end

  defp reduce_declared_ceilings(surface, mount_ids, configured) do
    surface
    |> applicability_ceilings(mount_ids)
    |> Enum.reduce_while({:ok, configured}, fn {mount_id, declared}, {:ok, acc} ->
      case merge_declared_ceiling(acc, mount_id, declared) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp merge_declared_ceiling(configured, mount_id, declared_data) do
    with {:ok, declared} <- Applicability.new(declared_data) do
      merge_configured_ceiling(configured, mount_id, declared)
    end
  end

  defp merge_configured_ceiling(configured, mount_id, declared) do
    case Map.fetch(configured, mount_id) do
      :error ->
        {:ok, Map.put(configured, mount_id, Applicability.to_data(declared))}

      {:ok, configured_data} ->
        with {:ok, ceiling} <- Applicability.new(configured_data),
             :ok <- Constraints.within_applicability_ceiling(ceiling, declared) do
          {:ok, configured}
        end
    end
  end

  defp unchanged_non_skill_components(parent, candidate) do
    drop = fn canonical ->
      canonical.components
      |> Enum.reject(&(&1.component_type == :skills))
    end

    if drop.(parent) == drop.(candidate),
      do: :ok,
      else: {:error, :morph_changed_component_outside_surface}
  end

  defp skill_mutations(parent, candidate) do
    with {:ok, parent_mounts} <- mounts_by_id(parent),
         {:ok, candidate_mounts} <- mounts_by_id(candidate) do
      {:ok, mutation_diff(parent_mounts, candidate_mounts)}
    end
  end

  defp mutation_diff(parent_mounts, candidate_mounts) do
    parent_mounts
    |> Map.keys()
    |> Kernel.++(Map.keys(candidate_mounts))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&mount_mutation(&1, parent_mounts, candidate_mounts))
  end

  defp mount_mutation(mount_id, parent_mounts, candidate_mounts) do
    case {Map.get(parent_mounts, mount_id), Map.get(candidate_mounts, mount_id)} do
      {nil, nil} -> []
      {nil, _candidate} -> [{mount_id, "mount_skill"}]
      {_parent, nil} -> [{mount_id, "disable_skill"}]
      {same, same} -> []
      {_parent, _candidate} -> [{mount_id, "replace_skill"}]
    end
  end

  defp mounts_by_id(canonical) do
    with {:ok, component} <- Canonical.fetch_component(canonical, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- value(payload, "mounts", []) do
      index_mounts(mounts)
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_morph_surface_skill_component}
    end
  end

  defp index_mounts(mounts),
    do: Enum.reduce_while(mounts, {:ok, %{}}, &index_mount/2)

  defp index_mount(mount, {:ok, acc}) do
    case put_mount(acc, mount) do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp put_mount(mounts, mount) do
    raw_mount_id = if is_map(mount), do: value(mount, "id"), else: nil

    case canonical_mount_id(raw_mount_id) do
      {:ok, mount_id} -> put_unique_mount(mounts, mount_id, raw_mount_id, mount)
      :error -> {:error, {:invalid_morph_surface_mount, raw_mount_id}}
    end
  end

  defp put_unique_mount(mounts, mount_id, raw_mount_id, mount) do
    if Map.has_key?(mounts, mount_id),
      do: {:error, {:duplicate_morph_surface_mount, raw_mount_id}},
      else: {:ok, Map.put(mounts, mount_id, mount)}
  end

  defp permitted_mutations(surface, mutations) do
    case Enum.find(mutations, fn {_mount_id, operation} -> not allows?(surface, operation) end) do
      nil -> :ok
      {mount_id, operation} -> {:error, {:morph_operation_outside_surface, operation, mount_id}}
    end
  end

  defp persisted_prompt_ceiling(surface, value)
       when is_number(value) and value >= 0 and value <= surface.prompt_token_ceiling,
       do: :ok

  defp persisted_prompt_ceiling(surface, value),
    do: {:error, {:morph_prompt_ceiling_not_sealed, value, surface.prompt_token_ceiling}}

  defp persisted_applicability_ceilings(surface, mutations, ceilings) do
    with {:ok, ceilings} <- Constraints.normalize_applicability_ceilings(ceilings) do
      surface
      |> applicability_ceilings(Enum.map(mutations, &elem(&1, 0)))
      |> verify_persisted_applicability_ceilings(ceilings)
    end
  end

  defp verify_persisted_applicability_ceilings(declared, ceilings) do
    Enum.reduce_while(declared, :ok, fn {mount_id, declared_data}, :ok ->
      case persisted_applicability_ceiling(ceilings, mount_id, declared_data) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp persisted_applicability_ceiling(ceilings, mount_id, declared_data) do
    with {:ok, persisted_data} <- Map.fetch(ceilings, mount_id),
         {:ok, persisted} <- Applicability.new(persisted_data),
         {:ok, declared} <- Applicability.new(declared_data),
         :ok <- Constraints.within_applicability_ceiling(persisted, declared) do
      :ok
    else
      :error -> {:error, {:morph_applicability_ceiling_not_sealed, mount_id}}
      {:error, _reason} = error -> error
    end
  end

  defp required_cases(surface, parent, candidate, mutations) do
    with {:ok, parent_mounts} <- mounts_by_id(parent),
         {:ok, candidate_mounts} <- mounts_by_id(candidate) do
      collect_required_cases(surface, mutations, parent_mounts, candidate_mounts)
    end
  end

  defp collect_required_cases(surface, mutations, parent_mounts, candidate_mounts) do
    Enum.reduce_while(mutations, {:ok, []}, fn mutation, {:ok, cases} ->
      append_required_cases(surface, mutation, parent_mounts, candidate_mounts, cases)
    end)
  end

  defp append_required_cases(
         surface,
         {mount_id, operation},
         parent_mounts,
         candidate_mounts,
         cases
       ) do
    source = mutation_source(operation, mount_id, parent_mounts, candidate_mounts)

    case mutation_cases(surface, mount_id, operation, source) do
      {:ok, required} -> {:cont, {:ok, cases ++ required}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp mutation_source("disable_skill", mount_id, parent_mounts, _candidate_mounts),
    do: Map.get(parent_mounts, mount_id)

  defp mutation_source(_operation, mount_id, _parent_mounts, candidate_mounts),
    do: Map.get(candidate_mounts, mount_id)

  defp mutation_cases(surface, mount_id, operation, mount)
       when operation in ["mount_skill", "replace_skill"] do
    with {:ok, skill} <- runtime_skill(mount, mount_id),
         :ok <- reply_only(skill, mount_id),
         {:ok, route} <- single_exact_reply(skill, mount_id),
         {:ok, fragment} <- route_fragment(skill, route.prompt_ref, mount_id),
         {:ok, scopes} <- obligation_scopes(skill, surface) do
      reply_cases(mount_id, scopes, route, fragment)
    end
  end

  defp mutation_cases(surface, mount_id, "disable_skill", mount) do
    with {:ok, skill} <- runtime_skill(mount, mount_id),
         inputs when is_list(inputs) and inputs != [] <-
           SkillDefinition.applicability(skill).positive,
         true <- Enum.all?(inputs, &(is_binary(&1) and &1 != "")),
         {:ok, cases} <- disabled_cases(mount_id, surface.scope_ceiling, inputs) do
      {:ok, cases}
    else
      false -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
      _value -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  defp runtime_skill(mount, mount_id) when is_map(mount) do
    with data when is_map(data) <- value(mount, "definition"),
         {:ok, canonical} <- Canonical.from_data(data),
         :ok <- embedded_definition_ref(canonical, value(mount, "definition_ref"), mount_id),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical),
         :runtime <- SkillDefinition.origin(skill) do
      {:ok, skill}
    else
      :compiled -> {:error, {:morph_compiled_skill_is_immutable, mount_id}}
      {:error, _reason} = error -> error
      _value -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  defp runtime_skill(_mount, mount_id),
    do: {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}

  defp reply_only(skill, mount_id) do
    if SkillDefinition.operation_refs(skill) == [] and SkillDefinition.works(skill) == [],
      do: :ok,
      else: {:error, {:morph_evaluation_obligation_not_declarative, mount_id}}
  end

  defp single_exact_reply(skill, mount_id) do
    case SkillDefinition.routes(skill) do
      [route] -> exact_reply_route(route, mount_id)
      _routes -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  defp exact_reply_route(route, mount_id) when is_map(route) do
    handler = value(route, "handler", %{})
    checks = value(route, "checks", [])
    label = value(route, "label")

    with kind when kind in [:reply, "reply"] <- value(handler, "kind"),
         prompt_ref when not is_nil(prompt_ref) <- value(handler, "prompt"),
         {:ok, input} <- exact_text_check(checks),
         true <- not is_nil(label) do
      {:ok,
       %{
         input: input,
         label: EvalCase.canonical(label),
         prompt_ref: prompt_ref
       }}
    else
      _value -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  defp exact_text_check([{:text, input}]) when is_binary(input) and input != "", do: {:ok, input}
  defp exact_text_check([["text", input]]) when is_binary(input) and input != "", do: {:ok, input}
  defp exact_text_check(_checks), do: :error

  defp route_fragment(skill, prompt_ref, mount_id) do
    case Enum.find(SkillDefinition.prompt_fragments(skill), &same_name?(&1.id, prompt_ref)) do
      %{content: content, condition_ref: nil, placeholders: placeholders} = fragment
      when is_binary(content) and is_map(placeholders) ->
        if Enum.all?(Map.keys(placeholders), &(&1 == "input.text")),
          do: {:ok, fragment},
          else: {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}

      _value ->
        {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  defp obligation_scopes(skill, surface) do
    scopes =
      skill
      |> SkillDefinition.applicability()
      |> Map.fetch!(:scopes)
      |> Enum.map(&canonical_scope/1)

    if scopes != [] and Enum.all?(scopes, &(is_binary(&1) and &1 in surface.scope_ceiling)),
      do: {:ok, scopes},
      else: {:error, :skill_applicability_ceiling_exceeded}
  end

  defp embedded_definition_ref(canonical, embedded, mount_id) when is_binary(embedded) do
    actual = canonical |> Canonical.ref() |> to_string()

    if embedded == actual,
      do: :ok,
      else: {:error, {:morph_skill_definition_ref_mismatch, mount_id, embedded, actual}}
  end

  defp embedded_definition_ref(_canonical, embedded, mount_id),
    do: {:error, {:invalid_morph_skill_definition_ref, mount_id, embedded}}

  defp canonical_scope(scope) when is_atom(scope) and not is_nil(scope), do: Atom.to_string(scope)
  defp canonical_scope(scope) when is_binary(scope) and scope != "", do: scope
  defp canonical_scope(_scope), do: nil

  defp reply_cases(mount_id, scopes, route, fragment) do
    Enum.reduce_while(scopes, {:ok, []}, fn scope, {:ok, cases} ->
      context = %{"scope" => scope}

      with {:ok, output, _evidence} <- Materializer.render(fragment, route.input, context),
           {:ok, evaluation_case} <-
             EvalCase.new(%{
               "id" => evaluation_case_id(mount_id, scope, "reply"),
               "input" => route.input,
               "expected_outcome" => "route",
               "expected_route" => route.label,
               "expected_output" => output,
               "context" => context,
               "llm" => "forbidden"
             }) do
        {:cont, {:ok, cases ++ [EvalCase.to_data(evaluation_case)]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:morph_evaluation_obligation_not_derivable, mount_id, reason}}}
      end
    end)
  end

  defp disabled_cases(mount_id, scopes, inputs) do
    for scope <- scopes, input <- inputs, reduce: {:ok, []} do
      {:ok, cases} ->
        case EvalCase.new(%{
               "id" => evaluation_case_id(mount_id, scope, "disabled:" <> input),
               "input" => input,
               "expected_outcome" => "clarify",
               "context" => %{"scope" => scope},
               "llm" => "forbidden"
             }) do
          {:ok, evaluation_case} -> {:ok, cases ++ [EvalCase.to_data(evaluation_case)]}
          {:error, _reason} -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp canonical_cases(cases) do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {case_data, index}, {:ok, normalized} ->
      with {:ok, evaluation_case} <- EvalCase.new(case_data),
           data = EvalCase.to_data(evaluation_case),
           false <- Map.has_key?(normalized, evaluation_case.id) do
        {:cont, {:ok, Map.put(normalized, evaluation_case.id, data)}}
      else
        true ->
          {:halt, {:error, {:duplicate_morph_evaluation_obligation, index}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_morph_evaluation_obligation, index, reason}}}
      end
    end)
  end

  defp require_cases(required, supplied) do
    Enum.reduce_while(required, :ok, fn expected, :ok ->
      id = expected["id"]

      case Map.fetch(supplied, id) do
        {:ok, ^expected} -> {:cont, :ok}
        {:ok, _other} -> {:halt, {:error, {:morph_evaluation_obligation_mismatch, id}}}
        :error -> {:halt, {:error, {:morph_evaluation_obligation_missing, id}}}
      end
    end)
  end

  # Compiled mount ids are commonly atoms while runtime-authored ids are
  # strings. Governance already treats those two forms as the same stable
  # name; mirror that rule without ever creating an atom from runtime data.
  defp canonical_mount_id(value) when is_binary(value) and value != "", do: {:ok, value}

  defp canonical_mount_id(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp canonical_mount_id(value) when is_integer(value), do: {:ok, value}
  defp canonical_mount_id(_value), do: :error

  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right), do: left == right

  defp exact_fields(attrs) do
    keys = Map.keys(attrs)
    allowed = @fields ++ @atom_fields
    unknown = keys -- allowed

    collision =
      Enum.find(Enum.zip(@fields, @atom_fields), fn {string, atom} ->
        Map.has_key?(attrs, string) and Map.has_key?(attrs, atom)
      end)

    cond do
      unknown != [] ->
        {:error, {:unknown_morph_surface_fields, Enum.sort_by(unknown, &inspect/1)}}

      collision != nil ->
        {:error, {:duplicate_morph_surface_field, elem(collision, 0)}}

      true ->
        :ok
    end
  end

  defp operations(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case operation_name(value) do
        {:ok, name} -> {:cont, {:ok, [name | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.uniq() |> Enum.sort()}
      {:error, _reason} = error -> error
    end
  end

  defp operations(value), do: {:error, {:invalid_morph_surface_operations, value}}

  defp operation_name(value) when is_atom(value) and not is_nil(value),
    do: operation_name(Atom.to_string(value))

  defp operation_name(value) when value in @operation_types, do: {:ok, value}
  defp operation_name(value), do: {:error, {:unsupported_morph_operation, value}}

  defp scopes(values) when is_list(values) and values != [] do
    normalized = Enum.map(values, &scope/1)

    if Enum.all?(normalized, &match?({:ok, _}, &1)) do
      {:ok, normalized |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()}
    else
      {:error, {:invalid_morph_surface_scopes, values}}
    end
  end

  defp scopes(value), do: {:error, {:invalid_morph_surface_scopes, value}}

  defp scope(value) when is_atom(value) and not is_nil(value), do: scope(Atom.to_string(value))
  defp scope(value) when is_binary(value) and value != "", do: {:ok, value}
  defp scope(value), do: {:error, {:invalid_morph_surface_scope, value}}

  defp prompt_tokens(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp prompt_tokens(value), do: {:error, {:invalid_morph_surface_prompt_tokens, value}}

  defp approval(value) when is_atom(value) and not is_nil(value),
    do: approval(Atom.to_string(value))

  defp approval(value) when value in @approval_requirements,
    do: {:ok, if(value == "human", do: :human, else: :host_policy)}

  defp approval(value), do: {:error, {:invalid_morph_surface_approval, value}}

  defp value(map, key, default \\ nil) do
    atom = String.to_existing_atom(key)
    Map.get(map, key, Map.get(map, atom, default))
  end

  defp unique_keyword?(values),
    do: values |> Keyword.keys() |> Enum.uniq() |> length() == length(values)

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
