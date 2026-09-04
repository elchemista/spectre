defmodule Spectre.Domain.Command.Commit do
  @moduledoc """
  Shared append and completion policy for a durable Domain command.

  Command modules still own planning, conflict re-planning and recovery checks.
  This helper owns the mechanical boundary they all share: obtain an operational
  batch identity, append once, recover after a CAS conflict, and classify fatal
  durability failures. Ordinary adapter errors are returned; exhausted or
  ambiguous commits stop the Sequencer so supervision can recover from ledger
  truth.
  """

  alias Spectre.Domain.Transaction
  alias Spectre.Domain.Sequencer.{Control, State}

  @type command_result(value) ::
          {:ok, State.t(), value} | {:error, State.t(), term()}

  @doc "Repairs derivable Duties before a command observes or changes Domain state."
  @spec prepare(State.t()) :: {:ok, State.t()} | {:error, State.t(), term()}
  def prepare(%State{} = state) do
    case Transaction.repair_missing_duties(state) do
      {:ok, projection} ->
        {:ok, %{state | projection: projection}}

      {:error, reason} ->
        tagged = {:preflight_duty_repair_failed, reason}
        {:error, Control.halt(state, tagged), tagged}
    end
  end

  @doc "Appends payloads and invokes command-specific recovery or re-planning callbacks."
  @spec append(
          State.t(),
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          (term() -> command_result(term())),
          (State.t(), non_neg_integer() -> command_result(term()))
        ) :: command_result(term())
  def append(
        %State{} = state,
        payloads,
        recorded_at,
        conflicts_left,
        on_success,
        on_conflict
      )
      when is_list(payloads) and is_integer(recorded_at) and recorded_at >= 0 and
             is_integer(conflicts_left) and conflicts_left >= 0 and is_function(on_success, 1) and
             is_function(on_conflict, 2) do
    with {:ok, batch_id} <- Transaction.operational_id(state) do
      state
      |> Transaction.append_exact(batch_id, payloads, recorded_at)
      |> resolve(state, conflicts_left, on_success, on_conflict)
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp resolve(append_result, state, conflicts_left, on_success, on_conflict) do
    case append_result do
      {:ok, recovered} ->
        on_success.(recovered)

      :conflict when conflicts_left > 0 ->
        retry_after_conflict(state, conflicts_left - 1, on_conflict)

      :conflict ->
        fatal(state, :conflict_retries_exhausted, :conflict_retries_exhausted)

      {:error, {:durable_recovery_failed, reason}} ->
        fatal(state, reason, {:durable_recovery_failed, reason})

      {:error, :ambiguous_commit_unresolved} ->
        fatal(state, :ambiguous_commit_unresolved, :ambiguous_commit_unresolved)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp retry_after_conflict(state, conflicts_left, on_conflict) do
    case Transaction.recover_with_repair(state) do
      {:ok, projection} -> on_conflict.(%{state | projection: projection}, conflicts_left)
      {:error, reason} -> fatal(state, reason, {:durable_recovery_failed, reason})
    end
  end

  defp fatal(state, halt_reason, reply_reason),
    do: {:error, Control.halt(state, halt_reason), reply_reason}
end
