defmodule Spectre.Execution.PortableDigest do
  @moduledoc false

  alias Spectre.Canonical.Value
  alias Spectre.Run.Value, as: RunValue

  @doc false
  @spec digest(term(), [term()]) :: {:ok, String.t()} | {:error, term()}
  def digest(value, path \\ []) when is_list(path) do
    with :ok <- RunValue.validate(value, path) do
      case Value.digest(value) do
        {:ok, digest} -> {:ok, digest}
        {:error, _reason} -> encoded_digest(value)
      end
    end
  end

  @spec encoded_digest(term()) :: {:ok, String.t()} | {:error, term()}
  defp encoded_digest(value) do
    with {:ok, encoded} <- RunValue.encode(value) do
      encoded
      |> canonical_run_value()
      |> Value.digest()
    end
  end

  @spec canonical_run_value(term()) :: term()
  defp canonical_run_value(%{"$spectre" => "map", "entries" => entries} = value)
       when is_list(entries) do
    entries =
      entries
      |> Enum.map(fn [key, item] ->
        [canonical_run_value(key), canonical_run_value(item)]
      end)
      |> Enum.sort_by(fn [key, _item] -> Value.encode!(key) end)

    Map.put(value, "entries", entries)
  end

  defp canonical_run_value(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {canonical_run_value(key), canonical_run_value(item)}
    end)
  end

  defp canonical_run_value(value) when is_list(value),
    do: Enum.map(value, &canonical_run_value/1)

  defp canonical_run_value(value), do: value
end
