defmodule Spectre.Domain.Command.Observation do
  @moduledoc """
  Records one executor Outcome as an exact governed transaction.

  Outcome normalization and event derivation are pure. The command appends the
  complete observation batch, recovers it, and returns only the durable record.
  CAS conflicts retry from a newly recovered prefix; unresolved durability
  failures stop the owning Sequencer.
  """

  alias Spectre.Domain.Transaction
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Command.Record, as: CommandRecord
  alias Spectre.Domain.Sequencer.State
  alias Spectre.Kernel.Observation
  alias Spectre.Outcome

  @doc "Normalizes and durably records an Outcome."
  @spec record(State.t(), Outcome.t() | map() | keyword()) ::
          {:ok, State.t(), Outcome.t()} | {:error, State.t(), term()}

  def record(state, input) do
    case Outcome.new(input) do
      {:ok, outcome} ->
        record_normalized_observation(state, outcome, state.conflict_retries)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp record_normalized_observation(state, outcome, conflicts_left) do
    case CommandRecord.lookup(state.projection.outcomes, outcome, :outcome_identity_conflict) do
      {:ok, durable} ->
        {:ok, state, durable}

      :not_found ->
        append_observation(state, outcome, conflicts_left)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp append_observation(state, outcome, conflicts_left) do
    with {:ok, now} <- Transaction.trusted_recorded_at(state),
         {:ok, payloads} <-
           Observation.payloads(
             state.projection,
             outcome,
             now,
             state.projection.constitution
           ),
         {:ok, _provisional} <- Transaction.apply_payloads(state.projection, payloads) do
      Commit.append(
        state,
        payloads,
        now,
        conflicts_left,
        &recovered_outcome(state, &1, outcome),
        &record_normalized_observation(&1, outcome, &2)
      )
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp recovered_outcome(state, projection, outcome) do
    CommandRecord.recover(
      state,
      projection,
      :outcomes,
      outcome,
      :outcome_identity_conflict,
      :outcome_not_recovered
    )
  end
end
