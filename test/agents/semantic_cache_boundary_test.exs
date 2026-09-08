defmodule Spectre.Agents.SemanticCacheBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Portable
  alias Spectre.Router.Adapter.Request
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.{Configuration, Example, Index, Memory, RouterAdapter}

  defmodule ReusableBackend do
    use Spectre.Router.SemanticCache.Memory
  end

  defmodule UntrustedBackend do
    def info(opts), do: Keyword.get(opts, :info, {:ok, %{binding: opts[:binding]}})
    def lookup(_, _, opts), do: Keyword.fetch!(opts, :reply)
    def examples(_, _, opts), do: Keyword.fetch!(opts, :reply)
    def put(_, _, opts), do: Keyword.fetch!(opts, :reply)
    def verify(_, _, _, opts), do: Keyword.fetch!(opts, :reply)
  end

  defmodule ConfigurableIndex do
    def build(_examples, opts), do: Keyword.fetch!(opts, :reply)
    def search(_index, _vector, query), do: Map.fetch!(query, :reply)
    def close(_index), do: :ok
  end

  defmodule RaisingIndex do
    def build(_examples, _opts), do: raise("private backend failure")
    def search(_index, _vector, _query), do: raise("private backend failure")
    def close(_index), do: :ok
  end

  setup do
    binding = %{namespace: "support", definition_ref: "definition:orders", flow: "orders", profile_ref: nil}
    opts = Map.to_list(binding) ++ [labels: ["orders/lookup"], max_entries: 10]
    server = start_supervised!({ReusableBackend, opts})
    {:ok, cache} = SemanticCache.bind({ReusableBackend, server: %{binding => server}}, binding)
    %{binding: binding, opts: opts, server: server, cache: cache}
  end

  test "a reusable backend resolves only explicitly wired partitions and reports missing capabilities", c do
    assert {:ok, %{count: 0}} = SemanticCache.info(c.cache)
    assert :ok = SemanticCache.capabilities(c.cache, :studio)
    assert {:error, :unknown_cache_capability} = SemanticCache.capabilities(c.cache, :invented)
    assert {:error, :invalid_cache_handle} = SemanticCache.capabilities(nil, :lookup)
    assert {:error, :cache_partition_not_wired} = SemanticCache.bind({ReusableBackend, server: %{}}, c.binding)
    assert {:error, :cache_server_required} = SemanticCache.bind({ReusableBackend, []}, c.binding)
    assert {:error, :invalid_cache_adapter} = SemanticCache.bind(nil, c.binding)
    assert {:error, :invalid_cache_info} = SemanticCache.bind({UntrustedBackend, info: {:ok, %{}}}, c.binding)
    assert {:error, :invalid_cache_handle} = SemanticCache.info(nil)
    assert {:error, :invalid_cache_handle} = SemanticCache.lookup(nil, %{})
    assert {:error, :invalid_cache_handle} = SemanticCache.snapshot(nil)
    {:ok, minimal} = SemanticCache.bind({UntrustedBackend, reply: :miss}, c.binding)
    assert {:error, _} = SemanticCache.capabilities(minimal, :snapshot)
  end

  test "removing one normalized-text alias does not remove another approved example", c do
    {:ok, first} = SemanticCache.put(c.cache, %{id: "first", text: " Where is my order? ", label: "orders/lookup"})
    {:ok, second} = SemanticCache.put(c.cache, %{id: "second", text: "where is my order?", label: "orders/lookup"})
    {:ok, first} = SemanticCache.verify(c.cache, first.id, first.revision)
    {:ok, second} = SemanticCache.verify(c.cache, second.id, second.revision)
    assert :ok = SemanticCache.delete(c.cache, first.id, first.revision)
    assert {:ok, [hit]} = SemanticCache.lookup(c.cache, query())
    assert hit.example_ref == second.id
    assert {:error, :cache_example_exists} = SemanticCache.put(c.cache, %{id: second.id, text: "changed", label: second.label})
    assert {:error, _} = SemanticCache.update(c.cache, second.id, %{verified: true}, second.revision)
    assert {:error, :cache_example_not_found} = SemanticCache.update(c.cache, "missing", %{text: "new"}, 1)
    assert {:error, :invalid_cache_revision} = SemanticCache.verify(c.cache, second.id, 1.0)
    assert {:error, _} = SemanticCache.verify(c.cache, "", 1)
    assert {:error, :invalid_cache_operation} = GenServer.call(c.server, {:bound, c.binding, :self_approve_all})
    assert {:ok, %{examples: [^second]}} = SemanticCache.examples(c.cache)
  end

  test "rehashing a snapshot cannot authorize duplicate or malformed example identities", c do
    {:ok, example} = SemanticCache.put(c.cache, %{id: "first", text: "where is my order?", label: "orders/lookup"})
    {:ok, snapshot} = SemanticCache.snapshot(c.cache)
    empty = start_supervised!({Memory, c.opts}, id: :empty)
    {:ok, target} = SemanticCache.bind({Memory, server: empty}, c.binding)
    for examples <- [[Example.dump(example), Example.dump(example)], [%{}]] do
      forged = Map.put(snapshot, "examples", examples) |> Map.delete("ref")
      forged = Map.put(forged, "ref", Portable.content_ref!(:cache_snapshot, forged))
      assert {:error, :invalid_cache_snapshot} = SemanticCache.restore(target, forged)
      assert {:ok, %{count: 0, revision: 0}} = SemanticCache.info(target)
    end
    assert {:error, :invalid_cache_snapshot} = SemanticCache.restore(target, nil)
    assert :ok = SemanticCache.restore(target, snapshot)
    assert {:ok, %{examples: [^example]}} = SemanticCache.examples(target)
  end

  test "backend nominations cannot inject extra labels, duplicates, fabricated review or a foreign binding", c do
    hit = %{label: "orders/lookup", score: 0.97, example_ref: "example:reviewed", example_revision: 2, content_ref: "content:order", binding: c.binding}
    assert {:ok, [^hit]} = SemanticCache.lookup(backend(c, {:ok, [hit]}), query())
    for invalid <- [%{hit | label: "payments/refund"}, %{hit | score: 1.1}, %{hit | example_revision: 2.0},
      %{hit | binding: %{c.binding | namespace: "other-tenant"}}, Map.put(hit, :authority, "root"), %{}] do
      assert {:error, :invalid_cache_nomination} = SemanticCache.lookup(backend(c, {:ok, [invalid]}), query())
    end
    assert {:error, :invalid_cache_nomination} = SemanticCache.lookup(backend(c, {:ok, [hit, hit]}), query())
    for reply <- [%{}, Enum.map(1..6, fn _ -> hit end)] do
      assert {:error, :invalid_cache_nominations} = SemanticCache.lookup(backend(c, {:ok, reply}), query())
    end
    assert {:error, {:invalid_cache_backend_reply, :lookup}} = SemanticCache.lookup(backend(c, :ok), query())
  end

  test "backend pages and mutation acknowledgements cannot smuggle unreviewed or unrelated revisions", c do
    {:ok, example} = SemanticCache.put(c.cache, %{text: "where is my order?", label: "orders/lookup"})
    for page <- [%{examples: [example, example], next: nil}, %{examples: [%{}], next: nil}, %{examples: [], next: 42}] do
      assert {:error, :invalid_cache_page_reply} = SemanticCache.examples(backend(c, {:ok, page}))
    end
    assert {:error, :invalid_cache_page_reply} = SemanticCache.examples(backend(c, {:ok, %{examples: [example], next: nil}}), verified: true)
    for reply <- [%{}, %{example | verified: true}, %{example | revision: 0}] do
      assert {:error, :invalid_cache_mutation_reply} = SemanticCache.put(backend(c, {:ok, reply}), %{})
    end
    assert {:error, :invalid_cache_mutation_reply} = SemanticCache.verify(backend(c, {:ok, %{example | revision: 2, verified: true}}), "different-id", 1)
  end

  test "cache configuration rejects unbounded queries and incomplete search bindings", c do
    assert {:error, _reason} = Configuration.new(unknown: true)

    for {key, value} <- [dimensions: 0, max_entries: 0, max_text_bytes: 0] do
      assert {:error, :invalid_semantic_cache_configuration} =
               c.opts |> Keyword.put(key, value) |> Configuration.new()
    end

    assert {:error, :invalid_cache_labels} = Configuration.query(%{text: "order", labels: nil})
    assert {:error, :invalid_cache_query} = Configuration.query(%{text: "order", labels: [], limit: 0})
    {:ok, config} = Configuration.new(c.opts)

    assert {:error, :cache_query_outside_binding} =
             Configuration.query(%{text: "order", labels: ["foreign/route"]}, config)

    assert {:error, :invalid_cache_search_binding} =
             c.opts
             |> Keyword.put(:dimensions, 384)
             |> Keyword.put(:search, {ConfigurableIndex, []})
             |> Configuration.new()
  end

  test "derived index adapters cannot smuggle malformed replies into routing" do
    assert :ok = Index.close(nil)

    for reply <- [{:error, :offline}, :malformed] do
      assert {:error, _reason} = Index.build({ConfigurableIndex, reply: reply}, [])
      assert {:error, _reason} = Index.search({ConfigurableIndex, :index}, [], %{reply: reply})
    end

    assert {:error, _reason} = Index.build({RaisingIndex, []}, [])
    assert {:error, _reason} = Index.search({RaisingIndex, :index}, [], %{})
  end

  test "the Router bridge requires a bound cache and a supported input shape", c do
    assert {:error, :semantic_cache_binding_required} = RouterAdapter.prepare(true, [])
    assert {:error, :invalid_semantic_cache_rule} = RouterAdapter.prepare(:enabled, cache: c.cache)

    request = %Request{input: self(), rules: [%{ref: "orders/lookup", data: true}]}
    assert {:error, :invalid_semantic_cache_input} = RouterAdapter.evaluate(request, cache: c.cache)
  end

  defp backend(c, reply) do
    {:ok, cache} = SemanticCache.bind({UntrustedBackend, reply: reply}, c.binding)
    cache
  end

  defp query, do: %{text: "where is my order?", labels: ["orders/lookup"], limit: 5}
end
