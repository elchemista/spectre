defmodule Spectre.Execution.Controller do
  @moduledoc false

  @behaviour Spectre.Operation.Controller

  alias Spectre.Execution.Expression
  alias Spectre.Execution.Program
  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Update
  alias Spectre.Operation.Validator
  alias Spectre.Prompt.Plan
  alias Spectre.Run.Value, as: RunValue

  @state_schema_version 1
  @history_limit 128
  @program_key :spectre_execution_program
  @plans_key :spectre_execution_plans
  @materialization_key :spectre_execution_materialization_digest

  @doc false
  @spec program_key() :: atom()
  def program_key, do: @program_key

  @doc false
  @spec plans_key() :: atom()
  def plans_key, do: @plans_key

  @doc false
  @spec materialization_key() :: atom()
  def materialization_key, do: @materialization_key

  @impl true
  def __spectre_loop_definition__ do
    Definition.new(%{
      id: "spectre.execution.controller",
      version: 1,
      kind: :work,
      input: :any,
      state: :map,
      update: :map,
      budget: %{steps: 1, attempts: 1}
    })
  end

  @impl true
  def init(input, context) do
    with {:ok, program} <- program(context),
         {:ok, data} <-
           Expression.evaluate(program.initial, %{
             input: input,
             state: nil,
             last_result: nil
           }),
         :ok <- Program.validate_state(program, data) do
      {:ok,
       %{
         schema_version: @state_schema_version,
         program_digest: program.digest,
         pc: program.entry,
         data: data,
         repeat_counts: %{},
         history: []
       }}
    end
  end

  @impl true
  def next(state, context) do
    with {:ok, program} <- program(context),
         :ok <- validate_state_envelope(state, program),
         {:ok, decision} <- select(program, state, context) do
      decision
    end
  end

  @impl true
  def apply_result(state, %Request{} = request, %Result{} = result, context) do
    with {:ok, program} <- program(context),
         :ok <- validate_state_envelope(state, program),
         :ok <- validate_request_pin(request, program, state),
         {:ok, node} <- Program.fetch_node(program, metadata(request, :execution_node_id)),
         {:ok, data, pc} <- reduce_result(node, state, result, context),
         :ok <- Program.validate_state(program, data),
         {:ok, repeat_counts} <- repeat_counts(request),
         {:ok, history} <- append_history(state.history, node, request, result) do
      {:ok,
       %{
         state
         | data: data,
           pc: pc,
           repeat_counts: repeat_counts,
           history: history
       }}
    end
  end

  @impl true
  def complete(state, context) do
    with {:ok, program} <- program(context),
         :ok <- validate_state_envelope(state, program),
         {:ok, node} <- Program.fetch_node(program, state.pc) do
      terminal_decision(node, state, context)
    end
  end

  @impl true
  def apply_update(state, input, %Update{payload: payload}, context) do
    with {:ok, program} <- program(context),
         :ok <- validate_state_envelope(state, program),
         {:ok, changes} <- normalize_update(payload),
         {:ok, data} <- apply_changes(state.data, changes, program.mutable_paths),
         :ok <- Program.validate_state(program, data),
         :ok <- Validator.validate(program.input, input, {:execution_program_input, program.id}) do
      {:ok, %{state | data: data}, input}
    end
  end

  @impl true
  def checkpoint_compatible?(stored, current), do: stored == current

  @spec select(Program.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  defp select(program, state, context) do
    select_node(program, state.pc, state, state.repeat_counts, context, MapSet.new())
  end

  @spec select_node(Program.t(), String.t(), map(), map(), map(), MapSet.t()) ::
          {:ok, term()} | {:error, term()}
  defp select_node(program, id, state, repeat_counts, context, visited) do
    if MapSet.member?(visited, id) do
      {:error, {:execution_control_cycle, id}}
    else
      with {:ok, node} <- Program.fetch_node(program, id) do
        select_node_kind(
          node,
          program,
          state,
          repeat_counts,
          context,
          MapSet.put(visited, id)
        )
      end
    end
  end

  @spec select_node_kind(map(), Program.t(), map(), map(), map(), MapSet.t()) ::
          {:ok, term()} | {:error, term()}
  defp select_node_kind(%{kind: :step} = node, program, state, counts, context, _visited) do
    with {:ok, input} <- Expression.evaluate(node.input, expression_env(state, context)) do
      {:ok, {:run, operation_request(node, program, state, counts, context, input)}}
    end
  end

  defp select_node_kind(%{kind: :infer} = node, program, state, counts, context, _visited) do
    with {:ok, plan} <- prompt_plan(context, node.prompt_ref),
         {:ok, constraints} <- inference_constraints(node.constraints) do
      inference =
        InferenceRequest.new(%{
          purpose: :data_driven_work,
          plan: plan,
          constraints: constraints,
          metadata: %{
            execution_program_digest: program.digest,
            execution_node_id: node.id,
            prompt_hash: plan.metadata.hash,
            explicit_model_override?: false
          }
        })

      {:ok, {:run, operation_request(node, program, state, counts, context, inference)}}
    end
  end

  defp select_node_kind(%{kind: :decide} = node, program, state, counts, context, _visited) do
    with {:ok, input} <- Expression.evaluate(node.input, expression_env(state, context)) do
      {:ok, {:run, operation_request(node, program, state, counts, context, input)}}
    end
  end

  defp select_node_kind(
         %{kind: :repeat} = node,
         program,
         state,
         counts,
         context,
         visited
       ) do
    count = Map.get(counts, node.id, 0)

    if count < node.max_iterations do
      next_counts = Map.put(counts, node.id, count + 1)
      select_node(program, node.body, state, next_counts, context, visited)
    else
      select_node(program, node.next, state, counts, context, visited)
    end
  end

  defp select_node_kind(%{kind: :complete} = node, _program, state, _counts, context, _visited) do
    with {:ok, output} <- Expression.evaluate(node.output, expression_env(state, context)) do
      {:ok, {:complete, output}}
    end
  end

  defp select_node_kind(%{kind: :fail} = node, _program, state, _counts, context, _visited) do
    with {:ok, reason} <- Expression.evaluate(node.reason, expression_env(state, context)) do
      {:ok, {:error, reason}}
    end
  end

  @spec operation_request(map(), Program.t(), map(), map(), map(), term()) :: Request.t()
  defp operation_request(node, program, state, counts, context, input) do
    operation = Map.get(node, :operation_ref, Map.get(node, :predicate_ref))

    Request.new(operation, input,
      id: request_id(program, node, state, counts, context),
      phase: node.id,
      branch: node.id,
      metadata:
        Map.merge(node.metadata, %{
          execution_program_digest: program.digest,
          execution_node_id: node.id,
          execution_origin_pc: state.pc,
          execution_repeat_counts: counts,
          execution_materialization_digest: Map.get(context, :execution_materialization_digest)
        })
    )
  end

  @spec request_id(Program.t(), map(), map(), map(), map()) :: String.t()
  defp request_id(program, node, state, counts, context) do
    RunValue.token("execution-request", {
      program.digest,
      Map.get(context, :loop_id),
      Map.get(context, :loop_revision, 0),
      state.pc,
      node.id,
      counts
    })
  end

  @spec reduce_result(map(), map(), Result.t(), map()) ::
          {:ok, term(), String.t()} | {:error, term()}
  defp reduce_result(%{kind: :step} = node, state, result, _context),
    do: store_and_advance(node, state.data, result.value)

  defp reduce_result(%{kind: :infer} = node, state, result, _context),
    do: store_and_advance(node, state.data, result.value)

  defp reduce_result(%{kind: :decide} = node, state, %Result{value: value}, _context)
       when is_boolean(value) do
    {:ok, state.data, if(value, do: node.on_true, else: node.on_false)}
  end

  defp reduce_result(%{kind: :decide} = node, _state, %Result{value: value}, _context),
    do: {:error, {:execution_predicate_returned_non_boolean, node.id, shape(value)}}

  defp reduce_result(node, _state, _result, _context),
    do: {:error, {:execution_node_cannot_reduce_result, node.id, node.kind}}

  @spec store_and_advance(map(), term(), term()) ::
          {:ok, term(), String.t()} | {:error, term()}
  defp store_and_advance(%{save_as: nil, next: next}, data, _value), do: {:ok, data, next}

  defp store_and_advance(%{save_as: path, next: next}, data, value) do
    with {:ok, data} <- Expression.put(data, path, value), do: {:ok, data, next}
  end

  @spec terminal_decision(map(), map(), map()) :: term()
  defp terminal_decision(%{kind: :complete} = node, state, context) do
    case Expression.evaluate(node.output, expression_env(state, context)) do
      {:ok, output} -> {:complete, output}
      {:error, _reason} = error -> error
    end
  end

  defp terminal_decision(%{kind: :fail} = node, state, context) do
    case Expression.evaluate(node.reason, expression_env(state, context)) do
      {:ok, reason} -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  defp terminal_decision(_node, _state, _context), do: :continue

  @spec program(map()) :: {:ok, Program.t()} | {:error, term()}
  defp program(context) do
    result =
      case Map.get(context, :execution_program) do
        %Program{} = program -> Program.new(program)
        data when is_map(data) -> Program.from_data(data)
        value -> {:error, {:execution_program_missing_from_context, shape(value)}}
      end

    with {:ok, program} <- result,
         {:ok, _plans} <-
           Program.normalize_plans(program, Map.get(context, :execution_plans, %{})) do
      {:ok, program}
    end
  end

  @spec prompt_plan(map(), String.t()) :: {:ok, Plan.t()} | {:error, term()}
  defp prompt_plan(context, prompt_ref) do
    plans = Map.get(context, :execution_plans, %{})

    case Map.fetch(plans, prompt_ref) do
      {:ok, %Plan{} = plan} -> {:ok, plan}
      {:ok, value} -> {:error, {:invalid_execution_prompt_plan, prompt_ref, shape(value)}}
      :error -> {:error, {:execution_prompt_plan_missing, prompt_ref}}
    end
  end

  @spec inference_constraints(map()) :: {:ok, Constraints.t()} | {:error, term()}
  defp inference_constraints(value) do
    {:ok, Constraints.new(value)}
  rescue
    error in ArgumentError ->
      {:error, {:invalid_execution_inference_constraints, Exception.message(error)}}
  end

  @spec validate_state_envelope(term(), Program.t()) :: :ok | {:error, term()}
  defp validate_state_envelope(state, program) when is_map(state) do
    cond do
      Map.get(state, :schema_version) != @state_schema_version ->
        {:error, {:unsupported_execution_state_schema, Map.get(state, :schema_version)}}

      Map.get(state, :program_digest) != program.digest ->
        {:error, :execution_state_program_mismatch}

      not is_binary(Map.get(state, :pc)) ->
        {:error, :invalid_execution_state_pc}

      not is_map(Map.get(state, :repeat_counts)) ->
        {:error, :invalid_execution_repeat_counts}

      not is_list(Map.get(state, :history)) ->
        {:error, :invalid_execution_history}

      true ->
        with {:ok, _node} <- Program.fetch_node(program, state.pc),
             :ok <- Program.validate_state(program, Map.get(state, :data)),
             :ok <- validate_repeat_counts(state.repeat_counts, program),
             :ok <- validate_history(state.history) do
          RunValue.validate(state, [:data_driven_execution_state, program.id])
        end
    end
  end

  defp validate_state_envelope(value, _program),
    do: {:error, {:invalid_execution_state, shape(value)}}

  @spec validate_repeat_counts(map(), Program.t()) :: :ok | {:error, term()}
  defp validate_repeat_counts(counts, program) do
    Enum.reduce_while(counts, :ok, fn {id, count}, :ok ->
      case Program.fetch_node(program, id) do
        {:ok, %{kind: :repeat, max_iterations: maximum}}
        when is_integer(count) and count >= 0 and count <= maximum ->
          {:cont, :ok}

        {:ok, _node} ->
          {:halt, {:error, {:execution_count_for_non_repeat, id}}}

        {:error, _reason} ->
          {:halt, {:error, {:execution_count_for_unknown_repeat, id}}}
      end
    end)
  end

  @spec validate_history(term()) :: :ok | {:error, term()}
  defp validate_history(history) do
    if length(history) > @history_limit,
      do: {:error, :execution_history_limit_exceeded},
      else: RunValue.validate(history, [:data_driven_execution_history])
  end

  @spec validate_request_pin(Request.t(), Program.t(), map()) :: :ok | {:error, term()}
  defp validate_request_pin(request, program, state) do
    cond do
      metadata(request, :execution_program_digest) != program.digest ->
        {:error, :execution_request_program_mismatch}

      metadata(request, :execution_origin_pc) != state.pc ->
        {:error, :execution_request_state_mismatch}

      true ->
        :ok
    end
  end

  @spec repeat_counts(Request.t()) :: {:ok, map()} | {:error, term()}
  defp repeat_counts(request) do
    case metadata(request, :execution_repeat_counts) do
      counts when is_map(counts) -> {:ok, counts}
      value -> {:error, {:invalid_execution_request_repeat_counts, shape(value)}}
    end
  end

  @spec append_history([map()], map(), Request.t(), Result.t()) ::
          {:ok, [map()]} | {:error, term()}
  defp append_history(history, node, request, result) do
    entry = %{
      node_id: node.id,
      operation_ref: request.operation,
      request_id: request.id,
      result_digest: RunValue.token("execution-result", result.value),
      receipt_digest: optional_digest(result.receipt),
      finished_at: result.finished_at
    }

    next = Enum.take([entry | history], @history_limit)

    case RunValue.validate(next, [:data_driven_execution_history]) do
      :ok -> {:ok, next}
      {:error, reason} -> {:error, {:nonportable_execution_history, reason}}
    end
  end

  @spec optional_digest(term()) :: String.t() | nil
  defp optional_digest(nil), do: nil
  defp optional_digest(value), do: RunValue.token("execution-receipt", value)

  @spec expression_env(map(), map()) :: map()
  defp expression_env(state, context) do
    %{
      input: Map.get(context, :input),
      state: state.data,
      last_result: result_value(Map.get(context, :last_result))
    }
  end

  @spec result_value(term()) :: term()
  defp result_value(%Result{value: value}), do: value
  defp result_value(value), do: value

  @spec normalize_update(term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_update(payload) when is_map(payload) do
    with {:ok, changes} <- update_changes(payload),
         {:ok, normalized} <- normalize_changes(changes) do
      unique_changes(normalized)
    end
  end

  defp normalize_update(value), do: {:error, {:invalid_execution_update, shape(value)}}

  @spec update_changes(map()) :: {:ok, [term()]} | {:error, term()}
  defp update_changes(payload) do
    allowed = [:changes, "changes"]
    change_keys = Enum.filter(allowed, &Map.has_key?(payload, &1))

    cond do
      Enum.any?(Map.keys(payload), &(&1 not in allowed)) ->
        {:error, :execution_update_contains_unknown_fields}

      length(change_keys) > 1 ->
        {:error, :duplicate_execution_update_changes_field}

      true ->
        changes_list(Map.get(payload, List.first(change_keys), []))
    end
  end

  @spec changes_list(term()) :: {:ok, [term()]} | {:error, term()}
  defp changes_list(changes) when is_list(changes), do: {:ok, changes}

  defp changes_list(changes),
    do: {:error, {:invalid_execution_update_changes, shape(changes)}}

  @spec normalize_changes([term()]) :: {:ok, [map()]} | {:error, term()}
  defp normalize_changes(changes) do
    changes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {change, index}, {:ok, acc} ->
      case normalize_change(change) do
        {:ok, change} -> {:cont, {:ok, [change | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_execution_update_change, index, reason}}}
      end
    end)
    |> reverse_changes()
  end

  @spec reverse_changes({:ok, [map()]} | {:error, term()}) ::
          {:ok, [map()]} | {:error, term()}
  defp reverse_changes({:ok, changes}), do: {:ok, Enum.reverse(changes)}
  defp reverse_changes({:error, _reason} = error), do: error

  @spec unique_changes([map()]) :: {:ok, [map()]} | {:error, term()}
  defp unique_changes(changes) do
    paths = Enum.map(changes, & &1.path)

    if Enum.uniq(paths) == paths,
      do: {:ok, changes},
      else: {:error, :duplicate_execution_update_path}
  end

  @spec normalize_change(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_change(change) when is_map(change) do
    allowed = [:path, :value, "path", "value"]
    path_keys = Enum.filter([:path, "path"], &Map.has_key?(change, &1))
    value_keys = Enum.filter([:value, "value"], &Map.has_key?(change, &1))

    cond do
      Enum.any?(Map.keys(change), &(&1 not in allowed)) ->
        {:error, :execution_update_change_contains_unknown_fields}

      length(path_keys) > 1 ->
        {:error, :duplicate_execution_update_path_field}

      length(value_keys) > 1 ->
        {:error, :duplicate_execution_update_value_field}

      value_keys == [] ->
        {:error, :execution_update_change_requires_value}

      true ->
        with {:ok, path} <- Expression.state_path(Map.get(change, List.first(path_keys))),
             value <- Map.get(change, List.first(value_keys)),
             :ok <- RunValue.validate(value, [:execution_update, path]) do
          {:ok, %{path: path, value: value}}
        end
    end
  end

  defp normalize_change(value), do: {:error, {:invalid_execution_update_change, shape(value)}}

  @spec apply_changes(term(), [map()], [[term()]]) :: {:ok, term()} | {:error, term()}
  defp apply_changes(data, changes, mutable_paths) do
    Enum.reduce_while(changes, {:ok, data}, fn change, {:ok, current} ->
      case apply_change(current, change, mutable_paths) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec apply_change(term(), map(), [[term()]]) :: {:ok, term()} | {:error, term()}
  defp apply_change(current, change, mutable_paths) do
    if change.path in mutable_paths,
      do: Expression.put(current, change.path, change.value),
      else: {:error, {:execution_update_path_not_mutable, change.path}}
  end

  @spec metadata(Request.t(), atom()) :: term()
  defp metadata(%Request{metadata: metadata}, key),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
