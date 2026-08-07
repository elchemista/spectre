defmodule Spectre.Instance.Runs do
  @moduledoc false

  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Invocation.Receipt
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Value

  @doc """
  Validates an invocation receipt against the recorded ownership fences.

  Every fence (invocation id, run id and revision, scheduler generation,
  dispatch id and capability) must match before the returned outcome shape
  is validated against the retained Run.
  """
  @spec validate_invocation_receipt(InstanceState.t(), String.t(), Receipt.t()) ::
          {:ok, map()} | {:error, term()}
  def validate_invocation_receipt(%InstanceState{} = data, invocation_id, %Receipt{} = receipt) do
    ownership = Map.get(data.invocations, invocation_id)

    cond do
      is_nil(ownership) ->
        {:error, :unknown_invocation}

      receipt.invocation_id != invocation_id ->
        {:error, :invocation_id_mismatch}

      receipt.run_id != ownership.run_id or
          receipt.run_revision != ownership.run_revision ->
        {:error, :run_fence_mismatch}

      receipt.generation != ownership.generation or
          receipt.dispatch_id != ownership.dispatch_id ->
        {:error, :dispatch_fence_mismatch}

      receipt.capability !== ownership.capability ->
        {:error, :invalid_receipt_capability}

      true ->
        with %Run{} = current <- Map.get(data.runs, ownership.run_id),
             true <- current.revision == ownership.run_revision,
             %Invocation{id: ^invocation_id} <- current.waiting,
             :ok <- validate_receipt_outcome(receipt.outcome, current) do
          {:ok, ownership}
        else
          _invalid -> {:error, :invalid_receipt_outcome}
        end
    end
  end

  @doc "Validates a scheduler move outcome for the given ready-queue entry."
  @spec validate_move_outcome(term(), Run.t(), map()) :: :ok | {:error, term()}
  def validate_move_outcome(
        {:continue, %Run{} = returned},
        current,
        %{operation: {:start, _input}}
      ) do
    validate_started_run(returned, current)
  end

  def validate_move_outcome(
        {:error, _reason, %Run{} = returned},
        current,
        %{operation: {:start, _input}}
      ) do
    if returned.status == :failed,
      do: validate_receipt_outcome({:error, nil, returned}, current),
      else: validate_started_run(returned, current)
  end

  def validate_move_outcome(outcome, current, _entry),
    do: validate_receipt_outcome(outcome, current)

  @doc "Resolves a live retained Run from a revision-fenced public reference."
  @spec owned_run(InstanceState.t(), Ref.t()) :: {:ok, Run.t()} | {:error, term()}
  def owned_run(%InstanceState{} = data, %Ref{} = supplied_ref) do
    case Map.get(data.runs, supplied_ref.run_id) do
      %Run{status: status} when status in [:complete, :failed] ->
        {:error, {:instance_run_terminal, supplied_ref.run_id, status}}

      %Run{} = run ->
        if run_ref_matches?(run, supplied_ref),
          do: {:ok, run},
          else:
            {:error,
             {:stale_instance_run_reference, supplied_ref.run_id, supplied_ref.revision,
              run.revision}}

      nil ->
        {:error, {:unknown_instance_run, supplied_ref.run_id}}
    end
  end

  @doc "Resolves the retained Run that produced a supplied Result."
  @spec owned_result_run(InstanceState.t(), Result.t(), boolean()) ::
          {:ok, Run.t()} | {:error, term()}
  def owned_result_run(
        %InstanceState{} = data,
        %Result{} = result,
        allow_terminal_replay? \\ false
      ) do
    case get_in(result.metadata, [:run, :id]) do
      run_id when is_binary(run_id) ->
        owned_result_run_by_id(data, result, run_id, allow_terminal_replay?)

      _missing ->
        {:error, :result_has_no_run_reference}
    end
  end

  @doc "Returns true when the Run reached a terminal status."
  @spec terminal_run?(Run.t()) :: boolean()
  def terminal_run?(%Run{status: status}), do: status in [:complete, :failed]

  @doc "Returns true when the Result carries a terminal Effect and no pending one."
  @spec terminal_result?(Result.t()) :: boolean()
  def terminal_result?(%Result{} = result) do
    is_nil(Spectre.Result.pending_effect(result)) and
      Enum.any?(result.effects, &Spectre.Effect.terminal?/1)
  end

  @doc "Marks a Run terminally failed, advancing its revision and lineage."
  @spec terminalize_failed_run(Run.t(), term()) :: Run.t()
  def terminalize_failed_run(%Run{} = run, failure) do
    failed = %{
      run
      | status: :failed,
        cursor: :complete,
        revision: run.revision + 1,
        waiting: nil,
        last_error: failure
    }

    put_failure_lineage(failed)
  end

  @doc "Rebases a retained Run and its Result onto the current Agent state."
  @spec rebase_run(Run.t(), Spectre.State.t()) :: Run.t()
  def rebase_run(%Run{} = run, %Spectre.State{} = state) do
    result =
      case run.result do
        %Result{} = result ->
          metadata =
            case Map.get(result.metadata, :state_persistence) do
              persistence when is_map(persistence) ->
                Map.put(
                  result.metadata,
                  :state_persistence,
                  Map.put(persistence, :revision, state.revision)
                )

              _missing ->
                result.metadata
            end

          %{result | state: state, metadata: metadata}

        nil ->
          nil
      end

    %{run | state: state, result: result}
  end

  @doc "Stores a Run under its id in the retained-Run window."
  @spec put_run(InstanceState.t(), Run.t()) :: InstanceState.t()
  def put_run(%InstanceState{} = data, %Run{} = run),
    do: %{data | runs: Map.put(data.runs, run.id, run)}

  @doc "Records a terminal Run for pruning, once per Run id."
  @spec record_terminal(InstanceState.t(), Run.t()) :: InstanceState.t()
  def record_terminal(%InstanceState{} = data, %Run{} = run) do
    if MapSet.member?(data.terminal_recorded, run.id) do
      data
    else
      completed = :queue.in(run.id, data.completed)

      %{
        data
        | completed: completed,
          terminal_recorded: MapSet.put(data.terminal_recorded, run.id)
      }
      |> prune_terminal()
    end
  end

  @doc "Evicts the oldest completed Runs to make room for one new Run."
  @spec prune_for_new_run(InstanceState.t()) :: InstanceState.t()
  def prune_for_new_run(%InstanceState{} = data) when map_size(data.runs) < data.max_runs,
    do: data

  def prune_for_new_run(%InstanceState{} = data) do
    case :queue.out(data.completed) do
      {{:value, run_id}, completed} ->
        case Map.get(data.runs, run_id) do
          %Run{} = run ->
            next = %{
              data
              | runs: Map.delete(data.runs, run_id),
                completed: completed,
                terminal_recorded: MapSet.delete(data.terminal_recorded, run_id),
                tombstones: Map.put(data.tombstones, run_id, run_projection(run)),
                tombstone_order: :queue.in(run_id, data.tombstone_order)
            }

            next |> prune_tombstones() |> prune_for_new_run()

          nil ->
            prune_for_new_run(%{data | completed: completed})
        end

      {:empty, _completed} ->
        data
    end
  end

  @doc "Returns the compact privacy-safe projection of one Run."
  @spec run_projection(Run.t()) :: map()
  def run_projection(%Run{} = run) do
    %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      waiting: waiting_kind(run.waiting),
      ref: run.result && get_in(run.result.metadata, [:run, :ref])
    }
  end

  @doc "Extracts the Run carried by a successful non-continue step."
  @spec step_run(term()) :: Run.t()
  def step_run({:await, %Invocation{}, %Run{} = run}), do: run
  def step_run({:boundary, %Boundary{}, %Run{} = run}), do: run
  def step_run({:complete, %Result{}, %Run{} = run}), do: run

  @doc "Extracts the Result carried by a successful non-continue step."
  @spec step_result(term()) :: Result.t() | nil
  def step_result({:await, %Invocation{}, %Run{result: result}}), do: result
  def step_result({:boundary, %Boundary{}, %Run{result: result}}), do: result
  def step_result({:complete, %Result{} = result, %Run{}}), do: result

  defp validate_receipt_outcome({:continue, %Run{} = returned}, current),
    do: validate_returned_run(returned, current, :advanced)

  defp validate_receipt_outcome(
         {:await, %Invocation{} = invocation, %Run{} = returned},
         current
       ) do
    with true <- returned.waiting == invocation,
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_await_receipt}
    end
  end

  defp validate_receipt_outcome(
         {:boundary, %Boundary{} = boundary, %Run{} = returned},
         current
       ) do
    with true <- returned.waiting == boundary,
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_boundary_receipt}
    end
  end

  defp validate_receipt_outcome(
         {:complete, %Result{} = result, %Run{} = returned},
         current
       ) do
    with true <- returned.result == result,
         true <- returned.status == :complete and is_nil(returned.waiting),
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_completion_receipt}
    end
  end

  defp validate_receipt_outcome({:error, _reason, %Run{} = returned}, current) do
    cond do
      returned == current ->
        :ok

      returned.revision == current.revision + 1 ->
        validate_returned_run(returned, current, :advanced)

      true ->
        {:error, :invalid_error_receipt}
    end
  end

  defp validate_receipt_outcome(_outcome, _current),
    do: {:error, :invalid_receipt_shape}

  defp validate_started_run(%Run{} = returned, %Run{} = current) do
    with :ok <- validate_run_identity(returned, current),
         :ok <- validate_started_shape(returned, current),
         true <- returned.state.revision == current.state.revision do
      :ok
    else
      false -> {:error, :state_revision_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_run_identity(returned, current) do
    if {returned.id, returned.agent, returned.trace_id} ==
         {current.id, current.agent, current.trace_id},
       do: :ok,
       else: {:error, :run_lineage_mismatch}
  end

  defp validate_started_shape(returned, current) do
    if {returned.revision, returned.status, returned.cursor, returned.waiting, returned.result} ==
         {current.revision, :ready, :turn, nil, nil},
       do: :ok,
       else: {:error, :invalid_started_run}
  end

  defp validate_returned_run(%Run{} = returned, %Run{} = current, :advanced) do
    cond do
      returned.id != current.id or returned.agent != current.agent or
          returned.trace_id != current.trace_id ->
        {:error, :run_lineage_mismatch}

      returned.revision != current.revision + 1 ->
        {:error, :run_revision_mismatch}

      returned.state.revision not in [current.state.revision, current.state.revision + 1] ->
        {:error, :state_revision_mismatch}

      not valid_result_lineage?(returned) ->
        {:error, :result_lineage_mismatch}

      true ->
        :ok
    end
  end

  defp valid_result_lineage?(%Run{result: nil}), do: true

  defp valid_result_lineage?(%Run{result: %Result{} = result} = run) do
    case get_in(result.metadata, [:run]) do
      %{
        id: id,
        revision: revision,
        status: status,
        cursor: cursor,
        ref: %Ref{run_id: ref_run_id, revision: ref_revision}
      } ->
        id == run.id and revision == run.revision and status == run.status and
          cursor == run.cursor and ref_run_id == run.id and ref_revision == run.revision

      _missing ->
        false
    end
  end

  defp valid_result_lineage?(_run), do: false

  defp owned_result_run_by_id(data, result, run_id, allow_terminal_replay?) do
    case Map.get(data.runs, run_id) do
      %Run{} = run ->
        validate_owned_result(run, result, allow_terminal_replay?)

      nil ->
        {:error, {:unknown_instance_run, run_id}}
    end
  end

  defp validate_owned_result(run, result, allow_terminal_replay?) do
    supplied_ref = get_in(result.metadata, [:run, :ref])

    cond do
      run_ref_matches?(run, supplied_ref) ->
        {:ok, run}

      allow_terminal_replay? and terminal_replay?(result, run.result) ->
        {:ok, run}

      is_nil(supplied_ref) ->
        {:error, :result_has_no_run_reference}

      true ->
        {:error, {:stale_instance_run_reference, run.id}}
    end
  end

  defp run_ref_matches?(
         %Run{revision: revision, waiting: %{ref: %Ref{} = expected}},
         %Ref{} = supplied
       ),
       do: expected.revision == revision and expected == supplied

  defp run_ref_matches?(
         %Run{revision: revision, result: %Result{} = result},
         %Ref{} = supplied
       ) do
    case get_in(result.metadata, [:run, :ref]) do
      %Ref{revision: ^revision} = expected -> expected == supplied
      _missing_or_stale -> false
    end
  end

  defp run_ref_matches?(_run, _supplied), do: false

  defp terminal_replay?(%Result{} = supplied, %Result{} = current) do
    terminal_result?(supplied) and terminal_result?(current) and
      terminal_effects(supplied) == terminal_effects(current)
  end

  defp terminal_replay?(_supplied, _current), do: false

  defp terminal_effects(%Result{} = result) do
    result.effects
    |> Enum.filter(&Spectre.Effect.terminal?/1)
    |> Enum.map(&{&1.id, &1.status})
    |> Enum.sort()
  end

  defp put_failure_lineage(%Run{result: %Result{} = result} = run) do
    boundary_id = Value.token("instance-error", {run.id, run.revision})
    ref = Ref.new(run.id, run.revision, :error, boundary_id)

    lineage = %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      step_id: run.step_id,
      trace_id: run.trace_id,
      ref: ref
    }

    result = %{result | metadata: Map.put(result.metadata, :run, lineage)}
    %{run | result: result}
  end

  defp put_failure_lineage(%Run{} = run), do: run

  defp prune_terminal(data) when map_size(data.runs) <= data.max_runs, do: data

  defp prune_terminal(data) do
    case :queue.out(data.completed) do
      {{:value, run_id}, completed} ->
        case Map.get(data.runs, run_id) do
          %Run{} = run ->
            tombstone = run_projection(run)

            next = %{
              data
              | runs: Map.delete(data.runs, run_id),
                completed: completed,
                terminal_recorded: MapSet.delete(data.terminal_recorded, run_id),
                tombstones: Map.put(data.tombstones, run_id, tombstone),
                tombstone_order: :queue.in(run_id, data.tombstone_order)
            }

            next |> prune_tombstones() |> prune_terminal()

          nil ->
            prune_terminal(%{data | completed: completed})
        end

      {:empty, _completed} ->
        data
    end
  end

  defp prune_tombstones(%{max_tombstones: max} = data)
       when map_size(data.tombstones) <= max,
       do: data

  defp prune_tombstones(data) do
    case :queue.out(data.tombstone_order) do
      {{:value, run_id}, order} ->
        prune_tombstones(%{
          data
          | tombstones: Map.delete(data.tombstones, run_id),
            tombstone_order: order
        })

      {:empty, _order} ->
        %{data | tombstones: %{}}
    end
  end

  defp waiting_kind(%Invocation{}), do: :invocation
  defp waiting_kind(%Boundary{kind: kind}), do: kind
  defp waiting_kind(nil), do: nil
end
