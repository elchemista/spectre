defmodule Spectre.Operation.Retry do
  @moduledoc "Portable retry and backoff policy for a registered operation."

  defstruct max_attempts: 1,
            strategy: :exponential,
            base_delay_ms: 100,
            max_delay_ms: 30_000,
            retry_on: [:error, :crash, :timeout]

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          strategy: :constant | :linear | :exponential,
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          retry_on: [atom()]
        }

  @spec new(t() | map() | keyword() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = retry), do: validate!(retry)
  def new(value) when is_list(value), do: value |> Map.new() |> new()

  def new(value) when is_map(value) do
    %__MODULE__{
      max_attempts: attr(value, :max_attempts, 1),
      strategy: attr(value, :strategy, :exponential),
      base_delay_ms: attr(value, :base_delay_ms, 100),
      max_delay_ms: attr(value, :max_delay_ms, 30_000),
      retry_on: List.wrap(attr(value, :retry_on, [:error, :crash, :timeout]))
    }
    |> validate!()
  end

  @spec delay(t(), pos_integer()) :: non_neg_integer()
  def delay(%__MODULE__{} = retry, attempt) when is_integer(attempt) and attempt > 0 do
    multiplier =
      case retry.strategy do
        :constant -> 1
        :linear -> attempt
        :exponential -> Integer.pow(2, max(attempt - 1, 0))
      end

    min(retry.base_delay_ms * multiplier, retry.max_delay_ms)
  end

  @spec retry?(t(), atom(), pos_integer()) :: boolean()
  def retry?(%__MODULE__{} = retry, reason_class, attempt) do
    reason_class in retry.retry_on and attempt < retry.max_attempts
  end

  defp validate!(%__MODULE__{} = retry) do
    unless is_integer(retry.max_attempts) and retry.max_attempts > 0,
      do: raise(ArgumentError, "operation retry max_attempts must be positive")

    unless retry.strategy in [:constant, :linear, :exponential],
      do: raise(ArgumentError, "invalid operation retry strategy")

    unless is_integer(retry.base_delay_ms) and retry.base_delay_ms >= 0 and
             is_integer(retry.max_delay_ms) and retry.max_delay_ms >= retry.base_delay_ms,
           do: raise(ArgumentError, "invalid operation retry delay")

    unless is_list(retry.retry_on) and Enum.all?(retry.retry_on, &is_atom/1),
      do: raise(ArgumentError, "operation retry_on must contain atoms")

    retry
  end

  defp attr(map, key, default),
    do: Map.get(map, key, default)
end
