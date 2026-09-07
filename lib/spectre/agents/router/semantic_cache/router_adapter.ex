defmodule Spectre.Router.SemanticCache.RouterAdapter do
  @moduledoc """
  Connects a semantic cache to the existing, extensible 0.4 router.

      adapters = [semantic_cache: {__MODULE__,
        [cache: MyApp.SupportCache, binding: cache_binding, embed: {MyApp.Embedder, []}]}]

      Spectre.Router.new(rules, via: [:regex, :semantic_cache], adapters: adapters)

  Declare `semantic_cache: true` in a rule's `match` map to opt in; false or
  omission excludes it. Example labels name rule references, not arbitrary
  actions. A cache hit can nominate only rules visible in the current flow.
  The router applies its usual accept/margin/ambiguity rules afterward.

  An input may be plain text or `%{"text" => text, "embedding" => vector}`
  when the host already obtained an embedding through governed execution.
  Supplying a precomputed vector avoids any callback during routing.
  Selection provenance includes the example ID, never its full text/vector.
  """

  use Spectre.Router.Adapter

  alias Spectre.Router.SemanticCache

  @impl Spectre.Router.Adapter
  def prepare(enabled, opts) when is_boolean(enabled) do
    if Keyword.has_key?(opts, :cache) and is_map(Keyword.get(opts, :binding)),
      do: {:ok, enabled},
      else: {:error, :semantic_cache_binding_required}
  end

  def prepare(_data, _opts), do: {:error, :invalid_semantic_cache_rule}

  @impl Spectre.Router.Adapter
  def evaluate(request, opts) do
    labels = for rule <- request.rules, rule.data === true, do: rule.ref

    with {:ok, text, query} <- input(request.input),
         query = Keyword.merge(Keyword.take(opts, [:embed, :binding]), query),
         query = Keyword.put(query, :labels, labels),
         {:ok, matches} <- SemanticCache.lookup(Keyword.fetch!(opts, :cache), text, query) do
      {:ok,
       Enum.map(
         matches,
         &result(&1.label, &1.score, %{
           "example_id" => &1.id,
           "method" => Atom.to_string(&1.method)
         })
       )}
    end
  end

  defp input(text) when is_binary(text), do: {:ok, text, []}

  defp input(%{"text" => text, "embedding" => vector}) when is_binary(text),
    do: {:ok, text, [embedding: vector]}

  defp input(_value), do: {:error, :invalid_semantic_cache_input}
end
