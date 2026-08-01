defmodule Spectre.Operation.Progress do
  @moduledoc "Revision-fenced, rate-limited progress emitted by a temporary Runner."

  alias Spectre.Run.Value

  @enforce_keys [
    :id,
    :attempt_id,
    :loop_id,
    :epoch,
    :fencing_token,
    :context_revision,
    :control_generation,
    :trigger_generation,
    :sequence,
    :at
  ]
  defstruct [
    :id,
    :attempt_id,
    :loop_id,
    :epoch,
    :fencing_token,
    :context_revision,
    :control_generation,
    :trigger_generation,
    :sequence,
    :value,
    :at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          attempt_id: String.t(),
          loop_id: String.t(),
          epoch: String.t(),
          fencing_token: String.t(),
          context_revision: non_neg_integer(),
          control_generation: non_neg_integer(),
          trigger_generation: non_neg_integer(),
          sequence: pos_integer(),
          value: term(),
          at: non_neg_integer(),
          metadata: map()
        }

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = progress) do
    cond do
      Enum.any?(
        [
          progress.id,
          progress.attempt_id,
          progress.loop_id,
          progress.epoch,
          progress.fencing_token
        ],
        &(not (is_binary(&1) and &1 != ""))
      ) ->
        {:error, :invalid_operation_progress_identity}

      not non_negative_integer?(progress.context_revision) ->
        {:error, :invalid_operation_progress_context_revision}

      not non_negative_integer?(progress.control_generation) ->
        {:error, :invalid_operation_progress_control_generation}

      not non_negative_integer?(progress.trigger_generation) ->
        {:error, :invalid_operation_progress_trigger_generation}

      not (is_integer(progress.sequence) and progress.sequence > 0) ->
        {:error, :invalid_operation_progress_sequence}

      not non_negative_integer?(progress.at) ->
        {:error, :invalid_operation_progress_timestamp}

      not is_map(progress.metadata) ->
        {:error, :invalid_operation_progress_metadata}

      true ->
        portable(progress)
    end
  end

  defp portable(progress) do
    case Value.validate(progress, [:operation_progress, progress.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_progress, reason}}
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
