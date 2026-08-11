defmodule Spectre.Governance.Checker.Declarative.ReceiptIssuer do
  @moduledoc """
  Issues replay and regression receipts for one declarative evaluation delta.

  Both receipts bind the exact parent, Candidate, closure, corpus, checker
  version, and result digest. This module only attests observations produced by
  the checker; it never reviews, approves, or activates a Candidate.
  """

  alias Spectre.Gate.Receipt
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.EvaluationDelta

  @checker_id "spectre.check.declarative"
  @checker_version 2
  @profile_ref "spectre.declarative.routing/2"

  @type checker_versions :: %{
          required(:replay) => {String.t(), pos_integer()},
          required(:regression) => {String.t(), pos_integer()}
        }

  @doc false
  @spec checker_versions() :: checker_versions()
  def checker_versions do
    %{
      replay: {@checker_id, @checker_version},
      regression: {@checker_id, @checker_version}
    }
  end

  @doc false
  @spec issue(CandidateState.t(), EvaluationDelta.t(), term()) ::
          {:ok, [Receipt.t()]} | {:error, term()}
  def issue(governance, delta, issued_at) do
    [:replay, :regression]
    |> Enum.reduce_while({:ok, []}, fn gate, {:ok, receipts} ->
      case receipt(gate, governance, delta, issued_at) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_receipts()
  end

  @spec receipt(:replay | :regression, CandidateState.t(), EvaluationDelta.t(), term()) ::
          {:ok, Receipt.t()} | {:error, term()}
  defp receipt(gate, governance, delta, issued_at) do
    Receipt.new(%{
      gate_class: gate,
      candidate_digest: governance.proposal_digest,
      parent_definition_ref: governance.parent_definition_ref,
      candidate_definition_ref: governance.candidate_definition_ref,
      closure_digest: governance.closure_digest,
      checker_id: @checker_id,
      checker_version: @checker_version,
      evaluation_cases_digest: governance.evaluation_cases_digest,
      profile_ref: if(gate == :replay, do: @profile_ref),
      issued_at: issued_at,
      status: if(delta.passed, do: :passed, else: :failed),
      result_digest: EvaluationDelta.digest(delta),
      provenance: %{source: :declarative_routing, model_free: true}
    })
  end

  @spec reverse_receipts({:ok, [Receipt.t()]} | {:error, term()}) ::
          {:ok, [Receipt.t()]} | {:error, term()}
  defp reverse_receipts({:ok, receipts}), do: {:ok, Enum.reverse(receipts)}
  defp reverse_receipts({:error, _reason} = error), do: error
end
