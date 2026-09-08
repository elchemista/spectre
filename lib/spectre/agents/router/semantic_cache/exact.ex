defmodule Spectre.Router.SemanticCache.Exact do
  @moduledoc """
  Bounded, reviewable exact-text cache without a vector or model dependency.

  Text is trimmed and case-folded for lookup. Only approved examples nominate
  routes. `Spectre.Router.SemanticCache.bind/2` provides the public handle;
  supervise this backend separately, with explicit namespace, Definition, flow
  and allowed labels. Storage and review reuse the shared cache engine.
  """

  use Spectre.Router.SemanticCache.Memory

  @doc "Starts an exact cache; a search implementation belongs in a different backend."
  def start_link(opts) do
    with true <- Spectre.Portable.keyword?(opts),
         false <- Keyword.has_key?(opts, :search) do
      super(opts)
    else
      _invalid -> {:error, :invalid_exact_cache_options}
    end
  end
end
