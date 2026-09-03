defmodule Spectre.Domain.Projection do
  @moduledoc """
  Deterministic read model rebuilt from a verified Domain ledger snapshot.

  This module is not an authority store. Its maps are disposable projections;
  `replay/1` first verifies the complete ledger chain and then derives them in
  revision order. Cross-record checks reject histories that are structurally
  valid ledgers but violate the governed-act lifecycle.
  """

  alias Spectre.{
    Act,
    Candidate,
    Condition,
    Constitution,
    Declassification,
    Definition,
    Disclosure,
    Duty,
    Erasure,
    Evidence,
    Governance,
    HostProfile,
    Mandate,
    Outcome,
    Presentation,
    Row,
    SubmissionContext,
    Surface
  }

  alias Spectre.Duty.{Derive, Disposition, EvidenceCause}
  alias Spectre.Duty.Authority, as: DutyAuthority
  alias Spectre.Evidence.Derivation
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Kernel.{Authority, Meter, Recognition}
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Mandate.Ancestry
  alias Spectre.Outcome.Attestation
  alias Spectre.Scope.Opening

  @known_events ~w(
    genesis_recorded
    principal_recorded
    host_profile_recorded
    host_profile_revised
    surface_recorded
    surface_revised
    mandate_issued
    mandate_restricted
    mandate_revoked
    declassification_recorded
    evidence_recorded
    presentation_recorded
    decision_recorded
    act_committed
    meter_reserved
    meter_settled
    meter_released
    meter_suspended
    meter_recontained
    meter_duty_resolved
    meter_devolved
    dispatch_ready
    dispatch_cancelled
    attempt_started
    outcome_recorded
    duty_opened
    duty_disposed
    scope_opened
    definition_revised
    erasure_requested
  )
  @event_fields [:type, :identity, :data, :schema_version]
  @manual_event_fields %{
    "mandate_revoked" => [:mandate_ref, :effective_at],
    "mandate_restricted" => [:act_ref, :predecessor_ref, :successor],
    "host_profile_revised" => [:act_ref, :previous_ref, :host_profile],
    "surface_revised" => [:act_ref, :previous_ref, :surface],
    "definition_revised" => [:act_ref, :previous_ref, :definition],
    "meter_reserved" => [:act_ref, :mandate_ref, :amounts],
    "meter_settled" => [:act_ref, :mandate_ref, :amounts],
    "meter_released" => [:act_ref, :mandate_ref, :amounts],
    "meter_suspended" => [:act_ref, :mandate_ref, :amounts],
    "meter_recontained" => [
      :act_ref,
      :mandate_ref,
      :outcome_ref,
      :amounts,
      :recontained,
      :deficits
    ],
    "meter_duty_resolved" => [
      :act_ref,
      :disposition_act_ref,
      :duty_ref,
      :mandate_ref,
      :operation,
      :amounts
    ],
    "meter_devolved" => [:act_ref, :child_mandate_ref, :amounts],
    "dispatch_ready" => [:act_ref, :executor_ref, :executor_contract_ref],
    "dispatch_cancelled" => [
      :act_ref,
      :mandate_ref,
      :cause_ref,
      :reason,
      :cancelled_at
    ],
    "duty_disposed" => [:cause_key, :disposition_act_ref]
  }

  @enforce_keys [:domain_ref]
  defstruct domain_ref: nil,
            constitution: %{},
            revision: 0,
            head_digest: Entry.genesis_digest(),
            event_recorded_at: %{},
            event_revisions: %{},
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
          event_recorded_at: %{
            optional({String.t(), String.t()}) => non_neg_integer()
          },
          event_revisions: %{
            optional({String.t(), String.t()}) => pos_integer()
          },
          genesis: struct() | map() | nil,
          host_profile: struct() | map() | nil,
          host_profiles: %{optional(String.t()) => HostProfile.t()},
          surface: struct() | map() | nil,
          surfaces: %{optional(String.t()) => Surface.t()},
          principals: map(),
          mandates: map(),
          mandate_successors: %{optional(String.t()) => String.t()},
          mandate_predecessors: %{optional(String.t()) => String.t()},
          revocations: map(),
          declassifications: %{optional(String.t()) => Declassification.t()},
          declassifications_by_act: %{optional(String.t()) => String.t()},
          declassifications_by_evidence: %{optional(String.t()) => String.t()},
          evidence: map(),
          presentations: map(),
          decisions: map(),
          candidate_identities: map(),
          acts: map(),
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

  @doc "Rebuilds a projection only after independently verifying the supplied ledger snapshot."
  @spec replay(Ledger.snapshot(), map()) :: {:ok, t()} | {:error, term()}
  def replay(snapshot, constitution \\ %{})

  def replay(snapshot, constitution)
      when is_map(snapshot) and not is_struct(snapshot) and is_map(constitution) and
             not is_struct(constitution) do
    with :ok <- Constitution.validate(constitution),
         {:ok, verified} <- Ledger.verify_snapshot(snapshot) do
      replay_entries(verified.domain_ref, verified.entries, constitution)
    end
  end

  def replay(_snapshot, _constitution), do: {:error, :invalid_domain_snapshot}

  @spec replay_entries(String.t(), [Entry.t()], map()) :: {:ok, t()} | {:error, term()}
  defp replay_entries(domain_ref, entries, constitution) do
    entries
    |> Enum.chunk_by(& &1.batch_id)
    |> Enum.reduce_while({:ok, new(domain_ref, constitution)}, fn batch, {:ok, projection} ->
      case replay_batch(projection, batch) do
        {:ok, projection} -> {:cont, {:ok, projection}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projection} ->
        with :ok <- validate_complete_history(projection), do: {:ok, projection}

      {:error, _reason} = error ->
        error
    end
  end

  defp replay_batch(projection, entries) do
    with :ok <- validate_batch_events(entries),
         {:ok, next} <- apply_batch_entries(projection, entries),
         :ok <- validate_batch_lifecycle(projection, next, entries) do
      {:ok, next}
    end
  end

  defp apply_batch_entries(projection, entries) do
    Enum.reduce_while(entries, {:ok, projection}, fn entry, {:ok, current} ->
      case apply_entry(current, entry) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_batch_events(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case validate_event(entry.payload) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_batch_lifecycle(before, after_projection, entries) do
    events =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        %{
          type: field(entry.payload, :type),
          identity: field(entry.payload, :identity),
          data: field(entry.payload, :data),
          index: index,
          recorded_at: entry.recorded_at
        }
      end)

    with :ok <- validate_dispatch_expiration_batch(before, events),
         :ok <- validate_admission_batch(before, after_projection, events),
         :ok <- validate_world_stage_batch(before, events),
         :ok <- validate_foundation_batch(events),
         :ok <- validate_mandate_batch(after_projection, events),
         :ok <- validate_governance_batch(events) do
      validate_meter_batch(before, after_projection, events)
    end
  end

  defp validate_dispatch_expiration_batch(_before, []), do: :ok

  defp validate_dispatch_expiration_batch(before, [%{recorded_at: recorded_at} | _] = events) do
    with {:ok, expired} <- expired_pending_dispatches(before, recorded_at),
         {:ok, expected_events} <- expected_dispatch_expiration_events(expired),
         true <-
           Enum.all?(events, &(&1.recorded_at == recorded_at)) and
             expiration_event_refs(events) == Enum.map(expired, fn {act, _mandate} -> act.ref end) and
             exact_event_sequence?(events, expected_events, 0) do
      :ok
    else
      false -> {:error, :dispatch_expiration_batch_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp expired_pending_dispatches(projection, recorded_at) do
    projection.dispatch_ready
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, expired} ->
      with {:ok, act} <- fetch_act(projection, act_ref),
           {:ok, mandate} <- fetch_mandate(projection, act.mandate_ref),
           true <- Governance.executor_mediated?(act),
           true <- act.mandate_revision == mandate.revision,
           false <- Map.has_key?(projection.attempts_by_act, act.ref),
           false <- Map.has_key?(projection.dispatch_cancellations, act.ref) do
        if mandate.expires_at <= recorded_at,
          do: {:cont, {:ok, [{act, mandate} | expired]}},
          else: {:cont, {:ok, expired}}
      else
        false -> {:halt, {:error, {:invalid_pending_dispatch, act_ref}}}
        true -> {:halt, {:error, {:terminal_pending_dispatch, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, expired} -> {:ok, Enum.reverse(expired)}
      {:error, _reason} = error -> error
    end
  end

  defp expected_dispatch_expiration_events(expired) do
    Enum.reduce_while(expired, {:ok, []}, fn {act, mandate}, {:ok, events} ->
      expiration =
        {"dispatch_cancelled", "dispatch_cancelled:" <> act.ref,
         %{
           "act_ref" => act.ref,
           "mandate_ref" => mandate.ref,
           "cause_ref" => mandate.ref,
           "reason" => :mandate_expired,
           "cancelled_at" => mandate.expires_at
         }}

      if has_reservations?(act) do
        case normalize_reservation_amounts(act.reservations) do
          {:ok, amounts} ->
            release =
              {"meter_released", "meter_released:" <> act.ref,
               %{
                 "act_ref" => act.ref,
                 "mandate_ref" => mandate.ref,
                 "amounts" => amounts
               }}

            {:cont, {:ok, events ++ [expiration, release]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      else
        {:cont, {:ok, events ++ [expiration]}}
      end
    end)
  end

  defp expiration_event_refs(events) do
    events
    |> Enum.filter(
      &(&1.type == "dispatch_cancelled" and field(&1.data, :reason) == :mandate_expired)
    )
    |> Enum.sort_by(& &1.index)
    |> Enum.map(&field(&1.data, :act_ref))
  end

  defp exact_event_sequence?(events, expected, first_index) do
    expected
    |> Enum.with_index(first_index)
    |> Enum.all?(fn {{type, identity, data}, index} ->
      exact_manual_event_at?(events, index, type, identity, data)
    end)
  end

  defp validate_admission_batch(before, projection, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "decision_recorded" ->
            validate_decision_batch_event(projection, events, event)

          "act_committed" ->
            validate_act_batch_event(before, projection, events, event)

          "dispatch_ready" ->
            validate_dispatch_batch_event(events, event)

          "dispatch_cancelled" ->
            validate_dispatch_cancellation_batch_event(events, event)

          "duty_opened" ->
            validate_disputed_dispatch_cancellation_batch(before, projection, events, event)

          _other ->
            :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_decision_batch_event(projection, events, event) do
    decision = Map.fetch!(projection.decisions, event.identity)

    acts =
      Enum.filter(
        events,
        &(&1.type == "act_committed" and field(&1.data, :decision_ref) == event.identity)
      )

    case {decision.outcome, acts} do
      {:admitted, [%{index: act_index}]} when act_index == event.index + 1 -> :ok
      {:admitted, _other} -> {:error, {:admitted_decision_batch_incomplete, decision.ref}}
      {_not_admitted, []} -> :ok
      {_not_admitted, _acts} -> {:error, {:non_admitted_decision_has_batch_act, decision.ref}}
    end
  end

  defp validate_act_batch_event(before, projection, events, event) do
    act = Map.fetch!(projection.acts, event.identity)
    previous = Enum.find(events, &(&1.index == event.index - 1))

    cond do
      is_nil(previous) or previous.type != "decision_recorded" or
          previous.identity != act.decision_ref ->
        {:error, {:act_outside_admission_batch, act.ref}}

      has_reservations?(act) and
          not batch_event?(events, "meter_reserved", "meter_reserved:" <> act.ref, event.index) ->
        {:error, {:act_reservation_missing_from_admission_batch, act.ref}}

      has_reservations?(act) and not Governance.executor_mediated?(act) and
          not internal_settlement_at?(events, act, event.index) ->
        {:error, {:internal_act_settlement_missing_from_admission_batch, act.ref}}

      Governance.executor_mediated?(act) and
          not batch_event?(events, "dispatch_ready", "dispatch_ready:" <> act.ref, event.index) ->
        {:error, {:act_dispatch_missing_from_admission_batch, act.ref}}

      true ->
        validate_governance_act_batch(before, projection, events, act, event.index)
    end
  end

  defp validate_governance_act_batch(before, projection, events, act, after_index) do
    case exact_governance_effect?(events, act, after_index) do
      true -> validate_authority_cancellation_batch(before, projection, events, act, after_index)
      false -> {:error, {:governance_act_batch_incomplete, act.ref, act.class}}
      :unsupported -> {:error, {:unsupported_governance_act_class, act.ref, act.class}}
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "mandate.delegate", consequence: %{"mandate_issue" => draft}} = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, mandate} <- Mandate.from_issue_draft(draft, act.ref) do
      exact_record_event_at?(events, act_index + 1, "mandate_issued", Mandate, mandate)
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "mandate.revoke",
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 1 do
    exact_manual_event_at?(
      events,
      act_index + 1,
      "mandate_revoked",
      act.ref,
      %{"mandate_ref" => mandate_ref, "effective_at" => act.committed_at}
    )
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" =>
               %{"predecessor_ref" => predecessor_ref, "successor" => draft} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor} <- Mandate.from_issue_draft(draft, act.ref) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "mandate_restricted",
        act.ref,
        predecessor_ref,
        :predecessor_ref,
        :successor,
        Mandate,
        successor
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "mandate.devolve",
           consequence: %{
             "mandate_devolve" =>
               %{"child_mandate_ref" => child_ref, "amounts" => amounts} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    exact_manual_event_at?(
      events,
      act_index + 1,
      "meter_devolved",
      "meter_devolved:" <> act.ref,
      %{"act_ref" => act.ref, "child_mandate_ref" => child_ref, "amounts" => amounts}
    )
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "surface.revise",
           consequence: %{
             "surface_revision" =>
               %{"previous_ref" => previous_ref, "surface" => canonical} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, surface} <- Surface.from_canonical(canonical) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "surface_revised",
        act.ref,
        previous_ref,
        :previous_ref,
        :surface,
        Surface,
        surface
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "host_profile.revise",
           consequence: %{
             "host_profile_revision" =>
               %{"previous_ref" => previous_ref, "host_profile" => canonical} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, profile} <- HostProfile.from_canonical(canonical) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "host_profile_revised",
        act.ref,
        previous_ref,
        :previous_ref,
        :host_profile,
        HostProfile,
        profile
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "definition.revise",
           consequence: %{
             "definition_revision" =>
               %{"previous_ref" => previous_ref, "definition" => canonical} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, definition} <- Definition.from_canonical(canonical) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "definition_revised",
        act.ref,
        previous_ref,
        :previous_ref,
        :definition,
        Definition,
        definition
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "data.declassify", consequence: %{"evidence_declassification" => draft}} =
           act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, decoded} <- Declassification.decode_draft(draft),
         {:ok, declassification} <-
           Declassification.from_draft(decoded.canonical, act.ref, act.committed_at) do
      exact_record_event_at?(
        events,
        act_index + 1,
        "declassification_recorded",
        Declassification,
        declassification
      ) and
        exact_record_event_at?(
          events,
          act_index + 2,
          "evidence_recorded",
          Evidence,
          decoded.evidence
        )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, canonical} <- Erasure.request_draft(draft),
         true <- canonical == draft,
         {:ok, erasure} <- Erasure.from_request_draft(canonical, act.ref) do
      exact_record_event_at?(
        events,
        act_index + 1,
        "erasure_requested",
        Erasure,
        erasure
      )
    else
      _invalid -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "scope.open", consequence: %{"scope_open" => draft}} = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, opening} <- Opening.from_governed_draft(draft, act.ref, act.committed_at) do
      exact_record_event_at?(events, act_index + 1, "scope_opened", Opening, opening)
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "duty.dispose"} = act,
         act_index
       ) do
    duty_disposition_batch_complete?(events, act, act_index)
  end

  defp exact_governance_effect?(_events, %Act{class: class}, _act_index)
       when class in [
              "mandate.delegate",
              "mandate.restrict",
              "mandate.revoke",
              "mandate.devolve",
              "surface.revise",
              "host_profile.revise",
              "definition.revise",
              "data.declassify",
              "data.erase",
              "scope.open",
              "duty.dispose"
            ],
       do: false

  defp exact_governance_effect?(_events, %Act{} = act, _act_index) do
    if act.row.delegate or act.row.govern, do: :unsupported, else: true
  end

  defp exact_record_event_at?(events, index, type, module, expected) do
    case event_at(events, index) do
      %{type: ^type, identity: identity, data: data} ->
        identity == record_ref(expected) and decode(module, data) == {:ok, expected}

      _missing_or_different ->
        false
    end
  end

  defp exact_embedded_event_at?(
         events,
         index,
         type,
         act_ref,
         relation_ref,
         relation_key,
         record_key,
         module,
         expected
       ) do
    case event_at(events, index) do
      %{type: ^type, identity: identity, data: data} ->
        identity == record_ref(expected) and field(data, :act_ref) == act_ref and
          field(data, relation_key) == relation_ref and
          decode(module, field(data, record_key)) == {:ok, expected}

      _missing_or_different ->
        false
    end
  end

  defp exact_manual_event_at?(events, index, type, identity, expected_data) do
    case event_at(events, index) do
      %{type: ^type, identity: ^identity, data: data} ->
        Enum.all?(expected_data, fn {key, value} -> field(data, key) == value end)

      _missing_or_different ->
        false
    end
  end

  defp event_at(events, index), do: Enum.find(events, &(&1.index == index))

  defp validate_dispatch_batch_event(events, event) do
    act_ref = field(event.data, :act_ref)

    if batch_event?(events, "act_committed", act_ref, -1),
      do: :ok,
      else: {:error, {:dispatch_outside_admission_batch, act_ref}}
  end

  defp validate_dispatch_cancellation_batch_event(events, event) do
    cause_ref = field(event.data, :cause_ref)

    case field(event.data, :reason) do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        if batch_event?(events, "act_committed", cause_ref, -1),
          do: :ok,
          else: {:error, {:dispatch_cancellation_outside_governance_batch, event.identity}}

      :disputed_evidence ->
        case event_at(events, event.index - 1) do
          %{type: "duty_opened", identity: ^cause_ref, data: duty_data} ->
            with {:ok, duty} <- decode(Spectre.Duty, duty_data),
                 true <- duty.class == :disputed_evidence,
                 true <- duty.act_ref == field(event.data, :act_ref),
                 true <- is_nil(duty.attempt_ref),
                 true <- duty.mandate_ref == field(event.data, :mandate_ref) do
              :ok
            else
              false -> {:error, {:invalid_disputed_dispatch_cancellation, event.identity}}
              {:error, _reason} = error -> error
            end

          _missing_or_different ->
            {:error, {:dispatch_cancellation_outside_duty_batch, event.identity}}
        end

      :mandate_expired ->
        :ok

      reason ->
        {:error, {:invalid_dispatch_cancellation_reason, event.identity, reason}}
    end
  end

  defp validate_disputed_dispatch_cancellation_batch(before, projection, events, event) do
    with {:ok, duty} <- decode(Spectre.Duty, event.data) do
      if duty.class == :disputed_evidence and
           MapSet.member?(pending_dispatch_refs_before(before, events, event.index), duty.act_ref) do
        with {:ok, act} <- fetch_act(projection, duty.act_ref),
             true <- exact_disputed_dispatch_cancellation?(events, event.index + 1, act, duty),
             true <- exact_cancellation_release?(events, event.index + 2, act) do
          :ok
        else
          false -> {:error, {:disputed_dispatch_cancellation_batch_mismatch, duty.ref}}
          {:error, _reason} = error -> error
        end
      else
        :ok
      end
    end
  end

  defp exact_disputed_dispatch_cancellation?(events, index, act, duty) do
    exact_manual_event_at?(
      events,
      index,
      "dispatch_cancelled",
      "dispatch_cancelled:" <> act.ref,
      %{
        "act_ref" => act.ref,
        "mandate_ref" => act.mandate_ref,
        "cause_ref" => duty.ref,
        "reason" => :disputed_evidence,
        "cancelled_at" => duty.opened_at
      }
    )
  end

  defp exact_cancellation_release?(events, index, act) do
    if has_reservations?(act) do
      with {:ok, amounts} <- normalize_reservation_amounts(act.reservations) do
        exact_manual_event_at?(
          events,
          index,
          "meter_released",
          "meter_released:" <> act.ref,
          %{
            "act_ref" => act.ref,
            "mandate_ref" => act.mandate_ref,
            "amounts" => amounts
          }
        )
      else
        {:error, _reason} -> false
      end
    else
      true
    end
  end

  defp duty_disposition_batch_complete?(events, act, act_index) do
    with {:ok, disposition} <- Disposition.from_consequence(act.consequence) do
      case disposition.meter_resolution do
        :none ->
          exact_duty_disposal_at?(events, act_index + 1, act, disposition)

        operation when operation in [:settle, :release] ->
          exact_duty_meter_resolution_at?(
            events,
            act_index + 1,
            act,
            disposition,
            operation
          ) and exact_duty_disposal_at?(events, act_index + 2, act, disposition)
      end
    else
      {:error, _reason} -> false
    end
  end

  defp exact_duty_meter_resolution_at?(events, index, act, disposition, operation) do
    case event_at(events, index) do
      %{
        type: "meter_duty_resolved",
        identity: "meter_duty_resolved:" <> disposition_act_ref,
        data: data
      } ->
        disposition_act_ref == act.ref and field(data, :disposition_act_ref) == act.ref and
          field(data, :duty_ref) == disposition.duty_ref and
          field(data, :operation) == operation

      _missing_or_different ->
        false
    end
  end

  defp exact_duty_disposal_at?(events, index, act, disposition) do
    exact_manual_event_at?(
      events,
      index,
      "duty_disposed",
      act.ref,
      %{"cause_key" => disposition.cause_key, "disposition_act_ref" => act.ref}
    )
  end

  defp validate_authority_cancellation_batch(
         before,
         projection,
         events,
         %Act{class: class} = cause_act,
         act_index
       )
       when class in ["mandate.revoke", "mandate.restrict"] do
    reason =
      if class == "mandate.revoke", do: :mandate_revoked, else: :mandate_restricted

    with {:ok, target_mandate_ref, cascade?} <-
           cancellation_authority_change(projection, cause_act, reason),
         {:ok, affected_acts} <-
           affected_pending_acts(
             before,
             projection,
             events,
             act_index,
             target_mandate_ref,
             cascade?
           ),
         {:ok, expected_events} <-
           expected_dispatch_cancellation_events(affected_acts, cause_act, reason),
         true <-
           exact_dispatch_cancellation_sequence?(
             events,
             cause_act,
             affected_acts,
             expected_events,
             act_index + 2
           ) do
      :ok
    else
      false -> {:error, {:dispatch_cancellation_batch_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_authority_cancellation_batch(_before, _projection, events, cause_act, _index) do
    if Enum.any?(events, fn event ->
         event.type == "dispatch_cancelled" and
           field(event.data, :cause_ref) == cause_act.ref
       end),
       do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref}},
       else: :ok
  end

  defp affected_pending_acts(
         before,
         projection,
         events,
         before_index,
         target_mandate_ref,
         cascade?
       ) do
    before
    |> pending_dispatch_refs_before(events, before_index)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, affected} ->
      with {:ok, act} <- fetch_act(projection, act_ref),
           {:ok, affected?} <-
             mandate_affected_by_change?(
               projection,
               act.mandate_ref,
               target_mandate_ref,
               cascade?
             ) do
        if affected?,
          do: {:cont, {:ok, [act | affected]}},
          else: {:cont, {:ok, affected}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, affected} -> {:ok, Enum.reverse(affected)}
      {:error, _reason} = error -> error
    end
  end

  defp pending_dispatch_refs_before(before, events, before_index) do
    events
    |> Enum.filter(&(&1.index < before_index))
    |> Enum.sort_by(& &1.index)
    |> Enum.reduce(before.dispatch_ready, fn event, pending ->
      case event.type do
        "dispatch_ready" -> MapSet.put(pending, field(event.data, :act_ref))
        "dispatch_cancelled" -> MapSet.delete(pending, field(event.data, :act_ref))
        "attempt_started" -> MapSet.delete(pending, field(event.data, :act_ref))
        _other -> pending
      end
    end)
  end

  defp expected_dispatch_cancellation_events(acts, cause_act, reason) do
    acts
    |> Enum.reduce_while({:ok, []}, fn act, {:ok, reversed} ->
      cancellation =
        {"dispatch_cancelled", "dispatch_cancelled:" <> act.ref,
         %{
           "act_ref" => act.ref,
           "mandate_ref" => act.mandate_ref,
           "cause_ref" => cause_act.ref,
           "reason" => reason,
           "cancelled_at" => cause_act.committed_at
         }}

      if has_reservations?(act) do
        case normalize_reservation_amounts(act.reservations) do
          {:ok, amounts} ->
            release =
              {"meter_released", "meter_released:" <> act.ref,
               %{
                 "act_ref" => act.ref,
                 "mandate_ref" => act.mandate_ref,
                 "amounts" => amounts
               }}

            {:cont, {:ok, [release, cancellation | reversed]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      else
        {:cont, {:ok, [cancellation | reversed]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp exact_dispatch_cancellation_sequence?(
         events,
         cause_act,
         affected_acts,
         expected_events,
         first_index
       ) do
    actual_act_refs =
      events
      |> Enum.filter(fn event ->
        event.type == "dispatch_cancelled" and
          field(event.data, :cause_ref) == cause_act.ref
      end)
      |> Enum.sort_by(& &1.index)
      |> Enum.map(&field(&1.data, :act_ref))

    expected_act_refs = Enum.map(affected_acts, & &1.ref)

    actual_act_refs == expected_act_refs and
      expected_events
      |> Enum.with_index(first_index)
      |> Enum.all?(fn {{type, identity, data}, index} ->
        exact_manual_event_at?(events, index, type, identity, data)
      end)
  end

  # Admission, capability consumption and observation are separate durable
  # transitions. Seeing an earlier event in the same atomic batch is not proof
  # that its append was acknowledged before the next boundary was crossed.
  defp validate_world_stage_batch(before, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "attempt_started" -> validate_prior_dispatch(before, event)
          "outcome_recorded" -> validate_prior_attempt(before, event)
          _other -> :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_prior_dispatch(before, event) do
    act_ref = field(event.data, :act_ref)

    if MapSet.member?(before.dispatch_ready, act_ref),
      do: :ok,
      else: {:error, {:attempt_without_prior_durable_dispatch, event.identity, act_ref}}
  end

  defp validate_prior_attempt(before, event) do
    attempt_ref = field(event.data, :attempt_ref)
    act_ref = field(event.data, :act_ref)

    case Map.fetch(before.attempts, attempt_ref) do
      {:ok, %{act_ref: ^act_ref}} ->
        :ok

      {:ok, _different} ->
        {:error, {:outcome_prior_attempt_mismatch, event.identity, attempt_ref}}

      :error ->
        {:error, {:outcome_without_prior_durable_attempt, event.identity, attempt_ref}}
    end
  end

  defp validate_foundation_batch(events) do
    genesis? = Enum.any?(events, &(&1.type == "genesis_recorded"))

    foundation? =
      Enum.any?(
        events,
        &(&1.type in ["principal_recorded", "host_profile_recorded", "surface_recorded"])
      )

    if foundation? and not genesis?,
      do: {:error, :foundation_record_outside_genesis_batch},
      else: :ok
  end

  defp validate_mandate_batch(projection, events) do
    Enum.reduce_while(Enum.filter(events, &(&1.type == "mandate_issued")), :ok, fn event, :ok ->
      mandate = Map.fetch!(projection.mandates, event.identity)

      valid? =
        if is_nil(mandate.parent_ref) do
          batch_event?(events, "genesis_recorded", projection.genesis.ref, -1)
        else
          batch_event?(events, "act_committed", mandate.source_ref, -1)
        end

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:mandate_outside_authorizing_batch, mandate.ref}}}
    end)
  end

  defp validate_governance_batch(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      required_act_ref =
        case event.type do
          "mandate_revoked" -> event.identity
          "mandate_restricted" -> field(event.data, :act_ref)
          "meter_devolved" -> field(event.data, :act_ref)
          "surface_revised" -> field(event.data, :act_ref)
          "host_profile_revised" -> field(event.data, :act_ref)
          "definition_revised" -> field(event.data, :act_ref)
          "declassification_recorded" -> field(event.data, :source_act_ref)
          "erasure_requested" -> field(event.data, :source_act_ref)
          "scope_opened" -> field(event.data, :source_act_ref)
          "meter_duty_resolved" -> field(event.data, :disposition_act_ref)
          "duty_disposed" -> field(event.data, :disposition_act_ref)
          _other -> nil
        end

      cond do
        is_nil(required_act_ref) ->
          {:cont, :ok}

        batch_event?(events, "act_committed", required_act_ref, -1) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:governance_event_outside_act_batch, event.type, required_act_ref}}}
      end
    end)
  end

  defp validate_meter_batch(before, projection, events) do
    with :ok <-
           Enum.reduce_while(events, :ok, fn event, :ok ->
             result =
               case event.type do
                 "meter_reserved" ->
                   validate_reserve_batch_event(events, event)

                 "meter_settled" ->
                   validate_disposition_batch_event(projection, events, event, [
                     :succeeded,
                     :failed
                   ])

                 "meter_released" ->
                   validate_disposition_batch_event(projection, events, event, [
                     :definitive_no_effect
                   ])

                 "meter_suspended" ->
                   validate_suspend_batch_event(before, projection, events, event)

                 "meter_recontained" ->
                   validate_recontainment_batch_event(events, event)

                 "meter_duty_resolved" ->
                   validate_duty_meter_resolution_batch_event(events, event)

                 _other ->
                   :ok
               end

             case result do
               :ok -> {:cont, :ok}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      validate_required_recontainments(before, events)
    end
  end

  defp validate_reserve_batch_event(events, event) do
    act_ref = field(event.data, :act_ref)

    if batch_event?(events, "act_committed", act_ref, -1),
      do: :ok,
      else: {:error, {:meter_reservation_outside_admission_batch, act_ref}}
  end

  defp validate_disposition_batch_event(projection, events, event, allowed_statuses) do
    act_ref = field(event.data, :act_ref)

    outcome_disposition? =
      Enum.any?(events, fn candidate ->
        candidate.type == "outcome_recorded" and field(candidate.data, :act_ref) == act_ref and
          field(candidate.data, :status) in allowed_statuses
      end)

    cancellation_release? =
      event.type == "meter_released" and
        case event_at(events, event.index - 1) do
          %{type: "dispatch_cancelled", data: data} ->
            field(data, :act_ref) == act_ref

          _other ->
            false
        end

    internal_settlement? =
      event.type == "meter_settled" and
        case Map.get(projection.acts, act_ref) do
          %Act{} = act -> internal_settlement_at?(events, act, event.index - 2)
          nil -> false
        end

    if outcome_disposition? or cancellation_release? or internal_settlement? do
      :ok
    else
      {:error, {:meter_disposition_outside_outcome_batch, act_ref, event.type}}
    end
  end

  defp validate_suspend_batch_event(before, projection, events, event) do
    act_ref = field(event.data, :act_ref)

    outcome_in_batch? =
      Enum.any?(events, fn candidate ->
        candidate.type == "outcome_recorded" and field(candidate.data, :act_ref) == act_ref and
          field(candidate.data, :status) == :ambiguous
      end)

    duty_in_batch? =
      Enum.any?(events, fn candidate ->
        candidate.type == "duty_opened" and field(candidate.data, :act_ref) == act_ref
      end)

    preexisting_duty? = Enum.any?(before.duties, fn {_key, duty} -> duty.act_ref == act_ref end)
    resulting_duty? = Enum.any?(projection.duties, fn {_key, duty} -> duty.act_ref == act_ref end)

    if outcome_in_batch? or (duty_in_batch? and resulting_duty?) or preexisting_duty?,
      do: :ok,
      else: {:error, {:meter_suspension_without_duty_or_outcome, act_ref}}
  end

  defp validate_recontainment_batch_event(events, event) do
    act_ref = field(event.data, :act_ref)
    outcome_ref = field(event.data, :outcome_ref)
    cause_key = {:contradicted_outcome, act_ref, nil, outcome_ref}

    outcome = Enum.find(events, &(&1.index == event.index - 1))
    duty = Enum.find(events, &(&1.index == event.index + 1))

    valid_outcome? =
      outcome && outcome.type == "outcome_recorded" && outcome.identity == outcome_ref &&
        field(outcome.data, :act_ref) == act_ref &&
        field(outcome.data, :status) in [:succeeded, :failed] &&
        present_ref?(field(outcome.data, :contradicts_outcome_ref))

    attempt_ref = if outcome, do: field(outcome.data, :attempt_ref)
    cause_key = put_elem(cause_key, 2, attempt_ref)

    valid_duty? =
      duty && duty.type == "duty_opened" && field(duty.data, :cause_key) == cause_key

    if valid_outcome? and valid_duty?,
      do: :ok,
      else: {:error, {:meter_recontainment_batch_incomplete, act_ref, outcome_ref}}
  end

  defp validate_duty_meter_resolution_batch_event(events, event) do
    disposition_act_ref = field(event.data, :disposition_act_ref)
    act = Enum.find(events, &(&1.index == event.index - 1))
    disposal = Enum.find(events, &(&1.index == event.index + 1))

    valid_act? =
      act && act.type == "act_committed" && act.identity == disposition_act_ref &&
        field(act.data, :class) == "duty.dispose"

    valid_disposal? =
      disposal && disposal.type == "duty_disposed" && disposal.identity == disposition_act_ref &&
        field(disposal.data, :disposition_act_ref) == disposition_act_ref

    if valid_act? and valid_disposal?,
      do: :ok,
      else: {:error, {:duty_meter_resolution_batch_incomplete, disposition_act_ref}}
  end

  defp validate_required_recontainments(before, events) do
    events
    |> Enum.filter(fn event ->
      event.type == "outcome_recorded" and
        present_ref?(field(event.data, :contradicts_outcome_ref)) and
        Map.get(before.reservation_states, field(event.data, :act_ref)) == :released
    end)
    |> Enum.reduce_while(:ok, fn outcome, :ok ->
      act_ref = field(outcome.data, :act_ref)

      matches =
        Enum.filter(events, fn event ->
          event.type == "meter_recontained" and field(event.data, :act_ref) == act_ref and
            field(event.data, :outcome_ref) == outcome.identity
        end)

      case matches do
        [_one] -> {:cont, :ok}
        _other -> {:halt, {:error, {:contradiction_recontainment_missing, outcome.identity}}}
      end
    end)
  end

  defp batch_event?(events, type, identity, after_index) do
    Enum.any?(events, &(&1.type == type and &1.identity == identity and &1.index > after_index))
  end

  defp validate_complete_history(projection) do
    with :ok <- complete_admissions(projection),
         :ok <- complete_reservations(projection),
         :ok <- complete_suspensions(projection),
         :ok <- complete_meter_recontainments(projection),
         :ok <- complete_mandate_restrictions(projection),
         :ok <- complete_meter_ownership(projection) do
      complete_declassifications(projection)
    end
  end

  defp complete_admissions(projection) do
    Enum.reduce_while(projection.decisions, :ok, fn {_ref, decision}, :ok ->
      act_count =
        Enum.count(projection.acts, fn {_ref, act} -> act.decision_ref == decision.ref end)

      case {decision.outcome, act_count} do
        {:admitted, 1} -> {:cont, :ok}
        {:admitted, _count} -> {:halt, {:error, {:incomplete_admitted_decision, decision.ref}}}
        {_other, 0} -> {:cont, :ok}
        {_other, _count} -> {:halt, {:error, {:non_admitted_decision_has_act, decision.ref}}}
      end
    end)
  end

  defp complete_reservations(projection) do
    Enum.reduce_while(projection.acts, :ok, fn {_ref, act}, :ok ->
      cond do
        has_reservations?(act) and not Map.has_key?(projection.reservation_states, act.ref) ->
          {:halt, {:error, {:act_reservation_not_recorded, act.ref}}}

        Governance.executor_mediated?(act) and
          not Map.has_key?(projection.attempts_by_act, act.ref) and
          not MapSet.member?(projection.dispatch_ready, act.ref) and
            not Map.has_key?(projection.dispatch_cancellations, act.ref) ->
          {:halt, {:error, {:act_dispatch_state_missing, act.ref}}}

        Map.has_key?(projection.dispatch_cancellations, act.ref) and
          has_reservations?(act) and
            Map.get(projection.reservation_states, act.ref) != :released ->
          {:halt, {:error, {:cancelled_dispatch_reservation_not_released, act.ref}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp complete_suspensions(projection) do
    Enum.reduce_while(projection.reservation_states, :ok, fn
      {act_ref, :suspended}, :ok ->
        if Enum.any?(projection.duties, fn {_key, duty} -> duty.act_ref == act_ref end),
          do: {:cont, :ok},
          else: {:halt, {:error, {:suspended_reservation_without_duty, act_ref}}}

      {_act_ref, _status}, :ok ->
        {:cont, :ok}
    end)
  end

  defp complete_meter_recontainments(projection) do
    with :ok <-
           Enum.reduce_while(projection.meter_recontainments, :ok, fn
             {act_ref, record}, :ok ->
               outcome = Map.get(projection.outcomes, record.outcome_ref)
               duty = Map.get(projection.duties, record.cause_key)
               reservation_status = Map.get(projection.reservation_states, act_ref)

               valid? =
                 record.act_ref == act_ref and
                   match?(%Outcome{act_ref: ^act_ref}, outcome) and
                   Outcome.correction?(outcome) and
                   record.mandate_ref == outcome_mandate_ref(projection, outcome) and
                   recontainment_record_complete?(record, duty, reservation_status)

               if valid?,
                 do: {:cont, :ok},
                 else: {:halt, {:error, {:incomplete_meter_recontainment, act_ref}}}
           end) do
      projection.outcomes
      |> Map.values()
      |> Enum.filter(&requires_recontainment?(projection, &1))
      |> Enum.reduce_while(:ok, fn outcome, :ok ->
        if Map.has_key?(projection.meter_recontainments, outcome.act_ref),
          do: {:cont, :ok},
          else: {:halt, {:error, {:missing_meter_recontainment, outcome.ref}}}
      end)
    end
  end

  defp recontainment_record_complete?(record, %{status: :open}, :suspended),
    do: record.status == :open and is_nil(record.disposition_act_ref)

  defp recontainment_record_complete?(record, %{status: :disposed} = duty, status)
       when status in [:settled, :released] do
    record.status == :disposed and record.disposition_act_ref == duty.disposition_act_ref
  end

  defp recontainment_record_complete?(_record, _duty, _status), do: false

  defp requires_recontainment?(projection, %Outcome{} = outcome) do
    case Map.get(projection.acts, outcome.act_ref) do
      %{reservations: reservations} when reservations not in [%{}, []] ->
        Outcome.correction?(outcome)

      _other ->
        false
    end
  end

  defp requires_recontainment?(_projection, _outcome), do: false

  defp complete_mandate_restrictions(projection) do
    with :ok <- complete_successor_links(projection),
         :ok <- complete_predecessor_links(projection),
         :ok <- complete_restricted_mandates(projection),
         :ok <- complete_restriction_acts(projection) do
      acyclic_successions(projection.mandate_successors)
    end
  end

  defp complete_successor_links(projection) do
    Enum.reduce_while(projection.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        with {:ok, predecessor} <- fetch_mandate(projection, predecessor_ref),
             {:ok, successor} <- fetch_mandate(projection, successor_ref),
             true <- Map.get(projection.mandate_predecessors, successor_ref) == predecessor_ref,
             {:ok, act} <- fetch_act(projection, successor.source_ref),
             :ok <-
               validate_restriction_contract(
                 act,
                 predecessor,
                 successor,
                 restriction_data(act, predecessor, successor)
               ) do
          {:cont, :ok}
        else
          false ->
            {:halt,
             {:error, {:mandate_restriction_links_mismatch, predecessor_ref, successor_ref}}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end)
  end

  defp complete_predecessor_links(projection) do
    Enum.reduce_while(projection.mandate_predecessors, :ok, fn
      {successor_ref, predecessor_ref}, :ok ->
        if Map.get(projection.mandate_successors, predecessor_ref) == successor_ref,
          do: {:cont, :ok},
          else:
            {:halt,
             {:error, {:mandate_restriction_links_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp complete_restricted_mandates(projection) do
    Enum.reduce_while(projection.mandates, :ok, fn {ref, mandate}, :ok ->
      predecessor_ref = Map.get(projection.mandate_predecessors, ref)

      cond do
        mandate.revision == 1 and is_nil(predecessor_ref) ->
          {:cont, :ok}

        mandate.revision > 1 and is_binary(predecessor_ref) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:mandate_revision_lineage_incomplete, ref, mandate.revision}}}
      end
    end)
  end

  defp complete_restriction_acts(projection) do
    projection.acts
    |> Map.values()
    |> Enum.filter(&(&1.class == "mandate.restrict"))
    |> Enum.reduce_while(:ok, fn act, :ok ->
      successors =
        Enum.filter(projection.mandates, fn {successor_ref, mandate} ->
          mandate.source_ref == act.ref and
            Map.has_key?(projection.mandate_predecessors, successor_ref)
        end)

      case successors do
        [_one] -> {:cont, :ok}
        _other -> {:halt, {:error, {:mandate_restriction_act_incomplete, act.ref}}}
      end
    end)
  end

  defp acyclic_successions(successors) do
    Enum.reduce_while(Map.keys(successors), :ok, fn ref, :ok ->
      if succession_cycle?(successors, ref, MapSet.new()),
        do: {:halt, {:error, {:mandate_restriction_cycle, ref}}},
        else: {:cont, :ok}
    end)
  end

  defp succession_cycle?(successors, ref, visited) do
    cond do
      MapSet.member?(visited, ref) -> true
      is_nil(Map.get(successors, ref)) -> false
      true -> succession_cycle?(successors, Map.fetch!(successors, ref), MapSet.put(visited, ref))
    end
  end

  defp complete_meter_ownership(projection) do
    expected_physical =
      projection.meter_owners
      |> Enum.filter(fn {mandate_ref, owner_ref} -> mandate_ref == owner_ref end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    actual_physical = projection.meters |> Map.keys() |> MapSet.new()

    with true <- map_size(projection.meter_owners) == map_size(projection.mandates),
         true <- expected_physical == actual_physical,
         :ok <- complete_meter_owner_refs(projection) do
      complete_restriction_meter_owners(projection)
    else
      false -> {:error, :mandate_meter_ownership_incomplete}
      {:error, _reason} = error -> error
    end
  end

  defp complete_meter_owner_refs(projection) do
    Enum.reduce_while(projection.mandates, :ok, fn {mandate_ref, _mandate}, :ok ->
      owner_ref = Map.get(projection.meter_owners, mandate_ref)

      if is_binary(owner_ref) and Map.has_key?(projection.mandates, owner_ref) and
           Map.has_key?(projection.meters, owner_ref) and
           Map.get(projection.meter_owners, owner_ref) == owner_ref,
         do: {:cont, :ok},
         else: {:halt, {:error, {:invalid_mandate_meter_owner, mandate_ref, owner_ref}}}
    end)
  end

  defp complete_restriction_meter_owners(projection) do
    Enum.reduce_while(projection.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        if Map.get(projection.meter_owners, predecessor_ref) ==
             Map.get(projection.meter_owners, successor_ref),
           do: {:cont, :ok},
           else:
             {:halt,
              {:error,
               {:mandate_restriction_meter_owner_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp outcome_mandate_ref(projection, %Outcome{act_ref: act_ref}) do
    case Map.get(projection.acts, act_ref) do
      %{mandate_ref: mandate_ref} -> mandate_ref
      _other -> nil
    end
  end

  defp complete_declassifications(projection) do
    with :ok <-
           Enum.reduce_while(projection.declassifications, :ok, fn {ref, record}, :ok ->
             valid? =
               Map.get(projection.declassifications_by_act, record.source_act_ref) == ref and
                 Map.get(projection.declassifications_by_evidence, record.evidence_ref) == ref and
                 Map.has_key?(projection.evidence, record.evidence_ref)

             if valid?,
               do: {:cont, :ok},
               else: {:halt, {:error, {:incomplete_declassification, ref}}}
           end) do
      Enum.reduce_while(projection.acts, :ok, fn {_ref, act}, :ok ->
        if act.class != "data.declassify" or
             Map.has_key?(projection.declassifications_by_act, act.ref),
           do: {:cont, :ok},
           else: {:halt, {:error, {:declassification_act_incomplete, act.ref}}}
      end)
    end
  end

  @doc "Builds the canonical plain-map envelope for a Domain event."
  @spec event(String.t(), String.t(), map()) :: map()
  def event(type, identity, data)
      when type in @known_events and is_binary(identity) and identity != "" and is_map(data) and
             not is_struct(data) do
    %{
      "type" => type,
      "identity" => identity,
      "data" => data,
      "schema_version" => 1
    }
  end

  @spec apply_entry(t(), Entry.t()) :: {:ok, t()} | {:error, term()}
  def apply_entry(%__MODULE__{} = projection, %Entry{} = entry) do
    with :ok <- Entry.verify(entry),
         true <- entry.domain_ref == projection.domain_ref,
         true <- entry.revision == projection.revision + 1,
         true <- entry.prev_digest == projection.head_digest,
         :ok <- validate_acquisition_time(entry.payload, entry.recorded_at),
         {:ok, projection} <- apply_payload(projection, entry.payload, entry.revision) do
      event_key = {field(entry.payload, :type), field(entry.payload, :identity)}

      {:ok,
       %{
         projection
         | revision: entry.revision,
           head_digest: entry.digest,
           event_recorded_at: Map.put(projection.event_recorded_at, event_key, entry.recorded_at),
           event_revisions: Map.put(projection.event_revisions, event_key, entry.revision)
       }}
    else
      false -> {:error, {:projection_chain_mismatch, entry.revision}}
      {:error, _reason} = error -> error
    end
  end

  def apply_entry(_projection, _entry), do: {:error, :invalid_projection_entry}

  defp validate_acquisition_time(payload, recorded_at)
       when is_map(payload) and is_integer(recorded_at) and recorded_at >= 0 do
    type = field(payload, :type)
    data = field(payload, :data)

    case type do
      "genesis_recorded" ->
        not_future_time(type, :issued_at, data, recorded_at)

      "host_profile_recorded" ->
        not_future_time(type, :declared_at, data, recorded_at)

      "host_profile_revised" ->
        not_future_time(type, :declared_at, field(data, :host_profile), recorded_at)

      "definition_revised" ->
        not_future_time(type, :declared_at, field(data, :definition), recorded_at)

      "declassification_recorded" ->
        exact_event_time(type, :recorded_at, data, recorded_at)

      "evidence_recorded" ->
        not_future_time(type, :observed_at, data, recorded_at)

      "presentation_recorded" ->
        not_future_time(type, :prepared_at, data, recorded_at)

      "decision_recorded" ->
        exact_event_time(type, :decided_at, data, recorded_at)

      "act_committed" ->
        exact_event_time(type, :committed_at, data, recorded_at)

      "attempt_started" ->
        exact_event_time(type, :started_at, data, recorded_at)

      "outcome_recorded" ->
        not_future_time(type, :observed_at, data, recorded_at)

      "duty_opened" ->
        not_future_time(type, :opened_at, data, recorded_at)

      "mandate_revoked" ->
        exact_event_time(type, :effective_at, data, recorded_at)

      "dispatch_cancelled" ->
        not_future_time(type, :cancelled_at, data, recorded_at)

      "scope_opened" ->
        scope_acquisition_time(type, data, recorded_at)

      "erasure_requested" ->
        not_future_time(type, :requested_at, data, recorded_at)

      _other ->
        :ok
    end
  end

  defp validate_acquisition_time(_payload, _recorded_at),
    do: {:error, :invalid_event_acquisition_time}

  defp scope_acquisition_time(type, data, recorded_at) do
    if is_nil(field(data, :source_act_ref)),
      do: not_future_time(type, :opened_at, data, recorded_at),
      else: exact_event_time(type, :opened_at, data, recorded_at)
  end

  defp exact_event_time(type, field_name, data, recorded_at) do
    case field(data, field_name) do
      ^recorded_at -> :ok
      value -> {:error, {:event_time_mismatch, type, field_name, value, recorded_at}}
    end
  end

  defp not_future_time(type, field_name, data, recorded_at) do
    case field(data, field_name) do
      value when is_integer(value) and value <= recorded_at -> :ok
      value -> {:error, {:event_from_future, type, field_name, value, recorded_at}}
    end
  end

  @doc "Applies one validated event to an in-memory provisional projection."
  @spec apply_payload(t(), map(), non_neg_integer() | nil) :: {:ok, t()} | {:error, term()}
  def apply_payload(projection, payload, revision \\ nil)

  def apply_payload(%__MODULE__{} = projection, payload, revision)
      when is_map(payload) and not is_struct(payload) do
    with :ok <- validate_event(payload) do
      reduce(
        field(payload, :type),
        field(payload, :identity),
        field(payload, :data),
        revision,
        projection
      )
    end
  end

  def apply_payload(_projection, _payload, _revision), do: {:error, :invalid_domain_event}

  @spec authority_view(t()) :: map()
  def authority_view(%__MODULE__{} = projection) do
    %{
      mandates: projection.mandates,
      mandate_successors: projection.mandate_successors,
      mandate_predecessors: projection.mandate_predecessors,
      revocations: projection.revocations,
      meters: projection.meters,
      meter_owners: projection.meter_owners,
      reservation_states: projection.reservation_states,
      reservation_bindings: projection.reservation_bindings,
      blocked_mandate_refs: blocked_mandate_refs(projection),
      blocked_effect_digests: blocked_effect_digests(projection),
      revision: projection.revision
    }
  end

  defp blocked_mandate_refs(projection) do
    blocked_owners =
      projection.meter_recontainments
      |> Map.values()
      |> Enum.filter(&(&1.status == :open and map_size(&1.deficits) > 0))
      |> Enum.map(fn record -> Map.get(projection.meter_owners, record.mandate_ref) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    projection.meter_owners
    |> Enum.filter(fn {_mandate_ref, owner_ref} -> MapSet.member?(blocked_owners, owner_ref) end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp blocked_effect_digests(projection) do
    projection.duties
    |> Map.values()
    |> Enum.flat_map(fn
      %Spectre.Duty{
        status: :open,
        containment: %{
          "dispatch" => :blocked,
          "retry" => :forbidden,
          "consequence_digest" => digest
        }
      }
      when is_binary(digest) and digest != "" ->
        [digest]

      _duty ->
        []
    end)
    |> MapSet.new()
  end

  @doc "Returns the physical Meter accounts owned by a logical Mandate revision."
  @spec meter_accounts(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def meter_accounts(%__MODULE__{} = projection, mandate_ref)
      when is_binary(mandate_ref) and mandate_ref != "" do
    with {:ok, owner_ref} <- fetch_meter_owner(projection, mandate_ref),
         {:ok, accounts} <- Map.fetch(projection.meters, owner_ref) do
      {:ok, accounts}
    else
      :error -> {:error, {:meter_mandate_not_found, mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  def meter_accounts(%__MODULE__{}, mandate_ref),
    do: {:error, {:invalid_meter_mandate_ref, mandate_ref}}

  @doc "Builds a read-only logical view without duplicating Meter state in the projection."
  @spec meter_view(t()) :: map()
  def meter_view(%__MODULE__{} = projection) do
    Map.new(projection.meter_owners, fn {mandate_ref, owner_ref} ->
      {mandate_ref, Map.fetch!(projection.meters, owner_ref)}
    end)
  end

  @spec evidence_set(t(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def evidence_set(%__MODULE__{} = projection, refs) when is_list(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, found} ->
      case Map.fetch(projection.evidence, ref) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | found]}}
        :error -> {:halt, {:error, {:evidence_not_found, ref}}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      {:error, _reason} = error -> error
    end
  end

  def evidence_set(_projection, _refs), do: {:error, :invalid_evidence_refs}

  @doc "Validates a current or resumed authenticated context against a durable Scope opening."
  @spec scope_context(t(), SubmissionContext.t()) :: {:ok, Opening.t()} | {:error, term()}
  def scope_context(%__MODULE__{} = projection, %SubmissionContext{} = context) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, %Opening{} = opening} <- Map.fetch(projection.scopes, context.scope_ref) do
      cond do
        context.domain_ref != projection.domain_ref or opening.domain_ref != context.domain_ref ->
          {:error, {:scope_context_domain_mismatch, context.scope_ref}}

        context.authenticated_principal_ref != opening.opened_by_ref ->
          {:error, {:scope_context_principal_mismatch, context.scope_ref}}

        context.authentication_ref != opening.authentication_ref ->
          {:error, {:scope_context_authentication_mismatch, context.scope_ref}}

        context.ingress_ref != opening.ingress_ref ->
          {:error, {:scope_context_ingress_mismatch, context.scope_ref}}

        context.channel_ref != opening.channel_ref ->
          {:error, {:scope_context_channel_mismatch, context.scope_ref}}

        context.session_ref != opening.session_ref ->
          {:error, {:scope_context_session_mismatch, context.scope_ref}}

        true ->
          {:ok, opening}
      end
    else
      :error -> {:error, {:scope_not_open, context.scope_ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_projected_scope, context.scope_ref}}
    end
  end

  def scope_context(%__MODULE__{}, _context), do: {:error, :invalid_scope_context}

  @doc "Looks up a Duty by its idempotent cause key or by its durable record ref."
  @spec duty(t(), {:cause_key, term()} | {:ref, String.t()}) ::
          {:ok, Spectre.Duty.t()} | :not_found | {:error, :invalid_duty_lookup}
  def duty(%__MODULE__{} = projection, {:cause_key, cause_key}) when not is_nil(cause_key) do
    case Map.fetch(projection.duties, cause_key) do
      {:ok, duty} -> {:ok, duty}
      :error -> :not_found
    end
  end

  def duty(%__MODULE__{} = projection, {:ref, ref}) when is_binary(ref) and ref != "" do
    with {:ok, cause_key} <- Map.fetch(projection.duty_refs, ref),
         {:ok, duty} <- Map.fetch(projection.duties, cause_key) do
      {:ok, duty}
    else
      :error -> :not_found
    end
  end

  def duty(%__MODULE__{}, _lookup), do: {:error, :invalid_duty_lookup}

  defp validate_event(payload) do
    type = field(payload, :type)
    identity = field(payload, :identity)
    data = field(payload, :data)
    version = field(payload, :schema_version)

    with :ok <- validate_event_keys(payload),
         :ok <- validate_manual_event_data(type, identity, data) do
      cond do
        version != 1 -> {:error, {:unsupported_domain_event, version}}
        type not in @known_events -> {:error, {:unknown_domain_event, type}}
        not (is_binary(identity) and identity != "") -> {:error, :invalid_domain_event_identity}
        not (is_map(data) and not is_struct(data)) -> {:error, :invalid_domain_event_data}
        true -> :ok
      end
    end
  end

  defp validate_event_keys(payload) do
    validate_exact_string_keys(payload, @event_fields, :domain_event)
  end

  defp validate_manual_event_data(type, identity, data) do
    case Map.fetch(@manual_event_fields, type) do
      :error ->
        :ok

      {:ok, fields} ->
        with true <- is_map(data) and not is_struct(data),
             :ok <- validate_exact_string_keys(data, fields, String.to_atom(type)),
             :ok <- validate_manual_event_identity(type, identity, data) do
          :ok
        else
          false -> {:error, :invalid_domain_event_data}
          {:error, _reason} = error -> error
        end
    end
  end

  defp validate_manual_event_identity(type, identity, data)
       when type in [
              "meter_reserved",
              "meter_settled",
              "meter_released",
              "meter_suspended",
              "meter_recontained",
              "meter_devolved"
            ] do
    exact_prefixed_identity(identity, type, field(data, :act_ref))
  end

  defp validate_manual_event_identity("dispatch_ready", identity, data),
    do: exact_prefixed_identity(identity, "dispatch_ready", field(data, :act_ref))

  defp validate_manual_event_identity("dispatch_cancelled", identity, data),
    do: exact_prefixed_identity(identity, "dispatch_cancelled", field(data, :act_ref))

  defp validate_manual_event_identity("meter_duty_resolved", identity, data),
    do:
      exact_prefixed_identity(
        identity,
        "meter_duty_resolved",
        field(data, :disposition_act_ref)
      )

  defp validate_manual_event_identity("duty_disposed", identity, data),
    do: exact_identity(identity, field(data, :disposition_act_ref))

  defp validate_manual_event_identity(_type, _identity, _data), do: :ok

  defp exact_prefixed_identity(identity, prefix, ref) when is_binary(ref) and ref != "",
    do: exact_identity(identity, prefix <> ":" <> ref)

  defp exact_prefixed_identity(_identity, _prefix, _ref),
    do: {:error, :invalid_domain_event_identity_binding}

  defp validate_exact_string_keys(map, fields, context)
       when is_map(map) and not is_struct(map) do
    expected = Enum.map(fields, &Atom.to_string/1)
    actual = Map.keys(map)
    unknown = actual -- expected
    missing = expected -- actual

    cond do
      unknown != [] ->
        {:error, {:unknown_fields, context, Enum.sort_by(unknown, &inspect/1)}}

      missing != [] ->
        {:error, {:missing_field, context, List.first(missing)}}

      true ->
        :ok
    end
  end

  defp reduce("genesis_recorded", identity, data, _revision, projection) do
    cond do
      projection.genesis ->
        {:error, :duplicate_genesis}

      projection.revision != 0 ->
        {:error, :genesis_must_be_first}

      true ->
        with {:ok, genesis} <- decode(Spectre.Genesis, data),
             :ok <- exact_identity(identity, record_ref(genesis)),
             true <- Map.get(genesis, :domain_ref) == projection.domain_ref do
          {:ok, %{projection | genesis: genesis}}
        else
          false -> {:error, :genesis_domain_mismatch}
          {:error, _reason} = error -> error
        end
    end
  end

  defp reduce("principal_recorded", identity, data, _revision, projection) do
    with :ok <- genesis_names(projection, :principal_refs, identity) do
      put_decoded(projection, :principals, Spectre.Principal, identity, data)
    end
  end

  defp reduce("host_profile_recorded", identity, data, _revision, projection) do
    if projection.host_profile do
      {:error, :duplicate_host_profile}
    else
      with :ok <- genesis_names(projection, :host_profile_ref, identity),
           {:ok, profile} <- decode(HostProfile, data),
           :ok <- exact_identity(identity, record_ref(profile)),
           :ok <- initial_host_profile_revision(profile) do
        {:ok,
         %{
           projection
           | host_profile: profile,
             host_profiles: Map.put(projection.host_profiles, identity, profile)
         }}
      end
    end
  end

  defp reduce("host_profile_revised", identity, data, _revision, projection) do
    with %HostProfile{} = current <- projection.host_profile,
         {:ok, profile} <- decode(HostProfile, field(data, :host_profile)),
         :ok <- exact_identity(identity, profile.ref),
         :ok <- unique(projection.host_profiles, identity, :host_profile),
         {:ok, act} <- fetch_act(projection, field(data, :act_ref)),
         :ok <- validate_host_profile_revision(act, current, profile, data) do
      {:ok,
       %{
         projection
         | host_profile: profile,
           host_profiles: Map.put(projection.host_profiles, identity, profile)
       }}
    else
      nil -> {:error, :host_profile_not_initialized}
      {:error, _reason} = error -> error
    end
  end

  defp reduce("definition_revised", identity, data, _revision, projection) do
    with {:ok, definition} <- decode(Definition, field(data, :definition)),
         :ok <- exact_identity(identity, definition.ref),
         :ok <- unique(projection.definitions, identity, :definition),
         {:ok, act} <- fetch_act(projection, field(data, :act_ref)),
         :ok <- validate_definition_revision(projection, act, definition, data) do
      key = Definition.key(definition)

      {:ok,
       %{
         projection
         | definitions: Map.put(projection.definitions, identity, definition),
           definition_heads: Map.put(projection.definition_heads, key, identity)
       }}
    end
  end

  defp reduce("surface_recorded", identity, data, _revision, projection) do
    if projection.surface do
      {:error, :duplicate_surface}
    else
      with :ok <- genesis_names(projection, :surface_ref, identity),
           {:ok, surface} <- decode(Spectre.Surface, data),
           :ok <- exact_identity(identity, record_ref(surface)),
           :ok <- initial_surface_revision(projection.genesis, surface) do
        {:ok,
         %{
           projection
           | surface: surface,
             surfaces: Map.put(projection.surfaces, identity, surface)
         }}
      end
    end
  end

  defp reduce("surface_revised", identity, data, _revision, projection) do
    with %Surface{} = current <- projection.surface,
         {:ok, surface} <- decode(Surface, field(data, :surface)),
         :ok <- exact_identity(identity, surface.ref),
         :ok <- unique(projection.surfaces, identity, :surface),
         {:ok, act} <- fetch_act(projection, field(data, :act_ref)),
         :ok <- validate_surface_revision(act, current, surface, data) do
      {:ok,
       %{
         projection
         | surface: surface,
           surfaces: Map.put(projection.surfaces, identity, surface)
       }}
    else
      nil -> {:error, :surface_not_initialized}
      {:error, _reason} = error -> error
    end
  end

  defp reduce("mandate_issued", identity, data, _entry_revision, projection) do
    with {:ok, mandate} <- decode(Spectre.Mandate, data),
         :ok <- exact_identity(identity, record_ref(mandate)),
         :ok <- unique(projection.mandates, identity, :mandate),
         :ok <- initial_mandate_revision(mandate),
         :ok <- validate_mandate_principals(projection, mandate),
         {:ok, meters} <- issue_mandate_meters(projection, mandate) do
      {:ok,
       %{
         projection
         | mandates: Map.put(projection.mandates, identity, mandate),
           meters: meters,
           meter_owners: Map.put(projection.meter_owners, identity, identity)
       }}
    end
  end

  defp reduce("mandate_restricted", identity, data, _revision, projection) do
    predecessor_ref = field(data, :predecessor_ref)
    act_ref = field(data, :act_ref)

    with {:ok, predecessor} <- fetch_mandate(projection, predecessor_ref),
         {:ok, act} <- fetch_act(projection, act_ref),
         {:ok, successor} <- decode(Mandate, field(data, :successor)),
         :ok <- exact_identity(identity, successor.ref),
         :ok <- canonical_restriction_event(successor, data),
         :ok <- unique(projection.mandates, successor.ref, :mandate),
         :ok <- validate_mandate_principals(projection, successor),
         :ok <- validate_restriction_contract(act, predecessor, successor, data),
         :ok <- restrictable_predecessor(projection, predecessor, act.committed_at),
         :ok <- restriction_link_available(projection, predecessor.ref, successor.ref),
         {:ok, owner_ref} <- fetch_meter_owner(projection, predecessor.ref) do
      {:ok,
       %{
         projection
         | mandates: Map.put(projection.mandates, successor.ref, successor),
           mandate_successors:
             Map.put(projection.mandate_successors, predecessor.ref, successor.ref),
           mandate_predecessors:
             Map.put(projection.mandate_predecessors, successor.ref, predecessor.ref),
           meter_owners: Map.put(projection.meter_owners, successor.ref, owner_ref)
       }}
    end
  end

  defp reduce("mandate_revoked", identity, data, revision, projection) do
    mandate_ref = field(data, :mandate_ref)

    with {:ok, mandate} <- fetch_mandate(projection, mandate_ref),
         false <- Map.has_key?(projection.revocations, mandate_ref),
         {:ok, governance_act} <- fetch_act(projection, identity),
         :ok <- validate_revocation(governance_act, mandate, data) do
      revocation =
        Map.merge(data, %{
          "identity" => identity,
          "mode" => Map.fetch!(mandate.revocation, "mode"),
          "revision" => revision
        })

      {:ok, %{projection | revocations: Map.put(projection.revocations, mandate_ref, revocation)}}
    else
      true -> {:error, {:mandate_already_revoked, mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp reduce("declassification_recorded", identity, data, _revision, projection) do
    with {:ok, record} <- decode(Declassification, data),
         :ok <- exact_identity(identity, record.ref),
         :ok <- unique(projection.declassifications, identity, :declassification),
         :ok <- unique_declassification_act(projection, record),
         :ok <- unique_declassified_evidence(projection, record),
         {:ok, act} <- fetch_act(projection, record.source_act_ref),
         {:ok, evidence} <- validate_declassification(projection, act, record) do
      {:ok,
       %{
         projection
         | declassifications: Map.put(projection.declassifications, identity, record),
           declassifications_by_act:
             Map.put(projection.declassifications_by_act, act.ref, identity),
           declassifications_by_evidence:
             Map.put(projection.declassifications_by_evidence, evidence.ref, identity)
       }}
    end
  end

  defp reduce("evidence_recorded", identity, data, _revision, projection) do
    with {:ok, evidence} <- decode(Evidence, data),
         :ok <- exact_identity(identity, evidence.ref),
         :ok <- unique(projection.evidence, identity, :evidence),
         :ok <- validate_evidence_scope_binding(projection, evidence),
         :ok <- validate_evidence_lineage(projection, evidence),
         :ok <- validate_presentation_approval_evidence(projection, evidence),
         :ok <- validate_duty_cause_evidence(projection, evidence) do
      {:ok, %{projection | evidence: Map.put(projection.evidence, identity, evidence)}}
    end
  end

  defp reduce("presentation_recorded", identity, data, _revision, projection) do
    with {:ok, presentation} <- decode(Presentation, data),
         :ok <- exact_identity(identity, presentation.ref),
         :ok <- unique(projection.presentations, identity, :presentation),
         :ok <- validate_prepared_presentation(projection, presentation) do
      {:ok,
       %{projection | presentations: Map.put(projection.presentations, identity, presentation)}}
    end
  end

  defp reduce("decision_recorded", identity, data, entry_revision, projection) do
    with {:ok, decision} <- decode(Spectre.Decision, data),
         :ok <- exact_identity(identity, record_ref(decision)),
         :ok <- unique(projection.decisions, identity, :decision),
         :ok <- validate_decision_revision(projection, decision, entry_revision),
         :ok <- validate_decision_context(projection, decision),
         :ok <- validate_decision_evidence_basis(projection, decision),
         :ok <- validate_decision_authority(projection, decision) do
      candidate_key = Map.get(decision, :candidate_identity_key)
      candidate_digest = Map.get(decision, :candidate_digest)

      case Map.fetch(projection.candidate_identities, candidate_key) do
        :error ->
          {:ok,
           %{
             projection
             | decisions: Map.put(projection.decisions, identity, decision),
               candidate_identities:
                 Map.put(projection.candidate_identities, candidate_key, %{
                   digest: candidate_digest,
                   decision_ref: identity
                 })
           }}

        {:ok, %{digest: ^candidate_digest}} ->
          {:error, {:duplicate_candidate_decision, candidate_key}}

        {:ok, _different} ->
          {:error, {:candidate_identity_conflict, candidate_key}}
      end
    end
  end

  defp reduce("act_committed", identity, data, _revision, projection) do
    with {:ok, act} <- decode(Spectre.Act, data),
         :ok <- exact_identity(identity, record_ref(act)),
         :ok <- unique(projection.acts, identity, :act),
         :ok <- Spectre.Governance.execution_boundary(act),
         {:ok, decision} <- fetch_decision(projection, act.decision_ref),
         :ok <- one_act_per_decision(projection, decision.ref),
         :ok <- match_act_to_decision(projection, act, decision),
         {:ok, candidate} <- rebuild_candidate(projection, act),
         :ok <- validate_candidate_at_act(projection, candidate, act, decision) do
      {:ok, %{projection | acts: Map.put(projection.acts, identity, act)}}
    end
  end

  defp reduce("meter_reserved", _identity, data, _revision, projection),
    do: reserve_meters(projection, data)

  defp reduce("meter_settled", _identity, data, _revision, projection),
    do: transition_reservation(projection, data, :settle)

  defp reduce("meter_released", _identity, data, _revision, projection),
    do: transition_reservation(projection, data, :release)

  defp reduce("meter_suspended", _identity, data, _revision, projection),
    do: transition_reservation(projection, data, :suspend)

  defp reduce("meter_recontained", _identity, data, _revision, projection),
    do: recontain_released_reservation(projection, data)

  defp reduce("meter_duty_resolved", _identity, data, _revision, projection),
    do: resolve_duty_meter(projection, data)

  defp reduce("meter_devolved", _identity, data, _revision, projection),
    do: devolve_meters(projection, data)

  defp reduce("dispatch_ready", _identity, data, _revision, projection) do
    act_ref = field(data, :act_ref)

    with {:ok, act} <- fetch_act(projection, act_ref),
         :ok <- validate_dispatch(projection, act, data) do
      {:ok, %{projection | dispatch_ready: MapSet.put(projection.dispatch_ready, act_ref)}}
    end
  end

  defp reduce("dispatch_cancelled", identity, data, _revision, projection) do
    act_ref = field(data, :act_ref)

    with :ok <- exact_prefixed_identity(identity, "dispatch_cancelled", act_ref),
         {:ok, act} <- fetch_act(projection, act_ref),
         :ok <- validate_dispatch_cancellation(projection, act, data) do
      cancellation = %{
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        cause_ref: field(data, :cause_ref),
        reason: field(data, :reason),
        cancelled_at: field(data, :cancelled_at)
      }

      {:ok,
       %{
         projection
         | dispatch_ready: MapSet.delete(projection.dispatch_ready, act.ref),
           dispatch_cancellations:
             Map.put(projection.dispatch_cancellations, act.ref, cancellation)
       }}
    end
  end

  defp reduce("attempt_started", identity, data, _revision, projection) do
    with {:ok, attempt} <- decode(Spectre.Attempt, data),
         :ok <- exact_identity(identity, record_ref(attempt)),
         :ok <- unique(projection.attempts, identity, :attempt),
         {:ok, act} <- fetch_act(projection, attempt.act_ref),
         :ok <- attempt_available(projection, attempt, act),
         :ok <- nonce_available(projection, attempt.grant_nonce_digest),
         :ok <- match_attempt_to_act(attempt, act),
         :ok <- validate_attempt_authority(projection, attempt, act) do
      act_ref = attempt.act_ref

      {:ok,
       %{
         projection
         | attempts: Map.put(projection.attempts, identity, attempt),
           attempts_by_act: Map.put(projection.attempts_by_act, act_ref, identity),
           dispatch_ready: MapSet.delete(projection.dispatch_ready, act_ref),
           consumed_nonces: MapSet.put(projection.consumed_nonces, attempt.grant_nonce_digest)
       }}
    end
  end

  defp reduce("outcome_recorded", identity, data, _revision, projection) do
    with {:ok, outcome} <- decode(Spectre.Outcome, data),
         :ok <- exact_identity(identity, record_ref(outcome)),
         :ok <- unique(projection.outcomes, identity, :outcome),
         {:ok, attempt} <- fetch_attempt(projection, outcome.attempt_ref),
         {:ok, act} <- fetch_act(projection, outcome.act_ref),
         :ok <- match_outcome_to_attempt(projection, outcome, attempt),
         :ok <- validate_erasure_outcome(act, outcome),
         :ok <- validate_outcome_time(outcome, attempt),
         :ok <- validate_outcome_transition(projection, outcome),
         :ok <- validate_outcome_evidence(projection, outcome, attempt, act) do
      {:ok, %{projection | outcomes: Map.put(projection.outcomes, identity, outcome)}}
    end
  end

  defp reduce("duty_opened", identity, data, _revision, projection) do
    with {:ok, duty} <- decode(Spectre.Duty, data),
         :ok <- exact_identity(identity, record_ref(duty)),
         :ok <- new_duty_open(duty),
         :ok <- unique_duty(projection, duty),
         :ok <- match_duty_references(projection, duty) do
      {:ok,
       %{
         projection
         | duties: Map.put(projection.duties, duty.cause_key, duty),
           duty_refs: Map.put(projection.duty_refs, duty.ref, duty.cause_key)
       }}
    end
  end

  defp reduce("duty_disposed", identity, data, _revision, projection) do
    cause_key = field(data, :cause_key)
    disposition_act_ref = field(data, :disposition_act_ref)

    with {:ok, duty} <- fetch_duty_by_cause(projection, cause_key),
         :ok <- duty_open(duty),
         :ok <- exact_identity(identity, disposition_act_ref),
         {:ok, act} <- fetch_act(projection, disposition_act_ref),
         {:ok, disposition} <- Disposition.from_consequence(act.consequence),
         {:ok, _supporting} <- validate_duty_disposition(projection, act, duty, disposition),
         :ok <- validate_duty_meter_disposed(projection, duty, disposition, act.ref),
         {:ok, updated} <-
           Spectre.Duty.new(%{
             duty
             | status: :disposed,
               disposition_act_ref: disposition_act_ref
           }) do
      {:ok, %{projection | duties: Map.put(projection.duties, cause_key, updated)}}
    end
  end

  defp reduce("scope_opened", identity, data, _revision, projection) do
    with {:ok, opening} <- decode(Opening, data),
         :ok <- exact_identity(identity, opening.ref),
         :ok <- unique(projection.scopes, identity, :scope),
         :ok <- validate_scope_opening(projection, opening) do
      {:ok, %{projection | scopes: Map.put(projection.scopes, identity, opening)}}
    end
  end

  defp reduce("erasure_requested", identity, data, _revision, projection) do
    with {:ok, erasure} <- decode(Erasure, data),
         :ok <- exact_identity(identity, erasure.ref),
         :ok <- unique(projection.erasures, identity, :erasure),
         :ok <- unique_erasure_act(projection, erasure),
         {:ok, act} <- fetch_act(projection, erasure.source_act_ref),
         :ok <- validate_erasure_request(projection, act, erasure) do
      {:ok,
       %{
         projection
         | erasures: Map.put(projection.erasures, identity, erasure),
           erasures_by_act: Map.put(projection.erasures_by_act, act.ref, identity)
       }}
    end
  end

  defp validate_erasure_outcome(%Act{class: "data.erase"}, %Outcome{status: :failed}),
    do: {:error, :erasure_failure_must_be_definitive_or_ambiguous}

  defp validate_erasure_outcome(_act, _outcome), do: :ok

  defp initial_mandate_revision(%Mandate{revision: 1}), do: :ok

  defp initial_mandate_revision(%Mandate{ref: ref, revision: revision}),
    do: {:error, {:invalid_initial_mandate_revision, ref, revision}}

  defp validate_mandate_principals(projection, mandate) do
    refs =
      [mandate.grantor_ref, mandate.holder_ref, mandate.accountable_ref] ++
        Map.fetch!(mandate.revocation, "controller_refs")

    case Enum.find(refs, &(not Map.has_key?(projection.principals, &1))) do
      nil -> :ok
      ref -> {:error, {:mandate_principal_not_found, mandate.ref, ref}}
    end
  end

  defp initial_host_profile_revision(%HostProfile{revision: 1}), do: :ok

  defp initial_host_profile_revision(%HostProfile{ref: ref, revision: revision}),
    do: {:error, {:invalid_initial_host_profile_revision, ref, revision}}

  defp initial_surface_revision(genesis, surface) do
    if surface.revision == genesis.surface_revision,
      do: :ok,
      else: {:error, :genesis_surface_revision_mismatch}
  end

  defp validate_definition_revision(projection, act, definition, data) do
    key = Definition.key(definition)
    current_ref = Map.get(projection.definition_heads, key)
    current = if current_ref, do: Map.get(projection.definitions, current_ref)

    expected_consequence = %{
      "definition_revision" => %{
        "previous_ref" => definition.previous_ref,
        "definition" => Definition.canonical(definition)
      }
    }

    cond do
      act.class != "definition.revise" ->
        {:error, {:definition_revision_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:definition_revision_act_row_mismatch, act.ref}}

      act.reservations not in [%{}, []] ->
        {:error, {:definition_revision_act_has_reservations, act.ref}}

      not act_targets?(act, Enum.reject([definition.previous_ref, definition.ref], &is_nil/1)) ->
        {:error, {:definition_revision_targets_missing, act.ref}}

      field(data, :previous_ref) != definition.previous_ref ->
        {:error, {:definition_revision_previous_ref_mismatch, definition.ref}}

      act.consequence != expected_consequence ->
        {:error, {:definition_revision_consequence_mismatch, act.ref}}

      is_nil(current) and (definition.revision != 1 or not is_nil(definition.previous_ref)) ->
        {:error, {:invalid_initial_definition_revision, definition.ref, definition.revision}}

      not is_nil(current) and definition.previous_ref != current.ref ->
        {:error,
         {:definition_revision_not_based_on_current, definition.ref, definition.previous_ref,
          current.ref}}

      not is_nil(current) and definition.revision != current.revision + 1 ->
        {:error,
         {:definition_revision_not_sequential, definition.ref, current.revision,
          definition.revision}}

      not is_nil(current) and definition.declared_at < current.declared_at ->
        {:error, {:definition_revision_time_regressed, definition.ref}}

      definition.declared_at > act.committed_at ->
        {:error, {:definition_revision_from_future, definition.ref}}

      true ->
        :ok
    end
  end

  defp validate_scope_opening(projection, opening) do
    with :ok <- scope_domain_matches(projection, opening),
         :ok <- scope_parent_exists(projection, opening),
         :ok <- scope_principals_exist(projection, opening),
         :ok <- scope_disposition_authorities_exist(projection, opening),
         :ok <- validate_opening_submission_context(opening),
         :ok <- validate_scope_opening_source(projection, opening) do
      :ok
    end
  end

  defp validate_scope_opening_source(_projection, %Opening{source_act_ref: nil}), do: :ok

  defp validate_scope_opening_source(projection, %Opening{} = opening) do
    with {:ok, act} <- fetch_act(projection, opening.source_act_ref),
         {:ok, draft} <- Opening.governed_draft(opening) do
      cond do
        act.class != "scope.open" ->
          {:error, {:scope_opening_act_class_mismatch, opening.ref, act.ref}}

        not exact_row?(act.row, [:write, :govern]) ->
          {:error, {:scope_opening_act_row_mismatch, opening.ref, act.ref}}

        has_reservations?(act) ->
          {:error, {:scope_opening_act_has_reservations, opening.ref, act.ref}}

        not ledger_internal_act?(act) ->
          {:error, {:scope_opening_act_not_ledger_internal, opening.ref, act.ref}}

        act.consequence != %{"scope_open" => draft} ->
          {:error, {:scope_opening_consequence_mismatch, opening.ref, act.ref}}

        act.scope_ref != opening.parent_ref ->
          {:error, {:scope_opening_parent_act_mismatch, opening.ref, act.ref}}

        act.accountable_ref != opening.accountable_ref ->
          {:error, {:scope_opening_accountable_act_mismatch, opening.ref, act.ref}}

        opening.ref not in act.target_refs ->
          {:error, {:scope_opening_target_missing, opening.ref, act.ref}}

        opening.opened_at != act.committed_at ->
          {:error, {:scope_opening_commit_time_mismatch, opening.ref, act.ref}}

        opening.host_generation != act.host_generation ->
          {:error, {:scope_opening_generation_act_mismatch, opening.ref, act.ref}}

        opening.ingress_ref != act.ingress_ref ->
          {:error, {:scope_opening_ingress_act_mismatch, opening.ref, act.ref}}

        true ->
          :ok
      end
    end
  end

  defp scope_domain_matches(projection, opening) do
    if opening.domain_ref == projection.domain_ref,
      do: :ok,
      else: {:error, {:scope_domain_mismatch, opening.ref, opening.domain_ref}}
  end

  defp scope_parent_exists(_projection, %Opening{parent_ref: nil}), do: :ok

  defp scope_parent_exists(projection, %Opening{} = opening) do
    if Map.has_key?(projection.scopes, opening.parent_ref),
      do: :ok,
      else: {:error, {:scope_parent_not_found, opening.ref, opening.parent_ref}}
  end

  defp scope_principals_exist(projection, opening) do
    refs =
      [opening.opened_by_ref, opening.accountable_ref]
      |> Enum.reject(&is_nil/1)

    case Enum.find(refs, &(not Map.has_key?(projection.principals, &1))) do
      nil -> :ok
      ref -> {:error, {:scope_principal_not_found, opening.ref, ref}}
    end
  end

  defp scope_disposition_authorities_exist(projection, opening) do
    case Enum.find(opening.disposition_authority_refs, fn ref ->
           not Map.has_key?(projection.principals, ref) and
             not Map.has_key?(projection.mandates, ref)
         end) do
      nil -> :ok
      ref -> {:error, {:scope_disposition_authority_not_found, opening.ref, ref}}
    end
  end

  defp validate_opening_submission_context(opening) do
    SubmissionContext.new(%{
      ref: opening.submission_context_ref,
      domain_ref: opening.domain_ref,
      scope_ref: opening.ref,
      authenticated_principal_ref: opening.opened_by_ref,
      authentication_ref: opening.authentication_ref,
      ingress_ref: opening.ingress_ref,
      channel_ref: opening.channel_ref,
      session_ref: opening.session_ref,
      host_generation: opening.host_generation
    })
    |> case do
      {:ok, _context} -> :ok
      {:error, reason} -> {:error, {:invalid_scope_submission_context, opening.ref, reason}}
    end
  end

  defp unique_declassification_act(projection, record) do
    case Map.fetch(projection.declassifications_by_act, record.source_act_ref) do
      :error ->
        :ok

      {:ok, existing_ref} ->
        {:error, {:act_already_has_declassification, record.source_act_ref, existing_ref}}
    end
  end

  defp unique_declassified_evidence(projection, record) do
    cond do
      Map.has_key?(projection.evidence, record.evidence_ref) ->
        {:error, {:declassified_evidence_already_recorded, record.evidence_ref}}

      Map.has_key?(projection.declassifications_by_evidence, record.evidence_ref) ->
        {:error, {:evidence_already_declassified, record.evidence_ref}}

      true ->
        :ok
    end
  end

  defp validate_declassification(
         projection,
         %Act{
           class: "data.declassify",
           consequence: %{"evidence_declassification" => draft}
         } = act,
         record
       )
       when map_size(act.consequence) == 1 do
    with true <- exact_row?(act.row, [:write, :govern]),
         true <- act.reservations in [%{}, []],
         true <- ledger_internal_act?(act),
         {:ok, decoded} <- Declassification.decode_draft(draft),
         true <- decoded.canonical == draft,
         {:ok, mandate} <- fetch_mandate(projection, act.mandate_ref),
         :ok <-
           Authority.owners_authorize_mandate?(
             mandate,
             decoded.removed_owner_refs,
             projection
           ),
         {:ok, expected} <- Declassification.from_draft(draft, act.ref, act.committed_at),
         true <- expected == record,
         :ok <-
           ErasureAnalysis.validate_evidence_available(
             projection,
             decoded.evidence.parent_refs
           ),
         {:ok, parents} <- evidence_set(projection, decoded.evidence.parent_refs),
         :ok <- Declassification.validate_transition(record, decoded.evidence, parents),
         {:ok, required_targets} <-
           Declassification.required_target_refs(decoded.evidence, decoded.removed_labels),
         true <- act_targets?(act, required_targets) do
      {:ok, decoded.evidence}
    else
      false -> {:error, {:invalid_evidence_declassification, record.ref, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_declassification(_projection, act, record),
    do: {:error, {:invalid_declassification_act, record.ref, act.ref}}

  defp unique_erasure_act(projection, erasure) do
    case Map.fetch(projection.erasures_by_act, erasure.source_act_ref) do
      :error ->
        :ok

      {:ok, existing_ref} ->
        {:error, {:act_already_has_erasure_request, erasure.source_act_ref, existing_ref}}
    end
  end

  defp validate_erasure_request(projection, act, erasure) do
    prefix = %{projection | acts: Map.delete(projection.acts, act.ref)}

    with {:ok, draft} <- Erasure.request_draft(erasure) do
      cond do
        act.class != "data.erase" ->
          {:error, {:erasure_act_class_mismatch, act.ref, act.class}}

        not exact_row?(act.row, [:attempt, :write, :govern]) ->
          {:error, {:erasure_act_row_mismatch, act.ref}}

        act.consequence != %{"erasure_request" => draft} ->
          {:error, {:erasure_consequence_mismatch, act.ref}}

        erasure.scope_ref != act.scope_ref ->
          {:error, {:erasure_scope_mismatch, erasure.ref, act.ref}}

        erasure.target_ref not in act.target_refs ->
          {:error, {:erasure_target_not_bound_to_act, erasure.ref, act.ref}}

        erasure.requested_at > act.committed_at ->
          {:error, {:erasure_request_from_future, erasure.ref}}

        true ->
          with :ok <- ErasureAnalysis.requestable?(prefix, erasure.target_ref) do
            ErasureAnalysis.validate_request(prefix, draft)
          end
      end
    end
  end

  defp validate_host_profile_revision(act, current, profile, data) do
    expected_consequence = %{
      "host_profile_revision" => %{
        "previous_ref" => current.ref,
        "host_profile" => HostProfile.canonical(profile)
      }
    }

    cond do
      act.class != "host_profile.revise" ->
        {:error, {:host_profile_revision_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:host_profile_revision_act_row_mismatch, act.ref}}

      not act_targets?(act, [current.ref, profile.ref]) ->
        {:error, {:host_profile_revision_targets_missing, act.ref}}

      field(data, :previous_ref) != current.ref ->
        {:error, {:host_profile_revision_previous_ref_mismatch, profile.ref}}

      profile.revision != current.revision + 1 ->
        {:error,
         {:host_profile_revision_not_sequential, profile.ref, current.revision, profile.revision}}

      profile.declared_at < current.declared_at or profile.declared_at > act.committed_at ->
        {:error, {:invalid_host_profile_revision_time, profile.ref, profile.declared_at}}

      act.host_profile_ref != current.ref ->
        {:error, {:host_profile_revision_act_context_mismatch, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:host_profile_revision_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_surface_revision(act, current, surface, data) do
    expected_consequence = %{
      "surface_revision" => %{
        "previous_ref" => current.ref,
        "surface" => Surface.canonical(surface)
      }
    }

    cond do
      act.class != "surface.revise" ->
        {:error, {:surface_revision_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:surface_revision_act_row_mismatch, act.ref}}

      not act_targets?(act, [current.ref, surface.ref]) ->
        {:error, {:surface_revision_targets_missing, act.ref}}

      field(data, :previous_ref) != current.ref ->
        {:error, {:surface_revision_previous_ref_mismatch, surface.ref}}

      surface.revision != current.revision + 1 ->
        {:error,
         {:surface_revision_not_sequential, surface.ref, current.revision, surface.revision}}

      act.surface_revision != current.revision ->
        {:error, {:surface_revision_act_context_mismatch, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:surface_revision_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp issue_mandate_meters(projection, %Mandate{parent_ref: nil} = mandate) do
    with :ok <- genesis_names(projection, :root_mandate_refs, mandate.ref),
         true <- mandate.source_ref == projection.genesis.ref do
      {:ok, initialize_meters(projection.meters, mandate)}
    else
      false -> {:error, {:invalid_root_mandate_source, mandate.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp issue_mandate_meters(projection, %Mandate{} = mandate) do
    with {:ok, parent} <- fetch_mandate(projection, mandate.parent_ref),
         {:ok, source_act} <- fetch_act(projection, mandate.source_ref),
         :ok <- validate_delegation_source(source_act, parent, mandate),
         :ok <- Authority.delegation_within?(parent, mandate, source_act.committed_at) do
      delegate_meters(projection, parent, mandate)
    end
  end

  defp genesis_names(%{genesis: nil}, _field, _ref), do: {:error, :genesis_required}

  defp genesis_names(%{genesis: genesis}, field_name, ref) do
    case Map.fetch!(genesis, field_name) do
      refs when is_list(refs) ->
        if ref in refs,
          do: :ok,
          else: {:error, {:record_not_named_by_genesis, field_name, ref}}

      ^ref ->
        :ok

      _different ->
        {:error, {:record_not_named_by_genesis, field_name, ref}}
    end
  end

  defp fetch_mandate(projection, mandate_ref) do
    case Map.fetch(projection.mandates, mandate_ref) do
      {:ok, mandate} -> {:ok, mandate}
      :error -> {:error, {:mandate_not_found, mandate_ref}}
    end
  end

  defp validate_delegation_source(source_act, parent, child) do
    expected_draft =
      child
      |> Mandate.canonical()
      |> Map.drop(["ref", "source_ref"])

    with true <- source_act.class == "mandate.delegate",
         true <- exact_row?(source_act.row, [:delegate, :govern]),
         true <- source_act.reservations in [%{}, []],
         true <- source_act.mandate_ref == parent.ref,
         true <- source_act.mandate_revision == parent.revision,
         true <- act_targets?(source_act, [parent.ref]),
         true <- source_act.consequence == %{"mandate_issue" => expected_draft} do
      :ok
    else
      false -> {:error, {:invalid_mandate_delegation_source, child.ref, source_act.ref}}
    end
  end

  defp delegate_meters(projection, parent, child) do
    with {:ok, parent_owner_ref} <- fetch_meter_owner(projection, parent.ref),
         {:ok, parent_accounts} <- fetch_meter_accounts(projection, parent.ref),
         child_accounts <- empty_meter_accounts(child),
         {:ok, parent_accounts, child_accounts} <-
           transfer_child_allocations(parent_accounts, child_accounts, child.meters) do
      {:ok,
       projection.meters
       |> Map.put(parent_owner_ref, parent_accounts)
       |> Map.put(child.ref, child_accounts)}
    end
  end

  defp empty_meter_accounts(mandate) do
    Map.new(mandate.meters, fn {meter_ref, _quantity} ->
      {meter_ref,
       %{
         ceiling: 0,
         available: 0,
         reserved: 0,
         suspended: 0,
         spent: 0,
         delegated: 0
       }}
    end)
  end

  defp transfer_child_allocations(parent_accounts, child_accounts, allocations) do
    allocations
    |> Enum.sort_by(fn {meter_ref, _quantity} -> meter_ref end)
    |> Enum.reduce_while({:ok, parent_accounts, child_accounts}, fn
      {meter_ref, quantity}, {:ok, parents, children} ->
        with {:ok, parent_account} <- fetch_meter_account(parents, meter_ref),
             {:ok, child_account} <- fetch_meter_account(children, meter_ref),
             {:ok, parent_account, child_account} <-
               Meter.delegate(parent_account, child_account, quantity) do
          {:cont,
           {:ok, Map.put(parents, meter_ref, parent_account),
            Map.put(children, meter_ref, child_account)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp canonical_restriction_event(successor, data) do
    if field(data, :successor) == Mandate.canonical(successor),
      do: :ok,
      else: {:error, {:noncanonical_mandate_restriction, successor.ref}}
  end

  defp validate_restriction_contract(act, predecessor, successor, data) do
    expected_consequence = %{
      "mandate_restrict" => %{
        "predecessor_ref" => predecessor.ref,
        "successor" => successor |> Mandate.canonical() |> Map.drop(["ref", "source_ref"])
      }
    }

    cond do
      act.class != "mandate.restrict" ->
        {:error, {:mandate_restriction_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:mandate_restriction_act_row_mismatch, act.ref}}

      act.reservations not in [%{}, []] ->
        {:error, {:mandate_restriction_act_has_reservations, act.ref}}

      not ledger_internal_act?(act) ->
        {:error, {:mandate_restriction_act_not_ledger_internal, act.ref}}

      not act_targets?(act, [predecessor.ref]) ->
        {:error, {:mandate_restriction_act_target_missing, act.ref, predecessor.ref}}

      field(data, :act_ref) != act.ref ->
        {:error, {:mandate_restriction_event_act_mismatch, successor.ref, act.ref}}

      field(data, :predecessor_ref) != predecessor.ref ->
        {:error, {:mandate_restriction_predecessor_mismatch, successor.ref, predecessor.ref}}

      successor.source_ref != act.ref ->
        {:error, {:mandate_restriction_source_mismatch, successor.ref, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:mandate_restriction_consequence_mismatch, act.ref, successor.ref}}

      true ->
        Authority.restriction_within?(predecessor, successor, act.committed_at)
    end
  end

  defp restriction_link_available(projection, predecessor_ref, successor_ref) do
    cond do
      Map.has_key?(projection.mandate_successors, predecessor_ref) ->
        {:error, {:mandate_already_has_successor, predecessor_ref}}

      Map.has_key?(projection.mandate_predecessors, successor_ref) ->
        {:error, {:mandate_already_has_predecessor, successor_ref}}

      succession_reaches?(projection.mandate_successors, successor_ref, predecessor_ref) ->
        {:error, {:mandate_restriction_cycle, predecessor_ref, successor_ref}}

      true ->
        :ok
    end
  end

  defp restrictable_predecessor(projection, predecessor, time) do
    with :ok <- Authority.restriction_status(predecessor, authority_view(projection)),
         {:ok, false} <- mandate_terminal?(projection, predecessor, time) do
      :ok
    else
      {:ok, true} -> {:error, {:mandate_restriction_predecessor_inactive, predecessor.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp succession_reaches?(successors, current_ref, target_ref),
    do: succession_reaches?(successors, current_ref, target_ref, MapSet.new())

  defp succession_reaches?(successors, current_ref, target_ref, visited) do
    cond do
      current_ref == target_ref ->
        true

      MapSet.member?(visited, current_ref) ->
        true

      is_nil(Map.get(successors, current_ref)) ->
        false

      true ->
        succession_reaches?(
          successors,
          Map.fetch!(successors, current_ref),
          target_ref,
          MapSet.put(visited, current_ref)
        )
    end
  end

  defp restriction_data(act, predecessor, successor) do
    %{
      "act_ref" => act.ref,
      "predecessor_ref" => predecessor.ref,
      "successor" => Mandate.canonical(successor)
    }
  end

  defp validate_revocation(act, mandate, data) do
    controllers = Map.get(mandate.revocation, "controller_refs", [])
    effective_at = field(data, :effective_at)

    consequence = %{
      "mandate_revoke" => %{
        "mandate_ref" => field(data, :mandate_ref)
      }
    }

    cond do
      act.class != "mandate.revoke" ->
        {:error, {:revocation_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:revocation_act_row_mismatch, act.ref}}

      act.reservations not in [%{}, []] ->
        {:error, {:revocation_act_has_reservations, act.ref}}

      not act_targets?(act, [mandate.ref]) ->
        {:error, {:revocation_act_target_missing, act.ref, mandate.ref}}

      act.proposer_ref not in controllers ->
        {:error, {:revocation_controller_not_authorized, act.proposer_ref, mandate.ref}}

      effective_at != act.committed_at ->
        {:error, {:invalid_revocation_effective_at, mandate.ref, effective_at}}

      act.consequence != consequence ->
        {:error, {:revocation_consequence_mismatch, act.ref, mandate.ref}}

      true ->
        :ok
    end
  end

  defp fetch_act(projection, act_ref) do
    case Map.fetch(projection.acts, act_ref) do
      {:ok, act} -> {:ok, act}
      :error -> {:error, {:act_not_found, act_ref}}
    end
  end

  defp fetch_attempt(projection, attempt_ref) do
    case Map.fetch(projection.attempts, attempt_ref) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, {:attempt_not_found, attempt_ref}}
    end
  end

  defp fetch_decision(projection, decision_ref) do
    case Map.fetch(projection.decisions, decision_ref) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, {:decision_not_found, decision_ref}}
    end
  end

  defp attempt_available(projection, attempt, act) do
    cond do
      not Governance.executor_mediated?(act) ->
        {:error, {:act_not_executor_mediated, act.ref}}

      not MapSet.member?(projection.dispatch_ready, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      has_reservations?(act) and
          Map.get(projection.reservation_states, act.ref) != :reserved ->
        {:error, {:act_reservation_not_attemptable, act.ref}}

      true ->
        case Map.fetch(projection.attempts_by_act, attempt.act_ref) do
          :error -> :ok
          {:ok, existing_ref} -> {:error, {:act_already_attempted, attempt.act_ref, existing_ref}}
        end
    end
  end

  defp nonce_available(projection, nonce_digest) do
    if MapSet.member?(projection.consumed_nonces, nonce_digest),
      do: {:error, {:grant_nonce_already_consumed, nonce_digest}},
      else: :ok
  end

  defp match_attempt_to_act(attempt, act) do
    cond do
      attempt.executor_ref != act.executor_ref ->
        {:error, {:attempt_executor_mismatch, attempt.ref, act.ref}}

      attempt.material_digest != act.material_digest ->
        {:error, {:attempt_material_mismatch, attempt.ref, act.ref}}

      attempt.started_at < act.committed_at ->
        {:error, {:attempt_precedes_act, attempt.ref, act.ref}}

      true ->
        :ok
    end
  end

  defp match_outcome_to_attempt(projection, outcome, attempt) do
    cond do
      outcome.act_ref != attempt.act_ref ->
        {:error, {:outcome_act_mismatch, outcome.ref, attempt.ref}}

      Map.get(projection.attempts_by_act, outcome.act_ref) != attempt.ref ->
        {:error, {:outcome_attempt_index_mismatch, outcome.ref, attempt.ref}}

      true ->
        :ok
    end
  end

  defp validate_outcome_time(outcome, attempt) do
    if outcome.observed_at >= attempt.started_at,
      do: :ok,
      else: {:error, {:outcome_precedes_attempt, outcome.ref, attempt.ref}}
  end

  defp validate_outcome_transition(projection, outcome) do
    prior =
      projection.outcomes
      |> Map.values()
      |> Enum.filter(&(&1.attempt_ref == outcome.attempt_ref))

    if Outcome.correction?(outcome) do
      validate_outcome_correction(prior, outcome)
    else
      case Enum.find(prior, &(&1.status != :ambiguous)) do
        nil ->
          :ok

        terminal ->
          {:error,
           {:attempt_already_has_definitive_outcome, outcome.attempt_ref, terminal.ref,
            terminal.status}}
      end
    end
  end

  defp validate_outcome_correction(prior, outcome) do
    target = Enum.find(prior, &(&1.ref == outcome.contradicts_outcome_ref))
    existing = Enum.find(prior, &(&1.contradicts_outcome_ref == outcome.contradicts_outcome_ref))

    cond do
      is_nil(target) ->
        {:error, {:corrected_outcome_not_found, outcome.contradicts_outcome_ref}}

      target.status != :definitive_no_effect ->
        {:error, {:corrected_outcome_not_no_effect, target.ref}}

      target.act_ref != outcome.act_ref or target.attempt_ref != outcome.attempt_ref ->
        {:error, {:outcome_correction_cause_mismatch, outcome.ref, target.ref}}

      outcome.observed_at < target.observed_at ->
        {:error, {:outcome_correction_precedes_target, outcome.ref, target.ref}}

      not is_nil(existing) ->
        {:error, {:outcome_already_corrected, target.ref, existing.ref}}

      true ->
        :ok
    end
  end

  defp validate_decision_context(projection, decision) do
    with {:ok, context} <- decision_submission_context(decision),
         {:ok, _opening} <- scope_context(projection, context) do
      cond do
        decision.domain_ref != projection.domain_ref ->
          {:error, {:decision_domain_mismatch, decision.ref, decision.domain_ref}}

        not Map.has_key?(projection.principals, decision.authenticated_principal_ref) ->
          {:error, {:authenticated_principal_not_found, decision.authenticated_principal_ref}}

        is_nil(projection.host_profile) or
            decision.host_profile_ref != projection.host_profile.ref ->
          {:error, {:decision_host_profile_mismatch, decision.ref}}

        is_nil(projection.surface) or decision.surface_revision != projection.surface.revision ->
          {:error, {:decision_surface_revision_mismatch, decision.ref}}

        decision.outcome == :admitted and
            decision.proposer_ref != decision.authenticated_principal_ref ->
          {:error, {:admitted_decision_principal_mismatch, decision.ref}}

        true ->
          :ok
      end
    end
  end

  defp decision_submission_context(decision) do
    SubmissionContext.new(%{
      ref: decision.submission_context_ref,
      domain_ref: decision.domain_ref,
      scope_ref: decision.scope_ref,
      authenticated_principal_ref: decision.authenticated_principal_ref,
      authentication_ref: decision.authentication_ref,
      ingress_ref: decision.ingress_ref,
      channel_ref: decision.channel_ref,
      session_ref: decision.session_ref,
      host_generation: decision.host_generation
    })
    |> case do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:invalid_decision_submission_context, decision.ref, reason}}
    end
  end

  defp validate_decision_revision(projection, decision, entry_revision) do
    expected_entry_revision = projection.revision + 1

    cond do
      decision.authority_revision != projection.revision ->
        {:error,
         {:decision_authority_revision_mismatch, decision.ref, projection.revision,
          decision.authority_revision}}

      not is_nil(entry_revision) and entry_revision != expected_entry_revision ->
        {:error,
         {:decision_entry_revision_mismatch, decision.ref, expected_entry_revision,
          entry_revision}}

      not is_nil(entry_revision) and decision.authority_revision != entry_revision - 1 ->
        {:error, {:decision_authority_fence_mismatch, decision.ref, entry_revision}}

      true ->
        :ok
    end
  end

  defp validate_decision_evidence_basis(projection, decision) do
    with :ok <-
           ErasureAnalysis.validate_evidence_available(
             projection,
             decision.recognition_evidence_refs
           ),
         {:ok, evidence} <- evidence_set(projection, decision.recognition_evidence_refs) do
      case Enum.find(evidence, &(&1.observed_at > decision.decided_at)) do
        nil -> :ok
        future -> {:error, {:decision_evidence_from_future, decision.ref, future.ref}}
      end
    end
  end

  defp validate_decision_authority(_projection, %{mandate_ref: nil, outcome: outcome})
       when outcome != :admitted,
       do: :ok

  defp validate_decision_authority(projection, decision) do
    case Map.fetch(projection.mandates, decision.mandate_ref) do
      {:ok, mandate} -> validate_decision_mandate(projection, decision, mandate)
      :error -> {:error, {:decision_mandate_not_found, decision.mandate_ref}}
    end
  end

  defp validate_decision_mandate(projection, decision, mandate) do
    cond do
      decision.mandate_revision != mandate.revision ->
        {:error, {:decision_mandate_revision_mismatch, decision.ref}}

      decision.outcome != :admitted ->
        :ok

      decision.reasons != [] ->
        {:error, {:admitted_decision_has_reasons, decision.ref}}

      retained_revocation_decision?(decision, mandate) ->
        validate_retained_revocation_decision(projection, decision, mandate)

      decision.authenticated_principal_ref != mandate.holder_ref ->
        {:error, {:decision_mandate_holder_mismatch, decision.ref}}

      decision.authorizer_ref != mandate.grantor_ref ->
        {:error, {:decision_authorizer_mismatch, decision.ref}}

      decision.accountable_ref != mandate.accountable_ref ->
        {:error, {:decision_accountable_mismatch, decision.ref}}

      decision.executor_ref not in mandate.executor_refs ->
        {:error, {:decision_executor_outside_mandate, decision.ref}}

      decision.decided_at < mandate.not_before or decision.decided_at >= mandate.expires_at ->
        {:error, {:decision_mandate_not_current, decision.ref}}

      effective_revocation?(Map.get(projection.revocations, mandate.ref), decision.decided_at) ->
        {:error, {:decision_mandate_revoked, decision.ref}}

      true ->
        :ok
    end
  end

  defp retained_revocation_decision?(decision, mandate) do
    decision.candidate_class == "mandate.revoke" and
      decision.mandate_ref == mandate.ref and
      Map.get(mandate.revocation, "mode") in [:retained_controller, "retained_controller"]
  end

  defp validate_retained_revocation_decision(projection, decision, mandate) do
    controllers = Map.get(mandate.revocation, "controller_refs", [])

    cond do
      decision.authenticated_principal_ref not in controllers ->
        {:error, {:decision_revocation_controller_mismatch, decision.ref}}

      decision.proposer_ref != decision.authenticated_principal_ref ->
        {:error, {:decision_revocation_proposer_mismatch, decision.ref}}

      decision.authorizer_ref != decision.authenticated_principal_ref ->
        {:error, {:decision_revocation_authorizer_mismatch, decision.ref}}

      decision.accountable_ref != mandate.accountable_ref ->
        {:error, {:decision_accountable_mismatch, decision.ref}}

      decision.executor_ref != Governance.kernel_executor_ref() ->
        {:error, {:decision_revocation_executor_mismatch, decision.ref}}

      decision.recognition_refs != [] or decision.recognition_evidence_refs != [] or
          decision.reservations not in [%{}, []] ->
        {:error, {:decision_revocation_not_narrow, decision.ref}}

      decision.decided_at < mandate.not_before or decision.decided_at >= mandate.expires_at ->
        {:error, {:decision_mandate_not_current, decision.ref}}

      effective_revocation?(Map.get(projection.revocations, mandate.ref), decision.decided_at) ->
        {:error, {:decision_mandate_revoked, decision.ref}}

      true ->
        :ok
    end
  end

  defp match_act_to_decision(projection, act, decision) do
    fields = [
      :candidate_identity_key,
      :candidate_digest,
      :submission_context_ref,
      :authenticated_principal_ref,
      :authentication_ref,
      :ingress_ref,
      :host_generation,
      :mandate_ref,
      :mandate_revision,
      :recognition_refs,
      :recognition_evidence_refs,
      :reservations,
      :proposer_ref,
      :executor_ref,
      :authorizer_ref,
      :accountable_ref,
      :scope_ref,
      :consent,
      :host_profile_ref,
      :surface_revision
    ]

    mismatch = Enum.find(fields, &(Map.fetch!(decision, &1) != Map.fetch!(act, &1)))
    identity = Map.get(projection.candidate_identities, act.candidate_identity_key)
    mandate = Map.get(projection.mandates, act.mandate_ref)

    cond do
      decision.outcome != :admitted ->
        {:error, {:act_for_non_admitted_decision, decision.ref}}

      projection.revision != decision.authority_revision + 1 ->
        {:error, {:act_not_adjacent_to_decision, act.ref, decision.ref}}

      mismatch ->
        {:error, {:decision_act_mismatch, mismatch, decision.ref, act.ref}}

      decision.candidate_class != act.class ->
        {:error, {:decision_act_class_mismatch, decision.ref, act.ref}}

      act.material_digest != decision.candidate_digest ->
        {:error, {:act_material_digest_mismatch, act.ref}}

      not decision_act_contract_authorized?(act, decision, mandate) ->
        {:error, {:act_executor_contract_outside_mandate, act.ref}}

      act.committed_at != decision.decided_at ->
        {:error, {:act_commit_time_mismatch, act.ref}}

      identity != %{digest: act.candidate_digest, decision_ref: decision.ref} ->
        {:error, {:act_candidate_identity_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp decision_act_contract_authorized?(_act, _decision, nil), do: false

  defp decision_act_contract_authorized?(act, decision, mandate) do
    act.executor_contract_ref in mandate.executor_contract_refs or
      (retained_revocation_decision?(decision, mandate) and
         act.executor_contract_ref == Governance.kernel_contract_ref())
  end

  defp one_act_per_decision(projection, decision_ref) do
    case Enum.find(projection.acts, fn {_ref, act} -> act.decision_ref == decision_ref end) do
      nil -> :ok
      {existing_ref, _act} -> {:error, {:decision_already_has_act, decision_ref, existing_ref}}
    end
  end

  defp rebuild_candidate(_projection, act) do
    with {:ok, reservations} <- normalize_reservation_amounts(act.reservations) do
      Candidate.new(%{
        identity_key: act.candidate_identity_key,
        material_digest: act.material_digest,
        class: act.class,
        consequence: act.consequence,
        row: act.row,
        requested_mandate_ref: act.requested_mandate_ref,
        proposer_ref: act.proposer_ref,
        executor_ref: act.executor_ref,
        accountable_ref: act.accountable_ref,
        scope_ref: act.scope_ref,
        subject_refs: act.subject_refs,
        target_refs: act.target_refs,
        purpose_ref: act.purpose_ref,
        purpose_params: act.purpose_params,
        consent: act.consent,
        evidence_refs: act.evidence_refs,
        disclosure: act.disclosure,
        presentation_ref: act.presentation_ref,
        meter_requests: reservations,
        executor_contract_ref: act.executor_contract_ref,
        observation_window_ms: act.observation_window_ms
      })
      |> case do
        {:ok, candidate} -> {:ok, candidate}
        {:error, _reason} -> {:error, :act_candidate_material_mismatch}
      end
    end
  end

  defp validate_candidate_at_act(projection, candidate, act, decision) do
    with {:ok, mandate} <- fetch_mandate(projection, act.mandate_ref),
         :ok <- validate_surface_binding(projection, candidate, act),
         :ok <-
           ErasureAnalysis.validate_evidence_available(projection, candidate.evidence_refs),
         :ok <- validate_candidate_disclosure(projection, candidate),
         {:ok, effective_mandate} <-
           validate_candidate_authority(projection, candidate, act, mandate),
         {:ok, mandate_basis_refs} <-
           validate_candidate_recognition(
             projection,
             candidate,
             decision,
             effective_mandate
           ),
         {:ok, presentation_basis_refs} <-
           validate_presentation_binding(projection, candidate, act),
         :ok <-
           validate_exact_recognition_basis(
             decision,
             mandate_basis_refs ++ presentation_basis_refs
           ) do
      validate_reservation_contract(projection, candidate, act, decision, effective_mandate)
    end
  end

  defp validate_candidate_disclosure(_projection, %Candidate{disclosure: nil}), do: :ok

  defp validate_candidate_disclosure(projection, %Candidate{disclosure: disclosure}),
    do: Disclosure.verify_sources(disclosure, projection.evidence)

  defp validate_surface_binding(%{surface: %Surface{} = surface}, candidate, act) do
    case Surface.classify(surface, candidate.class) do
      {:ok, row} when row == candidate.row ->
        with :ok <- Surface.validate_consequence(surface, candidate) do
          if Surface.presentation_required?(surface, candidate.class) and
               is_nil(candidate.presentation_ref) do
            {:error, {:act_missing_required_presentation, act.ref, candidate.class}}
          else
            :ok
          end
        else
          {:error, reason} -> {:error, {:act_consequence_contract_mismatch, act.ref, reason}}
        end

      {:ok, _different} ->
        {:error, {:act_surface_row_mismatch, act.ref}}

      {:error, :unknown_class} ->
        {:error, {:act_unknown_surface_class, act.ref, candidate.class}}
    end
  end

  defp validate_surface_binding(_projection, _candidate, act),
    do: {:error, {:act_surface_not_found, act.ref}}

  defp validate_candidate_authority(projection, candidate, act, mandate, time \\ nil) do
    context = %{
      domain_ref: projection.domain_ref,
      scope_ref: act.scope_ref,
      authenticated_principal_ref: act.authenticated_principal_ref,
      authentication_ref: act.authentication_ref,
      ingress_ref: act.ingress_ref,
      host_generation: act.host_generation
    }

    view = %{
      mandates: projection.mandates,
      mandate_successors: projection.mandate_successors,
      revocations: projection.revocations,
      blocked_mandate_refs: blocked_mandate_refs(projection),
      blocked_effect_digests: blocked_effect_digests(projection),
      host_generation: act.host_generation
    }

    case Authority.authorize(candidate, context, mandate, view, time || act.committed_at) do
      {:ok, effective_mandate} -> {:ok, effective_mandate}
      {:error, reason} -> {:error, {:act_without_current_authority, act.ref, reason}}
    end
  end

  defp validate_attempt_authority(projection, attempt, act) do
    with {:ok, candidate} <- rebuild_candidate(projection, act),
         {:ok, mandate} <- fetch_mandate(projection, act.mandate_ref) do
      case validate_candidate_authority(
             projection,
             candidate,
             act,
             mandate,
             attempt.started_at
           ) do
        {:ok, _effective_mandate} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp validate_candidate_recognition(projection, candidate, decision, mandate) do
    expected_refs = mandate.conditions |> Enum.map(&record_ref/1) |> Enum.sort()

    available_evidence =
      projection |> ErasureAnalysis.available_evidence() |> Map.values()

    {recognition, basis_refs} =
      Recognition.check_with_basis(mandate.conditions, available_evidence, decision.decided_at)

    with true <- decision.recognition_refs == expected_refs,
         {:ok, _declared_evidence} <- evidence_set(projection, candidate.evidence_refs),
         :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs),
         :satisfied <- recognition do
      {:ok, basis_refs}
    else
      false -> {:error, {:decision_recognition_refs_mismatch, decision.ref}}
      {:error, _reason} = error -> error
      result -> {:error, {:act_recognition_not_satisfied, candidate.ref, result}}
    end
  end

  defp validate_presentation_binding(
         projection,
         %Candidate{class: "presentation.show"} = candidate,
         act
       ) do
    with {:ok, presentation_ref} <- Presentation.show_presentation_ref(candidate.consequence),
         {:ok, presentation} <- Map.fetch(projection.presentations, presentation_ref),
         :ok <- Presentation.validate_show(candidate, presentation),
         :ok <- Presentation.validate_show(act, presentation),
         true <- presentation.prepared_at <= act.committed_at do
      {:ok, []}
    else
      :error -> {:error, {:act_presentation_not_found, act.ref}}
      false -> {:error, {:act_presentation_show_precedes_preparation, act.ref}}
      {:error, reason} -> {:error, {:invalid_presentation_show_act, act.ref, reason}}
    end
  end

  defp validate_presentation_binding(_projection, %Candidate{presentation_ref: nil}, %{
         presentation_ref: nil
       }),
       do: {:ok, []}

  defp validate_presentation_binding(projection, candidate, act) do
    case Map.fetch(projection.presentations, act.presentation_ref) do
      {:ok, presentation} ->
        with :ok <- Presentation.validate_candidate(candidate, presentation),
             true <- presentation.prepared_at <= act.committed_at,
             {:ok, approval_refs, basis_refs} <-
               validate_presentation_approval(
                 projection,
                 presentation,
                 act.committed_at,
                 act.ref
               ),
             true <-
               presentation.candidate_binding_ref ==
                 Candidate.presentation_binding_ref(candidate, approval_refs),
             :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs) do
          {:ok, basis_refs}
        else
          false -> {:error, {:act_presentation_binding_mismatch, act.ref}}
          {:error, _reason} = error -> error
        end

      :error ->
        {:error, {:act_presentation_not_found, act.ref, act.presentation_ref}}
    end
  end

  defp validate_presentation_approval(projection, presentation, time, act_ref) do
    evidence = projection |> ErasureAnalysis.available_evidence() |> Map.values()
    matching = Enum.filter(evidence, &approval_for_presentation?(&1, presentation.ref))

    current =
      Enum.reduce(matching, [], fn approval, valid ->
        case presentation_approval_basis(
               approval,
               presentation,
               projection,
               evidence,
               time
             ) do
          {:ok, basis_refs} -> [{approval, basis_refs} | valid]
          :invalid -> valid
        end
      end)

    cond do
      Enum.any?(current, fn {approval, _basis} -> approval.stance == :contradicts end) ->
        {:error, {:act_presentation_approval_contradicted, act_ref}}

      Enum.any?(current, fn {approval, _basis} -> approval.stance == :supports end) ->
        approval_refs =
          current |> Enum.map(fn {approval, _basis} -> approval.ref end) |> Enum.sort()

        basis_refs =
          current
          |> Enum.flat_map(fn {_approval, refs} -> refs end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, approval_refs, basis_refs}

      matching == [] ->
        {:error, {:act_presentation_approval_missing, act_ref}}

      true ->
        {:error, {:act_presentation_approval_not_current_or_final, act_ref}}
    end
  end

  defp required_evidence_declared(required_refs, declared_refs) do
    case required_refs -- declared_refs do
      [] -> :ok
      missing -> {:error, {:recognition_basis_not_declared, missing}}
    end
  end

  defp approval_for_presentation?(%Evidence{} = evidence, presentation_ref) do
    case Presentation.approval_refs(evidence) do
      {:ok, ^presentation_ref, _show_act_ref} -> true
      _other -> false
    end
  end

  defp approval_for_presentation?(_evidence, _presentation_ref), do: false

  defp presentation_approval_basis(approval, presentation, projection, evidence, time) do
    with {:ok, _presentation_ref, show_act_ref} <- Presentation.approval_refs(approval),
         {:ok, show_act} <- Map.fetch(projection.acts, show_act_ref),
         {:ok, basis_refs} <-
           Presentation.validate_response_with_basis(
             approval,
             presentation,
             show_act,
             Map.values(projection.outcomes),
             evidence,
             time
           ) do
      {:ok, basis_refs}
    else
      _invalid -> :invalid
    end
  end

  defp validate_exact_recognition_basis(decision, basis_refs) do
    expected = basis_refs |> Enum.uniq() |> Enum.sort()

    if decision.recognition_evidence_refs == expected,
      do: :ok,
      else: {:error, {:decision_recognition_evidence_refs_mismatch, decision.ref}}
  end

  defp validate_reservation_contract(projection, candidate, act, decision, mandate) do
    requests = candidate.meter_requests

    cond do
      map_size(requests) > 0 and not act.row.spend ->
        {:error, {:act_meter_request_not_declared_in_row, act.ref}}

      map_size(requests) == 0 and act.row.spend ->
        {:error, {:act_spend_without_meter_request, act.ref}}

      Enum.any?(Map.keys(requests), &(not Map.has_key?(mandate.meters, &1))) ->
        {:error, {:act_meter_outside_mandate, act.ref}}

      true ->
        with {:ok, declared} <- normalize_reservation_amounts(decision.reservations),
             true <- declared == requests,
             {:ok, accounts} <- fetch_meter_accounts(projection, mandate.ref),
             {:ok, planned} <- Meter.plan_reservations(requests, accounts),
             true <- reservation_list_to_map(planned) == requests do
          :ok
        else
          false -> {:error, {:act_reservation_plan_mismatch, act.ref}}
          {:error, reason} -> {:error, {:act_invalid_reservation_plan, act.ref, reason}}
        end
    end
  end

  defp reservation_list_to_map(reservations) do
    Map.new(reservations, fn reservation ->
      {field(reservation, :meter_ref), field(reservation, :quantity)}
    end)
  end

  defp validate_dispatch(projection, act, data) do
    cond do
      not Governance.executor_mediated?(act) ->
        {:error, {:act_not_executor_mediated, act.ref}}

      field(data, :executor_ref) != act.executor_ref ->
        {:error, {:dispatch_executor_mismatch, act.ref}}

      field(data, :executor_contract_ref) != act.executor_contract_ref ->
        {:error, {:dispatch_contract_mismatch, act.ref}}

      MapSet.member?(projection.dispatch_ready, act.ref) ->
        {:error, {:duplicate_dispatch_ready, act.ref}}

      Map.has_key?(projection.dispatch_cancellations, act.ref) ->
        {:error, {:dispatch_already_cancelled, act.ref}}

      Map.has_key?(projection.attempts_by_act, act.ref) ->
        {:error, {:act_already_attempted, act.ref}}

      open_disputed_duty_for_act?(projection, act.ref) ->
        {:error, {:act_dispatch_blocked_by_disputed_evidence, act.ref}}

      act.reservations not in [%{}, []] and
          Map.get(projection.reservation_states, act.ref) != :reserved ->
        {:error, {:act_reservation_not_ready, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_dispatch_cancellation(projection, act, data) do
    cond do
      not Governance.executor_mediated?(act) ->
        {:error, {:dispatch_cancellation_act_not_executor_mediated, act.ref}}

      not MapSet.member?(projection.dispatch_ready, act.ref) ->
        {:error, {:dispatch_cancellation_not_pending, act.ref}}

      Map.has_key?(projection.attempts_by_act, act.ref) ->
        {:error, {:dispatch_cancellation_after_attempt, act.ref}}

      Map.has_key?(projection.dispatch_cancellations, act.ref) ->
        {:error, {:duplicate_dispatch_cancellation, act.ref}}

      field(data, :mandate_ref) != act.mandate_ref ->
        {:error, {:dispatch_cancellation_mandate_mismatch, act.ref}}

      has_reservations?(act) and
          Map.get(projection.reservation_states, act.ref) != :reserved ->
        {:error, {:dispatch_cancellation_reservation_not_pending, act.ref}}

      true ->
        validate_dispatch_cancellation_cause(projection, act, data)
    end
  end

  defp validate_dispatch_cancellation_cause(projection, act, data) do
    case field(data, :reason) do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        with {:ok, cause_act} <- fetch_act(projection, field(data, :cause_ref)),
             :ok <- validate_governance_cancellation_time(act, cause_act, data),
             {:ok, target_mandate_ref, cascade?} <-
               cancellation_authority_change(projection, cause_act, reason),
             {:ok, true} <-
               mandate_affected_by_change?(
                 projection,
                 act.mandate_ref,
                 target_mandate_ref,
                 cascade?
               ) do
          :ok
        else
          {:ok, false} -> {:error, {:dispatch_cancellation_mandate_not_affected, act.ref}}
          {:error, _reason} = error -> error
        end

      :disputed_evidence ->
        with {:ok, duty} <- fetch_duty_by_ref(projection, field(data, :cause_ref)),
             true <- duty.class == :disputed_evidence,
             true <- duty.status == :open,
             true <- duty.act_ref == act.ref,
             true <- is_nil(duty.attempt_ref),
             true <- duty.mandate_ref == act.mandate_ref,
             true <- field(data, :cancelled_at) == duty.opened_at,
             true <- act.committed_at <= duty.opened_at do
          :ok
        else
          false -> {:error, {:invalid_disputed_dispatch_cancellation, act.ref}}
          {:error, _reason} = error -> error
        end

      :mandate_expired ->
        with {:ok, mandate} <- fetch_mandate(projection, act.mandate_ref),
             true <- field(data, :cause_ref) == mandate.ref,
             true <- act.mandate_revision == mandate.revision,
             true <- field(data, :cancelled_at) == mandate.expires_at do
          :ok
        else
          false -> {:error, {:invalid_dispatch_expiration, act.ref}}
          {:error, _reason} = error -> error
        end

      reason ->
        {:error, {:invalid_dispatch_cancellation_reason, act.ref, reason}}
    end
  end

  defp validate_governance_cancellation_time(act, cause_act, data) do
    cond do
      field(data, :cause_ref) != cause_act.ref ->
        {:error, {:dispatch_cancellation_cause_mismatch, act.ref}}

      field(data, :cancelled_at) != cause_act.committed_at ->
        {:error, {:dispatch_cancellation_time_mismatch, act.ref}}

      act.committed_at > cause_act.committed_at ->
        {:error, {:dispatch_cancellation_precedes_act, act.ref}}

      true ->
        :ok
    end
  end

  defp open_disputed_duty_for_act?(projection, act_ref) do
    Enum.any?(projection.duties, fn {_cause_key, duty} ->
      duty.class == :disputed_evidence and duty.status == :open and duty.act_ref == act_ref and
        is_nil(duty.attempt_ref)
    end)
  end

  defp cancellation_authority_change(
         projection,
         %Act{
           class: "mandate.revoke",
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
         } = cause_act,
         :mandate_revoked
       )
       when map_size(cause_act.consequence) == 1 and map_size(command) == 1 do
    with {:ok, mandate} <- fetch_mandate(projection, mandate_ref),
         {:ok, revocation} <- Map.fetch(projection.revocations, mandate_ref),
         true <- field(revocation, :identity) == cause_act.ref,
         true <- field(revocation, :effective_at) == cause_act.committed_at do
      {:ok, mandate_ref, field(mandate.revocation, :mode) == :cascade}
    else
      :error -> {:error, {:dispatch_cancellation_revocation_not_recorded, cause_act.ref}}
      false -> {:error, {:dispatch_cancellation_revocation_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_authority_change(
         projection,
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" => %{"predecessor_ref" => predecessor_ref} = command
           }
         } = cause_act,
         :mandate_restricted
       )
       when map_size(cause_act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor_ref} <- Map.fetch(projection.mandate_successors, predecessor_ref),
         {:ok, successor} <- fetch_mandate(projection, successor_ref),
         true <- successor.source_ref == cause_act.ref do
      {:ok, predecessor_ref, true}
    else
      :error -> {:error, {:dispatch_cancellation_restriction_not_recorded, cause_act.ref}}
      false -> {:error, {:dispatch_cancellation_restriction_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_authority_change(_projection, cause_act, reason),
    do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref, reason}}

  defp mandate_affected_by_change?(_projection, mandate_ref, mandate_ref, _cascade?),
    do: {:ok, true}

  defp mandate_affected_by_change?(_projection, _mandate_ref, _target_ref, false),
    do: {:ok, false}

  defp mandate_affected_by_change?(projection, mandate_ref, target_ref, true),
    do: mandate_descends_from?(projection, mandate_ref, target_ref, MapSet.new())

  defp mandate_descends_from?(_projection, target_ref, target_ref, _visited), do: {:ok, true}

  defp mandate_descends_from?(projection, mandate_ref, target_ref, visited) do
    cond do
      MapSet.member?(visited, mandate_ref) ->
        {:error, {:mandate_ancestry_cycle, mandate_ref}}

      true ->
        case fetch_mandate(projection, mandate_ref) do
          {:ok, %Mandate{parent_ref: nil}} ->
            {:ok, false}

          {:ok, %Mandate{parent_ref: parent_ref}} ->
            mandate_descends_from?(
              projection,
              parent_ref,
              target_ref,
              MapSet.put(visited, mandate_ref)
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp evidence_exists(projection, refs) do
    case Enum.find(refs, &(not Map.has_key?(projection.evidence, &1))) do
      nil -> :ok
      ref -> {:error, {:outcome_evidence_not_found, ref}}
    end
  end

  defp validate_evidence_scope_binding(projection, evidence) do
    scope_ref = field(evidence.bindings, :scope_ref)

    if is_nil(scope_ref) do
      :ok
    else
      case Map.fetch(projection.scopes, scope_ref) do
        {:ok, opening} ->
          cond do
            field(evidence.bindings, :domain_ref) != projection.domain_ref ->
              {:error, {:evidence_scope_domain_mismatch, evidence.ref, scope_ref}}

            field(evidence.bindings, :authenticated_principal_ref) != opening.opened_by_ref ->
              {:error, {:evidence_scope_principal_mismatch, evidence.ref, scope_ref}}

            field(evidence.bindings, :authentication_ref) != opening.authentication_ref ->
              {:error, {:evidence_scope_authentication_mismatch, evidence.ref, scope_ref}}

            evidence.provenance == :observed and evidence.source_ref != opening.ingress_ref ->
              {:error, {:evidence_scope_ingress_source_mismatch, evidence.ref, scope_ref}}

            true ->
              :ok
          end

        :error ->
          {:error, {:evidence_scope_not_open, evidence.ref, scope_ref}}
      end
    end
  end

  defp validate_prepared_presentation(projection, presentation) do
    case Map.fetch(projection.scopes, presentation.scope_ref) do
      {:ok, opening} when presentation.prepared_at >= opening.opened_at ->
        with :ok <-
               ErasureAnalysis.validate_evidence_available(
                 projection,
                 presentation.disclosure.source_evidence_refs
               ) do
          Disclosure.verify_sources(presentation.disclosure, projection.evidence)
        end

      {:ok, _opening} ->
        {:error, {:presentation_precedes_scope, presentation.ref}}

      :error ->
        {:error, {:presentation_scope_not_open, presentation.ref, presentation.scope_ref}}
    end
  end

  defp validate_presentation_approval_evidence(projection, evidence) do
    case Presentation.approval_refs(evidence) do
      :not_approval ->
        :ok

      {:error, reason} ->
        {:error, {:invalid_presentation_approval_evidence, evidence.ref, reason}}

      {:ok, presentation_ref, show_act_ref} ->
        with {:ok, presentation} <- Map.fetch(projection.presentations, presentation_ref),
             {:ok, show_act} <- Map.fetch(projection.acts, show_act_ref),
             {:ok, _basis_refs} <-
               Presentation.validate_response_with_basis(
                 evidence,
                 presentation,
                 show_act,
                 Map.values(projection.outcomes),
                 [
                   evidence
                   | projection
                     |> ErasureAnalysis.available_evidence()
                     |> Map.values()
                 ],
                 evidence.observed_at
               ) do
          :ok
        else
          :error ->
            {:error,
             {:presentation_approval_cause_not_found, evidence.ref, presentation_ref,
              show_act_ref}}

          {:error, reason} ->
            {:error, {:invalid_presentation_approval_evidence, evidence.ref, reason}}
        end
    end
  end

  defp validate_duty_cause_evidence(projection, evidence) do
    case EvidenceCause.extract(evidence, projection.constitution) do
      :not_cause ->
        :ok

      {:ok, cause} ->
        with true <- Map.has_key?(projection.principals, cause.accountable_ref),
             :ok <- optional_mandate_exists(projection, cause.mandate_ref),
             :ok <-
               ErasureAnalysis.validate_evidence_available(
                 projection,
                 cause.related_evidence_refs
               ),
             :ok <- evidence_exists(projection, cause.related_evidence_refs) do
          :ok
        else
          false ->
            {:error, {:duty_evidence_accountable_not_found, evidence.ref, cause.accountable_ref}}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp optional_mandate_exists(_projection, nil), do: :ok

  defp optional_mandate_exists(projection, mandate_ref) do
    if Map.has_key?(projection.mandates, mandate_ref),
      do: :ok,
      else: {:error, {:duty_evidence_mandate_not_found, mandate_ref}}
  end

  defp validate_evidence_lineage(_projection, %Evidence{provenance: :observed, parent_refs: []}),
    do: :ok

  defp validate_evidence_lineage(projection, %Evidence{} = evidence)
       when evidence.provenance in [:derived, :generated] do
    with :ok <- ErasureAnalysis.validate_evidence_available(projection, evidence.parent_refs),
         {:ok, parents} <- evidence_set(projection, evidence.parent_refs),
         :ok <- parents_not_after_evidence(parents, evidence) do
      case Map.fetch(projection.declassifications_by_evidence, evidence.ref) do
        {:ok, declassification_ref} ->
          with {:ok, record} <- Map.fetch(projection.declassifications, declassification_ref) do
            Declassification.validate_transition(record, evidence, parents)
          else
            :error -> {:error, {:declassification_not_found, declassification_ref}}
          end

        :error ->
          Derivation.validate(evidence, parents)
      end
    else
      {:error, {:evidence_not_found, ref}} ->
        {:error, {:evidence_parent_not_found, evidence.ref, ref}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_evidence_lineage(_projection, %Evidence{} = evidence),
    do: {:error, {:invalid_evidence_lineage, evidence.ref, evidence.provenance}}

  defp parents_not_after_evidence(parents, evidence) do
    case Enum.find(parents, &(&1.observed_at > evidence.observed_at)) do
      nil -> :ok
      parent -> {:error, {:evidence_parent_from_future, evidence.ref, parent.ref}}
    end
  end

  defp validate_outcome_evidence(projection, outcome, attempt, act) do
    with :ok <- ErasureAnalysis.validate_evidence_available(projection, outcome.evidence_refs),
         :ok <- evidence_exists(projection, outcome.evidence_refs) do
      Enum.reduce_while(outcome.evidence_refs, :ok, fn ref, :ok ->
        evidence = Map.fetch!(projection.evidence, ref)
        result = Attestation.validate(evidence, outcome, attempt, act)

        case result do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp unique_duty(projection, duty) do
    cond do
      Map.has_key?(projection.duties, duty.cause_key) ->
        {:error, {:duplicate_duty_cause, duty.cause_key}}

      Map.has_key?(projection.duty_refs, duty.ref) ->
        {:error, {:duplicate_domain_record, :duty, duty.ref}}

      true ->
        :ok
    end
  end

  defp new_duty_open(%Spectre.Duty{status: :open, disposition_act_ref: nil}), do: :ok

  defp new_duty_open(%Spectre.Duty{ref: ref}),
    do: {:error, {:duty_opened_in_terminal_state, ref}}

  defp match_duty_references(projection, duty) do
    with :ok <- optional_act_exists(projection, duty.act_ref),
         :ok <- optional_attempt_matches(projection, duty.attempt_ref, duty.act_ref),
         :ok <- evidence_exists(projection, duty.evidence_refs),
         :ok <- match_duty_act(projection, duty),
         :ok <- duty_required_at_prefix(projection, duty) do
      validate_builtin_duty_cause(projection, duty)
    end
  end

  defp duty_required_at_prefix(projection, duty) do
    cause =
      projection
      |> Derive.required_duties(projection.constitution, duty.opened_at)
      |> Enum.find(&(&1.cause_key == duty.cause_key))

    case cause do
      nil ->
        {:error, {:duty_cause_not_required_at_prefix, duty.ref}}

      cause ->
        with {:ok, expected} <-
               cause
               |> Derive.materialization_attrs(duty.opened_at)
               |> Duty.new(),
             true <- expected == duty do
          :ok
        else
          false -> {:error, {:duty_cause_materialization_mismatch, duty.ref}}
          {:error, reason} -> {:error, {:invalid_required_duty, duty.cause_key, reason}}
        end
    end
  end

  defp match_duty_act(_projection, %{act_ref: nil}), do: :ok

  defp match_duty_act(projection, duty) do
    with {:ok, act} <- fetch_act(projection, duty.act_ref) do
      cond do
        duty.mandate_ref != act.mandate_ref ->
          {:error, {:duty_mandate_mismatch, duty.ref, act.ref}}

        duty.subjects != act.subject_refs ->
          {:error, {:duty_subjects_mismatch, duty.ref, act.ref}}

        duty.accountable != act.accountable_ref ->
          {:error, {:duty_accountable_mismatch, duty.ref, act.ref}}

        not duty_conflicts_include_cause_roles?(duty, act) ->
          {:error, {:duty_conflict_refs_mismatch, duty.ref, act.ref}}

        true ->
          :ok
      end
    end
  end

  defp validate_builtin_duty_cause(
         projection,
         %{
           class: :ambiguous_outcome,
           cause_key: {:ambiguous_outcome, act_ref, attempt_ref}
         } = duty
       ) do
    deadline_reached? =
      case {Map.fetch(projection.attempts, attempt_ref), Map.fetch(projection.acts, act_ref)} do
        {{:ok, attempt}, {:ok, act}} ->
          duty.opened_at >= attempt.started_at + act.observation_window_ms

        _missing ->
          false
      end

    ambiguous_outcome? =
      Enum.any?(projection.outcomes, fn {_ref, outcome} ->
        outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref and
          outcome.status == :ambiguous and outcome.observed_at <= duty.opened_at
      end)

    safe_containment? =
      case Map.fetch(projection.acts, act_ref) do
        {:ok, act} -> valid_builtin_duty_containment?(duty, act)
        :error -> false
      end

    if duty.act_ref == act_ref and duty.attempt_ref == attempt_ref and
         (deadline_reached? or ambiguous_outcome?) and safe_containment?,
       do: :ok,
       else: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}
  end

  defp validate_builtin_duty_cause(
         projection,
         %{
           class: :contradicted_outcome,
           cause_key: {:contradicted_outcome, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, outcome} <- Map.fetch(projection.outcomes, outcome_ref),
         {:ok, act} <- Map.fetch(projection.acts, act_ref),
         true <- outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref,
         true <- Outcome.correction?(outcome) and outcome.observed_at <= duty.opened_at,
         {:ok, corrected} <- Map.fetch(projection.outcomes, outcome.contradicts_outcome_ref),
         true <- corrected.status == :definitive_no_effect,
         true <- duty.act_ref == act_ref and duty.attempt_ref == attempt_ref,
         true <- valid_builtin_duty_containment?(duty, act) do
      :ok
    else
      _missing_or_mismatch -> {:error, {:invalid_contradicted_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_duty_cause(_projection, %{class: :ambiguous_outcome} = duty),
    do: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(_projection, %{class: :contradicted_outcome} = duty),
    do: {:error, {:invalid_contradicted_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(
         projection,
         %{class: :disputed_evidence} = duty
       ) do
    cause =
      projection
      |> Derive.required_duties(%{}, duty.opened_at)
      |> Enum.find(&(&1.cause_key == duty.cause_key))

    expected = if cause, do: Derive.materialization_attrs(cause, duty.opened_at)
    act = if expected, do: Map.get(projection.acts, expected.act_ref)

    valid? =
      is_map(expected) and not is_nil(act) and duty.act_ref == expected.act_ref and
        duty.attempt_ref == expected.attempt_ref and duty.mandate_ref == expected.mandate_ref and
        duty.subjects == expected.subjects and duty.accountable == expected.accountable and
        duty.evidence_refs == expected.evidence_refs and duty.missing == expected.missing and
        duty.opened_at == expected.opened_at and valid_builtin_duty_containment?(duty, act)

    if valid?,
      do: :ok,
      else: {:error, {:invalid_disputed_evidence_duty_cause, duty.ref}}
  end

  defp validate_builtin_duty_cause(
         projection,
         %{
           class: :scope_promise_overdue,
           cause_key: {:scope_promise_overdue, scope_ref}
         } = duty
       ) do
    case Map.fetch(projection.scopes, scope_ref) do
      {:ok, %Opening{} = opening} ->
        condition = opening.promise_condition
        source_act = Map.get(projection.acts, opening.source_act_ref)
        timely_evidence = Derive.available_evidence_at(projection, opening.due_at)

        valid? =
          opening.kind in [:work, :vigil] and duty.act_ref == opening.source_act_ref and
            duty.attempt_ref == nil and not is_nil(source_act) and
            duty.mandate_ref == source_act.mandate_ref and
            duty.subjects == source_act.subject_refs and
            duty.accountable == opening.accountable_ref and
            duty.disposition_authority_refs == opening.disposition_authority_refs and
            duty_conflicts_include_cause_roles?(duty, source_act) and
            duty.closing_conditions == [Condition.canonical(condition)] and
            duty.opened_at >= opening.due_at and
            Recognition.check([condition], timely_evidence, opening.due_at) != :satisfied

        if valid?,
          do: :ok,
          else: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

      :error ->
        {:error, {:scope_promise_duty_scope_not_found, duty.ref, scope_ref}}
    end
  end

  defp validate_builtin_duty_cause(
         projection,
         %{
           class: :erasure_reduces_verifiability,
           cause_key:
             {:erasure_reduces_verifiability, erasure_ref, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, erasure} <- Map.fetch(projection.erasures, erasure_ref),
         {:ok, act} <- Map.fetch(projection.acts, act_ref),
         {:ok, attempt} <- Map.fetch(projection.attempts, attempt_ref),
         {:ok, outcome} <- Map.fetch(projection.outcomes, outcome_ref),
         true <- erasure.reduces_verifiability,
         true <- erasure.source_act_ref == act.ref,
         true <- attempt.act_ref == act.ref,
         true <- outcome.act_ref == act.ref and outcome.attempt_ref == attempt.ref,
         true <- outcome.status == :succeeded,
         true <- duty.act_ref == act.ref and duty.attempt_ref == attempt.ref,
         true <- duty.mandate_ref == act.mandate_ref,
         true <- duty.subjects == act.subject_refs,
         true <- duty.accountable == act.accountable_ref,
         true <- duty.evidence_refs == outcome.evidence_refs,
         true <- duty.opened_at >= outcome.observed_at do
      :ok
    else
      _missing_or_mismatch -> {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_duty_cause(_projection, %{class: :scope_promise_overdue} = duty),
    do: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(
         _projection,
         %{class: :erasure_reduces_verifiability} = duty
       ),
       do: {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(_projection, %{class: class})
       when is_binary(class),
       do: :ok

  defp duty_conflicts_include_cause_roles?(duty, act) when is_map(act) do
    duty.accountable
    |> Derive.conflict_refs([], act)
    |> Enum.all?(&(&1 in duty.conflict_refs))
  end

  defp valid_builtin_duty_containment?(duty, act) do
    case duty.containment do
      %{
        "consequence_digest" => consequence_digest,
        "meter_reservations" => reservations,
        "dispatch" => :blocked,
        "retry" => :forbidden
      } ->
        reservations == act.reservations and
          Spectre.Candidate.effect_digest(act) == {:ok, consequence_digest}

      _invalid ->
        false
    end
  end

  defp validate_duty_disposition(projection, act, duty, disposition) do
    with :ok <- validate_disposition_act(act, duty),
         :ok <- validate_disposition_binding(duty, disposition),
         {:ok, supporting} <- disposition_support(projection, disposition, act),
         :ok <- validate_disposition_authority(projection, act, duty, disposition),
         :ok <- validate_disposition_basis(projection, act, duty, disposition, supporting) do
      {:ok, supporting}
    end
  end

  defp validate_disposition_authority(_projection, _act, _duty, %{kind: :condition_met}),
    do: :ok

  defp validate_disposition_authority(projection, act, duty, disposition) do
    if Disposition.discretionary?(disposition) do
      DutyAuthority.validate(
        duty,
        act,
        duty_cause_act(projection, duty),
        projection.principals,
        projection.mandates
      )
    else
      :ok
    end
  end

  defp duty_cause_act(projection, %{act_ref: act_ref}) when is_binary(act_ref),
    do: Map.get(projection.acts, act_ref)

  defp duty_cause_act(
         projection,
         %{class: :scope_promise_overdue, cause_key: {:scope_promise_overdue, scope_ref}}
       ) do
    case Map.get(projection.scopes, scope_ref) do
      %Opening{source_act_ref: act_ref} -> Map.get(projection.acts, act_ref)
      _missing -> nil
    end
  end

  defp duty_cause_act(_projection, _duty), do: nil

  defp validate_disposition_act(act, duty) do
    cond do
      act.class != "duty.dispose" ->
        {:error, {:duty_disposition_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:duty_disposition_act_row_mismatch, act.ref}}

      act.reservations not in [%{}, []] ->
        {:error, {:duty_disposition_act_has_reservations, act.ref}}

      not act_targets?(act, [duty.ref]) ->
        {:error, {:duty_disposition_target_missing, act.ref, duty.ref}}

      act.ref == duty.act_ref ->
        {:error, {:duty_cause_act_cannot_dispose, duty.ref, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_disposition_binding(duty, disposition) do
    cond do
      disposition.duty_ref != duty.ref ->
        {:error, {:duty_disposition_ref_mismatch, duty.ref, disposition.duty_ref}}

      disposition.cause_key != duty.cause_key ->
        {:error, {:duty_disposition_cause_mismatch, duty.ref}}

      disposition.opening_digest != Spectre.Duty.digest(duty) ->
        {:error, {:duty_disposition_opening_mismatch, duty.ref}}

      true ->
        :ok
    end
  end

  defp disposition_support(projection, disposition, act) do
    Enum.reduce_while(disposition.supporting_refs, {:ok, []}, fn ref, {:ok, records} ->
      case supporting_record(projection, ref) do
        {:ok, record} ->
          with :ok <- support_frozen_and_available(projection, act, ref, record),
               true <- support_available_at?(record, act.committed_at) do
            {:cont, {:ok, [record | records]}}
          else
            false -> {:halt, {:error, {:duty_disposition_support_from_future, ref}}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp support_frozen_and_available(projection, act, ref, {:evidence, _evidence}) do
    if ref in act.evidence_refs,
      do: ErasureAnalysis.validate_evidence_available(projection, [ref]),
      else: {:error, {:duty_disposition_evidence_not_frozen, act.ref, ref}}
  end

  defp support_frozen_and_available(_projection, _act, _ref, {_kind, _record}), do: :ok

  defp supporting_record(projection, ref) do
    matches =
      [
        {:evidence, Map.get(projection.evidence, ref)},
        {:outcome, Map.get(projection.outcomes, ref)},
        {:act, Map.get(projection.acts, ref)}
      ]
      |> Enum.reject(fn {_kind, record} -> is_nil(record) end)

    case matches do
      [record] -> {:ok, record}
      [] -> {:error, {:duty_disposition_support_not_found, ref}}
      _collision -> {:error, {:duty_disposition_support_ambiguous, ref}}
    end
  end

  defp support_available_at?({:evidence, evidence}, committed_at),
    do: evidence.observed_at <= committed_at

  defp support_available_at?({:outcome, outcome}, committed_at),
    do: outcome.observed_at <= committed_at

  defp support_available_at?({:act, act}, committed_at),
    do: act.committed_at <= committed_at

  defp validate_disposition_basis(
         projection,
         act,
         duty,
         %{kind: :condition_met},
         supporting
       ) do
    if Enum.any?(
         duty.closing_conditions,
         &closing_condition_met?(projection, &1, supporting, act.committed_at)
       ) do
      :ok
    else
      {:error, {:duty_closing_condition_not_met, duty.ref}}
    end
  end

  defp validate_disposition_basis(_projection, act, duty, disposition, _supporting) do
    if Disposition.discretionary?(disposition),
      do: :ok,
      else: {:error, {:invalid_duty_disposition_kind, disposition.kind, act.ref, duty.ref}}
  end

  defp closing_condition_met?(
         projection,
         %{"kind" => :definitive_outcome, "attempt_ref" => attempt_ref} = condition,
         supporting,
         committed_at
       )
       when map_size(condition) == 2 do
    Enum.any?(supporting, fn
      {:outcome, outcome} ->
        outcome.attempt_ref == attempt_ref and
          outcome.status in [:succeeded, :failed, :definitive_no_effect] and
          outcome.observed_at <= committed_at and
          outcome_not_corrected_at?(projection, outcome, committed_at)

      _other ->
        false
    end)
  end

  defp closing_condition_met?(projection, condition, supporting, committed_at) do
    available_evidence = projection |> ErasureAnalysis.available_evidence() |> Map.values()
    supporting_refs = for {:evidence, item} <- supporting, do: item.ref

    with {:ok, condition} <- Condition.new(condition),
         {:satisfied, basis_refs} <-
           Recognition.check_with_basis([condition], available_evidence, committed_at) do
      basis_refs -- supporting_refs == []
    else
      _not_satisfied_or_invalid -> false
    end
  end

  defp resolve_duty_meter(projection, data) do
    disposition_act_ref = field(data, :disposition_act_ref)
    duty_ref = field(data, :duty_ref)
    cause_act_ref = field(data, :act_ref)
    mandate_ref = field(data, :mandate_ref)
    operation = field(data, :operation)

    with true <- operation in [:settle, :release],
         {:ok, amounts} <- normalize_reservation_amounts(field(data, :amounts)),
         :ok <- duty_meter_resolution_absent(projection, disposition_act_ref),
         {:ok, duty} <- fetch_duty_by_ref(projection, duty_ref),
         :ok <- duty_open(duty),
         true <- duty.act_ref == cause_act_ref,
         {:ok, disposition_act} <- fetch_act(projection, disposition_act_ref),
         {:ok, disposition} <- Disposition.from_consequence(disposition_act.consequence),
         {:ok, supporting} <-
           validate_duty_disposition(projection, disposition_act, duty, disposition),
         true <- disposition.meter_resolution == operation,
         {:ok, cause_act} <- fetch_act(projection, cause_act_ref),
         true <- cause_act.mandate_ref == mandate_ref,
         true <- cause_act.reservations not in [%{}, []],
         {:ok, :suspended, binding} <- fetch_reservation(projection, cause_act.ref),
         :ok <- match_duty_meter_binding(binding, cause_act, mandate_ref),
         {:ok, expected_amounts, recontainment} <-
           expected_duty_meter_amounts(projection, cause_act, duty),
         true <- amounts == expected_amounts,
         :ok <-
           validate_duty_meter_resolution(
             projection,
             operation,
             supporting,
             cause_act,
             duty,
             disposition_act.committed_at
           ),
         {:ok, accounts} <- fetch_meter_accounts(projection, mandate_ref),
         {:ok, accounts} <- transition_accounts(accounts, amounts, operation, :suspended),
         {:ok, projection} <- put_meter_accounts(projection, mandate_ref, accounts) do
      resolution = %{
        act_ref: cause_act.ref,
        disposition_act_ref: disposition_act.ref,
        duty_ref: duty.ref,
        mandate_ref: mandate_ref,
        operation: operation,
        amounts: amounts
      }

      projection =
        projection
        |> put_duty_meter_resolution(resolution)
        |> put_resolved_recontainment(recontainment, disposition_act.ref)

      {:ok,
       %{
         projection
         | reservation_states:
             Map.put(
               projection.reservation_states,
               cause_act.ref,
               resolved_reservation_status(operation)
             )
       }}
    else
      false ->
        {:error, {:invalid_duty_meter_resolution_event, disposition_act_ref}}

      {:ok, status, _binding} ->
        {:error, {:duty_meter_resolution_requires_suspension, cause_act_ref, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp duty_meter_resolution_absent(projection, disposition_act_ref) do
    if Map.has_key?(projection.duty_meter_resolutions, disposition_act_ref),
      do: {:error, {:duplicate_duty_meter_resolution, disposition_act_ref}},
      else: :ok
  end

  defp match_duty_meter_binding(binding, cause_act, mandate_ref) do
    with true <- binding.act_ref == cause_act.ref,
         true <- binding.mandate_ref == mandate_ref,
         {:ok, declared} <- normalize_reservation_amounts(cause_act.reservations),
         true <- binding.amounts == declared do
      :ok
    else
      false -> {:error, {:duty_meter_reservation_binding_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp expected_duty_meter_amounts(projection, cause_act, duty) do
    case Map.get(projection.meter_recontainments, cause_act.ref) do
      nil ->
        with {:ok, binding} <- Map.fetch(projection.reservation_bindings, cause_act.ref) do
          {:ok, binding.amounts, nil}
        else
          :error -> {:error, {:reservation_binding_not_found, cause_act.ref}}
        end

      %{status: :open, cause_key: cause_key, mandate_ref: mandate_ref} = record ->
        cond do
          cause_key != duty.cause_key ->
            {:error, {:meter_recontainment_requires_causal_duty, cause_act.ref, cause_key}}

          mandate_ref != cause_act.mandate_ref ->
            {:error, {:meter_recontainment_mandate_mismatch, cause_act.ref}}

          true ->
            {:ok, record.recontained, record}
        end

      %{status: status} ->
        {:error, {:invalid_meter_recontainment_state, cause_act.ref, status}}

      _invalid ->
        {:error, {:invalid_meter_recontainment, cause_act.ref}}
    end
  end

  defp put_duty_meter_resolution(projection, resolution) do
    %{
      projection
      | duty_meter_resolutions:
          Map.put(
            projection.duty_meter_resolutions,
            resolution.disposition_act_ref,
            resolution
          )
    }
  end

  defp put_resolved_recontainment(projection, nil, _disposition_act_ref), do: projection

  defp put_resolved_recontainment(projection, record, disposition_act_ref) do
    updated = %{record | status: :disposed, disposition_act_ref: disposition_act_ref}

    %{
      projection
      | meter_recontainments: Map.put(projection.meter_recontainments, record.act_ref, updated)
    }
  end

  defp validate_duty_meter_disposed(projection, %{act_ref: nil} = duty, disposition, act_ref) do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(projection.duty_meter_resolutions, act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, act_ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed(projection, duty, disposition, disposition_act_ref) do
    with {:ok, cause_act} <- fetch_act(projection, duty.act_ref) do
      validate_duty_meter_disposed_for_act(
        projection,
        duty,
        cause_act,
        disposition,
        disposition_act_ref
      )
    end
  end

  defp validate_duty_meter_disposed_for_act(
         projection,
         duty,
         %{reservations: reservations} = cause_act,
         disposition,
         disposition_act_ref
       )
       when reservations in [%{}, []] do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(projection.reservation_states, cause_act.ref) ->
        {:error, {:unexpected_duty_reservation_state, cause_act.ref}}

      Map.has_key?(projection.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed_for_act(
         projection,
         duty,
         cause_act,
         %{meter_resolution: :none},
         disposition_act_ref
       ) do
    recontainment = Map.get(projection.meter_recontainments, cause_act.ref)

    cond do
      Map.has_key?(projection.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      Map.get(projection.reservation_states, cause_act.ref) == :suspended and
        match?(%{status: :open}, recontainment) and
          recontainment.cause_key != duty.cause_key ->
        :ok

      Map.get(projection.reservation_states, cause_act.ref) not in [:settled, :released] ->
        {:error, {:duty_meter_not_resolved, cause_act.ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed_for_act(
         projection,
         duty,
         cause_act,
         disposition,
         disposition_act_ref
       ) do
    expected_status = resolved_reservation_status(disposition.meter_resolution)

    with {:ok, resolution} <-
           Map.fetch(projection.duty_meter_resolutions, disposition_act_ref),
         true <- resolution.act_ref == cause_act.ref,
         true <- resolution.duty_ref == duty.ref,
         true <- resolution.mandate_ref == cause_act.mandate_ref,
         true <- resolution.operation == disposition.meter_resolution,
         true <- Map.get(projection.reservation_states, cause_act.ref) == expected_status,
         :ok <-
           validate_resolved_recontainment(
             projection,
             cause_act.ref,
             duty.cause_key,
             disposition_act_ref
           ) do
      :ok
    else
      :error -> {:error, {:duty_meter_resolution_missing, disposition_act_ref}}
      false -> {:error, {:duty_meter_resolution_binding_mismatch, disposition_act_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_resolved_recontainment(projection, cause_act_ref, cause_key, disposition_act_ref) do
    case Map.get(projection.meter_recontainments, cause_act_ref) do
      nil ->
        :ok

      %{status: :disposed, cause_key: ^cause_key, disposition_act_ref: ^disposition_act_ref} ->
        :ok

      _invalid ->
        {:error, {:meter_recontainment_not_resolved, cause_act_ref}}
    end
  end

  defp resolved_reservation_status(:settle), do: :settled
  defp resolved_reservation_status(:release), do: :released

  defp validate_duty_meter_resolution(
         _projection,
         :settle,
         _supporting,
         _cause_act,
         _duty,
         _committed_at
       ),
       do: :ok

  defp validate_duty_meter_resolution(
         projection,
         :release,
         supporting,
         cause_act,
         duty,
         committed_at
       ) do
    if Enum.any?(supporting, fn
         {:outcome, %{status: :definitive_no_effect} = outcome} ->
           outcome.act_ref == cause_act.ref and
             (is_nil(duty.attempt_ref) or outcome.attempt_ref == duty.attempt_ref) and
             outcome_not_corrected_at?(projection, outcome, committed_at)

         _other ->
           false
       end) do
      :ok
    else
      {:error, :duty_meter_release_not_proven}
    end
  end

  defp outcome_not_corrected_at?(projection, outcome, committed_at) do
    not Enum.any?(projection.outcomes, fn {_ref, candidate} ->
      candidate.contradicts_outcome_ref == outcome.ref and
        candidate.observed_at <= committed_at
    end)
  end

  defp optional_act_exists(_projection, nil), do: :ok

  defp optional_act_exists(projection, act_ref) do
    with {:ok, _act} <- fetch_act(projection, act_ref), do: :ok
  end

  defp optional_attempt_matches(_projection, nil, _act_ref), do: :ok

  defp optional_attempt_matches(projection, attempt_ref, act_ref) do
    with {:ok, attempt} <- fetch_attempt(projection, attempt_ref) do
      if attempt.act_ref == act_ref,
        do: :ok,
        else: {:error, {:duty_attempt_act_mismatch, attempt_ref, act_ref}}
    end
  end

  defp fetch_duty_by_cause(projection, cause_key) when not is_nil(cause_key) do
    case Map.fetch(projection.duties, cause_key) do
      {:ok, duty} -> {:ok, duty}
      :error -> {:error, {:duty_not_found, cause_key}}
    end
  end

  defp fetch_duty_by_cause(_projection, cause_key),
    do: {:error, {:invalid_duty_cause_key, cause_key}}

  defp fetch_duty_by_ref(projection, duty_ref) when is_binary(duty_ref) and duty_ref != "" do
    with {:ok, cause_key} <- Map.fetch(projection.duty_refs, duty_ref),
         {:ok, duty} <- Map.fetch(projection.duties, cause_key) do
      {:ok, duty}
    else
      :error -> {:error, {:duty_not_found, duty_ref}}
    end
  end

  defp fetch_duty_by_ref(_projection, duty_ref),
    do: {:error, {:invalid_duty_ref, duty_ref}}

  defp duty_open(%Spectre.Duty{status: :open}), do: :ok
  defp duty_open(%Spectre.Duty{cause_key: cause_key}), do: {:error, {:duty_disposed, cause_key}}

  defp put_decoded(projection, field_name, module, identity, data) do
    collection = Map.fetch!(projection, field_name)

    with {:ok, record} <- decode(module, data),
         :ok <- exact_identity(identity, record_ref(record)),
         :ok <- unique(collection, identity, field_name) do
      {:ok, Map.put(projection, field_name, Map.put(collection, identity, record))}
    end
  end

  defp decode(module, data) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :from_canonical, 1) do
      module.from_canonical(data)
    else
      _unavailable -> {:error, {:record_decoder_unavailable, module}}
    end
  end

  defp record_ref(record), do: Map.get(record, :ref) || Map.get(record, "ref")

  defp exact_identity(identity, identity) when is_binary(identity), do: :ok
  defp exact_identity(_identity, _record_ref), do: {:error, :domain_event_identity_mismatch}

  defp unique(collection, identity, kind) do
    if Map.has_key?(collection, identity),
      do: {:error, {:duplicate_domain_record, kind, identity}},
      else: :ok
  end

  defp initialize_meters(all_meters, mandate) do
    mandate_ref = record_ref(mandate)
    allocations = Map.get(mandate, :meters, %{})

    accounts =
      Map.new(allocations, fn {meter_ref, ceiling} ->
        {meter_ref,
         %{
           ceiling: ceiling,
           available: ceiling,
           reserved: 0,
           suspended: 0,
           spent: 0,
           delegated: 0
         }}
      end)

    Map.put(all_meters, mandate_ref, accounts)
  end

  defp reserve_meters(projection, data) do
    with {:ok, context} <- reservation_context(projection, data),
         :ok <- reservation_absent(projection, context.act_ref),
         {:ok, accounts} <- fetch_meter_accounts(projection, context.mandate_ref),
         {:ok, accounts} <-
           transition_accounts(accounts, context.amounts, :reserve, :unreserved),
         {:ok, projection} <- put_meter_accounts(projection, context.mandate_ref, accounts) do
      {:ok,
       %{
         projection
         | reservation_states: Map.put(projection.reservation_states, context.act_ref, :reserved),
           reservation_bindings:
             Map.put(projection.reservation_bindings, context.act_ref, context)
       }}
    end
  end

  defp devolve_meters(projection, data) do
    act_ref = field(data, :act_ref)
    child_ref = field(data, :child_mandate_ref)

    with {:ok, act} <- fetch_act(projection, act_ref),
         :ok <- devolution_not_applied(projection, act_ref),
         {:ok, child} <- fetch_mandate(projection, child_ref),
         :ok <- child_mandate(child),
         {:ok, parent} <- fetch_mandate(projection, child.parent_ref),
         {:ok, true} <- mandate_terminal?(projection, child, act.committed_at),
         {:ok, amounts} <- normalize_devolution_amounts(field(data, :amounts)),
         :ok <- validate_devolution_act(act, child, amounts),
         {:ok, parent_owner_ref} <- fetch_meter_owner(projection, parent.ref),
         {:ok, child_owner_ref} <- fetch_meter_owner(projection, child.ref),
         true <- parent_owner_ref != child_owner_ref,
         {:ok, parent_accounts} <- fetch_meter_accounts(projection, parent.ref),
         {:ok, child_accounts} <- fetch_meter_accounts(projection, child.ref),
         :ok <- exact_available_devolution(child.ref, child_accounts, amounts),
         {:ok, parent_accounts, child_accounts} <-
           apply_devolution(parent_accounts, child_accounts, amounts) do
      meters =
        projection.meters
        |> Map.put(parent_owner_ref, parent_accounts)
        |> Map.put(child_owner_ref, child_accounts)

      {:ok,
       %{
         projection
         | meters: meters,
           meter_devolutions: MapSet.put(projection.meter_devolutions, act_ref)
       }}
    else
      false -> {:error, {:meter_devolution_owner_collision, child_ref}}
      {:ok, false} -> {:error, {:mandate_not_terminal_for_devolution, child_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp devolution_not_applied(projection, act_ref) do
    if MapSet.member?(projection.meter_devolutions, act_ref),
      do: {:error, {:meter_devolution_already_applied, act_ref}},
      else: :ok
  end

  defp child_mandate(%Mandate{parent_ref: parent_ref})
       when is_binary(parent_ref) and parent_ref != "",
       do: :ok

  defp child_mandate(%Mandate{ref: ref}), do: {:error, {:root_mandate_cannot_devolve, ref}}

  defp validate_devolution_act(act, child, amounts) do
    consequence = %{
      "mandate_devolve" => %{
        "child_mandate_ref" => child.ref,
        "amounts" => amounts
      }
    }

    cond do
      act.class != "mandate.devolve" ->
        {:error, {:meter_devolution_act_class_mismatch, act.ref, act.class}}

      not exact_row?(act.row, [:delegate, :govern]) ->
        {:error, {:meter_devolution_act_row_mismatch, act.ref}}

      act.reservations not in [%{}, []] ->
        {:error, {:meter_devolution_act_has_reservations, act.ref}}

      not act_targets?(act, [child.ref]) ->
        {:error, {:meter_devolution_target_missing, act.ref, child.ref}}

      act.consequence != consequence ->
        {:error, {:meter_devolution_consequence_mismatch, act.ref, child.ref}}

      true ->
        :ok
    end
  end

  defp exact_available_devolution(child_ref, accounts, amounts) do
    available =
      accounts
      |> Enum.flat_map(fn {meter_ref, account} ->
        case field(account, :available) do
          quantity when is_integer(quantity) and quantity > 0 -> [{meter_ref, quantity}]
          _zero_or_invalid -> []
        end
      end)
      |> Map.new()

    cond do
      map_size(available) == 0 ->
        {:error, {:meter_devolution_has_no_available_quantity, child_ref}}

      available != amounts ->
        {:error, {:meter_devolution_not_exact_available, child_ref}}

      true ->
        :ok
    end
  end

  defp apply_devolution(parent_accounts, child_accounts, amounts) do
    amounts
    |> Enum.sort_by(fn {meter_ref, _quantity} -> meter_ref end)
    |> Enum.reduce_while({:ok, parent_accounts, child_accounts}, fn
      {meter_ref, quantity}, {:ok, parents, children} ->
        with {:ok, parent_account} <- fetch_meter_account(parents, meter_ref),
             {:ok, child_account} <- fetch_meter_account(children, meter_ref),
             {:ok, parent_account, child_account} <-
               Meter.devolve(parent_account, child_account, quantity) do
          {:cont,
           {:ok, Map.put(parents, meter_ref, parent_account),
            Map.put(children, meter_ref, child_account)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp mandate_terminal?(projection, mandate, time) when is_integer(time) do
    cond do
      time >= mandate.expires_at ->
        {:ok, true}

      true ->
        Ancestry.revoked?(projection.mandates, projection.revocations, mandate, time)
    end
  end

  defp mandate_terminal?(_projection, _mandate, _time), do: {:error, :invalid_devolution_time}

  defp recontain_released_reservation(projection, data) do
    outcome_ref = field(data, :outcome_ref)

    with {:ok, context} <- reservation_context(projection, data),
         {:ok, status, binding} <- fetch_reservation(projection, context.act_ref),
         :ok <- released_reservation(status, context.act_ref),
         :ok <- match_reservation(binding, context),
         {:ok, %Outcome{} = outcome} <- Map.fetch(projection.outcomes, outcome_ref),
         :ok <- validate_recontainment_cause(projection, context, outcome),
         :ok <- recontainment_absent(projection, context.act_ref),
         {:ok, recontained} <- normalize_reservation_amounts(field(data, :recontained)),
         {:ok, deficits} <- normalize_reservation_amounts(field(data, :deficits)),
         :ok <- validate_recontainment_partition(context.amounts, recontained, deficits),
         {:ok, accounts} <- fetch_meter_accounts(projection, context.mandate_ref),
         {:ok, accounts, expected_recontained, expected_deficits} <-
           Meter.recontain_many(context.amounts, accounts),
         :ok <-
           exact_recontainment_result(
             context.act_ref,
             recontained,
             deficits,
             expected_recontained,
             expected_deficits
           ),
         {:ok, projection} <- put_meter_accounts(projection, context.mandate_ref, accounts) do
      record = %{
        act_ref: context.act_ref,
        mandate_ref: context.mandate_ref,
        outcome_ref: outcome.ref,
        cause_key: {:contradicted_outcome, context.act_ref, outcome.attempt_ref, outcome.ref},
        amounts: context.amounts,
        recontained: recontained,
        deficits: deficits,
        status: :open,
        disposition_act_ref: nil
      }

      {:ok,
       %{
         projection
         | reservation_states:
             Map.put(projection.reservation_states, context.act_ref, :suspended),
           meter_recontainments: Map.put(projection.meter_recontainments, context.act_ref, record)
       }}
    else
      :error -> {:error, {:recontainment_outcome_not_found, outcome_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp released_reservation(:released, _act_ref), do: :ok

  defp released_reservation(status, act_ref),
    do: {:error, {:meter_recontainment_requires_released_reservation, act_ref, status}}

  defp validate_recontainment_cause(projection, context, outcome) do
    corrected = Map.get(projection.outcomes, outcome.contradicts_outcome_ref)

    cond do
      not Outcome.correction?(outcome) ->
        {:error, {:meter_recontainment_outcome_not_correction, outcome.ref}}

      outcome.act_ref != context.act_ref ->
        {:error, {:meter_recontainment_act_mismatch, outcome.ref, context.act_ref}}

      not match?(%Outcome{status: :definitive_no_effect}, corrected) ->
        {:error, {:meter_recontainment_without_definitive_no_effect, outcome.ref}}

      true ->
        :ok
    end
  end

  defp recontainment_absent(projection, act_ref) do
    if Map.has_key?(projection.meter_recontainments, act_ref),
      do: {:error, {:meter_recontainment_already_recorded, act_ref}},
      else: :ok
  end

  defp validate_recontainment_partition(amounts, recontained, deficits) do
    valid? =
      Enum.all?(Map.keys(recontained) ++ Map.keys(deficits), &Map.has_key?(amounts, &1)) and
        Enum.all?(amounts, fn {meter_ref, amount} ->
          Map.get(recontained, meter_ref, 0) + Map.get(deficits, meter_ref, 0) == amount
        end)

    if valid?, do: :ok, else: {:error, :invalid_meter_recontainment_partition}
  end

  defp exact_recontainment_result(
         _act_ref,
         recontained,
         deficits,
         recontained,
         deficits
       ),
       do: :ok

  defp exact_recontainment_result(act_ref, _actual, _deficits, _expected, _expected_deficits),
    do: {:error, {:meter_recontainment_balance_mismatch, act_ref}}

  defp transition_reservation(projection, data, operation) do
    with {:ok, context} <- reservation_context(projection, data),
         {:ok, status, binding} <- fetch_reservation(projection, context.act_ref),
         :ok <- match_reservation(binding, context),
         :ok <-
           validate_reservation_disposition(projection, context.act_ref, operation),
         {:ok, next_status} <- next_reservation_status(status, operation, context.act_ref),
         {:ok, accounts} <- fetch_meter_accounts(projection, context.mandate_ref),
         {:ok, accounts} <-
           transition_accounts(accounts, context.amounts, operation, status),
         {:ok, projection} <- put_meter_accounts(projection, context.mandate_ref, accounts) do
      {:ok,
       %{
         projection
         | reservation_states:
             Map.put(projection.reservation_states, context.act_ref, next_status)
       }}
    end
  end

  defp validate_reservation_disposition(projection, act_ref, operation) do
    outcomes =
      projection.outcomes
      |> Map.values()
      |> Enum.filter(&(&1.act_ref == act_ref))

    allowed_statuses =
      case operation do
        :settle -> [:succeeded, :failed]
        :release -> [:definitive_no_effect]
        :suspend -> [:ambiguous]
      end

    cond do
      Enum.any?(outcomes, &(&1.status in allowed_statuses)) ->
        :ok

      operation == :settle and internal_spend_act?(Map.get(projection.acts, act_ref)) ->
        :ok

      operation == :release and Map.has_key?(projection.dispatch_cancellations, act_ref) ->
        :ok

      operation == :suspend and Map.has_key?(projection.attempts_by_act, act_ref) and
          outcomes == [] ->
        :ok

      true ->
        {:error, {:reservation_disposition_not_evidenced, act_ref, operation}}
    end
  end

  defp reservation_context(projection, data) do
    act_ref = field(data, :act_ref)
    mandate_ref = field(data, :mandate_ref)

    with {:ok, act} <- fetch_act(projection, act_ref),
         :ok <- match_meter_mandate(act, mandate_ref),
         {:ok, amounts} <- normalize_reservation_amounts(field(data, :amounts)),
         {:ok, declared} <- normalize_reservation_amounts(act.reservations),
         :ok <- match_reservation_amounts(act_ref, amounts, declared) do
      {:ok, %{act_ref: act_ref, mandate_ref: mandate_ref, amounts: amounts}}
    end
  end

  defp match_meter_mandate(act, mandate_ref) do
    if act.mandate_ref == mandate_ref,
      do: :ok,
      else: {:error, {:meter_act_mandate_mismatch, act.ref, mandate_ref}}
  end

  defp match_reservation_amounts(_act_ref, amounts, amounts), do: :ok

  defp match_reservation_amounts(act_ref, _amounts, _declared),
    do: {:error, {:meter_act_amounts_mismatch, act_ref}}

  defp reservation_absent(projection, act_ref) do
    case Map.fetch(projection.reservation_states, act_ref) do
      :error -> :ok
      {:ok, status} -> {:error, {:reservation_already_exists, act_ref, status}}
    end
  end

  defp fetch_reservation(projection, act_ref) do
    with {:ok, status} <- Map.fetch(projection.reservation_states, act_ref),
         {:ok, binding} <- Map.fetch(projection.reservation_bindings, act_ref) do
      {:ok, status, binding}
    else
      :error -> {:error, {:reservation_not_found, act_ref}}
    end
  end

  defp match_reservation(binding, context) do
    if binding.act_ref == context.act_ref and binding.mandate_ref == context.mandate_ref and
         binding.amounts == context.amounts,
       do: :ok,
       else: {:error, {:reservation_identity_mismatch, context.act_ref}}
  end

  defp next_reservation_status(:reserved, :settle, _act_ref), do: {:ok, :settled}
  defp next_reservation_status(:reserved, :release, _act_ref), do: {:ok, :released}
  defp next_reservation_status(:reserved, :suspend, _act_ref), do: {:ok, :suspended}
  defp next_reservation_status(:suspended, :settle, _act_ref), do: {:ok, :settled}
  defp next_reservation_status(:suspended, :release, _act_ref), do: {:ok, :released}

  defp next_reservation_status(status, operation, act_ref),
    do: {:error, {:invalid_reservation_transition, act_ref, status, operation}}

  defp fetch_meter_accounts(projection, mandate_ref) do
    meter_accounts(projection, mandate_ref)
  end

  defp fetch_meter_owner(projection, mandate_ref) do
    case Map.fetch(projection.meter_owners, mandate_ref) do
      {:ok, owner_ref} -> {:ok, owner_ref}
      :error -> {:error, {:meter_owner_not_found, mandate_ref}}
    end
  end

  defp put_meter_accounts(projection, mandate_ref, accounts) do
    with {:ok, owner_ref} <- fetch_meter_owner(projection, mandate_ref) do
      {:ok, %{projection | meters: Map.put(projection.meters, owner_ref, accounts)}}
    end
  end

  defp transition_accounts(accounts, amounts, operation, reservation_status) do
    Enum.reduce_while(amounts, {:ok, accounts}, fn {meter_ref, amount}, {:ok, current} ->
      with {:ok, account} <- fetch_meter_account(current, meter_ref),
           {:ok, account} <-
             transition_account(account, operation, reservation_status, amount) do
        {:cont, {:ok, Map.put(current, meter_ref, account)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_meter_account(accounts, meter_ref) do
    case Map.fetch(accounts, meter_ref) do
      {:ok, account} -> {:ok, account}
      :error -> {:error, {:meter_not_found, meter_ref}}
    end
  end

  defp transition_account(account, :reserve, :unreserved, amount),
    do: Meter.reserve(account, amount)

  defp transition_account(account, :settle, :reserved, amount),
    do: Meter.settle(account, amount)

  defp transition_account(account, :release, :reserved, amount),
    do: Meter.release(account, amount)

  defp transition_account(account, :suspend, :reserved, amount),
    do: Meter.suspend(account, amount)

  defp transition_account(account, :settle, :suspended, amount),
    do: Meter.resolve_suspended(account, amount, :settle)

  defp transition_account(account, :release, :suspended, amount),
    do: Meter.resolve_suspended(account, amount, :release)

  defp has_reservations?(%{reservations: reservations}),
    do: reservations not in [%{}, []]

  defp internal_settlement_at?(events, %Act{} = act, act_index) do
    case {event_at(events, act_index + 1), event_at(events, act_index + 2)} do
      {%{type: "meter_reserved", data: reservation}, %{type: "meter_settled", data: settlement}} ->
        internal_spend_act?(act) and field(reservation, :act_ref) == act.ref and
          field(settlement, :act_ref) == act.ref

      _missing_or_interposed ->
        false
    end
  end

  defp internal_spend_act?(%Act{row: %{spend: true}} = act),
    do: Governance.ledger_internal?(act) and has_reservations?(act)

  defp internal_spend_act?(_act), do: false

  defp effective_revocation?(nil, _time), do: false

  defp effective_revocation?(revocation, time) when is_map(revocation) and is_integer(time) do
    case field(revocation, :effective_at) do
      effective_at when is_integer(effective_at) -> time >= effective_at
      _invalid -> true
    end
  end

  defp effective_revocation?(_invalid, _time), do: true

  defp normalize_devolution_amounts(amounts) do
    with {:ok, amounts} <- normalize_reservation_amounts(amounts),
         false <- map_size(amounts) == 0 do
      {:ok, amounts}
    else
      true -> {:error, :empty_meter_devolution}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_reservation_amounts(amounts)
       when is_map(amounts) and not is_struct(amounts) do
    Enum.reduce_while(amounts, {:ok, %{}}, fn {meter_ref, amount}, {:ok, normalized} ->
      if is_binary(meter_ref) and meter_ref != "" and is_integer(amount) and amount > 0,
        do: {:cont, {:ok, Map.put(normalized, meter_ref, amount)}},
        else: {:halt, {:error, {:invalid_meter_amount, meter_ref}}}
    end)
  end

  defp normalize_reservation_amounts(amounts) when is_list(amounts) do
    Enum.reduce_while(amounts, {:ok, %{}}, fn reservation, {:ok, normalized} ->
      meter_ref = field(reservation, :meter_ref)
      amount = field(reservation, :quantity)

      cond do
        not (is_binary(meter_ref) and meter_ref != "" and is_integer(amount) and amount > 0) ->
          {:halt, {:error, :invalid_meter_reservation}}

        Map.has_key?(normalized, meter_ref) ->
          {:halt, {:error, {:duplicate_meter_reservation, meter_ref}}}

        true ->
          {:cont, {:ok, Map.put(normalized, meter_ref, amount)}}
      end
    end)
  end

  defp normalize_reservation_amounts(_amounts), do: {:error, :invalid_meter_amounts}

  defp exact_row?(%Row{} = row, dimensions), do: Row.dimensions(row) == dimensions

  defp act_targets?(act, refs), do: Enum.all?(refs, &(&1 in act.target_refs))

  defp ledger_internal_act?(act) do
    Spectre.Governance.ledger_internal?(act)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil

  defp present_ref?(value), do: is_binary(value) and value != ""
end
