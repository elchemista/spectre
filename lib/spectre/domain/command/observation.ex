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
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Kernel.Observation
  alias Spectre.Outcome

  @doc "Normalizes and durably records an Outcome."
  @spec record(State.t(), Outcome.t() | map() | keyword(), keyword(), non_neg_integer()) ::
          {:ok, State.t(), Outcome.t()} | {:error, State.t(), term()}

  def record(state, input, ledger_opts, conflicts_left) do
    case Outcome.new(input) do
      {:ok, outcome} ->
        record_normalized_observation(state, outcome, ledger_opts, conflicts_left)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp record_normalized_observation(state, outcome, ledger_opts, conflicts_left) do
    case existing_outcome(state.projection, outcome) do
      {:ok, durable} ->
        {:ok, state, durable}

      :not_found ->
        append_observation(state, outcome, ledger_opts, conflicts_left)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp append_observation(state, outcome, ledger_opts, conflicts_left) do
    with {:ok, now} <- Transaction.trusted_recorded_at(state.clock, state.projection),
         {:ok, payloads} <-
           Observation.payloads(state.projection, outcome, now, state.constitution),
         {:ok, _provisional} <- Transaction.apply_payloads(state.projection, payloads),
         {:ok, batch_id} <- Transaction.operational_id(state, "outcome") do
      expected_revision = state.projection.revision

      append_result =
        Transaction.append_exact(
          state,
          batch_id,
          payloads,
          expected_revision,
          ledger_opts,
          state.ambiguous_retries,
          now
        )

      Commit.resolve(
        state,
        append_result,
        conflicts_left,
        &recovered_outcome(state, &1, outcome),
        &retry_observation_after_conflict(state, outcome, ledger_opts, &1)
      )
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp retry_observation_after_conflict(state, outcome, ledger_opts, conflicts_left) do
    case Transaction.recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        record(
          %{state | projection: projection},
          outcome,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp existing_outcome(projection, outcome) do
    case Map.fetch(projection.outcomes, outcome.ref) do
      {:ok, existing} ->
        if Outcome.canonical(existing) == Outcome.canonical(outcome),
          do: {:ok, existing},
          else: {:error, {:outcome_identity_conflict, outcome.ref}}

      :error ->
        :not_found
    end
  end

  defp recovered_outcome(state, projection, outcome) do
    case existing_outcome(projection, outcome) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        halted = Control.halt(state, :outcome_not_recovered)
        {:error, halted, :outcome_not_recovered}

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, reason}
    end
  end
end
