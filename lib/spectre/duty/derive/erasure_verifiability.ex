defmodule Spectre.Duty.Derive.ErasureVerifiability do
  @moduledoc """
  Derives the explicit verification debt created by a successful erasure.
  """

  alias Spectre.{Act, Erasure}
  alias Spectre.Duty.Derive.{Cause, Facts}
  alias Spectre.Outcome

  @doc false
  @spec causes(Facts.t(), map(), integer()) :: [map()]
  def causes(%Facts{} = facts, constitution, time) do
    Enum.flat_map(facts.erasures, fn {_erasure_ref, %Erasure{} = erasure} ->
      with true <- erasure.reduces_verifiability,
           %Act{} = act <- Map.get(facts.acts, erasure.source_act_ref),
           {:ok, attempt, outcome} <- succeeded_outcome(facts, erasure.source_act_ref, time) do
        [
          Cause.build(
            :erasure_reduces_verifiability,
            {:erasure_reduces_verifiability, erasure.ref, act.ref, attempt.ref, outcome.ref},
            %{
              "erasure_ref" => erasure.ref,
              "act_ref" => act.ref,
              "attempt_ref" => attempt.ref,
              "outcome_ref" => outcome.ref
            },
            constitution,
            %{
              act: act,
              known_evidence_refs: outcome.evidence_refs,
              missing_evidence: [:continued_verifiability],
              required_at: outcome.observed_at
            }
          )
        ]
      else
        _not_confirmed -> []
      end
    end)
  end

  defp succeeded_outcome(facts, act_ref, time) do
    facts.outcomes
    |> Enum.filter(fn {_outcome_ref, %Outcome{} = outcome} ->
      outcome.act_ref == act_ref and outcome.status == :succeeded and
        Facts.available_at?(facts, outcome.ref, time)
    end)
    |> Enum.sort_by(fn {_outcome_ref, outcome} -> Cause.stable_sort_key(outcome) end)
    |> Enum.find_value(:not_found, fn {_outcome_ref, %Outcome{} = outcome} ->
      case Map.get(facts.attempts, outcome.attempt_ref) do
        nil -> nil
        attempt -> if attempt.act_ref == act_ref, do: {:ok, attempt, outcome}
      end
    end)
  end
end
