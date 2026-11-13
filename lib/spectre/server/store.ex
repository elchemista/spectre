defmodule Spectre.Server.Store do
  @moduledoc """
  Durable coordination storage with compare-and-swap revision fencing.

  A successful mutation acknowledges a durable, atomic acquisition of the
  entire value. Implementations must reject nonportable values and distinguish
  an absent key from an unavailable or corrupt store. A checkpoint adapter can
  acquire its inbox, state and command outbox as one value.
  """

  @type entry :: %{revision: pos_integer(), value: term()}
  @callback fetch(term(), term()) :: {:ok, entry()} | :not_found | {:error, term()}
  @callback put_new(term(), term(), term()) :: {:ok, pos_integer()} | {:error, term()}
  @callback compare_and_swap(term(), term(), pos_integer(), term()) ::
              {:ok, pos_integer()} | {:error, term()}
  @callback delete(term(), term(), pos_integer()) :: :ok | {:error, term()}
end
