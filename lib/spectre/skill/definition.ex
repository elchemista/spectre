defmodule Spectre.Skill.Definition do
  @moduledoc """
  Unified view of compiled and runtime Skill Definitions.

  Both origins are backed by `Spectre.Definition.Canonical`. Runtime input is
  data-only: it may declare closed prompt fragments, exact Flow routes and
  registered operation references, but never callbacks, modules or AST.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Program
  alias Spectre.Input
  alias Spectre.Prompt.Fragment
  alias Spectre.Skill.Applicability
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

  @runtime_fields [
    :id,
    :declared_version,
    :version,
    :publisher_ref,
    :description,
    :metadata,
    :applicability,
    :flows,
    :works,
    :prompt_fragments,
    :operation_refs,
    :prompt_budget
  ]

  @fragment_fields [
    :schema_version,
    :id,
    :content,
    :scope,
    :target,
    :position,
    :source,
    :trust,
    :placeholders,
    :provenance,
    :visibility,
    :requested_priority,
    :granted_priority,
    :budget_class,
    :token_cap,
    :condition_ref
  ]

  @runtime_fragment_governance [
    scope: :skill,
    target: :task,
    position: :end,
    trust: :instruction,
    granted_priority: :normal
  ]

  @enforce_keys [:canonical, :ref]
  defstruct [:canonical, :ref]

  @type t :: %__MODULE__{canonical: Canonical.t(), ref: Ref.t()}

  @doc "Lowers a compiled Skill module into the unified Definition view."
  @spec from_compiled(module() | Definition.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_compiled(source, opts \\ []) do
    with {:ok, canonical} <- Canonical.lower(source, opts), do: from_canonical(canonical)
  end

  @doc "Builds a strictly declarative runtime Skill."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_runtime_skill, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = atomize_known_keys(attrs, @runtime_fields)

    with :ok <- exact_keys(attrs, @runtime_fields, :unknown_runtime_skill_fields),
         {:ok, id} <- required(attrs, :id),
         {:ok, version} <- declared_version(attrs),
         {:ok, publisher_ref} <- publisher_ref(attrs),
         {:ok, description} <- description(attrs),
         {:ok, metadata} <- metadata(attrs),
         {:ok, applicability} <-
           attrs |> Map.get(:applicability, %{}) |> Applicability.new(),
         {:ok, fragments} <-
           runtime_fragments(Map.get(attrs, :prompt_fragments, []), publisher_ref),
         {:ok, budget} <- runtime_budget(fragments, Map.get(attrs, :prompt_budget, 512)),
         {:ok, programs} <- runtime_programs(Map.get(attrs, :works, [])),
         :ok <- validate_program_prompt_refs(programs, fragments),
         {:ok, authored_operation_refs} <-
           normalize_operation_refs(Map.get(attrs, :operation_refs, [])),
         {:ok, operation_refs} <- merge_program_operation_refs(authored_operation_refs, programs),
         {:ok, rules} <-
           runtime_flows(Map.get(attrs, :flows, []), fragments, operation_refs, programs),
         :ok <- unique_route_selectors(rules),
         {:ok, components} <-
           runtime_components(%{
             id: id,
             version: version,
             publisher_ref: publisher_ref,
             description: description,
             metadata: metadata,
             applicability: applicability,
             fragments: fragments,
             budget: budget,
             programs: programs,
             operation_refs: operation_refs,
             rules: rules
           }),
         {:ok, canonical} <-
           Canonical.new(
             kind: :skill,
             id: id,
             declared_version: version,
             origin: :runtime,
             components: components
           ) do
      from_canonical(canonical)
    end
  end

  def new(value), do: {:error, {:invalid_runtime_skill, shape(value)}}

  @doc "Alias that makes runtime construction explicit at call sites."
  @spec runtime(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def runtime(attrs), do: new(attrs)

  @doc "Builds a runtime Skill or raises with its stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid runtime Skill: #{inspect(reason)}"
    end
  end

  @doc "Validates and wraps an existing canonical Skill Definition."
  @spec from_canonical(Canonical.t()) :: {:ok, t()} | {:error, term()}
  def from_canonical(%Canonical{} = canonical) do
    with {:ok, canonical} <- normalize_canonical(canonical),
         :ok <- require_skill_canonical(canonical),
         :ok <- required_components(canonical),
         :ok <- reject_runtime_code(canonical),
         {:ok, _applicability} <- canonical_applicability(canonical),
         {:ok, fragments} <- canonical_fragments(canonical),
         {:ok, _budget} <- canonical_budget(canonical, fragments),
         {:ok, programs} <- canonical_programs(canonical),
         :ok <- validate_program_prompt_refs(programs, fragments),
         {:ok, operation_refs} <- canonical_operation_refs(canonical),
         :ok <- validate_program_operation_refs(programs, operation_refs),
         {:ok, rules} <- canonical_routes(canonical),
         :ok <- validate_handlers(rules, fragments, operation_refs, programs, canonical.origin),
         :ok <- unique_route_selectors(rules) do
      {:ok, %__MODULE__{canonical: canonical, ref: Canonical.ref(canonical)}}
    else
      {:error, _reason} = error -> error
    end
  end

  def from_canonical(value), do: {:error, {:invalid_canonical_skill, shape(value)}}

  @doc "Returns the shared canonical Definition envelope."
  @spec canonical(t()) :: Canonical.t()
  def canonical(%__MODULE__{canonical: canonical}), do: canonical

  @doc "Returns the content-addressed exact Definition Ref."
  @spec ref(t()) :: Ref.t()
  def ref(%__MODULE__{ref: ref}), do: ref

  @doc "Returns whether the Definition was compiled or supplied as runtime data."
  @spec origin(t()) :: :compiled | :runtime
  def origin(%__MODULE__{canonical: canonical}), do: canonical.origin

  @doc "Returns normalized structured applicability."
  @spec applicability(t()) :: Applicability.t()
  def applicability(%__MODULE__{canonical: canonical}) do
    {:ok, applicability} = canonical_applicability(canonical)
    applicability
  end

  @doc "Returns canonical routing rules."
  @spec routes(t()) :: [map()]
  def routes(%__MODULE__{canonical: canonical}) do
    {:ok, routes} = canonical_routes(canonical)
    routes
  end

  @doc "Returns canonical closed prompt fragments."
  @spec prompt_fragments(t()) :: [Fragment.t()]
  def prompt_fragments(%__MODULE__{canonical: canonical}) do
    {:ok, fragments} = canonical_fragments(canonical)
    fragments
  end

  @doc "Returns the Definition's immutable prompt budget."
  @spec prompt_budget(t()) :: PromptBudget.t()
  def prompt_budget(%__MODULE__{canonical: canonical}) do
    {:ok, fragments} = canonical_fragments(canonical)
    {:ok, budget} = canonical_budget(canonical, fragments)
    budget
  end

  @doc "Returns the registered operation identifiers requested by the Skill."
  @spec operation_refs(t()) :: [term()]
  def operation_refs(%__MODULE__{canonical: canonical}) do
    {:ok, refs} = canonical_operation_refs(canonical)
    refs
  end

  @doc "Returns the immutable data-driven Work programs declared by the Skill."
  @spec works(t()) :: [Program.t()]
  def works(%__MODULE__{canonical: canonical}) do
    {:ok, programs} = canonical_programs(canonical)
    programs
  end

  @doc "Fetches one data-driven Work by stable id."
  @spec work(t(), term()) :: {:ok, Program.t()} | {:error, term()}
  def work(%__MODULE__{} = definition, id) do
    case Enum.find(works(definition), &same_name?(&1.id, id)) do
      %Program{} = program -> {:ok, program}
      nil -> {:error, {:unknown_skill_work, id}}
    end
  end

  @doc "Returns origin-neutral semantic IR for equivalence and fixtures."
  @spec semantic_ir(t()) :: map()
  def semantic_ir(%__MODULE__{} = definition) do
    canonical = definition.canonical

    base = %{
      schema_version: 1,
      id: canonical.id,
      declared_version: canonical.declared_version,
      applicability: definition |> applicability() |> Applicability.to_data(),
      routes: definition |> routes() |> Enum.map(&semantic_route/1),
      prompt_fragments: definition |> prompt_fragments() |> Enum.map(&semantic_fragment/1),
      prompt_budget: definition |> prompt_budget() |> PromptBudget.to_data(),
      operation_refs: operation_refs(definition)
    }

    case works(definition) do
      [] ->
        base

      programs ->
        Map.merge(base, %{schema_version: 2, works: Enum.map(programs, &Program.to_data/1)})
    end
  end

  @doc "Returns true when compiled and runtime sources declare equal behavior."
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = left, %__MODULE__{} = right),
    do: semantic_ir(left) == semantic_ir(right)

  @doc "Routes an input inside one Skill and fails closed on ambiguity."
  @spec route(t(), Input.t() | String.t() | map() | term()) ::
          {:ok, map()} | {:error, term()}
  def route(%__MODULE__{} = definition, input) do
    with {:ok, input} <- normalize_input(input) do
      matches = Enum.filter(routes(definition), &route_matches?(&1, input))

      case matches do
        [rule] -> {:ok, rule}
        [] -> {:error, :skill_route_not_found}
        rules -> {:error, {:ambiguous_skill_route, Enum.map(rules, &get(&1, :label))}}
      end
    end
  end

  @doc "Runs positive/negative applicability examples as an anti-hijack corpus."
  @spec anti_hijack(t()) :: {:ok, map()} | {:error, term()}
  def anti_hijack(%__MODULE__{} = definition) do
    applicability = applicability(definition)

    positive_failures =
      Enum.reject(applicability.positive, &match?({:ok, _rule}, route(definition, &1)))

    negative_failures =
      Enum.filter(applicability.negative, &negative_example_matches?(definition, &1))

    if positive_failures == [] and negative_failures == [] do
      {:ok,
       %{
         schema_version: 1,
         positive: length(applicability.positive),
         negative: length(applicability.negative),
         definition_ref: Ref.to_string(definition.ref)
       }}
    else
      {:error,
       {:skill_anti_hijack_failed,
        %{positive_unmatched: positive_failures, negative_matched: negative_failures}}}
    end
  end

  @spec runtime_components(map()) :: {:ok, [Component.t()]} | {:error, term()}
  defp runtime_components(data) do
    labels = Enum.map(data.rules, &get(&1, :label))
    flow_paths = data.rules |> Enum.map(&get(&1, :flow_path, [])) |> Enum.uniq()

    payloads = %{
      identity: %{
        owner_ref: %{kind: :runtime_publisher, publisher_ref: data.publisher_ref},
        source_kind: :skill,
        source_schema_version: data.version
      },
      metadata: %{description: data.description, authored: data.metadata},
      applicability: %{
        declared: Applicability.to_data(data.applicability),
        inferred: %{scope: :skill, labels: labels, flow_paths: flow_paths}
      },
      routing: %{router: [], rules: data.rules},
      policies: %{declarations: %{}},
      prompt_fragments: %{
        fragments: Enum.map(data.fragments, &fragment_data/1),
        budget: PromptBudget.to_data(data.budget)
      },
      requirements: %{
        requested:
          Enum.map(data.operation_refs, fn operation ->
            %{kind: :operation, name: operation, mode: :read, opts: []}
          end),
        grants: []
      },
      skills: %{mounts: []},
      compiled_runtime: %{
        config: [],
        prompt_assets: :closed_runtime_fragments,
        protections: [],
        before_actions: [],
        after_actions: [],
        stack_ref: nil,
        stack_bindings: [],
        extensions: []
      },
      execution: %{
        schema_version: 1,
        programs: Enum.map(data.programs, &Program.to_data/1)
      },
      projection: %{
        generators: runtime_projection_generators(data.programs)
      }
    }

    component_specs(data.programs)
    |> Enum.reduce_while({:ok, []}, fn {type, schema_ref, criticality}, {:ok, components} ->
      case Component.new(
             component_type: type,
             schema_ref: schema_ref,
             criticality: criticality,
             payload: Map.fetch!(payloads, type)
           ) do
        {:ok, component} -> {:cont, {:ok, [component | components]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  @spec component_specs([Program.t()]) :: [tuple()]
  defp component_specs([]), do: @component_specs
  defp component_specs(_programs), do: @component_specs ++ [@execution_component]

  @spec runtime_projection_generators([Program.t()]) :: [map()]
  defp runtime_projection_generators(programs) do
    generators = [
      %{id: "spectre.projection.audit", version: 1, contract_ref: "spectre.projection/1"},
      %{
        id: "spectre.projection.routing",
        version: 1,
        contract_ref: "spectre.projection/1"
      }
    ]

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
  end

  @spec runtime_fragments(term(), String.t()) ::
          {:ok, [Fragment.t()]} | {:error, term()}
  defp runtime_fragments(fragments, publisher_ref) when is_list(fragments) do
    fragments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {fragment, index}, {:ok, normalized} ->
      case runtime_fragment(fragment, publisher_ref) do
        {:ok, fragment} -> {:cont, {:ok, [fragment | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_runtime_prompt_fragment, index, reason}}}
      end
    end)
    |> reverse_result()
    |> unique_fragments()
  end

  defp runtime_fragments(value, _publisher_ref),
    do: {:error, {:invalid_runtime_prompt_fragments, shape(value)}}

  @spec runtime_fragment(term(), String.t()) :: {:ok, Fragment.t()} | {:error, term()}
  defp runtime_fragment(%Fragment{} = fragment, publisher_ref),
    do: fragment |> Fragment.canonical_data() |> runtime_fragment(publisher_ref)

  defp runtime_fragment(fragment, publisher_ref)
       when is_map(fragment) and not is_struct(fragment) do
    attrs = atomize_known_keys(fragment, @fragment_fields)

    with :ok <- exact_keys(attrs, @fragment_fields, :unknown_runtime_prompt_fragment_fields),
         {:ok, content} <- closed_content(Map.get(attrs, :content)),
         {:ok, closed, observed_placeholders} <- Fragment.close_template(content),
         attrs <-
           attrs
           |> Map.put(:content, closed)
           |> Map.put(:scope, :skill)
           |> Map.put(:target, :task)
           |> Map.put(:position, :end)
           |> Map.put(:source, %{kind: :runtime_authored, publisher_ref: publisher_ref})
           |> Map.put(:trust, :instruction)
           |> Map.put(:placeholders, observed_placeholders)
           |> Map.put(:provenance, %{publisher_ref: publisher_ref})
           |> Map.put(:granted_priority, :normal),
         {:ok, attrs} <- normalize_fragment_enums(attrs) do
      Fragment.canonical(attrs)
    end
  end

  defp runtime_fragment(value, _publisher_ref),
    do: {:error, {:invalid_runtime_prompt_fragment, shape(value)}}

  @spec closed_content(term()) :: {:ok, String.t()} | {:error, term()}
  defp closed_content(content) when is_binary(content), do: {:ok, content}
  defp closed_content(_content), do: {:error, :runtime_prompt_fragment_requires_closed_content}

  @spec normalize_fragment_enums(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_fragment_enums(attrs) do
    fields = [
      target: [:instructions, :context, :task],
      position: [:start, :end, :replace],
      trust: [:instruction, :data],
      visibility: [:private, :agent, :operator, :public],
      requested_priority: [:low, :normal, :high],
      granted_priority: [:low, :normal, :high],
      budget_class: [:small, :standard, :large]
    ]

    Enum.reduce_while(fields, {:ok, attrs}, fn {field, allowed}, {:ok, normalized} ->
      case normalize_enum(Map.get(normalized, field), allowed) do
        {:ok, nil} -> {:cont, {:ok, normalized}}
        {:ok, value} -> {:cont, {:ok, Map.put(normalized, field, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec runtime_budget([Fragment.t()], term()) :: {:ok, PromptBudget.t()} | {:error, term()}
  defp runtime_budget(fragments, cap) when is_integer(cap) do
    PromptBudget.new(fragments, token_cap: cap, require_fragment_caps?: true)
  end

  defp runtime_budget(fragments, cap) when is_map(cap) do
    token_cap = get(cap, :token_cap)
    reserved = get(cap, :reserved_tokens, 0)

    PromptBudget.new(fragments,
      token_cap: token_cap,
      reserved_tokens: reserved,
      require_fragment_caps?: true
    )
  end

  defp runtime_budget(_fragments, value),
    do: {:error, {:invalid_runtime_skill_prompt_budget, value}}

  @spec runtime_programs(term()) :: {:ok, [Program.t()]} | {:error, term()}
  defp runtime_programs(programs) when is_list(programs) do
    programs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {program, index}, {:ok, normalized} ->
      case Program.new(program) do
        {:ok, program} -> {:cont, {:ok, [program | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_runtime_work, index, reason}}}
      end
    end)
    |> reverse_result()
    |> unique_programs()
  end

  defp runtime_programs(value), do: {:error, {:invalid_runtime_works, shape(value)}}

  @spec unique_programs({:ok, [Program.t()]} | {:error, term()}) ::
          {:ok, [Program.t()]} | {:error, term()}
  defp unique_programs({:error, _reason} = error), do: error

  defp unique_programs({:ok, programs}) do
    case duplicate_by(programs, & &1.id) do
      nil -> {:ok, Enum.sort_by(programs, & &1.id)}
      id -> {:error, {:duplicate_runtime_work, id}}
    end
  end

  @spec merge_program_operation_refs([term()], [Program.t()]) ::
          {:ok, [term()]} | {:error, term()}
  defp merge_program_operation_refs(authored, programs) do
    refs = Enum.flat_map(programs, &Program.operation_refs/1)

    merged =
      Enum.reduce(refs, authored, fn ref, acc ->
        if Enum.any?(acc, &same_name?(&1, ref)), do: acc, else: [ref | acc]
      end)

    normalize_operation_refs(merged)
  end

  @spec validate_program_prompt_refs([Program.t()], [Fragment.t()]) ::
          :ok | {:error, term()}
  defp validate_program_prompt_refs(programs, fragments) do
    prompt_ids = Enum.map(fragments, & &1.id)

    Enum.reduce_while(programs, :ok, fn program, :ok ->
      case Enum.find(Program.prompt_refs(program), fn ref ->
             not Enum.any?(prompt_ids, &same_name?(&1, ref))
           end) do
        nil -> {:cont, :ok}
        ref -> {:halt, {:error, {:unknown_execution_prompt_ref, program.id, ref}}}
      end
    end)
  end

  @spec validate_program_operation_refs([Program.t()], [term()]) ::
          :ok | {:error, term()}
  defp validate_program_operation_refs(programs, operation_refs) do
    Enum.reduce_while(programs, :ok, fn program, :ok ->
      case Enum.find(Program.operation_refs(program), fn ref ->
             not Enum.any?(operation_refs, &same_name?(&1, ref))
           end) do
        nil -> {:cont, :ok}
        ref -> {:halt, {:error, {:undeclared_execution_operation_ref, program.id, ref}}}
      end
    end)
  end

  @spec runtime_flows(term(), [Fragment.t()], [term()], [Program.t()]) ::
          {:ok, [map()]} | {:error, term()}
  defp runtime_flows(flows, fragments, operation_refs, programs) when is_list(flows) do
    prompt_ids = Enum.map(fragments, & &1.id)
    work_ids = Enum.map(programs, & &1.id)

    flows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {flow, flow_index}, {:ok, rules} ->
      case runtime_flow(flow, prompt_ids, operation_refs, work_ids) do
        {:ok, flow_rules} -> {:cont, {:ok, Enum.reverse(flow_rules, rules)}}
        {:error, reason} -> {:halt, {:error, {:invalid_runtime_flow, flow_index, reason}}}
      end
    end)
    |> reverse_result()
  end

  defp runtime_flows(value, _fragments, _operation_refs, _programs),
    do: {:error, {:invalid_runtime_flows, shape(value)}}

  @spec runtime_flow(term(), [term()], [term()], [String.t()]) ::
          {:ok, [map()]} | {:error, term()}
  defp runtime_flow(flow, prompt_ids, operation_refs, work_ids) when is_map(flow) do
    flow = atomize_known_keys(flow, [:id, :routes])

    with :ok <- exact_keys(flow, [:id, :routes], :unknown_runtime_flow_fields),
         {:ok, id} <- required(flow, :id),
         routes when is_list(routes) <- Map.get(flow, :routes),
         {:ok, rules} <- runtime_rules(routes, id, prompt_ids, operation_refs, work_ids) do
      {:ok, rules}
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_runtime_flow_routes, shape(value)}}
    end
  end

  defp runtime_flow(value, _prompt_ids, _operation_refs, _work_ids),
    do: {:error, {:invalid_runtime_flow, shape(value)}}

  @spec runtime_rules([term()], term(), [term()], [term()], [String.t()]) ::
          {:ok, [map()]} | {:error, term()}
  defp runtime_rules(routes, flow, prompt_ids, operation_refs, work_ids) do
    routes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {route, index}, {:ok, rules} ->
      case runtime_rule(route, flow, prompt_ids, operation_refs, work_ids) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        {:error, reason} -> {:halt, {:error, {:invalid_runtime_route, index, reason}}}
      end
    end)
    |> reverse_result()
  end

  @spec runtime_rule(term(), term(), [term()], [term()], [String.t()]) ::
          {:ok, map()} | {:error, term()}
  defp runtime_rule(route, flow, prompt_ids, operation_refs, work_ids) when is_map(route) do
    fields = [:label, :match, :check, :handler, :input]
    route = atomize_known_keys(route, fields)

    with :ok <- exact_keys(route, fields, :unknown_runtime_route_fields),
         {:ok, label} <- required(route, :label),
         {:ok, check} <- exact_match(Map.get(route, :match, Map.get(route, :check))),
         {:ok, handler} <-
           runtime_handler(
             Map.get(route, :handler),
             Map.get(route, :input),
             prompt_ids,
             operation_refs,
             work_ids
           ) do
      {:ok,
       %{
         label: label,
         flow: flow,
         flow_path: [flow],
         handler: handler,
         regex: [],
         bag: [],
         jaro: [],
         embedding: [],
         cache: true,
         learn: false,
         checks: [check],
         via: [],
         constraints: [],
         global?: false,
         opts: [],
         prompt_fragment_scopes: []
       }}
    end
  end

  defp runtime_rule(value, _flow, _prompt_ids, _operation_refs, _work_ids),
    do: {:error, {:invalid_runtime_route, shape(value)}}

  @spec exact_match(term()) :: {:ok, {:text, String.t()}} | {:error, term()}
  defp exact_match({kind, text}) when kind in [:exact, :text] and is_binary(text) and text != "",
    do: {:ok, {:text, text}}

  defp exact_match(match) when is_map(match) do
    kind = get(match, :kind)
    value = get(match, :value)

    if kind in [:exact, :text, "exact", "text"] and is_binary(value) and value != "",
      do: {:ok, {:text, value}},
      else: {:error, {:invalid_runtime_exact_match, match}}
  end

  defp exact_match(value), do: {:error, {:invalid_runtime_exact_match, value}}

  @spec runtime_handler(term(), term(), [term()], [term()], [String.t()]) ::
          {:ok, map()} | {:error, term()}
  defp runtime_handler({:operation, operation}, input, _prompt_ids, operation_refs, _work_ids),
    do: operation_handler(operation, input || :input, operation_refs)

  defp runtime_handler(
         {:operation, operation, opts},
         input,
         _prompt_ids,
         operation_refs,
         _work_ids
       )
       when is_list(opts) do
    operation_handler(operation, input || Keyword.get(opts, :input, :input), operation_refs)
  end

  defp runtime_handler({:reply, prompt}, _input, prompt_ids, _operation_refs, _work_ids),
    do: reply_handler(prompt, prompt_ids)

  defp runtime_handler({:work, work}, input, _prompt_ids, _operation_refs, work_ids),
    do: work_handler(work, input || :input, work_ids)

  defp runtime_handler({:work, work, opts}, input, _prompt_ids, _operation_refs, work_ids)
       when is_list(opts),
       do: work_handler(work, input || Keyword.get(opts, :input, :input), work_ids)

  defp runtime_handler(handler, route_input, prompt_ids, operation_refs, work_ids)
       when is_map(handler) do
    kind = get(handler, :kind)

    case kind do
      value when value in [:operation, "operation"] ->
        operation = get(handler, :operation_ref, get(handler, :operation))
        input = route_input || get(handler, :input, :input)
        operation_handler(operation, input, operation_refs)

      value when value in [:reply, "reply"] ->
        reply_handler(get(handler, :prompt), prompt_ids)

      value when value in [:work, "work"] ->
        work = get(handler, :work_ref, get(handler, :work))
        input = route_input || get(handler, :input, :input)
        work_handler(work, input, work_ids)

      _other ->
        {:error, {:unsupported_runtime_skill_handler, kind}}
    end
  end

  defp runtime_handler(value, _input, _prompt_ids, _operation_refs, _work_ids),
    do: {:error, {:unsupported_runtime_skill_handler, value}}

  @spec operation_handler(term(), term(), [term()]) :: {:ok, map()} | {:error, term()}
  defp operation_handler(operation, input, operation_refs) do
    with true <- member?(operation_refs, operation),
         {:ok, input} <- normalize_operation_input(input) do
      {:ok, %{kind: :operation, operation_ref: operation, input: input, opts: []}}
    else
      false -> {:error, {:undeclared_runtime_skill_operation, operation}}
      {:error, _reason} = error -> error
    end
  end

  @spec reply_handler(term(), [term()]) :: {:ok, map()} | {:error, term()}
  defp reply_handler(prompt, prompt_ids) do
    if member?(prompt_ids, prompt),
      do: {:ok, %{kind: :reply, prompt: prompt, opts: []}},
      else: {:error, {:unknown_runtime_skill_prompt, prompt}}
  end

  @spec work_handler(term(), term(), [String.t()]) :: {:ok, map()} | {:error, term()}
  defp work_handler(work, input, work_ids) do
    with {:ok, work_ref} <- stable_runtime_name(work, :work_ref),
         true <- work_ref in work_ids,
         {:ok, input} <- normalize_operation_input(input) do
      {:ok, %{kind: :work, work_ref: work_ref, input: input, opts: []}}
    else
      false -> {:error, {:unknown_runtime_skill_work, work}}
      {:error, _reason} = error -> error
    end
  end

  @spec stable_runtime_name(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp stable_runtime_name(value, field) when is_atom(value) and not is_nil(value) do
    name = Atom.to_string(value)

    if String.starts_with?(name, "Elixir."),
      do: {:error, {:runtime_skill_code_reference_forbidden, field}},
      else: {:ok, name}
  end

  defp stable_runtime_name(value, _field) when is_binary(value) and value != "",
    do: {:ok, value}

  defp stable_runtime_name(value, field),
    do: {:error, {:invalid_runtime_skill_name, field, value}}

  @spec normalize_operation_input(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_operation_input(value) when value in [:text, "text"], do: {:ok, :text}
  defp normalize_operation_input(value) when value in [:input, "input"], do: {:ok, :input}

  defp normalize_operation_input({:fixed, value}) do
    case Value.validate(value) do
      :ok -> {:ok, {:fixed, value}}
      {:error, reason} -> {:error, {:nonportable_runtime_operation_input, reason}}
    end
  end

  defp normalize_operation_input(%{"kind" => "fixed", "value" => value}),
    do: normalize_operation_input({:fixed, value})

  defp normalize_operation_input(%{kind: :fixed, value: value}),
    do: normalize_operation_input({:fixed, value})

  defp normalize_operation_input(value),
    do: {:error, {:invalid_runtime_operation_input, value}}

  @spec normalize_operation_refs(term()) :: {:ok, [term()]} | {:error, term()}
  defp normalize_operation_refs(refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, %{}}, fn ref, {:ok, unique} ->
      case add_operation_ref(unique, ref) do
        {:ok, unique} -> {:cont, {:ok, unique}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, unique} -> {:ok, unique |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_operation_refs(value),
    do: {:error, {:invalid_runtime_operation_refs, shape(value)}}

  @spec add_operation_ref(map(), term()) :: {:ok, map()} | {:error, term()}
  defp add_operation_ref(unique, ref) do
    with true <- valid_ref?(ref),
         {:ok, encoded} <- Value.encode(ref) do
      {:ok, Map.put(unique, encoded, ref)}
    else
      false -> {:error, {:invalid_runtime_operation_ref, ref}}
      {:error, reason} -> {:error, {:invalid_runtime_operation_ref, reason}}
    end
  end

  @spec normalize_canonical(Canonical.t()) :: {:ok, Canonical.t()} | {:error, term()}
  defp normalize_canonical(%Canonical{} = canonical) do
    with {:ok, canonical} <- canonical |> Map.from_struct() |> Canonical.new() do
      canonical |> Canonical.to_data() |> Canonical.from_data()
    end
  end

  @spec require_skill_canonical(Canonical.t()) :: :ok | {:error, term()}
  defp require_skill_canonical(%Canonical{kind: :skill}), do: :ok

  defp require_skill_canonical(%Canonical{kind: kind}),
    do: {:error, {:canonical_definition_is_not_skill, kind}}

  @spec required_components(Canonical.t()) :: :ok | {:error, term()}
  defp required_components(canonical) do
    case Enum.find(@component_specs, fn {type, _schema, _criticality} ->
           not match?({:ok, _component}, Canonical.fetch_component(canonical, type))
         end) do
      nil -> :ok
      {type, _schema, _criticality} -> {:error, {:missing_skill_definition_component, type}}
    end
  end

  @spec reject_runtime_code(Canonical.t()) :: :ok | {:error, term()}
  defp reject_runtime_code(%Canonical{origin: :compiled}), do: :ok

  defp reject_runtime_code(%Canonical{origin: :runtime} = canonical) do
    case code_ref_path(Canonical.to_data(canonical), []) do
      nil -> :ok
      path -> {:error, {:runtime_skill_contains_code_ref, path}}
    end
  end

  @spec code_ref_path(term(), [term()]) :: [term()] | nil
  defp code_ref_path(%{"$spectre_type" => "code_ref"}, path), do: Enum.reverse(path)

  defp code_ref_path(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      code_ref_path(key, [{:key, key} | path]) || code_ref_path(item, [key | path])
    end)
  end

  defp code_ref_path(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {item, index} -> code_ref_path(item, [index | path]) end)
  end

  defp code_ref_path(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> code_ref_path(path)

  defp code_ref_path(_value, _path), do: nil

  @spec canonical_applicability(Canonical.t()) ::
          {:ok, Applicability.t()} | {:error, term()}
  defp canonical_applicability(canonical) do
    with {:ok, payload} <- component_payload(canonical, :applicability),
         declared when is_map(declared) <- get(payload, :declared, %{}) do
      Applicability.new(declared)
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_canonical_skill_applicability, value}}
    end
  end

  @spec canonical_fragments(Canonical.t()) :: {:ok, [Fragment.t()]} | {:error, term()}
  defp canonical_fragments(canonical) do
    with {:ok, payload} <- component_payload(canonical, :prompt_fragments),
         fragments when is_list(fragments) <- get(payload, :fragments, []),
         {:ok, fragments} <- restore_fragments(fragments),
         :ok <- validate_runtime_fragment_governance(canonical, fragments) do
      {:ok, fragments}
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_canonical_skill_prompt_fragments, value}}
    end
  end

  @spec validate_runtime_fragment_governance(Canonical.t(), [Fragment.t()]) ::
          :ok | {:error, term()}
  defp validate_runtime_fragment_governance(%Canonical{origin: :compiled}, _fragments), do: :ok

  defp validate_runtime_fragment_governance(%Canonical{origin: :runtime} = canonical, fragments) do
    with {:ok, publisher_ref} <- canonical_runtime_publisher_ref(canonical) do
      expected =
        @runtime_fragment_governance ++
          [
            source: %{kind: :runtime_authored, publisher_ref: publisher_ref},
            provenance: %{publisher_ref: publisher_ref}
          ]

      validate_runtime_fragment_values(fragments, expected)
    end
  end

  @spec validate_runtime_fragment_values([Fragment.t()], keyword()) ::
          :ok | {:error, term()}
  defp validate_runtime_fragment_values(fragments, expected) do
    fragments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {fragment, index}, :ok ->
      violations =
        expected
        |> Enum.reject(fn {field, expected} -> Map.fetch!(fragment, field) == expected end)
        |> Map.new(fn {field, _expected} -> {field, Map.fetch!(fragment, field)} end)

      if violations == %{},
        do: {:cont, :ok},
        else: {:halt, {:error, {:runtime_skill_prompt_governance_violation, index, violations}}}
    end)
  end

  @spec canonical_runtime_publisher_ref(Canonical.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp canonical_runtime_publisher_ref(canonical) do
    with {:ok, identity} <- component_payload(canonical, :identity),
         owner when is_map(owner) <- get(identity, :owner_ref, %{}),
         publisher_ref when is_binary(publisher_ref) and publisher_ref != "" <-
           get(owner, :publisher_ref) do
      {:ok, publisher_ref}
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_runtime_skill_publisher_ref, value}}
    end
  end

  @spec restore_fragments([map()]) :: {:ok, [Fragment.t()]} | {:error, term()}
  defp restore_fragments(fragments) do
    fragments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {data, index}, {:ok, restored} ->
      case fragment_from_data(data) do
        {:ok, fragment} ->
          {:cont, {:ok, [fragment | restored]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_canonical_skill_prompt_fragment, index, reason}}}
      end
    end)
    |> reverse_result()
  end

  @spec fragment_from_data(term()) :: {:ok, Fragment.t()} | {:error, term()}
  defp fragment_from_data(data) when is_map(data) do
    data
    |> atomize_known_keys(@fragment_fields ++ [:digest])
    |> Map.take(@fragment_fields)
    |> normalize_fragment_enums()
    |> case do
      {:ok, attrs} -> Fragment.canonical(attrs)
      {:error, _reason} = error -> error
    end
  end

  defp fragment_from_data(value), do: {:error, {:invalid_prompt_fragment_data, shape(value)}}

  @spec canonical_budget(Canonical.t(), [Fragment.t()]) ::
          {:ok, PromptBudget.t()} | {:error, term()}
  defp canonical_budget(canonical, fragments) do
    with {:ok, payload} <- component_payload(canonical, :prompt_fragments) do
      case get(payload, :budget) do
        nil when canonical.origin == :compiled -> PromptBudget.new(fragments)
        nil -> {:error, :runtime_skill_missing_prompt_budget}
        budget -> verify_canonical_budget(canonical.origin, fragments, budget)
      end
    end
  end

  @spec canonical_programs(Canonical.t()) :: {:ok, [Program.t()]} | {:error, term()}
  defp canonical_programs(%Canonical{} = canonical) do
    case Canonical.fetch_component(canonical, :execution) do
      {:ok, %Component{} = component} -> canonical_program_component(component)
      {:error, {:unknown_definition_component, :execution}} -> {:ok, []}
    end
  end

  @spec canonical_program_component(Component.t()) ::
          {:ok, [Program.t()]} | {:error, term()}
  defp canonical_program_component(%Component{} = component) do
    cond do
      component.schema_ref != elem(@execution_component, 1) ->
        {:error, {:invalid_skill_execution_schema_ref, component.schema_ref}}

      component.criticality != elem(@execution_component, 2) ->
        {:error, {:invalid_skill_execution_criticality, component.criticality}}

      not is_map(component.payload) ->
        {:error, {:invalid_skill_execution_payload, shape(component.payload)}}

      not exact_named_keys?(component.payload, [:schema_version, :programs]) ->
        {:error, :unknown_skill_execution_payload_fields}

      get(component.payload, :schema_version) != 1 ->
        {:error, {:unsupported_skill_execution_schema, get(component.payload, :schema_version)}}

      not is_list(get(component.payload, :programs)) ->
        {:error, {:invalid_skill_execution_programs, shape(get(component.payload, :programs))}}

      true ->
        component.payload
        |> get(:programs)
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {data, index}, {:ok, programs} ->
          case Program.from_data(data) do
            {:ok, program} ->
              {:cont, {:ok, [program | programs]}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_canonical_skill_work, index, reason}}}
          end
        end)
        |> reverse_result()
        |> unique_programs()
    end
  end

  @spec verify_canonical_budget(:compiled | :runtime, [Fragment.t()], term()) ::
          {:ok, PromptBudget.t()} | {:error, term()}
  defp verify_canonical_budget(origin, fragments, budget) do
    with {:ok, declared} <- PromptBudget.from_data(budget),
         {:ok, derived} <-
           PromptBudget.new(fragments,
             token_cap: declared.token_cap,
             reserved_tokens: declared.reserved_tokens,
             require_fragment_caps?: origin == :runtime
           ),
         :ok <- exact_canonical_budget(declared, derived) do
      {:ok, derived}
    end
  end

  @spec exact_canonical_budget(PromptBudget.t(), PromptBudget.t()) :: :ok | {:error, term()}
  defp exact_canonical_budget(budget, budget), do: :ok

  defp exact_canonical_budget(declared, derived) do
    {:error,
     {:canonical_skill_prompt_budget_mismatch, PromptBudget.to_data(declared),
      PromptBudget.to_data(derived)}}
  end

  @spec canonical_operation_refs(Canonical.t()) :: {:ok, [term()]} | {:error, term()}
  defp canonical_operation_refs(canonical) do
    with {:ok, payload} <- component_payload(canonical, :requirements),
         requested when is_list(requested) <- get(payload, :requested, []),
         :ok <- validate_canonical_entries(requested, :requirement) do
      requested
      |> Enum.filter(&(get(&1, :kind) in [:operation, "operation"]))
      |> Enum.map(&get(&1, :name))
      |> normalize_operation_refs()
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_canonical_skill_requirements, value}}
    end
  end

  @spec canonical_routes(Canonical.t()) :: {:ok, [map()]} | {:error, term()}
  defp canonical_routes(canonical) do
    with {:ok, payload} <- component_payload(canonical, :routing),
         routes when is_list(routes) <- get(payload, :rules, []),
         :ok <- validate_canonical_entries(routes, :route) do
      {:ok, routes}
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_canonical_skill_routing, value}}
    end
  end

  @spec validate_canonical_entries([term()], :requirement | :route) :: :ok | {:error, term()}
  defp validate_canonical_entries(entries, type) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {entry, _index}, :ok when is_map(entry) ->
        {:cont, :ok}

      {entry, index}, :ok ->
        {:halt, {:error, {canonical_entry_error(type), index, shape(entry)}}}
    end)
  end

  defp canonical_entry_error(:requirement), do: :invalid_canonical_skill_requirement
  defp canonical_entry_error(:route), do: :invalid_canonical_skill_route

  @spec validate_handlers(
          [map()],
          [Fragment.t()],
          [term()],
          [Program.t()],
          :compiled | :runtime
        ) ::
          :ok | {:error, term()}
  defp validate_handlers(rules, fragments, operation_refs, programs, origin) do
    prompt_ids = Enum.map(fragments, & &1.id)
    work_ids = Enum.map(programs, & &1.id)

    rules
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {rule, index}, :ok ->
      handler = get(rule, :handler)

      case validate_handler(handler, prompt_ids, operation_refs, work_ids, origin) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_skill_handler, index, reason}}}
      end
    end)
  end

  @spec validate_handler(term(), [term()], [term()], [String.t()], :compiled | :runtime) ::
          :ok | {:error, term()}
  defp validate_handler(handler, prompt_ids, operation_refs, work_ids, origin)
       when is_map(handler) do
    kind = get(handler, :kind)

    with :ok <- validate_runtime_handler_shape(handler, kind, origin) do
      cond do
        kind in [:operation, "operation"] and
            not member?(operation_refs, get(handler, :operation_ref)) ->
          {:error, {:undeclared_skill_operation, get(handler, :operation_ref)}}

        kind in [:reply, "reply"] and not member?(prompt_ids, get(handler, :prompt)) ->
          {:error, {:unknown_skill_prompt, get(handler, :prompt)}}

        kind in [:work, "work"] and
            not Enum.any?(work_ids, &same_name?(&1, get(handler, :work_ref))) ->
          {:error, {:unknown_skill_work, get(handler, :work_ref)}}

        origin == :runtime and
            kind not in [:operation, "operation", :reply, "reply", :work, "work"] ->
          {:error, {:unsupported_runtime_skill_handler, kind}}

        true ->
          :ok
      end
    end
  end

  defp validate_handler(handler, _prompt_ids, _operation_refs, _work_ids, _origin),
    do: {:error, {:invalid_canonical_skill_handler, handler}}

  @spec validate_runtime_handler_shape(map(), term(), :compiled | :runtime) ::
          :ok | {:error, term()}
  defp validate_runtime_handler_shape(_handler, _kind, :compiled), do: :ok

  defp validate_runtime_handler_shape(handler, kind, :runtime) do
    allowed =
      case kind do
        value when value in [:operation, "operation"] ->
          [:kind, :operation_ref, :input, :opts]

        value when value in [:reply, "reply"] ->
          [:kind, :prompt, :opts]

        value when value in [:work, "work"] ->
          [:kind, :work_ref, :input, :opts]

        _other ->
          [:kind]
      end

    cond do
      not exact_named_keys?(handler, allowed) ->
        {:error, :unknown_runtime_skill_handler_fields}

      :opts in allowed and get(handler, :opts) != [] ->
        {:error, :runtime_skill_handler_options_must_be_empty}

      true ->
        :ok
    end
  end

  @spec exact_named_keys?(map(), [atom()]) :: boolean()
  defp exact_named_keys?(value, expected) do
    allowed = expected ++ Enum.map(expected, &Atom.to_string/1)

    Enum.all?(Map.keys(value), &(&1 in allowed)) and
      Enum.all?(expected, fn key ->
        Map.has_key?(value, key) != Map.has_key?(value, Atom.to_string(key))
      end)
  end

  @spec unique_route_selectors([map()]) :: :ok | {:error, term()}
  defp unique_route_selectors(rules) do
    rules
    |> Enum.reduce_while({:ok, %{}}, fn rule, {:ok, seen} ->
      selector =
        Value.encode!({
          get(rule, :flow_path, []),
          get(rule, :checks, []),
          get(rule, :regex, []),
          get(rule, :bag, []),
          get(rule, :jaro, []),
          get(rule, :embedding, [])
        })

      case Map.fetch(seen, selector) do
        {:ok, label} ->
          {:halt, {:error, {:conflicting_skill_route, label, get(rule, :label)}}}

        :error ->
          {:cont, {:ok, Map.put(seen, selector, get(rule, :label))}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    ArgumentError -> {:error, :nonportable_skill_route_selector}
  end

  @spec unique_fragments({:ok, [Fragment.t()]} | {:error, term()}) ::
          {:ok, [Fragment.t()]} | {:error, term()}
  defp unique_fragments({:error, _reason} = error), do: error

  defp unique_fragments({:ok, fragments}) do
    case duplicate_by(fragments, & &1.id) do
      nil -> {:ok, fragments}
      id -> {:error, {:duplicate_runtime_prompt_fragment, id}}
    end
  end

  @spec component_payload(Canonical.t(), atom()) :: {:ok, map()} | {:error, term()}
  defp component_payload(canonical, type) do
    with {:ok, component} <- Canonical.fetch_component(canonical, type),
         true <- is_map(component.payload) do
      {:ok, component.payload}
    else
      false -> {:error, {:invalid_skill_component_payload, type}}
      {:error, _reason} = error -> error
    end
  end

  @spec semantic_route(map()) :: map()
  defp semantic_route(rule) do
    %{
      label: get(rule, :label),
      flow_path: get(rule, :flow_path, []),
      checks: get(rule, :checks, []),
      regex: get(rule, :regex, []),
      bag: get(rule, :bag, []),
      jaro: get(rule, :jaro, []),
      embedding: get(rule, :embedding, []),
      handler: semantic_handler(get(rule, :handler, %{}))
    }
  end

  @spec semantic_handler(map()) :: map()
  defp semantic_handler(handler) do
    case get(handler, :kind) do
      :operation ->
        %{
          kind: :operation,
          operation_ref: get(handler, :operation_ref),
          input: get(handler, :input, :input)
        }

      :reply ->
        %{kind: :reply, prompt: get(handler, :prompt)}

      :work ->
        %{
          kind: :work,
          work_ref: get(handler, :work_ref),
          input: get(handler, :input, :input)
        }

      kind ->
        %{kind: kind}
    end
  end

  @spec semantic_fragment(Fragment.t()) :: map()
  defp semantic_fragment(fragment) do
    fragment
    |> Fragment.canonical_data()
    |> Map.drop([:source, :provenance])
  end

  @spec route_matches?(map(), Input.t()) :: boolean()
  defp route_matches?(rule, input) do
    checks = get(rule, :checks, [])
    checks != [] and Enum.all?(checks, &check_matches?(&1, input))
  end

  @spec check_matches?(term(), Input.t()) :: boolean()
  defp check_matches?({field, expected}, input) when field in [:text, "text"],
    do: input.text == expected

  defp check_matches?([field, expected], input) when field in [:text, "text"],
    do: input.text == expected

  defp check_matches?(_check, _input), do: false

  @spec negative_example_matches?(t(), String.t()) :: boolean()
  defp negative_example_matches?(definition, example) do
    case route(definition, example) do
      {:ok, _rule} -> true
      {:error, {:ambiguous_skill_route, _labels}} -> true
      {:error, _reason} -> false
    end
  end

  @spec normalize_input(term()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(input) do
    {:ok, Input.new(input)}
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, {:invalid_skill_input, shape(input)}}
  end

  @spec fragment_data(Fragment.t()) :: map()
  defp fragment_data(fragment) do
    fragment
    |> Fragment.canonical_data()
    |> Map.put(:digest, fragment.digest)
  end

  @spec declared_version(map()) :: {:ok, pos_integer()} | {:error, term()}
  defp declared_version(attrs) do
    version = Map.get(attrs, :declared_version, Map.get(attrs, :version, 1))

    if is_integer(version) and version > 0,
      do: {:ok, version},
      else: {:error, {:invalid_runtime_skill_version, version}}
  end

  @spec publisher_ref(map()) :: {:ok, String.t()} | {:error, term()}
  defp publisher_ref(attrs) do
    case Map.get(attrs, :publisher_ref) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_runtime_skill_publisher_ref, value}}
    end
  end

  @spec description(map()) :: {:ok, String.t() | nil} | {:error, term()}
  defp description(attrs) do
    case Map.get(attrs, :description) do
      value when is_nil(value) or is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_runtime_skill_description, value}}
    end
  end

  @spec metadata(map()) :: {:ok, map()} | {:error, term()}
  defp metadata(attrs) do
    value = Map.get(attrs, :metadata, %{})

    with true <- is_map(value) and not is_struct(value),
         :ok <- Value.validate(value) do
      {:ok, value}
    else
      false -> {:error, {:invalid_runtime_skill_metadata, shape(value)}}
      {:error, reason} -> {:error, {:nonportable_runtime_skill_metadata, reason}}
    end
  end

  @spec required(map(), atom()) :: {:ok, term()} | {:error, term()}
  defp required(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, nil} -> {:error, {:missing_runtime_skill_field, key}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_runtime_skill_field, key}}
    end
  end

  @spec exact_keys(map(), [atom()], atom()) :: :ok | {:error, term()}
  defp exact_keys(attrs, allowed, error) do
    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {error, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec atomize_known_keys(map(), [atom()]) :: map()
  defp atomize_known_keys(attrs, fields) do
    Enum.reduce(fields, attrs, fn key, normalized ->
      string = Atom.to_string(key)

      case Map.fetch(normalized, string) do
        {:ok, value} -> normalized |> Map.delete(string) |> Map.put_new(key, value)
        :error -> normalized
      end
    end)
  end

  @spec normalize_enum(term(), [atom()]) :: {:ok, atom() | nil} | {:error, term()}
  defp normalize_enum(nil, _allowed), do: {:ok, nil}

  defp normalize_enum(value, allowed) when is_atom(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_runtime_skill_enum, value, allowed}}
  end

  defp normalize_enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_runtime_skill_enum, value, allowed}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_enum(value, allowed),
    do: {:error, {:invalid_runtime_skill_enum, value, allowed}}

  @spec member?([term()], term()) :: boolean()
  defp member?(values, value) do
    encoded = Value.encode!(value)
    Enum.any?(values, &(Value.encode!(&1) == encoded))
  rescue
    ArgumentError -> false
  end

  @spec same_name?(term(), term()) :: boolean()
  defp same_name?(left, right) when is_atom(left) and not is_nil(left),
    do: same_name?(Atom.to_string(left), right)

  defp same_name?(left, right) when is_atom(right) and not is_nil(right),
    do: same_name?(left, Atom.to_string(right))

  defp same_name?(left, right) when is_binary(left) and is_binary(right), do: left == right
  defp same_name?(_left, _right), do: false

  @spec valid_ref?(term()) :: boolean()
  defp valid_ref?(value),
    do: (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != "")

  @spec duplicate_by([term()], (term() -> term())) :: term() | nil
  defp duplicate_by(values, key_fun) do
    values
    |> Enum.reduce_while(MapSet.new(), fn value, seen ->
      key = key_fun.(value)

      if MapSet.member?(seen, key),
        do: {:halt, key},
        else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  @spec get(map(), atom(), term()) :: term()
  defp get(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec reverse_result({:ok, [term()]} | {:error, term()}) ::
          {:ok, [term()]} | {:error, term()}
  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
