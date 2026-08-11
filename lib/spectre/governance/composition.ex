defmodule Spectre.Governance.Composition do
  @moduledoc false

  alias Spectre.Definition.Canonical

  @risk_order %{low: 0, medium: 1, high: 2, critical: 3}

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
          risk: :low | :medium | :high | :critical,
          changed_components: [atom()],
          operation_types: [String.t()]
        }

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

  @spec mark(t(), String.t(), [atom()], atom()) :: t()
  def mark(%__MODULE__{} = composition, operation_type, components, risk) do
    %{
      composition
      | risk: max_risk(composition.risk, risk),
        changed_components:
          (composition.changed_components ++ components) |> Enum.uniq() |> Enum.sort(),
        operation_types: composition.operation_types ++ [operation_type]
    }
  end

  defp maybe_definition(composition, nil), do: composition

  defp maybe_definition(composition, %Canonical{} = definition),
    do: %{composition | definition: definition}

  defp maybe_eval_case(composition, nil), do: composition

  defp maybe_eval_case(composition, %{} = evaluation_case),
    do: %{composition | eval_cases: composition.eval_cases ++ [evaluation_case]}

  defp maybe_migration(composition, nil), do: composition

  defp maybe_migration(composition, %{} = migration),
    do: %{composition | state_migrations: composition.state_migrations ++ [migration]}

  defp max_risk(left, right) do
    if Map.fetch!(@risk_order, left) >= Map.fetch!(@risk_order, right), do: left, else: right
  end
end
