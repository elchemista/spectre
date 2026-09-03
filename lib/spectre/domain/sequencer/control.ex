defmodule Spectre.Domain.Sequencer.Control do
  @moduledoc """
  Process-control invariants shared by Domain command workflows.

  A fatal durable-state error marks the current state and asks the owning
  GenServer to stop. The supervisor can then rebuild from the ledger; a Domain
  is never left alive while permanently refusing work.
  """

  alias Spectre.Domain.Sequencer.State

  @doc "Marks the first fatal reason and schedules termination of the owning Sequencer."
  @spec halt(State.t(), term()) :: State.t()
  def halt(%State{halted_reason: nil} = state, reason) do
    send(self(), {:stop_halted, reason})
    %{state | halted_reason: reason}
  end

  def halt(%State{} = state, _reason), do: state
end
