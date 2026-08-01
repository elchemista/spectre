defmodule Spectre.Operation.Result do
  @moduledoc "Correlated terminal result of exactly one operational attempt."

  alias Spectre.Run.Value

  @statuses [:ok, :error, :ambiguous]

  @enforce_keys [
    :id,
    :attempt_id,
    :loop_id,
    :operation,
    :epoch,
    :fencing_token,
    :context_revision,
    :control_generation,
    :status,
    :finished_at
  ]
  defstruct [
    :id,
    :attempt_id,
    :loop_id,
    :operation,
    :epoch,
    :fencing_token,
    :context_revision,
    :control_generation,
    :trigger_generation,
    :status,
    :value,
    :error,
    :receipt,
    :usage,
    :finished_at,
    artifacts: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          attempt_id: String.t(),
          loop_id: String.t(),
          operation: atom() | String.t(),
          epoch: String.t(),
          fencing_token: String.t(),
          context_revision: non_neg_integer(),
          control_generation: non_neg_integer(),
          trigger_generation: non_neg_integer(),
          status: :ok | :error | :ambiguous,
          value: term(),
          error: term(),
          receipt: term(),
          usage: map(),
          finished_at: non_neg_integer(),
          artifacts: [term()],
          metadata: map()
        }

  @spec new(Spectre.Operation.Attempt.t(), :ok | :error | :ambiguous, term(), keyword()) :: t()
  def new(%Spectre.Operation.Attempt{} = attempt, status, value, opts \\ [])
      when status in @statuses do
    result = %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      attempt_id: attempt.id,
      loop_id: attempt.loop_id,
      operation: attempt.operation,
      epoch: attempt.epoch,
      fencing_token: attempt.fencing_token,
      context_revision: attempt.context_revision,
      control_generation: attempt.control_generation,
      trigger_generation: attempt.trigger_generation,
      status: status,
      value: if(status == :ok, do: value),
      error: if(status == :ok, do: nil, else: value),
      receipt: Keyword.get(opts, :receipt),
      usage: Keyword.get(opts, :usage, %{}),
      finished_at: Keyword.get(opts, :finished_at, System.system_time(:millisecond)),
      artifacts: Keyword.get(opts, :artifacts, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate!(result)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = result) do
    cost =
      if is_map(result.usage), do: Map.get(result.usage, :cost, Map.get(result.usage, "cost"))

    cond do
      Enum.any?(
        [result.id, result.attempt_id, result.loop_id, result.epoch, result.fencing_token],
        &(not (is_binary(&1) and &1 != ""))
      ) ->
        {:error, :invalid_operation_result_identity}

      not valid_name?(result.operation) ->
        {:error, :invalid_operation_result_operation}

      not non_negative_integer?(result.context_revision) ->
        {:error, :invalid_operation_result_context_revision}

      not non_negative_integer?(result.control_generation) ->
        {:error, :invalid_operation_result_control_generation}

      not non_negative_integer?(result.trigger_generation) ->
        {:error, :invalid_operation_result_trigger_generation}

      result.status not in @statuses ->
        {:error, {:invalid_operation_result_status, result.status}}

      result.status == :ok and not is_nil(result.error) ->
        {:error, :successful_operation_result_with_error}

      result.status != :ok and not is_nil(result.value) ->
        {:error, :failed_operation_result_with_value}

      not non_negative_integer?(result.finished_at) ->
        {:error, :invalid_operation_result_timestamp}

      not is_map(result.usage) ->
        {:error, :invalid_operation_result_usage}

      not is_nil(cost) and not (is_number(cost) and cost >= 0) ->
        {:error, :invalid_operation_result_cost}

      not is_list(result.artifacts) ->
        {:error, :invalid_operation_result_artifacts}

      not is_map(result.metadata) ->
        {:error, :invalid_operation_result_metadata}

      true ->
        portable(result)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = result) do
    case validate(result) do
      :ok -> result
      {:error, reason} -> raise ArgumentError, "invalid operation result: #{inspect(reason)}"
    end
  end

  defp portable(result) do
    case Value.validate(result, [:operation_result, result.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_result, reason}}
    end
  end

  defp valid_name?(value),
    do: (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != "")

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
