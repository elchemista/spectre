defmodule Spectre.GovernedAct.State do
  @moduledoc """
  Disposable state derived from a verified governed history.

  This struct is a read model, never an authority store. Every field can be
  rebuilt from the append-only ledger through `Spectre.GovernedAct.Fold`.
  Keeping the container separate from the reducer lets transition modules share
  one explicit shape without turning the fold itself into a mutable domain
  object.
  """

  alias Spectre.{Declassification, Definition, Erasure, HostProfile, Surface}
  alias Spectre.Domain.Event
  alias Spectre.Ledger.Entry
  alias Spectre.Mandate.Revocation
  alias Spectre.Scope.Opening

  @enforce_keys [:domain_ref]
  defstruct domain_ref: nil,
            constitution: %{},
            revision: 0,
            head_digest: Entry.genesis_digest(),
            recorded_at: 0,
            event_metadata: %{},
            genesis: nil,
            host_profile: nil,
            host_profiles: %{},
            surface: nil,
            surfaces: %{},
            principals: %{},
            mandates: %{},
            mandate_successors: %{},
            mandate_predecessors: %{},
            revocations: %{},
            declassifications: %{},
            declassifications_by_act: %{},
            declassifications_by_evidence: %{},
            evidence: %{},
            presentations: %{},
            decisions: %{},
            candidate_identities: %{},
            acts: %{},
            acts_by_decision: %{},
            attempts: %{},
            attempts_by_act: %{},
            outcomes: %{},
            meters: %{},
            meter_owners: %{},
            reservation_states: %{},
            reservation_bindings: %{},
            meter_recontainments: %{},
            duty_meter_resolutions: %{},
            meter_devolutions: MapSet.new(),
            dispatch_ready: MapSet.new(),
            dispatch_cancellations: %{},
            consumed_nonces: MapSet.new(),
            duties: %{},
            duty_refs: %{},
            scopes: %{},
            definitions: %{},
            definition_heads: %{},
            erasures: %{},
            erasures_by_act: %{}

  @type t :: %__MODULE__{
          domain_ref: String.t(),
          constitution: map(),
          revision: non_neg_integer(),
          head_digest: String.t(),
          recorded_at: non_neg_integer(),
          event_metadata: %{optional(Event.key()) => Event.Metadata.t()},
          genesis: struct() | map() | nil,
          host_profile: struct() | map() | nil,
          host_profiles: %{optional(String.t()) => HostProfile.t()},
          surface: struct() | map() | nil,
          surfaces: %{optional(String.t()) => Surface.t()},
          principals: map(),
          mandates: map(),
          mandate_successors: %{optional(String.t()) => String.t()},
          mandate_predecessors: %{optional(String.t()) => String.t()},
          revocations: %{optional(String.t()) => Revocation.t()},
          declassifications: %{optional(String.t()) => Declassification.t()},
          declassifications_by_act: %{optional(String.t()) => String.t()},
          declassifications_by_evidence: %{optional(String.t()) => String.t()},
          evidence: map(),
          presentations: map(),
          decisions: map(),
          candidate_identities: map(),
          acts: map(),
          acts_by_decision: %{optional(String.t()) => String.t()},
          attempts: map(),
          attempts_by_act: map(),
          outcomes: map(),
          meters: map(),
          meter_owners: %{optional(String.t()) => String.t()},
          reservation_states: %{optional(String.t()) => reservation_status()},
          reservation_bindings: %{optional(String.t()) => reservation_binding()},
          meter_recontainments: %{optional(String.t()) => meter_recontainment()},
          duty_meter_resolutions: %{optional(String.t()) => duty_meter_resolution()},
          meter_devolutions: MapSet.t(),
          dispatch_ready: MapSet.t(),
          dispatch_cancellations: %{optional(String.t()) => dispatch_cancellation()},
          consumed_nonces: MapSet.t(),
          duties: %{optional(term()) => Spectre.Duty.t()},
          duty_refs: %{optional(String.t()) => term()},
          scopes: %{optional(String.t()) => Opening.t()},
          definitions: %{optional(String.t()) => Definition.t()},
          definition_heads: %{optional({String.t(), String.t()}) => String.t()},
          erasures: %{optional(String.t()) => Erasure.t()},
          erasures_by_act: %{optional(String.t()) => String.t()}
        }

  @type reservation_status :: :reserved | :suspended | :settled | :released
  @type dispatch_cancellation :: %{
          required(:act_ref) => String.t(),
          required(:mandate_ref) => String.t(),
          required(:cause_ref) => String.t(),
          required(:reason) =>
            :mandate_revoked | :mandate_restricted | :mandate_expired | :disputed_evidence,
          required(:cancelled_at) => non_neg_integer()
        }

  @type reservation_binding :: %{
          required(:act_ref) => String.t(),
          required(:mandate_ref) => String.t(),
          required(:amounts) => %{optional(String.t()) => non_neg_integer()}
        }

  @type meter_recontainment :: %{
          required(:act_ref) => String.t(),
          required(:mandate_ref) => String.t(),
          required(:outcome_ref) => String.t(),
          required(:cause_key) => term(),
          required(:amounts) => %{optional(String.t()) => pos_integer()},
          required(:recontained) => %{optional(String.t()) => pos_integer()},
          required(:deficits) => %{optional(String.t()) => pos_integer()},
          required(:status) => :open | :disposed,
          required(:disposition_act_ref) => String.t() | nil
        }

  @type duty_meter_resolution :: %{
          required(:act_ref) => String.t(),
          required(:disposition_act_ref) => String.t(),
          required(:duty_ref) => String.t(),
          required(:mandate_ref) => String.t(),
          required(:operation) => :settle | :release,
          required(:amounts) => %{optional(String.t()) => pos_integer()}
        }

  @spec new(String.t(), map()) :: t()
  def new(domain_ref, constitution \\ %{})

  def new(domain_ref, constitution)
      when is_binary(domain_ref) and domain_ref != "" and is_map(constitution) and
             not is_struct(constitution),
      do: %__MODULE__{domain_ref: domain_ref, constitution: constitution}
end
