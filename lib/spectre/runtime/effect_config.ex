defmodule Spectre.EffectConfig do
  @moduledoc """
  Resolves extension-contributed executors for non-action effect kinds.
  """

  alias Spectre.Effect.Executor.Mount
  alias Spectre.Extension

  @doc "Returns every non-action executor visible to an Agent."
  @spec executors(module()) :: [Mount.t()]
  def executors(agent) when is_atom(agent) and not is_nil(agent) do
    agent
    |> Spectre.Definition.fetch!()
    |> Map.fetch!(:extensions)
    |> Enum.flat_map(&Extension.effect_executors/1)
    |> unique_executors!()
  end

  @doc "Resolves the executor registered for `kind`."
  @spec executor(module(), atom()) :: {:ok, Mount.t()} | {:error, term()}
  def executor(agent, kind) when is_atom(kind) and not is_nil(kind) do
    case Enum.find(executors(agent), &(&1.kind == kind)) do
      %Mount{} = mount -> {:ok, mount}
      nil -> {:error, {:unsupported_effect_kind, kind}}
    end
  end

  @spec unique_executors!([Mount.t()]) :: [Mount.t()]
  defp unique_executors!(executors) do
    case duplicate_kind(executors) do
      nil -> executors
      kind -> raise ArgumentError, "duplicate effect executor: #{inspect(kind)}"
    end
  end

  @spec duplicate_kind([Mount.t()]) :: atom() | nil
  defp duplicate_kind(executors) do
    executors
    |> Enum.reduce_while(MapSet.new(), fn %Mount{kind: kind}, seen ->
      if MapSet.member?(seen, kind),
        do: {:halt, kind},
        else: {:cont, MapSet.put(seen, kind)}
    end)
    |> case do
      %MapSet{} -> nil
      kind -> kind
    end
  end
end
