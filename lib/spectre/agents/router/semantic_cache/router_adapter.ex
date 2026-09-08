defmodule Spectre.Router.SemanticCache.RouterAdapter do
  @moduledoc """
  Connects a semantic cache to the existing, extensible 0.4 router.

      adapters = [semantic_cache: {__MODULE__,
        [cache: bound_cache]}]

      Spectre.Router.new(rules, via: [:regex, :semantic_cache], adapters: adapters)

  Declare `semantic_cache: true` in a rule's `match` map to opt in; false or
  omission excludes it. Example labels name rule references, not arbitrary
  actions. A cache hit can nominate only rules visible in the current flow.
  The router applies its usual accept/margin/ambiguity rules afterward.

  An input may be plain text or
  `%{"text" => text, "embedding" => vector, "profile_ref" => encoder_ref}`
  when the host already obtained an embedding through governed execution.
  Supplying a precomputed vector avoids any callback during routing.
  Selection provenance includes the example ID, never its full text/vector.
  """

  use Spectre.Router.Adapter

  alias Spectre.Router.SemanticCache

  @impl Spectre.Router.Adapter
  def prepare(enabled, opts) when is_boolean(enabled) do
    with {:ok, attrs} <- Spectre.Portable.normalize_attrs(opts, [:cache], :semantic_cache_router),
         {:ok, cache} <- Map.fetch(attrs, :cache),
         :ok <- SemanticCache.capabilities(cache, :lookup) do
      {:ok, enabled}
    else
      :error -> {:error, :semantic_cache_binding_required}
      {:error, _} = error -> error
    end
  end

  def prepare(_data, _opts), do: {:error, :invalid_semantic_cache_rule}

  @impl Spectre.Router.Adapter
  def evaluate(request, opts) do
    labels = for rule <- request.rules, rule.data === true, do: rule.ref

    with {:ok, query} <- input(request.input),
         query = Map.merge(query, %{labels: labels, limit: 32}),
         {:ok, matches} <- SemanticCache.lookup(Keyword.fetch!(opts, :cache), query) do
      {:ok,
       Enum.map(
         matches,
         &result(&1.label, &1.score, %{
           "example_ref" => &1.example_ref,
           "example_revision" => &1.example_revision,
           "content_ref" => &1.content_ref
         })
       )}
    else
      :miss -> {:ok, []}
      {:error, :embedding_required} -> :skip
      {:error, _} = error -> error
    end
  end

  defp input(text) when is_binary(text), do: {:ok, %{text: text, vector: nil}}

  defp input(%{"text" => text} = input) when is_binary(text),
    do:
      {:ok,
       %{
         text: text,
         vector: Map.get(input, "embedding"),
         profile_ref: Map.get(input, "profile_ref")
       }}

  defp input(_value), do: {:error, :invalid_semantic_cache_input}
end
