defmodule Spectre.Governance.ChangeSet.Registry do
  @moduledoc """
  Host-owned registry mapping inert ChangeSet operation types to reviewed code.

  Registration accepts modules, never runtime data. This keeps the vocabulary
  extensible without a central dispatch `case` and without permitting a
  ChangeSet to choose an arbitrary handler.
  """

  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition

  @risk_order %{low: 0, medium: 1, high: 2, critical: 3}
  @max_operations 256

  @builtin_handlers [
    Spectre.Governance.ChangeSet.Handlers.Skill,
    Spectre.Governance.ChangeSet.Handlers.EvalCase,
    Spectre.Governance.ChangeSet.Handlers.StateMigration
  ]

  @enforce_keys [:entries]
  defstruct entries: %{}

  @type entry :: %{handler: module(), component_classes: [atom()]}
  @type t :: %__MODULE__{entries: %{optional(String.t()) => entry()}}

  @doc "Returns the reviewed built-in 0.2.9 vocabulary."
  @spec default() :: t()
  def default, do: new!(@builtin_handlers)

  @doc "Builds a registry from compiled handler modules."
  @spec new([module()]) :: {:ok, t()} | {:error, term()}
  def new(handlers) when is_list(handlers) do
    Enum.reduce_while(handlers, {:ok, %__MODULE__{entries: %{}}}, fn handler, {:ok, registry} ->
      case register(registry, handler) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def new(value), do: {:error, {:invalid_governance_handler_registry, shape(value)}}

  @doc "Builds a registry or raises with the stable validation reason."
  @spec new!([module()]) :: t()
  def new!(handlers) do
    case new(handlers) do
      {:ok, registry} ->
        registry

      {:error, reason} ->
        raise ArgumentError, "invalid ChangeSet handler registry: #{inspect(reason)}"
    end
  end

  @doc "Registers one loaded reviewed handler."
  @spec register(t(), module()) :: {:ok, t()} | {:error, term()}
  def register(%__MODULE__{} = registry, handler) when is_atom(handler) and not is_nil(handler) do
    with :ok <- ensure_handler(handler),
         {:ok, types} <- handler_types(handler),
         {:ok, classes} <- handler_classes(handler),
         :ok <- ensure_available(registry, types) do
      entry = %{handler: handler, component_classes: classes}
      entries = Enum.reduce(types, registry.entries, &Map.put(&2, &1, entry))
      {:ok, %{registry | entries: entries}}
    end
  end

  def register(%__MODULE__{}, value),
    do: {:error, {:invalid_governance_handler, value}}

  @doc "Applies operations in order through their registered handlers."
  @spec apply(t(), [Operation.t()], Composition.t(), map()) ::
          {:ok, Composition.t()} | {:error, term()}
  def apply(%__MODULE__{} = registry, operations, %Composition{} = composition, context)
      when is_list(operations) and length(operations) <= @max_operations and is_map(context) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, composition}, fn {operation, index}, {:ok, current} ->
      case apply_one(registry, operation, current, context) do
        {:ok, %Composition{} = next} ->
          {:cont, {:ok, next}}

        {:ok, value} ->
          {:halt, {:error, {:invalid_governance_handler_result, index, shape(value)}}}

        {:error, reason} ->
          {:halt, {:error, {:governance_operation_failed, index, reason}}}
      end
    end)
  end

  def apply(%__MODULE__{}, _operations, _composition, _context),
    do: {:error, :invalid_governance_registry_application}

  defp apply_one(registry, %Operation{type: type} = operation, composition, context) do
    case Map.fetch(registry.entries, type) do
      {:ok, entry} ->
        with {:ok, %Composition{} = next} <-
               invoke(
                 entry.handler,
                 operation,
                 composition,
                 Map.put(context, :component_classes, entry.component_classes)
               ),
             :ok <- declared_component_classes(entry, operation, composition, next) do
          {:ok, next}
        end

      :error ->
        {:error, {:unregistered_governance_operation, type}}
    end
  end

  defp apply_one(_registry, value, _composition, _context),
    do: {:error, {:invalid_governance_operation, shape(value)}}

  defp invoke(handler, operation, composition, context) do
    handler.apply(operation, composition, context)
  rescue
    exception -> {:error, {:governance_handler_exception, handler, exception.__struct__}}
  catch
    kind, reason -> {:error, {:governance_handler_failure, handler, kind, reason}}
  end

  defp declared_component_classes(entry, operation, previous, next) do
    with :ok <- unchanged_definition_envelope(previous.definition, next.definition),
         {:ok, actual} <- actual_component_changes(previous, next),
         :ok <- monotonic_composition_metadata(operation, previous, next, actual) do
      claimed = next.changed_components -- previous.changed_components

      case Enum.uniq(actual ++ claimed) -- entry.component_classes do
        [] -> :ok
        undeclared -> {:error, {:governance_handler_undeclared_component_classes, undeclared}}
      end
    end
  end

  defp unchanged_definition_envelope(previous, next) do
    previous_header = previous |> Map.from_struct() |> Map.delete(:components)
    next_header = next |> Map.from_struct() |> Map.delete(:components)

    if previous_header == next_header,
      do: :ok,
      else: {:error, :governance_handler_changed_definition_envelope}
  end

  defp actual_component_changes(previous, next) do
    previous_components = Map.new(previous.definition.components, &{&1.component_type, &1})
    next_components = Map.new(next.definition.components, &{&1.component_type, &1})

    definition_changes =
      (Map.keys(previous_components) ++ Map.keys(next_components))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(previous_components, &1) != Map.get(next_components, &1)))

    changes =
      definition_changes
      |> maybe_add(previous.eval_cases != next.eval_cases, :candidate_eval_cases)
      |> maybe_add(previous.state_migrations != next.state_migrations, :state_migrations)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, changes}
  end

  defp monotonic_composition_metadata(operation, previous, next, actual) do
    cond do
      previous.changed_components -- next.changed_components != [] ->
        {:error, :governance_handler_removed_change_evidence}

      actual -- next.changed_components != [] ->
        {:error,
         {:governance_handler_unreported_component_classes, actual -- next.changed_components}}

      next.operation_types != previous.operation_types ++ [operation.type] ->
        {:error, :governance_handler_operation_lineage_mismatch}

      not Map.has_key?(@risk_order, previous.risk) or not Map.has_key?(@risk_order, next.risk) ->
        {:error, :governance_handler_invalid_risk}

      Map.fetch!(@risk_order, next.risk) < Map.fetch!(@risk_order, previous.risk) ->
        {:error, :governance_handler_lowered_risk}

      true ->
        :ok
    end
  end

  defp maybe_add(values, true, value), do: [value | values]
  defp maybe_add(values, false, _value), do: values

  defp ensure_handler(handler) do
    cond do
      not Code.ensure_loaded?(handler) ->
        {:error, {:governance_handler_not_loaded, handler}}

      missing =
          Enum.find([operation_types: 0, component_classes: 0, apply: 3], fn {function, arity} ->
            not function_exported?(handler, function, arity)
          end) ->
        {function, arity} = missing
        {:error, {:governance_handler_callback_missing, handler, function, arity}}

      true ->
        :ok
    end
  end

  defp handler_types(handler) do
    case handler.operation_types() do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &valid_type?/1) and length(Enum.uniq(values)) == length(values),
          do: {:ok, values},
          else: {:error, {:invalid_governance_handler_types, handler}}

      _value ->
        {:error, {:invalid_governance_handler_types, handler}}
    end
  rescue
    exception -> {:error, {:governance_handler_exception, handler, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:governance_handler_failure, handler, :operation_types, kind, reason}}
  end

  defp handler_classes(handler) do
    case handler.component_classes() do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_atom(&1) and not is_nil(&1))),
          do: {:ok, values |> Enum.uniq() |> Enum.sort()},
          else: {:error, {:invalid_governance_handler_classes, handler}}

      _value ->
        {:error, {:invalid_governance_handler_classes, handler}}
    end
  rescue
    exception -> {:error, {:governance_handler_exception, handler, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:governance_handler_failure, handler, :component_classes, kind, reason}}
  end

  defp ensure_available(registry, types) do
    case Enum.find(types, &Map.has_key?(registry.entries, &1)) do
      nil -> :ok
      duplicate -> {:error, {:duplicate_governance_operation_handler, duplicate}}
    end
  end

  defp valid_type?(value) when is_binary(value) and value != "",
    do: Regex.match?(~r/^[a-z][a-z0-9_]{0,63}\z/, value)

  defp valid_type?(_value), do: false

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
