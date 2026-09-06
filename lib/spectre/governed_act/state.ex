defmodule Spectre.GovernedAct.State do
  @moduledoc """
  Disposable state derived from a verified governed history.

  This struct is a read model, never an authority store. Every field can be
  rebuilt from the append-only ledger through `Spectre.GovernedAct.Fold`.
  Keeping the container separate from the reducer lets transition modules share
  one explicit shape without turning the fold itself into a mutable domain
  object.

  Governed declarations live together in `Spectre.GovernedAct.Catalog`;
  execution, information lineage and accounting stay on this state. Both
  containers have fixed, compact shapes and share their immutable records.
  """

  alias Spectre.{
    Act,
    Attempt,
    Decision,
    Declassification,
    Duty,
    Erasure,
    Evidence,
    HostProfile,
    Mandate,
    Outcome,
    Presentation,
    Surface
  }

  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Catalog
  alias Spectre.GovernedAct.DispatchState
  alias Spectre.Kernel.Meter
  alias Spectre.Ledger.Entry
  alias Spectre.Mandate.Revocation

  @enforce_keys [:domain_ref]
  defstruct domain_ref: nil,
            # Durable cursor. `event_metadata` is intentionally sparse and is
            # retained only for facts whose acquisition order affects derivation.
            constitution: %{},
            revision: 0,
            head_digest: Entry.genesis_digest(),
            recorded_at: 0,
            event_metadata: %{},
            # Governed declarations plus O(1) pointers to current revisions.
            catalog: %Catalog{},
            # Authority history and subtractive-lineage indexes.
            mandates: %{},
            mandate_successors: %{},
            revocations: %{},
            # Information lineage.
            declassifications: %{},
            declassifications_by_evidence: %{},
            evidence: %{},
            presentations: %{},
            erasures: %{},
            # Admission and world-side history.
            decisions: %{},
            admissions: %{},
            acts: %{},
            attempts: %{},
            outcomes: %{},
            pending_dispatches: MapSet.new(),
            terminal_dispatches: %{},
            consumed_nonces: MapSet.new(),
            # Conserved Meter state. Immutable reservation bindings remain on
            # their Acts; this projection stores only mutable statuses/indexes.
            meters: %{},
            meter_owner_aliases: %{},
            meter_reservations: %{},
            meter_recontainments: %{},
            duty_meter_resolutions: MapSet.new(),
            meter_devolutions: MapSet.new(),
            # Causal obligations and stable ref lookup.
            duties: %{},
            # Rebuildable operational indexes, never canonical authority.
            read_index: %Spectre.GovernedAct.ReadIndex{}

  @type t :: %__MODULE__{
          domain_ref: String.t(),
          constitution: map(),
          revision: non_neg_integer(),
          head_digest: String.t(),
          recorded_at: non_neg_integer(),
          event_metadata: %{optional(String.t()) => Event.Metadata.t()},
          catalog: Catalog.t(),
          mandates: %{optional(String.t()) => Mandate.t()},
          mandate_successors: %{optional(String.t()) => String.t()},
          revocations: %{optional(String.t()) => Revocation.t()},
          declassifications: %{optional(String.t()) => Declassification.t()},
          declassifications_by_evidence: %{optional(String.t()) => String.t()},
          evidence: %{optional(String.t()) => Evidence.t()},
          presentations: %{optional(String.t()) => Presentation.t()},
          decisions: %{optional(String.t()) => Decision.t()},
          admissions: %{optional(String.t()) => admission()},
          acts: %{optional(String.t()) => Act.t()},
          attempts: %{optional(String.t()) => Attempt.t()},
          outcomes: %{optional(String.t()) => Outcome.t()},
          meters: %{optional(String.t()) => Meter.accounts()},
          meter_owner_aliases: %{optional(String.t()) => String.t()},
          meter_reservations: %{optional(String.t()) => reservation_status()},
          meter_recontainments: %{optional(String.t()) => meter_recontainment()},
          duty_meter_resolutions: MapSet.t(String.t()),
          meter_devolutions: MapSet.t(String.t()),
          pending_dispatches: MapSet.t(String.t()),
          terminal_dispatches: %{optional(String.t()) => DispatchState.terminal()},
          consumed_nonces: MapSet.t(String.t()),
          duties: %{optional(term()) => Duty.t()},
          read_index: Spectre.GovernedAct.ReadIndex.t(),
          erasures: %{optional(String.t()) => Erasure.t()}
        }

  @type reservation_status :: :reserved | :suspended | :settled | :released
  @type admission :: %{
          required(:decision_ref) => String.t(),
          required(:act_ref) => String.t() | nil
        }

  @type dispatch_cancellation :: DispatchState.cancellation()

  @type meter_reservation :: %{
          required(:mandate_ref) => String.t(),
          required(:amounts) => %{optional(String.t()) => non_neg_integer()},
          required(:status) => reservation_status()
        }

  @type meter_recontainment :: %{
          required(:outcome_ref) => String.t(),
          required(:cause_key) => term(),
          required(:recontained) => %{optional(String.t()) => pos_integer()},
          required(:deficits) => %{optional(String.t()) => pos_integer()},
          required(:disposition_act_ref) => String.t() | nil
        }

  @spec new(String.t(), map()) :: t()
  def new(domain_ref, constitution \\ %{})

  def new(domain_ref, constitution)
      when is_binary(domain_ref) and domain_ref != "" and is_map(constitution) and
             not is_struct(constitution),
      do: %__MODULE__{domain_ref: domain_ref, constitution: constitution}

  @doc "Returns the current HostProfile from its single historical collection."
  @spec host_profile(t()) :: HostProfile.t() | nil
  def host_profile(%__MODULE__{
        catalog: %Catalog{host_profile_ref: ref, host_profiles: profiles}
      }),
      do: Map.get(profiles, ref)

  @doc "Returns the current Surface from its single historical collection."
  @spec surface(t()) :: Surface.t() | nil
  def surface(%__MODULE__{catalog: %Catalog{surface_ref: ref, surfaces: surfaces}}),
    do: Map.get(surfaces, ref)
end
