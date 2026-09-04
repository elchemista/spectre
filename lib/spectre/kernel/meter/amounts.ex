defmodule Spectre.Kernel.Meter.Amounts do
  @moduledoc """
  Canonical shape for quantities bound to Meter references.

  Constructors may accept a map or a list of reservation descriptors for host
  ergonomics. This module normalizes either form once to
  `%{meter_ref => positive_integer}`. Durable records and governed semantics
  use only that map thereafter, avoiding representation-dependent digests and
  repeated atom/string guessing inside the core.
  """

  @type t :: %{optional(String.t()) => pos_integer()}

  @doc "Normalizes Meter quantities; the empty map is valid."
  @spec normalize(map() | list()) :: {:ok, t()} | {:error, term()}
  def normalize(amounts) when is_map(amounts) and not is_struct(amounts) do
    Enum.reduce_while(amounts, {:ok, %{}}, fn {meter_ref, quantity}, {:ok, normalized} ->
      case valid_pair(meter_ref, quantity) do
        :ok -> {:cont, {:ok, Map.put(normalized, meter_ref, quantity)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def normalize(reservations) when is_list(reservations) do
    Enum.reduce_while(reservations, {:ok, %{}}, fn reservation, {:ok, normalized} ->
      with {:ok, meter_ref, quantity} <- reservation_pair(reservation),
           false <- Map.has_key?(normalized, meter_ref) do
        {:cont, {:ok, Map.put(normalized, meter_ref, quantity)}}
      else
        true -> {:halt, {:error, {:duplicate_meter_reservation, reservation_ref(reservation)}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def normalize(_amounts), do: {:error, :invalid_meter_amounts}

  @doc "Normalizes quantities and rejects an empty result."
  @spec non_empty(map() | list()) :: {:ok, t()} | {:error, term()}
  def non_empty(amounts) do
    with {:ok, normalized} <- normalize(amounts),
         false <- map_size(normalized) == 0 do
      {:ok, normalized}
    else
      true -> {:error, :empty_meter_amounts}
      {:error, _reason} = error -> error
    end
  end

  @doc "Checks that two partial maps are an exact, disjoint partition of a total."
  @spec exact_partition(t(), t(), t()) :: :ok | {:error, :invalid_meter_partition}
  def exact_partition(total, left, right)
      when is_map(total) and is_map(left) and is_map(right) do
    valid? =
      Enum.all?(left, fn {meter_ref, _quantity} ->
        Map.has_key?(total, meter_ref) and not Map.has_key?(right, meter_ref)
      end) and
        Enum.all?(right, fn {meter_ref, _quantity} -> Map.has_key?(total, meter_ref) end) and
        Enum.all?(total, fn {meter_ref, quantity} ->
          Map.get(left, meter_ref, 0) + Map.get(right, meter_ref, 0) == quantity
        end)

    if valid?, do: :ok, else: {:error, :invalid_meter_partition}
  end

  def exact_partition(_total, _left, _right), do: {:error, :invalid_meter_partition}

  defp reservation_pair(%{meter_ref: meter_ref, quantity: quantity}),
    do: checked_pair(meter_ref, quantity)

  defp reservation_pair(%{"meter_ref" => meter_ref, "quantity" => quantity}),
    do: checked_pair(meter_ref, quantity)

  defp reservation_pair({meter_ref, quantity}), do: checked_pair(meter_ref, quantity)
  defp reservation_pair(_reservation), do: {:error, :invalid_meter_reservation}

  defp checked_pair(meter_ref, quantity) do
    with :ok <- valid_pair(meter_ref, quantity), do: {:ok, meter_ref, quantity}
  end

  defp valid_pair(meter_ref, quantity)
       when is_binary(meter_ref) and meter_ref != "" and is_integer(quantity) and quantity > 0,
       do: :ok

  defp valid_pair(meter_ref, _quantity), do: {:error, {:invalid_meter_amount, meter_ref}}

  defp reservation_ref(%{meter_ref: meter_ref}), do: meter_ref
  defp reservation_ref(%{"meter_ref" => meter_ref}), do: meter_ref
  defp reservation_ref({meter_ref, _quantity}), do: meter_ref
  defp reservation_ref(_reservation), do: nil
end
