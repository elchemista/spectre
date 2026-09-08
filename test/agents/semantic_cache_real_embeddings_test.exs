defmodule Spectre.SemanticCache.RealEmbeddingsTest do
  use ExUnit.Case, async: false

  alias Spectre.{Eval, Router}
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.RouterAdapter
  alias Spectre.SemanticCache.Test.CustomerSupport
  alias Spectre.SemanticCache.Vettore, as: Cache

  @moduletag timeout: 180_000

  setup_all do
    # Requires the real model, cached between runs. Download/inference failures are
    # failures, never silently skipped or replaced by hand-written vectors.
    %{vectors: CustomerSupport.embed!()}
  end

  for engine <- [:flat, :hnsw] do
    describe "#{engine} with real FastEmbed support conversations" do
      setup c do
        binding = %{
          namespace: "retailer:europe",
          definition_ref: "definition:customer-service:v4",
          flow: "support",
          profile_ref: CustomerSupport.profile()
        }

        options =
          Map.to_list(binding) ++
            [
              dimensions: 384,
              max_entries: 200,
              labels: CustomerSupport.labels(),
              index: unquote(engine)
            ]

        server = start_supervised!({Cache, options})
        {:ok, cache} = SemanticCache.bind({Cache, server: server}, binding)

        examples =
          Enum.map(CustomerSupport.examples(), fn {label, text} ->
            {:ok, example} =
              SemanticCache.put(cache, %{
                text: text,
                label: label,
                embedding: Map.fetch!(c.vectors, text),
                profile_ref: binding.profile_ref
              })

            {:ok, example} = SemanticCache.verify(cache, example.id, example.revision)
            example
          end)

        rules =
          Map.new(CustomerSupport.labels(), &{&1, %{to: &1, match: %{semantic_cache: true}}})

        {:ok, router} =
          Router.new(rules,
            via: [:semantic_cache],
            accept: 0.70,
            margin: 0.03,
            adapters: [semantic_cache: {RouterAdapter, cache: cache}]
          )

        %{cache: cache, router: router, options: options, examples: examples, binding: binding}
      end

      test "held-out customer paraphrases route to their intended handlers", c do
        for {expected, text} <- CustomerSupport.queries() do
          refute Enum.any?(c.examples, &(&1.text == text))
          assert length(c.vectors[text]) == 384
          assert {:ok, selected} = Router.route(c.router, input(c, text))
          assert selected.candidate == expected, "wrong intent for: #{text}"
          assert selected.via == "semantic_cache"
          assert selected.score >= 0.70

          assert Enum.any?(
                   c.examples,
                   &(&1.id == selected.matched["example_ref"] and &1.label == expected)
                 )
        end
      end

      test "offline evaluation reuses the native cache and real embeddings without training it",
           c do
        cases =
          for {label, text} <- CustomerSupport.queries() do
            %{
              "input" => input(c, text),
              "expected" => %{"status" => "matched", "rule" => label, "via" => "semantic_cache"}
            }
          end

        {:ok, before} = SemanticCache.snapshot(c.cache)
        assert {:ok, report} = Eval.run(c.router, cases)
        assert report.total == length(CustomerSupport.queries())
        assert report.failed == 0
        assert {:ok, ^before} = SemanticCache.snapshot(c.cache)
      end

      test "unrelated content is not forced into the nearest business action", c do
        assert :no_match = Router.route(c.router, input(c, CustomerSupport.unrelated()))
      end

      test "exact text remains usable without model access, but unseen text does not embed inside routing",
           c do
        example = hd(c.examples)
        assert {:ok, %{score: 1.0}} = Router.route(c.router, example.text)
        {_label, text} = hd(CustomerSupport.queries())
        assert :no_match = Router.route(c.router, text)
        assert {:ok, %{candidate: "refund"}} = Router.route(c.router, input(c, text))
      end

      test "approved examples cannot leak across tenants or equally sized encoder profiles", c do
        {_label, text} = hd(CustomerSupport.queries())

        assert {:error, _} =
                 Router.route(
                   c.router,
                   Map.put(input(c, text), "profile_ref", "encoder:foreign:384")
                 )

        foreign = Keyword.put(c.options, :namespace, "retailer:other")
        other = start_supervised!(Supervisor.child_spec({Cache, foreign}, id: :other_tenant))

        {:ok, handle} =
          SemanticCache.bind({Cache, server: other}, %{c.binding | namespace: "retailer:other"})

        assert {:ok, []} =
                 SemanticCache.lookup(handle, %{
                   text: text,
                   vector: c.vectors[text],
                   labels: CustomerSupport.labels(),
                   profile_ref: c.binding.profile_ref
                 })

        {:ok, snapshot} = SemanticCache.snapshot(c.cache)
        assert {:error, _} = SemanticCache.restore(handle, snapshot)
      end

      test "erasing all refund examples removes semantic recall and their stored conversation text",
           c do
        {_label, text} = hd(CustomerSupport.queries())
        assert {:ok, %{candidate: "refund"}} = Router.route(c.router, input(c, text))
        removed = Enum.filter(c.examples, &(&1.label == "refund"))

        for example <- removed,
            do: assert(:ok == SemanticCache.delete(c.cache, example.id, example.revision))

        assert {:ok, []} =
                 SemanticCache.lookup(c.cache, %{
                   text: text,
                   vector: c.vectors[text],
                   labels: ["refund"],
                   profile_ref: c.binding.profile_ref
                 })

        assert {:ok, snapshot} = SemanticCache.snapshot(c.cache)
        for example <- removed, do: refute(inspect(snapshot) =~ example.text)
      end

      test "review edits cannot leave a stale native index serving the previous intent", c do
        {_label, text} = hd(CustomerSupport.queries())
        assert {:ok, selected} = Router.route(c.router, input(c, text))
        example = Enum.find(c.examples, &(&1.id == selected.matched["example_ref"]))

        {:ok, edited} =
          SemanticCache.update(
            c.cache,
            example.id,
            %{text: "Withdrawn after customer correction"},
            example.revision
          )

        assert edited.embedding == nil
        refute edited.verified
        assert {:ok, new_selection} = Router.route(c.router, input(c, text))
        refute new_selection.matched["example_ref"] == example.id

        assert {:error, :cache_revision_conflict} =
                 SemanticCache.verify(c.cache, example.id, example.revision)
      end
    end
  end

  defp input(c, text),
    do: %{
      "text" => text,
      "embedding" => Map.fetch!(c.vectors, text),
      "profile_ref" => CustomerSupport.profile()
    }
end
