defmodule Spectre.Router.SemanticCache.Configuration do
  @moduledoc false

  alias Spectre.Portable

  @binding [:namespace, :definition_ref, :profile_ref, :dimensions]
  @options @binding ++ [:name, :labels, :max_entries, :max_text_bytes, :index, :index_options]

  def new(opts) do
    with {:ok, attrs} <- Portable.normalize_attrs(opts, @options, :semantic_cache),
         true <- Enum.all?([:namespace, :definition_ref, :profile_ref], &reference?(attrs[&1])),
         dimensions = attrs[:dimensions],
         true <- is_integer(dimensions) and dimensions in 1..8192,
         labels = attrs[:labels],
         true <-
           is_list(labels) and length(labels) in 1..1024 and Enum.all?(labels, &reference?/1),
         true <- length(Enum.uniq(labels)) == length(labels),
         max_entries = Map.get(attrs, :max_entries, 1000),
         true <- is_integer(max_entries) and max_entries in 1..100_000,
         max_text_bytes = Map.get(attrs, :max_text_bytes, 8192),
         true <- is_integer(max_text_bytes) and max_text_bytes in 1..65_536,
         index = Map.get(attrs, :index, :flat),
         true <- index in [:flat, :hnsw],
         index_options = Map.get(attrs, :index_options, []),
         true <- Portable.keyword?(index_options) do
      {:ok,
       %{
         binding: Map.take(attrs, @binding),
         dimensions: dimensions,
         labels: MapSet.new(labels),
         max_entries: max_entries,
         max_text_bytes: max_text_bytes,
         index: index,
         index_options: index_options,
         name: Map.get(attrs, :name)
       }}
    else
      false -> {:error, :invalid_semantic_cache_configuration}
      {:error, _} = error -> error
    end
  end

  def query(opts, config) do
    with true <- Portable.keyword?(opts),
         {:ok, attrs} <-
           Portable.normalize_attrs(
             opts,
             [:labels, :limit, :binding, :embedding, :embed],
             :semantic_cache_query
           ),
         true <- Map.get(attrs, :binding, config.binding) === config.binding,
         labels = Map.get(attrs, :labels, MapSet.to_list(config.labels)),
         true <- is_list(labels) and Enum.all?(labels, &MapSet.member?(config.labels, &1)),
         limit = Map.get(attrs, :limit, 32),
         true <- is_integer(limit) and limit in 1..32 do
      {:ok, %{labels: MapSet.new(labels), limit: limit}}
    else
      false -> {:error, :invalid_cache_query_or_binding}
      {:error, _} = error -> error
    end
  end

  def page(opts) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(opts, [:limit, :after, :source, :verified], :cache_examples),
         limit = Map.get(attrs, :limit, 100),
         true <- is_integer(limit) and limit in 1..500,
         after_id = Map.get(attrs, :after),
         true <- is_nil(after_id) or reference?(after_id),
         source = Map.get(attrs, :source),
         true <- source in [nil, "online_learned", "offline_dataset", "static_route_example"],
         verified = Map.get(attrs, :verified),
         true <- verified in [nil, true, false] do
      {:ok, %{limit: limit, after: after_id, source: source, verified: verified}}
    else
      _invalid -> {:error, :invalid_cache_page}
    end
  end

  defp reference?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
