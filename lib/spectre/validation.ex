defmodule Spectre.Validation do
  @moduledoc false

  @doc "Checks items in enumeration order, stopping at the first error."
  @spec all(Enumerable.t(), (term() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def all(items, validate) when is_function(validate, 1) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate.(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
