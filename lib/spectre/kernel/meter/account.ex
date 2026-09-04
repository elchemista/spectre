defmodule Spectre.Kernel.Meter.Account do
  @moduledoc """
  Disposable balance for one Meter allocation.

  The surrounding governed state identifies the physical owner. The account
  keeps only the Meter identity and its conserved quantities, so restriction
  successors can share the same allocation without duplicating ownership
  metadata in every balance.

  Meter units, precision and rate windows remain host-defined extensions until
  the governed model specifies their durable representation. The core uses
  non-negative integers and never guesses those semantics.
  """

  @buckets [:available, :reserved, :suspended, :spent, :delegated]

  @enforce_keys [:meter_ref, :ceiling, :available]
  defstruct meter_ref: nil,
            ceiling: 0,
            available: 0,
            reserved: 0,
            suspended: 0,
            spent: 0,
            delegated: 0

  @type t :: %__MODULE__{
          meter_ref: String.t(),
          ceiling: non_neg_integer(),
          available: non_neg_integer(),
          reserved: non_neg_integer(),
          suspended: non_neg_integer(),
          spent: non_neg_integer(),
          delegated: non_neg_integer()
        }

  @doc "Creates the initial balance issued by a root Mandate."
  @spec root(String.t(), non_neg_integer()) :: t()
  def root(meter_ref, ceiling)
      when is_binary(meter_ref) and meter_ref != "" and is_integer(ceiling) and ceiling >= 0 do
    %__MODULE__{meter_ref: meter_ref, ceiling: ceiling, available: ceiling}
  end

  @doc "Creates an empty child balance before subtractive delegation."
  @spec child(String.t()) :: t()
  def child(meter_ref) when is_binary(meter_ref) and meter_ref != "" do
    %__MODULE__{meter_ref: meter_ref, ceiling: 0, available: 0}
  end

  @doc "Validates identity, integer quantities and the conservation equation."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = account) do
    invalid_quantity =
      Enum.find([:ceiling | @buckets], fn field ->
        value = Map.fetch!(account, field)
        not (is_integer(value) and value >= 0)
      end)

    cond do
      not (is_binary(account.meter_ref) and account.meter_ref != "") ->
        {:error, :invalid_meter_ref}

      invalid_quantity ->
        {:error, {:invalid_meter_quantity, invalid_quantity}}

      not conserved?(account) ->
        {:error,
         {:meter_conservation_violation,
          %{ceiling: account.ceiling, buckets: Map.take(account, @buckets)}}}

      true ->
        :ok
    end
  end

  def validate(_account), do: {:error, :invalid_meter_account}

  defp conserved?(account) do
    account.available + account.reserved + account.suspended + account.spent +
      account.delegated == account.ceiling
  end
end
