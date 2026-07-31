defmodule Spectre.Operation.Execution do
  @moduledoc """
  Portable output envelope produced by an operational executor.

  Ordinary functions may still return a plain value. Executors that need audit
  data can return this struct to attach a receipt, usage, artifacts and redacted
  metadata to the fenced Result without gaining access to canonical state.
  """

  alias Spectre.Run.Value

  defstruct [:value, :receipt, usage: %{}, artifacts: [], metadata: %{}]

  @type t :: %__MODULE__{
          value: term(),
          receipt: term(),
          usage: map(),
          artifacts: [term()],
          metadata: map()
        }

  @spec new(term(), keyword()) :: t()
  def new(value, opts \\ []) when is_list(opts) do
    execution = %__MODULE__{
      value: value,
      receipt: Keyword.get(opts, :receipt),
      usage: Keyword.get(opts, :usage, %{}),
      artifacts: List.wrap(Keyword.get(opts, :artifacts, [])),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate!(execution)
  end

  @spec normalize(t() | term()) :: t()
  def normalize(%__MODULE__{} = execution), do: execution
  def normalize(value), do: new(value)

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = execution) do
    cost =
      if is_map(execution.usage),
        do: Map.get(execution.usage, :cost, Map.get(execution.usage, "cost"))

    cond do
      not is_map(execution.usage) ->
        {:error, :invalid_operation_execution_usage}

      not is_nil(cost) and not (is_number(cost) and cost >= 0) ->
        {:error, :invalid_operation_execution_cost}

      not is_list(execution.artifacts) ->
        {:error, :invalid_operation_execution_artifacts}

      not is_map(execution.metadata) ->
        {:error, :invalid_operation_execution_metadata}

      true ->
        portable(execution)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = execution) do
    case validate(execution) do
      :ok -> execution
      {:error, reason} -> raise ArgumentError, "invalid operation execution: #{inspect(reason)}"
    end
  end

  defp portable(execution) do
    case Value.validate(execution, [:operation_execution]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_execution, reason}}
    end
  end
end
