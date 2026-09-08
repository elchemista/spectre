defmodule Spectre.Agents.SemanticCacheTest do
  use ExUnit.Case, async: true

  alias Spectre.Router
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.{Example, Memory, RouterAdapter}

  setup do
    binding = %{
      namespace: "tenant-a",
      definition_ref: "definition:support",
      flow: "orders",
      profile_ref: "embedding:test"
    }

    options = Map.to_list(binding) ++ [dimensions: 2, labels: ["orders/lookup"], max_entries: 2]
    server = start_supervised!({Memory, options})
    {:ok, cache} = SemanticCache.bind({Memory, server: server}, binding)
    %{cache: cache, server: server, binding: binding, options: options}
  end

  test "only the inspected, approved revision participates in exact routing", c do
    assert {:ok, example} =
             SemanticCache.put(c.cache, %{text: "order 42", label: "orders/lookup"})

    refute example.verified
    assert :miss = lookup(c.cache, example.text)
    assert {:ok, approved} = SemanticCache.verify(c.cache, example.id, example.revision)
    assert approved.revision > example.revision
    assert {:ok, [hit]} = lookup(c.cache, " ORDER 42 ")
    assert hit.example_ref == example.id
    assert hit.example_revision == approved.revision
    assert hit.binding === c.binding
    assert hit.score == 1.0
  end

  test "stale review cannot approve an edit and failure leaves a snapshot unchanged", c do
    {:ok, example} = SemanticCache.put(c.cache, %{text: "order 42", label: "orders/lookup"})

    {:ok, edited} =
      SemanticCache.update(c.cache, example.id, %{text: "order 43"}, example.revision)

    {:ok, before} = SemanticCache.snapshot(c.cache)

    assert {:error, :cache_revision_conflict} =
             SemanticCache.verify(c.cache, example.id, example.revision)

    assert {:ok, ^before} = SemanticCache.snapshot(c.cache)
    assert {:ok, %{examples: [^edited]}} = SemanticCache.examples(c.cache)
    assert :miss = lookup(c.cache, edited.text)
    assert Process.alive?(c.server)
  end

  test "editing withdraws approval, removes the old exact index and discards its vector", c do
    {:ok, example} =
      SemanticCache.put(c.cache, %{
        text: "order 42",
        label: "orders/lookup",
        embedding: [1.0, 0.0],
        profile_ref: c.binding.profile_ref
      })

    {:ok, example} = SemanticCache.verify(c.cache, example.id, example.revision)
    assert {:ok, [_]} = lookup(c.cache, "order 42")

    {:ok, edited} =
      SemanticCache.update(c.cache, example.id, %{text: "order 43"}, example.revision)

    refute edited.verified
    assert is_nil(edited.embedding)
    assert :miss = lookup(c.cache, "order 42")
    assert :miss = lookup(c.cache, "order 43")
  end

  test "a foreign namespace, Definition, flow or encoder cannot bind the same server", c do
    for key <- [:namespace, :definition_ref, :flow, :profile_ref] do
      assert {:error, :cache_binding_mismatch} =
               SemanticCache.bind({Memory, server: c.server}, Map.put(c.binding, key, "foreign"))
    end

    assert {:error, :cache_configuration_mismatch} =
             SemanticCache.bind({Memory, server: c.server, max_entries: 20}, c.binding)
  end

  test "the old embedding callback is rejected even before an exact lookup", c do
    assert {:error, :cache_embedding_callback_not_supported} =
             SemanticCache.bind(
               {Memory, server: c.server, embed: fn _ -> flunk("must not run") end},
               c.binding
             )

    assert {:error, _} =
             SemanticCache.lookup(
               c.cache,
               %{
                 text: "order",
                 labels: ["orders/lookup"],
                 embed: fn _ -> flunk("must not run") end
               }
             )
  end

  test "caller cannot promote on insert or bind vectors from an equal-sized foreign encoder", c do
    for attrs <- [
          %{text: "a", label: "orders/lookup", verified: true},
          %{text: "a", label: "orders/lookup", embedding: [1.0, 0.0]},
          %{text: "a", label: "orders/lookup", embedding: [1.0, 0.0], profile_ref: "foreign"}
        ] do
      assert {:error, _} = SemanticCache.put(c.cache, attrs)
    end

    assert {:ok, %{count: 0}} = SemanticCache.info(c.cache)
  end

  test "capacity includes quarantined examples and deletion frees only the selected revision",
       c do
    {:ok, first} = SemanticCache.put(c.cache, %{id: "a", text: "a", label: "orders/lookup"})
    {:ok, second} = SemanticCache.put(c.cache, %{id: "b", text: "b", label: "orders/lookup"})

    assert {:error, :semantic_cache_full} =
             SemanticCache.put(c.cache, %{text: "c", label: "orders/lookup"})

    assert {:error, :cache_revision_conflict} =
             SemanticCache.delete(c.cache, first.id, first.revision + 1)

    assert :ok = SemanticCache.delete(c.cache, first.id, first.revision)
    assert {:ok, %{examples: [^second]}} = SemanticCache.examples(c.cache)
    assert {:ok, _} = SemanticCache.put(c.cache, %{text: "c", label: "orders/lookup"})
  end

  test "pages filter before limiting and do not duplicate the cursor row", c do
    {:ok, _} = SemanticCache.put(c.cache, %{id: "a", text: "a", label: "orders/lookup"})
    {:ok, second} = SemanticCache.put(c.cache, %{id: "b", text: "b", label: "orders/lookup"})
    {:ok, second} = SemanticCache.verify(c.cache, second.id, second.revision)

    assert {:ok, %{examples: [^second]}} =
             SemanticCache.examples(c.cache, verified: true, limit: 1)

    assert {:ok, %{examples: [first], next: cursor}} = SemanticCache.examples(c.cache, limit: 1)
    assert first.id == "a"

    assert {:ok, %{examples: [^second]}} =
             SemanticCache.examples(c.cache, limit: 1, after: cursor)
  end

  test "snapshot restore preserves approval and binding only into a fresh destination", c do
    {:ok, example} = SemanticCache.put(c.cache, %{text: "order 42", label: "orders/lookup"})
    {:ok, approved} = SemanticCache.verify(c.cache, example.id, example.revision)
    {:ok, snapshot} = SemanticCache.snapshot(c.cache)
    assert {:error, :cache_not_empty} = SemanticCache.restore(c.cache, snapshot)
    restored_server = start_supervised!(Supervisor.child_spec({Memory, c.options}, id: :restored))
    {:ok, restored} = SemanticCache.bind({Memory, server: restored_server}, c.binding)
    assert :ok = SemanticCache.restore(restored, snapshot)
    assert lookup(c.cache, "order 42") === lookup(restored, "order 42")
    assert {:error, :cache_not_empty} = SemanticCache.restore(restored, snapshot)
    assert :ok = SemanticCache.delete(c.cache, example.id, approved.revision)
    assert {:error, :cache_not_empty} = SemanticCache.restore(c.cache, snapshot)
  end

  test "corrupted snapshots and forged pagination options cannot mutate the backend", c do
    {:ok, snapshot} = SemanticCache.snapshot(c.cache)
    assert {:error, _} = SemanticCache.restore(c.cache, Map.put(snapshot, "revision", 1.0))

    for opts <- [[limit: 0], [limit: 1.0], [limit: 501], [after: self()], [verified: :yes]] do
      assert {:error, _} = SemanticCache.examples(c.cache, opts)
    end

    assert {:ok, ^snapshot} = SemanticCache.snapshot(c.cache)
  end

  test "the ordinary Router bridge uses review and preserves miss versus error", c do
    rules = %{"orders/lookup" => %{to: "lookup", match: %{semantic_cache: true}}}

    {:ok, router} =
      Router.new(rules,
        via: [:semantic_cache],
        adapters: [semantic_cache: {RouterAdapter, cache: c.cache}]
      )

    assert :no_match = Router.route(router, "order 42")
    {:ok, example} = SemanticCache.put(c.cache, %{text: "order 42", label: "orders/lookup"})
    {:ok, _} = SemanticCache.verify(c.cache, example.id, example.revision)

    assert {:ok, %{candidate: "lookup", via: "semantic_cache", matched: matched}} =
             Router.route(router, "order 42")

    assert matched["example_ref"] == example.id
    refute Map.has_key?(matched, "text")

    assert {:error, _} =
             Router.route(router, %{
               "text" => "order",
               "embedding" => [1, 0],
               "profile_ref" => "foreign"
             })
  end

  test "generic embedding validation preserves finite values and rejects conversion overflow" do
    <<maximum::float-32>> = <<0x7F7FFFFF::32>>
    assert {:ok, [^maximum, negative]} = Example.embedding([maximum, -maximum], 2)
    assert negative == -maximum
    # Native f32 restrictions belong to the optional backend, not every store.
    assert {:ok, _} = Example.embedding([maximum * 1.000_001, 1.0], 2)

    for value <- [Integer.pow(2, 1024), -Integer.pow(2, 1024)] do
      assert {:error, :invalid_cache_embedding} = Example.embedding([value, 1.0], 2)
    end
  end

  defp lookup(cache, text),
    do:
      SemanticCache.lookup(
        cache,
        %{text: text, vector: nil, labels: ["orders/lookup"], limit: 5}
      )
end
