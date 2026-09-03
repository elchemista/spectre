defmodule Spectre.Constitution do
  @moduledoc """
  Canonical identity for the executable rules supplied to a Domain.

  The rules remain a plain portable map: Spectre does not invent a universal
  policy language. Their canonical reference is named by `Genesis`, which
  prevents a restart from silently substituting different duty or governance
  rules under the same Domain history.
  """

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
  def validate(rules) when is_map(rules) and not is_struct(rules) do
    with :ok <- portable_rules(rules),
         :ok <- validate_duty_rules(rules) do
      :ok
    end
  end

  def validate(_rules), do: {:error, :invalid_constitution}

  @doc "Returns the exact plain value whose digest identifies these rules."
  @spec canonical(map()) :: map()
  def canonical(rules) when is_map(rules) and not is_struct(rules) do
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
  def duty_rule(rules, class) when is_map(rules) and not is_struct(rules) do
    duty_rules = field(rules, :duty_rules, %{})

    if is_map(duty_rules) and not is_struct(duty_rules) do
      Map.get(duty_rules, class) || Map.get(duty_rules, to_string(class)) || %{}
    else
      %{}
    end
  end

  def duty_rule(_rules, _class), do: %{}

  @doc false
  @spec disposition_authority_refs(map(), atom() | String.t()) :: [String.t()]
  def disposition_authority_refs(rules, class) do
    rules
    |> duty_rule(class)
    |> field(:disposition_authority_refs, [])
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
    |> field(:conflict_refs, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

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
      |> field(:duty_rules, %{})
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

  defp validate_duty_rules(rules) do
    case field(rules, :duty_rules, %{}) do
      duty_rules when is_map(duty_rules) and not is_struct(duty_rules) ->
        duty_rules
        |> Enum.reduce_while({:ok, MapSet.new()}, fn {class, rule}, {:ok, seen} ->
          with {:ok, normalized_class} <- configurable_duty_class(class),
               false <- MapSet.member?(seen, normalized_class),
               :ok <- validate_duty_rule(normalized_class, rule) do
            {:cont, {:ok, MapSet.put(seen, normalized_class)}}
          else
            true -> {:halt, {:error, {:duplicate_constitution_duty_rule, class}}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, _seen} -> :ok
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_constitution_duty_rules}
    end
  end

  defp validate_duty_rule(class, rule) do
    if is_map(rule) and not is_struct(rule) do
      validate_duty_rule_fields(class, rule)
    else
      {:error, {:invalid_constitution_duty_rule, class}}
    end
  end

  defp validate_duty_rule_fields(class, rule) do
    authorities = field(rule, :disposition_authority_refs, [])
    cause_sources = field(rule, :cause_source_refs, [])
    conflicts = field(rule, :conflict_refs, [])
    closing = field(rule, :closing_conditions, field(rule, :closure_conditions, []))
    containment = field(rule, :containment, %{})

    cond do
      not is_list(authorities) or
          not Enum.all?(authorities, &(is_binary(&1) and &1 != "")) ->
        {:error, {:invalid_duty_disposition_authorities, class}}

      not is_list(cause_sources) or
          not Enum.all?(cause_sources, &(is_binary(&1) and &1 != "")) ->
        {:error, {:invalid_duty_cause_sources, class}}

      is_binary(class) and cause_sources == [] ->
        {:error, {:application_duty_cause_source_required, class}}

      not is_list(conflicts) or
          not Enum.all?(conflicts, &(is_binary(&1) and &1 != "")) ->
        {:error, {:invalid_duty_conflict_refs, class}}

      not is_list(closing) ->
        {:error, {:invalid_duty_closing_conditions, class}}

      not is_map(containment) or is_struct(containment) ->
        {:error, {:invalid_duty_containment, class}}

      true ->
        :ok
    end
  end

  defp field(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
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
