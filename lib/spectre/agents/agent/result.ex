defmodule Spectre.Agent.Result do
  @moduledoc """
  Human-oriented view of confirmed proposal facts, retaining the original.

  Pending is not unclear. An absent Attempt does not prove cancellation; an
  absent Outcome does not prove either success or failure. Fallback facts stay
  separate from the primary result. This module performs no executor retry.
  """
  alias Spectre.Attempt.Runner
  alias Spectre.{Outcome, Scope}
  alias Spectre.Proposal.Result, as: Proposal

  @doc "Projects a governed result; verifies dispatch facts only when the result lacks an Outcome."
  def from_proposal(%Proposal{} = proposal, %Scope{} = scope) do
    with {:ok, primary} <- summarize(proposal.primary, scope),
         {:ok, fallback} <- fallback(proposal.fallback, scope) do
      {:ok, Map.merge(primary, %{details: proposal, fallback: fallback})}
    end
  end

  defp summarize(%Runner.Result{decision: %{outcome: outcome} = decision}, _scope)
       when outcome in [:refused, :undecidable, :unknown_class],
       do: {:ok, %{status: outcome, data: nil, reason: decision.reasons}}

  defp summarize(%Runner.Result{outcome: %Outcome{} = outcome} = result, _scope) do
    status =
      case outcome.status do
        :succeeded -> :done
        :failed -> :failed
        :definitive_no_effect -> :no_effect
        :ambiguous -> :unclear
      end

    {:ok, %{status: status, data: data(result), reason: outcome.details_ref}}
  end

  defp summarize(%Runner.Result{act: act}, scope) when not is_nil(act) do
    with {:ok, facts} <- Spectre.dispatch_status(scope, act.ref) do
      case facts do
        %{mode: :ledger_internal} ->
          {:ok, %{status: :done, data: act.consequence, reason: nil}}

        %{terminal: {:cancelled, cause}, pending?: false} ->
          {:ok, %{status: :not_attempted, data: nil, reason: cause}}

        _in_flight ->
          {:ok, %{status: :pending, data: nil, reason: nil}}
      end
    end
  end

  defp summarize(_result, _scope), do: {:error, :invalid_proposal_lifecycle}

  defp data(%Runner.Result{outcome: outcome, act: act, evidence: evidence}) do
    proposition =
      Outcome.proposition(outcome.status, act.ref, outcome.attempt_ref, act.executor_contract_ref)

    case Enum.filter(
           evidence,
           &(&1.ref in outcome.evidence_refs and &1.proposition === proposition)
         ) do
      [%{payload: payload, payload_ref: nil}] -> payload
      [%{payload_ref: ref}] -> %{"payload_ref" => ref}
      _not_a_single_payload -> nil
    end
  end

  defp fallback(value, _scope) when value in [:not_applicable, :silence], do: {:ok, value}

  defp fallback(%{mode: mode, result: result}, scope) do
    with {:ok, view} <- summarize(result, scope), do: {:ok, %{mode: mode, result: view}}
  end
end
