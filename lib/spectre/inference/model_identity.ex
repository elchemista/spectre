defmodule Spectre.Inference.ModelIdentity do
  @moduledoc false

  alias Spectre.SensitiveData

  @spec sanitize(term()) :: term()
  def sanitize(value), do: sanitize_value(value)

  defp sanitize_value(%URI{} = value) do
    fields = value |> Map.from_struct() |> Map.delete(:userinfo) |> sanitize_map()
    {:struct, URI, fields}
  end

  defp sanitize_value(%{__struct__: module} = value) do
    {:struct, module, value |> Map.from_struct() |> sanitize_map()}
  end

  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.reduce([], fn
      {key, item}, acc when is_atom(key) or is_binary(key) ->
        if SensitiveData.sensitive_key?(key) do
          acc
        else
          [{key, sanitize_value(item)} | acc]
        end

      item, acc ->
        [sanitize_value(item) | acc]
    end)
    |> Enum.reverse()
  end

  defp sanitize_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_value/1)
    |> List.to_tuple()
  end

  defp sanitize_value(value), do: value

  defp sanitize_map(value) do
    Enum.reduce(value, %{}, fn {key, item}, sanitized ->
      if SensitiveData.sensitive_key?(key) do
        sanitized
      else
        Map.put(sanitized, key, sanitize_value(item))
      end
    end)
  end
end
