defmodule Spectre.Inference.BudgetSnapshot do
  @moduledoc """
  Immutable, per-attempt budget handed from the Instance to a worker/session.

  Deadlines are absolute system milliseconds. Heartbeats may renew stall
  timers, but they never mutate `deadline_at`.
  """

  alias Spectre.Inference.Usage
  alias Spectre.Run.Value

  @limit_fields [:input_tokens, :output_tokens, :total_tokens, :cost, :duration_ms]
  @policies [:provider, :conservative, :unavailable]

  @enforce_keys [:inference_id, :attempt_id]
  defstruct [
    :inference_id,
    :attempt_id,
    :deadline_at,
    :pricing_ref,
    remaining: %{},
    reserved: %Usage{},
    estimation_policy: :unavailable
  ]

  @type limit :: non_neg_integer() | number() | nil
  @type t :: %__MODULE__{
          inference_id: String.t(),
          attempt_id: String.t(),
          deadline_at: integer() | nil,
          remaining: %{optional(atom()) => limit()},
          reserved: Usage.t(),
          pricing_ref: String.t() | nil,
          estimation_policy: :provider | :conservative | :unavailable
        }

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    snapshot = %__MODULE__{
      inference_id: Keyword.fetch!(opts, :inference_id),
      attempt_id: Keyword.fetch!(opts, :attempt_id),
      deadline_at: Keyword.get(opts, :deadline_at),
      remaining: normalize_limits(Keyword.get(opts, :remaining, %{})),
      reserved: Usage.new(Keyword.get(opts, :reserved)),
      pricing_ref: Keyword.get(opts, :pricing_ref),
      estimation_policy: Keyword.get(opts, :estimation_policy, :unavailable)
    }

    case validate(snapshot) do
      :ok -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid budget snapshot: #{inspect(reason)}"
    end
  end

  @spec exceeded(t(), Usage.t() | map()) :: :ok | {:error, atom()}
  def exceeded(%__MODULE__{} = snapshot, usage) do
    usage = Usage.new(usage)

    Enum.find_value(@limit_fields, :ok, fn field ->
      used = Map.fetch!(usage, field)

      case Map.get(snapshot.remaining, field) do
        nil -> false
        limit when used > limit -> {:error, field}
        _within -> false
      end
    end)
  end

  @spec deadline_exceeded?(t(), integer()) :: boolean()
  def deadline_exceeded?(%__MODULE__{deadline_at: nil}, _now), do: false
  def deadline_exceeded?(%__MODULE__{deadline_at: deadline}, now), do: now >= deadline

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # The dispatch snapshot is security-sensitive input to the data plane, so
  # validate its complete portable shape at one boundary.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = snapshot) do
    cond do
      not nonempty_binary?(snapshot.inference_id) or not nonempty_binary?(snapshot.attempt_id) ->
        {:error, :invalid_budget_snapshot_identity}

      not is_nil(snapshot.deadline_at) and
          (not is_integer(snapshot.deadline_at) or snapshot.deadline_at < 0) ->
        {:error, :invalid_budget_snapshot_deadline}

      not valid_limits?(snapshot.remaining) ->
        {:error, :invalid_budget_snapshot_remaining}

      not is_nil(snapshot.pricing_ref) and not nonempty_binary?(snapshot.pricing_ref) ->
        {:error, :invalid_budget_snapshot_pricing_ref}

      Map.has_key?(snapshot.remaining, :cost) and is_nil(snapshot.pricing_ref) ->
        {:error, :inference_cost_budget_requires_pricing_ref}

      snapshot.estimation_policy not in @policies ->
        {:error, :invalid_budget_estimation_policy}

      true ->
        with :ok <- Usage.validate(snapshot.reserved) do
          Value.validate(snapshot, [:budget_snapshot])
        end
    end
  end

  defp normalize_limits(limits) when is_list(limits) do
    if Keyword.keyword?(limits), do: limits |> Map.new() |> normalize_limits(), else: limits
  end

  defp normalize_limits(limits) when is_map(limits) and not is_struct(limits) do
    Map.new(limits, fn
      {field, value} when field in @limit_fields -> {field, value}
      {field, value} when is_binary(field) -> {known_limit_field(field), value}
      entry -> entry
    end)
  end

  # Preserve invalid shapes so validation fails closed. In particular, a typo
  # or negative value must never be normalized into an unlimited budget.
  defp normalize_limits(limits), do: limits

  defp valid_limits?(limits) when is_map(limits) and not is_struct(limits) do
    Enum.all?(limits, fn
      {field, nil} when field in @limit_fields -> true
      {field, value} when field in @limit_fields -> is_number(value) and value >= 0
      _entry -> false
    end)
  end

  defp valid_limits?(_limits), do: false

  defp known_limit_field("input_tokens"), do: :input_tokens
  defp known_limit_field("output_tokens"), do: :output_tokens
  defp known_limit_field("total_tokens"), do: :total_tokens
  defp known_limit_field("cost"), do: :cost
  defp known_limit_field("duration_ms"), do: :duration_ms
  defp known_limit_field(field), do: field
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
