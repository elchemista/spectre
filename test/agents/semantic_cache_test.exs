defmodule Spectre.Agents.SemanticCacheTest do
  use ExUnit.Case, async: true

  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.{Example, Memory}

  setup do
    cache =
      start_supervised!(
        {Memory,
         namespace: "test/support",
         definition_ref: "definition:support",
         profile_ref: "embedding:test",
         dimensions: 2,
         labels: ["orders/lookup"]}
      )

    %{cache: cache}
  end

  test "review promotes only the inspected example and makes it eligible for exact routing", c do
    assert {:ok, example} =
             SemanticCache.put(c.cache, %{text: "order 42", label: "orders/lookup"})

    refute example.verified
    assert {:ok, []} = SemanticCache.lookup(c.cache, example.text)
    assert {:ok, approved} = SemanticCache.verify(c.cache, example.id, example.revision)
    assert approved.verified
    assert approved.revision == example.revision + 1
    assert approved.id == example.id

    assert {:ok, [%{id: id, label: "orders/lookup", score: 1.0, method: :exact}]} =
             SemanticCache.lookup(c.cache, example.text)

    assert id == example.id
  end

  test "a stale review cannot approve an edit or mutate cache state", c do
    {:ok, example} = SemanticCache.put(c.cache, %{text: "order 42", label: "orders/lookup"})

    assert {:ok, edited} =
             SemanticCache.update_example(c.cache, example.id, example.revision, %{
               text: "order 43"
             })

    assert {:ok, before_review} = SemanticCache.snapshot(c.cache)

    assert {:error, :cache_revision_conflict} =
             SemanticCache.verify(c.cache, example.id, example.revision)

    assert {:ok, ^before_review} = SemanticCache.snapshot(c.cache)
    assert {:ok, ^edited} = SemanticCache.get_example(c.cache, example.id)
    assert {:ok, []} = SemanticCache.lookup(c.cache, edited.text)
    assert Process.alive?(c.cache)
  end

  test "reviewing a missing example returns an error without changing the cache", c do
    assert {:ok, before_review} = SemanticCache.snapshot(c.cache)

    assert {:error, :cache_example_not_found} =
             SemanticCache.verify(c.cache, "missing", 1)

    assert {:ok, ^before_review} = SemanticCache.snapshot(c.cache)
    assert Process.alive?(c.cache)
  end

  test "online review cannot rewrite an imported read-only example", c do
    assert {:ok, 1} =
             SemanticCache.import_examples(c.cache, [
               %{id: "offline", text: "order 42", label: "orders/lookup"}
             ])

    assert {:ok, example} = SemanticCache.get_example(c.cache, "offline")
    assert {:ok, before_review} = SemanticCache.snapshot(c.cache)

    assert {:error, :cache_example_read_only} =
             SemanticCache.verify(c.cache, example.id, example.revision)

    assert {:ok, ^before_review} = SemanticCache.snapshot(c.cache)
    assert {:ok, ^example} = SemanticCache.get_example(c.cache, example.id)
  end

  test "embedding validation preserves both exact IEEE float32 finite limits" do
    <<maximum::float-32>> = <<0x7F7FFFFF::32>>
    vector = [maximum, -maximum]

    assert {:ok, ^vector} = Example.embedding(vector, 2)
  end

  test "embedding validation rejects float32 overflow and oversized integers without raising" do
    <<maximum::float-32>> = <<0x7F7FFFFF::32>>
    overflow = maximum * 1.000_001
    oversized_integer = Integer.pow(2, 1024)

    for value <- [overflow, -overflow, oversized_integer, -oversized_integer] do
      assert {:error, :invalid_cache_embedding} = Example.embedding([value, 1.0], 2)
    end
  end
end
