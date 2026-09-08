defmodule Spectre.Router.SemanticCache.Configuration do
  @moduledoc false
  import Kernel, except: [binding: 1]

  alias Spectre.{Adapter, Portable}
  alias Spectre.Router.SemanticCache.Example

  @binding [:namespace, :definition_ref, :flow, :profile_ref]
  @options @binding ++ [:name, :labels, :dimensions, :max_entries, :max_text_bytes, :search]

  @doc "Normalizes the identity shared by a cache handle and every backend operation."
  def binding(value) do
    with {:ok, attrs} <- Portable.normalize_attrs(value, @binding, :cache_binding),
         true <- Enum.all?([:namespace, :definition_ref, :flow], &reference?(attrs[&1])),
         profile = Map.get(attrs, :profile_ref),
         true <- is_nil(profile) or reference?(profile) do
      {:ok, Map.put_new(attrs, :profile_ref, nil)}
    else
      _invalid -> {:error, :invalid_cache_binding}
    end
  end

  @doc "Checks storage limits without selecting or loading an embedding model."
  def new(opts) do
    with {:ok, attrs} <- Portable.normalize_attrs(opts, @options, :semantic_cache),
         {:ok, binding} <- binding(Map.take(attrs, @binding)),
         {:ok, labels} <- labels(Map.get(attrs, :labels)),
         dimensions = Map.get(attrs, :dimensions),
         true <- is_nil(dimensions) or (is_integer(dimensions) and dimensions in 1..8192),
         max_entries = Map.get(attrs, :max_entries, 1000),
         max_text_bytes = Map.get(attrs, :max_text_bytes, 8192),
         true <- is_integer(max_entries) and max_entries in 1..100_000,
         true <- is_integer(max_text_bytes) and max_text_bytes in 1..65_536,
         :ok <- search(Map.get(attrs, :search), dimensions, binding.profile_ref) do
      {:ok,
       %{
         binding: binding,
         labels: MapSet.new(labels),
         dimensions: dimensions,
         name: Map.get(attrs, :name),
         max_entries: max_entries,
         max_text_bytes: max_text_bytes,
         search: Map.get(attrs, :search)
       }}
    else
      false -> {:error, :invalid_semantic_cache_configuration}
      {:error, _} = error -> error
    end
  end

  @doc "Validates a bounded query; embedding callbacks are never accepted."
  def query(value) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             value,
             [:text, :vector, :profile_ref, :labels, :limit],
             :cache_query
           ),
         {:ok, text} <- Example.text(Map.get(attrs, :text), 65_536),
         {:ok, labels} <- labels(Map.get(attrs, :labels)),
         limit = Map.get(attrs, :limit, 5),
         true <- is_integer(limit) and limit in 1..32,
         {:ok, vector} <- Example.embedding(Map.get(attrs, :vector), nil) do
      {:ok,
       %{
         text: text,
         vector: vector,
         profile_ref: Map.get(attrs, :profile_ref),
         labels: labels,
         limit: limit
       }}
    else
      false -> {:error, :invalid_cache_query}
      {:error, _} = error -> error
    end
  end

  def query(value, config) do
    with {:ok, query} <- query(value),
         true <- byte_size(query.text) <= config.max_text_bytes,
         true <- Enum.all?(query.labels, &MapSet.member?(config.labels, &1)),
         :ok <- Example.profile(query.vector, query.profile_ref, config.binding.profile_ref),
         {:ok, vector} <- Example.embedding(query.vector, config.dimensions) do
      {:ok, %{query | labels: MapSet.new(query.labels), vector: vector}}
    else
      false -> {:error, :cache_query_outside_binding}
      {:error, _} = error -> error
    end
  end

  def page(opts) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(opts, [:limit, :after, :verified], :cache_examples),
         limit = Map.get(attrs, :limit, 100),
         true <- is_integer(limit) and limit in 1..500,
         after_id = Map.get(attrs, :after),
         true <- is_nil(after_id) or reference?(after_id),
         verified = Map.get(attrs, :verified),
         true <- verified in [nil, true, false] do
      {:ok, %{limit: limit, after: after_id, verified: verified}}
    else
      _invalid -> {:error, :invalid_cache_page}
    end
  end

  defp labels(values) when is_list(values) and length(values) <= 1024 do
    if Enum.all?(values, &reference?/1) and length(Enum.uniq(values)) == length(values),
      do: {:ok, values},
      else: {:error, :invalid_cache_labels}
  end

  defp labels(_values), do: {:error, :invalid_cache_labels}

  defp search(nil, _dimensions, _profile), do: :ok

  defp search({module, opts}, dimensions, profile)
       when is_integer(dimensions) and is_binary(profile) do
    if Portable.keyword?(opts),
      do: Adapter.validate(module, build: 2, search: 3, close: 1),
      else: {:error, :invalid_cache_search_options}
  end

  defp search(_search, _dimensions, _profile), do: {:error, :invalid_cache_search_binding}

  defp reference?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
