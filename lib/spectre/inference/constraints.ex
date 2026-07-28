defmodule Spectre.Inference.Constraints do
  @moduledoc """
  Hard limits and soft preferences attached to one inference request.

  Constraint merging is monotonic: a handler may strengthen a flow constraint,
  but cannot widen privacy, cost, latency, or minimum-capability limits.
  """

  @standard_ranks %{fast: 10, balanced: 20, deep: 30}
  @tier_ranks %{low: 10, medium: 20, high: 30}
  @privacy_ranks %{cloud_allowed: 10, private_cloud_only: 20, local_only: 30}

  defstruct [
    :minimum_level,
    :preferred_level,
    :context_tokens,
    :maximum_latency_ms,
    :maximum_cost_tier,
    :maximum_output_tokens,
    structured_output?: false,
    risk: :low,
    privacy: :cloud_allowed,
    strict?: false,
    max_attempts: nil
  ]

  @type t :: %__MODULE__{
          minimum_level: term(),
          preferred_level: term(),
          structured_output?: boolean(),
          context_tokens: non_neg_integer() | nil,
          risk: :low | :medium | :high | atom(),
          privacy: :cloud_allowed | :private_cloud_only | :local_only | atom(),
          maximum_latency_ms: pos_integer() | nil,
          maximum_cost_tier: :low | :medium | :high | nil,
          maximum_output_tokens: pos_integer() | nil,
          strict?: boolean(),
          max_attempts: pos_integer() | nil
        }

  @spec new(t() | map() | keyword() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = constraints), do: constraints
  def new(attrs) when is_list(attrs), do: attrs |> normalize_aliases() |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    constraints = struct(__MODULE__, Map.take(attrs, fields()))
    validate!(constraints)
    constraints
  end

  @doc """
  Builds constraints from flow contributions followed by call-site options.
  """
  @spec from_options(keyword(), [Spectre.Flow.Constraint.t()]) :: t()
  def from_options(opts, flow_constraints \\ []) when is_list(opts) do
    flow =
      flow_constraints
      |> Enum.filter(&(&1.kind == :inference))
      |> Enum.reduce(new(nil), fn constraint, accumulated ->
        constraint.values
        |> Enum.reduce(accumulated, fn value, current -> merge(current, new(value)) end)
      end)

    explicit =
      opts
      |> inference_options()
      |> new()

    merge(flow, explicit)
  end

  @doc """
  Merges a stronger layer into an existing constraint set.
  """
  @spec merge(t(), t() | map() | keyword()) :: t()
  def merge(base, stronger) do
    base = new(base)
    stronger = new(stronger)

    %__MODULE__{
      minimum_level: stricter_minimum(base.minimum_level, stronger.minimum_level),
      preferred_level: stronger.preferred_level || base.preferred_level,
      structured_output?: base.structured_output? or stronger.structured_output?,
      context_tokens: max_optional(base.context_tokens, stronger.context_tokens),
      risk: stricter_ranked(base.risk, stronger.risk, %{low: 10, medium: 20, high: 30}),
      privacy: stricter_ranked(base.privacy, stronger.privacy, @privacy_ranks),
      maximum_latency_ms: min_optional(base.maximum_latency_ms, stronger.maximum_latency_ms),
      maximum_cost_tier:
        min_ranked(base.maximum_cost_tier, stronger.maximum_cost_tier, @tier_ranks),
      maximum_output_tokens:
        min_optional(base.maximum_output_tokens, stronger.maximum_output_tokens),
      strict?: base.strict? or stronger.strict?,
      max_attempts: min_optional(base.max_attempts, stronger.max_attempts)
    }
  end

  @spec inference_options(keyword()) :: keyword()
  defp inference_options(opts) do
    nested =
      [:inference, :prism]
      |> Enum.flat_map(fn key ->
        case Keyword.get(opts, key, []) do
          value when is_list(value) -> value
          value when is_map(value) -> Map.to_list(value)
          _other -> []
        end
      end)

    intelligence =
      case Keyword.get(opts, :intelligence) do
        nil -> []
        level -> [minimum_level: level, preferred_level: level]
      end

    direct =
      Keyword.take(opts, [
        :minimum_level,
        :minimum,
        :preferred_level,
        :prefer,
        :structured_output?,
        :structured_output,
        :context_tokens,
        :risk,
        :privacy,
        :maximum_latency_ms,
        :maximum_cost_tier,
        :maximum_output_tokens,
        :strict?,
        :strict,
        :max_attempts,
        :maximum_attempts
      ])

    direct
    |> Keyword.merge(nested)
    |> Keyword.merge(intelligence)
    |> normalize_aliases()
  end

  @spec normalize_aliases(keyword()) :: keyword()
  defp normalize_aliases(opts) do
    opts
    |> move_alias(:minimum, :minimum_level)
    |> move_alias(:prefer, :preferred_level)
    |> move_alias(:structured_output, :structured_output?)
    |> move_alias(:strict, :strict?)
    |> move_alias(:maximum_attempts, :max_attempts)
  end

  @spec move_alias(keyword(), atom(), atom()) :: keyword()
  defp move_alias(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {value, opts} -> Keyword.put_new(opts, to, value)
    end
  end

  @spec stricter_minimum(term(), term()) :: term()
  defp stricter_minimum(nil, value), do: value
  defp stricter_minimum(value, nil), do: value

  defp stricter_minimum(left, right) do
    case {Map.get(@standard_ranks, left), Map.get(@standard_ranks, right)} do
      {left_rank, right_rank} when is_integer(left_rank) and is_integer(right_rank) ->
        if right_rank >= left_rank, do: right, else: left

      _custom ->
        right
    end
  end

  @spec stricter_ranked(term(), term(), map()) :: term()
  defp stricter_ranked(nil, value, _ranks), do: value
  defp stricter_ranked(value, nil, _ranks), do: value

  defp stricter_ranked(left, right, ranks) do
    if Map.get(ranks, right, 0) >= Map.get(ranks, left, 0), do: right, else: left
  end

  @spec min_ranked(term(), term(), map()) :: term()
  defp min_ranked(nil, value, _ranks), do: value
  defp min_ranked(value, nil, _ranks), do: value

  defp min_ranked(left, right, ranks) do
    if Map.get(ranks, right, 1_000) <= Map.get(ranks, left, 1_000), do: right, else: left
  end

  @spec min_optional(number() | nil, number() | nil) :: number() | nil
  defp min_optional(nil, value), do: value
  defp min_optional(value, nil), do: value
  defp min_optional(left, right), do: min(left, right)

  @spec max_optional(number() | nil, number() | nil) :: number() | nil
  defp max_optional(nil, value), do: value
  defp max_optional(value, nil), do: value
  defp max_optional(left, right), do: max(left, right)

  @spec validate!(t()) :: :ok
  defp validate!(%__MODULE__{} = constraints) do
    validate_positive(constraints.context_tokens, :context_tokens, allow_zero?: true)
    validate_positive(constraints.maximum_latency_ms, :maximum_latency_ms)
    validate_positive(constraints.maximum_output_tokens, :maximum_output_tokens)
    validate_positive(constraints.max_attempts, :max_attempts)

    unless constraints.maximum_cost_tier in [nil, :low, :medium, :high],
      do: raise(ArgumentError, "invalid maximum cost tier")

    unless is_boolean(constraints.structured_output?) and is_boolean(constraints.strict?),
      do: raise(ArgumentError, "inference boolean constraints must be booleans")

    :ok
  end

  @spec validate_positive(term(), atom(), keyword()) :: :ok
  defp validate_positive(value, field, opts \\ [])
  defp validate_positive(nil, _field, _opts), do: :ok

  defp validate_positive(value, _field, _opts)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_positive(0, _field, opts) do
    if Keyword.get(opts, :allow_zero?, false),
      do: :ok,
      else: raise(ArgumentError, "inference constraint must be positive")
  end

  defp validate_positive(_value, field, _opts),
    do: raise(ArgumentError, "#{field} must be a positive integer")

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
