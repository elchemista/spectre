defmodule Spectre.Operation.Outcome do
  @moduledoc "Typed terminal outcome of an operational loop."

  alias Spectre.Run.Value

  @categories [
    :completed,
    :failed,
    :cancelled,
    :expired,
    :budget_exhausted,
    :unknown_side_effect
  ]

  @enforce_keys [:category, :at]
  defstruct [
    :category,
    :reason,
    :result,
    :limit,
    :consumed,
    :last_revision,
    :at,
    partial: %{},
    artifacts: [],
    metadata: %{}
  ]

  @type category ::
          :completed
          | :failed
          | :cancelled
          | :expired
          | :budget_exhausted
          | :unknown_side_effect

  @type t :: %__MODULE__{
          category: category(),
          reason: term(),
          result: term(),
          limit: term(),
          consumed: term(),
          last_revision: non_neg_integer() | nil,
          at: non_neg_integer(),
          partial: map(),
          artifacts: [term()],
          metadata: map()
        }

  @spec new(category(), keyword()) :: t()
  def new(category, opts \\ []) when category in @categories and is_list(opts) do
    outcome = %__MODULE__{
      category: category,
      reason: Keyword.get(opts, :reason),
      result: Keyword.get(opts, :result),
      limit: Keyword.get(opts, :limit),
      consumed: Keyword.get(opts, :consumed),
      last_revision: Keyword.get(opts, :last_revision),
      at: Keyword.get(opts, :at, System.system_time(:millisecond)),
      partial: Keyword.get(opts, :partial, %{}),
      artifacts: Keyword.get(opts, :artifacts, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate!(outcome)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = outcome) do
    cond do
      outcome.category not in @categories ->
        {:error, :invalid_operation_outcome_category}

      not (is_integer(outcome.at) and outcome.at >= 0) ->
        {:error, :invalid_operation_outcome_timestamp}

      not is_nil(outcome.last_revision) and
          (not is_integer(outcome.last_revision) or outcome.last_revision < 0) ->
        {:error, :invalid_operation_outcome_revision}

      not is_map(outcome.partial) ->
        {:error, :invalid_operation_outcome_partial_state}

      not is_list(outcome.artifacts) ->
        {:error, :invalid_operation_outcome_artifacts}

      not is_map(outcome.metadata) ->
        {:error, :invalid_operation_outcome_metadata}

      true ->
        portable(outcome)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = outcome) do
    case validate(outcome) do
      :ok -> outcome
      {:error, reason} -> raise ArgumentError, "invalid operation outcome: #{inspect(reason)}"
    end
  end

  defp portable(outcome) do
    case Value.validate(outcome, [:operation_outcome, outcome.category]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_outcome, reason}}
    end
  end
end
