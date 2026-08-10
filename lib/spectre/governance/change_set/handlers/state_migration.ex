defmodule Spectre.Governance.ChangeSet.Handlers.StateMigration do
  @moduledoc false

  @behaviour Spectre.Governance.ChangeSet.Handler

  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition

  @impl true
  def operation_types, do: ["select_state_migration"]

  @impl true
  def component_classes, do: [:state_migrations]

  @impl true
  def apply(
        %Operation{type: "select_state_migration", payload: payload},
        %Composition{} = composition,
        context
      ) do
    with [] <- Map.keys(payload) -- ~w(skill_id migration_ref),
         {:ok, skill_id} <- stable_name(Map.get(payload, "skill_id"), :skill_id),
         {:ok, migration_ref} <- stable_name(Map.get(payload, "migration_ref"), :migration_ref),
         true <- registered?(migration_ref, Map.get(context, :registered_migrations, [])),
         false <- Enum.any?(composition.state_migrations, &(&1["skill_id"] == skill_id)) do
      {:ok,
       Composition.update(composition,
         state_migration: %{"skill_id" => skill_id, "migration_ref" => migration_ref},
         operation_type: "select_state_migration",
         component_classes: [:state_migrations],
         risk: :high
       )}
    else
      [_first | _rest] = unknown ->
        {:error, {:unknown_state_migration_governance_fields, unknown}}

      false ->
        {:error, {:state_migration_not_registered, Map.get(payload, "migration_ref")}}

      true ->
        {:error, {:duplicate_skill_state_migration, Map.get(payload, "skill_id")}}

      {:error, _reason} = error ->
        error
    end
  end

  defp stable_name(value, _field) when is_binary(value) and value != "" do
    if String.starts_with?(value, "Elixir."),
      do: {:error, :state_migration_code_reference_forbidden},
      else: {:ok, value}
  end

  defp stable_name(value, field), do: {:error, {:invalid_state_migration_field, field, value}}

  defp registered?(ref, refs) when is_list(refs) do
    Enum.any?(refs, fn
      ^ref -> true
      value when is_atom(value) -> Atom.to_string(value) == ref
      _value -> false
    end)
  end

  defp registered?(_ref, _refs), do: false
end
