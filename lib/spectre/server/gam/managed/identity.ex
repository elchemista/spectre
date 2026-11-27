defmodule Spectre.Server.GAM.Managed.Identity do
  @moduledoc false

  alias ExGAM.Canonical.Value

  @fields [:subject, :conversation, :task, :tenant, :org, :organization]
  @keys Enum.map(@fields, &{Atom.to_string(&1), &1})
  @accepted @fields ++ Enum.map(@fields, &Atom.to_string/1)

  @doc false
  @spec normalize(term()) :: {:ok, map()} | {:error, :invalid_managed_identity}
  def normalize(identity) when is_map(identity) and not is_struct(identity) do
    with :ok <- Value.validate(identity),
         true <- Map.keys(identity) -- @accepted == [] do
      Enum.reduce_while(@keys, {:ok, identity}, &normalize_field/2)
    else
      _ -> {:error, :invalid_managed_identity}
    end
  end

  def normalize(_), do: {:error, :invalid_managed_identity}

  defp normalize_field({string, atom}, {:ok, acc}) do
    case {Map.fetch(acc, string), Map.fetch(acc, atom)} do
      {{:ok, value}, {:ok, other}} when value != other ->
        {:halt, {:error, :invalid_managed_identity}}

      {{:ok, value}, _} ->
        {:cont, {:ok, acc |> Map.delete(string) |> Map.put(atom, value)}}

      {:error, _} ->
        {:cont, {:ok, acc}}
    end
  end
end
