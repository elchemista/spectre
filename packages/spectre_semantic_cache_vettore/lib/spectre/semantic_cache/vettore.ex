defmodule Spectre.SemanticCache.Vettore do
  @moduledoc """
  Optional vector backend for Spectre's ordinary semantic-cache Router method.

  Exact lookup, quarantine, revision checks, pagination and snapshots use the
  same engine as `Spectre.Router.SemanticCache.Exact`. Only the derived search
  index is native. Supply saved vectors and an explicit encoder `profile_ref`;
  this backend never embeds text, downloads models or calls a provider.

  Add `:spectre_semantic_cache_vettore` to the host's dependencies and supervise
  this child there. Index configuration selects `:flat` (default) or `:hnsw`.
  Vectors in snapshots remain host-owned data with their own retention policy.
  """

  use Spectre.Router.SemanticCache.Memory

  alias Spectre.Portable
  alias Spectre.SemanticCache.Vettore.Index

  @doc "Selects a local native index without changing the cache's binding or review rules."
  def start_link(opts) do
    with true <- Portable.keyword?(opts) and not Keyword.has_key?(opts, :search),
         index = Keyword.get(opts, :index, :flat),
         true <- index in [:flat, :hnsw],
         index_options = Keyword.get(opts, :index_options, []),
         true <- Portable.keyword?(index_options) do
      native = [
        dimensions: Keyword.get(opts, :dimensions),
        metric: :cosine,
        normalize: :l2,
        score: :raw,
        compressed: true,
        index: index,
        index_options: index_options
      ]

      opts
      |> Keyword.drop([:index, :index_options])
      |> Keyword.put(:search, {Index, native})
      |> super()
    else
      _invalid -> {:error, :invalid_vettore_cache_options}
    end
  end
end
