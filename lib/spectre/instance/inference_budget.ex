defmodule Spectre.Instance.InferenceBudget do
  @moduledoc false

  # Internal budget boundary shared by live dispatch, retry, steering, and
  # recovery. It owns configuration normalization and immutable attempt
  # reservations; the Instance remains responsible for canonical commits.

  alias Spectre.Inference.Budget
  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Failure
  alias Spectre.Inference.Prepared
  alias Spectre.Inference.Selector.Default
  alias Spectre.Inference.Usage
  alias Spectre.Invocation
  alias Spectre.Run

  @doc false
  @spec reserve(Run.t(), Invocation.t(), Prepared.t(), map()) ::
          {:ok, Run.t(), BudgetSnapshot.t()} | {:error, term()}
  def reserve(%Run{} = run, %Invocation{} = invocation, %Prepared{} = prepared, entry)
      when is_map(entry) do
    continuation = run.inference_continuation

    with {:ok, budget} <- budget(continuation, prepared, entry),
         requested <- reservation(prepared, budget),
         {:ok, budget, snapshot} <- Budget.reserve(budget, invocation.attempt_id, requested) do
      continuation = %{continuation | budget: budget}
      {:ok, %{run | inference_continuation: continuation}, snapshot}
    end
  end

  @doc false
  @spec settle(map(), String.t(), Usage.t() | map(), :confirmed | :ambiguous) ::
          {:ok, map()} | {:error, map(), term()}
  def settle(%{budget: %Budget{} = budget} = continuation, attempt_id, usage, status) do
    case Budget.settle(budget, attempt_id, usage, status) do
      {:ok, settled} ->
        {:ok, %{continuation | budget: settled}}

      {:error, reason} ->
        failed = %{
          continuation
          | recovery: %{
              status: :budget_settlement_failed,
              reason: Failure.sanitize(reason)
            }
        }

        {:error, failed, reason}
    end
  end

  def settle(continuation, _attempt_id, _usage, _status), do: {:ok, continuation}

  @doc false
  @spec enforce(map(), Usage.t() | map()) :: :ok | {:error, atom()}
  def enforce(%{budget_snapshot: %BudgetSnapshot{} = snapshot}, usage),
    do: BudgetSnapshot.exceeded(snapshot, usage)

  def enforce(_ownership, _usage), do: :ok

  defp budget(%{budget: %Budget{} = budget}, prepared, entry) do
    with :ok <- validate_cost_budget(budget.limits, budget.pricing_ref, prepared, entry),
         :ok <- validate_rebound_pricing_ref(budget, entry) do
      {:ok, budget}
    end
  end

  defp budget(continuation, prepared, entry),
    do: new_budget(continuation, prepared, entry)

  defp new_budget(continuation, prepared, entry) do
    with {:ok, configured} <- normalize(entry.opts),
         {:ok, attempts} <- attempt_limit(prepared, entry),
         {:ok, pricing_ref} <- pricing_ref(entry.opts),
         :ok <- validate_cost_budget(configured, pricing_ref, prepared, entry) do
      constraints = prepared.descriptor.constraints
      aggregate_input = multiply_limit(constraints.context_tokens, attempts)
      aggregate_output = multiply_limit(constraints.maximum_output_tokens, attempts)

      limits =
        configured
        |> maybe_put_limit(:input_tokens, aggregate_input)
        |> maybe_put_limit(:output_tokens, aggregate_output)
        |> maybe_put_limit(:total_tokens, sum_limits(aggregate_input, aggregate_output))
        |> maybe_put_limit(:attempts, attempts)
        |> maybe_put_limit(
          :duration_ms,
          Keyword.get(entry.opts, :stream_max_duration_ms, constraints.maximum_latency_ms)
        )

      deadline_at =
        case Map.get(limits, :duration_ms) do
          duration when is_integer(duration) and duration > 0 ->
            Spectre.Determinism.system_time(:millisecond) + duration

          _none ->
            nil
        end

      {:ok,
       Budget.new(continuation.inference_id,
         limits: limits,
         deadline_at: deadline_at,
         pricing_ref: pricing_ref,
         estimation_policy:
           if(MapSet.member?(prepared.stream_capabilities, :incremental_usage),
             do: :provider,
             else: :conservative
           )
       )}
    end
  end

  defp normalize(opts) do
    value = Keyword.get(opts, :inference_budget, %{})

    with {:ok, entries} <- entries(value) do
      Enum.reduce_while(entries, {:ok, %{}}, &put_normalized_limit/2)
    end
  end

  defp put_normalized_limit({key, limit}, {:ok, limits}) do
    case normalize_limit(key, limit) do
      {:ok, field} -> {:cont, {:ok, Map.put(limits, field, limit)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp normalize_limit(key, limit) do
    with {:ok, field} <- field(key),
         :ok <- validate_limit(field, limit) do
      {:ok, field}
    end
  end

  defp entries(value) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, value}, else: {:error, :invalid_inference_budget}
  end

  defp entries(value) when is_map(value) and not is_struct(value),
    do: {:ok, Map.to_list(value)}

  defp entries(_value), do: {:error, :invalid_inference_budget}

  defp field(field)
       when field in [
              :input_tokens,
              :output_tokens,
              :total_tokens,
              :cost,
              :attempts,
              :duration_ms
            ],
       do: {:ok, field}

  defp field(field) when is_binary(field) do
    case field do
      "input_tokens" -> {:ok, :input_tokens}
      "output_tokens" -> {:ok, :output_tokens}
      "total_tokens" -> {:ok, :total_tokens}
      "cost" -> {:ok, :cost}
      "attempts" -> {:ok, :attempts}
      "duration_ms" -> {:ok, :duration_ms}
      _unknown -> {:error, {:unknown_inference_budget_limit, field}}
    end
  end

  defp field(field), do: {:error, {:unknown_inference_budget_limit, field}}

  defp validate_limit(:attempts, value) when is_integer(value) and value > 0, do: :ok

  defp validate_limit(:attempts, value),
    do: {:error, {:invalid_inference_budget_limit, :attempts, value}}

  defp validate_limit(_field, value) when is_number(value) and value >= 0, do: :ok

  defp validate_limit(field, value),
    do: {:error, {:invalid_inference_budget_limit, field, value}}

  @doc false
  @spec attempt_limit(Prepared.t(), map()) :: {:ok, pos_integer()} | {:error, term()}
  def attempt_limit(%Prepared{} = prepared, entry) when is_map(entry) do
    fallback_attempts = length(prepared.selection.fallback_chain) + 1

    one_shot_default =
      if prepared.selection.selector == Default,
        do: max(fallback_attempts, 1),
        else: max(fallback_attempts, 2)

    value =
      prepared.descriptor.constraints.max_attempts ||
        if(prepared.stream_adapter,
          do: Keyword.get(entry.opts, :stream_max_attempts, 3),
          else: Keyword.get(entry.opts, :inference_max_attempts, one_shot_default)
        )

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, {:invalid_inference_attempt_limit, value}}
  end

  defp pricing_ref(opts) do
    case Keyword.get(opts, :inference_pricing_ref) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_inference_pricing_ref, value}}
    end
  end

  defp validate_cost_budget(configured, pricing_ref, prepared, entry) do
    if Map.has_key?(configured, :cost) do
      cond do
        is_nil(pricing_ref) ->
          {:error, :inference_cost_budget_requires_pricing_ref}

        prepared.stream_adapter &&
            not MapSet.member?(prepared.stream_capabilities, :cost_usage) ->
          {:error, :inference_cost_budget_usage_unavailable}

        is_nil(prepared.stream_adapter) &&
            Keyword.get(entry.opts, :inference_cost_usage?, false) != true ->
          {:error, :inference_cost_budget_usage_unavailable}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp validate_rebound_pricing_ref(%Budget{limits: limits}, _entry)
       when not is_map_key(limits, :cost),
       do: :ok

  defp validate_rebound_pricing_ref(%Budget{pricing_ref: expected}, entry) do
    case pricing_ref(entry.opts) do
      {:ok, ^expected} -> :ok
      {:ok, _different} -> {:error, :inference_pricing_ref_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp reservation(prepared, budget) do
    input_tokens = prepared.descriptor.constraints.context_tokens || 0
    output_tokens = prepared.descriptor.constraints.maximum_output_tokens || 0

    # Cost cannot be predicted safely from the core. Reserving the complete
    # remaining allowance keeps an ambiguous attempt fenced until recovery
    # establishes an authoritative settlement.
    cost = Map.get(Budget.remaining(budget), :cost, 0)

    %Usage{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      cost: cost
    }
  end

  defp maybe_put_limit(limits, _field, nil), do: limits
  defp maybe_put_limit(limits, field, value), do: Map.put_new(limits, field, value)

  defp multiply_limit(nil, _multiplier), do: nil
  defp multiply_limit(value, multiplier), do: value * multiplier

  defp sum_limits(left, right) when is_number(left) and is_number(right), do: left + right

  # A missing component means that dimension is unbounded. Treating it as zero
  # would turn an input estimate into a hard total-token ceiling.
  defp sum_limits(_left, _right), do: nil
end
