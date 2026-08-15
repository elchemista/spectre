# JSON Schema traversal mirrors a recursively nested external document. Keeping
# each keyword's validation beside its child traversal makes error paths
# auditable; flattening these branches would obscure which schema edge failed.
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Spectre.Action.Schema do
  @moduledoc """
  Bounded JSON-Schema subset used at the action capability boundary.

  Action providers historically used `schema` for discovery metadata such as
  `arity` and `version`. Those maps remain unconstrained. As soon as a schema
  declares a validation keyword, every constraint must belong to the supported
  vocabulary; unknown constraints fail closed instead of being ignored.

  The validator deliberately returns paths and rule names, never rejected
  values, so telemetry and errors cannot accidentally disclose action payloads.
  """

  @max_depth 64
  @max_schema_bytes 256_000
  @max_properties 1_024
  @max_required_properties 1_024
  @max_enum_values 1_024
  @max_type_variants 16
  @max_combinator_branches 128
  @max_pattern_bytes 4_096
  @regex_match_limit 100_000
  @regex_recursion_limit 10_000

  @validation_keywords MapSet.new(~w(
    type nullable enum const
    properties required additionalProperties minProperties maxProperties
    items minItems maxItems uniqueItems
    minLength maxLength pattern
    minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
    allOf anyOf oneOf not
  ))

  @annotation_keywords MapSet.new(~w(
    $schema $id $comment title description default examples deprecated readOnly writeOnly
    arity version
  ))

  @allowed_keywords MapSet.union(@validation_keywords, @annotation_keywords)
  @schema_signal_keywords MapSet.union(
                            @validation_keywords,
                            MapSet.new(~w(
                              $schema $id $ref $defs definitions format
                              patternProperties dependentRequired dependentSchemas
                              unevaluatedProperties contains minContains maxContains
                            ))
                          )
  @types ~w(object array string integer number boolean null)

  @type path :: [String.t() | non_neg_integer()]

  @doc "Returns whether a value declares at least one supported validation keyword."
  @spec constrained?(term()) :: boolean()
  def constrained?(schema) when is_boolean(schema), do: true

  def constrained?(schema) when is_map(schema) and not is_struct(schema) do
    Enum.any?(Map.keys(schema), fn key ->
      key |> normalized_key() |> then(&MapSet.member?(@schema_signal_keywords, &1))
    end)
  end

  def constrained?(_schema), do: false

  @doc false
  @spec rejects_additional_properties?(term()) :: boolean()
  def rejects_additional_properties?(false), do: true

  def rejects_additional_properties?(schema) when is_map(schema) and not is_struct(schema) do
    values =
      schema
      |> Enum.filter(fn {key, _value} -> normalized_key(key) == "additionalProperties" end)
      |> Enum.map(&elem(&1, 1))

    values == [false]
  end

  def rejects_additional_properties?(_schema), do: false

  @doc "Validates action arguments without evaluating code or resolving remote refs."
  @spec validate(term(), term()) :: :ok | {:error, term()}
  def validate(schema, value) do
    if constrained?(schema) do
      with :ok <- validate_schema_size(schema),
           :ok <- validate_definition(schema, [], 0) do
        validate_node(schema, value, [], 0)
      end
    else
      :ok
    end
  end

  defp validate_definition(_schema, path, depth) when depth > @max_depth,
    do: schema_error(path, :maximum_depth_exceeded)

  defp validate_definition(schema, _path, _depth) when is_boolean(schema), do: :ok

  defp validate_definition(schema, path, depth)
       when is_map(schema) and not is_struct(schema) do
    with :ok <- validate_schema_keys(schema, path),
         :ok <- validate_type_definition(schema, path),
         :ok <- validate_enum_definition(schema, path),
         :ok <- validate_boolean_definition(schema, path),
         :ok <- validate_numeric_definition(schema, path),
         :ok <- validate_length_definition(schema, path),
         :ok <- validate_pattern_definition(schema, path),
         {:ok, properties} <- properties(schema, path),
         :ok <- validate_property_definitions(properties, path, depth),
         {:ok, _required} <- required_properties(schema, path),
         :ok <- validate_single_schema_keyword(schema, "additionalProperties", path, depth),
         :ok <- validate_single_schema_keyword(schema, "items", path, depth),
         :ok <- validate_single_schema_keyword(schema, "not", path, depth),
         :ok <- validate_schema_list_definition(schema, "allOf", path, depth),
         :ok <- validate_schema_list_definition(schema, "anyOf", path, depth) do
      validate_schema_list_definition(schema, "oneOf", path, depth)
    end
  end

  defp validate_definition(_schema, path, _depth),
    do: schema_error(path, :schema_must_be_boolean_or_object)

  defp validate_type_definition(schema, path) do
    case fetch(schema, "type") do
      :error ->
        :ok

      {:ok, declared} ->
        case normalize_types(declared, path) do
          {:ok, _types} -> :ok
          error -> error
        end
    end
  end

  defp validate_enum_definition(schema, path) do
    case fetch(schema, "enum") do
      :error ->
        :ok

      {:ok, values}
      when is_list(values) and values != [] and length(values) <= @max_enum_values ->
        if length(Enum.uniq(values)) == length(values),
          do: :ok,
          else: schema_error(path, :duplicate_enum_value)

      {:ok, _invalid} ->
        schema_error(path, :invalid_enum)
    end
  end

  defp validate_boolean_definition(schema, path) do
    Enum.reduce_while(["nullable", "uniqueItems"], :ok, fn keyword, :ok ->
      case fetch(schema, keyword) do
        :error -> {:cont, :ok}
        {:ok, value} when is_boolean(value) -> {:cont, :ok}
        {:ok, _invalid} -> {:halt, schema_error(path, {:invalid_boolean, keyword})}
      end
    end)
  end

  defp validate_numeric_definition(schema, path) do
    keywords = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"]

    with :ok <- validate_keyword_values(schema, keywords, path, &is_number/1) do
      case fetch(schema, "multipleOf") do
        :error -> :ok
        {:ok, value} when is_number(value) and value > 0 -> :ok
        {:ok, _invalid} -> schema_error(path, :invalid_multiple_of)
      end
    end
  end

  defp validate_length_definition(schema, path) do
    validate_keyword_values(
      schema,
      ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"],
      path,
      &(is_integer(&1) and &1 >= 0)
    )
  end

  defp validate_keyword_values(schema, keywords, path, predicate) do
    Enum.reduce_while(keywords, :ok, fn keyword, :ok ->
      case fetch(schema, keyword) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          if predicate.(value),
            do: {:cont, :ok},
            else: {:halt, schema_error(path, {:invalid_keyword_value, keyword})}
      end
    end)
  end

  defp validate_pattern_definition(schema, path) do
    case fetch(schema, "pattern") do
      :error ->
        :ok

      {:ok, pattern} when is_binary(pattern) and byte_size(pattern) <= @max_pattern_bytes ->
        case Regex.compile(pattern, "u") do
          {:ok, _regex} -> :ok
          {:error, _reason} -> schema_error(path, :invalid_pattern)
        end

      {:ok, _invalid} ->
        schema_error(path, :invalid_pattern)
    end
  end

  defp validate_property_definitions(properties, path, depth) do
    Enum.reduce_while(properties, :ok, fn {name, child}, :ok ->
      case validate_definition(child, path ++ [name], depth + 1) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_single_schema_keyword(schema, keyword, path, depth) do
    case fetch(schema, keyword) do
      :error -> :ok
      {:ok, value} when keyword == "additionalProperties" and is_boolean(value) -> :ok
      {:ok, child} -> validate_definition(child, path ++ [keyword], depth + 1)
    end
  end

  defp validate_schema_list_definition(schema, keyword, path, depth) do
    case fetch(schema, keyword) do
      :error ->
        :ok

      {:ok, schemas}
      when is_list(schemas) and schemas != [] and
             length(schemas) <= @max_combinator_branches ->
        schemas
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
          case validate_definition(child, path ++ [keyword, index], depth + 1) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:ok, _invalid} ->
        schema_error(path, {:invalid_schema_list, keyword})
    end
  end

  defp validate_node(_schema, _value, path, depth) when depth > @max_depth,
    do: schema_error(path, :maximum_depth_exceeded)

  defp validate_node(true, _value, _path, _depth), do: :ok
  defp validate_node(false, _value, path, _depth), do: value_error(path, :false_schema)

  defp validate_node(schema, value, path, depth)
       when is_map(schema) and not is_struct(schema) do
    with :ok <- validate_schema_keys(schema, path),
         {:ok, nullable?} <- boolean_keyword(schema, "nullable", false, path),
         :cont <- nullable(value, nullable?),
         :ok <- validate_type(schema, value, path),
         :ok <- validate_const(schema, value, path),
         :ok <- validate_enum(schema, value, path),
         :ok <- validate_number(schema, value, path),
         :ok <- validate_string(schema, value, path),
         :ok <- validate_array(schema, value, path, depth),
         :ok <- validate_object(schema, value, path, depth),
         :ok <- validate_all_of(schema, value, path, depth),
         :ok <- validate_any_of(schema, value, path, depth),
         :ok <- validate_one_of(schema, value, path, depth),
         :ok <- validate_not(schema, value, path, depth) do
      :ok
    else
      :nullable -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_node(_schema, _value, path, _depth),
    do: schema_error(path, :schema_must_be_boolean_or_object)

  defp nullable(nil, true), do: :nullable
  defp nullable(_value, _nullable?), do: :cont

  defp validate_schema_keys(schema, path) do
    Enum.reduce_while(Map.keys(schema), {:ok, MapSet.new()}, fn key, {:ok, seen} ->
      case normalized_key(key) do
        nil ->
          {:halt, schema_error(path, :non_string_keyword)}

        name ->
          cond do
            MapSet.member?(seen, name) ->
              {:halt, schema_error(path, {:duplicate_keyword, name})}

            not MapSet.member?(@allowed_keywords, name) ->
              {:halt, schema_error(path, {:unsupported_keyword, name})}

            true ->
              {:cont, {:ok, MapSet.put(seen, name)}}
          end
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_type(schema, value, path) do
    case fetch(schema, "type") do
      :error ->
        :ok

      {:ok, declared} ->
        with {:ok, types} <- normalize_types(declared, path) do
          if Enum.any?(types, &type_matches?(&1, value)),
            do: :ok,
            else: value_error(path, :type)
        end
    end
  end

  defp normalize_types(types, path)
       when is_list(types) and types != [] and length(types) <= @max_type_variants do
    Enum.reduce_while(types, {:ok, []}, fn type, {:ok, normalized} ->
      case normalize_type(type) do
        {:ok, type} ->
          if type in normalized,
            do: {:halt, schema_error(path, {:duplicate_type, type})},
            else: {:cont, {:ok, [type | normalized]}}

        :error ->
          {:halt, schema_error(path, :invalid_type)}
      end
    end)
  end

  defp normalize_types(type, path) do
    case normalize_type(type) do
      {:ok, type} -> {:ok, [type]}
      :error -> schema_error(path, :invalid_type)
    end
  end

  defp normalize_type(type) when is_atom(type), do: normalize_type(Atom.to_string(type))
  defp normalize_type(type) when type in @types, do: {:ok, type}
  defp normalize_type(_type), do: :error

  defp type_matches?("object", value), do: is_map(value) and not is_struct(value)
  defp type_matches?("array", value), do: is_list(value)
  defp type_matches?("string", value), do: is_binary(value) and String.valid?(value)
  defp type_matches?("integer", value), do: is_integer(value)
  defp type_matches?("number", value), do: is_number(value)
  defp type_matches?("boolean", value), do: is_boolean(value)
  defp type_matches?("null", value), do: is_nil(value)

  defp validate_const(schema, value, path) do
    case fetch(schema, "const") do
      :error -> :ok
      {:ok, expected} when expected === value -> :ok
      {:ok, _expected} -> value_error(path, :const)
    end
  end

  defp validate_enum(schema, value, path) do
    case fetch(schema, "enum") do
      :error ->
        :ok

      {:ok, values}
      when is_list(values) and values != [] and length(values) <= @max_enum_values ->
        if Enum.any?(values, &(&1 === value)), do: :ok, else: value_error(path, :enum)

      {:ok, _invalid} ->
        schema_error(path, :invalid_enum)
    end
  end

  defp validate_number(schema, value, path) when is_number(value) do
    with :ok <- compare_limit(schema, "minimum", value, path, &>=/2),
         :ok <- compare_limit(schema, "maximum", value, path, &<=/2),
         :ok <- compare_limit(schema, "exclusiveMinimum", value, path, &>/2),
         :ok <- compare_limit(schema, "exclusiveMaximum", value, path, &</2) do
      validate_multiple_of(schema, value, path)
    end
  end

  defp validate_number(_schema, _value, _path), do: :ok

  defp compare_limit(schema, keyword, value, path, comparison) do
    case fetch(schema, keyword) do
      :error ->
        :ok

      {:ok, limit} when is_number(limit) ->
        if comparison.(value, limit), do: :ok, else: value_error(path, keyword)

      {:ok, _invalid} ->
        schema_error(path, {:invalid_numeric_limit, keyword})
    end
  end

  defp validate_multiple_of(schema, value, path) do
    case fetch(schema, "multipleOf") do
      :error ->
        :ok

      {:ok, divisor} when is_integer(value) and is_integer(divisor) and divisor > 0 ->
        if rem(value, divisor) == 0,
          do: :ok,
          else: value_error(path, "multipleOf")

      {:ok, divisor} when is_number(divisor) and divisor > 0 ->
        try do
          quotient = value / divisor
          tolerance = max(abs(quotient), 1.0) * 1.0e-12

          if abs(quotient - Float.round(quotient)) <= tolerance,
            do: :ok,
            else: value_error(path, "multipleOf")
        rescue
          ArithmeticError -> value_error(path, "multipleOf")
        end

      {:ok, _invalid} ->
        schema_error(path, :invalid_multiple_of)
    end
  end

  defp validate_string(schema, value, path) when is_binary(value) do
    if String.valid?(value) do
      with :ok <- length_limit(schema, "minLength", String.length(value), path, &>=/2),
           :ok <- length_limit(schema, "maxLength", String.length(value), path, &<=/2) do
        validate_pattern(schema, value, path)
      end
    else
      value_error(path, :utf8)
    end
  end

  defp validate_string(_schema, _value, _path), do: :ok

  defp validate_pattern(schema, value, path) do
    case fetch(schema, "pattern") do
      :error ->
        :ok

      {:ok, pattern} when is_binary(pattern) and byte_size(pattern) <= @max_pattern_bytes ->
        case Regex.compile(pattern, "u") do
          {:ok, regex} -> validate_regex_match(regex, value, path)
          {:error, _reason} -> schema_error(path, :invalid_pattern)
        end

      {:ok, _invalid} ->
        schema_error(path, :invalid_pattern)
    end
  end

  defp validate_array(schema, value, path, depth) when is_list(value) do
    with :ok <- length_limit(schema, "minItems", length(value), path, &>=/2),
         :ok <- length_limit(schema, "maxItems", length(value), path, &<=/2),
         :ok <- validate_unique_items(schema, value, path) do
      validate_items(schema, value, path, depth)
    end
  end

  defp validate_array(_schema, _value, _path, _depth), do: :ok

  defp validate_unique_items(schema, value, path) do
    case fetch(schema, "uniqueItems") do
      :error ->
        :ok

      {:ok, false} ->
        :ok

      {:ok, true} ->
        if length(Enum.uniq(value)) == length(value),
          do: :ok,
          else: value_error(path, "uniqueItems")

      {:ok, _invalid} ->
        schema_error(path, :invalid_unique_items)
    end
  end

  defp validate_items(schema, values, path, depth) do
    case fetch(schema, "items") do
      :error ->
        :ok

      {:ok, item_schema} ->
        values
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
          case validate_node(item_schema, value, path ++ [index], depth + 1) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp validate_object(schema, value, path, depth)
       when is_map(value) and not is_struct(value) do
    with {:ok, entries} <- object_entries(value, path),
         :ok <- length_limit(schema, "minProperties", map_size(value), path, &>=/2),
         :ok <- length_limit(schema, "maxProperties", map_size(value), path, &<=/2),
         {:ok, properties} <- properties(schema, path),
         {:ok, required} <- required_properties(schema, path),
         :ok <- validate_required(entries, required, path),
         :ok <- validate_declared_properties(entries, properties, path, depth) do
      validate_additional_properties(schema, entries, properties, path, depth)
    end
  end

  defp validate_object(_schema, _value, _path, _depth), do: :ok

  defp object_entries(value, path) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, entry}, {:ok, entries} ->
      case normalized_key(key) do
        nil ->
          {:halt, value_error(path, :object_key)}

        name ->
          if Map.has_key?(entries, name) do
            {:halt, value_error(path ++ [name], :duplicate_logical_key)}
          else
            {:cont, {:ok, Map.put(entries, name, entry)}}
          end
      end
    end)
  end

  defp properties(schema, path) do
    case fetch(schema, "properties") do
      :error ->
        {:ok, %{}}

      {:ok, properties}
      when is_map(properties) and not is_struct(properties) and
             map_size(properties) <= @max_properties ->
        Enum.reduce_while(properties, {:ok, %{}}, fn {key, property_schema}, {:ok, acc} ->
          case normalized_key(key) do
            nil ->
              {:halt, schema_error(path, :invalid_property_name)}

            name ->
              if Map.has_key?(acc, name),
                do: {:halt, schema_error(path ++ [name], :duplicate_property_name)},
                else: {:cont, {:ok, Map.put(acc, name, property_schema)}}
          end
        end)

      {:ok, _invalid} ->
        schema_error(path, :invalid_properties)
    end
  end

  defp required_properties(schema, path) do
    case fetch(schema, "required") do
      :error ->
        {:ok, []}

      {:ok, required}
      when is_list(required) and length(required) <= @max_required_properties ->
        Enum.reduce_while(required, {:ok, []}, fn key, {:ok, acc} ->
          case normalized_key(key) do
            nil ->
              {:halt, schema_error(path, :invalid_required_property)}

            name ->
              if name in acc,
                do: {:halt, schema_error(path, {:duplicate_required_property, name})},
                else: {:cont, {:ok, [name | acc]}}
          end
        end)

      {:ok, _invalid} ->
        schema_error(path, :invalid_required)
    end
  end

  defp validate_required(entries, required, path) do
    case Enum.find(required, &(not Map.has_key?(entries, &1))) do
      nil -> :ok
      missing -> value_error(path ++ [missing], :required)
    end
  end

  defp validate_declared_properties(entries, properties, path, depth) do
    Enum.reduce_while(properties, :ok, fn {name, property_schema}, :ok ->
      case Map.fetch(entries, name) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          case validate_node(property_schema, value, path ++ [name], depth + 1) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp validate_additional_properties(schema, entries, properties, path, depth) do
    additional = Map.drop(entries, Map.keys(properties))

    case fetch(schema, "additionalProperties") do
      :error ->
        :ok

      {:ok, true} ->
        :ok

      {:ok, false} ->
        case Map.keys(additional) do
          [] -> :ok
          [name | _rest] -> value_error(path ++ [name], :additional_property)
        end

      {:ok, additional_schema} ->
        Enum.reduce_while(additional, :ok, fn {name, value}, :ok ->
          case validate_node(additional_schema, value, path ++ [name], depth + 1) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp validate_all_of(schema, value, path, depth) do
    validate_schema_list(schema, "allOf", path, fn schemas ->
      Enum.reduce_while(schemas, :ok, fn child, :ok ->
        case validate_node(child, value, path, depth + 1) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end)
  end

  defp validate_any_of(schema, value, path, depth) do
    validate_schema_list(schema, "anyOf", path, fn schemas ->
      if Enum.any?(schemas, &match?(:ok, validate_node(&1, value, path, depth + 1))),
        do: :ok,
        else: value_error(path, "anyOf")
    end)
  end

  defp validate_one_of(schema, value, path, depth) do
    validate_schema_list(schema, "oneOf", path, fn schemas ->
      matches = Enum.count(schemas, &match?(:ok, validate_node(&1, value, path, depth + 1)))
      if matches == 1, do: :ok, else: value_error(path, "oneOf")
    end)
  end

  defp validate_not(schema, value, path, depth) do
    case fetch(schema, "not") do
      :error ->
        :ok

      {:ok, child} ->
        if match?(:ok, validate_node(child, value, path, depth + 1)),
          do: value_error(path, "not"),
          else: :ok
    end
  end

  defp validate_schema_list(schema, keyword, path, callback) do
    case fetch(schema, keyword) do
      :error ->
        :ok

      {:ok, schemas}
      when is_list(schemas) and schemas != [] and
             length(schemas) <= @max_combinator_branches ->
        callback.(schemas)

      {:ok, _invalid} ->
        schema_error(path, {:invalid_schema_list, keyword})
    end
  end

  defp length_limit(schema, keyword, actual, path, comparison) do
    case fetch(schema, keyword) do
      :error ->
        :ok

      {:ok, limit} when is_integer(limit) and limit >= 0 ->
        if comparison.(actual, limit), do: :ok, else: value_error(path, keyword)

      {:ok, _invalid} ->
        schema_error(path, {:invalid_length_limit, keyword})
    end
  end

  defp boolean_keyword(schema, keyword, default, path) do
    case fetch(schema, keyword) do
      :error -> {:ok, default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _invalid} -> schema_error(path, {:invalid_boolean, keyword})
    end
  end

  defp validate_schema_size(schema) do
    size = :erlang.external_size(schema)

    if size <= @max_schema_bytes,
      do: :ok,
      else: schema_error([], {:maximum_size_exceeded, size, @max_schema_bytes})
  rescue
    _exception -> schema_error([], :size_validation_failed)
  end

  defp validate_regex_match(%Regex{re_pattern: compiled}, value, path) do
    options = [
      {:capture, :none},
      {:match_limit, @regex_match_limit},
      {:match_limit_recursion, @regex_recursion_limit}
    ]

    case :re.run(value, compiled, options) do
      :match -> :ok
      :nomatch -> value_error(path, "pattern")
      {:error, _reason} -> value_error(path, :pattern_evaluation_limit)
    end
  end

  defp fetch(map, name) do
    Enum.find_value(map, :error, fn {key, value} ->
      if normalized_key(key) == name, do: {:ok, value}, else: false
    end)
  end

  defp normalized_key(key) when is_binary(key) and key != "" do
    if String.valid?(key), do: key, else: nil
  end

  defp normalized_key(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp normalized_key(_key), do: nil

  defp schema_error(path, reason), do: {:error, {:invalid_action_schema, path, reason}}

  defp value_error(path, rule),
    do: {:error, {:action_arguments_outside_schema, path, rule}}
end
