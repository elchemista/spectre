defmodule Spectre.Duty.Derive.Facts do
  @moduledoc """
  Read-only input prepared for pure Duty derivation.

  Governed records stay as their decoded structs. Ledger position and
  acquisition time stay in `Spectre.Domain.Event.Metadata`, where replay put
  them. This avoids manufacturing a second, map-shaped representation of an
  Act, Evidence or Outcome merely to attach metadata.

  The container also owns the small secondary indexes used repeatedly by Duty
  derivation. It is disposable and carries no authority: the append-only
  ledger remains the source of truth and `Spectre.GovernedAct.State` remains
  the complete replay projection.
  """

  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.State

  @event_types %{
    act: "act_committed",
    attempt: "attempt_started",
    duty: "duty_opened",
    erasure: "erasure_requested",
    evidence: "evidence_recorded",
    mandate: "mandate_issued",
    outcome: "outcome_recorded",
    presentation: "presentation_recorded",
    scope: "scope_opened"
  }

  @enforce_keys [
    :acts,
    :acts_by_ref,
    :attempts,
    :attempts_by_ref,
    :duties,
    :erasures,
    :evidence,
    :event_metadata,
    :mandates,
    :mandates_by_ref,
    :outcomes,
    :outcomes_by_attempt,
    :presentations,
    :presentations_by_ref,
    :scopes
  ]
  defstruct @enforce_keys

  @type kind ::
          :act
          | :attempt
          | :duty
          | :erasure
          | :evidence
          | :mandate
          | :outcome
          | :presentation
          | :scope

  @type t :: %__MODULE__{
          acts: [Spectre.Act.t()],
          acts_by_ref: %{optional(String.t()) => Spectre.Act.t()},
          attempts: [Spectre.Attempt.t()],
          attempts_by_ref: %{optional(String.t()) => Spectre.Attempt.t()},
          duties: [Spectre.Duty.t()],
          erasures: [Spectre.Erasure.t()],
          evidence: [Spectre.Evidence.t()],
          event_metadata: %{optional(Event.key()) => Event.Metadata.t()},
          mandates: [Spectre.Mandate.t()],
          mandates_by_ref: %{optional(String.t()) => Spectre.Mandate.t()},
          outcomes: [Spectre.Outcome.t()],
          outcomes_by_attempt: %{optional(String.t()) => [Spectre.Outcome.t()]},
          presentations: [Spectre.Presentation.t()],
          presentations_by_ref: %{optional(String.t()) => Spectre.Presentation.t()},
          scopes: [Spectre.Scope.Opening.t()]
        }

  @doc "Builds the minimal indexed view used by the Duty algebra."
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    outcomes = Map.values(state.outcomes)

    %__MODULE__{
      acts: Map.values(state.acts),
      acts_by_ref: state.acts,
      attempts: Map.values(state.attempts),
      attempts_by_ref: state.attempts,
      duties: Map.values(state.duties),
      erasures: Map.values(state.erasures),
      evidence: Map.values(state.evidence),
      event_metadata: state.event_metadata,
      mandates: Map.values(state.mandates),
      mandates_by_ref: state.mandates,
      outcomes: outcomes,
      outcomes_by_attempt: Enum.group_by(outcomes, & &1.attempt_ref),
      presentations: Map.values(state.presentations),
      presentations_by_ref: state.presentations,
      scopes: Map.values(state.scopes)
    }
  end

  @doc "Looks up trusted ledger metadata for a typed record identity."
  @spec metadata(t(), kind(), String.t()) ::
          {:ok, Event.Metadata.t()} | {:error, :missing_event_metadata}
  def metadata(%__MODULE__{} = facts, kind, ref)
      when is_map_key(@event_types, kind) and is_binary(ref) do
    case Map.fetch(facts.event_metadata, {Map.fetch!(@event_types, kind), ref}) do
      {:ok, %Event.Metadata{} = metadata} -> {:ok, metadata}
      _missing -> {:error, :missing_event_metadata}
    end
  end

  def metadata(%__MODULE__{}, _kind, _ref), do: {:error, :missing_event_metadata}

  @doc "Returns whether a fact was durably known at the given ledger revision."
  @spec recorded_through?(t(), kind(), String.t(), non_neg_integer()) :: boolean()
  def recorded_through?(%__MODULE__{} = facts, kind, ref, revision) do
    case metadata(facts, kind, ref) do
      {:ok, metadata} -> metadata.revision <= revision
      {:error, :missing_event_metadata} -> false
    end
  end

  @doc "Returns whether a fact was durably available at the given trusted time."
  @spec available_at?(t(), kind(), String.t(), integer()) :: boolean()
  def available_at?(%__MODULE__{} = facts, kind, ref, time) when is_integer(time) do
    case metadata(facts, kind, ref) do
      {:ok, metadata} -> metadata.recorded_at <= time
      {:error, :missing_event_metadata} -> false
    end
  end
end
