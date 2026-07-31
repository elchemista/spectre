defmodule Spectre.Operation.Attempt do
  @moduledoc "Revision- and epoch-fenced identity for one temporary Runner."

  alias Spectre.Run.Value

  @kinds [:work, :vigil, :directive]
  @side_effects [:none, :idempotent, :reconcilable, :non_idempotent]

  @enforce_keys [
    :id,
    :loop_id,
    :loop_kind,
    :operation,
    :request_id,
    :number,
    :epoch,
    :fencing_token,
    :base_revision,
    :context_revision,
    :control_generation,
    :snapshot_id,
    :idempotency_key,
    :started_at
  ]
  defstruct [
    :id,
    :loop_id,
    :loop_kind,
    :operation,
    :request_id,
    :number,
    :epoch,
    :fencing_token,
    :base_revision,
    :context_revision,
    :control_generation,
    :trigger_generation,
    :snapshot_id,
    :idempotency_key,
    :started_at,
    :timeout,
    :side_effect,
    :retry_number,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          loop_id: String.t(),
          loop_kind: :work | :vigil | :directive,
          operation: atom() | String.t(),
          request_id: String.t(),
          number: pos_integer(),
          epoch: String.t(),
          fencing_token: String.t(),
          base_revision: non_neg_integer(),
          context_revision: non_neg_integer(),
          control_generation: non_neg_integer(),
          trigger_generation: non_neg_integer(),
          snapshot_id: String.t(),
          idempotency_key: String.t(),
          started_at: non_neg_integer(),
          timeout: pos_integer(),
          side_effect: atom(),
          retry_number: non_neg_integer(),
          metadata: map()
        }

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = attempt) do
    cond do
      Enum.any?(
        [
          attempt.id,
          attempt.loop_id,
          attempt.epoch,
          attempt.fencing_token,
          attempt.snapshot_id,
          attempt.idempotency_key,
          attempt.request_id
        ],
        &(not valid_binary?(&1))
      ) ->
        {:error, :invalid_operation_attempt_identity}

      attempt.loop_kind not in @kinds ->
        {:error, :invalid_operation_attempt_kind}

      not valid_name?(attempt.operation) ->
        {:error, :invalid_operation_attempt_operation}

      not positive_integer?(attempt.number) ->
        {:error, :invalid_operation_attempt_number}

      not non_negative_integer?(attempt.base_revision) ->
        {:error, :invalid_operation_attempt_base_revision}

      not non_negative_integer?(attempt.context_revision) ->
        {:error, :invalid_operation_attempt_context_revision}

      not non_negative_integer?(attempt.control_generation) ->
        {:error, :invalid_operation_attempt_control_generation}

      not non_negative_integer?(attempt.trigger_generation) ->
        {:error, :invalid_operation_attempt_trigger_generation}

      not non_negative_integer?(attempt.started_at) ->
        {:error, :invalid_operation_attempt_started_at}

      not positive_integer?(attempt.timeout) ->
        {:error, :invalid_operation_attempt_timeout}

      attempt.side_effect not in @side_effects ->
        {:error, :invalid_operation_attempt_side_effect}

      not non_negative_integer?(attempt.retry_number) ->
        {:error, :invalid_operation_attempt_retry_number}

      not is_map(attempt.metadata) ->
        {:error, :invalid_operation_attempt_metadata}

      true ->
        portable(attempt)
    end
  end

  defp portable(attempt) do
    case Value.validate(attempt, [:operation_attempt, attempt.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_attempt, reason}}
    end
  end

  defp valid_binary?(value), do: is_binary(value) and value != ""
  defp valid_name?(value), do: (is_atom(value) and not is_nil(value)) or valid_binary?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
