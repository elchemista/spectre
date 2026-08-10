defmodule Spectre.Execution.Program do
  @moduledoc """
  Immutable, data-only program for a precise Work.

  A program is a finite graph of registered operation steps, pure decisions,
  bounded repeats, inference steps and terminal nodes. The graph contains no
  callback or module selected by authored data. It materializes an ordinary
  `Spectre.Operation.Definition`, so execution, fencing, retry, recovery and
  control-plane semantics remain those of the existing operational runtime.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Execution.Expression
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator
  alias Spectre.Prompt.Plan

  @schema_version 1
  @node_kinds [:step, :infer, :decide, :repeat, :complete, :fail]
  @validators [:any, :map, :list, :binary, :integer, :number, :atom, :boolean]
  @standard_levels [:fast, :balanced, :deep]
  @risk_levels [:low, :medium, :high]
  @privacy_levels [:cloud_allowed, :private_cloud_only, :local_only]
  @cost_tiers [:low, :medium, :high]
  @constraint_fields [
    :minimum_level,
    :preferred_level,
    :structured_output?,
    :context_tokens,
    :risk,
    :privacy,
    :maximum_latency_ms,
    :maximum_cost_tier,
    :maximum_output_tokens,
    :strict?,
    :max_attempts
  ]
  @fields [
    :schema_version,
    :id,
    :version,
    :entry,
    :input,
    :state,
    :update,
    :initial,
    :nodes,
    :budget,
    :migrations,
    :mutable_paths,
    :security,
    :metadata,
    :digest
  ]

  @enforce_keys [
    :id,
    :version,
    :entry,
    :input,
    :state,
    :update,
    :initial,
    :nodes,
    :operation_refs,
    :prompt_refs,
    :budget,
    :migrations,
    :mutable_paths,
    :security,
    :metadata,
    :digest
  ]
  defstruct schema_version: @schema_version,
            id: nil,
            version: nil,
            entry: nil,
            input: :any,
            state: :map,
            update: :map,
            initial: nil,
            nodes: %{},
            operation_refs: [],
            prompt_refs: [],
            budget: %{},
            migrations: [],
            mutable_paths: [],
            security: %{},
            metadata: %{},
            digest: nil

  @type program_node :: map()
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          version: pos_integer() | String.t(),
          entry: String.t(),
          input: atom(),
          state: atom(),
          update: atom(),
          initial: Expression.t(),
          nodes: %{required(String.t()) => program_node()},
          operation_refs: [String.t()],
          prompt_refs: [String.t()],
          budget: map(),
          migrations: [map()],
          mutable_paths: [[String.t() | non_neg_integer()]],
          security: map(),
          metadata: map(),
          digest: String.t()
        }

  @doc "Builds and fully validates a data-driven Work program."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = program), do: program |> to_data() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_execution_program, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- reject_ambiguous_keys(attrs, @fields, :program),
         attrs <- atomize_known_keys(attrs, @fields),
         :ok <- exact_keys(attrs, @fields),
         :ok <- schema(Map.get(attrs, :schema_version, @schema_version)),
         {:ok, id} <- stable_name(Map.get(attrs, :id), :execution_program_id),
         {:ok, version} <- version(Map.get(attrs, :version, 1)),
         {:ok, entry} <- stable_name(Map.get(attrs, :entry), :execution_program_entry),
         {:ok, input} <- validator(Map.get(attrs, :input, :any), :input),
         {:ok, state} <- validator(Map.get(attrs, :state, :map), :state),
         {:ok, update} <- validator(Map.get(attrs, :update, :map), :update),
         {:ok, initial} <- Expression.normalize_program(Map.get(attrs, :initial, :input)),
         {:ok, nodes} <- normalize_nodes(Map.get(attrs, :nodes)),
         :ok <- validate_graph(entry, nodes),
         {:ok, budget} <- normalize_budget(Map.get(attrs, :budget)),
         :ok <- validate_repeats(nodes, budget),
         {:ok, migrations} <- normalize_migrations(Map.get(attrs, :migrations, []), version),
         {:ok, mutable_paths} <- normalize_mutable_paths(Map.get(attrs, :mutable_paths, [])),
         {:ok, security} <- host_owned_security(Map.get(attrs, :security, %{})),
         {:ok, metadata} <- portable_map(Map.get(attrs, :metadata, %{}), :metadata) do
      operation_refs = operation_refs(nodes, migrations)
      prompt_refs = derive_prompt_refs(nodes)

      base = %__MODULE__{
        id: id,
        version: version,
        entry: entry,
        input: input,
        state: state,
        update: update,
        initial: initial,
        nodes: nodes,
        operation_refs: operation_refs,
        prompt_refs: prompt_refs,
        budget: budget,
        migrations: migrations,
        mutable_paths: mutable_paths,
        security: security,
        metadata: metadata,
        digest: "pending"
      }

      finish_program(base, Map.get(attrs, :digest))
    end
  end

  def new(value), do: {:error, {:invalid_execution_program, shape(value)}}

  @spec finish_program(t(), term()) :: {:ok, t()} | {:error, term()}
  defp finish_program(base, declared) do
    with {:ok, digest} <- canonical_program_digest(base),
         :ok <- declared_program_digest(declared, digest) do
      {:ok, %{base | digest: digest}}
    end
  end

  @spec canonical_program_digest(t()) :: {:ok, String.t()} | {:error, term()}
  defp canonical_program_digest(program) do
    case Value.digest(identity_data(program)) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, {:noncanonical_execution_program, reason}}
    end
  end

  @spec declared_program_digest(term(), String.t()) :: :ok | {:error, term()}
  defp declared_program_digest(nil, _digest), do: :ok
  defp declared_program_digest(digest, digest), do: :ok

  defp declared_program_digest(declared, digest),
    do: {:error, {:execution_program_digest_mismatch, declared, digest}}

  @doc "Builds a program or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, program} -> program
      {:error, reason} -> raise ArgumentError, "invalid execution program: #{inspect(reason)}"
    end
  end

  @doc "Loads a compiled declarative Work module into the same program IR."
  @spec from_compiled(module()) :: {:ok, t()} | {:error, term()}
  def from_compiled(module) when is_atom(module) and not is_nil(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:execution_program_module_not_loaded, module}}

      not function_exported?(module, :__spectre_execution_program__, 0) ->
        {:error, {:execution_program_export_missing, module}}

      true ->
        module.__spectre_execution_program__() |> new()
    end
  rescue
    error -> {:error, {:execution_program_load_exception, module, error.__struct__}}
  catch
    kind, reason -> {:error, {:execution_program_load_failure, module, kind, reason}}
  end

  def from_compiled(value), do: {:error, {:invalid_execution_program_module, value}}

  @doc "Restores a program from canonical data and verifies its digest."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Returns the complete portable program representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = program),
    do: Map.put(identity_data(program), :digest, program.digest)

  @doc "Fetches one exact node by its stable id."
  @spec fetch_node(t(), term()) :: {:ok, program_node()} | {:error, term()}
  def fetch_node(%__MODULE__{} = program, id) do
    with {:ok, id} <- stable_name(id, :execution_node_id) do
      case Map.fetch(program.nodes, id) do
        {:ok, node} -> {:ok, node}
        :error -> {:error, {:unknown_execution_node, id}}
      end
    end
  end

  @doc "Returns the registered operation IDs required by the program."
  @spec operation_refs(t()) :: [String.t()]
  def operation_refs(%__MODULE__{operation_refs: refs}), do: refs

  @doc "Returns prompt fragment IDs required by inference nodes."
  @spec prompt_refs(t()) :: [String.t()]
  def prompt_refs(%__MODULE__{prompt_refs: refs}), do: refs

  @doc "Builds the code-owned operational contract consumed by the shared runtime."
  @spec operation_definition(t()) :: Definition.t()
  def operation_definition(%__MODULE__{} = program) do
    branches =
      program.nodes
      |> Enum.reduce(%{}, fn {_id, node}, acc ->
        case node_operation(node) do
          nil -> acc
          operation -> Map.put(acc, node.id, [operation])
        end
      end)

    Definition.new(%{
      id: program.id,
      version: program.version,
      kind: :work,
      input: program.input,
      state: :map,
      update: program.update,
      checkpoint: %{schema_version: 1, program_digest: program.digest},
      on_budget_exhausted: :terminate,
      operations: %{},
      imports: program.operation_refs,
      branches: branches,
      blockers: [],
      waits: [],
      triggers: [],
      can_start: [],
      update_fields: [],
      security: %{},
      artifact_policy: %{},
      budget: %{limits: program.budget},
      metadata: %{execution_program_digest: program.digest}
    })
  end

  @doc "Validates registered operation kinds and purity constraints for one Agent."
  @spec validate_bindings(t(), module()) :: :ok | {:error, term()}
  def validate_bindings(%__MODULE__{} = program, agent) when is_atom(agent) do
    definition = operation_definition(program)

    program.nodes
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while(:ok, fn node, :ok ->
      case validate_node_binding(node, agent, definition) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> validate_migration_bindings(program, agent, definition)
      {:error, _reason} = error -> error
    end
  end

  def validate_bindings(%__MODULE__{}, agent),
    do: {:error, {:invalid_execution_program_agent, agent}}

  @doc "Validates a user state value against the program's declared schema."
  @spec validate_state(t(), term()) :: :ok | {:error, term()}
  def validate_state(%__MODULE__{} = program, state),
    do: Validator.validate(program.state, state, {:execution_program_state, program.id})

  @doc false
  @spec normalize_plans(t(), term()) ::
          {:ok, %{optional(String.t()) => Plan.t()}} | {:error, term()}
  def normalize_plans(%__MODULE__{} = program, plans)
      when is_map(plans) and not is_struct(plans) do
    entries =
      Enum.map(plans, fn {ref, plan} ->
        case stable_name(ref, :execution_prompt_ref) do
          {:ok, ref} -> {:ok, ref, plan}
          {:error, _reason} = error -> error
        end
      end)

    with :ok <- plan_entries(entries) do
      normalized = Map.new(entries, fn {:ok, ref, plan} -> {ref, plan} end)

      cond do
        map_size(normalized) != length(entries) ->
          {:error, :duplicate_execution_prompt_plan_ref}

        Enum.sort(Map.keys(normalized)) != Enum.sort(program.prompt_refs) ->
          {:error, :execution_prompt_plan_set_mismatch}

        Enum.any?(normalized, fn {_ref, plan} -> not valid_plan?(plan) end) ->
          {:error, :invalid_execution_prompt_plan}

        true ->
          {:ok, normalized}
      end
    end
  end

  def normalize_plans(%__MODULE__{}, value),
    do: {:error, {:invalid_execution_prompt_plans, shape(value)}}

  @spec plan_entries([tuple()]) :: :ok | {:error, term()}
  defp plan_entries(entries) do
    case Enum.find(entries, &match?({:error, _reason}, &1)) do
      nil -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec valid_plan?(term()) :: boolean()
  defp valid_plan?(%Plan{rendered: rendered, metadata: metadata})
       when is_binary(rendered) and is_map(metadata) do
    expected =
      rendered
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.get(metadata, :hash) == expected
  end

  defp valid_plan?(_plan), do: false

  @spec identity_data(t()) :: map()
  defp identity_data(%__MODULE__{} = program) do
    %{
      schema_version: program.schema_version,
      id: program.id,
      version: program.version,
      entry: program.entry,
      input: program.input,
      state: program.state,
      update: program.update,
      initial: program.initial,
      nodes: program.nodes |> Map.values() |> Enum.sort_by(& &1.id),
      budget: program.budget,
      migrations: program.migrations,
      mutable_paths: program.mutable_paths,
      security: program.security,
      metadata: program.metadata
    }
  end

  @spec normalize_nodes(term()) :: {:ok, %{String.t() => program_node()}} | {:error, term()}
  defp normalize_nodes(nodes) when is_map(nodes) do
    nodes
    |> Enum.map(fn {id, node} -> if is_map(node), do: Map.put_new(node, :id, id), else: node end)
    |> normalize_nodes()
  end

  defp normalize_nodes(nodes) when is_list(nodes) and nodes != [] do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {node, index}, {:ok, acc} ->
      case normalize_node(node) do
        {:ok, %{id: id} = normalized} when not is_map_key(acc, id) ->
          {:cont, {:ok, Map.put(acc, id, normalized)}}

        {:ok, %{id: id}} ->
          {:halt, {:error, {:duplicate_execution_node, id}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_execution_node, index, reason}}}
      end
    end)
  end

  defp normalize_nodes(value), do: {:error, {:invalid_execution_nodes, shape(value)}}

  @spec normalize_node(term()) :: {:ok, program_node()} | {:error, term()}
  defp normalize_node(node) when is_map(node) and not is_struct(node) do
    fields = [
      :id,
      :kind,
      :operation,
      :operation_ref,
      :predicate,
      :predicate_ref,
      :prompt,
      :prompt_ref,
      :input,
      :save_as,
      :next,
      :on_true,
      :on_false,
      :body,
      :max_iterations,
      :output,
      :reason,
      :constraints,
      :profile_ref,
      :metadata
    ]

    with :ok <- reject_ambiguous_keys(node, fields, :node),
         node <- atomize_known_keys(node, fields),
         {:ok, kind} <- enum(Map.get(node, :kind), @node_kinds, :execution_node_kind),
         {:ok, id} <- stable_name(Map.get(node, :id), :execution_node_id) do
      normalize_node_kind(kind, id, node)
    end
  end

  defp normalize_node(value), do: {:error, {:invalid_execution_node_shape, shape(value)}}

  @spec normalize_node_kind(atom(), String.t(), map()) ::
          {:ok, program_node()} | {:error, term()}
  defp normalize_node_kind(:step, id, node) do
    allowed = [:id, :kind, :operation, :operation_ref, :input, :save_as, :next, :metadata]

    with :ok <- exact_keys(node, allowed, :unknown_execution_node_fields),
         {:ok, operation} <- operation_name(node),
         {:ok, input} <- Expression.normalize_program(Map.get(node, :input, :state)),
         {:ok, save_as} <- optional_path(Map.get(node, :save_as)),
         {:ok, next} <- stable_name(Map.get(node, :next), :execution_node_next),
         {:ok, metadata} <- portable_map(Map.get(node, :metadata, %{}), :node_metadata) do
      {:ok,
       %{
         id: id,
         kind: :step,
         operation_ref: operation,
         input: input,
         save_as: save_as,
         next: next,
         metadata: metadata
       }}
    end
  end

  defp normalize_node_kind(:infer, id, node) do
    allowed = [
      :id,
      :kind,
      :operation,
      :operation_ref,
      :prompt,
      :prompt_ref,
      :save_as,
      :next,
      :constraints,
      :profile_ref,
      :metadata
    ]

    with :ok <- exact_keys(node, allowed, :unknown_execution_node_fields),
         {:ok, operation} <- operation_name(node),
         {:ok, prompt_ref} <- prompt_name(node),
         {:ok, save_as} <- optional_path(Map.get(node, :save_as)),
         {:ok, next} <- stable_name(Map.get(node, :next), :execution_node_next),
         {:ok, constraints} <- constraints(node),
         {:ok, metadata} <- portable_map(Map.get(node, :metadata, %{}), :node_metadata) do
      {:ok,
       %{
         id: id,
         kind: :infer,
         operation_ref: operation,
         prompt_ref: prompt_ref,
         save_as: save_as,
         next: next,
         constraints: constraints,
         metadata: metadata
       }}
    end
  end

  defp normalize_node_kind(:decide, id, node) do
    allowed = [
      :id,
      :kind,
      :predicate,
      :predicate_ref,
      :input,
      :on_true,
      :on_false,
      :metadata
    ]

    with :ok <- exact_keys(node, allowed, :unknown_execution_node_fields),
         {:ok, predicate} <- predicate_name(node),
         {:ok, input} <- Expression.normalize_program(Map.get(node, :input, :state)),
         {:ok, on_true} <- stable_name(Map.get(node, :on_true), :execution_node_on_true),
         {:ok, on_false} <- stable_name(Map.get(node, :on_false), :execution_node_on_false),
         {:ok, metadata} <- portable_map(Map.get(node, :metadata, %{}), :node_metadata) do
      {:ok,
       %{
         id: id,
         kind: :decide,
         predicate_ref: predicate,
         input: input,
         on_true: on_true,
         on_false: on_false,
         metadata: metadata
       }}
    end
  end

  defp normalize_node_kind(:repeat, id, node) do
    allowed = [:id, :kind, :body, :next, :max_iterations, :metadata]

    with :ok <- exact_keys(node, allowed, :unknown_execution_node_fields),
         {:ok, body} <- stable_name(Map.get(node, :body), :execution_repeat_body),
         {:ok, next} <- stable_name(Map.get(node, :next), :execution_node_next),
         {:ok, maximum} <- positive_integer(Map.get(node, :max_iterations), :max_iterations),
         {:ok, metadata} <- portable_map(Map.get(node, :metadata, %{}), :node_metadata) do
      {:ok,
       %{
         id: id,
         kind: :repeat,
         body: body,
         next: next,
         max_iterations: maximum,
         metadata: metadata
       }}
    end
  end

  defp normalize_node_kind(:complete, id, node) do
    allowed = [:id, :kind, :output, :metadata]

    with :ok <- exact_keys(node, allowed, :unknown_execution_node_fields),
         {:ok, output} <- Expression.normalize_program(Map.get(node, :output, :state)),
         {:ok, metadata} <- portable_map(Map.get(node, :metadata, %{}), :node_metadata) do
      {:ok, %{id: id, kind: :complete, output: output, metadata: metadata}}
    end
  end

  defp normalize_node_kind(:fail, id, node) do
    allowed = [:id, :kind, :reason, :metadata]

    with :ok <- exact_keys(node, allowed, :unknown_execution_node_fields),
         {:ok, reason} <- normalize_failure_reason(Map.get(node, :reason, :execution_failed)),
         {:ok, metadata} <- portable_map(Map.get(node, :metadata, %{}), :node_metadata) do
      {:ok, %{id: id, kind: :fail, reason: reason, metadata: metadata}}
    end
  end

  @spec normalize_failure_reason(term()) :: {:ok, Expression.t()} | {:error, term()}
  defp normalize_failure_reason(%{kind: kind} = reason)
       when kind in [:source, :fixed, :object, :list],
       do: Expression.normalize_program(reason)

  defp normalize_failure_reason(%{"kind" => kind} = reason)
       when kind in ["source", "fixed", "object", "list"],
       do: Expression.normalize_program(reason)

  defp normalize_failure_reason(reason), do: Expression.normalize_program({:fixed, reason})

  @spec validate_graph(String.t(), map()) :: :ok | {:error, term()}
  defp validate_graph(entry, nodes) do
    with true <- Map.has_key?(nodes, entry),
         :ok <- validate_targets(nodes),
         :ok <- validate_reachability(entry, nodes),
         :ok <- no_repeat_control_cycle(nodes),
         :ok <- no_cycle_without_repeat(nodes),
         :ok <- terminating_after_repeat_exhaustion(nodes) do
      :ok
    else
      false -> {:error, {:unknown_execution_entry, entry}}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_targets(map()) :: :ok | {:error, term()}
  defp validate_targets(nodes) do
    Enum.reduce_while(nodes, :ok, fn {_id, node}, :ok ->
      case Enum.find(node_edges(node), &(not Map.has_key?(nodes, &1))) do
        nil -> {:cont, :ok}
        target -> {:halt, {:error, {:unknown_execution_node_target, node.id, target}}}
      end
    end)
  end

  @spec validate_reachability(String.t(), map()) :: :ok | {:error, term()}
  defp validate_reachability(entry, nodes) do
    reachable = walk([entry], nodes, MapSet.new())

    case nodes |> Map.keys() |> Enum.find(&(not MapSet.member?(reachable, &1))) do
      nil -> :ok
      id -> {:error, {:unreachable_execution_node, id}}
    end
  end

  @spec no_cycle_without_repeat(map()) :: :ok | {:error, term()}
  defp no_cycle_without_repeat(nodes) do
    non_repeat = Map.reject(nodes, fn {_id, node} -> node.kind == :repeat end)

    graph =
      Map.new(non_repeat, fn {id, node} ->
        {id, Enum.filter(node_edges(node), &is_map_key(non_repeat, &1))}
      end)

    case cycle(graph) do
      nil -> :ok
      ids -> {:error, {:unbounded_execution_cycle, ids}}
    end
  end

  @spec no_repeat_control_cycle(map()) :: :ok | {:error, term()}
  defp no_repeat_control_cycle(nodes) do
    repeat_ids =
      nodes
      |> Enum.filter(fn {_id, node} -> node.kind == :repeat end)
      |> Map.new()

    graph =
      Map.new(repeat_ids, fn {id, node} ->
        {id, Enum.filter([node.body, node.next], &Map.has_key?(repeat_ids, &1))}
      end)

    case cycle(graph) do
      nil -> :ok
      ids -> {:error, {:execution_repeat_control_cycle, ids}}
    end
  end

  @spec terminating_after_repeat_exhaustion(map()) :: :ok | {:error, term()}
  defp terminating_after_repeat_exhaustion(nodes) do
    graph =
      Map.new(nodes, fn {id, node} ->
        edges = if node.kind == :repeat, do: [node.next], else: node_edges(node)
        {id, edges}
      end)

    case cycle(graph) do
      nil -> :ok
      ids -> {:error, {:nonterminating_execution_repeat_exit, ids}}
    end
  end

  @spec cycle(map()) :: [String.t()] | nil
  defp cycle(graph) do
    graph
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({MapSet.new(), nil}, fn node, {visited, _cycle} ->
      case dfs_cycle(node, graph, visited, MapSet.new(), []) do
        {visited, nil} -> {:cont, {visited, nil}}
        {_visited, cycle} -> {:halt, {visited, cycle}}
      end
    end)
    |> elem(1)
  end

  @spec dfs_cycle(String.t(), map(), MapSet.t(), MapSet.t(), [String.t()]) ::
          {MapSet.t(), [String.t()] | nil}
  defp dfs_cycle(node, graph, visited, active, path) do
    cond do
      MapSet.member?(active, node) ->
        {visited, Enum.reverse([node | Enum.take_while(path, &(&1 != node))])}

      MapSet.member?(visited, node) ->
        {visited, nil}

      true ->
        active = MapSet.put(active, node)
        visited = MapSet.put(visited, node)
        dfs_cycle_children(Map.get(graph, node, []), graph, visited, active, [node | path])
    end
  end

  @spec dfs_cycle_children([String.t()], map(), MapSet.t(), MapSet.t(), [String.t()]) ::
          {MapSet.t(), [String.t()] | nil}
  defp dfs_cycle_children(children, graph, visited, active, path) do
    Enum.reduce_while(children, {visited, nil}, fn child, {seen, _cycle} ->
      case dfs_cycle(child, graph, seen, active, path) do
        {seen, nil} -> {:cont, {seen, nil}}
        {seen, cycle} -> {:halt, {seen, cycle}}
      end
    end)
  end

  @spec walk([String.t()], map(), MapSet.t()) :: MapSet.t()
  defp walk([], _nodes, seen), do: seen

  defp walk([id | rest], nodes, seen) do
    if MapSet.member?(seen, id) do
      walk(rest, nodes, seen)
    else
      node = Map.fetch!(nodes, id)
      walk(node_edges(node) ++ rest, nodes, MapSet.put(seen, id))
    end
  end

  @spec node_edges(program_node()) :: [String.t()]
  defp node_edges(%{kind: kind, next: next}) when kind in [:step, :infer], do: [next]
  defp node_edges(%{kind: :decide, on_true: yes, on_false: no}), do: [yes, no]
  defp node_edges(%{kind: :repeat, body: body, next: next}), do: [body, next]
  defp node_edges(%{kind: kind}) when kind in [:complete, :fail], do: []

  @spec normalize_budget(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_budget(nil), do: {:error, :execution_program_requires_budget}

  defp normalize_budget(value) do
    with :ok <- reject_ambiguous_budget(value) do
      value = atomize_budget(value)
      budget = Budget.new(value, 0)
      limits = budget.limits

      cond do
        not (is_integer(limits.steps) and limits.steps > 0) ->
          {:error, :execution_program_requires_step_limit}

        not (is_integer(limits.attempts) and limits.attempts > 0) ->
          {:error, :execution_program_requires_attempt_limit}

        true ->
          {:ok, limits}
      end
    end
  rescue
    error in ArgumentError ->
      {:error, {:invalid_execution_program_budget, Exception.message(error)}}
  end

  @spec atomize_budget(term()) :: term()
  defp atomize_budget(value) when is_map(value) do
    fields = [:limits, :steps, :attempts, :retries, :duration_ms, :cost]
    value = atomize_known_keys(value, fields)

    case Map.fetch(value, :limits) do
      {:ok, limits} when is_map(limits) ->
        Map.put(value, :limits, atomize_known_keys(limits, tl(fields)))

      _other ->
        value
    end
  end

  defp atomize_budget(value), do: value

  @spec validate_repeats(map(), map()) :: :ok | {:error, term()}
  defp validate_repeats(nodes, budget) do
    maximum = trunc(min(budget.steps, budget.attempts))

    case Enum.find(Map.values(nodes), fn
           %{kind: :repeat, max_iterations: iterations} -> iterations > maximum
           _node -> false
         end) do
      nil -> :ok
      node -> {:error, {:execution_repeat_exceeds_budget, node.id, node.max_iterations, maximum}}
    end
  end

  @spec normalize_migrations(term(), term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_migrations(migrations, version) when is_list(migrations) do
    migrations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {migration, index}, {:ok, acc} ->
      case normalize_migration(migration, version) do
        {:ok, migration} -> {:cont, {:ok, [migration | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_execution_migration, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, &Value.encode!(&1.from))

        case duplicate_by(normalized, & &1.from) do
          nil -> {:ok, normalized}
          from -> {:error, {:duplicate_execution_migration, from}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_migrations(value, _version),
    do: {:error, {:invalid_execution_migrations, shape(value)}}

  @spec normalize_migration(term(), term()) :: {:ok, map()} | {:error, term()}
  defp normalize_migration(value, target) when is_map(value) do
    fields = [:from, :to, :operation, :operation_ref, :metadata]

    with :ok <- reject_ambiguous_keys(value, fields, :migration),
         value <- atomize_known_keys(value, fields),
         :ok <-
           exact_keys(
             value,
             fields,
             :unknown_execution_migration_fields
           ),
         {:ok, from} <- version(Map.get(value, :from)),
         {:ok, to} <- version(Map.get(value, :to, target)),
         true <- to == target,
         {:ok, operation} <- operation_name(value),
         {:ok, metadata} <- portable_map(Map.get(value, :metadata, %{}), :migration_metadata) do
      {:ok, %{from: from, to: to, operation_ref: operation, metadata: metadata}}
    else
      false -> {:error, {:execution_migration_target_mismatch, Map.get(value, :to), target}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_migration(value, _target),
    do: {:error, {:invalid_execution_migration_shape, shape(value)}}

  @spec normalize_mutable_paths(term()) :: {:ok, [[term()]]} | {:error, term()}
  defp normalize_mutable_paths(paths) when is_list(paths) do
    paths
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {path, index}, {:ok, acc} ->
      case Expression.state_path(path) do
        {:ok, path} -> {:cont, {:ok, [path | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_execution_mutable_path, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = normalized |> Enum.uniq() |> Enum.sort_by(&Value.encode!/1)
        {:ok, normalized}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_mutable_paths(value),
    do: {:error, {:invalid_execution_mutable_paths, shape(value)}}

  @spec constraints(map()) :: {:ok, map()} | {:error, term()}
  defp constraints(node) do
    value = Map.get(node, :constraints, %{})

    with true <- is_map(value) and not is_struct(value),
         :ok <- reject_ambiguous_keys(value, @constraint_fields, :constraints),
         value <- atomize_known_keys(value, @constraint_fields),
         :ok <- exact_keys(value, @constraint_fields, :unknown_execution_inference_constraints),
         {:ok, profile_ref} <- optional_name(Map.get(node, :profile_ref), :profile_ref),
         {:ok, value} <- normalize_constraint_values(value, profile_ref) do
      try do
        constraints = Spectre.Inference.Constraints.new(value)
        {:ok, Map.from_struct(constraints)}
      rescue
        error in ArgumentError ->
          {:error, {:invalid_execution_inference_constraints, Exception.message(error)}}
      end
    else
      false -> {:error, {:invalid_execution_inference_constraints, shape(value)}}
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_constraint_values(map(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  defp normalize_constraint_values(value, profile_ref) do
    with {:ok, value} <- normalize_level_constraint(value, :minimum_level),
         {:ok, value} <- normalize_level_constraint(value, :preferred_level),
         {:ok, value} <- normalize_enum_constraint(value, :risk, @risk_levels),
         {:ok, value} <- normalize_enum_constraint(value, :privacy, @privacy_levels),
         {:ok, value} <- normalize_enum_constraint(value, :maximum_cost_tier, @cost_tiers),
         {:ok, profile_ref} <- normalize_level(profile_ref) do
      bind_profile_ref(value, profile_ref)
    end
  end

  @spec normalize_level_constraint(map(), atom()) :: {:ok, map()} | {:error, term()}
  defp normalize_level_constraint(value, field) do
    if Map.has_key?(value, field) do
      with {:ok, normalized} <- normalize_level(Map.fetch!(value, field)) do
        {:ok, Map.put(value, field, normalized)}
      end
    else
      {:ok, value}
    end
  end

  @spec normalize_level(term()) :: {:ok, atom() | String.t() | nil} | {:error, term()}
  defp normalize_level(nil), do: {:ok, nil}
  defp normalize_level(value) when value in @standard_levels, do: {:ok, value}

  defp normalize_level(value) when is_binary(value) and value != "" do
    case Enum.find(@standard_levels, &(Atom.to_string(&1) == value)) do
      nil -> {:ok, value}
      level -> {:ok, level}
    end
  end

  defp normalize_level(value) when is_atom(value),
    do: stable_name(value, :execution_inference_level)

  defp normalize_level(value),
    do: {:error, {:invalid_execution_inference_level, value}}

  @spec normalize_enum_constraint(map(), atom(), [atom()]) ::
          {:ok, map()} | {:error, term()}
  defp normalize_enum_constraint(value, field, allowed) do
    if Map.has_key?(value, field) do
      with {:ok, normalized} <- normalize_enum_value(Map.fetch!(value, field), field, allowed) do
        {:ok, Map.put(value, field, normalized)}
      end
    else
      {:ok, value}
    end
  end

  @spec normalize_enum_value(term(), atom(), [atom()]) ::
          {:ok, atom() | nil} | {:error, term()}
  defp normalize_enum_value(nil, _field, _allowed), do: {:ok, nil}

  defp normalize_enum_value(item, field, allowed) when is_atom(item) do
    if item in allowed,
      do: {:ok, item},
      else: {:error, {:invalid_execution_inference_constraint, field, item}}
  end

  defp normalize_enum_value(item, field, allowed) when is_binary(item) do
    case Enum.find(allowed, &(Atom.to_string(&1) == item)) do
      nil -> {:error, {:invalid_execution_inference_constraint, field, item}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_enum_value(item, field, _allowed),
    do: {:error, {:invalid_execution_inference_constraint, field, item}}

  @spec bind_profile_ref(map(), atom() | String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  defp bind_profile_ref(value, nil), do: {:ok, value}

  defp bind_profile_ref(value, profile_ref) do
    case Map.get(value, :preferred_level) do
      nil -> {:ok, Map.put(value, :preferred_level, profile_ref)}
      ^profile_ref -> {:ok, value}
      preferred -> {:error, {:conflicting_execution_inference_profile, preferred, profile_ref}}
    end
  end

  @spec validate_node_binding(program_node(), module(), Definition.t()) ::
          :ok | {:error, term()}
  defp validate_node_binding(%{kind: kind}, _agent, _definition)
       when kind in [:repeat, :complete, :fail],
       do: :ok

  defp validate_node_binding(node, agent, definition) do
    case Registry.resolve(agent, definition, node_operation(node)) do
      {:ok, spec} -> validate_bound_spec(node, spec)
      {:error, reason} -> {:error, {:execution_operation_unavailable, node.id, reason}}
    end
  end

  @spec validate_bound_spec(program_node(), Spec.t()) :: :ok | {:error, term()}
  defp validate_bound_spec(%{kind: :infer}, %Spec{kind: :cognitive}), do: :ok

  defp validate_bound_spec(%{kind: :infer, id: id}, %Spec{} = spec),
    do: {:error, {:execution_infer_requires_cognitive_operation, id, spec.id, spec.kind}}

  defp validate_bound_spec(%{kind: :decide, id: id}, %Spec{} = spec) do
    boolean_contract? = spec.output == :boolean or spec.domain in [[true, false], [false, true]]

    cond do
      spec.side_effect != :none ->
        {:error, {:execution_predicate_must_be_pure, id, spec.id, spec.side_effect}}

      not boolean_contract? ->
        {:error, {:execution_predicate_must_return_boolean, id, spec.id}}

      true ->
        :ok
    end
  end

  defp validate_bound_spec(%{kind: :step}, %Spec{}), do: :ok

  @spec validate_migration_bindings(t(), module(), Definition.t()) :: :ok | {:error, term()}
  defp validate_migration_bindings(program, agent, definition) do
    Enum.reduce_while(program.migrations, :ok, fn migration, :ok ->
      case Registry.resolve(agent, definition, migration.operation_ref) do
        {:ok, %Spec{side_effect: :none}} ->
          {:cont, :ok}

        {:ok, %Spec{} = spec} ->
          {:halt,
           {:error,
            {:execution_migration_must_be_pure, migration.operation_ref, spec.side_effect}}}

        {:error, reason} ->
          {:halt, {:error, {:execution_migration_unavailable, migration.from, reason}}}
      end
    end)
  end

  @spec operation_refs(map(), [map()]) :: [String.t()]
  defp operation_refs(nodes, migrations) do
    node_refs = nodes |> Map.values() |> Enum.map(&node_operation/1) |> Enum.reject(&is_nil/1)
    migration_refs = Enum.map(migrations, & &1.operation_ref)
    Enum.sort(Enum.uniq(node_refs ++ migration_refs))
  end

  @spec derive_prompt_refs(map()) :: [String.t()]
  defp derive_prompt_refs(nodes) do
    nodes
    |> Map.values()
    |> Enum.flat_map(fn
      %{kind: :infer, prompt_ref: prompt_ref} -> [prompt_ref]
      _node -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec node_operation(program_node()) :: String.t() | nil
  defp node_operation(%{kind: :step, operation_ref: ref}), do: ref
  defp node_operation(%{kind: :infer, operation_ref: ref}), do: ref
  defp node_operation(%{kind: :decide, predicate_ref: ref}), do: ref
  defp node_operation(_node), do: nil

  @spec operation_name(map()) :: {:ok, String.t()} | {:error, term()}
  defp operation_name(value),
    do: aliased_name(value, :operation_ref, :operation, &registered_name/2)

  @spec predicate_name(map()) :: {:ok, String.t()} | {:error, term()}
  defp predicate_name(value),
    do: aliased_name(value, :predicate_ref, :predicate, &registered_name/2)

  @spec prompt_name(map()) :: {:ok, String.t()} | {:error, term()}
  defp prompt_name(value),
    do: aliased_name(value, :prompt_ref, :prompt, &stable_name/2)

  @spec aliased_name(map(), atom(), atom(), (term(), atom() ->
                                               {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  defp aliased_name(value, canonical, shorthand, validator) do
    case {Map.fetch(value, canonical), Map.fetch(value, shorthand)} do
      {{:ok, _canonical}, {:ok, _shorthand}} ->
        {:error, {:duplicate_execution_name, canonical, shorthand}}

      {{:ok, name}, :error} ->
        validator.(name, canonical)

      {:error, {:ok, name}} ->
        validator.(name, canonical)

      {:error, :error} ->
        validator.(nil, canonical)
    end
  end

  @spec stable_name(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp stable_name(value, field) when is_atom(value) and not is_nil(value) do
    name = Atom.to_string(value)

    if String.starts_with?(name, "Elixir."),
      do: {:error, {:execution_code_reference_forbidden, field}},
      else: {:ok, name}
  end

  defp stable_name(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp stable_name(value, field), do: {:error, {:invalid_execution_name, field, value}}

  @spec registered_name(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp registered_name(value, field) when is_atom(value) and not is_nil(value) do
    if Code.ensure_loaded?(value),
      do: {:error, {:execution_code_reference_forbidden, field}},
      else: stable_name(value, field)
  end

  defp registered_name(value, field), do: stable_name(value, field)

  @spec optional_name(term(), atom()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_name(nil, _field), do: {:ok, nil}
  defp optional_name(value, field), do: stable_name(value, field)

  @spec optional_path(term()) :: {:ok, [term()] | nil} | {:error, term()}
  defp optional_path(nil), do: {:ok, nil}
  defp optional_path(value), do: Expression.state_path(value)

  @spec schema(term()) :: :ok | {:error, term()}
  defp schema(@schema_version), do: :ok
  defp schema(value), do: {:error, {:unsupported_execution_program_schema, value}}

  @spec version(term()) :: {:ok, pos_integer() | String.t()} | {:error, term()}
  defp version(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp version(value) when is_binary(value) and value != "", do: {:ok, value}
  defp version(value), do: {:error, {:invalid_execution_program_version, value}}

  @spec validator(term(), atom()) :: {:ok, atom()} | {:error, term()}
  defp validator(value, _field) when value in @validators, do: {:ok, value}

  defp validator(value, field) when is_binary(value) do
    case Enum.find(@validators, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_execution_validator, field, value}}
      validator -> {:ok, validator}
    end
  end

  defp validator(value, field), do: {:error, {:invalid_execution_validator, field, value}}

  @spec portable_map(term(), atom()) :: {:ok, map()} | {:error, term()}
  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Expression.normalize_literal(value) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, reason} ->
        {:error, {:nonportable_execution_program_field, field, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_execution_program_field, field, shape(value)}}

  @spec host_owned_security(term()) :: {:ok, map()} | {:error, term()}
  defp host_owned_security(value) when is_map(value) and not is_struct(value) do
    if map_size(value) == 0,
      do: {:ok, %{}},
      else: {:error, :execution_program_security_is_host_owned}
  end

  defp host_owned_security(value),
    do: {:error, {:invalid_execution_program_field, :security, shape(value)}}

  @spec positive_integer(term(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, field),
    do: {:error, {:invalid_execution_positive_integer, field, value}}

  @spec enum(term(), [atom()], atom()) :: {:ok, atom()} | {:error, term()}
  defp enum(value, allowed, field) when is_atom(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_execution_enum, field, value}}
  end

  defp enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_execution_enum, field, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp enum(value, _allowed, field), do: {:error, {:invalid_execution_enum, field, value}}

  @spec exact_keys(map(), [atom()], atom()) :: :ok | {:error, term()}
  defp exact_keys(value, allowed, error \\ :unknown_execution_program_fields) do
    case Map.keys(value) -- allowed do
      [] -> :ok
      unknown -> {:error, {error, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec atomize_known_keys(map(), [atom()]) :: map()
  defp atomize_known_keys(value, fields) when is_map(value) do
    Enum.reduce(fields, value, fn field, acc ->
      string = Atom.to_string(field)

      case Map.fetch(acc, string) do
        {:ok, item} -> acc |> Map.delete(string) |> Map.put_new(field, item)
        :error -> acc
      end
    end)
  end

  @spec reject_ambiguous_budget(term()) :: :ok | {:error, term()}
  defp reject_ambiguous_budget(value) when is_map(value) and not is_struct(value) do
    fields = [:limits, :steps, :attempts, :retries, :duration_ms, :cost]

    with :ok <- reject_ambiguous_keys(value, fields, :budget) do
      case Map.get(value, :limits, Map.get(value, "limits")) do
        limits when is_map(limits) and not is_struct(limits) ->
          reject_ambiguous_keys(limits, tl(fields), :budget_limits)

        _other ->
          :ok
      end
    end
  end

  defp reject_ambiguous_budget(_value), do: :ok

  @spec reject_ambiguous_keys(map(), [atom()], atom()) :: :ok | {:error, term()}
  defp reject_ambiguous_keys(value, fields, label) do
    case Enum.find(fields, fn field ->
           Map.has_key?(value, field) and Map.has_key?(value, Atom.to_string(field))
         end) do
      nil -> :ok
      field -> {:error, {:ambiguous_execution_program_field, label, field}}
    end
  end

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

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
