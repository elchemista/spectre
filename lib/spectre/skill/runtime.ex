defmodule Spectre.Skill.Runtime do
  @moduledoc """
  Immutable, host-governed registry for compiled and runtime Skills.

  Mount, replacement and disable are explicit authority-checked operations
  with revision compare-and-swap. Routing is fail-closed, prompt capacity
  reserves the kernel window first, and continuations remain pinned to the
  exact content-addressed Skill generation that created them.
  """

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Program
  alias Spectre.Input
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Projection
  alias Spectre.Projection.Routing
  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Materializer, as: PromptMaterializer
  alias Spectre.Prompt.Plan
  alias Spectre.Prompt.Predicate
  alias Spectre.Router.IndexProfile
  alias Spectre.Skill.Applicability
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime.Response

  @mount_capability "spectre.skill.runtime.mount"
  @replace_capability "spectre.skill.runtime.replace"
  @disable_capability "spectre.skill.runtime.disable"

  @enforce_keys [
    :agent,
    :authority,
    :index_profile,
    :revision,
    :max_prompt_tokens,
    :kernel_prompt_tokens,
    :per_skill_prompt_cap,
    :mounts,
    :retired,
    :continuations
  ]
  defstruct [
    :agent,
    :authority,
    :index_profile,
    :revision,
    :max_prompt_tokens,
    :kernel_prompt_tokens,
    :per_skill_prompt_cap,
    mounts: %{},
    retired: %{},
    continuations: %{}
  ]

  @type lifecycle :: :active | :draining | :disabled
  @type entry :: %{
          required(:mount_id) => term(),
          required(:definition) => SkillDefinition.t(),
          required(:state) => lifecycle(),
          required(:mounted_revision) => non_neg_integer(),
          required(:routing_projection) => Projection.t()
        }
  @type continuation :: %{
          required(:mount_id) => term(),
          required(:definition_ref) => String.t()
        }
  @type t :: %__MODULE__{
          agent: module(),
          authority: Envelope.t(),
          index_profile: IndexProfile.t(),
          revision: non_neg_integer(),
          max_prompt_tokens: pos_integer(),
          kernel_prompt_tokens: non_neg_integer(),
          per_skill_prompt_cap: pos_integer(),
          mounts: %{optional(term()) => entry()},
          retired: %{optional({term(), String.t()}) => entry()},
          continuations: %{optional(String.t()) => continuation()}
        }

  @doc "Returns the stable host capability required for one lifecycle action."
  @spec capability(:mount | :replace | :disable) :: String.t()
  def capability(:mount), do: @mount_capability
  def capability(:replace), do: @replace_capability
  def capability(:disable), do: @disable_capability

  @doc "Creates an empty Skill runtime under an effective Authority Envelope."
  @spec new(module(), Envelope.t() | map() | keyword(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(agent, authority, opts \\ [])

  def new(agent, authority, opts) when is_atom(agent) and is_list(opts) do
    with :ok <- validate_new_options(opts),
         {:ok, agent_definition} <- Definition.fetch(agent),
         :ok <- require_agent(agent_definition),
         {:ok, authority} <- Envelope.new(authority),
         {:ok, index_profile} <-
           opts |> Keyword.get(:index_profile, %{}) |> IndexProfile.new(),
         {:ok, prompt_limits} <- prompt_limits(authority, opts) do
      {:ok,
       %__MODULE__{
         agent: agent,
         authority: authority,
         index_profile: index_profile,
         revision: 0,
         max_prompt_tokens: prompt_limits.max,
         kernel_prompt_tokens: prompt_limits.kernel,
         per_skill_prompt_cap: prompt_limits.per_skill,
         mounts: %{},
         retired: %{},
         continuations: %{}
       }}
    end
  end

  def new(agent, _authority, _opts), do: {:error, {:invalid_skill_runtime_agent, agent}}

  @doc "Creates a Skill runtime or raises with its stable validation reason."
  @spec new!(module(), Envelope.t() | map() | keyword(), keyword()) :: t()
  def new!(agent, authority, opts \\ []) do
    case new(agent, authority, opts) do
      {:ok, runtime} -> runtime
      {:error, reason} -> raise ArgumentError, "invalid Skill runtime: #{inspect(reason)}"
    end
  end

  @doc "Mounts one compiled or runtime Definition after all gates pass."
  @spec mount(t(), term(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def mount(%__MODULE__{} = runtime, mount_id, source, opts \\ []) do
    with :ok <- cas(runtime, opts),
         :ok <- authorized(runtime, @mount_capability),
         :ok <- available_mount_id(runtime, mount_id),
         {:ok, definition} <- normalize_definition(source),
         :ok <- validate_mount(runtime, mount_id, definition),
         {:ok, projection} <- routing_projection(runtime, definition) do
      revision = runtime.revision + 1

      entry = %{
        mount_id: mount_id,
        definition: definition,
        state: :active,
        mounted_revision: revision,
        routing_projection: projection
      }

      {:ok,
       %{
         runtime
         | revision: revision,
           mounts: Map.put(runtime.mounts, mount_id, entry)
       }}
    end
  end

  @doc "Atomically replaces a mount and drains its pinned generation if needed."
  @spec replace(t(), term(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def replace(%__MODULE__{} = runtime, mount_id, source, opts \\ []) do
    with :ok <- cas(runtime, opts),
         :ok <- authorized(runtime, @replace_capability),
         {:ok, current} <- current_entry(runtime, mount_id),
         {:ok, definition} <- normalize_definition(source),
         :ok <- validate_mount(runtime, mount_id, definition, replacing: current),
         {:ok, projection} <- routing_projection(runtime, definition) do
      revision = runtime.revision + 1
      {runtime, _old_state} = retire_for_replace(runtime, current)

      entry = %{
        mount_id: mount_id,
        definition: definition,
        state: :active,
        mounted_revision: revision,
        routing_projection: projection
      }

      {:ok,
       %{
         runtime
         | revision: revision,
           mounts: Map.put(runtime.mounts, mount_id, entry)
       }}
    end
  end

  @doc "Disables a mount immediately or drains its owned continuations."
  @spec disable(t(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def disable(%__MODULE__{} = runtime, mount_id, opts \\ []) do
    with :ok <- cas(runtime, opts),
         :ok <- authorized(runtime, @disable_capability),
         {:ok, entry} <- current_entry(runtime, mount_id),
         :ok <- disable_state(entry.state) do
      ref = definition_ref(entry)
      state = if continuation_count(runtime, mount_id, ref) > 0, do: :draining, else: :disabled
      revision = runtime.revision + 1

      {:ok,
       %{
         runtime
         | revision: revision,
           mounts: Map.put(runtime.mounts, mount_id, %{entry | state: state})
       }}
    end
  end

  @doc "Returns the active route selected across mounted Skills."
  @spec route(t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def route(runtime, input, context \\ %{})

  def route(%__MODULE__{} = runtime, input, context) when is_map(context) do
    with {:ok, input} <- normalize_input(input) do
      runtime
      |> routing_candidates(input, context)
      |> select_candidate()
    end
  end

  def route(%__MODULE__{}, _input, context),
    do: {:error, {:invalid_skill_routing_context, context}}

  @doc "Builds a reply or registered Operation Request without executing it."
  @spec respond(t(), term(), map(), keyword()) ::
          {:ok, Response.t(), t()} | {:error, term()}
  def respond(%__MODULE__{} = runtime, input, context \\ %{}, opts \\ []) do
    with :ok <- cas(runtime, opts),
         {:ok, input} <- normalize_input(input),
         {:ok, match} <- route(runtime, input, context) do
      materialize_response(runtime, match, input, context)
    end
  end

  @doc "Pins a caller-owned continuation to the current exact Skill generation."
  @spec claim_continuation(t(), term(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def claim_continuation(%__MODULE__{} = runtime, mount_id, continuation_id, opts \\ []) do
    with :ok <- cas(runtime, opts),
         :ok <- valid_continuation_id(continuation_id),
         false <- Map.has_key?(runtime.continuations, continuation_id),
         {:ok, entry} <- current_entry(runtime, mount_id),
         :ok <- active_state(entry.state) do
      {:ok, put_continuation(runtime, entry, continuation_id)}
    else
      true -> {:error, {:duplicate_skill_continuation, continuation_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolves the exact active or retired Definition pinned by a continuation."
  @spec continuation(t(), String.t()) :: {:ok, SkillDefinition.t()} | {:error, term()}
  def continuation(%__MODULE__{} = runtime, continuation_id) do
    with {:ok, pin} <- fetch_continuation(runtime, continuation_id),
         {:ok, entry} <- pinned_entry(runtime, pin) do
      {:ok, entry.definition}
    end
  end

  @doc "Releases one continuation and completes any exhausted drain."
  @spec release_continuation(t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def release_continuation(%__MODULE__{} = runtime, continuation_id, opts \\ []) do
    with :ok <- cas(runtime, opts),
         {:ok, pin} <- fetch_continuation(runtime, continuation_id) do
      runtime = %{
        runtime
        | revision: runtime.revision + 1,
          continuations: Map.delete(runtime.continuations, continuation_id)
      }

      {:ok, complete_drain(runtime, pin)}
    end
  end

  @doc "Returns a stable lifecycle projection for one mount."
  @spec status(t(), term()) :: {:ok, map()} | {:error, term()}
  def status(%__MODULE__{} = runtime, mount_id) do
    with {:ok, entry} <- current_entry(runtime, mount_id) do
      ref = definition_ref(entry)

      {:ok,
       %{
         mount_id: mount_id,
         state: entry.state,
         definition_ref: ref,
         mounted_revision: entry.mounted_revision,
         continuation_count: continuation_count(runtime, mount_id, ref)
       }}
    end
  end

  @doc "Returns a deterministic summary of all current mounts."
  @spec mounts(t()) :: [map()]
  def mounts(%__MODULE__{} = runtime) do
    runtime.mounts
    |> Map.keys()
    |> Enum.sort_by(&Value.encode!/1)
    |> Enum.map(fn mount_id ->
      {:ok, status} = status(runtime, mount_id)
      status
    end)
  end

  @spec normalize_definition(term()) :: {:ok, SkillDefinition.t()} | {:error, term()}
  defp normalize_definition(%SkillDefinition{canonical: %Canonical{} = canonical}),
    do: SkillDefinition.from_canonical(canonical)

  defp normalize_definition(%SkillDefinition{} = definition),
    do: {:error, {:invalid_skill_mount_source, shape(definition)}}

  defp normalize_definition(%Canonical{origin: :runtime} = canonical),
    do: SkillDefinition.from_canonical(canonical)

  defp normalize_definition(%Canonical{origin: origin}),
    do: {:error, {:skill_mount_requires_runtime_origin, origin}}

  defp normalize_definition(module) when is_atom(module),
    do: SkillDefinition.from_compiled(module)

  defp normalize_definition(value), do: {:error, {:invalid_skill_mount_source, shape(value)}}

  @spec routing_candidates(t(), Input.t(), map()) :: [map()]
  defp routing_candidates(runtime, input, context) do
    runtime.mounts
    |> Map.values()
    |> Enum.filter(&eligible_entry?(&1, context))
    |> Enum.reduce([], &route_entry(&1, input, &2))
  end

  @spec eligible_entry?(entry(), map()) :: boolean()
  defp eligible_entry?(entry, context) do
    entry.state == :active and
      Applicability.matches?(SkillDefinition.applicability(entry.definition), context)
  end

  @spec route_entry(entry(), Input.t(), [map()]) :: [map()]
  defp route_entry(entry, input, matches) do
    case SkillDefinition.route(entry.definition, input) do
      {:ok, rule} ->
        [
          %{
            mount_id: entry.mount_id,
            definition_ref: SkillDefinition.ref(entry.definition),
            definition: entry.definition,
            rule: rule,
            specificity:
              entry.definition
              |> SkillDefinition.applicability()
              |> Applicability.specificity()
          }
          | matches
        ]

      {:error, :skill_route_not_found} ->
        matches

      {:error, reason} ->
        [%{error: reason, mount_id: entry.mount_id} | matches]
    end
  end

  @spec validate_mount(t(), term(), SkillDefinition.t(), keyword()) :: :ok | {:error, term()}
  defp validate_mount(runtime, mount_id, definition, opts \\ []) do
    replacing = Keyword.get(opts, :replacing)

    with :ok <- valid_mount_id(mount_id),
         :ok <- validate_declarative_routes(definition),
         :ok <- validate_operation_authority(runtime, definition),
         :ok <- validate_prompt_authority(runtime, definition, replacing),
         :ok <- validate_model_authority(runtime, definition),
         :ok <- validate_execution_budget_authority(runtime, definition),
         :ok <- validate_conflicts(runtime, mount_id, definition, replacing),
         {:ok, _report} <- SkillDefinition.anti_hijack(definition) do
      :ok
    end
  end

  @spec validate_declarative_routes(SkillDefinition.t()) :: :ok | {:error, term()}
  defp validate_declarative_routes(definition) do
    definition
    |> SkillDefinition.routes()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {rule, index}, :ok ->
      case declarative_route(rule) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_runtime_skill_route, index, reason}}}
      end
    end)
  end

  @spec declarative_route(map()) :: :ok | {:error, term()}
  defp declarative_route(rule) do
    handler = get(rule, :handler, %{})
    checks = get(rule, :checks, [])

    selectors =
      get(rule, :regex, []) ++
        get(rule, :bag, []) ++ get(rule, :jaro, []) ++ get(rule, :embedding, [])

    cond do
      not exact_text_checks?(checks) or selectors != [] ->
        {:error, :runtime_skill_requires_exact_text_route}

      get(handler, :kind) == :operation ->
        validate_operation_input_policy(get(handler, :input, :input))

      get(handler, :kind) == :reply ->
        :ok

      get(handler, :kind) == :work ->
        validate_operation_input_policy(get(handler, :input, :input))

      true ->
        {:error, {:unsupported_runtime_skill_handler, get(handler, :kind)}}
    end
  end

  @spec exact_text_checks?(term()) :: boolean()
  defp exact_text_checks?([{field, text}]) when field in [:text, "text"] and is_binary(text),
    do: text != ""

  defp exact_text_checks?([[field, text]]) when field in [:text, "text"] and is_binary(text),
    do: text != ""

  defp exact_text_checks?(_checks), do: false

  @spec validate_operation_input_policy(term()) :: :ok | {:error, term()}
  defp validate_operation_input_policy(value) when value in [:text, :input], do: :ok
  defp validate_operation_input_policy({:fixed, _value}), do: :ok

  defp validate_operation_input_policy(value),
    do: {:error, {:invalid_skill_operation_input, value}}

  @spec validate_operation_authority(t(), SkillDefinition.t()) :: :ok | {:error, term()}
  defp validate_operation_authority(runtime, definition) do
    Enum.reduce_while(SkillDefinition.operation_refs(definition), :ok, fn operation, :ok ->
      case validate_operation_grant(runtime, operation) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_operation_grant(t(), term()) :: :ok | {:error, term()}
  defp validate_operation_grant(runtime, operation) do
    case Registry.resolve_id(runtime.agent, operation) do
      {:ok, registered_operation} ->
        authorize_registered_operation(runtime, registered_operation)

      {:error, _reason} ->
        {:error, {:skill_operation_not_registered, operation}}
    end
  end

  @spec authorize_registered_operation(t(), term()) :: :ok | {:error, term()}
  defp authorize_registered_operation(runtime, operation) do
    if Envelope.allows?(runtime.authority, :operations, operation),
      do: :ok,
      else: {:error, {:skill_operation_not_authorized, operation}}
  end

  @spec validate_prompt_authority(t(), SkillDefinition.t(), entry() | nil) ::
          :ok | {:error, term()}
  defp validate_prompt_authority(runtime, definition, replacing) do
    budget = SkillDefinition.prompt_budget(definition)

    with :ok <- per_skill_budget(budget.token_cap, runtime.per_skill_prompt_cap),
         :ok <- fragment_budget_classes(runtime, definition),
         :ok <- fragment_conditions(runtime, definition) do
      total_prompt_budget(runtime, definition, replacing)
    end
  end

  defp fragment_conditions(runtime, definition) do
    definition
    |> SkillDefinition.prompt_fragments()
    |> Enum.reduce_while(:ok, fn
      %Fragment{condition_ref: nil}, :ok ->
        {:cont, :ok}

      %Fragment{condition_ref: condition_ref}, :ok ->
        case Predicate.validate_ref(runtime.agent, condition_ref) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  @spec per_skill_budget(pos_integer(), pos_integer()) :: :ok | {:error, term()}
  defp per_skill_budget(cap, maximum) when cap <= maximum, do: :ok
  defp per_skill_budget(cap, maximum), do: {:error, {:skill_prompt_cap_exceeded, cap, maximum}}

  @spec fragment_budget_classes(t(), SkillDefinition.t()) :: :ok | {:error, term()}
  defp fragment_budget_classes(runtime, definition) do
    definition
    |> SkillDefinition.prompt_fragments()
    |> Enum.reduce_while(:ok, fn fragment, :ok ->
      if Envelope.allows?(runtime.authority, :prompt_budget_classes, fragment.budget_class),
        do: {:cont, :ok},
        else:
          {:halt, {:error, {:skill_prompt_budget_class_not_authorized, fragment.budget_class}}}
    end)
  end

  @spec total_prompt_budget(t(), SkillDefinition.t(), entry() | nil) ::
          :ok | {:error, term()}
  defp total_prompt_budget(runtime, definition, replacing) do
    retained =
      all_retained_entries(runtime)
      |> Enum.reject(fn entry ->
        replace_without_live_continuation?(runtime, entry, replacing)
      end)
      |> Enum.map(& &1.definition)

    reserved =
      [definition | retained]
      |> Enum.map(&SkillDefinition.prompt_budget(&1).reserved_tokens)
      |> Enum.sum()

    available = runtime.max_prompt_tokens - runtime.kernel_prompt_tokens

    if reserved <= available,
      do: :ok,
      else: {:error, {:skill_prompt_window_exceeded, reserved, available}}
  end

  @spec validate_model_authority(t(), SkillDefinition.t()) :: :ok | {:error, term()}
  defp validate_model_authority(runtime, definition) do
    definition
    |> SkillDefinition.works()
    |> Enum.reduce_while(:ok, fn program, :ok ->
      with :ok <- Program.validate_profile_pinning(program),
           :ok <- authorize_model_purpose(runtime.authority, program),
           :ok <- authorize_model_profiles(runtime.authority, program) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp authorize_model_purpose(authority, program) do
    if not Program.uses_inference?(program) or
         named_grant?(authority.model_purposes, :data_driven_work) do
      :ok
    else
      {:error, {:execution_model_purpose_not_authorized, program.id, :data_driven_work}}
    end
  end

  defp authorize_model_profiles(authority, program) do
    case Enum.find(Program.profile_refs(program), fn profile ->
           not named_grant?(authority.model_profiles, profile)
         end) do
      nil -> :ok
      profile -> {:error, {:execution_model_profile_not_authorized, program.id, profile}}
    end
  end

  defp named_grant?(grants, value) do
    Enum.any?(grants, &(stable_ref(&1) == stable_ref(value)))
  end

  defp stable_ref(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_ref(value) when is_binary(value), do: value

  @spec validate_execution_budget_authority(t(), SkillDefinition.t()) ::
          :ok | {:error, term()}
  defp validate_execution_budget_authority(runtime, definition) do
    definition
    |> SkillDefinition.works()
    |> Enum.reduce_while(:ok, fn program, :ok ->
      with :ok <- execution_budget_limit(program, runtime.authority, :cost, :max_cost),
           :ok <- execution_budget_limit(program, runtime.authority, :pages, :max_pages),
           :ok <-
             execution_budget_limit(
               program,
               runtime.authority,
               :duration_ms,
               :max_duration_ms
             ) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec execution_budget_limit(
          Spectre.Execution.Program.t(),
          Envelope.t(),
          atom(),
          atom()
        ) :: :ok | {:error, term()}
  defp execution_budget_limit(program, authority, budget_field, authority_field) do
    case Map.fetch(authority.limits, authority_field) do
      :error ->
        :ok

      {:ok, ceiling} ->
        requested = Map.get(program.budget, budget_field)

        if is_number(requested) and requested <= ceiling,
          do: :ok,
          else:
            {:error,
             {:execution_budget_not_authorized, program.id, budget_field, requested, ceiling}}
    end
  end

  defp replace_without_live_continuation?(_runtime, _entry, nil), do: false

  defp replace_without_live_continuation?(runtime, entry, replacing) do
    same_entry?(entry, replacing) and
      continuation_count(runtime, entry.mount_id, definition_ref(entry)) == 0
  end

  @spec validate_conflicts(t(), term(), SkillDefinition.t(), entry() | nil) ::
          :ok | {:error, term()}
  defp validate_conflicts(runtime, mount_id, definition, replacing) do
    candidate = SkillDefinition.applicability(definition)
    candidate_id = definition.canonical.id

    conflict =
      runtime
      |> all_retained_entries()
      |> Enum.reject(&(not is_nil(replacing) and same_entry?(&1, replacing)))
      |> Enum.find(fn entry ->
        existing = SkillDefinition.applicability(entry.definition)
        existing_id = entry.definition.canonical.id

        Applicability.conflicts?(candidate, entry.mount_id) or
          Applicability.conflicts?(candidate, existing_id) or
          Applicability.conflicts?(existing, mount_id) or
          Applicability.conflicts?(existing, candidate_id)
      end)

    if conflict,
      do: {:error, {:conflicting_skill_applicability, mount_id, conflict.mount_id}},
      else: :ok
  end

  @spec routing_projection(t(), SkillDefinition.t()) ::
          {:ok, Projection.t()} | {:error, term()}
  defp routing_projection(runtime, definition) do
    definition
    |> SkillDefinition.canonical()
    |> Projection.generate(Routing, index_profile: runtime.index_profile)
  end

  @spec select_candidate([map()]) :: {:ok, map()} | {:error, term()}
  defp select_candidate(candidates) do
    case Enum.find(candidates, &Map.has_key?(&1, :error)) do
      %{error: reason, mount_id: mount_id} ->
        {:error, {:skill_route_failed, mount_id, reason}}

      nil ->
        select_by_specificity(candidates)
    end
  end

  @spec select_by_specificity([map()]) :: {:ok, map()} | {:error, term()}
  defp select_by_specificity([]), do: {:error, :runtime_skill_route_not_found}

  defp select_by_specificity(candidates) do
    maximum = candidates |> Enum.map(& &1.specificity) |> Enum.max()
    finalists = Enum.filter(candidates, &(&1.specificity == maximum))

    case finalists do
      [candidate] ->
        {:ok, Map.delete(candidate, :specificity)}

      ambiguous ->
        {:error,
         {:ambiguous_skill_applicability,
          ambiguous |> Enum.map(& &1.mount_id) |> Enum.sort_by(&Value.encode!/1)}}
    end
  end

  @spec materialize_response(t(), map(), Input.t(), map()) ::
          {:ok, Response.t(), t()} | {:error, term()}
  defp materialize_response(runtime, match, input, context) do
    handler = get(match.rule, :handler, %{})

    case get(handler, :kind) do
      :operation -> operation_response(runtime, match, handler, input)
      :reply -> reply_response(runtime, match, handler, input, context)
      :work -> work_response(runtime, match, handler, input)
      kind -> {:error, {:unsupported_runtime_skill_response, kind}}
    end
  end

  @spec operation_response(t(), map(), map(), Input.t()) ::
          {:ok, Response.t(), t()} | {:error, term()}
  defp operation_response(runtime, match, handler, input) do
    operation = get(handler, :operation_ref)

    with {:ok, registered_operation} <- Registry.resolve_id(runtime.agent, operation),
         true <- Envelope.allows?(runtime.authority, :operations, registered_operation),
         {:ok, operation_input} <- operation_input(get(handler, :input, :input), input) do
      request =
        Request.new(registered_operation, operation_input,
          phase: :skill,
          branch: normalize_branch(match.mount_id),
          metadata: %{
            skill_definition_ref: Ref.to_string(match.definition_ref),
            skill_mount_id: match.mount_id,
            route_label: get(match.rule, :label)
          }
        )

      entry = Map.fetch!(runtime.mounts, match.mount_id)
      runtime = put_continuation(runtime, entry, request.id)

      response = %Response{
        kind: :operation,
        mount_id: match.mount_id,
        definition_ref: match.definition_ref,
        route_label: get(match.rule, :label),
        operation_request: request,
        continuation_id: request.id,
        metadata: %{execution: :host_boundary}
      }

      {:ok, response, runtime}
    else
      false ->
        {:error, {:runtime_skill_operation_unavailable, operation}}

      {:error, {:operation_not_registered, _id}} ->
        {:error, {:runtime_skill_operation_unavailable, operation}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec reply_response(t(), map(), map(), Input.t(), map()) ::
          {:ok, Response.t(), t()} | {:error, term()}
  defp reply_response(runtime, match, handler, input, context) do
    prompt = get(handler, :prompt)

    case Enum.find(SkillDefinition.prompt_fragments(match.definition), &same?(&1.id, prompt)) do
      %Fragment{} = fragment ->
        definition_ref = Ref.to_string(match.definition_ref)

        with {:ok, %Plan{} = plan, receipt} <-
               PromptMaterializer.materialize(
                 fragment,
                 input,
                 context,
                 definition_ref,
                 agent: runtime.agent
               ) do
          {:ok,
           %Response{
             kind: :reply,
             mount_id: match.mount_id,
             definition_ref: match.definition_ref,
             route_label: get(match.rule, :label),
             output: Plan.legacy(plan),
             prompt_plan: plan,
             prompt_receipt: receipt,
             metadata: %{prompt_digest: fragment.digest, prompt_receipt_digest: receipt.digest}
           }, runtime}
        end

      nil ->
        {:error, {:runtime_skill_prompt_not_found, prompt}}
    end
  end

  @spec work_response(t(), map(), map(), Input.t()) ::
          {:ok, Response.t(), t()} | {:error, term()}
  defp work_response(runtime, match, handler, input) do
    work_ref = get(handler, :work_ref)

    with {:ok, program} <- SkillDefinition.work(match.definition, work_ref),
         {:ok, work_input} <- operation_input(get(handler, :input, :input), input) do
      continuation_id = Spectre.Identity.uuid7()
      entry = Map.fetch!(runtime.mounts, match.mount_id)
      runtime = put_continuation(runtime, entry, continuation_id)

      response = %Response{
        kind: :work,
        mount_id: match.mount_id,
        definition_ref: match.definition_ref,
        route_label: get(match.rule, :label),
        work_ref: program.id,
        work_input: work_input,
        program_digest: program.digest,
        continuation_id: continuation_id,
        metadata: %{execution: :materialization_boundary}
      }

      {:ok, response, runtime}
    end
  end

  @spec operation_input(term(), Input.t()) :: {:ok, term()} | {:error, term()}
  defp operation_input(:text, input), do: {:ok, input.text}
  defp operation_input(:input, input), do: {:ok, %{text: input.text, meta: input.meta}}
  defp operation_input({:fixed, value}, _input), do: {:ok, value}
  defp operation_input(value, _input), do: {:error, {:invalid_skill_operation_input, value}}

  @spec put_continuation(t(), entry(), String.t()) :: t()
  defp put_continuation(runtime, entry, continuation_id) do
    pin = %{mount_id: entry.mount_id, definition_ref: definition_ref(entry)}

    %{
      runtime
      | revision: runtime.revision + 1,
        continuations: Map.put(runtime.continuations, continuation_id, pin)
    }
  end

  @spec retire_for_replace(t(), entry()) :: {t(), lifecycle()}
  defp retire_for_replace(runtime, entry) do
    ref = definition_ref(entry)

    if continuation_count(runtime, entry.mount_id, ref) > 0 do
      retired = Map.put(runtime.retired, {entry.mount_id, ref}, %{entry | state: :draining})
      {%{runtime | retired: retired}, :draining}
    else
      {runtime, :disabled}
    end
  end

  @spec complete_drain(t(), continuation()) :: t()
  defp complete_drain(runtime, pin) do
    count = continuation_count(runtime, pin.mount_id, pin.definition_ref)

    cond do
      count > 0 ->
        runtime

      Map.has_key?(runtime.retired, {pin.mount_id, pin.definition_ref}) ->
        %{runtime | retired: Map.delete(runtime.retired, {pin.mount_id, pin.definition_ref})}

      match?(%{state: :draining}, Map.get(runtime.mounts, pin.mount_id)) and
          definition_ref(Map.fetch!(runtime.mounts, pin.mount_id)) == pin.definition_ref ->
        entry = Map.fetch!(runtime.mounts, pin.mount_id)
        %{runtime | mounts: Map.put(runtime.mounts, pin.mount_id, %{entry | state: :disabled})}

      true ->
        runtime
    end
  end

  @spec pinned_entry(t(), continuation()) :: {:ok, entry()} | {:error, term()}
  defp pinned_entry(runtime, pin) do
    current = Map.get(runtime.mounts, pin.mount_id)

    cond do
      current && definition_ref(current) == pin.definition_ref ->
        {:ok, current}

      entry = Map.get(runtime.retired, {pin.mount_id, pin.definition_ref}) ->
        {:ok, entry}

      true ->
        {:error, {:orphaned_skill_continuation, pin.mount_id, pin.definition_ref}}
    end
  end

  @spec fetch_continuation(t(), String.t()) :: {:ok, continuation()} | {:error, term()}
  defp fetch_continuation(runtime, id) do
    case Map.fetch(runtime.continuations, id) do
      {:ok, pin} -> {:ok, pin}
      :error -> {:error, {:unknown_skill_continuation, id}}
    end
  end

  @spec all_retained_entries(t()) :: [entry()]
  defp all_retained_entries(runtime) do
    current = runtime.mounts |> Map.values() |> Enum.reject(&(&1.state == :disabled))
    current ++ Map.values(runtime.retired)
  end

  @spec continuation_count(t(), term(), String.t()) :: non_neg_integer()
  defp continuation_count(runtime, mount_id, ref) do
    Enum.count(runtime.continuations, fn {_id, pin} ->
      same?(pin.mount_id, mount_id) and pin.definition_ref == ref
    end)
  end

  @spec definition_ref(entry()) :: String.t()
  defp definition_ref(entry),
    do: entry.definition |> SkillDefinition.ref() |> Ref.to_string()

  @spec same_entry?(entry(), entry()) :: boolean()
  defp same_entry?(left, right),
    do: same?(left.mount_id, right.mount_id) and definition_ref(left) == definition_ref(right)

  @spec current_entry(t(), term()) :: {:ok, entry()} | {:error, term()}
  defp current_entry(runtime, mount_id) do
    case Map.fetch(runtime.mounts, mount_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_skill_mount, mount_id}}
    end
  end

  @spec available_mount_id(t(), term()) :: :ok | {:error, term()}
  defp available_mount_id(runtime, mount_id) do
    with :ok <- valid_mount_id(mount_id),
         false <- Map.has_key?(runtime.mounts, mount_id) do
      :ok
    else
      true -> {:error, {:duplicate_skill_mount, mount_id}}
      {:error, _reason} = error -> error
    end
  end

  @spec valid_mount_id(term()) :: :ok | {:error, term()}
  defp valid_mount_id(id) when is_atom(id) and not is_nil(id), do: :ok
  defp valid_mount_id(id) when is_binary(id) and id != "", do: :ok
  defp valid_mount_id(id) when is_integer(id), do: :ok
  defp valid_mount_id(id), do: {:error, {:invalid_skill_mount_id, id}}

  @spec authorized(t(), String.t()) :: :ok | {:error, term()}
  defp authorized(runtime, capability) do
    if Envelope.allows?(runtime.authority, :open_capabilities, capability),
      do: :ok,
      else: {:error, {:skill_runtime_capability_not_granted, capability}}
  end

  @spec cas(t(), keyword()) :: :ok | {:error, term()}
  defp cas(runtime, opts) when is_list(opts) do
    case Keyword.fetch(opts, :expected_revision) do
      {:ok, revision} when revision == runtime.revision -> :ok
      {:ok, revision} -> {:error, {:stale_skill_runtime_revision, revision, runtime.revision}}
      :error -> {:error, {:expected_skill_runtime_revision_required, runtime.revision}}
    end
  end

  defp cas(runtime, _opts),
    do: {:error, {:expected_skill_runtime_revision_required, runtime.revision}}

  @spec valid_continuation_id(term()) :: :ok | {:error, term()}
  defp valid_continuation_id(id) when is_binary(id) and id != "", do: :ok
  defp valid_continuation_id(id), do: {:error, {:invalid_skill_continuation_id, id}}

  @spec active_state(lifecycle()) :: :ok | {:error, term()}
  defp active_state(:active), do: :ok
  defp active_state(state), do: {:error, {:skill_mount_not_active, state}}

  @spec disable_state(lifecycle()) :: :ok | {:error, term()}
  defp disable_state(:active), do: :ok
  defp disable_state(state), do: {:error, {:skill_mount_not_active, state}}

  @spec validate_new_options(keyword()) :: :ok | {:error, term()}
  defp validate_new_options(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) --
             [:index_profile, :max_prompt_tokens, :kernel_prompt_tokens, :per_skill_prompt_cap] do
        [] -> :ok
        unknown -> {:error, {:unknown_skill_runtime_options, Enum.uniq(unknown)}}
      end
    else
      {:error, :invalid_skill_runtime_options}
    end
  end

  @spec prompt_limits(Envelope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp prompt_limits(authority, opts) do
    requested_max = Keyword.get(opts, :max_prompt_tokens, 4_096)
    authority_max = Map.get(authority.limits, :max_tokens, requested_max)

    with {:ok, max_tokens} <- effective_prompt_max(requested_max, authority_max),
         {:ok, kernel} <-
           prompt_kernel(
             Keyword.get(opts, :kernel_prompt_tokens, min(1_024, max_tokens)),
             max_tokens
           ),
         {:ok, per_skill} <-
           prompt_per_skill(Keyword.get(opts, :per_skill_prompt_cap, 512), max_tokens) do
      {:ok, %{max: max_tokens, kernel: kernel, per_skill: per_skill}}
    end
  end

  @spec effective_prompt_max(term(), term()) :: {:ok, pos_integer()} | {:error, term()}
  defp effective_prompt_max(requested, authority)
       when is_integer(requested) and requested > 0 and is_number(authority) and authority >= 1,
       do: {:ok, min(requested, trunc(authority))}

  defp effective_prompt_max(requested, authority),
    do: {:error, {:invalid_skill_runtime_prompt_window, {requested, authority}}}

  defp prompt_kernel(kernel, maximum)
       when is_integer(kernel) and kernel >= 0 and kernel <= maximum,
       do: {:ok, kernel}

  defp prompt_kernel(kernel, maximum),
    do: {:error, {:invalid_skill_runtime_kernel_budget, kernel, maximum}}

  defp prompt_per_skill(cap, maximum)
       when is_integer(cap) and cap > 0 and cap <= maximum,
       do: {:ok, cap}

  defp prompt_per_skill(cap, maximum),
    do: {:error, {:invalid_skill_runtime_per_skill_budget, cap, maximum}}

  @spec require_agent(Definition.t()) :: :ok | {:error, term()}
  defp require_agent(%Definition{kind: :agent}), do: :ok
  defp require_agent(%Definition{kind: kind}), do: {:error, {:skill_runtime_host_not_agent, kind}}

  @spec normalize_branch(term()) :: atom() | String.t()
  defp normalize_branch(value) when is_atom(value) and not is_nil(value), do: value
  defp normalize_branch(value) when is_binary(value) and value != "", do: value
  defp normalize_branch(value), do: "skill:" <> Value.digest!(value)

  @spec same?(term(), term()) :: boolean()
  defp same?(left, right) do
    Value.encode!(left) == Value.encode!(right)
  rescue
    ArgumentError -> false
  end

  @spec normalize_input(term()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(input) do
    {:ok, Input.new(input)}
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, {:invalid_skill_input, shape(input)}}
  end

  @spec get(map(), atom(), term()) :: term()
  defp get(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
