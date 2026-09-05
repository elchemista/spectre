defmodule Spectre.Domain.Command.Record do
  @moduledoc """
  Exact-identity recovery shared by durable single-record commands.

  Scope, Presentation and Outcome commands have different validation and event
  semantics, but the same idempotency rule: an existing reference is reusable
  only when the complete normalized record is equal. After a successful append,
  absence or a different record is a fatal recovery contradiction.

  This module deliberately does not build events, choose collections or append
  to the ledger. Those responsibilities remain explicit in each command.
  """

  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.GovernedAct.State, as: GovernedState

  @type lookup(record) :: {:ok, record} | :not_found | {:error, term()}

  @doc "Looks up one normalized record under exact identity semantics."
  @spec lookup(map(), struct(), atom()) :: lookup(struct())
  def lookup(index, %{ref: ref} = expected, conflict)
      when is_map(index) and is_binary(ref) and ref != "" and is_atom(conflict) do
    case Map.fetch(index, ref) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _different} -> {:error, {conflict, ref}}
      :error -> :not_found
    end
  end

  @doc "Returns an exact recovered record or halts state on a contradiction."
  @spec recover(State.t(), GovernedState.t(), map(), struct(), atom(), atom()) ::
          {:ok, State.t(), struct()} | {:error, State.t(), term()}
  def recover(
        %State{} = state,
        %GovernedState{} = projection,
        index,
        expected,
        conflict,
        missing
      )
      when is_map(index) and is_atom(conflict) and is_atom(missing) do
    case lookup(index, expected, conflict) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        {:error, Control.halt(state, missing), missing}

      {:error, reason} ->
        {:error, Control.halt(state, reason), reason}
    end
  end
end
