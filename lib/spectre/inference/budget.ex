defmodule Spectre.Inference.Budget do
  @moduledoc """
  Portable aggregate budget owned by an Instance for one logical inference.

  Reservations happen before dispatch and settlements are keyed by attempt id,
  making duplicate terminal receipts idempotent. Ambiguous attempts retain
  their reservation until a reconciliation result is committed.
  """

  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Usage
  alias Spectre.Run.Value

  @limit_fields [:input_tokens, :output_tokens, :total_tokens, :cost, :attempts, :duration_ms]
  @estimation_policies [:provider, :conservative, :unavailable]

  @enforce_keys [:inference_id]
  defstruct [
    :inference_id,
    :deadline_at,
    :pricing_ref,
    limits: %{},
    consumed: %Usage{},
    reservations: %{},
    settlements: %{},
    estimation_policy: :unavailable
  ]

  @type t :: %__MODULE__{
          inference_id: String.t(),
          deadline_at: integer() | nil,
          pricing_ref: String.t() | nil,
          limits: map(),
          consumed: Usage.t(),
          reservations: %{optional(String.t()) => Usage.t()},
          settlements: %{optional(String.t()) => map()},
          estimation_policy: :provider | :conservative | :unavailable
        }

  @spec new(String.t(), keyword()) :: t()
  def new(inference_id, opts \\ []) when is_binary(inference_id) and is_list(opts) do
    budget = %__MODULE__{
      inference_id: inference_id,
      deadline_at: Keyword.get(opts, :deadline_at),
      pricing_ref: Keyword.get(opts, :pricing_ref),
      limits: Map.new(Keyword.get(opts, :limits, %{})),
      estimation_policy: Keyword.get(opts, :estimation_policy, :unavailable)
    }

    case validate(budget) do
      :ok -> budget
      {:error, reason} -> raise ArgumentError, "invalid inference budget: #{inspect(reason)}"
    end
  end

  @spec reserve(t(), String.t(), Usage.t() | map() | keyword()) ::
          {:ok, t(), BudgetSnapshot.t()} | {:error, term()}
  def reserve(%__MODULE__{} = budget, attempt_id, requested)
      when is_binary(attempt_id) and attempt_id != "" do
    requested = Usage.new(requested)

    case {Map.fetch(budget.reservations, attempt_id),
          Map.has_key?(budget.settlements, attempt_id)} do
      {{:ok, existing}, _settled?} ->
        available =
          remaining(%{budget | reservations: Map.delete(budget.reservations, attempt_id)})

        {:ok, budget, snapshot(budget, attempt_id, existing, available)}

      {:error, true} ->
        {:error, {:inference_attempt_already_settled, attempt_id}}

      {:error, false} ->
        remaining = remaining(budget)

        with :ok <- attempt_available?(remaining),
             :ok <- cost_available?(budget, remaining),
             :ok <- reservation_fits?(requested, remaining) do
          next = %{budget | reservations: Map.put(budget.reservations, attempt_id, requested)}
          {:ok, next, snapshot(next, attempt_id, requested, remaining)}
        else
          {:error, field} -> {:error, {:inference_budget_exhausted, field}}
        end
    end
  end

  @spec settle(t(), String.t(), Usage.t() | map(), :confirmed | :ambiguous) ::
          {:ok, t()} | {:error, term()}
  def settle(%__MODULE__{} = budget, attempt_id, usage, status)
      when status in [:confirmed, :ambiguous] do
    usage = Usage.new(usage)

    case Map.fetch(budget.settlements, attempt_id) do
      {:ok, %{usage: ^usage, status: ^status}} ->
        {:ok, budget}

      {:ok, %{usage: previous, status: :ambiguous}} when status == :confirmed ->
        if Usage.at_least?(usage, previous) do
          settlement = %{usage: usage, status: :confirmed}

          {:ok,
           %{
             budget
             | consumed: Usage.add(budget.consumed, usage),
               reservations: Map.delete(budget.reservations, attempt_id),
               settlements: Map.put(budget.settlements, attempt_id, settlement)
           }}
        else
          {:error, {:inference_budget_settlement_regressed, attempt_id}}
        end

      {:ok, _conflict} ->
        {:error, {:inference_budget_settlement_conflict, attempt_id}}

      :error ->
        settlement = %{usage: usage, status: status}
        settlements = Map.put(budget.settlements, attempt_id, settlement)

        if status == :ambiguous do
          {:ok, %{budget | settlements: settlements}}
        else
          {:ok,
           %{
             budget
             | consumed: Usage.add(budget.consumed, usage),
               reservations: Map.delete(budget.reservations, attempt_id),
               settlements: settlements
           }}
        end
    end
  end

  @spec remaining(t()) :: map()
  def remaining(%__MODULE__{} = budget) do
    reserved =
      budget.reservations
      |> Map.values()
      |> Enum.reduce(%Usage{}, &Usage.add(&2, &1))

    used = Usage.add(budget.consumed, reserved)

    attempts_used =
      budget.reservations
      |> Map.keys()
      |> Kernel.++(Map.keys(budget.settlements))
      |> MapSet.new()
      |> MapSet.size()

    Map.new(budget.limits, fn {field, limit} ->
      value = if field == :attempts, do: attempts_used, else: Map.get(used, field, 0)
      {field, if(is_number(limit), do: max(limit - value, 0), else: nil)}
    end)
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # Budget validation is a closed boundary: every persisted field and
  # cross-field invariant remains visible in one audit point.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = budget) do
    cond do
      not nonempty_binary?(budget.inference_id) ->
        {:error, :invalid_inference_budget_id}

      not is_nil(budget.deadline_at) and
          (not is_integer(budget.deadline_at) or budget.deadline_at < 0) ->
        {:error, :invalid_inference_budget_deadline}

      not is_nil(budget.pricing_ref) and
          (not is_binary(budget.pricing_ref) or budget.pricing_ref == "") ->
        {:error, :invalid_inference_budget_pricing_ref}

      budget.estimation_policy not in @estimation_policies ->
        {:error, :invalid_inference_budget_estimation_policy}

      not valid_limits?(budget.limits) ->
        {:error, :invalid_inference_budget_limits}

      Map.has_key?(budget.limits, :cost) and is_nil(budget.pricing_ref) ->
        {:error, :inference_cost_budget_requires_pricing_ref}

      not valid_reservations?(budget.reservations) or
          not valid_settlements?(budget.settlements) ->
        {:error, :invalid_inference_budget_accounting}

      true ->
        with :ok <- Usage.validate(budget.consumed) do
          Value.validate(budget, [:inference_budget])
        end
    end
  end

  defp snapshot(budget, attempt_id, reserved, available) do
    attempt_limits =
      available
      # Attempt count is enforced atomically by `reserve/3`; it is not a
      # usage counter that a worker can consume during generation.
      |> Map.drop([:attempts])
      |> Map.new(fn {field, remaining} ->
        requested = Map.get(reserved, field, 0)

        limit =
          if is_number(remaining) and is_number(requested) and requested > 0,
            do: min(remaining, requested),
            else: remaining

        {field, limit}
      end)

    BudgetSnapshot.new(
      inference_id: budget.inference_id,
      attempt_id: attempt_id,
      deadline_at: budget.deadline_at,
      # The attempt receives the capacity that existed before its reservation.
      # Returning the post-reservation aggregate would make a fully reserved
      # output budget appear exhausted at the first emitted token.
      remaining: attempt_limits,
      reserved: reserved,
      pricing_ref: budget.pricing_ref,
      estimation_policy: budget.estimation_policy
    )
  end

  defp reservation_fits?(usage, remaining) do
    Enum.find_value(remaining, :ok, fn {field, available} ->
      requested = Map.get(usage, field, 0)

      if is_number(available) and requested > available,
        do: {:error, field},
        else: false
    end)
  end

  defp attempt_available?(%{attempts: remaining}) when is_number(remaining) and remaining < 1,
    do: {:error, :attempts}

  defp attempt_available?(_remaining), do: :ok

  defp cost_available?(%__MODULE__{limits: limits}, remaining) do
    if Map.has_key?(limits, :cost) and Map.get(remaining, :cost, 0) <= 0,
      do: {:error, :cost},
      else: :ok
  end

  defp valid_limits?(limits) when is_map(limits) and not is_struct(limits) do
    Enum.all?(limits, fn
      {:attempts, value} -> is_integer(value) and value >= 0
      {field, value} when field in @limit_fields -> is_number(value) and value >= 0
      _entry -> false
    end)
  end

  defp valid_limits?(_limits), do: false

  defp valid_reservations?(reservations)
       when is_map(reservations) and not is_struct(reservations) do
    Enum.all?(reservations, fn
      {attempt_id, %Usage{} = usage} ->
        nonempty_binary?(attempt_id) and Usage.validate(usage) == :ok

      _entry ->
        false
    end)
  end

  defp valid_reservations?(_reservations), do: false

  defp valid_settlements?(settlements)
       when is_map(settlements) and not is_struct(settlements) do
    Enum.all?(settlements, fn
      {attempt_id, %{usage: %Usage{} = usage, status: status} = settlement} ->
        nonempty_binary?(attempt_id) and status in [:confirmed, :ambiguous] and
          map_size(settlement) == 2 and Usage.validate(usage) == :ok

      _entry ->
        false
    end)
  end

  defp valid_settlements?(_settlements), do: false
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
