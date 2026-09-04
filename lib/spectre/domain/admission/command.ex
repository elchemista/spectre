defmodule Spectre.Domain.Admission.Command do
  @moduledoc """
  Plans, appends and recovers one ordered group of Candidate submissions.

  The command receives queue entries whose ledger configuration is owned by
  the Sequencer state. It builds their provisional decisions in order, commits
  one atomic batch, then reconstructs each response from durable state.
  Executor Grants are minted only after that recovery. It does not own a
  mailbox or choose batch timing.
  """

  alias Spectre.{Act, Candidate}
  alias Spectre.Domain.Admission.Planner, as: AdmissionPlanner
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Command.Execution, as: ExecutionCommand
  alias Spectre.Domain.{Projection, Transaction}
  alias Spectre.Domain.Sequencer.State
  alias Spectre.Scope.Opening

  @doc "Processes one non-empty, ledger-option-homogeneous submission group."
  @spec run(State.t(), [map()]) :: {State.t(), [{GenServer.from(), term()}]}

  def run(%State{} = state, requests) do
    case Commit.prepare(state) do
      {:ok, current} ->
        case admit(current, requests, current.conflict_retries) do
          {:ok, next_state, plans} ->
            {next_state, finalize_admission(next_state, plans)}

          {:error, next_state, {plans, reason}} ->
            replies =
              Enum.map(plans, fn plan ->
                admission_error_reply(plan, reason)
              end)

            {next_state, replies}
        end

      {:error, halted, reason} ->
        replies = Enum.map(requests, &{&1.from, {:error, reason}})
        {halted, replies}
    end
  end

  defp admission_error_reply(plan, batch_reason) do
    reason = plan.error || batch_reason
    {plan.from, {:error, reason}}
  end

  defp admit(state, requests, conflicts_left) do
    with {:ok, admitted_at} <- Transaction.trusted_recorded_at(state) do
      {plans, payloads} = AdmissionPlanner.plan(state, requests, admitted_at)

      if payloads == [] do
        {:ok, state, plans}
      else
        append_planned_admission(
          state,
          requests,
          plans,
          payloads,
          conflicts_left,
          admitted_at
        )
      end
    else
      {:error, reason} ->
        {:error, state, {AdmissionPlanner.error_plans(requests), reason}}
    end
  end

  defp append_planned_admission(
         state,
         requests,
         plans,
         payloads,
         conflicts_left,
         admitted_at
       ) do
    result =
      Commit.append(
        state,
        payloads,
        admitted_at,
        conflicts_left,
        fn recovered -> {:ok, %{state | projection: recovered}, plans} end,
        &admit(&1, requests, &2)
      )

    case result do
      {:error, next_state, {failed_plans, _reason} = failure}
      when is_list(failed_plans) ->
        {:error, next_state, failure}

      {:error, next_state, reason} ->
        {:error, next_state, {plans, reason}}

      {:ok, _next_state, _plans} = success ->
        success
    end
  end

  defp finalize_admission(state, plans) do
    Enum.map(plans, fn plan ->
      reply =
        if plan.error do
          {:error, plan.error}
        else
          admission_reply(state, plan)
        end

      {plan.from, reply}
    end)
  end

  defp admission_reply(state, %{candidate: %Candidate{class: "scope.open"}} = plan) do
    with {:ok, admission} <- admission_from_projection(state, plan.candidate),
         {:ok, opening} <- admitted_scope_opening(state.projection, admission, plan.candidate) do
      {:ok, Map.put(admission, :opening, opening)}
    end
  end

  defp admission_reply(state, plan),
    do: admission_from_projection(state, plan.candidate)

  defp admitted_scope_opening(_projection, %{decision: %{outcome: outcome}, act: nil}, _candidate)
       when outcome != :admitted,
       do: {:ok, nil}

  defp admitted_scope_opening(
         projection,
         %{decision: %{outcome: :admitted}, act: %Act{ref: act_ref}},
         %Candidate{consequence: %{"scope_open" => %{"ref" => scope_ref}}}
       ) do
    case Map.fetch(projection.scopes, scope_ref) do
      {:ok, %Opening{source_act_ref: ^act_ref} = opening} -> {:ok, opening}
      {:ok, %Opening{}} -> {:error, {:scope_opening_source_mismatch, scope_ref, act_ref}}
      :error -> {:error, {:governed_scope_opening_not_recovered, scope_ref}}
    end
  end

  defp admitted_scope_opening(_projection, _admission, _candidate),
    do: {:error, :invalid_governed_scope_admission}

  defp admission_from_projection(state, candidate) do
    with {:ok, decision} <-
           Projection.candidate_decision(state.projection, candidate.identity_key),
         true <- decision.candidate_digest == candidate.material_digest,
         {:ok, act} <- Projection.decision_act(state.projection, decision),
         {:ok, grant} <- ExecutionCommand.mint_grant(state, act) do
      {:ok, %{decision: decision, act: act, grant: grant}}
    else
      :not_found -> {:error, :admission_not_recovered}
      false -> {:error, {:candidate_identity_conflict, candidate.identity_key}}
      {:error, _reason} = error -> error
    end
  end
end
