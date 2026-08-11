defmodule Spectre.Governance.ChangeSet.Handlers.EvalCase do
  @moduledoc false

  @behaviour Spectre.Governance.ChangeSet.Handler

  alias Spectre.Eval.Case
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition

  @impl true
  def operation_types, do: ["add_eval_case", "replace_eval_case"]

  @impl true
  def component_classes, do: [:candidate_eval_cases]

  @impl true
  def apply(
        %Operation{type: type, payload: %{"case" => attrs} = payload},
        %Composition{} = composition,
        _context
      )
      when type in ["add_eval_case", "replace_eval_case"] do
    with [] <- Map.keys(payload) -- ["case"],
         {:ok, evaluation_case} <- Case.new(attrs),
         {:ok, eval_cases} <- update_cases(type, composition.eval_cases, evaluation_case) do
      {:ok,
       composition
       |> Map.put(:eval_cases, eval_cases)
       |> Composition.update(
         operation_type: type,
         component_classes: [:candidate_eval_cases],
         risk: :low
       )}
    else
      [_first | _rest] = unknown -> {:error, {:unknown_eval_case_governance_fields, unknown}}
      {:error, _reason} = error -> error
    end
  end

  def apply(%Operation{type: type}, %Composition{}, _context)
      when type in ["add_eval_case", "replace_eval_case"],
      do: {:error, :invalid_candidate_eval_case_operation}

  defp update_cases("add_eval_case", cases, evaluation_case) do
    if Enum.any?(cases, &(&1["id"] == evaluation_case.id)),
      do: {:error, {:duplicate_candidate_eval_case, evaluation_case.id}},
      else: {:ok, cases ++ [Case.to_data(evaluation_case)]}
  end

  defp update_cases("replace_eval_case", cases, evaluation_case) do
    if Enum.any?(cases, &(&1["id"] == evaluation_case.id)) do
      {:ok,
       Enum.map(cases, fn existing ->
         if existing["id"] == evaluation_case.id,
           do: Case.to_data(evaluation_case),
           else: existing
       end)}
    else
      {:error, {:candidate_eval_case_not_found, evaluation_case.id}}
    end
  end
end
