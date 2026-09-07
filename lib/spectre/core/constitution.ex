defmodule Spectre.Constitution do
  @moduledoc """
  Canonical identity for the executable rules supplied to a Domain.

  The rules remain a plain portable map: Spectre does not invent a universal
  policy language. Their canonical reference is named by `Genesis`, which
  prevents a restart from silently substituting different duty or governance
  rules under the same Domain history.
  """

  require Spectre.Portable

  alias Spectre.{Duty, Portable}

  @schema_version 1
  @discretionary_duty_classes [
    :ambiguous_outcome,
    :contradicted_outcome,
    :disputed_evidence,
    :scope_promise_overdue,
    :erasure_reduces_verifiability
  ]

  @doc "Validates a rule map without granting it authority."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(rules) when Portable.is_plain_map(rules) do
    with :ok <- unique_semantic_keys(rules),
         :ok <- portable_rules(rules) do
      validate_duty_rules(rules)
    end
  end

  def validate(_rules), do: {:error, :invalid_constitution}

  @doc "Returns the exact plain value whose digest identifies these rules."
  @spec canonical(map()) :: map()
  def canonical(rules) when Portable.is_plain_map(rules) do
    %{"schema_version" => @schema_version, "rules" => rules}
  end

  @doc "Returns the content reference that a matching Genesis must name."
  @spec ref(map()) :: {:ok, String.t()} | {:error, term()}
  def ref(rules) do
    with :ok <- validate(rules), do: Portable.content_ref(:constitution, canonical(rules))
  end

  @doc "Returns the content reference or raises for an invalid rule map."
  @spec ref!(map()) :: String.t()
  def ref!(rules) do
    case ref(rules) do
      {:ok, ref} -> ref
      {:error, reason} -> raise ArgumentError, "invalid constitution: #{inspect(reason)}"
    end
  end

  @doc false
  @spec duty_rule(map(), atom() | String.t()) :: map()
  def duty_rule(rules, class) when Portable.is_plain_map(rules) do
    duty_rules = rule_value(rules, :duty_rules, %{})

    if Portable.is_plain_map(duty_rules) do
      Map.get(duty_rules, class) || Map.get(duty_rules, to_string(class)) || %{}
    else
      %{}
    end
  end

  def duty_rule(_rules, _class), do: %{}

  @doc """
  Reads one field from host-authored Constitution configuration.

  Governed records are always structs after replay. Constitution rules remain
  intentionally portable user configuration, so this is the single boundary
  where atom and string keys are accepted. Core modules should not duplicate
  tolerant field lookup for durable records.
  """
  @spec rule_value(map(), atom(), term()) :: term()
  def rule_value(rule, key, default \\ nil)

  def rule_value(rule, key, default)
      when Portable.is_plain_map(rule) and is_atom(key) do
    Map.get(rule, key, Map.get(rule, Atom.to_string(key), default))
  end

  def rule_value(_rule, _key, default), do: default

  @doc false
  @spec disposition_authority_refs(map(), atom() | String.t()) :: [String.t()]
  def disposition_authority_refs(rules, class) do
    rules
    |> duty_rule(class)
    |> rule_value(:disposition_authority_refs, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec conflict_refs(map(), atom() | String.t()) :: [String.t()]
  def conflict_refs(rules, class) do
    rules
    |> duty_rule(class)
    |> rule_value(:conflict_refs, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec emergency_max_duration(map()) :: {:ok, pos_integer()} | {:error, term()}
  def emergency_max_duration(rules) when Portable.is_plain_map(rules) do
    case rule_value(rules, :emergency_max_duration_ms, nil) do
      duration when Portable.is_positive_integer(duration) -> {:ok, duration}
      nil -> {:error, :emergency_max_duration_required}
      _invalid -> {:error, :invalid_emergency_max_duration_ms}
    end
  end

  def emergency_max_duration(_rules), do: {:error, :invalid_constitution}

  @doc false
  @spec validate_duty_routes(map(), [String.t()] | MapSet.t()) :: :ok | {:error, term()}
  def validate_duty_routes(rules, known_authority_refs) do
    known = MapSet.new(known_authority_refs)

    Enum.reduce_while(discretionary_duty_classes(rules), :ok, fn class, :ok ->
      authority_refs = disposition_authority_refs(rules, class)

      cond do
        authority_refs == [] ->
          {:halt, {:error, {:duty_disposition_route_required, class}}}

        invalid = Enum.find(authority_refs, &(not MapSet.member?(known, &1))) ->
          {:halt, {:error, {:duty_disposition_authority_not_found, class, invalid}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp discretionary_duty_classes(rules) do
    configured_classes =
      rules
      |> rule_value(:duty_rules, %{})
      |> Map.keys()
      |> Enum.map(fn class ->
        {:ok, normalized} = configurable_duty_class(class)
        normalized
      end)

    (@discretionary_duty_classes ++ configured_classes)
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
  end

  defp portable_rules(rules) do
    case Portable.validate(rules) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_constitution, reason}}
    end
  end

  defp unique_semantic_keys(rules) do
    case Portable.stringify_atom_keys(rules) do
      {:ok, _normalized} ->
        :ok

      {:error, {:equivalent_map_keys, path}} ->
        {:error, {:constitution_key_collision, path}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_duty_rules(rules) do
    case rule_value(rules, :duty_rules, %{}) do
      duty_rules when Portable.is_plain_map(duty_rules) ->
        duty_rules
        |> Enum.reduce_while({:ok, MapSet.new()}, &validate_unique_duty_rule/2)
        |> case do
          {:ok, _seen} -> :ok
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_constitution_duty_rules}
    end
  end

  defp validate_unique_duty_rule({class, rule}, {:ok, seen}) do
    with {:ok, normalized_class} <- configurable_duty_class(class),
         false <- MapSet.member?(seen, normalized_class),
         :ok <- validate_duty_rule(normalized_class, rule) do
      {:cont, {:ok, MapSet.put(seen, normalized_class)}}
    else
      true -> {:halt, {:error, {:duplicate_constitution_duty_rule, class}}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp validate_duty_rule(class, rule) do
    if Portable.is_plain_map(rule) do
      validate_duty_rule_fields(class, rule)
    else
      {:error, {:invalid_constitution_duty_rule, class}}
    end
  end

  defp validate_duty_rule_fields(class, rule) do
    authorities = rule_value(rule, :disposition_authority_refs, [])
    cause_sources = rule_value(rule, :cause_source_refs, [])
    conflicts = rule_value(rule, :conflict_refs, [])
    closing = rule_value(rule, :closing_conditions, [])
    containment = rule_value(rule, :containment, %{})

    cond do
      not reference_list?(authorities) ->
        {:error, {:invalid_duty_disposition_authorities, class}}

      not reference_list?(cause_sources) ->
        {:error, {:invalid_duty_cause_sources, class}}

      is_binary(class) and cause_sources == [] ->
        {:error, {:application_duty_cause_source_required, class}}

      not reference_list?(conflicts) ->
        {:error, {:invalid_duty_conflict_refs, class}}

      not is_list(closing) ->
        {:error, {:invalid_duty_closing_conditions, class}}

      not Portable.is_plain_map(containment) ->
        {:error, {:invalid_duty_containment, class}}

      true ->
        :ok
    end
  end

  defp reference_list?(values) do
    is_list(values) and Enum.all?(values, &Portable.is_non_empty_binary(&1))
  end

  defp configurable_duty_class(class) do
    with {:ok, normalized} <- Duty.normalize_class(class),
         true <- Duty.configurable_class?(normalized) do
      {:ok, normalized}
    else
      false -> {:error, {:fixed_constitution_duty_class, class}}
      {:error, _reason} -> {:error, {:invalid_constitution_duty_class, Portable.shape(class)}}
    end
  end
end
