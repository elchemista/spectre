defmodule SpectreActionSchemaMatrixTest do
  use ExUnit.Case, async: true

  alias Spectre.Action.Schema

  test "boolean, nullable, type union, const, enum, and primitive schemas are exact" do
    assert Schema.constrained?(true)
    refute Schema.constrained?(:metadata)
    assert :ok = Schema.validate(true, self())
    assert outside([], :false_schema) == Schema.validate(false, :anything)
    assert :ok = Schema.validate(%{nullable: true, type: :string}, nil)

    for {type, value} <- [
          {:object, %{}},
          {:array, []},
          {:string, "text"},
          {:integer, 1},
          {:number, 1.5},
          {:boolean, true},
          {:null, nil}
        ] do
      assert :ok = Schema.validate(%{type: type}, value)
    end

    assert :ok = Schema.validate(%{type: [:string, :null]}, nil)
    assert outside([], :type) == Schema.validate(%{type: [:string, :null]}, 1)
    assert outside([], :const) == Schema.validate(%{const: 1}, 1.0)
    assert :ok = Schema.validate(%{const: 1}, 1)
    assert outside([], :enum) == Schema.validate(%{enum: [1, "one"]}, 1.0)
    assert :ok = Schema.validate(%{enum: [1, "one"]}, "one")
  end

  test "schema definitions reject malformed types, enums, booleans, and combinators" do
    invalid = [
      {%{type: []}, :invalid_type},
      {%{type: [:string, :string]}, {:duplicate_type, "string"}},
      {%{type: :unknown}, :invalid_type},
      {%{enum: []}, :invalid_enum},
      {%{enum: [1, 1]}, :duplicate_enum_value},
      {%{nullable: :yes}, {:invalid_boolean, "nullable"}},
      {%{uniqueItems: :yes}, {:invalid_boolean, "uniqueItems"}},
      {%{minimum: "zero"}, {:invalid_keyword_value, "minimum"}},
      {%{multipleOf: 0}, :invalid_multiple_of},
      {%{minLength: -1}, {:invalid_keyword_value, "minLength"}},
      {%{pattern: "["}, :invalid_pattern},
      {%{allOf: []}, {:invalid_schema_list, "allOf"}},
      {%{anyOf: :invalid}, {:invalid_schema_list, "anyOf"}},
      {%{oneOf: [true, :invalid]}, :schema_must_be_boolean_or_object},
      {%{properties: %{"nested" => :invalid}}, :schema_must_be_boolean_or_object},
      {%{items: :invalid}, :schema_must_be_boolean_or_object},
      {%{not: :invalid}, :schema_must_be_boolean_or_object}
    ]

    Enum.each(invalid, fn {schema, reason} ->
      assert {:error, {:invalid_action_schema, _path, ^reason}} = Schema.validate(schema, nil)
    end)
  end

  test "numeric bounds and integer or floating multipleOf rules report their exact keyword" do
    schema = %{
      type: :number,
      minimum: 1,
      maximum: 10,
      exclusiveMinimum: 0,
      exclusiveMaximum: 11
    }

    assert :ok = Schema.validate(schema, 5)

    for {keyword, limit, value} <- [
          {"minimum", 1, 0},
          {"maximum", 10, 12},
          {"exclusiveMinimum", 0, 0},
          {"exclusiveMaximum", 11, 11}
        ] do
      assert outside([], keyword) == Schema.validate(%{keyword => limit}, value)
    end

    assert :ok = Schema.validate(%{multipleOf: 3}, 9)
    assert outside([], "multipleOf") == Schema.validate(%{multipleOf: 3}, 10)
    assert :ok = Schema.validate(%{multipleOf: 0.1}, 0.3)
    assert outside([], "multipleOf") == Schema.validate(%{multipleOf: 0.2}, 0.3)

    assert {:error, {:invalid_action_schema, [], {:invalid_keyword_value, "minimum"}}} =
             Schema.validate(%{minimum: :zero}, 1)
  end

  test "strings enforce UTF-8, Unicode length, and bounded regular expressions" do
    schema = %{type: :string, minLength: 2, maxLength: 4, pattern: "^[[:alpha:]]+$"}
    assert :ok = Schema.validate(schema, "café")
    assert outside([], "minLength") == Schema.validate(schema, "a")
    assert outside([], "maxLength") == Schema.validate(schema, "abcde")
    assert outside([], "pattern") == Schema.validate(schema, "ab1")
    assert outside([], :utf8) == Schema.validate(%{minLength: 0}, <<255>>)

    assert {:error, {:invalid_action_schema, [], :invalid_pattern}} =
             Schema.validate(%{pattern: 42}, "text")

    assert {:error, {:invalid_action_schema, [], :invalid_pattern}} =
             Schema.validate(%{pattern: String.duplicate("a", 4_097)}, "text")
  end

  test "arrays enforce cardinality, uniqueness, and indexed item paths" do
    schema = %{
      type: :array,
      minItems: 1,
      maxItems: 2,
      uniqueItems: true,
      items: %{type: :integer}
    }

    assert :ok = Schema.validate(schema, [1, 2])
    assert outside([], "minItems") == Schema.validate(schema, [])
    assert outside([], "maxItems") == Schema.validate(schema, [1, 2, 3])
    assert outside([], "uniqueItems") == Schema.validate(schema, [1, 1])
    assert outside([1], :type) == Schema.validate(schema, [1, "two"])
    assert :ok = Schema.validate(%{type: :array, uniqueItems: false}, [1, 1])

    assert {:error, {:invalid_action_schema, [], {:invalid_boolean, "uniqueItems"}}} =
             Schema.validate(%{type: :array, uniqueItems: :yes}, [])
  end

  test "objects normalize logical keys and enforce required, declared, and additional fields" do
    schema = %{
      type: :object,
      minProperties: 1,
      maxProperties: 3,
      required: [:known],
      properties: %{known: %{type: :integer}},
      additionalProperties: %{type: :string}
    }

    assert :ok = Schema.validate(schema, %{"known" => 1, extra: "allowed"})
    assert outside(["known"], :required) == Schema.validate(schema, %{"extra" => "value"})
    assert outside(["known"], :type) == Schema.validate(schema, %{known: "wrong"})
    assert outside(["extra"], :type) == Schema.validate(schema, %{known: 1, extra: 2})
    assert outside([], "minProperties") == Schema.validate(schema, %{})

    assert outside([], "maxProperties") ==
             Schema.validate(schema, %{known: 1, a: "a", b: "b", c: "c"})

    assert outside([], :object_key) == Schema.validate(%{type: :object}, %{1 => "invalid"})

    assert outside(["known"], :duplicate_logical_key) ==
             Schema.validate(%{type: :object}, %{"known" => 2, known: 1})

    assert {:error, {:invalid_action_schema, [], :invalid_properties}} =
             Schema.validate(%{properties: []}, %{})

    assert {:error, {:invalid_action_schema, ["known"], :duplicate_property_name}} =
             Schema.validate(%{properties: %{"known" => true, known: true}}, %{})

    assert {:error, {:invalid_action_schema, [], :invalid_required_property}} =
             Schema.validate(%{required: [1]}, %{})

    assert {:error, {:invalid_action_schema, [], {:duplicate_required_property, "known"}}} =
             Schema.validate(%{required: [:known, "known"]}, %{})

    assert {:error, {:invalid_action_schema, [], :invalid_required}} =
             Schema.validate(%{required: :known}, %{})

    # Optional declared fields may be absent, and both explicit additional
    # property policies must handle an object with no extras.
    assert :ok =
             Schema.validate(
               %{type: :object, properties: %{optional: %{type: :string}}},
               %{}
             )

    assert :ok = Schema.validate(%{type: :object, additionalProperties: true}, %{extra: 1})

    assert :ok =
             Schema.validate(
               %{type: :object, properties: %{known: true}, additionalProperties: false},
               %{known: :value}
             )
  end

  test "allOf, anyOf, oneOf, and not preserve their standard matching cardinality" do
    assert :ok =
             Schema.validate(%{allOf: [%{type: :integer}, %{minimum: 1}]}, 2)

    assert outside([], :type) ==
             Schema.validate(%{allOf: [%{type: :integer}, %{minimum: 1}]}, "two")

    assert :ok =
             Schema.validate(%{anyOf: [%{type: :string}, %{type: :integer}]}, 2)

    assert outside([], "anyOf") ==
             Schema.validate(%{anyOf: [%{type: :string}, %{type: :integer}]}, false)

    assert :ok =
             Schema.validate(%{oneOf: [%{type: :string}, %{type: :integer}]}, 2)

    assert outside([], "oneOf") ==
             Schema.validate(%{oneOf: [%{type: :number}, %{type: :integer}]}, 2)

    assert :ok = Schema.validate(%{not: %{type: :string}}, 2)
    assert outside([], "not") == Schema.validate(%{not: %{type: :string}}, "two")
  end

  test "schema size, depth, keyword names, and collection bounds remain finite" do
    assert {:error, {:invalid_action_schema, [], :non_string_keyword}} =
             Schema.validate(%{nil => true, type: :object}, %{})

    assert {:error, {:invalid_action_schema, [], {:invalid_boolean, "nullable"}}} =
             Schema.validate(%{nullable: :yes}, nil)

    oversized = %{enum: Enum.to_list(1..1_025)}
    assert {:error, {:invalid_action_schema, [], :invalid_enum}} = Schema.validate(oversized, 1)

    too_many_types = %{type: List.duplicate(:string, 17)}

    assert {:error, {:invalid_action_schema, [], :invalid_type}} =
             Schema.validate(too_many_types, "text")

    too_many_branches = %{allOf: List.duplicate(true, 129)}

    assert {:error, {:invalid_action_schema, [], {:invalid_schema_list, "allOf"}}} =
             Schema.validate(too_many_branches, :anything)

    deep = Enum.reduce(1..66, %{type: :string}, fn _level, child -> %{not: child} end)

    assert {:error, {:invalid_action_schema, _path, :maximum_depth_exceeded}} =
             Schema.validate(deep, "text")

    huge = %{description: String.duplicate("x", 256_001), type: :string}

    assert {:error, {:invalid_action_schema, [], {:maximum_size_exceeded, size, 256_000}}} =
             Schema.validate(huge, "text")

    assert size > 256_000
  end

  defp outside(path, rule), do: {:error, {:action_arguments_outside_schema, path, rule}}
end
