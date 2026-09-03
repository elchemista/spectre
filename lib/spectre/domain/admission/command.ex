defmodule Spectre.Domain.Admission.Command do
  @moduledoc """
  Plans, appends and recovers one ordered group of Candidate submissions.

  The command receives queue entries that already share ledger options. It
  builds their provisional decisions in order, commits one atomic batch, then
  reconstructs each response from durable state. Executor Grants are minted
  only after that recovery. It does not own a mailbox or choose batch timing.
  """

  alias Spectre.{Act, Candidate, Decision}
  alias Spectre.Domain.Admission.Planner, as: AdmissionPlanner
  alias Spectre.Domain.Command.Execution, as: ExecutionCommand
  alias Spectre.Domain.{Transaction}
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Scope.Opening

  @doc "Processes one non-empty, ledger-option-homogeneous submission group."
  @spec run(State.t(), [map()]) :: {State.t(), [{GenServer.from(), term()}]}

  def run(%State{} = state, requests) do
    ledger_opts = hd(requests).ledger_opts

    case preflight_duty_repair(state, ledger_opts) do
      {:ok, current} ->
        case admit(current, requests, ledger_opts, current.conflict_retries) do
          {:ok, next_state, plans} ->
            {next_state, finalize_admission(next_state, plans)}

          {:error, next_state, plans, reason} ->
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
    {plan.request.from, {:error, reason}}
  end

  defp admit(state, requests, ledger_opts, conflicts_left) do
    with {:ok, admitted_at} <- Transaction.trusted_recorded_at(state.clock, state.projection) do
      {plans, _provisional, payloads} = AdmissionPlanner.plan(state, requests, admitted_at)

      if payloads == [] do
        {:ok, state, plans}
      else
        case Transaction.operational_id(state, "admission") do
          {:ok, batch_id} ->
            commit_planned_admission(
              state,
              requests,
              plans,
              payloads,
              batch_id,
              ledger_opts,
              conflicts_left,
              admitted_at
            )

          {:error, reason} ->
            {:error, state, plans, reason}
        end
      end
    else
      {:error, reason} -> {:error, state, AdmissionPlanner.error_plans(requests), reason}
    end
  end

  defp commit_planned_admission(
         state,
         requests,
         plans,
         payloads,
         batch_id,
         ledger_opts,
         conflicts_left,
         admitted_at
       ) do
    case Transaction.append_exact(
           state,
           batch_id,
           payloads,
           state.projection.revision,
           ledger_opts,
           state.ambiguous_retries,
           admitted_at
         ) do
      {:ok, recovered} ->
        {:ok, %{state | projection: recovered}, plans}

      :conflict when conflicts_left > 0 ->
        retry_admission_after_conflict(state, requests, ledger_opts, conflicts_left - 1)

      :conflict ->
        halted = Control.halt(state, :conflict_retries_exhausted)
        {:error, halted, plans, :conflict_retries_exhausted}

      {:error, {:durable_recovery_failed, reason}} ->
        halted = Control.halt(state, reason)
        {:error, halted, plans, {:durable_recovery_failed, reason}}

      {:error, :ambiguous_commit_unresolved} ->
        halted = Control.halt(state, :ambiguous_commit_unresolved)
        {:error, halted, plans, :ambiguous_commit_unresolved}

      {:error, reason} ->
        {:error, state, plans, reason}
    end
  end

  defp retry_admission_after_conflict(state, requests, ledger_opts, conflicts_left) do
    case Transaction.recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        admit(%{state | projection: projection}, requests, ledger_opts, conflicts_left)

      {:error, reason} ->
        plans = AdmissionPlanner.error_plans(requests)
        halted = Control.halt(state, reason)
        {:error, halted, plans, {:durable_recovery_failed, reason}}
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

      {plan.request.from, reply}
    end)
  end

  defp admission_reply(state, %{request: %{kind: :governed_scope_opening}} = plan) do
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
    with {:ok, identity} <-
           Map.fetch(state.projection.candidate_identities, candidate.identity_key),
         true <- identity.digest == candidate.material_digest,
         {:ok, decision} <- Map.fetch(state.projection.decisions, identity.decision_ref),
         {:ok, act} <- act_for_decision(state.projection, decision),
         {:ok, grant} <- ExecutionCommand.mint_grant(state, act) do
      {:ok, %{decision: decision, act: act, grant: grant}}
    else
      :error -> {:error, :admission_not_recovered}
      false -> {:error, {:candidate_identity_conflict, candidate.identity_key}}
      {:error, _reason} = error -> error
    end
  end

  defp act_for_decision(_projection, %Decision{outcome: outcome}) when outcome != :admitted,
    do: {:ok, nil}

  defp act_for_decision(projection, %Decision{outcome: :admitted, ref: decision_ref}) do
    with {:ok, act_ref} <- Map.fetch(projection.acts_by_decision, decision_ref),
         {:ok, act} <- Map.fetch(projection.acts, act_ref) do
      {:ok, act}
    else
      :error -> {:error, {:admitted_decision_missing_act, decision_ref}}
    end
  end

  defp preflight_duty_repair(state, ledger_opts) do
    case Transaction.repair_missing_duties(
           state,
           state.projection,
           ledger_opts,
           state.conflict_retries
         ) do
      {:ok, projection} ->
        {:ok, %{state | projection: projection}}

      {:error, reason} ->
        tagged = {:preflight_duty_repair_failed, reason}
        {:error, Control.halt(state, tagged), tagged}
    end
  end
end
