defmodule Spectre.Agents.SemanticCacheIndexContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Memory
  alias Spectre.SemanticCache.Test.CustomerSupport
  alias Spectre.SemanticCache.Vettore.Index, as: NativeIndex

  defmodule ObservedIndex do
    @behaviour Spectre.Router.SemanticCache.Index

    @impl true
    def build(examples, opts) do
      {observer, opts} = Keyword.pop!(opts, :observer)
      send(observer, {:index_build, examples})
      NativeIndex.build(examples, opts)
    end

    @impl true
    defdelegate search(index, vector, query), to: NativeIndex
    @impl true
    defdelegate close(index), to: NativeIndex
  end

  test "the shared engine never sends quarantined or withdrawn text to an index adapter" do
    {:ok, 384} = ExFastembed.load(CustomerSupport.model())

    texts = [
      "Find the delivery status of my order",
      "Unreviewed private support draft",
      "Where is my package?"
    ]

    {:ok, [approved_vector, draft_vector, query_vector]} = ExFastembed.embed_text(texts)

    binding = %{
      namespace: "index-contract",
      definition_ref: "definition:support",
      flow: "orders",
      profile_ref: CustomerSupport.profile()
    }

    native = [
      observer: self(),
      dimensions: 384,
      metric: :cosine,
      normalize: :l2,
      score: :raw,
      compressed: true,
      index: :flat
    ]

    options =
      Map.to_list(binding) ++
        [
          dimensions: 384,
          labels: ["orders/lookup"],
          max_entries: 20,
          search: {ObservedIndex, native}
        ]

    server = start_supervised!({Memory, options})
    {:ok, cache} = SemanticCache.bind({Memory, server: server}, binding)

    {:ok, approved} =
      SemanticCache.put(cache, %{
        text: hd(texts),
        label: "orders/lookup",
        embedding: approved_vector,
        profile_ref: binding.profile_ref
      })

    {:ok, approved} = SemanticCache.verify(cache, approved.id, approved.revision)

    {:ok, draft} =
      SemanticCache.put(cache, %{
        text: Enum.at(texts, 1),
        label: "orders/lookup",
        embedding: draft_vector,
        profile_ref: binding.profile_ref
      })

    query = %{
      text: List.last(texts),
      vector: query_vector,
      profile_ref: binding.profile_ref,
      labels: ["orders/lookup"]
    }

    assert {:ok, [%{example_ref: ref}]} = SemanticCache.lookup(cache, query)
    assert ref == approved.id
    assert_receive {:index_build, examples}
    assert examples == [{approved.id, approved}]

    # An unreviewed edit must not rebuild or disclose the draft to the index.
    assert {:ok, _} =
             SemanticCache.update(
               cache,
               draft.id,
               %{text: "Still awaiting review"},
               draft.revision
             )

    assert {:ok, [_]} = SemanticCache.lookup(cache, query)
    refute_received {:index_build, _}

    # Editing an approved example withdraws it. Rebuilding now gets no records.
    assert {:ok, _} =
             SemanticCache.update(
               cache,
               approved.id,
               %{text: "Changed delivery policy"},
               approved.revision
             )

    assert {:ok, []} = SemanticCache.lookup(cache, query)
    assert_receive {:index_build, []}
    assert {:ok, %{count: 2}} = SemanticCache.info(cache)
  end
end
