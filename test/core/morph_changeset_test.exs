defmodule Spectre.Core.MorphChangesetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.{Definition, Morph}

  defmodule Strategy do
    @behaviour Spectre.Morph
    @impl true
    def changes(_definition, opts),
      do: {:ok, [%{op: :put, path: ["prompt"], value: opts[:prompt]}]}
  end

  defmodule Malformed do
    @behaviour Spectre.Morph
    @impl true
    def changes(_definition, _opts), do: :ok
  end

  defmodule Crashing do
    @behaviour Spectre.Morph
    @impl true
    def changes(_definition, _opts), do: raise("private model response")
  end

  defmodule Agent do
    use Spectre.Agent, namespace: "morph", name: "agent", revision: 1, declared_at: 0
    candidate("lookup", class: "orders.lookup")
    route("request", to: "lookup", match: [string_bag: ["find order"]])
    asset("prompt", "look up the order")
  end

  test "atomic changesets pin the exact predecessor and retain metadata identity" do
    original = definition(%{"prompt" => "old", "items" => ["a", "b"]})

    assert {:ok, revised} =
             Morph.prepare(
               original,
               [
                 %{op: :test, path: ["prompt"], value: "old"},
                 %{op: :put, path: ["prompt"], value: "new"},
                 %{op: :delete, path: ["items", 0]}
               ],
               10
             )

    assert revised.body == %{"prompt" => "new", "items" => ["b"]}
    assert revised.previous_ref == original.ref
    assert revised.revision == original.revision + 1
    assert Definition.key(revised) == Definition.key(original)
    assert revised.declared_at == 10
    assert original.body["prompt"] == "old"
  end

  test "failed exact preconditions abort earlier writes too" do
    original = definition(%{"amount" => 1})

    assert {:error, {:invalid_morph_change, 1, :morph_precondition_failed}} =
             Morph.prepare(
               original,
               [
                 %{op: :put, path: ["temporary"], value: true},
                 %{op: :test, path: ["amount"], value: 1.0}
               ],
               1
             )

    assert original.body == %{"amount" => 1}
  end

  test "traversal cannot invent absent intermediate containers or coerce list indices" do
    original = definition(%{"items" => [%{"name" => "first"}]})

    for path <- [["missing", "nested"], ["items", -1], ["items", 1], ["items", 0.0]] do
      assert {:error, _} = Morph.prepare(original, [%{op: :put, path: path, value: "x"}], 1)
    end

    assert {:ok, revised} =
             Morph.prepare(
               original,
               [%{op: :put, path: ["items", 0, "name"], value: "second"}],
               1
             )

    assert revised.body["items"] == [%{"name" => "second"}]
  end

  test "delete distinguishes an absent key from a nil value" do
    original = definition(%{"nil" => nil})

    assert {:error, {:invalid_morph_change, 0, :morph_path_not_found}} =
             Morph.prepare(original, [%{op: :delete, path: ["missing"]}], 1)

    assert {:ok, revised} = Morph.prepare(original, [%{op: :delete, path: ["nil"]}], 1)
    assert revised.body == %{}
  end

  test "the root can only be replaced with a valid body, never deleted" do
    original = definition(%{"old" => true})
    assert {:ok, revised} = Morph.prepare(original, [%{op: :put, path: [], value: %{}}], 1)
    assert revised.body == %{}
    assert {:error, _} = Morph.prepare(original, [%{op: :put, path: [], value: "not a body"}], 1)
    assert {:error, _} = Morph.prepare(original, [%{op: :delete, path: []}], 1)
  end

  test "portable transport spellings preserve the same exact prepared Definition" do
    original = definition(%{})
    assert {:ok, revised} = Morph.prepare(original, [%{op: :put, path: ["x"], value: 1}], 1)

    assert {:ok, ^revised} =
             Morph.prepare(original, [%{"op" => "put", "path" => ["x"], "value" => 1}], 1)
  end

  test "malformed changes and capabilities fail before partial data is returned" do
    for changes <- [
          nil,
          [1],
          [%{op: :put, path: []}],
          [%{op: :put, path: nil, value: 1}],
          [%{op: :delete, path: ["x"], value: nil}],
          [%{op: :execute, path: ["x"], value: "shell"}],
          [%{op: :put, path: ["x"], value: self()}],
          [%{op: :put, path: ["x"], value: fn -> :power end}],
          [%{op: :put, path: ["x"], value: 1, authority: true}],
          [:ok | :improper]
        ] do
      assert {:error, _} = Morph.prepare(definition(%{}), changes, 1)
    end
  end

  test "a changeset cannot hide dangling routes or discard the Agent schema" do
    assert {:error, :invalid_agent_routing} =
             Morph.prepare(
               Agent.definition(),
               [%{op: :delete, path: ["candidates", "lookup"]}],
               1
             )

    assert {:error, :not_an_agent_declaration} =
             Morph.prepare(
               Agent.definition(),
               [%{op: :put, path: ["format"], value: "bypass"}],
               1
             )

    assert {:ok, revised} =
             Morph.prepare(
               Agent.definition(),
               [
                 %{op: :delete, path: ["routing", "rules", "request"]},
                 %{op: :delete, path: ["candidates", "lookup"]}
               ],
               1
             )

    assert revised.body["candidates"] == %{}
  end

  test "diff distinguishes integer/float changes and preserves deletions" do
    before = definition(%{"a" => 1, "b" => 2})
    after_definition = definition(%{"c" => 3, "a" => 1.0})
    assert {:ok, changes} = Morph.diff(before, after_definition)
    assert %{op: :put, path: ["a"], value: 1.0} in changes
    assert %{op: :delete, path: ["b"]} in changes
    assert {:ok, applied} = Morph.prepare(before, changes, 1)
    assert applied.body === after_definition.body
    assert {:ok, []} = Morph.diff(before, before)
  end

  property "reviewed diffs apply exactly to generated map and list-valued Definitions" do
    check all(
            before <-
              map_of(
                string(:alphanumeric, min_length: 1, max_length: 5),
                list_of(integer(), max_length: 5),
                max_length: 8
              ),
            after_body <-
              map_of(
                string(:alphanumeric, min_length: 1, max_length: 5),
                list_of(integer(), max_length: 5),
                max_length: 8
              ),
            max_runs: 40
          ) do
      original = definition(before)
      assert {:ok, changes} = Morph.diff(original, definition(after_body))
      assert {:ok, result} = Morph.prepare(original, changes, 1)
      assert result.body === after_body
      assert result.previous_ref === original.ref
    end
  end

  test "a broad diff is an applicable atomic replacement instead of an oversized changeset" do
    original = definition(%{"retained" => %{"old" => true}})
    body = Map.new(1..512, fn index -> {"asset-#{index}", %{"text" => "content #{index}"}} end)
    assert {:ok, [change] = changes} = Morph.diff(original, definition(body))
    assert change == %{op: :put, path: [], value: body}
    assert {:ok, revised} = Morph.prepare(original, changes, 1)
    assert revised.body === body
    assert revised.previous_ref === original.ref
  end

  test "a nested diff at the operation limit retains the reviewable leaf changes" do
    original = definition(%{"assets" => %{}})
    body = %{"assets" => Map.new(1..128, fn index -> {"prompt-#{index}", "text"} end)}
    assert {:ok, changes} = Morph.diff(original, definition(body))
    assert length(changes) == 128
    assert Enum.all?(changes, &match?(%{op: :put, path: ["assets", _]}, &1))
    assert {:ok, revised} = Morph.prepare(original, changes, 1)
    assert revised.body === body
  end

  test "a wide change within one nested container cannot bypass the operation budget" do
    original = definition(%{"assets" => %{}})
    body = %{"assets" => Map.new(1..129, fn index -> {"prompt-#{index}", "text"} end)}
    assert {:ok, [%{op: :put, path: []}] = changes} = Morph.diff(original, definition(body))
    assert {:ok, revised} = Morph.prepare(original, changes, 1)
    assert revised.body === body
  end

  test "rollback is a new forward revision preserving both earlier entries" do
    original = definition(%{"prompt" => "old"})

    assert {:ok, revised} =
             Morph.prepare(original, [%{op: :put, path: ["prompt"], value: "new"}], 1)

    assert {:ok, rollback} = Morph.rollback(revised, original, 2)
    assert rollback.body == original.body
    assert rollback.revision == 3
    assert rollback.previous_ref == revised.ref
    refute rollback.ref == original.ref
    assert {:error, :not_a_prior_definition} = Morph.rollback(original, revised, 2)
  end

  test "rollback refuses another logical Definition even with an older revision" do
    original = definition(%{})
    {:ok, revised} = Definition.revise(original, %{}, 1)
    {:ok, other} = Definition.new(namespace: "morph", name: "other", revision: 1, declared_at: 0)
    assert {:error, :not_a_prior_definition} = Morph.rollback(revised, other, 2)
  end

  test "strategy adapters return data, not activation permissions" do
    original = definition(%{"prompt" => "old"})
    assert {:ok, revised} = Morph.from_adapter(original, Strategy, [prompt: "new"], 1)
    assert revised.body == %{"prompt" => "new"}
    assert {:error, :invalid_morph_adapter_reply} = Morph.from_adapter(original, Malformed, [], 1)

    assert {:error, {:adapter_callback_exception, Crashing, :changes, RuntimeError}} =
             Morph.from_adapter(original, Crashing, [], 1)
  end

  test "large changesets are rejected without invoking a compiler or runtime" do
    changes = List.duplicate(%{op: :put, path: ["x"], value: 1}, 129)
    assert {:error, :invalid_morph_changes} = Morph.prepare(definition(%{}), changes, 1)
  end

  defp definition(body) do
    {:ok, definition} =
      Definition.new(namespace: "morph", name: "plain", revision: 1, declared_at: 0, body: body)

    definition
  end
end
