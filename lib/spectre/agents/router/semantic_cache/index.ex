defmodule Spectre.Router.SemanticCache.Index do
  @moduledoc false

  alias Spectre.Router.SemanticCache.Example

  # The native index is derived only from approved examples with saved vectors.
  # Rebuild after review changes, not after requests or unverified learning.
  # The owning cache is bounded; neither this table nor its work grows with the
  # Domain's ledger. Vettore monitors its creator and cleans up on owner death.
  def build(config, examples) do
    with {:ok, collection} <-
           Vettore.new(
             dimensions: config.dimensions,
             metric: :cosine,
             score: :raw,
             normalize: :l2,
             compressed: true,
             index: config.index,
             index_options: config.index_options
           ) do
      embeddings =
        for {_id, %Example{verified: true, embedding: vector} = example} <- examples,
            not is_nil(vector),
            do: %Vettore.Embedding{
              id: example.id,
              value: example.id,
              vector: vector,
              metadata: %{label: example.label}
            }

      case Vettore.put_many(collection, embeddings) do
        :ok ->
          {:ok, {collection, length(embeddings)}}

        {:error, _} = error ->
          Vettore.close(collection)
          error
      end
    end
  end

  def search({_collection, 0}, _vector, _query), do: {:ok, []}

  def search({collection, count}, vector, query) do
    # Filter visibility BEFORE top-k and label deduplication. Otherwise a flow
    # with many examples can hide another flow's only eligible nomination.
    with {:ok, results} <- Vettore.search(collection, vector, limit: count) do
      matches =
        results
        |> Enum.filter(&MapSet.member?(query.labels, &1.metadata.label))
        |> Enum.map(
          &%{
            id: &1.id,
            label: &1.metadata.label,
            score: max(0.0, min(1.0, &1.score)),
            method: :semantic
          }
        )
        |> rank(query.limit)

      {:ok, matches}
    end
  end

  def rank(matches, limit) do
    matches
    |> Enum.sort_by(&{-&1.score, &1.label, &1.id})
    |> Enum.uniq_by(& &1.label)
    |> Enum.take(limit)
  end

  def close(nil), do: :ok
  def close({collection, _count}), do: Vettore.close(collection)
end
