defmodule Spectre.Domain.Admission.Planner do
  @moduledoc """
  Builds a provisional atomic Admission plan from queued submissions.

  The planner validates sealed Scope bindings and host execution-route
  availability before calling the pure kernel. It does not append, mint Grants
  or reply to callers. Each accepted Candidate is applied to provisional state
  so later Candidates in the same group observe the exact preceding prefix.
  """

  alias Spectre.{Candidate, Governance}
  alias Spectre.Domain.{Context, Projection}
  alias Spectre.Domain.Sequencer.State
  alias Spectre.Execution.Router
  alias Spectre.GovernedAct.Class, as: GovernedClass
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel, as: GovernedKernel
  alias Spectre.Kernel.Commit
  alias Spectre.Scope.Opening

  @type plan :: %{
          required(:from) => GenServer.from(),
          required(:candidate) => Candidate.t() | nil,
          required(:error) => term() | nil
        }

  @doc "Plans a submission group in queue order."
  @spec plan(State.t(), [map()], non_neg_integer()) ::
          {[plan()], [map()]}

  def plan(state, requests, admitted_at) do
    Enum.reduce(requests, {[], state.projection, []}, fn request,
                                                         {plans, provisional, reversed_payloads} ->
      case plan_submission(state, request, provisional, admitted_at) do
        {:ok, plan, next_projection, new_payloads} ->
          {
            [plan | plans],
            next_projection,
            Enum.reverse(new_payloads, reversed_payloads)
          }

        {:error, reason} ->
          plan = error_plan(request, reason)
          {[plan | plans], provisional, reversed_payloads}
      end
    end)
    |> then(fn {plans, _projection, reversed_payloads} ->
      {Enum.reverse(plans), Enum.reverse(reversed_payloads)}
    end)
  end

  defp plan_submission(state, request, projection, admitted_at) do
    with {:ok, candidate} <- Candidate.new(request.candidate),
         {:ok, context, _opening} <- Context.validate_scope(state, projection, request.context),
         :ok <- validate_domain_route(projection, context),
         :ok <- validate_submission_kind(state, request, candidate, context) do
      case Projection.candidate_decision(projection, candidate.identity_key) do
        {:ok, %{candidate_digest: digest}} when digest == candidate.material_digest ->
          {:ok, success_plan(request, candidate), projection, []}

        {:ok, _different} ->
          {:error, {:candidate_identity_conflict, candidate.identity_key}}

        :not_found ->
          with :ok <-
                 Router.validate_candidate(state.execution_boundary, projection, candidate) do
            evaluate_submission(request, candidate, context, projection, admitted_at)
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp validate_submission_kind(
         state,
         %{child_context: child_context},
         candidate,
         parent_context
       ) do
    with {:ok, child_context} <- Context.validate_current(state, child_context),
         :ok <- validate_child_context_boundary(parent_context, child_context),
         {:ok, draft} <- candidate_scope_opening_draft(candidate),
         :ok <- validate_scope_opening_candidate(candidate, draft, parent_context, child_context) do
      :ok
    end
  end

  defp validate_submission_kind(_state, request, candidate, _context)
       when not is_map_key(request, :child_context) do
    if candidate.class == Governance.scope_open_class(),
      do: {:error, :governed_scope_context_required},
      else: :ok
  end

  defp validate_child_context_boundary(parent_context, child_context) do
    if child_context.scope_ref == parent_context.scope_ref,
      do: {:error, :child_scope_ref_must_differ_from_parent},
      else: :ok
  end

  defp candidate_scope_opening_draft(%Candidate{
         class: class,
         consequence: %{"scope_open" => draft} = consequence
       })
       when class == "scope.open" and map_size(consequence) == 1 do
    with {:ok, canonical} <- Opening.governed_draft(draft),
         true <- canonical == draft do
      {:ok, canonical}
    else
      false -> {:error, :noncanonical_governed_scope_draft}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_scope_opening_draft(_candidate),
    do: {:error, :invalid_governed_scope_opening_consequence}

  defp validate_scope_opening_candidate(candidate, draft, parent_context, child_context) do
    context_fields =
      child_context
      |> Opening.context_bindings()
      |> Map.put(:parent_ref, parent_context.scope_ref)

    mismatch =
      Enum.find(context_fields, fn {field, expected} ->
        Map.get(draft, Atom.to_string(field)) != expected
      end)

    cond do
      mismatch ->
        {field, _expected} = mismatch
        {:error, {:governed_scope_context_mismatch, Atom.to_string(field)}}

      not GovernedClass.exact_row?(Governance.scope_open_class(), candidate.row) ->
        {:error, :invalid_governed_scope_opening_row}

      candidate.executor_ref != GovernedExecution.kernel_executor_ref() or
          candidate.executor_contract_ref != GovernedExecution.kernel_contract_ref() ->
        {:error, :governed_scope_opening_not_ledger_internal}

      candidate.meter_requests != %{} or candidate.observation_window_ms != 0 ->
        {:error, :invalid_governed_scope_opening_execution}

      candidate.accountable_ref != Map.fetch!(draft, "accountable_ref") ->
        {:error, :governed_scope_accountable_mismatch}

      child_context.scope_ref not in candidate.target_refs ->
        {:error, :governed_scope_opening_target_missing}

      true ->
        :ok
    end
  end

  # A context routed to another Domain must never reach this ledger. Candidate
  # identity and Scope fields, however, are untrusted claims: the kernel owns
  # their comparison with the authenticated context and records mismatches as
  # durable refused Decisions.
  defp validate_domain_route(projection, context) do
    if context.domain_ref == projection.domain_ref,
      do: :ok,
      else: {:error, {:submission_domain_mismatch, context.domain_ref, projection.domain_ref}}
  end

  defp evaluate_submission(request, candidate, context, projection, admitted_at) do
    with {:ok, decision, act} <-
           GovernedKernel.evaluate(candidate, context, projection, admitted_at),
         {:ok, payloads} <- Commit.payloads(projection, decision, act),
         {:ok, next_projection} <-
           Projection.apply_payloads(projection, payloads, admitted_at) do
      {:ok, success_plan(request, candidate), next_projection, payloads}
    end
  end

  defp success_plan(request, candidate),
    do: %{from: request.from, candidate: candidate, error: nil}

  @doc "Creates neutral error plans when Admission cannot start."
  @spec error_plans([map()]) :: [plan()]
  def error_plans(requests) do
    Enum.map(requests, &error_plan(&1, nil))
  end

  defp error_plan(request, reason),
    do: %{from: request.from, candidate: nil, error: reason}
end
