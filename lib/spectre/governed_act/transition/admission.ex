defmodule Spectre.GovernedAct.Transition.Admission do
  @moduledoc """
  Replays the immutable Decision-to-Act Admission lifecycle.

  This transition owns ordering and indexes only. `Admission.Decision`
  reconstructs the admission-time authority and Evidence proof;
  `Admission.Act` rebuilds the frozen Candidate and verifies its exact binding
  to that Decision. Mutable authority standing is checked later, when an
  Attempt starts.
  """

  alias Spectre.{Act, Decision}
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{Index, State}
  alias Spectre.GovernedAct.Transition.Admission.Act, as: ActProof
  alias Spectre.GovernedAct.Transition.Admission.Decision, as: DecisionProof

  @spec apply(State.t(), Event.t(), non_neg_integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def apply(
        %State{} = state,
        %Event{type: "decision_recorded", identity: identity, data: data},
        entry_revision
      ) do
    with {:ok, decision} <-
           Index.restore_unique(state.decisions, Decision, identity, data, :decision),
         :ok <- DecisionProof.validate(state, decision, entry_revision) do
      install_decision(state, decision)
    end
  end

  def apply(
        %State{} = state,
        %Event{type: "act_committed", identity: identity, data: data},
        _revision
      ) do
    with {:ok, act} <- Index.restore_unique(state.acts, Act, identity, data, :act),
         :ok <- GovernedExecution.validate(act),
         {:ok, decision} <- Index.fetch_decision(state, act.decision_ref),
         :ok <- ActProof.validate(state, act, decision) do
      admission = Map.fetch!(state.admissions, decision.candidate_identity_key)

      {:ok,
       %{
         state
         | acts: Map.put(state.acts, identity, act),
           admissions:
             Map.put(state.admissions, decision.candidate_identity_key, %{
               admission
               | act_ref: identity
             })
       }}
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_admission_event, type}}

  defp install_decision(state, decision) do
    candidate_key = decision.candidate_identity_key

    case Map.fetch(state.admissions, candidate_key) do
      :error ->
        {:ok,
         %{
           state
           | decisions: Map.put(state.decisions, decision.ref, decision),
             admissions:
               Map.put(state.admissions, candidate_key, %{
                 decision_ref: decision.ref,
                 act_ref: nil
               })
         }}

      {:ok, %{decision_ref: existing_ref}} ->
        existing_decision(state, decision, existing_ref)

      {:ok, _invalid} ->
        {:error, {:invalid_candidate_admission, candidate_key}}
    end
  end

  defp existing_decision(state, decision, existing_ref) do
    case Map.fetch(state.decisions, existing_ref) do
      {:ok, %Decision{candidate_digest: digest}} when digest == decision.candidate_digest ->
        {:error, {:duplicate_candidate_decision, decision.candidate_identity_key}}

      {:ok, %Decision{}} ->
        {:error, {:candidate_identity_conflict, decision.candidate_identity_key}}

      :error ->
        {:error,
         {:candidate_identity_decision_not_found, decision.candidate_identity_key, existing_ref}}
    end
  end
end
