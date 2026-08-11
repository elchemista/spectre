defmodule Spectre.Governance.Checker.Declarative do
  @moduledoc """
  Model-free replay and regression checker for closed declarative Skill replies.

  It resolves both Definitions from the Store, runs the canonical evaluation
  cases through the same Skill runtime loader used by live turns, and binds
  route, outcome, context and optional exact output to the protected corpus
  digest. Candidates containing Operation or Work handlers are refused.
  """

  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Store
  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Gate.Receipt
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.Checker.Declarative.Evaluator
  alias Spectre.Governance.Checker.Declarative.ReceiptIssuer
  alias Spectre.Governance.Checker.Declarative.Rehearsability
  alias Spectre.Governance.Checker.Declarative.Shape
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Skill.Runtime.Loader

  @type evaluation_case :: EvalCase.t() | map()
  @type governed_candidate ::
          Candidate.t() | %{required(:governance) => CandidateState.t()}
  @type result ::
          {:ok, EvaluationDelta.t(), [Receipt.t()]}
          | {:error, term()}

  @doc "Returns the checker versions trusted by the built-in Morph workflow."
  @spec checker_versions() :: %{
          required(:replay) => {String.t(), pos_integer()},
          required(:regression) => {String.t(), pos_integer()}
        }
  def checker_versions, do: ReceiptIssuer.checker_versions()

  @doc "Runs protected and Candidate-owned cases against exact parent/Candidate refs."
  @spec run(Store.config(), governed_candidate(), term()) :: result()
  @spec run(Store.config(), governed_candidate(), term(), keyword()) :: result()
  def run(store, candidate, cases, opts \\ [])

  def run(store, %{governance: %CandidateState{} = governance}, cases, opts)
      when is_list(cases) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: run_checked(store, governance, cases, opts),
      else: {:error, {:invalid_declarative_check, Shape.of(cases), Shape.of(opts)}}
  end

  def run(_store, _candidate, cases, opts),
    do: {:error, {:invalid_declarative_check, Shape.of(cases), Shape.of(opts)}}

  @spec run_checked(Store.config(), CandidateState.t(), [evaluation_case()], keyword()) ::
          result()
  defp run_checked(store, governance, cases, opts) do
    issued_at = Keyword.get(opts, :issued_at, 0)
    protected_cases = Keyword.get(opts, :protected_cases, cases)
    candidate_ids = governance.candidate_case_ids || []
    candidate_cases = governance.candidate_cases || []

    with {:ok, agent_snapshot} <- Rehearsability.agent_snapshot(opts),
         :ok <- Rehearsability.verify_live_path(agent_snapshot),
         {:ok, protected} <- Evaluator.normalize_cases(protected_cases),
         {:ok, owned} <- Evaluator.normalize_cases(candidate_cases),
         :ok <- Evaluator.verify_candidate_case_ids(owned, candidate_ids),
         all_cases = protected ++ owned,
         :ok <- Rehearsability.verify_cases(all_cases),
         {:ok, parent} <-
           Loader.load(
             store,
             governance.parent_definition_ref,
             agent_snapshot.agent,
             runtime_only?: true
           ),
         {:ok, proposed} <-
           Loader.load(
             store,
             governance.candidate_definition_ref,
             agent_snapshot.agent,
             runtime_only?: true
           ),
         :ok <- Rehearsability.verify_runtime(parent.runtime),
         :ok <- Rehearsability.verify_runtime(proposed.runtime),
         {:ok, parent_results} <- Evaluator.evaluate(parent, protected, agent_snapshot),
         {:ok, candidate_results} <- Evaluator.evaluate(proposed, all_cases, agent_snapshot),
         {:ok, delta} <-
           EvaluationDelta.new(parent_results, candidate_results,
             protected_cases: Enum.map(protected, &EvalCase.to_data/1),
             candidate_case_ids: candidate_ids
           ),
         {:ok, receipts} <- ReceiptIssuer.issue(governance, delta, issued_at) do
      {:ok, delta, receipts}
    end
  end
end
