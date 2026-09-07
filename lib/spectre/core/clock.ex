defmodule Spectre.Clock do
  @moduledoc """
  Trusted time source used at the governed boundary.

  Time is sampled by the Domain sequencer and then persisted as decision input;
  pure kernel functions never read the system clock themselves.
  """

  alias Spectre.Adapter

  @callback now() :: non_neg_integer()

  @doc false
  @spec read(module()) :: {:ok, non_neg_integer()} | {:error, term()}
  def read(source) when is_atom(source) and source not in [nil, true, false] do
    case Adapter.invoke(source, :now, []) do
      {:ok, now} when is_integer(now) and now >= 0 -> {:ok, now}
      {:ok, _invalid} -> {:error, :invalid_clock_value}
      {:error, _reason} = error -> error
    end
  end

  def read(_source), do: {:error, :invalid_clock_source}
end
