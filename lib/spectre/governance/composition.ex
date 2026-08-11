defmodule Spectre.Governance.Composition do
  @moduledoc """
  Accumulates the typed result of applying governed ChangeSet operations.

  Registered `Spectre.Governance.ChangeSet.Handler` implementations receive a
  Composition and return its next immutable value. The struct records the
  candidate Definition, evaluation obligations, state migrations, affected
  component classes, operation vocabulary, and maximum risk observed so far.

  A Composition is transient governance state. It is never an activation,
  authority grant, or durable Candidate by itself.
  """

  alias Spectre.Definition.Canonical

  @risk_order %{low: 0, medium: 1, high: 2, critical: 3}

  @typedoc "The highest governance risk contributed by applied operations."
  @type risk :: :low | :medium | :high | :critical

  @enforce_keys [
    :definition,
    :eval_cases,
    :state_migrations,
    :risk,
    :changed_components,
    :operation_types
  ]
  defstruct definition: nil,
            eval_cases: [],
            state_migrations: [],
            risk: :low,
            changed_components: [],
            operation_types: []

  @type t :: %__MODULE__{
          definition: Canonical.t(),
          eval_cases: [map()],
          state_migrations: [map()],
          risk: risk(),
          changed_components: [atom()],
          operation_types: [String.t()]
        }

  @doc "Creates an empty composition rooted in the supplied Definition."
  @spec new(Canonical.t()) :: t()
  def new(%Canonical{} = definition) do
    %__MODULE__{
      definition: definition,
      eval_cases: [],
      state_migrations: [],
      risk: :low,
      changed_components: [],
      operation_types: []
    }
  end

  @doc """
  Applies one validated handler result to the composition.

  `:operation_type` is required. A handler may also provide a replacement
  Definition, one evaluation case, one state migration, component classes, and
  its risk contribution.
  """
  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = composition, opts) when is_list(opts) do
    composition
    |> maybe_definition(Keyword.get(opts, :definition))
    |> maybe_eval_case(Keyword.get(opts, :eval_case))
    |> maybe_migration(Keyword.get(opts, :state_migration))
    |> mark(
      Keyword.fetch!(opts, :operation_type),
      Keyword.get(opts, :component_classes, []),
      Keyword.get(opts, :risk, :low)
    )
  end

  @doc "Records an operation type, affected component classes, and risk."
  @spec mark(t(), String.t(), [atom()], risk()) :: t()
  def mark(%__MODULE__{} = composition, operation_type, components, risk) do
    %{
      composition
      | risk: max_risk(composition.risk, risk),
        changed_components:
          (composition.changed_components ++ components) |> Enum.uniq() |> Enum.sort(),
        operation_types: composition.operation_types ++ [operation_type]
    }
  end

  @spec maybe_definition(t(), Canonical.t() | nil) :: t()
  defp maybe_definition(composition, nil), do: composition

  defp maybe_definition(composition, %Canonical{} = definition),
    do: %{composition | definition: definition}

  @spec maybe_eval_case(t(), map() | nil) :: t()
  defp maybe_eval_case(composition, nil), do: composition

  defp maybe_eval_case(composition, %{} = evaluation_case),
    do: %{composition | eval_cases: composition.eval_cases ++ [evaluation_case]}

  @spec maybe_migration(t(), map() | nil) :: t()
  defp maybe_migration(composition, nil), do: composition

  defp maybe_migration(composition, %{} = migration),
    do: %{composition | state_migrations: composition.state_migrations ++ [migration]}

  @spec max_risk(risk(), risk()) :: risk()
  defp max_risk(left, right) do
    if Map.fetch!(@risk_order, left) >= Map.fetch!(@risk_order, right), do: left, else: right
  end
end
