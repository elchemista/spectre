defmodule Spectre.Duty.Derive.ScopePromise do
  @moduledoc """
  Derives a Duty when a Work or Vigil Scope reaches its unmet promise deadline.
  """

  alias Spectre.Condition
  alias Spectre.Duty.Derive.{Cause, Facts}
  alias Spectre.Kernel.Recognition
  alias Spectre.Scope.Opening

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    Enum.flat_map(Facts.sources(facts, :scopes), fn {_scope_ref, %Opening{} = opening} ->
      eligible? =
        opening.kind in [:work, :vigil] and is_integer(opening.due_at) and
          time >= opening.due_at and match?(%Condition{}, opening.promise_condition)

      if eligible? and
           not promise_satisfied?(opening.promise_condition, facts, opening.due_at) do
        source_act = Map.get(facts.acts, opening.source_act_ref)

        [
          Cause.build(
            :scope_promise_overdue,
            {:scope_promise_overdue, opening.ref},
            %{"scope_ref" => opening.ref, "act_ref" => opening.source_act_ref},
            constitution,
            %{
              act: source_act,
              accountable_ref: opening.accountable_ref,
              missing_evidence: [%{"condition_ref" => opening.promise_condition.ref}],
              closing_conditions: [Condition.canonical(opening.promise_condition)],
              disposition_authority: opening.disposition_authority_refs,
              required_at: opening.due_at
            }
          )
        ]
      else
        []
      end
    end)
  end

  defp promise_satisfied?(condition, facts, due_at) do
    Recognition.check([condition], Facts.available_evidence(facts, due_at), due_at) == :satisfied
  end
end
