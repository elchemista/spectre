defmodule Spectre.SemanticCache.Vettore.Index do
  @moduledoc false

  @behaviour Spectre.Router.SemanticCache.Index

  alias Spectre.Router.SemanticCache.Example

  # The native index is derived only from approved examples with saved vectors.
  # Rebuild after review changes, not after requests or unverified learning.
  # The owning cache is bounded; neither this table nor its work grows with the
  # Domain's ledger. Vettore monitors its creator and cleans up on owner death.
  @impl true
  def build(examples, opts) do
    with :ok <- validate_examples(examples),
         {:ok, collection} <- Vettore.new(opts) do
      embeddings =
        for {_id, %Example{verified: true, embedding: vector} = example} <- examples,
            not is_nil(vector),
            do: %Vettore.Embedding{
              id: example.id,
              value: example.id,
              vector: vector,
              metadata: %{label: example.label}
            }

      case Spectre.Adapter.invoke(Vettore, :put_many, [collection, embeddings]) do
        {:ok, :ok} ->
          {:ok, {collection, length(embeddings)}}

        reply ->
          Vettore.close(collection)

          case reply do
            {:ok, {:error, _} = error} -> error
            {:error, _} = error -> error
            _invalid -> {:error, :invalid_vettore_index_reply}
          end
      end
    end
  end

  @impl true
  def search({_collection, 0}, _vector, _query), do: {:ok, []}

  def search({collection, count}, vector, query) do
    # Filter visibility BEFORE top-k and label deduplication. Otherwise a flow
    # with many examples can hide another flow's only eligible nomination.
    with :ok <- validate_vector(vector),
         {:ok, results} <- Vettore.search(collection, vector, limit: count) do
      matches =
        results
        |> Enum.filter(&MapSet.member?(query.labels, &1.metadata.label))
        |> Enum.map(
          &%{
            example_ref: &1.id,
            label: &1.metadata.label,
            score: max(0.0, min(1.0, &1.score))
          }
        )
        |> Spectre.Router.SemanticCache.Index.rank(query.limit)

      {:ok, matches}
    end
  end

  @impl true
  def close(nil), do: :ok
  def close({collection, _count}), do: Vettore.close(collection)

  defp validate_examples(examples) do
    Enum.reduce_while(examples, :ok, fn
      {_id, %Example{verified: true, embedding: vector}}, :ok when not is_nil(vector) ->
        case validate_vector(vector) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _example, :ok ->
        {:cont, :ok}
    end)
  end

  # f32 and nonzero are properties of this native index, not of the cache protocol.
  defp validate_vector(vector) do
    if Enum.all?(vector, &(abs(&1) <= 3.402_823_466_385_288_6e38)) and
         Enum.any?(vector, &(&1 != 0)), do: :ok, else: {:error, :invalid_vettore_embedding}
  end
end
