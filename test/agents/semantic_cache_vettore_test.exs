defmodule Spectre.SemanticCache.VettoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Router
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.RouterAdapter
  alias Spectre.SemanticCache.Vettore, as: Cache

  # Both engines use the real native Vettore dependency, not a matcher stub.
  # Analytical vectors exercise numerical boundaries; the companion real-model
  # and full-agent suites use FastEmbed-generated customer conversations.
  for index <- [:flat, :hnsw] do
    describe "#{index} native index" do
      setup do
        binding = %{
          namespace: "customer-a",
          definition_ref: "definition:support",
          flow: "support",
          profile_ref: "encoder:two-dimensions:v1"
        }

        options =
          Map.to_list(binding) ++
            [
              index: unquote(index),
              dimensions: 2,
              labels: ["support/orders", "support/billing"],
              max_entries: 20
            ]

        server = start_supervised!({Cache, options})
        {:ok, cache} = SemanticCache.bind({Cache, server: server}, binding)
        %{cache: cache, binding: binding, server: server, options: options}
      end

      test "quarantine cannot route; approval enables a non-exact semantic match", c do
        example = put(c, "order shipping", "support/orders", [1.0, 0.0])
        assert {:ok, []} = search(c, [0.99, 0.01])
        assert {:ok, approved} = SemanticCache.verify(c.cache, example.id, example.revision)
        assert {:ok, [hit]} = search(c, [0.99, 0.01])
        assert hit.example_ref == example.id
        assert hit.example_revision == approved.revision
        assert hit.binding === c.binding
        assert hit.score > 0.99
      end

      test "exact hits need no vector; a miss requests one and never embeds text", c do
        approved(c, "order shipping", "support/orders", nil)
        assert {:ok, [hit]} = search(c, nil, text: " ORDER SHIPPING ")
        assert hit.score === 1.0
        assert {:error, :embedding_required} = search(c, nil)

        assert {:error, :cache_embedding_callback_not_supported} =
                 SemanticCache.bind(
                   {Cache, server: c.server, embed: fn _ -> flunk("network callback") end},
                   c.binding
                 )
      end

      test "Router applies normal thresholds, preserves provenance and skips a missing vector",
           c do
        example = approved(c, "order shipping", "support/orders", [1.0, 0.0])
        {:ok, router} = router(c, accept: 0.9)
        assert :no_match = Router.route(router, "different words")
        assert :no_match = Router.route(router, input(c, [0.0, 1.0]))
        assert {:ok, selection} = Router.route(router, input(c, [0.99, 0.01]))
        assert selection.candidate == "orders"
        assert selection.via == "semantic_cache"
        assert selection.matched["example_ref"] == example.id
        assert selection.matched["example_revision"] == example.revision
        refute Map.has_key?(selection.matched, "text")
        refute Map.has_key?(selection.matched, "embedding")
      end

      test "two indistinguishable nominations stay ambiguous instead of selecting authority", c do
        approved(c, "order shipping", "support/orders", [1.0, 0.0])
        approved(c, "invoice shipping", "support/billing", [1.0, 0.0])
        {:ok, router} = router(c, margin: 0.1)
        assert {:ambiguous, refs} = Router.route(router, input(c, [1.0, 0.0]))
        assert Enum.sort(refs) == ["support/billing", "support/orders"]
      end

      test "label filtering precedes top-k even with many closer forbidden examples", c do
        for n <- 1..8, do: approved(c, "order #{n}", "support/orders", [1.0, 0.0])
        wanted = approved(c, "invoice", "support/billing", [0.8, 0.6])
        assert {:ok, [hit]} = search(c, [1.0, 0.0], labels: ["support/billing"], limit: 1)
        assert hit.example_ref == wanted.id
        assert_in_delta hit.score, 0.8, 0.0001
      end

      test "edits invalidate the built index and require fresh review", c do
        example = approved(c, "order shipping", "support/orders", [1.0, 0.0])
        assert {:ok, [_]} = search(c, [1.0, 0.0])

        assert {:ok, edited} =
                 SemanticCache.update(
                   c.cache,
                   example.id,
                   %{label: "support/billing"},
                   example.revision
                 )

        refute edited.verified
        assert {:ok, []} = search(c, [1.0, 0.0])

        assert {:error, :cache_revision_conflict} =
                 SemanticCache.verify(c.cache, example.id, example.revision)

        assert {:ok, _} = SemanticCache.verify(c.cache, edited.id, edited.revision)
        assert {:ok, [%{label: "support/billing"}]} = search(c, [1.0, 0.0])
      end

      test "deletion removes exact and vector data; reusing the id cannot revive old review", c do
        example = approved(c, "order shipping", "support/orders", [1.0, 0.0])
        assert {:ok, [_]} = search(c, [1.0, 0.0])
        assert :ok = SemanticCache.delete(c.cache, example.id, example.revision)
        assert {:ok, []} = search(c, [1.0, 0.0])
        assert {:error, :embedding_required} = search(c, nil, text: example.text)
        assert {:ok, %{examples: []}} = SemanticCache.examples(c.cache)
        assert {:ok, snapshot} = SemanticCache.snapshot(c.cache)
        assert snapshot["examples"] == []

        assert {:ok, replacement} =
                 SemanticCache.put(
                   c.cache,
                   %{id: example.id, text: "new content", label: "support/orders"}
                 )

        assert replacement.revision > example.revision

        assert {:error, :cache_revision_conflict} =
                 SemanticCache.verify(c.cache, example.id, example.revision)
      end

      test "recovery rebuilds the index from approved examples, never native opaque resources",
           c do
        approved(c, "order shipping", "support/orders", [1.0, 0.0])
        put(c, "unreviewed invoice", "support/billing", [0.0, 1.0])
        assert {:ok, before} = search(c, [0.9, 0.1])
        {:ok, snapshot} = SemanticCache.snapshot(c.cache)
        restored = start_supervised!(Supervisor.child_spec({Cache, c.options}, id: :restored))
        {:ok, handle} = SemanticCache.bind({Cache, server: restored}, c.binding)
        assert :ok = SemanticCache.restore(handle, snapshot)
        assert {:ok, after_restore} = search(%{c | cache: handle}, [0.9, 0.1])
        assert after_restore === before
        assert {:error, :cache_not_empty} = SemanticCache.restore(handle, snapshot)
      end

      test "every binding dimension is checked on each backend call, not just handle creation",
           c do
        example = approved(c, "order shipping", "support/orders", [1.0, 0.0])

        for field <- [:namespace, :definition_ref, :flow, :profile_ref] do
          foreign = Map.put(c.binding, field, "foreign")

          assert {:error, :cache_binding_mismatch} =
                   Cache.lookup(
                     foreign,
                     %{text: "order shipping", labels: ["support/orders"]},
                     server: c.server
                   )

          assert {:error, :cache_binding_mismatch} =
                   Cache.delete(foreign, example.id, example.revision, server: c.server)
        end

        assert {:ok, [_]} = search(c, [1.0, 0.0])
      end

      test "invalid dimensions, profile and native vectors fail without killing the store", c do
        approved(c, "order shipping", "support/orders", [1.0, 0.0])

        for vector <- [[1.0], [1.0, 0.0, 0.0], [0.0, 0.0], [1.0e40, 1.0]] do
          assert {:error, _} = search(c, vector)
        end

        assert {:error, _} = search(c, [1.0, 0.0], profile_ref: "different-encoder")
        assert Process.alive?(c.server)
        assert {:ok, [_]} = search(c, [1.0, 0.0])
      end

      test "concurrent reviewers can approve only one exact revision", c do
        example = put(c, "order shipping", "support/orders", [1.0, 0.0])

        replies =
          1..12
          |> Task.async_stream(
            fn _ ->
              SemanticCache.verify(c.cache, example.id, example.revision)
            end,
            max_concurrency: 12
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(replies, &match?({:ok, _}, &1)) == 1
        assert Enum.count(replies, &(&1 == {:error, :cache_revision_conflict})) == 11
        assert {:ok, [_]} = search(c, [1.0, 0.0])
      end
    end
  end

  defp put(c, text, label, vector) do
    attrs = %{text: text, label: label, embedding: vector, profile_ref: c.binding.profile_ref}
    assert {:ok, example} = SemanticCache.put(c.cache, attrs)
    example
  end

  defp approved(c, text, label, vector) do
    example = put(c, text, label, vector)
    assert {:ok, example} = SemanticCache.verify(c.cache, example.id, example.revision)
    example
  end

  defp search(c, vector, options \\ []) do
    query =
      Map.merge(
        %{
          text: "different words",
          vector: vector,
          profile_ref: c.binding.profile_ref,
          labels: ["support/orders", "support/billing"],
          limit: 5
        },
        Map.new(options)
      )

    SemanticCache.lookup(c.cache, query)
  end

  defp input(c, vector),
    do: %{
      "text" => "different words",
      "embedding" => vector,
      "profile_ref" => c.binding.profile_ref
    }

  defp router(c, opts) do
    rules = %{
      "support/orders" => %{to: "orders", match: %{semantic_cache: true}},
      "support/billing" => %{to: "billing", match: %{semantic_cache: true}}
    }

    Router.new(
      rules,
      Keyword.merge(
        [via: [:semantic_cache], adapters: [semantic_cache: {RouterAdapter, cache: c.cache}]],
        opts
      )
    )
  end
end
