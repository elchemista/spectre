defmodule Spectre.Operation.Budget do
  @moduledoc """
  Portable limits and consumption counters for one operational loop.

  A missing limit means that dimension is not bounded. Budget checks happen
  before a Runner is created and again after its committed result.
  """

  @dimensions [:steps, :attempts, :retries, :duration_ms, :cost]

  defstruct limits: %{
              steps: nil,
              attempts: nil,
              retries: nil,
              duration_ms: nil,
              cost: nil
            },
            consumed: %{steps: 0, attempts: 0, retries: 0, cost: 0},
            started_at: nil,
            deadline_at: nil,
            resources: %{}

  @type dimension :: :steps | :attempts | :retries | :duration_ms | :cost

  @type t :: %__MODULE__{
          limits: %{optional(dimension()) => non_neg_integer() | number() | nil},
          consumed: %{optional(atom()) => non_neg_integer() | number()},
          started_at: non_neg_integer(),
          deadline_at: non_neg_integer() | nil,
          resources: map()
        }

  @doc """
  Builds a validated budget from a struct, map, keyword list or `nil`.

  `nil` yields an unbounded budget. Limits may be given at the top level or under
  `:limits`; a `:duration_ms` limit derives `deadline_at` from `now` unless a
  deadline is given explicitly. Raises `ArgumentError` when the result is invalid.
  """
  @spec new(t() | map() | keyword() | nil, non_neg_integer()) :: t()
  def new(value \\ nil, now \\ System.system_time(:millisecond))

  def new(%__MODULE__{} = budget, _now), do: validate!(budget)
  def new(nil, now), do: new(%{}, now)
  def new(value, now) when is_list(value), do: value |> Map.new() |> new(now)

  def new(value, now) when is_map(value) and is_integer(now) and now >= 0 do
    validate_input_keys!(value)
    raw_limits = attr(value, :limits, value)
    if Map.has_key?(value, :limits), do: validate_limit_keys!(raw_limits)
    raw_consumed = attr(value, :consumed, %{})
    validate_consumed_keys!(raw_consumed)
    duration = attr(raw_limits, :duration_ms)

    limits =
      Map.new(@dimensions, fn dimension ->
        {dimension, attr(raw_limits, dimension)}
      end)

    consumed =
      raw_consumed
      |> then(fn consumed ->
        %{
          steps: attr(consumed, :steps, 0),
          attempts: attr(consumed, :attempts, 0),
          retries: attr(consumed, :retries, 0),
          cost: attr(consumed, :cost, 0)
        }
      end)

    %__MODULE__{
      limits: limits,
      consumed: consumed,
      started_at: attr(value, :started_at, now),
      deadline_at: attr(value, :deadline_at, deadline(now, duration)),
      resources: attr(value, :resources, %{})
    }
    |> validate!()
  end

  @doc "Returns the first exhausted dimension, if any."
  @spec exhausted(t(), non_neg_integer()) :: nil | {dimension(), number(), number()}
  def exhausted(%__MODULE__{} = budget, now \\ System.system_time(:millisecond)) do
    Enum.find_value(@dimensions, fn
      :duration_ms ->
        case budget.deadline_at do
          deadline when is_integer(deadline) and now >= deadline ->
            {:duration_ms, max(now - budget.started_at, 0), budget.limits.duration_ms}

          _unbounded ->
            nil
        end

      dimension ->
        limit = Map.fetch!(budget.limits, dimension)
        consumed = Map.get(budget.consumed, dimension, 0)

        if is_number(limit) and consumed >= limit,
          do: {dimension, consumed, limit},
          else: nil
    end)
  end

  @doc "Consumes one or more budget dimensions."
  @spec consume(t(), map() | keyword()) :: t()
  def consume(%__MODULE__{} = budget, usage) when is_list(usage),
    do: consume(budget, Map.new(usage))

  def consume(%__MODULE__{} = budget, usage) when is_map(usage) do
    consumed =
      Enum.reduce(usage, budget.consumed, fn {dimension, amount}, acc ->
        unless dimension in [:steps, :attempts, :retries, :cost] and is_number(amount) and
                 amount >= 0 do
          raise ArgumentError,
                "invalid operational budget consumption: #{inspect({dimension, amount})}"
        end

        Map.update(acc, dimension, amount, &(&1 + amount))
      end)

    %{budget | consumed: consumed}
  end

  @doc "Returns the remaining value for a bounded dimension."
  @spec remaining(t(), dimension()) :: number() | :infinity
  def remaining(%__MODULE__{} = budget, :duration_ms) do
    case budget.deadline_at do
      nil -> :infinity
      deadline -> max(deadline - System.system_time(:millisecond), 0)
    end
  end

  def remaining(%__MODULE__{} = budget, dimension) when dimension in @dimensions do
    case Map.fetch!(budget.limits, dimension) do
      nil -> :infinity
      limit -> max(limit - Map.get(budget.consumed, dimension, 0), 0)
    end
  end

  @doc """
  Validates the budget's limits, consumption counters, timestamps and portability.

  Returns `:ok`, or `{:error, reason}` naming the first invalid field.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = budget) do
    cond do
      not is_map(budget.limits) ->
        {:error, :invalid_operational_budget_limits}

      MapSet.new(Map.keys(budget.limits)) != MapSet.new(@dimensions) ->
        {:error, :invalid_operational_budget_dimensions}

      invalid =
          Enum.find(budget.limits, fn {_dimension, value} ->
            not (is_nil(value) or (is_number(value) and value >= 0))
          end) ->
        {:error, {:invalid_operational_budget_limit, invalid}}

      not is_map(budget.consumed) ->
        {:error, :invalid_operational_budget_consumption}

      invalid =
          Enum.find(budget.consumed, fn {dimension, value} ->
            dimension not in [:steps, :attempts, :retries, :cost] or
                not (is_number(value) and value >= 0)
          end) ->
        {:error, {:invalid_operational_budget_consumption, invalid}}

      not is_integer(budget.started_at) or budget.started_at < 0 ->
        {:error, :invalid_operational_budget_start}

      not is_nil(budget.deadline_at) and
          (not is_integer(budget.deadline_at) or budget.deadline_at < budget.started_at) ->
        {:error, :invalid_operational_budget_deadline}

      not is_map(budget.resources) ->
        {:error, :invalid_operational_budget_resources}

      true ->
        case Spectre.Run.Value.validate(budget, [:operation_budget]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:nonportable_operational_budget, reason}}
        end
    end
  end

  @doc """
  Same as `validate/1` but returns the budget, raising `ArgumentError` when invalid.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = budget) do
    case validate(budget) do
      :ok -> budget
      {:error, reason} -> raise ArgumentError, "invalid operational budget: #{inspect(reason)}"
    end
  end

  @spec deadline(non_neg_integer(), term()) :: non_neg_integer() | nil
  defp deadline(_now, nil), do: nil

  defp deadline(now, duration) when is_number(duration) and duration >= 0,
    do: now + trunc(duration)

  defp deadline(_now, _duration), do: nil

  @spec attr(map(), atom(), term()) :: term()
  defp attr(map, key, default \\ nil),
    do: Map.get(map, key, default)

  defp validate_input_keys!(value) do
    allowed = @dimensions ++ [:limits, :consumed, :started_at, :deadline_at, :resources]

    case Enum.find(Map.keys(value), &(&1 not in allowed)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown operational budget key: #{inspect(key)}"
    end
  end

  defp validate_limit_keys!(limits) when is_map(limits) do
    case Enum.find(Map.keys(limits), &(&1 not in @dimensions)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown operational budget limit: #{inspect(key)}"
    end
  end

  defp validate_limit_keys!(limits) do
    raise ArgumentError, "invalid operational budget limits: #{inspect(limits)}"
  end

  defp validate_consumed_keys!(consumed) when is_map(consumed) do
    allowed = [:steps, :attempts, :retries, :cost]

    case Enum.find(Map.keys(consumed), &(&1 not in allowed)) do
      nil -> :ok
      key -> raise ArgumentError, "unknown operational budget consumption: #{inspect(key)}"
    end
  end

  defp validate_consumed_keys!(consumed) do
    raise ArgumentError, "invalid operational budget consumption: #{inspect(consumed)}"
  end
end
