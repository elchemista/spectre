defmodule Spectre.Execution.ExpressionTest do
  use ExUnit.Case, async: true

  alias Spectre.Execution.Expression

  test "normalizes every closed expression form without creating atoms" do
    assert {:ok, %{kind: :source, source: :input, path: []}} = Expression.normalize(:input)

    assert {:ok, %{kind: :source, source: :last_result, path: []}} =
             Expression.normalize("last_result")

    assert {:ok, %{kind: :source, source: :state, path: ["items", 0]}} =
             Expression.normalize({:path, "state", [:items, 0]})

    assert {:ok, %{kind: :fixed, value: %{"ready" => true}}} =
             Expression.normalize({:fixed, %{"ready" => true}})

    assert {:ok, object} =
             Expression.normalize(%{
               "kind" => "object",
               "fields" => %{
                 "answer" => %{"kind" => "fixed", "value" => 42},
                 "request" => %{
                   "kind" => "source",
                   "source" => "input",
                   "path" => ["request"]
                 }
               }
             })

    assert object == %{
             kind: :object,
             fields: [
               %{key: "answer", value: %{kind: :fixed, value: 42}},
               %{
                 key: "request",
                 value: %{kind: :source, source: :input, path: ["request"]}
               }
             ]
           }

    assert {:ok, %{kind: :list, items: [^object, %{kind: :source, source: :state, path: []}]}} =
             Expression.normalize(%{"kind" => "list", "items" => [object, "state"]})

    assert {:ok, ^object} = Expression.normalize(object)
  end

  test "evaluates nested map/list paths and composite expressions deterministically" do
    env = %{
      input: %{"request" => [%{answer: 42}]},
      state: %{status: :ready},
      last_result: "previous"
    }

    expression =
      normalize!(%{
        kind: :object,
        fields: %{
          answer: {:path, :input, ["request", 0, :answer]},
          state: :state,
          values: %{kind: :list, items: [:last_result, {:fixed, true}]}
        }
      })

    assert {:ok,
            %{
              "answer" => 42,
              "state" => %{status: :ready},
              "values" => ["previous", true]
            }} = Expression.evaluate(expression, env)

    assert {:error, {:missing_execution_expression_source, :input}} =
             Expression.evaluate(%{kind: :source, source: :input, path: []}, %{})

    assert {:error, {:execution_expression_path_not_found, "missing"}} =
             evaluate_path(env, :input, ["missing"])

    assert {:error, {:execution_expression_path_not_found, 5}} =
             evaluate_path(env, :input, ["request", 5])

    assert {:error, {:execution_expression_path_not_traversable, "child"}} =
             evaluate_path(env, :last_result, ["child"])

    assert {:error, {:execution_expression_path_not_traversable, -1}} =
             evaluate_path(env, :input, ["request", -1])

    assert {:error, {:invalid_execution_expression, :list}} =
             Expression.evaluate([], env)
  end

  test "closed writes preserve existing key types and reject malformed paths" do
    original = %{profile: %{"names" => [%{"value" => "Ada"}]}}

    assert {:ok, %{profile: %{"names" => [%{"value" => "Grace"}]}}} =
             Expression.put(original, [:profile, "names", 0, "value"], "Grace")

    assert {:ok, %{profile: %{"new" => %{"enabled" => true}}}} =
             Expression.put(%{profile: %{}}, [:profile, "new", "enabled"], true)

    assert {:ok, [1, 9, 3]} = Expression.put([1, 2, 3], [1], 9)

    assert {:error, {:execution_write_index_out_of_bounds, 3}} =
             Expression.put([1, 2, 3], [3], 9)

    assert {:error, {:execution_write_path_not_traversable, "child"}} =
             Expression.put(%{"value" => 1}, ["value", "child"], 9)

    assert {:error, {:invalid_execution_write_path, []}} = Expression.put(%{}, [], 1)
    assert {:error, {:invalid_execution_write_path, [-1]}} = Expression.put([1], [-1], 2)
    assert {:error, {:invalid_execution_write_path, [""]}} = Expression.put(%{}, [""], 2)
    assert {:error, {:invalid_execution_write_path, :path}} = Expression.put(%{}, :path, 2)
  end

  test "state paths and authored shapes fail closed" do
    assert {:ok, ["profile", 0]} = Expression.state_path([:profile, 0])
    assert {:error, :execution_path_cannot_be_empty} = Expression.state_path([])
    assert {:error, {:invalid_execution_path, [-1]}} = Expression.state_path([-1])
    assert {:error, {:invalid_execution_path, [nil]}} = Expression.state_path([nil])
    assert {:error, {:invalid_execution_path, :profile}} = Expression.state_path(:profile)

    assert {:error, {:ambiguous_execution_expression_field, :kind}} =
             Expression.normalize(%{"kind" => "list", kind: :fixed, value: 1})

    assert {:error, :execution_fixed_expression_requires_value} =
             Expression.normalize(%{kind: :fixed})

    assert {:error, {:unknown_execution_expression_fields, [:extra]}} =
             Expression.normalize(%{kind: :fixed, value: 1, extra: true})

    assert {:error, {:invalid_execution_expression_source, "unknown"}} =
             Expression.normalize(%{kind: :source, source: "unknown", path: []})

    assert {:error, {:invalid_execution_expression_source, 1}} =
             Expression.normalize({:path, 1, []})

    assert {:error, {:invalid_execution_object_field, 0, :not_a_map}} =
             Expression.normalize(%{kind: :object, fields: [:not_a_field]})

    assert {:error, {:invalid_execution_object_fields, :atom}} =
             Expression.normalize(%{kind: :object, fields: :not_fields})

    assert {:error, {:invalid_execution_object_key, ""}} =
             Expression.normalize(%{kind: :object, fields: %{"" => {:fixed, 1}}})

    assert {:error, :duplicate_execution_object_key} =
             Expression.normalize(%{
               kind: :object,
               fields: [
                 %{key: :answer, value: {:fixed, 1}},
                 %{"key" => "answer", "value" => {:fixed, 2}}
               ]
             })

    assert {:error,
            {:invalid_execution_object_field, 0, {:unknown_execution_expression_fields, [:extra]}}} =
             Expression.normalize(%{
               kind: :object,
               fields: [%{key: "answer", value: {:fixed, 1}, extra: true}]
             })

    assert {:error, {:invalid_execution_list_items, :map}} =
             Expression.normalize(%{kind: :list, items: %{}})

    assert {:error, {:invalid_execution_list_item, 1, {:invalid_execution_expression, :other}}} =
             Expression.normalize(%{kind: :list, items: [{:fixed, 1}, self()]})

    assert {:error, {:invalid_execution_expression_kind, "call"}} =
             Expression.normalize(%{kind: "call"})

    assert {:error, {:invalid_execution_expression_kind, nil}} = Expression.normalize(%{})
    assert {:error, {:invalid_execution_expression, :tuple}} = Expression.normalize({:call, :x})
  end

  test "fixed literals reject Elixir modules, Erlang modules, MFAs and nonportable terms" do
    assert {:error, {:module_execution_literal, []}} = Expression.normalize({:fixed, System})
    assert {:error, {:module_execution_literal, []}} = Expression.normalize({:fixed, :os})

    assert {:error, {:executable_execution_literal, []}} =
             Expression.normalize({:fixed, {System, :cmd}})

    assert {:error, {:executable_execution_literal, []}} =
             Expression.normalize({:fixed, {:os, :cmd}})

    assert {:error, {:module_execution_literal, ["nested", 0]}} =
             Expression.normalize({:fixed, %{"nested" => [System]}})

    assert {:error, {:nonportable_execution_literal, _reason}} =
             Expression.normalize({:fixed, self()})
  end

  defp evaluate_path(env, source, path) do
    Expression.evaluate(%{kind: :source, source: source, path: path}, env)
  end

  defp normalize!(value) do
    {:ok, expression} = Expression.normalize(value)
    expression
  end
end
