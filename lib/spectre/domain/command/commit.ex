defmodule Spectre.Domain.Command.Commit do
  @moduledoc """
  Shared completion policy for a durable Domain command.

  Command modules still own planning, conflict re-planning and recovery checks.
  This helper centralizes the invariant response to an exact append: ordinary
  adapter errors are returned, CAS conflicts may retry, while exhausted or
  ambiguous durability failures stop the Sequencer so supervision can recover
  from ledger truth.
  """

  alias Spectre.Domain.Sequencer.{Control, State}

  @type command_result(value) ::
          {:ok, State.t(), value} | {:error, State.t(), term()}

  @doc "Resolves an append result through command-specific success and retry callbacks."
  @spec resolve(
          State.t(),
          {:ok, term()} | :conflict | {:error, term()},
          non_neg_integer(),
          (term() -> command_result(term())),
          (non_neg_integer() -> command_result(term()))
        ) :: command_result(term())
  def resolve(%State{} = state, append_result, conflicts_left, on_success, on_conflict)
      when is_integer(conflicts_left) and conflicts_left >= 0 and is_function(on_success, 1) and
             is_function(on_conflict, 1) do
    case append_result do
      {:ok, recovered} ->
        on_success.(recovered)

      :conflict when conflicts_left > 0 ->
        on_conflict.(conflicts_left - 1)

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

  defp fatal(state, halt_reason, reply_reason),
    do: {:error, Control.halt(state, halt_reason), reply_reason}
end
