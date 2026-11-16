defmodule Spectre.ValueShape do
  @moduledoc false

  # Error vocabularies differ between public boundaries. Only expose the
  # primitive shapes that each caller already reported.
  @spec of(term(), [atom()]) :: atom()
  def of(value, supported) do
    shape = classify(value)
    if shape in supported, do: shape, else: :other
  end

  defp classify(value) when is_map(value), do: :map
  defp classify(value) when is_list(value), do: :list
  defp classify(value) when is_tuple(value), do: :tuple
  defp classify(value) when is_binary(value), do: :binary
  defp classify(value) when is_integer(value), do: :integer
  defp classify(value) when is_atom(value), do: :atom
  defp classify(value) when is_pid(value), do: :pid
  defp classify(value) when is_port(value), do: :port
  defp classify(value) when is_reference(value), do: :reference
  defp classify(value) when is_function(value), do: :function
  defp classify(_value), do: :other
end
