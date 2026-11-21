defmodule Spectre.GAM.Facade.Proposal do
  @moduledoc false

  # Host-side orchestration, not another kernel or process. The Domain commits
  # admission before Runner receives a Grant; only capability-free results
  # return through Spectre.GAM.propose/3. A fallback is one new governed proposal,
  # never recursion or a retry of an uncertain external effect.
  alias Spectre.GAM.Attempt.Runner
  alias Spectre.GAM.{Candidate, Fallback, Scope, Surface}
  alias Spectre.GAM.Domain.Admission.Fence
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.Facade.Access
  alias Spectre.GAM.Proposal.Result, as: ProposalResult

  @execution_options [:sequencer_opts]

  @doc "Runs a public proposal and its declared, non-recursive fallback through normal admission."
  @spec run(Scope.t(), Candidate.t() | map() | keyword(), keyword()) ::
          {:ok, ProposalResult.t()} | {:error, term()}
  def run(%Scope{} = scope, candidate, opts) when is_list(opts) do
    with :ok <- validate_public_execution_options(opts), do: run_proposal(scope, candidate, opts)
  end

  def run(_scope, _candidate, _opts), do: {:error, :invalid_proposal}

  @doc false
  @spec run_activity(Scope.t(), Candidate.t(), reference(), Fence.origin()) ::
          {:ok, ProposalResult.t()} | {:error, term()}
  def run_activity(%Scope{} = scope, candidate, token, origin),
    do: run_proposal(scope, candidate, activity: {token, origin})

  defp run_proposal(scope, candidate, opts) do
    with {:ok, scope} <- Access.rebind_scope(scope),
         {:ok, candidate} <- Candidate.new(candidate),
         {:ok, primary} <- submit_and_run(scope, candidate, opts),
         {:ok, fallback} <- declared_fallback(scope, primary, opts) do
      {:ok, %ProposalResult{primary: primary, fallback: fallback}}
    end
  end

  defp submit_and_run(scope, candidate, opts) do
    with {:ok, admission} <-
           Access.sequencer_result(
             fn -> submit(scope, candidate, opts) end,
             :domain_submission_failed
           ) do
      run_admission(scope.domain.server, {:ok, admission}, Keyword.delete(opts, :activity))
    end
  end

  defp submit(scope, candidate, opts) do
    case opts[:activity] do
      {token, origin} ->
        Sequencer.submit_activity(scope.domain.server, scope.context, candidate, token, origin)

      nil ->
        Sequencer.submit(
          scope.domain.server,
          scope.context,
          candidate,
          Keyword.get(opts, :sequencer_opts, [])
        )
    end
  end

  defp declared_fallback(
         _scope,
         %Runner.Result{decision: %{outcome: :admitted}},
         _opts
       ),
       do: {:ok, :not_applicable}

  defp declared_fallback(
         _scope,
         %Runner.Result{decision: %{outcome: :undecidable}},
         _opts
       ),
       do: {:ok, :not_applicable}

  defp declared_fallback(
         _scope,
         %Runner.Result{decision: %{outcome: :unknown_class}},
         _opts
       ),
       do: {:ok, :silence}

  defp declared_fallback(
         scope,
         %Runner.Result{decision: %{outcome: :refused} = decision},
         opts
       ) do
    with {:ok, surface} <- Access.scoped_query(scope, {:surface, decision.surface_revision}),
         {:ok, policy} <- Surface.fallback(surface, decision.candidate_class),
         {:ok, fallback} <- Fallback.materialize(policy, decision, scope.context) do
      execute_fallback(scope, fallback, opts)
    end
  end

  defp declared_fallback(_scope, %Runner.Result{}, _opts),
    do: {:error, :invalid_primary_decision_outcome}

  defp execute_fallback(_scope, :silence, _opts), do: {:ok, :silence}

  defp execute_fallback(scope, {mode, candidate}, opts)
       when mode in [:candidate_template, :governed_handoff] do
    # This is deliberately not propose/3: a refused fallback ends this path.
    # Recursion is bounded by control flow, not by guessing an identity prefix.
    with {:ok, result} <- submit_and_run(scope, candidate, opts) do
      {:ok, %{mode: mode, result: result}}
    end
  end

  defp run_admission(sequencer, admission, opts) do
    case Access.safe_call(
           fn -> Runner.run(sequencer, admission, opts) end,
           :execution_orchestration_failed
         ) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp validate_public_execution_options(opts) do
    with :ok <- Access.validate_keyword(opts, :execution_options),
         :ok <- Access.validate_known_options(opts, @execution_options, :execution),
         {:ok, sequencer_opts} <- Access.nested_keyword(opts, :sequencer_opts) do
      Access.validate_sequencer_options(sequencer_opts)
    end
  end
end
