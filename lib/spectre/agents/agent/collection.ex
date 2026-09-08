defmodule Spectre.Agent.Collection do
  @moduledoc """
  Error-aware collection construction shared by authoring and its adapters.

  Each item returns {:ok, value} or {:error, reason}. map/2 preserves enumeration
  order and stops at the first error, without returning a partial collection.
  It has no process, retry, concurrency or coercion policy; the caller owns
  input limits and element validation. GAM state transitions do not use it.
  """

  @doc "Maps items once in order, stopping before later callbacks on failure."
  @spec map(Enumerable.t(), (term() -> {:ok, value} | {:error, reason})) ::
          {:ok, [value]} | {:error, reason}
        when value: term(), reason: term()
  def map(items, transform) when is_function(transform, 1) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, values} ->
      case transform.(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
