defmodule Spectre.Router.SemanticCache.Index do
  @moduledoc """
  Optional derived search index for the shared in-memory cache engine.

  Implementations receive approved examples and already prepared vectors. They
  never generate embeddings. Native resources stay owned by the cache process;
  invalidation closes them before another index is built. No index is needed
  for the Exact adapter.
  """

  alias Spectre.Adapter

  @callback build([{String.t(), Spectre.Router.SemanticCache.Example.t()}], keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback search(term(), [float()], map()) :: {:ok, [map()]} | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}

  @doc false
  def build({module, opts}, examples) do
    case Adapter.invoke(module, :build, [examples, opts]) do
      {:ok, {:ok, index}} -> {:ok, {module, index}}
      {:ok, {:error, _} = error} -> error
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_cache_index_reply}
    end
  end

  @doc false
  def search({module, index}, vector, query) do
    case Adapter.invoke(module, :search, [index, vector, query]) do
      {:ok, {:ok, hits}} when is_list(hits) -> {:ok, hits}
      {:ok, {:error, _} = error} -> error
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_cache_index_reply}
    end
  end

  @doc false
  def close(nil), do: :ok

  def close({module, index}) do
    Adapter.invoke(module, :close, [index])
    :ok
  end

  @doc false
  def rank(matches, limit) do
    matches
    |> Enum.sort_by(&{-&1.score, &1.label, &1.example_ref})
    |> Enum.uniq_by(& &1.label)
    |> Enum.take(limit)
  end
end
