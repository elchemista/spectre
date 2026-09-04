defmodule Spectre.Erasure.Analysis.Facts do
  @moduledoc """
  Typed, read-only inputs for causal erasure analysis.

  Live callers use `from_state/1`. Historical consumers may construct a
  prefix with the same decoded record maps. This keeps canonical maps at the
  ledger boundary and prevents erasure semantics from guessing atom keys,
  string keys, structs or lists on every access.
  """

  alias Spectre.GovernedAct.State

  defstruct evidence: %{},
            presentations: %{},
            acts: %{},
            decisions: %{},
            attempts: %{},
            outcomes: %{},
            duties: %{},
            declassifications: %{},
            erasures: %{},
            terminal_dispatches: %{}

  @type t :: %__MODULE__{
          evidence: %{optional(String.t()) => Spectre.Evidence.t()},
          presentations: %{optional(String.t()) => Spectre.Presentation.t()},
          acts: %{optional(String.t()) => Spectre.Act.t()},
          decisions: %{optional(String.t()) => Spectre.Decision.t()},
          attempts: %{optional(String.t()) => Spectre.Attempt.t()},
          outcomes: %{optional(String.t()) => Spectre.Outcome.t()},
          duties: %{optional(term()) => Spectre.Duty.t()},
          declassifications: %{optional(String.t()) => Spectre.Declassification.t()},
          erasures: %{optional(String.t()) => Spectre.Erasure.t()},
          terminal_dispatches: map()
        }

  @doc "Builds the erasure view of a complete folded Domain state."
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    %__MODULE__{
      evidence: state.evidence,
      presentations: state.presentations,
      acts: state.acts,
      decisions: state.decisions,
      attempts: state.attempts,
      outcomes: state.outcomes,
      duties: state.duties,
      declassifications: state.declassifications,
      erasures: state.erasures,
      terminal_dispatches: state.terminal_dispatches
    }
  end

  @doc false
  @spec coerce(State.t() | t()) :: {:ok, t()} | {:error, :invalid_erasure_facts}
  def coerce(%__MODULE__{} = facts), do: {:ok, facts}
  def coerce(%State{} = state), do: {:ok, from_state(state)}
  def coerce(_facts), do: {:error, :invalid_erasure_facts}
end
