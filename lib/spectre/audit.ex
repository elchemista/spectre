defmodule Spectre.Audit do
  @moduledoc """
  Independent semantic verifier for a v0.4 Domain ledger snapshot.

  The auditor verifies the ledger chain, then folds canonical events directly.
  It deliberately does not read or trust the runtime projection. A successful
  report therefore means that the exported history is both structurally intact
  and consistent with the governed-act lifecycle understood by this version.

  Genesis and host attestations remain visible trust anchors: this module
  reports them, but does not claim to verify deployment isolation or an
  attestation scheme that is external to the ledger.
  """

  alias Spectre.Duty.{Derive, Disposition}
  alias Spectre.Duty.Authority, as: DutyAuthority
  alias Spectre.Evidence.Derivation
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Kernel.{Authority, Meter, Recognition}
  alias Spectre.Mandate.Ancestry
  alias Spectre.Outcome.Attestation
  alias Spectre.Scope.Opening

  alias Spectre.{
    Act,
    Attempt,
    Candidate,
    Condition,
    Constitution,
    Decision,
    Declassification,
    Definition,
    Disclosure,
    Duty,
    Erasure,
    Evidence,
    Genesis,
    Governance,
    HostProfile,
    Ledger,
    Mandate,
    Outcome,
    Presentation,
    Principal,
    Row,
    SubmissionContext,
    Surface
  }

  @format "spectre-semantic-audit"
  @format_version 1

  @record_events %{
    "genesis_recorded" => Genesis,
    "principal_recorded" => Principal,
    "host_profile_recorded" => HostProfile,
    "surface_recorded" => Surface,
    "mandate_issued" => Mandate,
    "declassification_recorded" => Declassification,
    "evidence_recorded" => Evidence,
    "presentation_recorded" => Presentation,
    "decision_recorded" => Decision,
    "act_committed" => Act,
    "attempt_started" => Attempt,
    "outcome_recorded" => Outcome,
    "duty_opened" => Duty,
    "scope_opened" => Opening,
    "erasure_requested" => Erasure
  }

  @manual_fields %{
    "mandate_revoked" => ~w(mandate_ref effective_at),
    "mandate_restricted" => ~w(act_ref predecessor_ref successor),
    "host_profile_revised" => ~w(act_ref previous_ref host_profile),
    "surface_revised" => ~w(act_ref previous_ref surface),
    "definition_revised" => ~w(act_ref previous_ref definition),
    "meter_reserved" => ~w(act_ref mandate_ref amounts),
    "meter_settled" => ~w(act_ref mandate_ref amounts),
    "meter_released" => ~w(act_ref mandate_ref amounts),
    "meter_suspended" => ~w(act_ref mandate_ref amounts),
    "meter_recontained" => ~w(act_ref mandate_ref outcome_ref amounts recontained deficits),
    "meter_duty_resolved" =>
      ~w(act_ref disposition_act_ref duty_ref mandate_ref operation amounts),
    "meter_devolved" => ~w(act_ref child_mandate_ref amounts),
    "dispatch_ready" => ~w(act_ref executor_ref executor_contract_ref),
    "dispatch_cancelled" => ~w(act_ref mandate_ref cause_ref reason cancelled_at),
    "duty_disposed" => ~w(cause_key disposition_act_ref)
  }

  @known_events Map.keys(@record_events) ++ Map.keys(@manual_fields)
  @event_fields ~w(type identity data schema_version)

  defmodule State do
    @moduledoc false

    defstruct domain_ref: nil,
              constitution: nil,
              revision: 0,
              event_recorded_at: %{},
              event_revisions: %{},
              required_duty_causes: %{},
              genesis: nil,
              genesis_batch: nil,
              principals: %{},
              host_profile: nil,
              host_profiles: %{},
              surface: nil,
              surfaces: %{},
              mandates: %{},
              mandate_successors: %{},
              mandate_predecessors: %{},
              revocations: %{},
              declassifications: %{},
              declassification_meta: %{},
              declassifications_by_act: %{},
              declassifications_by_evidence: %{},
              evidence: %{},
              presentations: %{},
              decisions: %{},
              decision_meta: %{},
              candidate_identities: %{},
              acts: %{},
              act_meta: %{},
              acts_by_decision: %{},
              act_contexts: %{},
              dispatch_ready: MapSet.new(),
              dispatch_cancellations: %{},
              attempts: %{},
              attempt_meta: %{},
              attempts_by_act: %{},
              consumed_nonces: MapSet.new(),
              outcomes: %{},
              outcome_meta: %{},
              meters: %{},
              meter_owners: %{},
              reservation_states: %{},
              reservation_bindings: %{},
              meter_recontainments: %{},
              duty_meter_resolutions: %{},
              meter_devolutions: MapSet.new(),
              duties: %{},
              duty_refs: %{},
              scopes: %{},
              definitions: %{},
              definition_heads: %{},
              erasures: %{},
              erasures_by_act: %{},
              last_event: nil
  end

  @typedoc "Portable report produced only after structural and semantic verification."
  @type report :: %{
          required(:format) => String.t(),
          required(:format_version) => pos_integer(),
          required(:domain_ref) => String.t(),
          required(:ledger_revision) => non_neg_integer(),
          required(:head_digest) => String.t(),
          required(:constitution_ref) => String.t(),
          required(:audited_at) => non_neg_integer(),
          required(:foundation) => map(),
          required(:act_contexts) => [map()],
          required(:meters) => map(),
          required(:meter_owners) => map(),
          required(:mandate_restrictions) => [map()],
          required(:meter_recontainments) => [map()],
          required(:dispatch_cancellations) => [map()],
          required(:open_duties) => [map()],
          required(:counts) => map()
        }

  @doc """
  Verifies a complete ledger snapshot against its pinned Constitution.

  `audited_at` is trusted audit time. It must not precede the latest durable
  ledger acquisition time. Structural failures are tagged
  `:ledger_integrity_failed`; semantic failures include the offending ledger
  revision and event type where one exists.
  """
  @spec verify(Ledger.snapshot() | map(), map(), non_neg_integer()) ::
          {:ok, report()} | {:error, term()}
  def verify(snapshot, constitution, audited_at)
      when is_map(constitution) and not is_struct(constitution) and
             is_integer(audited_at) and audited_at >= 0 do
    with :ok <- Constitution.validate(constitution),
         {:ok, verified} <- verify_ledger(snapshot),
         :ok <- audit_time_covers_ledger(verified, audited_at) do
      audit_verified(verified, constitution, audited_at)
    end
  end

  def verify(_snapshot, _constitution, _audited_at),
    do: {:error, :invalid_semantic_audit_input}

  defp verify_ledger(snapshot) do
    verification =
      if is_map(snapshot) and not is_struct(snapshot) and Map.has_key?(snapshot, "format"),
        do: Ledger.verify(snapshot),
        else: Ledger.verify_snapshot(snapshot)

    case verification do
      {:ok, verified} -> {:ok, verified}
      {:error, reason} -> {:error, {:ledger_integrity_failed, reason}}
    end
  end

  defp audit_time_covers_ledger(%{entries: []}, _audited_at), do: :ok

  defp audit_time_covers_ledger(%{entries: entries}, audited_at) do
    latest = entries |> List.last() |> Map.fetch!(:recorded_at)

    if audited_at >= latest,
      do: :ok,
      else: {:error, {:audit_time_precedes_ledger, audited_at, latest}}
  end

  defp audit_verified(snapshot, constitution, audited_at) do
    initial = %State{domain_ref: snapshot.domain_ref, constitution: constitution}

    snapshot.entries
    |> Enum.chunk_by(& &1.batch_id)
    |> Enum.reduce_while({:ok, initial}, fn entries, {:ok, state} ->
      case replay_batch(state, entries) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} ->
        state
        |> remember_required_duties(audited_at)
        |> finish(snapshot, constitution, audited_at)

      {:error, _reason} = error ->
        error
    end
  end

  defp replay_batch(state, entries) do
    with {:ok, events} <- decode_batch(entries),
         :ok <- validate_prior_durable_stages(state, events),
         {:ok, next} <- apply_events(state, events),
         :ok <- validate_batch(state, next, events) do
      {:ok, remember_required_duties(next, List.last(events).recorded_at)}
    else
      {:batch_error, revision, reason} -> semantic_error(revision, "batch", reason)
      {:error, _reason} = error -> error
    end
  end

  defp decode_batch(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, events} ->
      case decode_event(entry) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, semantic_error(entry.revision, "event", reason)}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_event(entry) do
    payload = entry.payload

    with :ok <- exact_keys(payload, @event_fields, :event),
         1 <- Map.fetch!(payload, "schema_version"),
         type when type in @known_events <- Map.fetch!(payload, "type"),
         identity when is_binary(identity) and identity != "" <- Map.fetch!(payload, "identity"),
         data when is_map(data) and not is_struct(data) <- Map.fetch!(payload, "data"),
         :ok <- validate_manual_data(type, identity, data),
         :ok <- validate_acquisition_time(type, data, entry.recorded_at) do
      {:ok,
       %{
         type: type,
         identity: identity,
         data: data,
         revision: entry.revision,
         batch_id: entry.batch_id,
         batch_index: entry.batch_index,
         recorded_at: entry.recorded_at
       }}
    else
      {:error, _reason} = error -> error
      version when is_integer(version) -> {:error, {:unsupported_event_schema_version, version}}
      _invalid -> {:error, :invalid_domain_event}
    end
  end

  defp validate_manual_data(type, identity, data) do
    case Map.fetch(@manual_fields, type) do
      :error ->
        :ok

      {:ok, fields} ->
        with :ok <- exact_keys(data, fields, type),
             :ok <- validate_manual_identity(type, identity, data) do
          :ok
        end
    end
  end

  defp validate_manual_identity(type, identity, %{"act_ref" => act_ref})
       when type in [
              "meter_reserved",
              "meter_settled",
              "meter_released",
              "meter_suspended",
              "meter_recontained",
              "meter_devolved",
              "dispatch_ready",
              "dispatch_cancelled"
            ] do
    if is_binary(act_ref) and act_ref != "" do
      expected = type <> ":" <> act_ref

      if identity == expected,
        do: :ok,
        else: {:error, {:event_identity_mismatch, identity, expected}}
    else
      {:error, {:invalid_event_act_ref, act_ref}}
    end
  end

  defp validate_manual_identity("duty_disposed", identity, %{
         "disposition_act_ref" => act_ref
       }) do
    if identity == act_ref,
      do: :ok,
      else: {:error, {:event_identity_mismatch, identity, act_ref}}
  end

  defp validate_manual_identity("meter_duty_resolved", identity, %{
         "disposition_act_ref" => act_ref
       }) do
    if is_binary(act_ref) and act_ref != "" do
      expected = "meter_duty_resolved:" <> act_ref

      if identity == expected,
        do: :ok,
        else: {:error, {:event_identity_mismatch, identity, expected}}
    else
      {:error, {:invalid_event_act_ref, act_ref}}
    end
  end

  defp validate_manual_identity(_type, _identity, _data), do: :ok

  defp validate_acquisition_time(type, data, recorded_at)
       when is_binary(type) and is_map(data) and is_integer(recorded_at) and recorded_at >= 0 do
    case type do
      "genesis_recorded" ->
        audit_not_future_time(type, "issued_at", data, recorded_at)

      "host_profile_recorded" ->
        audit_not_future_time(type, "declared_at", data, recorded_at)

      "host_profile_revised" ->
        audit_not_future_time(type, "declared_at", data["host_profile"], recorded_at)

      "definition_revised" ->
        audit_not_future_time(type, "declared_at", data["definition"], recorded_at)

      "declassification_recorded" ->
        audit_exact_event_time(type, "recorded_at", data, recorded_at)

      "evidence_recorded" ->
        audit_not_future_time(type, "observed_at", data, recorded_at)

      "presentation_recorded" ->
        audit_not_future_time(type, "prepared_at", data, recorded_at)

      "decision_recorded" ->
        audit_exact_event_time(type, "decided_at", data, recorded_at)

      "act_committed" ->
        audit_exact_event_time(type, "committed_at", data, recorded_at)

      "attempt_started" ->
        audit_exact_event_time(type, "started_at", data, recorded_at)

      "outcome_recorded" ->
        audit_not_future_time(type, "observed_at", data, recorded_at)

      "duty_opened" ->
        audit_not_future_time(type, "opened_at", data, recorded_at)

      "mandate_revoked" ->
        audit_exact_event_time(type, "effective_at", data, recorded_at)

      "dispatch_cancelled" ->
        audit_not_future_time(type, "cancelled_at", data, recorded_at)

      "scope_opened" ->
        audit_scope_acquisition_time(type, data, recorded_at)

      "erasure_requested" ->
        audit_not_future_time(type, "requested_at", data, recorded_at)

      _other ->
        :ok
    end
  end

  defp validate_acquisition_time(_type, _data, _recorded_at),
    do: {:error, :invalid_event_acquisition_time}

  defp audit_scope_acquisition_time(type, data, recorded_at) do
    if is_nil(data["source_act_ref"]),
      do: audit_not_future_time(type, "opened_at", data, recorded_at),
      else: audit_exact_event_time(type, "opened_at", data, recorded_at)
  end

  defp audit_exact_event_time(type, field, data, recorded_at) do
    case Map.get(data, field) do
      ^recorded_at -> :ok
      value -> {:error, {:event_time_mismatch, type, field, value, recorded_at}}
    end
  end

  defp audit_not_future_time(type, field, data, recorded_at) when is_map(data) do
    case Map.get(data, field) do
      value when is_integer(value) and value <= recorded_at -> :ok
      value -> {:error, {:event_from_future, type, field, value, recorded_at}}
    end
  end

  defp audit_not_future_time(type, field, data, recorded_at),
    do: {:error, {:event_from_future, type, field, data, recorded_at}}

  defp validate_prior_durable_stages(state, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "attempt_started" -> prior_dispatch(state, event)
          "outcome_recorded" -> prior_attempt(state, event)
          _other -> :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:batch_error, event.revision, reason}}
      end
    end)
  end

  defp prior_dispatch(state, event) do
    act_ref = Map.get(event.data, "act_ref")

    if MapSet.member?(state.dispatch_ready, act_ref),
      do: :ok,
      else: {:error, {:attempt_without_prior_durable_dispatch, event.identity, act_ref}}
  end

  defp prior_attempt(state, event) do
    attempt_ref = Map.get(event.data, "attempt_ref")
    act_ref = Map.get(event.data, "act_ref")

    case Map.fetch(state.attempts, attempt_ref) do
      {:ok, %Attempt{act_ref: ^act_ref}} -> :ok
      {:ok, _different} -> {:error, {:outcome_attempt_act_mismatch, event.identity, attempt_ref}}
      :error -> {:error, {:outcome_without_prior_durable_attempt, event.identity, attempt_ref}}
    end
  end

  defp apply_events(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, current} ->
      case apply_event(current, event) do
        {:ok, next} ->
          event_key = {event.type, event.identity}

          next = %{
            next
            | revision: event.revision,
              last_event: event,
              event_recorded_at: Map.put(next.event_recorded_at, event_key, event.recorded_at),
              event_revisions: Map.put(next.event_revisions, event_key, event.revision)
          }

          {:cont, {:ok, next}}

        {:error, reason} ->
          {:halt, semantic_error(event.revision, event.type, reason)}
      end
    end)
  end

  defp apply_event(state, %{type: "genesis_recorded"} = event),
    do: record_genesis(state, event)

  defp apply_event(state, %{type: "principal_recorded"} = event),
    do: record_foundation(state, event, Principal, :principals, :principal_refs)

  defp apply_event(state, %{type: "host_profile_recorded"} = event),
    do: record_host_profile(state, event)

  defp apply_event(state, %{type: "host_profile_revised"} = event),
    do: revise_host_profile(state, event)

  defp apply_event(state, %{type: "surface_recorded"} = event),
    do: record_surface(state, event)

  defp apply_event(state, %{type: "surface_revised"} = event),
    do: revise_surface(state, event)

  defp apply_event(state, %{type: "definition_revised"} = event),
    do: revise_definition(state, event)

  defp apply_event(state, %{type: "mandate_issued"} = event),
    do: record_mandate(state, event)

  defp apply_event(state, %{type: "mandate_restricted"} = event),
    do: record_mandate_restriction(state, event)

  defp apply_event(state, %{type: "mandate_revoked"} = event),
    do: record_revocation(state, event)

  defp apply_event(state, %{type: "declassification_recorded"} = event),
    do: record_declassification(state, event)

  defp apply_event(state, %{type: "evidence_recorded"} = event),
    do: record_evidence(state, event)

  defp apply_event(state, %{type: "presentation_recorded"} = event),
    do: record_presentation(state, event)

  defp apply_event(state, %{type: "decision_recorded"} = event),
    do: record_decision(state, event)

  defp apply_event(state, %{type: "act_committed"} = event),
    do: record_act(state, event)

  defp apply_event(state, %{type: "meter_reserved"} = event),
    do: reserve_meters(state, event)

  defp apply_event(state, %{type: type} = event)
       when type in ["meter_settled", "meter_released", "meter_suspended"],
       do: move_reservation(state, event)

  defp apply_event(state, %{type: "meter_recontained"} = event),
    do: recontain_released_reservation(state, event)

  defp apply_event(state, %{type: "meter_duty_resolved"} = event),
    do: resolve_duty_meter(state, event)

  defp apply_event(state, %{type: "meter_devolved"} = event),
    do: devolve_meters(state, event)

  defp apply_event(state, %{type: "dispatch_ready"} = event),
    do: record_dispatch(state, event)

  defp apply_event(state, %{type: "dispatch_cancelled"} = event),
    do: record_dispatch_cancellation(state, event)

  defp apply_event(state, %{type: "attempt_started"} = event),
    do: record_attempt(state, event)

  defp apply_event(state, %{type: "outcome_recorded"} = event),
    do: record_outcome(state, event)

  defp apply_event(state, %{type: "duty_opened"} = event),
    do: record_duty(state, event)

  defp apply_event(state, %{type: "duty_disposed"} = event),
    do: dispose_duty(state, event)

  defp apply_event(state, %{type: "scope_opened"} = event),
    do: record_scope(state, event)

  defp apply_event(state, %{type: "erasure_requested"} = event),
    do: record_erasure(state, event)

  defp record_genesis(%State{genesis: nil, revision: 0} = state, event) do
    with {:ok, genesis} <- decode_record(event, Genesis),
         true <- genesis.domain_ref == state.domain_ref do
      {:ok, %{state | genesis: genesis, genesis_batch: event.batch_id}}
    else
      false -> {:error, :genesis_domain_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp record_genesis(%State{genesis: nil}, _event), do: {:error, :genesis_must_be_first}
  defp record_genesis(_state, _event), do: {:error, :duplicate_genesis}

  defp record_foundation(state, event, module, collection, genesis_field) do
    with :ok <- same_genesis_batch(state, event),
         :ok <- genesis_names(state, genesis_field, event.identity),
         {:ok, record} <- decode_record(event, module),
         :ok <- absent(Map.fetch!(state, collection), event.identity, collection) do
      {:ok,
       Map.put(state, collection, Map.put(Map.fetch!(state, collection), event.identity, record))}
    end
  end

  defp record_host_profile(state, event) do
    with :ok <- same_genesis_batch(state, event),
         :ok <- genesis_names(state, :host_profile_ref, event.identity),
         :ok <- empty_single(state.host_profile, :host_profile),
         {:ok, profile} <- decode_record(event, HostProfile),
         true <- profile.revision == 1 do
      {:ok,
       %{
         state
         | host_profile: profile,
           host_profiles: Map.put(state.host_profiles, profile.ref, profile)
       }}
    else
      false -> {:error, {:invalid_initial_host_profile_revision, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp record_surface(state, event) do
    with :ok <- same_genesis_batch(state, event),
         :ok <- genesis_names(state, :surface_ref, event.identity),
         :ok <- empty_single(state.surface, :surface),
         {:ok, surface} <- decode_record(event, Surface),
         true <- surface.revision == state.genesis.surface_revision do
      {:ok, %{state | surface: surface, surfaces: Map.put(state.surfaces, surface.ref, surface)}}
    else
      false -> {:error, :genesis_surface_revision_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp revise_host_profile(%State{host_profile: nil}, _event),
    do: {:error, :host_profile_not_initialized}

  defp revise_host_profile(state, event) do
    current = state.host_profile

    with {:ok, profile} <- decode_embedded_record(event, HostProfile, "host_profile"),
         :ok <- absent(state.host_profiles, profile.ref, :host_profile),
         {:ok, act} <- fetch(state.acts, event.data["act_ref"], :act),
         :ok <- same_act_batch(state, act, event, :host_profile_revision),
         :ok <- validate_host_profile_revision(act, current, profile, event.data) do
      {:ok,
       %{
         state
         | host_profile: profile,
           host_profiles: Map.put(state.host_profiles, profile.ref, profile)
       }}
    end
  end

  defp validate_host_profile_revision(act, current, profile, data) do
    expected = %{
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

      has_reservations?(act) ->
        {:error, {:host_profile_revision_act_has_reservations, act.ref}}

      not act_targets?(act, [current.ref, profile.ref]) ->
        {:error, {:host_profile_revision_targets_missing, act.ref}}

      data["previous_ref"] != current.ref ->
        {:error, {:host_profile_revision_previous_ref_mismatch, profile.ref}}

      profile.revision != current.revision + 1 ->
        {:error,
         {:host_profile_revision_not_sequential, profile.ref, current.revision, profile.revision}}

      profile.declared_at < current.declared_at or profile.declared_at > act.committed_at ->
        {:error, {:invalid_host_profile_revision_time, profile.ref, profile.declared_at}}

      act.host_profile_ref != current.ref ->
        {:error, {:host_profile_revision_act_context_mismatch, act.ref}}

      act.consequence != expected ->
        {:error, {:host_profile_revision_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp revise_surface(%State{surface: nil}, _event), do: {:error, :surface_not_initialized}

  defp revise_surface(state, event) do
    current = state.surface

    with {:ok, surface} <- decode_embedded_record(event, Surface, "surface"),
         :ok <- absent(state.surfaces, surface.ref, :surface),
         {:ok, act} <- fetch(state.acts, event.data["act_ref"], :act),
         :ok <- same_act_batch(state, act, event, :surface_revision),
         :ok <- validate_surface_revision(act, current, surface, event.data) do
      {:ok, %{state | surface: surface, surfaces: Map.put(state.surfaces, surface.ref, surface)}}
    end
  end

  defp validate_surface_revision(act, current, surface, data) do
    expected = %{
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

      has_reservations?(act) ->
        {:error, {:surface_revision_act_has_reservations, act.ref}}

      not act_targets?(act, [current.ref, surface.ref]) ->
        {:error, {:surface_revision_targets_missing, act.ref}}

      data["previous_ref"] != current.ref ->
        {:error, {:surface_revision_previous_ref_mismatch, surface.ref}}

      surface.revision != current.revision + 1 ->
        {:error,
         {:surface_revision_not_sequential, surface.ref, current.revision, surface.revision}}

      act.surface_revision != current.revision ->
        {:error, {:surface_revision_act_context_mismatch, act.ref}}

      act.consequence != expected ->
        {:error, {:surface_revision_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp revise_definition(state, event) do
    with {:ok, definition} <- decode_embedded_record(event, Definition, "definition"),
         :ok <- absent(state.definitions, definition.ref, :definition),
         {:ok, act} <- fetch(state.acts, event.data["act_ref"], :act),
         :ok <- same_act_batch(state, act, event, :definition_revision),
         :ok <- validate_definition_revision(state, act, definition, event.data) do
      key = Definition.key(definition)

      {:ok,
       %{
         state
         | definitions: Map.put(state.definitions, definition.ref, definition),
           definition_heads: Map.put(state.definition_heads, key, definition.ref)
       }}
    end
  end

  defp validate_definition_revision(state, act, definition, data) do
    current_ref = Map.get(state.definition_heads, Definition.key(definition))
    current = if current_ref, do: Map.get(state.definitions, current_ref)

    expected = %{
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

      has_reservations?(act) ->
        {:error, {:definition_revision_act_has_reservations, act.ref}}

      not act_targets?(act, Enum.reject([definition.previous_ref, definition.ref], &is_nil/1)) ->
        {:error, {:definition_revision_targets_missing, act.ref}}

      data["previous_ref"] != definition.previous_ref ->
        {:error, {:definition_revision_previous_ref_mismatch, definition.ref}}

      act.consequence != expected ->
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

  defp decode_embedded_record(event, module, key) do
    decode_record(%{event | data: Map.get(event.data, key)}, module)
  end

  defp same_act_batch(state, act, event, kind) do
    case Map.get(state.act_meta, act.ref) do
      %{batch_id: batch_id} when batch_id == event.batch_id -> :ok
      %{batch_id: _other} -> {:error, {kind, :outside_governing_act_batch, act.ref}}
      nil -> {:error, {kind, :act_metadata_missing, act.ref}}
    end
  end

  defp record_scope(state, event) do
    with {:ok, opening} <- decode_record(event, Opening),
         :ok <- absent(state.scopes, event.identity, :scope),
         :ok <- validate_scope_opening(state, opening, event) do
      {:ok, %{state | scopes: Map.put(state.scopes, event.identity, opening)}}
    end
  end

  defp validate_scope_opening(state, opening, event) do
    principal_refs = [opening.opened_by_ref, opening.accountable_ref] |> Enum.reject(&is_nil/1)

    with true <- opening.domain_ref == state.domain_ref,
         true <- is_nil(opening.parent_ref) or Map.has_key?(state.scopes, opening.parent_ref),
         nil <- Enum.find(principal_refs, &(not Map.has_key?(state.principals, &1))),
         nil <-
           Enum.find(opening.disposition_authority_refs, fn ref ->
             not Map.has_key?(state.principals, ref) and not Map.has_key?(state.mandates, ref)
           end),
         {:ok, _context} <-
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
           }) do
      validate_scope_opening_source(state, opening, event)
    else
      false when opening.domain_ref != state.domain_ref ->
        {:error, {:scope_domain_mismatch, opening.ref, opening.domain_ref}}

      false ->
        {:error, {:scope_parent_not_found, opening.ref, opening.parent_ref}}

      ref when is_binary(ref) ->
        if ref in opening.disposition_authority_refs,
          do: {:error, {:scope_disposition_authority_not_found, opening.ref, ref}},
          else: {:error, {:scope_principal_not_found, opening.ref, ref}}

      {:error, reason} ->
        {:error, {:invalid_scope_submission_context, opening.ref, reason}}
    end
  end

  defp validate_scope_opening_source(_state, %Opening{source_act_ref: nil}, _event), do: :ok

  defp validate_scope_opening_source(state, %Opening{} = opening, event) do
    with {:ok, act} <- fetch(state.acts, opening.source_act_ref, :act),
         :ok <- same_act_batch(state, act, event, :scope_opening),
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

  defp record_declassification(state, event) do
    with {:ok, record} <- decode_record(event, Declassification),
         :ok <- absent(state.declassifications, record.ref, :declassification),
         :ok <- declassification_act_available(state, record),
         :ok <- declassified_evidence_available(state, record),
         {:ok, act} <- fetch(state.acts, record.source_act_ref, :act),
         :ok <- same_act_batch(state, act, event, :declassification),
         :ok <- declassification_follows_act(state, act, event),
         {:ok, _evidence} <- validate_declassification_act(state, act, record) do
      {:ok,
       %{
         state
         | declassifications: Map.put(state.declassifications, record.ref, record),
           declassification_meta:
             Map.put(state.declassification_meta, record.ref, event_metadata(event)),
           declassifications_by_act: Map.put(state.declassifications_by_act, act.ref, record.ref),
           declassifications_by_evidence:
             Map.put(state.declassifications_by_evidence, record.evidence_ref, record.ref)
       }}
    end
  end

  defp declassification_act_available(state, record) do
    case Map.fetch(state.declassifications_by_act, record.source_act_ref) do
      :error ->
        :ok

      {:ok, existing_ref} ->
        {:error, {:act_already_has_declassification, record.source_act_ref, existing_ref}}
    end
  end

  defp declassified_evidence_available(state, record) do
    cond do
      Map.has_key?(state.evidence, record.evidence_ref) ->
        {:error, {:declassified_evidence_already_recorded, record.evidence_ref}}

      Map.has_key?(state.declassifications_by_evidence, record.evidence_ref) ->
        {:error, {:evidence_already_declassified, record.evidence_ref}}

      true ->
        :ok
    end
  end

  defp declassification_follows_act(state, act, event) do
    case state.last_event do
      %{type: "act_committed", identity: identity, batch_id: batch_id, batch_index: index}
      when identity == act.ref and batch_id == event.batch_id and
             index + 1 == event.batch_index ->
        :ok

      _other ->
        {:error, {:declassification_not_immediately_after_act, act.ref}}
    end
  end

  defp validate_declassification_act(
         state,
         %Act{
           class: "data.declassify",
           consequence: %{"evidence_declassification" => draft}
         } = act,
         record
       )
       when map_size(act.consequence) == 1 do
    with true <- exact_row?(act.row, [:write, :govern]),
         false <- has_reservations?(act),
         true <- ledger_internal_act?(act),
         {:ok, decoded} <- Declassification.decode_draft(draft),
         true <- decoded.canonical == draft,
         {:ok, mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
         :ok <-
           Authority.owners_authorize_mandate?(
             mandate,
             decoded.removed_owner_refs,
             state
           ),
         {:ok, expected} <- Declassification.from_draft(draft, act.ref, act.committed_at),
         true <- expected == record,
         :ok <-
           ErasureAnalysis.validate_evidence_available(
             state,
             decoded.evidence.parent_refs
           ),
         {:ok, parents} <-
           fetch_many(state.evidence, decoded.evidence.parent_refs, :evidence_parent),
         :ok <- Declassification.validate_transition(record, decoded.evidence, parents),
         {:ok, required_targets} <-
           Declassification.required_target_refs(decoded.evidence, decoded.removed_labels),
         true <- act_targets?(act, required_targets) do
      {:ok, decoded.evidence}
    else
      true -> {:error, {:declassification_act_has_reservations, act.ref}}
      false -> {:error, {:invalid_evidence_declassification, record.ref, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_declassification_act(_state, act, record),
    do: {:error, {:invalid_declassification_act, record.ref, act.ref}}

  defp record_evidence(state, event) do
    with {:ok, evidence} <- decode_record(event, Evidence),
         :ok <- absent(state.evidence, evidence.ref, :evidence),
         :ok <- validate_evidence_scope_binding(state, evidence),
         :ok <- validate_evidence_lineage(state, evidence, event),
         :ok <- validate_presentation_approval_evidence(state, evidence) do
      {:ok, %{state | evidence: Map.put(state.evidence, evidence.ref, evidence)}}
    end
  end

  defp record_presentation(state, event) do
    with {:ok, presentation} <- decode_record(event, Presentation),
         :ok <- absent(state.presentations, presentation.ref, :presentation),
         {:ok, opening} <- fetch(state.scopes, presentation.scope_ref, :scope),
         true <- presentation.prepared_at >= opening.opened_at,
         :ok <-
           ErasureAnalysis.validate_evidence_available(
             state,
             presentation.disclosure.source_evidence_refs
           ),
         :ok <- Disclosure.verify_sources(presentation.disclosure, state.evidence) do
      {:ok,
       %{state | presentations: Map.put(state.presentations, presentation.ref, presentation)}}
    else
      false -> {:error, {:presentation_precedes_scope, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_evidence_scope_binding(state, evidence) do
    scope_ref = map_field(evidence.bindings, :scope_ref)

    if is_nil(scope_ref) do
      :ok
    else
      case Map.fetch(state.scopes, scope_ref) do
        {:ok, opening} ->
          cond do
            map_field(evidence.bindings, :domain_ref) != state.domain_ref ->
              {:error, {:evidence_scope_domain_mismatch, evidence.ref, scope_ref}}

            map_field(evidence.bindings, :authenticated_principal_ref) !=
                opening.opened_by_ref ->
              {:error, {:evidence_scope_principal_mismatch, evidence.ref, scope_ref}}

            map_field(evidence.bindings, :authentication_ref) != opening.authentication_ref ->
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

  defp validate_presentation_approval_evidence(state, evidence) do
    case Presentation.approval_refs(evidence) do
      :not_approval ->
        :ok

      {:error, reason} ->
        {:error, {:invalid_presentation_approval_evidence, evidence.ref, reason}}

      {:ok, presentation_ref, show_act_ref} ->
        with {:ok, presentation} <- fetch(state.presentations, presentation_ref, :presentation),
             {:ok, show_act} <- fetch(state.acts, show_act_ref, :act),
             {:ok, _basis_refs} <-
               Presentation.validate_response_with_basis(
                 evidence,
                 presentation,
                 show_act,
                 Map.values(state.outcomes),
                 [
                   evidence
                   | state
                     |> ErasureAnalysis.available_evidence()
                     |> Map.values()
                 ],
                 evidence.observed_at
               ) do
          :ok
        else
          {:error, reason} ->
            {:error, {:invalid_presentation_approval_evidence, evidence.ref, reason}}
        end
    end
  end

  defp validate_evidence_lineage(
         _state,
         %Evidence{provenance: :observed, parent_refs: []},
         _event
       ),
       do: :ok

  defp validate_evidence_lineage(state, %Evidence{provenance: provenance} = evidence, event)
       when provenance in [:derived, :generated] do
    with :ok <- ErasureAnalysis.validate_evidence_available(state, evidence.parent_refs),
         {:ok, parents} <- fetch_many(state.evidence, evidence.parent_refs, :evidence_parent),
         nil <- Enum.find(parents, &(&1.observed_at > evidence.observed_at)) do
      case Map.fetch(state.declassifications_by_evidence, evidence.ref) do
        {:ok, record_ref} ->
          with {:ok, record} <- fetch(state.declassifications, record_ref, :declassification),
               {:ok, metadata} <-
                 fetch(state.declassification_meta, record_ref, :declassification_metadata),
               true <- metadata.batch_id == event.batch_id,
               true <- metadata.batch_index + 1 == event.batch_index do
            Declassification.validate_transition(record, evidence, parents)
          else
            false -> {:error, {:declassified_evidence_outside_governing_batch, evidence.ref}}
            {:error, _reason} = error -> error
          end

        :error ->
          Derivation.validate(evidence, parents)
      end
    else
      %Evidence{} = parent ->
        {:error, {:evidence_parent_from_future, evidence.ref, parent.ref}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_evidence_lineage(_state, %Evidence{} = evidence, _event),
    do: {:error, {:invalid_evidence_lineage, evidence.ref, evidence.provenance}}

  defp record_erasure(state, event) do
    with {:ok, erasure} <- decode_record(event, Erasure),
         :ok <- absent(state.erasures, erasure.ref, :erasure),
         :ok <- erasure_act_available(state, erasure),
         {:ok, act} <- fetch(state.acts, erasure.source_act_ref, :act),
         :ok <- same_act_batch(state, act, event, :erasure_request),
         :ok <- validate_erasure_request(state, act, erasure) do
      {:ok,
       %{
         state
         | erasures: Map.put(state.erasures, erasure.ref, erasure),
           erasures_by_act: Map.put(state.erasures_by_act, act.ref, erasure.ref)
       }}
    end
  end

  defp erasure_act_available(state, erasure) do
    case Map.fetch(state.erasures_by_act, erasure.source_act_ref) do
      :error ->
        :ok

      {:ok, existing_ref} ->
        {:error, {:act_already_has_erasure_request, erasure.source_act_ref, existing_ref}}
    end
  end

  defp validate_erasure_request(state, act, erasure) do
    prefix = %{state | acts: Map.delete(state.acts, act.ref)}

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

  defp decode_record(event, module) do
    with {:ok, record} <- module.from_canonical(event.data),
         true <- module.canonical(record) == event.data,
         true <- Map.fetch!(record, :ref) == event.identity do
      {:ok, record}
    else
      false -> {:error, {:noncanonical_or_misidentified_record, module, event.identity}}
      {:error, reason} -> {:error, {:invalid_record, module, reason}}
    end
  end

  defp same_genesis_batch(%State{genesis: nil}, _event), do: {:error, :genesis_required}

  defp same_genesis_batch(state, event) do
    if state.genesis_batch == event.batch_id,
      do: :ok,
      else: {:error, :foundation_outside_genesis_batch}
  end

  defp genesis_names(state, field, ref) do
    named = Map.fetch!(state.genesis, field)

    if (is_list(named) and ref in named) or named == ref,
      do: :ok,
      else: {:error, {:foundation_not_named_by_genesis, field, ref}}
  end

  defp empty_single(nil, _kind), do: :ok
  defp empty_single(_record, kind), do: {:error, {:duplicate_foundation_record, kind}}

  defp absent(collection, identity, kind) do
    if Map.has_key?(collection, identity),
      do: {:error, {:duplicate_record, kind, identity}},
      else: :ok
  end

  defp record_mandate(state, event) do
    with {:ok, mandate} <- decode_record(event, Mandate),
         :ok <- absent(state.mandates, mandate.ref, :mandate),
         true <- mandate.revision == 1,
         :ok <- validate_mandate_principals(state, mandate),
         {:ok, meters} <- issue_mandate_meters(state, event, mandate) do
      {:ok,
       %{
         state
         | mandates: Map.put(state.mandates, mandate.ref, mandate),
           meters: meters,
           meter_owners: Map.put(state.meter_owners, mandate.ref, mandate.ref)
       }}
    else
      false -> {:error, {:invalid_initial_mandate_revision, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_mandate_principals(state, mandate) do
    refs =
      [mandate.grantor_ref, mandate.holder_ref, mandate.accountable_ref] ++
        Map.fetch!(mandate.revocation, "controller_refs")

    case Enum.find(refs, &(not Map.has_key?(state.principals, &1))) do
      nil -> :ok
      ref -> {:error, {:mandate_principal_not_found, mandate.ref, ref}}
    end
  end

  defp issue_mandate_meters(state, event, %Mandate{parent_ref: nil} = mandate) do
    with :ok <- same_genesis_batch(state, event),
         true <- root_mandate_named?(state.genesis, mandate.ref),
         true <- mandate.source_ref == state.genesis.ref do
      {:ok, Map.put(state.meters, mandate.ref, initial_accounts(mandate.meters))}
    else
      false -> {:error, {:invalid_root_mandate, mandate.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp issue_mandate_meters(state, event, %Mandate{} = child) do
    with {:ok, parent} <- fetch(state.mandates, child.parent_ref, :mandate),
         {:ok, source_act} <- fetch(state.acts, child.source_ref, :act),
         %{batch_id: batch_id} <- Map.get(state.act_meta, source_act.ref),
         true <- batch_id == event.batch_id,
         :ok <- validate_delegation_act(source_act, parent, child),
         :ok <- Authority.delegation_within?(parent, child, source_act.committed_at),
         {:ok, meters} <- transfer_child_meters(state, parent, child) do
      {:ok, meters}
    else
      nil -> {:error, {:delegation_source_metadata_missing, child.source_ref}}
      false -> {:error, {:delegated_mandate_outside_source_batch, child.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_delegation_act(act, parent, child) do
    expected_draft = child |> Mandate.canonical() |> Map.drop(["ref", "source_ref"])

    cond do
      act.class != "mandate.delegate" ->
        {:error, {:delegation_act_class_mismatch, act.ref}}

      not exact_row?(act.row, [:delegate, :govern]) ->
        {:error, {:delegation_act_row_mismatch, act.ref}}

      has_reservations?(act) ->
        {:error, {:delegation_act_has_reservations, act.ref}}

      act.mandate_ref != parent.ref or act.mandate_revision != parent.revision ->
        {:error, {:delegation_parent_authority_mismatch, act.ref, parent.ref}}

      not act_targets?(act, [parent.ref]) ->
        {:error, {:delegation_parent_target_missing, act.ref, parent.ref}}

      act.consequence != %{"mandate_issue" => expected_draft} ->
        {:error, {:delegation_draft_mismatch, act.ref, child.ref}}

      true ->
        :ok
    end
  end

  defp root_mandate_named?(genesis, ref) do
    ref in genesis.root_mandate_refs or genesis.emergency_mandate_ref == ref
  end

  defp initial_accounts(allocations) do
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
  end

  defp transfer_child_meters(state, parent, child) do
    with {:ok, parent_owner_ref} <- fetch_meter_owner(state, parent.ref),
         {:ok, parent_accounts} <- fetch_meter_accounts(state, parent.ref) do
      child_accounts = initial_accounts(Map.new(child.meters, fn {ref, _amount} -> {ref, 0} end))

      child.meters
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, parent_accounts, child_accounts}, fn
        {meter_ref, amount}, {:ok, parents, children} ->
          with {:ok, parent_account} <- fetch(parents, meter_ref, :meter),
               {:ok, child_account} <- fetch(children, meter_ref, :meter),
               {:ok, parent_account, child_account} <-
                 Meter.delegate(parent_account, child_account, amount) do
            {:cont,
             {:ok, Map.put(parents, meter_ref, parent_account),
              Map.put(children, meter_ref, child_account)}}
          else
            {:error, _reason} = error -> {:halt, error}
          end
      end)
      |> case do
        {:ok, parents, children} ->
          {:ok,
           state.meters
           |> Map.put(parent_owner_ref, parents)
           |> Map.put(child.ref, children)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp record_mandate_restriction(state, event) do
    predecessor_ref = Map.fetch!(event.data, "predecessor_ref")
    act_ref = Map.fetch!(event.data, "act_ref")

    with {:ok, predecessor} <- fetch(state.mandates, predecessor_ref, :mandate),
         {:ok, act} <- fetch(state.acts, act_ref, :act),
         :ok <- same_act_batch(state, act, event, :mandate_restriction),
         {:ok, successor} <-
           decode_record(%{event | data: Map.fetch!(event.data, "successor")}, Mandate),
         true <- Map.fetch!(event.data, "successor") == Mandate.canonical(successor),
         :ok <- absent(state.mandates, successor.ref, :mandate),
         :ok <- validate_mandate_principals(state, successor),
         :ok <- validate_restriction_act(act, predecessor, successor, event.data),
         :ok <- restrictable_predecessor(state, predecessor, act.committed_at),
         :ok <- restriction_link_available(state, predecessor.ref, successor.ref),
         {:ok, owner_ref} <- fetch_meter_owner(state, predecessor.ref) do
      {:ok,
       %{
         state
         | mandates: Map.put(state.mandates, successor.ref, successor),
           mandate_successors: Map.put(state.mandate_successors, predecessor.ref, successor.ref),
           mandate_predecessors:
             Map.put(state.mandate_predecessors, successor.ref, predecessor.ref),
           meter_owners: Map.put(state.meter_owners, successor.ref, owner_ref)
       }}
    else
      false -> {:error, {:noncanonical_mandate_restriction, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_restriction_act(act, predecessor, successor, data) do
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

      has_reservations?(act) ->
        {:error, {:mandate_restriction_act_has_reservations, act.ref}}

      not ledger_internal_act?(act) ->
        {:error, {:mandate_restriction_act_not_ledger_internal, act.ref}}

      not act_targets?(act, [predecessor.ref]) ->
        {:error, {:mandate_restriction_act_target_missing, act.ref, predecessor.ref}}

      Map.fetch!(data, "act_ref") != act.ref ->
        {:error, {:mandate_restriction_event_act_mismatch, successor.ref, act.ref}}

      Map.fetch!(data, "predecessor_ref") != predecessor.ref ->
        {:error, {:mandate_restriction_predecessor_mismatch, successor.ref, predecessor.ref}}

      successor.source_ref != act.ref ->
        {:error, {:mandate_restriction_source_mismatch, successor.ref, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:mandate_restriction_consequence_mismatch, act.ref, successor.ref}}

      true ->
        Authority.restriction_within?(predecessor, successor, act.committed_at)
    end
  end

  defp restrictable_predecessor(state, predecessor, time) do
    with :ok <- Authority.restriction_status(predecessor, authority_view(state)),
         {:ok, revoked?} <-
           Ancestry.revoked?(state.mandates, state.revocations, predecessor, time),
         false <- time >= predecessor.expires_at or revoked? do
      :ok
    else
      true -> {:error, {:mandate_restriction_predecessor_inactive, predecessor.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp restriction_link_available(state, predecessor_ref, successor_ref) do
    cond do
      Map.has_key?(state.mandate_successors, predecessor_ref) ->
        {:error, {:mandate_already_has_successor, predecessor_ref}}

      Map.has_key?(state.mandate_predecessors, successor_ref) ->
        {:error, {:mandate_already_has_predecessor, successor_ref}}

      succession_reaches?(state.mandate_successors, successor_ref, predecessor_ref) ->
        {:error, {:mandate_restriction_cycle, predecessor_ref, successor_ref}}

      true ->
        :ok
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

  defp record_revocation(state, event) do
    mandate_ref = Map.fetch!(event.data, "mandate_ref")

    with {:ok, mandate} <- fetch(state.mandates, mandate_ref, :mandate),
         :ok <- absent(state.revocations, mandate_ref, :revocation),
         {:ok, act} <- fetch(state.acts, event.identity, :act),
         %{batch_id: batch_id} <- Map.get(state.act_meta, act.ref),
         true <- batch_id == event.batch_id,
         :ok <- validate_revocation_act(act, mandate, event.data) do
      revocation =
        Map.merge(event.data, %{
          "act_ref" => act.ref,
          "mode" => Map.fetch!(mandate.revocation, "mode"),
          "revision" => event.revision
        })

      {:ok, %{state | revocations: Map.put(state.revocations, mandate_ref, revocation)}}
    else
      nil -> {:error, {:revocation_act_metadata_missing, event.identity}}
      false -> {:error, {:revocation_outside_governing_act_batch, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_revocation_act(act, mandate, data) do
    effective_at = Map.fetch!(data, "effective_at")
    controllers = Map.fetch!(mandate.revocation, "controller_refs")

    expected = %{
      "mandate_revoke" => %{
        "mandate_ref" => mandate.ref
      }
    }

    cond do
      act.class != "mandate.revoke" ->
        {:error, {:revocation_act_class_mismatch, act.ref}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:revocation_act_row_mismatch, act.ref}}

      has_reservations?(act) ->
        {:error, {:revocation_act_has_reservations, act.ref}}

      not act_targets?(act, [mandate.ref]) ->
        {:error, {:revocation_act_target_missing, act.ref, mandate.ref}}

      act.proposer_ref not in controllers ->
        {:error, {:revocation_controller_not_authorized, act.proposer_ref}}

      effective_at != act.committed_at ->
        {:error, {:invalid_revocation_effective_at, effective_at}}

      act.consequence != expected ->
        {:error, {:revocation_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp record_decision(state, event) do
    with {:ok, decision} <- decode_record(event, Decision),
         :ok <- absent(state.decisions, decision.ref, :decision),
         :ok <- decision_revision(state, event, decision),
         :ok <- decision_foundation(state, decision),
         :ok <- decision_evidence_basis(state, decision),
         :ok <- decision_authority(state, decision),
         :ok <- candidate_identity_available(state, decision) do
      {:ok,
       %{
         state
         | decisions: Map.put(state.decisions, decision.ref, decision),
           decision_meta: Map.put(state.decision_meta, decision.ref, event_metadata(event)),
           candidate_identities:
             Map.put(state.candidate_identities, decision.candidate_identity_key, %{
               digest: decision.candidate_digest,
               decision_ref: decision.ref
             })
       }}
    end
  end

  defp decision_revision(state, event, decision) do
    if decision.authority_revision == state.revision and
         decision.authority_revision == event.revision - 1,
       do: :ok,
       else: {:error, {:decision_authority_revision_mismatch, decision.ref}}
  end

  defp decision_evidence_basis(state, decision) do
    with :ok <-
           ErasureAnalysis.validate_evidence_available(
             state,
             decision.recognition_evidence_refs
           ),
         {:ok, evidence} <-
           fetch_many(state.evidence, decision.recognition_evidence_refs, :evidence) do
      case Enum.find(evidence, &(&1.observed_at > decision.decided_at)) do
        nil -> :ok
        future -> {:error, {:decision_evidence_from_future, decision.ref, future.ref}}
      end
    end
  end

  defp decision_foundation(state, decision) do
    with {:ok, context} <- decision_submission_context(decision),
         {:ok, _opening} <- decision_scope_context(state, context) do
      cond do
        decision.domain_ref != state.domain_ref ->
          {:error, {:decision_domain_mismatch, decision.ref, decision.domain_ref}}

        not Map.has_key?(state.principals, decision.authenticated_principal_ref) ->
          {:error, {:decision_principal_not_found, decision.authenticated_principal_ref}}

        is_nil(state.host_profile) or decision.host_profile_ref != state.host_profile.ref ->
          {:error, {:decision_host_profile_mismatch, decision.ref}}

        is_nil(state.surface) or decision.surface_revision != state.surface.revision ->
          {:error, {:decision_surface_revision_mismatch, decision.ref}}

        decision.outcome == :unknown_class and
            match?({:ok, _row}, Surface.classify(state.surface, decision.candidate_class)) ->
          {:error,
           {:decision_known_class_reported_unknown, decision.ref, decision.candidate_class}}

        decision.outcome == :admitted and
            decision.proposer_ref != decision.authenticated_principal_ref ->
          {:error, {:decision_proposer_not_authenticated, decision.ref}}

        true ->
          :ok
      end
    end
  end

  defp decision_scope_context(state, context) do
    case Map.fetch(state.scopes, context.scope_ref) do
      {:ok, %Opening{} = opening} ->
        cond do
          context.domain_ref != state.domain_ref or opening.domain_ref != context.domain_ref ->
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

      :error ->
        {:error, {:scope_not_open, context.scope_ref}}

      {:ok, _invalid} ->
        {:error, {:invalid_audited_scope, context.scope_ref}}
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

  defp decision_authority(_state, %Decision{outcome: outcome, mandate_ref: nil})
       when outcome != :admitted,
       do: :ok

  defp decision_authority(state, decision) do
    with {:ok, mandate} <- fetch(state.mandates, decision.mandate_ref, :mandate),
         {:ok, revoked?} <-
           Ancestry.revoked?(state.mandates, state.revocations, mandate, decision.decided_at) do
      cond do
        decision.mandate_revision != mandate.revision ->
          {:error, {:decision_mandate_revision_mismatch, decision.ref}}

        decision.outcome != :admitted ->
          :ok

        decision.reasons != [] ->
          {:error, {:admitted_decision_has_reasons, decision.ref}}

        retained_revocation_decision?(decision, mandate) ->
          validate_retained_revocation_decision(state, decision, mandate)

        decision.authenticated_principal_ref != mandate.holder_ref ->
          {:error, {:decision_holder_mismatch, decision.ref}}

        decision.authorizer_ref != mandate.grantor_ref ->
          {:error, {:decision_authorizer_mismatch, decision.ref}}

        decision.accountable_ref != mandate.accountable_ref ->
          {:error, {:decision_accountable_mismatch, decision.ref}}

        decision.executor_ref not in mandate.executor_refs ->
          {:error, {:decision_executor_outside_mandate, decision.ref}}

        decision.decided_at < mandate.not_before or decision.decided_at >= mandate.expires_at ->
          {:error, {:decision_mandate_not_current, decision.ref}}

        revoked? ->
          {:error, {:decision_mandate_revoked, decision.ref}}

        true ->
          :ok
      end
    end
  end

  defp retained_revocation_decision?(decision, mandate) do
    decision.candidate_class == "mandate.revoke" and
      decision.mandate_ref == mandate.ref and
      Map.get(mandate.revocation, "mode") in [:retained_controller, "retained_controller"]
  end

  defp validate_retained_revocation_decision(state, decision, mandate) do
    controllers = Map.get(mandate.revocation, "controller_refs", [])

    with {:ok, revoked?} <-
           Ancestry.revoked?(state.mandates, state.revocations, mandate, decision.decided_at) do
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

        revoked? ->
          {:error, {:decision_mandate_revoked, decision.ref}}

        true ->
          :ok
      end
    end
  end

  defp candidate_identity_available(state, decision) do
    case Map.fetch(state.candidate_identities, decision.candidate_identity_key) do
      :error ->
        :ok

      {:ok, %{digest: digest}} when digest == decision.candidate_digest ->
        {:error, {:duplicate_candidate_decision, decision.candidate_identity_key}}

      {:ok, _different} ->
        {:error, {:candidate_identity_conflict, decision.candidate_identity_key}}
    end
  end

  defp reserve_meters(state, event) do
    with {:ok, context} <- reservation_context(state, event.data),
         :ok <- absent(state.reservation_states, context.act_ref, :reservation),
         %{batch_id: batch_id} <- Map.get(state.act_meta, context.act_ref),
         true <- batch_id == event.batch_id,
         {:ok, accounts} <- fetch_meter_accounts(state, context.mandate_ref),
         {:ok, accounts} <- move_accounts(accounts, context.amounts, :reserve, :unreserved),
         {:ok, state} <- put_meter_accounts(state, context.mandate_ref, accounts) do
      {:ok,
       %{
         state
         | reservation_states: Map.put(state.reservation_states, context.act_ref, :reserved),
           reservation_bindings: Map.put(state.reservation_bindings, context.act_ref, context)
       }}
    else
      nil -> {:error, {:reservation_act_metadata_missing, event.data["act_ref"]}}
      false -> {:error, {:reservation_outside_admission_batch, event.data["act_ref"]}}
      {:error, _reason} = error -> error
    end
  end

  defp move_reservation(state, event) do
    operation = meter_operation(event.type)

    with {:ok, context} <- reservation_context(state, event.data),
         {:ok, status} <- fetch(state.reservation_states, context.act_ref, :reservation),
         {:ok, binding} <-
           fetch(state.reservation_bindings, context.act_ref, :reservation_binding),
         true <- binding == context,
         :ok <- disposition_evidenced(state, event, operation),
         {:ok, next_status} <- reservation_transition(status, operation, context.act_ref),
         {:ok, accounts} <- fetch_meter_accounts(state, context.mandate_ref),
         {:ok, accounts} <- move_accounts(accounts, context.amounts, operation, status),
         {:ok, state} <- put_meter_accounts(state, context.mandate_ref, accounts) do
      {:ok,
       %{
         state
         | reservation_states: Map.put(state.reservation_states, context.act_ref, next_status)
       }}
    else
      false -> {:error, {:reservation_binding_mismatch, event.data["act_ref"]}}
      {:error, _reason} = error -> error
    end
  end

  defp recontain_released_reservation(state, event) do
    outcome_ref = Map.fetch!(event.data, "outcome_ref")

    with {:ok, context} <- reservation_context(state, event.data),
         {:ok, status} <- fetch(state.reservation_states, context.act_ref, :reservation),
         true <- status == :released,
         {:ok, binding} <-
           fetch(state.reservation_bindings, context.act_ref, :reservation_binding),
         true <- binding == context,
         {:ok, %Outcome{} = outcome} <- fetch(state.outcomes, outcome_ref, :outcome),
         :ok <- validate_recontainment_cause(state, context, outcome),
         :ok <- absent(state.meter_recontainments, context.act_ref, :meter_recontainment),
         {:ok, recontained} <- normalize_amounts_or_empty(event.data["recontained"]),
         {:ok, deficits} <- normalize_amounts_or_empty(event.data["deficits"]),
         :ok <- validate_recontainment_partition(context.amounts, recontained, deficits),
         {:ok, accounts} <- fetch_meter_accounts(state, context.mandate_ref),
         {:ok, accounts, expected_recontained, expected_deficits} <-
           Meter.recontain_many(context.amounts, accounts),
         true <- recontained == expected_recontained and deficits == expected_deficits,
         {:ok, state} <- put_meter_accounts(state, context.mandate_ref, accounts) do
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
         state
         | reservation_states: Map.put(state.reservation_states, context.act_ref, :suspended),
           meter_recontainments: Map.put(state.meter_recontainments, context.act_ref, record)
       }}
    else
      false -> {:error, {:invalid_meter_recontainment, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_recontainment_cause(state, context, outcome) do
    corrected = Map.get(state.outcomes, outcome.contradicts_outcome_ref)

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

  defp validate_recontainment_partition(amounts, recontained, deficits) do
    valid? =
      Enum.all?(Map.keys(recontained) ++ Map.keys(deficits), &Map.has_key?(amounts, &1)) and
        Enum.all?(amounts, fn {meter_ref, amount} ->
          Map.get(recontained, meter_ref, 0) + Map.get(deficits, meter_ref, 0) == amount
        end)

    if valid?, do: :ok, else: {:error, :invalid_meter_recontainment_partition}
  end

  defp reservation_context(state, data) do
    act_ref = Map.fetch!(data, "act_ref")
    mandate_ref = Map.fetch!(data, "mandate_ref")

    with {:ok, act} <- fetch(state.acts, act_ref, :act),
         true <- act.mandate_ref == mandate_ref,
         {:ok, amounts} <- normalize_amounts(Map.fetch!(data, "amounts")),
         {:ok, declared} <- normalize_amounts(act.reservations),
         true <- amounts == declared do
      {:ok, %{act_ref: act_ref, mandate_ref: mandate_ref, amounts: amounts}}
    else
      false -> {:error, {:meter_act_binding_mismatch, act_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp disposition_evidenced(state, event, operation) do
    act_ref = Map.fetch!(event.data, "act_ref")

    allowed =
      case operation do
        :settle -> [:succeeded, :failed]
        :release -> [:definitive_no_effect]
        :suspend -> [:ambiguous]
      end

    outcome_in_batch? =
      Enum.any?(state.outcomes, fn {ref, outcome} ->
        outcome.act_ref == act_ref and outcome.status in allowed and
          state.outcome_meta[ref].batch_id == event.batch_id
      end)

    silent_attempt? =
      operation == :suspend and Map.has_key?(state.attempts_by_act, act_ref) and
        Enum.all?(state.outcomes, fn {_ref, outcome} -> outcome.act_ref != act_ref end)

    cancellation_release? =
      operation == :release and Map.has_key?(state.dispatch_cancellations, act_ref) and
        match?(
          %{
            type: "dispatch_cancelled",
            batch_id: batch_id,
            data: %{"act_ref" => ^act_ref}
          }
          when batch_id == event.batch_id,
          state.last_event
        )

    if outcome_in_batch? or silent_attempt? or cancellation_release?,
      do: :ok,
      else: {:error, {:meter_disposition_without_same_batch_evidence, act_ref, operation}}
  end

  defp meter_operation("meter_settled"), do: :settle
  defp meter_operation("meter_released"), do: :release
  defp meter_operation("meter_suspended"), do: :suspend

  defp reservation_transition(:reserved, :settle, _act_ref), do: {:ok, :settled}
  defp reservation_transition(:reserved, :release, _act_ref), do: {:ok, :released}
  defp reservation_transition(:reserved, :suspend, _act_ref), do: {:ok, :suspended}
  defp reservation_transition(:suspended, :settle, _act_ref), do: {:ok, :settled}
  defp reservation_transition(:suspended, :release, _act_ref), do: {:ok, :released}

  defp reservation_transition(status, operation, act_ref),
    do: {:error, {:invalid_reservation_transition, act_ref, status, operation}}

  defp move_accounts(accounts, amounts, operation, status) do
    Enum.reduce_while(amounts, {:ok, accounts}, fn {meter_ref, amount}, {:ok, current} ->
      with {:ok, account} <- fetch(current, meter_ref, :meter),
           {:ok, account} <- move_account(account, operation, status, amount) do
        {:cont, {:ok, Map.put(current, meter_ref, account)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp move_account(account, :reserve, :unreserved, amount), do: Meter.reserve(account, amount)
  defp move_account(account, :settle, :reserved, amount), do: Meter.settle(account, amount)
  defp move_account(account, :release, :reserved, amount), do: Meter.release(account, amount)
  defp move_account(account, :suspend, :reserved, amount), do: Meter.suspend(account, amount)

  defp move_account(account, :settle, :suspended, amount),
    do: Meter.resolve_suspended(account, amount, :settle)

  defp move_account(account, :release, :suspended, amount),
    do: Meter.resolve_suspended(account, amount, :release)

  defp devolve_meters(state, event) do
    act_ref = event.data["act_ref"]
    child_ref = event.data["child_mandate_ref"]

    with {:ok, act} <- fetch(state.acts, act_ref, :act),
         :ok <- same_act_batch(state, act, event, :meter_devolution),
         :ok <- devolution_not_applied(state, act_ref),
         {:ok, child} <- fetch(state.mandates, child_ref, :mandate),
         :ok <- child_mandate(child),
         {:ok, parent} <- fetch(state.mandates, child.parent_ref, :mandate),
         :ok <- mandate_terminal(state, child, act.committed_at),
         {:ok, amounts} <- normalize_amounts(event.data["amounts"]),
         :ok <- validate_devolution_act(act, child, amounts),
         {:ok, parent_owner_ref} <- fetch_meter_owner(state, parent.ref),
         {:ok, child_owner_ref} <- fetch_meter_owner(state, child.ref),
         true <- parent_owner_ref != child_owner_ref,
         {:ok, parent_accounts} <- fetch_meter_accounts(state, parent.ref),
         {:ok, child_accounts} <- fetch_meter_accounts(state, child.ref),
         :ok <- exact_available_devolution(child.ref, child_accounts, amounts),
         {:ok, parent_accounts, child_accounts} <-
           apply_devolution(parent_accounts, child_accounts, amounts) do
      meters =
        state.meters
        |> Map.put(parent_owner_ref, parent_accounts)
        |> Map.put(child_owner_ref, child_accounts)

      {:ok,
       %{
         state
         | meters: meters,
           meter_devolutions: MapSet.put(state.meter_devolutions, act_ref)
       }}
    else
      false -> {:error, {:meter_devolution_owner_collision, child_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp devolution_not_applied(state, act_ref) do
    if MapSet.member?(state.meter_devolutions, act_ref),
      do: {:error, {:meter_devolution_already_applied, act_ref}},
      else: :ok
  end

  defp child_mandate(%Mandate{parent_ref: parent_ref})
       when is_binary(parent_ref) and parent_ref != "",
       do: :ok

  defp child_mandate(%Mandate{ref: ref}), do: {:error, {:root_mandate_cannot_devolve, ref}}

  defp validate_devolution_act(act, child, amounts) do
    expected = %{
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

      has_reservations?(act) ->
        {:error, {:meter_devolution_act_has_reservations, act.ref}}

      not act_targets?(act, [child.ref]) ->
        {:error, {:meter_devolution_target_missing, act.ref, child.ref}}

      act.consequence != expected ->
        {:error, {:meter_devolution_consequence_mismatch, act.ref, child.ref}}

      true ->
        :ok
    end
  end

  defp exact_available_devolution(child_ref, accounts, amounts) do
    available =
      accounts
      |> Enum.flat_map(fn {meter_ref, account} ->
        case Map.get(account, :available) do
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
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, parent_accounts, child_accounts}, fn
      {meter_ref, amount}, {:ok, parents, children} ->
        with {:ok, parent} <- fetch(parents, meter_ref, :meter),
             {:ok, child} <- fetch(children, meter_ref, :meter),
             {:ok, parent, child} <- Meter.devolve(parent, child, amount) do
          {:cont, {:ok, Map.put(parents, meter_ref, parent), Map.put(children, meter_ref, child)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp mandate_terminal(state, mandate, time) do
    with {:ok, revoked?} <-
           Ancestry.revoked?(state.mandates, state.revocations, mandate, time) do
      if time >= mandate.expires_at or revoked?,
        do: :ok,
        else: {:error, {:mandate_not_terminal_for_devolution, mandate.ref}}
    end
  end

  defp record_dispatch(state, event) do
    act_ref = Map.fetch!(event.data, "act_ref")

    with {:ok, act} <- fetch(state.acts, act_ref, :act),
         %{batch_id: batch_id} <- Map.get(state.act_meta, act_ref),
         true <- batch_id == event.batch_id,
         true <- act.row.attempt,
         true <- event.data["executor_ref"] == act.executor_ref,
         true <- event.data["executor_contract_ref"] == act.executor_contract_ref,
         false <- MapSet.member?(state.dispatch_ready, act_ref),
         false <- Map.has_key?(state.dispatch_cancellations, act_ref),
         false <- Map.has_key?(state.attempts_by_act, act_ref),
         false <- open_disputed_duty_for_act?(state, act.ref),
         :ok <- reservation_ready(state, act) do
      {:ok, %{state | dispatch_ready: MapSet.put(state.dispatch_ready, act_ref)}}
    else
      nil -> {:error, {:dispatch_act_metadata_missing, act_ref}}
      false -> {:error, {:invalid_or_duplicate_dispatch, act_ref}}
      true -> {:error, {:invalid_or_duplicate_dispatch, act_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp record_dispatch_cancellation(state, event) do
    act_ref = Map.fetch!(event.data, "act_ref")

    with {:ok, act} <- fetch(state.acts, act_ref, :act),
         :ok <- validate_dispatch_cancellation(state, act, event) do
      cancellation = %{
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        cause_ref: event.data["cause_ref"],
        reason: event.data["reason"],
        cancelled_at: event.data["cancelled_at"]
      }

      {:ok,
       %{
         state
         | dispatch_ready: MapSet.delete(state.dispatch_ready, act.ref),
           dispatch_cancellations: Map.put(state.dispatch_cancellations, act.ref, cancellation)
       }}
    end
  end

  defp validate_dispatch_cancellation(state, act, event) do
    data = event.data

    cond do
      not act.row.attempt ->
        {:error, {:dispatch_cancellation_act_not_attemptable, act.ref}}

      not MapSet.member?(state.dispatch_ready, act.ref) ->
        {:error, {:dispatch_cancellation_not_pending, act.ref}}

      Map.has_key?(state.attempts_by_act, act.ref) ->
        {:error, {:dispatch_cancellation_after_attempt, act.ref}}

      Map.has_key?(state.dispatch_cancellations, act.ref) ->
        {:error, {:duplicate_dispatch_cancellation, act.ref}}

      data["mandate_ref"] != act.mandate_ref ->
        {:error, {:dispatch_cancellation_mandate_mismatch, act.ref}}

      has_reservations?(act) and Map.get(state.reservation_states, act.ref) != :reserved ->
        {:error, {:dispatch_cancellation_reservation_not_pending, act.ref}}

      true ->
        validate_dispatch_cancellation_cause(state, act, event)
    end
  end

  defp validate_dispatch_cancellation_cause(state, act, event) do
    data = event.data

    case data["reason"] do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        with {:ok, cause_act} <- fetch(state.acts, data["cause_ref"], :cancellation_cause_act),
             :ok <- same_act_batch(state, cause_act, event, :dispatch_cancellation),
             :ok <- validate_governance_cancellation_time(act, cause_act, data),
             {:ok, target_mandate_ref, cascade?} <-
               cancellation_authority_change(state, cause_act, reason),
             {:ok, true} <-
               mandate_affected_by_change?(
                 state,
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
        with {:ok, duty} <- fetch_duty_by_ref(state, data["cause_ref"]),
             true <- duty.class == :disputed_evidence,
             true <- duty.status == :open,
             true <- duty.act_ref == act.ref,
             true <- is_nil(duty.attempt_ref),
             true <- duty.mandate_ref == act.mandate_ref,
             true <- data["cancelled_at"] == duty.opened_at,
             true <- act.committed_at <= duty.opened_at,
             %{type: "duty_opened", identity: duty_ref, batch_id: batch_id} <- state.last_event,
             true <- duty_ref == duty.ref and batch_id == event.batch_id do
          :ok
        else
          false -> {:error, {:invalid_disputed_dispatch_cancellation, act.ref}}
          nil -> {:error, {:dispatch_cancellation_outside_duty_batch, act.ref}}
          {:error, _reason} = error -> error
          _invalid -> {:error, {:dispatch_cancellation_outside_duty_batch, act.ref}}
        end

      :mandate_expired ->
        with {:ok, mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
             true <- data["cause_ref"] == mandate.ref,
             true <- act.mandate_revision == mandate.revision,
             true <- data["cancelled_at"] == mandate.expires_at do
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
      data["cause_ref"] != cause_act.ref ->
        {:error, {:dispatch_cancellation_cause_mismatch, act.ref}}

      data["cancelled_at"] != cause_act.committed_at ->
        {:error, {:dispatch_cancellation_time_mismatch, act.ref}}

      act.committed_at > cause_act.committed_at ->
        {:error, {:dispatch_cancellation_precedes_act, act.ref}}

      true ->
        :ok
    end
  end

  defp open_disputed_duty_for_act?(state, act_ref) do
    Enum.any?(state.duties, fn {_cause_key, duty} ->
      duty.class == :disputed_evidence and duty.status == :open and duty.act_ref == act_ref and
        is_nil(duty.attempt_ref)
    end)
  end

  defp cancellation_authority_change(
         state,
         %Act{
           class: "mandate.revoke",
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
         } = cause_act,
         :mandate_revoked
       )
       when map_size(cause_act.consequence) == 1 and map_size(command) == 1 do
    with {:ok, mandate} <- fetch(state.mandates, mandate_ref, :mandate),
         {:ok, revocation} <- Map.fetch(state.revocations, mandate_ref),
         true <- revocation["act_ref"] == cause_act.ref,
         true <- revocation["effective_at"] == cause_act.committed_at do
      {:ok, mandate_ref, mandate.revocation["mode"] == :cascade}
    else
      :error -> {:error, {:dispatch_cancellation_revocation_not_recorded, cause_act.ref}}
      false -> {:error, {:dispatch_cancellation_revocation_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_authority_change(
         state,
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" => %{"predecessor_ref" => predecessor_ref} = command
           }
         } = cause_act,
         :mandate_restricted
       )
       when map_size(cause_act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor_ref} <- Map.fetch(state.mandate_successors, predecessor_ref),
         {:ok, successor} <- fetch(state.mandates, successor_ref, :mandate),
         true <- successor.source_ref == cause_act.ref do
      {:ok, predecessor_ref, true}
    else
      :error -> {:error, {:dispatch_cancellation_restriction_not_recorded, cause_act.ref}}
      false -> {:error, {:dispatch_cancellation_restriction_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_authority_change(_state, cause_act, reason),
    do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref, reason}}

  defp mandate_affected_by_change?(_state, mandate_ref, mandate_ref, _cascade?),
    do: {:ok, true}

  defp mandate_affected_by_change?(_state, _mandate_ref, _target_ref, false),
    do: {:ok, false}

  defp mandate_affected_by_change?(state, mandate_ref, target_ref, true),
    do: mandate_descends_from?(state, mandate_ref, target_ref, MapSet.new())

  defp mandate_descends_from?(_state, target_ref, target_ref, _visited), do: {:ok, true}

  defp mandate_descends_from?(state, mandate_ref, target_ref, visited) do
    cond do
      MapSet.member?(visited, mandate_ref) ->
        {:error, {:mandate_ancestry_cycle, mandate_ref}}

      true ->
        case fetch(state.mandates, mandate_ref, :mandate) do
          {:ok, %Mandate{parent_ref: nil}} ->
            {:ok, false}

          {:ok, %Mandate{parent_ref: parent_ref}} ->
            mandate_descends_from?(
              state,
              parent_ref,
              target_ref,
              MapSet.put(visited, mandate_ref)
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp reservation_ready(state, act) do
    if has_reservations?(act) and Map.get(state.reservation_states, act.ref) != :reserved,
      do: {:error, {:act_reservation_not_ready, act.ref}},
      else: :ok
  end

  defp record_attempt(state, event) do
    with {:ok, attempt} <- decode_record(event, Attempt),
         :ok <- absent(state.attempts, attempt.ref, :attempt),
         {:ok, act} <- fetch(state.acts, attempt.act_ref, :act),
         :ok <- attempt_available(state, act),
         false <- MapSet.member?(state.consumed_nonces, attempt.grant_nonce_digest),
         :ok <- match_attempt(attempt, act),
         :ok <- authority_at(state, act, attempt.started_at) do
      {:ok,
       %{
         state
         | attempts: Map.put(state.attempts, attempt.ref, attempt),
           attempt_meta: Map.put(state.attempt_meta, attempt.ref, event_metadata(event)),
           attempts_by_act: Map.put(state.attempts_by_act, act.ref, attempt.ref),
           consumed_nonces: MapSet.put(state.consumed_nonces, attempt.grant_nonce_digest),
           dispatch_ready: MapSet.delete(state.dispatch_ready, act.ref)
       }}
    else
      true -> {:error, {:grant_nonce_reused, event.data["grant_nonce_digest"]}}
      {:error, _reason} = error -> error
    end
  end

  defp attempt_available(state, act) do
    cond do
      not act.row.attempt ->
        {:error, {:act_not_attemptable, act.ref}}

      not MapSet.member?(state.dispatch_ready, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      has_reservations?(act) and Map.get(state.reservation_states, act.ref) != :reserved ->
        {:error, {:act_reservation_not_attemptable, act.ref}}

      Map.has_key?(state.attempts_by_act, act.ref) ->
        {:error, {:act_already_attempted, act.ref}}

      true ->
        :ok
    end
  end

  defp match_attempt(attempt, act) do
    cond do
      attempt.executor_ref != act.executor_ref ->
        {:error, {:attempt_executor_mismatch, attempt.ref}}

      attempt.material_digest != act.material_digest ->
        {:error, {:attempt_material_mismatch, attempt.ref}}

      attempt.started_at < act.committed_at ->
        {:error, {:attempt_precedes_act, attempt.ref}}

      true ->
        :ok
    end
  end

  defp record_act(state, event) do
    with {:ok, act} <- decode_record(event, Act),
         :ok <- absent(state.acts, act.ref, :act),
         :ok <- Governance.execution_boundary(act),
         {:ok, decision} <- fetch(state.decisions, act.decision_ref, :decision),
         :ok <- act_follows_decision(state, event, act),
         :ok <- one_act_per_decision(state, decision.ref),
         :ok <- match_act_decision(state, act, decision),
         {:ok, candidate} <- rebuild_candidate(act),
         :ok <- candidate_authorized(state, candidate, act, decision) do
      context = %{
        act_ref: act.ref,
        decision_ref: decision.ref,
        mandate_ref: act.mandate_ref,
        ledger_revision: event.revision,
        batch_id: event.batch_id,
        host_profile_ref: act.host_profile_ref,
        host_profile: HostProfile.canonical(state.host_profile),
        surface_ref: state.surface.ref,
        surface_revision: act.surface_revision,
        surface: Surface.canonical(state.surface)
      }

      {:ok,
       %{
         state
         | acts: Map.put(state.acts, act.ref, act),
           act_meta: Map.put(state.act_meta, act.ref, event_metadata(event)),
           acts_by_decision: Map.put(state.acts_by_decision, decision.ref, act.ref),
           act_contexts: Map.put(state.act_contexts, act.ref, context)
       }}
    end
  end

  defp act_follows_decision(state, event, act) do
    case state.last_event do
      %{type: "decision_recorded", identity: decision_ref, batch_id: batch_id}
      when decision_ref == act.decision_ref and batch_id == event.batch_id ->
        :ok

      _other ->
        {:error, {:act_not_immediately_after_decision, act.ref}}
    end
  end

  defp one_act_per_decision(state, decision_ref) do
    if Map.has_key?(state.acts_by_decision, decision_ref),
      do: {:error, {:decision_already_has_act, decision_ref}},
      else: :ok
  end

  defp match_act_decision(state, act, decision) do
    shared_fields = [
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

    mismatch = Enum.find(shared_fields, &(Map.fetch!(decision, &1) != Map.fetch!(act, &1)))
    identity = Map.get(state.candidate_identities, act.candidate_identity_key)
    mandate = Map.get(state.mandates, act.mandate_ref)

    cond do
      decision.outcome != :admitted ->
        {:error, {:act_for_non_admitted_decision, decision.ref}}

      state.revision != decision.authority_revision + 1 ->
        {:error, {:act_not_revision_adjacent_to_decision, act.ref}}

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

  defp rebuild_candidate(act) do
    with {:ok, reservations} <- normalize_amounts_or_empty(act.reservations),
         {:ok, candidate} <-
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
           }) do
      {:ok, candidate}
    else
      {:error, _reason} -> {:error, {:act_candidate_material_mismatch, act.ref}}
    end
  end

  defp candidate_authorized(state, candidate, act, decision) do
    with {:ok, mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
         :ok <- surface_covers(state.surface, candidate, act),
         :ok <- ErasureAnalysis.validate_evidence_available(state, candidate.evidence_refs),
         :ok <- validate_candidate_disclosure(state, candidate),
         {:ok, effective_mandate} <-
           effective_authority_at(state, candidate, act, mandate, act.committed_at),
         {:ok, mandate_basis_refs} <-
           recognition_satisfied(state, candidate, decision, effective_mandate),
         {:ok, presentation_basis_refs} <- presentation_satisfied(state, candidate, act),
         :ok <-
           exact_recognition_basis(
             decision,
             mandate_basis_refs ++ presentation_basis_refs
           ),
         :ok <-
           reservation_plan_valid(state, candidate, act, decision, effective_mandate) do
      :ok
    end
  end

  defp validate_candidate_disclosure(_state, %Candidate{disclosure: nil}), do: :ok

  defp validate_candidate_disclosure(state, %Candidate{disclosure: disclosure}),
    do: Disclosure.verify_sources(disclosure, state.evidence)

  defp surface_covers(surface, candidate, act) do
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

  defp authority_at(state, act, time) do
    with {:ok, candidate} <- rebuild_candidate(act),
         {:ok, mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
         {:ok, _effective_mandate} <-
           effective_authority_at(state, candidate, act, mandate, time) do
      :ok
    end
  end

  defp effective_authority_at(state, candidate, act, mandate, time) do
    context = %{
      domain_ref: state.domain_ref,
      scope_ref: act.scope_ref,
      authenticated_principal_ref: act.authenticated_principal_ref,
      authentication_ref: act.authentication_ref,
      ingress_ref: act.ingress_ref,
      host_generation: act.host_generation
    }

    view =
      state
      |> authority_view()
      |> Map.put(:host_generation, act.host_generation)

    case Authority.authorize(candidate, context, mandate, view, time) do
      {:ok, effective_mandate} -> {:ok, effective_mandate}
      {:error, reason} -> {:error, {:act_without_current_authority, act.ref, reason}}
    end
  end

  defp authority_view(state) do
    %{
      mandates: state.mandates,
      mandate_successors: state.mandate_successors,
      mandate_predecessors: state.mandate_predecessors,
      revocations: state.revocations,
      blocked_mandate_refs: blocked_mandate_refs(state),
      blocked_effect_digests: blocked_effect_digests(state)
    }
  end

  defp recognition_satisfied(state, candidate, decision, mandate) do
    expected_refs = mandate.conditions |> Enum.map(& &1.ref) |> Enum.sort()

    available_evidence =
      state
      |> ErasureAnalysis.available_evidence()
      |> Map.values()

    {recognition, basis_refs} =
      Recognition.check_with_basis(mandate.conditions, available_evidence, decision.decided_at)

    with true <- decision.recognition_refs == expected_refs,
         {:ok, _declared_evidence} <-
           fetch_many(state.evidence, candidate.evidence_refs, :evidence),
         :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs),
         :satisfied <- recognition do
      {:ok, basis_refs}
    else
      false -> {:error, {:decision_recognition_refs_mismatch, decision.ref}}
      {:error, _reason} = error -> error
      result -> {:error, {:act_recognition_not_satisfied, candidate.ref, result}}
    end
  end

  defp presentation_satisfied(
         state,
         %Candidate{class: "presentation.show"} = candidate,
         act
       ) do
    with {:ok, presentation_ref} <- Presentation.show_presentation_ref(candidate.consequence),
         {:ok, presentation} <- fetch(state.presentations, presentation_ref, :presentation),
         :ok <- Presentation.validate_show(candidate, presentation),
         :ok <- Presentation.validate_show(act, presentation),
         true <- presentation.prepared_at <= act.committed_at do
      {:ok, []}
    else
      false -> {:error, {:act_presentation_show_precedes_preparation, act.ref}}
      {:error, reason} -> {:error, {:invalid_presentation_show_act, act.ref, reason}}
    end
  end

  defp presentation_satisfied(_state, %Candidate{presentation_ref: nil}, %Act{
         presentation_ref: nil
       }),
       do: {:ok, []}

  defp presentation_satisfied(state, candidate, act) do
    with {:ok, presentation} <- fetch(state.presentations, act.presentation_ref, :presentation),
         :ok <- Presentation.validate_candidate(candidate, presentation),
         true <- presentation.prepared_at <= act.committed_at,
         {:ok, approval_refs, basis_refs} <- presentation_approval(state, presentation, act),
         true <-
           presentation.candidate_binding_ref ==
             Candidate.presentation_binding_ref(candidate, approval_refs),
         :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs) do
      {:ok, basis_refs}
    else
      false -> {:error, {:act_presentation_binding_mismatch, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp presentation_approval(state, presentation, act) do
    evidence = state |> ErasureAnalysis.available_evidence() |> Map.values()
    matching = Enum.filter(evidence, &approval_for_presentation?(&1, presentation.ref))

    current =
      Enum.reduce(matching, [], fn approval, valid ->
        case presentation_approval_basis(
               approval,
               presentation,
               state,
               evidence,
               act.committed_at
             ) do
          {:ok, basis_refs} -> [{approval, basis_refs} | valid]
          :invalid -> valid
        end
      end)

    cond do
      Enum.any?(current, fn {approval, _basis} -> approval.stance == :contradicts end) ->
        {:error, {:act_presentation_approval_contradicted, act.ref}}

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
        {:error, {:act_presentation_approval_missing, act.ref}}

      true ->
        {:error, {:act_presentation_approval_not_current_or_final, act.ref}}
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

  defp presentation_approval_basis(approval, presentation, state, evidence, time) do
    with {:ok, _presentation_ref, show_act_ref} <- Presentation.approval_refs(approval),
         {:ok, show_act} <- fetch(state.acts, show_act_ref, :act),
         {:ok, basis_refs} <-
           Presentation.validate_response_with_basis(
             approval,
             presentation,
             show_act,
             Map.values(state.outcomes),
             evidence,
             time
           ) do
      {:ok, basis_refs}
    else
      _invalid -> :invalid
    end
  end

  defp exact_recognition_basis(decision, basis_refs) do
    expected = basis_refs |> Enum.uniq() |> Enum.sort()

    if decision.recognition_evidence_refs == expected,
      do: :ok,
      else: {:error, {:decision_recognition_evidence_refs_mismatch, decision.ref}}
  end

  defp reservation_plan_valid(state, candidate, act, decision, mandate) do
    requests = candidate.meter_requests

    cond do
      map_size(requests) > 0 and not act.row.spend ->
        {:error, {:act_meter_request_not_declared_in_row, act.ref}}

      map_size(requests) == 0 and act.row.spend ->
        {:error, {:act_spend_without_meter_request, act.ref}}

      Enum.any?(Map.keys(requests), &(not Map.has_key?(mandate.meters, &1))) ->
        {:error, {:act_meter_outside_mandate, act.ref}}

      true ->
        with {:ok, declared} <- normalize_amounts_or_empty(decision.reservations),
             true <- declared == requests,
             {:ok, accounts} <- fetch_meter_accounts(state, mandate.ref),
             {:ok, planned} <- Meter.plan_reservations(requests, accounts),
             true <- reservation_map(planned) == requests do
          :ok
        else
          false -> {:error, {:act_reservation_plan_mismatch, act.ref}}
          {:error, reason} -> {:error, {:act_invalid_reservation_plan, act.ref, reason}}
        end
    end
  end

  defp reservation_map(reservations) do
    Map.new(reservations, fn reservation ->
      {Map.fetch!(reservation, :meter_ref), Map.fetch!(reservation, :quantity)}
    end)
  end

  defp record_outcome(state, event) do
    with {:ok, outcome} <- decode_record(event, Outcome),
         :ok <- absent(state.outcomes, outcome.ref, :outcome),
         {:ok, attempt} <- fetch(state.attempts, outcome.attempt_ref, :attempt),
         {:ok, act} <- fetch(state.acts, outcome.act_ref, :act),
         true <- attempt.act_ref == outcome.act_ref,
         true <- Map.get(state.attempts_by_act, outcome.act_ref) == attempt.ref,
         true <- outcome.observed_at >= attempt.started_at,
         :ok <- validate_erasure_outcome(act, outcome),
         :ok <- valid_outcome_transition(state, outcome),
         :ok <- ErasureAnalysis.validate_evidence_available(state, outcome.evidence_refs),
         {:ok, evidence} <- fetch_many(state.evidence, outcome.evidence_refs, :evidence),
         :ok <- validate_outcome_evidence(outcome, evidence, attempt, act) do
      {:ok,
       %{
         state
         | outcomes: Map.put(state.outcomes, outcome.ref, outcome),
           outcome_meta: Map.put(state.outcome_meta, outcome.ref, event_metadata(event))
       }}
    else
      false -> {:error, {:outcome_causal_mismatch, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_erasure_outcome(%Act{class: "data.erase"}, %Outcome{status: :failed}),
    do: {:error, :erasure_failure_must_be_definitive_or_ambiguous}

  defp validate_erasure_outcome(_act, _outcome), do: :ok

  defp validate_outcome_evidence(outcome, evidence, attempt, act) do
    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      result = Attestation.validate(item, outcome, attempt, act)

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_outcome_transition(state, outcome) do
    prior = Enum.filter(Map.values(state.outcomes), &(&1.attempt_ref == outcome.attempt_ref))

    if Outcome.correction?(outcome) do
      validate_outcome_correction(prior, outcome)
    else
      case Enum.find(prior, &(&1.status != :ambiguous)) do
        nil ->
          :ok

        terminal ->
          {:error, {:attempt_already_has_definitive_outcome, outcome.attempt_ref, terminal.ref}}
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

  defp record_duty(state, event) do
    with {:ok, duty} <- decode_record(event, Duty),
         true <- duty.status == :open and is_nil(duty.disposition_act_ref),
         :ok <- absent(state.duties, duty.cause_key, :duty_cause),
         :ok <- absent(state.duty_refs, duty.ref, :duty),
         {:ok, _evidence} <- fetch_many(state.evidence, duty.evidence_refs, :evidence),
         :ok <- duty_causal_records(state, duty),
         {:ok, required_cause} <- required_duty_cause_at_prefix(state, duty, event.recorded_at),
         :ok <- validate_builtin_duty(state, duty) do
      required_duty_causes =
        Map.put_new(state.required_duty_causes, required_cause.cause_key, required_cause)

      {:ok,
       %{
         state
         | duties: Map.put(state.duties, duty.cause_key, duty),
           duty_refs: Map.put(state.duty_refs, duty.ref, duty.cause_key),
           required_duty_causes: required_duty_causes
       }}
    else
      false -> {:error, {:duty_opened_in_terminal_state, event.identity}}
      {:error, _reason} = error -> error
    end
  end

  defp required_duty_cause_at_prefix(state, duty, recorded_at) do
    cause =
      state
      |> Derive.required_duties(state.constitution, recorded_at)
      |> Enum.find(&(&1.cause_key == duty.cause_key))

    case cause do
      nil ->
        {:error, {:duty_cause_not_required_at_prefix, duty.ref}}

      cause ->
        with {:ok, expected} <- expected_duty(cause, recorded_at),
             true <- duty_cause_matches?(duty, expected) do
          {:ok, cause}
        else
          false -> {:error, {:duty_cause_materialization_mismatch, duty.ref}}
          {:error, reason} -> {:error, {:invalid_required_duty, duty.cause_key, reason}}
        end
    end
  end

  defp duty_causal_records(state, duty) do
    with {:ok, act} <- optional_fetch(state.acts, duty.act_ref, :act),
         {:ok, attempt} <- optional_fetch(state.attempts, duty.attempt_ref, :attempt),
         :ok <- match_optional_attempt(attempt, duty.act_ref) do
      match_duty_act(duty, act)
    end
  end

  defp match_optional_attempt(nil, _act_ref), do: :ok

  defp match_optional_attempt(attempt, act_ref) do
    if attempt.act_ref == act_ref,
      do: :ok,
      else: {:error, {:duty_attempt_act_mismatch, attempt.ref, act_ref}}
  end

  defp match_duty_act(_duty, nil), do: :ok

  defp match_duty_act(duty, act) do
    cond do
      duty.mandate_ref != act.mandate_ref ->
        {:error, {:duty_mandate_mismatch, duty.ref}}

      duty.subjects != act.subject_refs ->
        {:error, {:duty_subjects_mismatch, duty.ref}}

      duty.accountable != act.accountable_ref ->
        {:error, {:duty_accountable_mismatch, duty.ref}}

      true ->
        :ok
    end
  end

  defp validate_builtin_duty(
         state,
         %Duty{
           class: :ambiguous_outcome,
           cause_key: {:ambiguous_outcome, act_ref, attempt_ref}
         } = duty
       ) do
    deadline_reached? =
      with {:ok, attempt} <- Map.fetch(state.attempts, attempt_ref),
           {:ok, act} <- Map.fetch(state.acts, act_ref) do
        duty.opened_at >= attempt.started_at + act.observation_window_ms
      else
        :error -> false
      end

    ambiguous_outcome? =
      Enum.any?(state.outcomes, fn {_ref, outcome} ->
        outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref and
          outcome.status == :ambiguous and outcome.observed_at <= duty.opened_at
      end)

    safe_containment? =
      case Map.fetch(state.acts, act_ref) do
        {:ok, act} -> valid_builtin_duty_containment?(duty, act)
        :error -> false
      end

    if duty.act_ref == act_ref and duty.attempt_ref == attempt_ref and
         (deadline_reached? or ambiguous_outcome?) and safe_containment?,
       do: :ok,
       else: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}
  end

  defp validate_builtin_duty(
         state,
         %Duty{
           class: :contradicted_outcome,
           cause_key: {:contradicted_outcome, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, outcome} <- Map.fetch(state.outcomes, outcome_ref),
         {:ok, act} <- Map.fetch(state.acts, act_ref),
         true <- outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref,
         true <- Outcome.correction?(outcome) and outcome.observed_at <= duty.opened_at,
         {:ok, corrected} <- Map.fetch(state.outcomes, outcome.contradicts_outcome_ref),
         true <- corrected.status == :definitive_no_effect,
         true <- duty.act_ref == act_ref and duty.attempt_ref == attempt_ref,
         true <- valid_builtin_duty_containment?(duty, act) do
      :ok
    else
      _missing_or_mismatch -> {:error, {:invalid_contradicted_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_duty(_state, %Duty{class: :ambiguous_outcome} = duty),
    do: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}

  defp validate_builtin_duty(_state, %Duty{class: :contradicted_outcome} = duty),
    do: {:error, {:invalid_contradicted_duty_cause, duty.ref}}

  defp validate_builtin_duty(_state, %Duty{class: :disputed_evidence}), do: :ok

  defp validate_builtin_duty(
         state,
         %Duty{
           class: :scope_promise_overdue,
           cause_key: {:scope_promise_overdue, scope_ref}
         } = duty
       ) do
    case Map.fetch(state.scopes, scope_ref) do
      {:ok, %Opening{} = opening} ->
        source_act = Map.get(state.acts, opening.source_act_ref)
        timely_evidence = Derive.available_evidence_at(state, opening.due_at)

        valid? =
          opening.kind in [:work, :vigil] and duty.act_ref == opening.source_act_ref and
            is_nil(duty.attempt_ref) and not is_nil(source_act) and
            duty.mandate_ref == source_act.mandate_ref and
            duty.subjects == source_act.subject_refs and
            duty.accountable == opening.accountable_ref and
            duty.disposition_authority_refs == opening.disposition_authority_refs and
            duty.closing_conditions == [Condition.canonical(opening.promise_condition)] and
            duty.opened_at >= opening.due_at and
            Recognition.check([opening.promise_condition], timely_evidence, opening.due_at) !=
              :satisfied

        if valid?,
          do: :ok,
          else: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

      :error ->
        {:error, {:scope_promise_duty_scope_not_found, duty.ref, scope_ref}}
    end
  end

  defp validate_builtin_duty(
         state,
         %Duty{
           class: :erasure_reduces_verifiability,
           cause_key:
             {:erasure_reduces_verifiability, erasure_ref, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, erasure} <- Map.fetch(state.erasures, erasure_ref),
         {:ok, act} <- Map.fetch(state.acts, act_ref),
         {:ok, attempt} <- Map.fetch(state.attempts, attempt_ref),
         {:ok, outcome} <- Map.fetch(state.outcomes, outcome_ref),
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

  defp validate_builtin_duty(_state, %Duty{class: :scope_promise_overdue} = duty),
    do: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

  defp validate_builtin_duty(
         _state,
         %Duty{class: :erasure_reduces_verifiability} = duty
       ),
       do: {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}

  defp validate_builtin_duty(_state, %Duty{class: class} = duty) when is_binary(class),
    do: {:error, {:application_duty_requires_canonical_cause, duty.ref, class}}

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

  defp dispose_duty(state, event) do
    cause_key = Map.fetch!(event.data, "cause_key")
    act_ref = Map.fetch!(event.data, "disposition_act_ref")

    with {:ok, %Duty{status: :open} = duty} <- fetch(state.duties, cause_key, :duty_cause),
         {:ok, act} <- fetch(state.acts, act_ref, :act),
         :ok <- same_act_batch(state, act, event, :duty_disposition),
         {:ok, disposition} <- Disposition.from_consequence(act.consequence),
         {:ok, _supporting} <- validate_duty_disposition(state, act, duty, disposition),
         :ok <- validate_duty_meter_disposed(state, duty, disposition, act.ref),
         {:ok, disposed} <- Duty.new(%{duty | status: :disposed, disposition_act_ref: act.ref}) do
      {:ok, %{state | duties: Map.put(state.duties, cause_key, disposed)}}
    end
  end

  defp validate_duty_disposition(state, act, duty, disposition) do
    with :ok <- validate_disposition_act(act, duty),
         :ok <- validate_disposition_binding(duty, disposition),
         {:ok, supporting} <- disposition_support(state, disposition, act),
         :ok <- validate_disposition_authority(state, act, duty, disposition),
         :ok <- validate_disposition_basis(state, act, duty, disposition, supporting) do
      {:ok, supporting}
    end
  end

  defp validate_disposition_authority(_state, _act, _duty, %Disposition{kind: :condition_met}),
    do: :ok

  defp validate_disposition_authority(state, act, duty, disposition) do
    if Disposition.discretionary?(disposition) do
      DutyAuthority.validate(
        duty,
        act,
        duty_cause_act(state, duty),
        state.principals,
        state.mandates
      )
    else
      :ok
    end
  end

  defp duty_cause_act(state, %Duty{act_ref: act_ref}) when is_binary(act_ref),
    do: Map.get(state.acts, act_ref)

  defp duty_cause_act(
         state,
         %Duty{class: :scope_promise_overdue, cause_key: {:scope_promise_overdue, scope_ref}}
       ) do
    case Map.get(state.scopes, scope_ref) do
      %Opening{source_act_ref: act_ref} -> Map.get(state.acts, act_ref)
      _missing -> nil
    end
  end

  defp duty_cause_act(_state, _duty), do: nil

  defp validate_disposition_act(act, duty) do
    cond do
      act.class != "duty.dispose" ->
        {:error, {:duty_disposition_act_class_mismatch, act.ref}}

      not exact_row?(act.row, [:govern]) ->
        {:error, {:duty_disposition_act_row_mismatch, act.ref}}

      has_reservations?(act) ->
        {:error, {:duty_disposition_act_has_reservations, act.ref}}

      not act_targets?(act, [duty.ref]) ->
        {:error, {:duty_disposition_target_missing, act.ref, duty.ref}}

      act.ref == duty.act_ref ->
        {:error, {:duty_cause_act_cannot_dispose, duty.ref}}

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

      disposition.opening_digest != Duty.digest(duty) ->
        {:error, {:duty_disposition_opening_mismatch, duty.ref}}

      true ->
        :ok
    end
  end

  defp disposition_support(state, disposition, act) do
    Enum.reduce_while(disposition.supporting_refs, {:ok, []}, fn ref, {:ok, records} ->
      with {:ok, record} <- supporting_record(state, ref),
           :ok <- support_frozen_and_available(state, act, ref, record),
           true <- support_available_at?(record, act.committed_at) do
        {:cont, {:ok, [record | records]}}
      else
        false -> {:halt, {:error, {:duty_disposition_support_from_future, ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp support_frozen_and_available(state, act, ref, {:evidence, _evidence}) do
    if ref in act.evidence_refs,
      do: ErasureAnalysis.validate_evidence_available(state, [ref]),
      else: {:error, {:duty_disposition_evidence_not_frozen, act.ref, ref}}
  end

  defp support_frozen_and_available(_state, _act, _ref, {_kind, _record}), do: :ok

  defp supporting_record(state, ref) do
    matches =
      [
        {:evidence, Map.get(state.evidence, ref)},
        {:outcome, Map.get(state.outcomes, ref)},
        {:act, Map.get(state.acts, ref)}
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
         state,
         act,
         duty,
         %Disposition{kind: :condition_met},
         supporting
       ) do
    if Enum.any?(
         duty.closing_conditions,
         &closing_condition_met?(state, &1, supporting, act.committed_at)
       ),
       do: :ok,
       else: {:error, {:duty_closing_condition_not_met, duty.ref}}
  end

  defp validate_disposition_basis(_state, act, duty, disposition, _supporting) do
    if Disposition.discretionary?(disposition),
      do: :ok,
      else: {:error, {:invalid_duty_disposition_kind, disposition.kind, act.ref, duty.ref}}
  end

  defp closing_condition_met?(
         state,
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
          outcome_not_corrected_at?(state, outcome, committed_at)

      _other ->
        false
    end)
  end

  defp closing_condition_met?(state, condition, supporting, committed_at) do
    available_evidence = state |> ErasureAnalysis.available_evidence() |> Map.values()
    supporting_refs = for {:evidence, item} <- supporting, do: item.ref

    with {:ok, condition} <- Condition.new(condition),
         {:satisfied, basis_refs} <-
           Recognition.check_with_basis([condition], available_evidence, committed_at) do
      basis_refs -- supporting_refs == []
    else
      _not_satisfied_or_invalid -> false
    end
  end

  defp resolve_duty_meter(state, event) do
    disposition_act_ref = event.data["disposition_act_ref"]
    duty_ref = event.data["duty_ref"]
    cause_act_ref = event.data["act_ref"]
    mandate_ref = event.data["mandate_ref"]
    operation = event.data["operation"]

    with true <- operation in [:settle, :release],
         {:ok, amounts} <- normalize_amounts_or_empty(event.data["amounts"]),
         :ok <- duty_meter_resolution_absent(state, disposition_act_ref),
         {:ok, duty} <- fetch_duty_by_ref(state, duty_ref),
         true <- duty.status == :open,
         true <- duty.act_ref == cause_act_ref,
         {:ok, disposition_act} <- fetch(state.acts, disposition_act_ref, :act),
         :ok <- same_act_batch(state, disposition_act, event, :duty_meter_resolution),
         {:ok, disposition} <- Disposition.from_consequence(disposition_act.consequence),
         {:ok, supporting} <-
           validate_duty_disposition(state, disposition_act, duty, disposition),
         true <- disposition.meter_resolution == operation,
         {:ok, cause_act} <- fetch(state.acts, cause_act_ref, :act),
         true <- cause_act.mandate_ref == mandate_ref,
         true <- cause_act.reservations not in [%{}, []],
         {:ok, :suspended} <- fetch(state.reservation_states, cause_act.ref, :reservation),
         {:ok, binding} <-
           fetch(state.reservation_bindings, cause_act.ref, :reservation_binding),
         :ok <- match_duty_meter_binding(binding, cause_act, mandate_ref),
         {:ok, expected_amounts, recontainment} <-
           expected_duty_meter_amounts(state, cause_act, duty),
         true <- amounts == expected_amounts,
         :ok <-
           validate_duty_meter_resolution(
             state,
             operation,
             supporting,
             cause_act,
             duty,
             disposition_act.committed_at
           ),
         {:ok, accounts} <- fetch_meter_accounts(state, mandate_ref),
         {:ok, accounts} <- move_accounts(accounts, amounts, operation, :suspended),
         {:ok, state} <- put_meter_accounts(state, mandate_ref, accounts) do
      resolution = %{
        act_ref: cause_act.ref,
        disposition_act_ref: disposition_act.ref,
        duty_ref: duty.ref,
        mandate_ref: mandate_ref,
        operation: operation,
        amounts: amounts
      }

      state =
        state
        |> put_duty_meter_resolution(resolution)
        |> put_resolved_recontainment(recontainment, disposition_act.ref)

      {:ok,
       %{
         state
         | reservation_states:
             Map.put(state.reservation_states, cause_act.ref, resolution_status(operation))
       }}
    else
      false ->
        {:error, {:invalid_duty_meter_resolution_event, disposition_act_ref}}

      {:ok, status} ->
        {:error, {:duty_meter_resolution_requires_suspension, cause_act_ref, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp duty_meter_resolution_absent(state, disposition_act_ref) do
    if Map.has_key?(state.duty_meter_resolutions, disposition_act_ref),
      do: {:error, {:duplicate_duty_meter_resolution, disposition_act_ref}},
      else: :ok
  end

  defp fetch_duty_by_ref(state, duty_ref) do
    with {:ok, cause_key} <- fetch(state.duty_refs, duty_ref, :duty_ref),
         {:ok, duty} <- fetch(state.duties, cause_key, :duty_cause) do
      {:ok, duty}
    end
  end

  defp match_duty_meter_binding(binding, cause_act, mandate_ref) do
    with true <- binding.act_ref == cause_act.ref,
         true <- binding.mandate_ref == mandate_ref,
         {:ok, declared} <- normalize_amounts(cause_act.reservations),
         true <- binding.amounts == declared do
      :ok
    else
      false -> {:error, {:duty_meter_reservation_binding_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp expected_duty_meter_amounts(state, cause_act, duty) do
    case Map.get(state.meter_recontainments, cause_act.ref) do
      nil ->
        with {:ok, binding} <-
               fetch(state.reservation_bindings, cause_act.ref, :reservation_binding) do
          {:ok, binding.amounts, nil}
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

  defp put_duty_meter_resolution(state, resolution) do
    %{
      state
      | duty_meter_resolutions:
          Map.put(state.duty_meter_resolutions, resolution.disposition_act_ref, resolution)
    }
  end

  defp put_resolved_recontainment(state, nil, _disposition_act_ref), do: state

  defp put_resolved_recontainment(state, record, disposition_act_ref) do
    updated = %{record | status: :disposed, disposition_act_ref: disposition_act_ref}

    %{
      state
      | meter_recontainments: Map.put(state.meter_recontainments, record.act_ref, updated)
    }
  end

  defp validate_duty_meter_disposed(state, %Duty{act_ref: nil} = duty, disposition, act_ref) do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(state.duty_meter_resolutions, act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, act_ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed(state, duty, disposition, disposition_act_ref) do
    with {:ok, cause_act} <- fetch(state.acts, duty.act_ref, :act) do
      validate_duty_meter_disposed_for_act(
        state,
        duty,
        cause_act,
        disposition,
        disposition_act_ref
      )
    end
  end

  defp validate_duty_meter_disposed_for_act(
         state,
         duty,
         %Act{reservations: reservations} = cause_act,
         disposition,
         disposition_act_ref
       )
       when reservations in [%{}, []] do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(state.reservation_states, cause_act.ref) ->
        {:error, {:unexpected_duty_reservation_state, cause_act.ref}}

      Map.has_key?(state.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed_for_act(
         state,
         duty,
         cause_act,
         %{meter_resolution: :none},
         disposition_act_ref
       ) do
    recontainment = Map.get(state.meter_recontainments, cause_act.ref)

    cond do
      Map.has_key?(state.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      Map.get(state.reservation_states, cause_act.ref) == :suspended and
        match?(%{status: :open}, recontainment) and
          recontainment.cause_key != duty.cause_key ->
        :ok

      Map.get(state.reservation_states, cause_act.ref) not in [:settled, :released] ->
        {:error, {:duty_meter_not_resolved, cause_act.ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed_for_act(
         state,
         duty,
         cause_act,
         disposition,
         disposition_act_ref
       ) do
    expected_status = resolution_status(disposition.meter_resolution)

    with {:ok, resolution} <-
           fetch(
             state.duty_meter_resolutions,
             disposition_act_ref,
             :duty_meter_resolution
           ),
         true <- resolution.act_ref == cause_act.ref,
         true <- resolution.duty_ref == duty.ref,
         true <- resolution.mandate_ref == cause_act.mandate_ref,
         true <- resolution.operation == disposition.meter_resolution,
         true <- Map.get(state.reservation_states, cause_act.ref) == expected_status,
         :ok <-
           validate_resolved_recontainment(
             state,
             cause_act.ref,
             duty.cause_key,
             disposition_act_ref
           ) do
      :ok
    else
      false -> {:error, {:duty_meter_resolution_binding_mismatch, disposition_act_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_resolved_recontainment(state, cause_act_ref, cause_key, disposition_act_ref) do
    case Map.get(state.meter_recontainments, cause_act_ref) do
      nil ->
        :ok

      %{status: :disposed, cause_key: ^cause_key, disposition_act_ref: ^disposition_act_ref} ->
        :ok

      _invalid ->
        {:error, {:meter_recontainment_not_resolved, cause_act_ref}}
    end
  end

  defp resolution_status(:settle), do: :settled
  defp resolution_status(:release), do: :released

  defp validate_duty_meter_resolution(
         _state,
         :settle,
         _supporting,
         _cause_act,
         _duty,
         _committed_at
       ),
       do: :ok

  defp validate_duty_meter_resolution(
         state,
         :release,
         supporting,
         cause_act,
         duty,
         committed_at
       ) do
    if Enum.any?(supporting, fn
         {:outcome, %Outcome{status: :definitive_no_effect} = outcome} ->
           outcome.act_ref == cause_act.ref and
             (is_nil(duty.attempt_ref) or outcome.attempt_ref == duty.attempt_ref) and
             outcome_not_corrected_at?(state, outcome, committed_at)

         _other ->
           false
       end),
       do: :ok,
       else: {:error, :duty_meter_release_not_proven}
  end

  defp outcome_not_corrected_at?(state, outcome, committed_at) do
    not Enum.any?(state.outcomes, fn {_ref, candidate} ->
      candidate.contradicts_outcome_ref == outcome.ref and
        candidate.observed_at <= committed_at
    end)
  end

  defp validate_batch(before, state, events) do
    with :ok <- validate_dispatch_expiration_batch(before, events),
         :ok <- validate_admission_batch(before, state, events),
         :ok <- validate_suspension_batch(state, events),
         :ok <- validate_recontainment_batch(events),
         :ok <- validate_duty_meter_resolution_batch(events) do
      validate_required_recontainments(before, events)
    else
      {:error, reason} -> {:batch_error, hd(events).revision, reason}
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

  defp expired_pending_dispatches(state, recorded_at) do
    state.dispatch_ready
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, expired} ->
      with {:ok, act} <- fetch(state.acts, act_ref, :act),
           {:ok, mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
           true <- act.row.attempt,
           true <- act.mandate_revision == mandate.revision,
           false <- Map.has_key?(state.attempts_by_act, act.ref),
           false <- Map.has_key?(state.dispatch_cancellations, act.ref) do
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
        case normalize_amounts_or_empty(act.reservations) do
          {:ok, amounts} when map_size(amounts) > 0 ->
            release =
              {"meter_released", "meter_released:" <> act.ref,
               %{
                 "act_ref" => act.ref,
                 "mandate_ref" => mandate.ref,
                 "amounts" => amounts
               }}

            {:cont, {:ok, events ++ [expiration, release]}}

          {:ok, _empty} ->
            {:halt, {:error, {:empty_meter_reservation, act.ref}}}

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
    |> Enum.filter(&(&1.type == "dispatch_cancelled" and &1.data["reason"] == :mandate_expired))
    |> Enum.sort_by(& &1.batch_index)
    |> Enum.map(& &1.data["act_ref"])
  end

  defp exact_event_sequence?(events, expected, first_index) do
    expected
    |> Enum.with_index(first_index)
    |> Enum.all?(fn {{type, identity, data}, index} ->
      exact_event_at?(events, index, type, identity, data)
    end)
  end

  defp validate_admission_batch(before, state, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "decision_recorded" ->
            complete_decision_batch(state, events, event)

          "act_committed" ->
            complete_act_batch(before, state, events, event)

          "dispatch_cancelled" ->
            complete_dispatch_cancellation_batch(events, event)

          "duty_opened" ->
            complete_disputed_dispatch_cancellation_batch(before, state, events, event)

          _other ->
            :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp complete_decision_batch(state, events, event) do
    decision = Map.fetch!(state.decisions, event.identity)

    acts =
      Enum.filter(events, fn candidate ->
        candidate.type == "act_committed" and
          Map.get(candidate.data, "decision_ref") == decision.ref
      end)

    case {decision.outcome, acts} do
      {:admitted, [%{batch_index: index}]} when index == event.batch_index + 1 -> :ok
      {:admitted, _other} -> {:error, {:admitted_decision_batch_incomplete, decision.ref}}
      {_not_admitted, []} -> :ok
      {_not_admitted, _acts} -> {:error, {:non_admitted_decision_has_act, decision.ref}}
    end
  end

  defp complete_act_batch(before, state, events, event) do
    act = Map.fetch!(state.acts, event.identity)
    reservation_events = events_for_act(events, "meter_reserved", act.ref)
    dispatch_events = events_for_act(events, "dispatch_ready", act.ref)

    cond do
      has_reservations?(act) and length(reservation_events) != 1 ->
        {:error, {:act_reservation_batch_incomplete, act.ref}}

      not has_reservations?(act) and reservation_events != [] ->
        {:error, {:act_has_unexpected_reservation, act.ref}}

      act.row.attempt and length(dispatch_events) != 1 ->
        {:error, {:act_dispatch_batch_incomplete, act.ref}}

      not act.row.attempt and dispatch_events != [] ->
        {:error, {:internal_act_has_dispatch, act.ref}}

      Enum.any?(reservation_events ++ dispatch_events, &(&1.batch_index <= event.batch_index)) ->
        {:error, {:admission_effect_precedes_act, act.ref}}

      true ->
        governance_effect_complete(before, state, events, act, event.batch_index)
    end
  end

  defp governance_effect_complete(before, state, events, act, act_index) do
    case governance_effect_adjacent?(events, act, act_index) do
      true -> validate_authority_cancellation_batch(before, state, events, act, act_index)
      false -> {:error, {:governance_act_batch_incomplete, act.ref, act.class}}
      :unsupported -> {:error, {:unsupported_governance_act_class, act.ref, act.class}}
    end
  end

  defp complete_dispatch_cancellation_batch(events, event) do
    cause_ref = event.data["cause_ref"]

    case event.data["reason"] do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        if Enum.any?(events, fn candidate ->
             candidate.type == "act_committed" and candidate.identity == cause_ref
           end),
           do: :ok,
           else: {:error, {:dispatch_cancellation_outside_governance_batch, event.identity}}

      :disputed_evidence ->
        case event_at(events, event.batch_index - 1) do
          %{type: "duty_opened", identity: ^cause_ref, data: duty_data} ->
            with {:ok, duty} <- Duty.from_canonical(duty_data),
                 true <- duty.class == :disputed_evidence,
                 true <- duty.act_ref == event.data["act_ref"],
                 true <- is_nil(duty.attempt_ref),
                 true <- duty.mandate_ref == event.data["mandate_ref"] do
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

  defp complete_disputed_dispatch_cancellation_batch(before, state, events, event) do
    with {:ok, duty} <- Duty.from_canonical(event.data) do
      if duty.class == :disputed_evidence and
           MapSet.member?(
             pending_dispatch_refs_before(before, events, event.batch_index),
             duty.act_ref
           ) do
        with {:ok, act} <- fetch(state.acts, duty.act_ref, :act),
             true <-
               exact_event_at?(
                 events,
                 event.batch_index + 1,
                 "dispatch_cancelled",
                 "dispatch_cancelled:" <> act.ref,
                 %{
                   "act_ref" => act.ref,
                   "mandate_ref" => act.mandate_ref,
                   "cause_ref" => duty.ref,
                   "reason" => :disputed_evidence,
                   "cancelled_at" => duty.opened_at
                 }
               ),
             true <- exact_cancellation_release?(events, event.batch_index + 2, act) do
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

  defp exact_cancellation_release?(events, index, act) do
    if has_reservations?(act) do
      with {:ok, amounts} <- normalize_amounts_or_empty(act.reservations),
           true <- map_size(amounts) > 0 do
        exact_event_at?(events, index, "meter_released", "meter_released:" <> act.ref, %{
          "act_ref" => act.ref,
          "mandate_ref" => act.mandate_ref,
          "amounts" => amounts
        })
      else
        _invalid -> false
      end
    else
      true
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{class: "mandate.delegate", consequence: %{"mandate_issue" => draft}} = act,
         index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, mandate} <- Mandate.from_issue_draft(draft, act.ref) do
      exact_record_event_at?(events, index + 1, "mandate_issued", Mandate, mandate)
    else
      {:error, _reason} -> false
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" =>
               %{"predecessor_ref" => predecessor_ref, "successor" => draft} = command
           }
         } = act,
         index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor} <- Mandate.from_issue_draft(draft, act.ref) do
      exact_event_at?(events, index + 1, "mandate_restricted", successor.ref, %{
        "act_ref" => act.ref,
        "predecessor_ref" => predecessor_ref,
        "successor" => Mandate.canonical(successor)
      })
    else
      {:error, _reason} -> false
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{
           class: "mandate.revoke",
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
         } = act,
         index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 1 do
    exact_event_at?(events, index + 1, "mandate_revoked", act.ref, %{
      "mandate_ref" => mandate_ref,
      "effective_at" => act.committed_at
    })
  end

  defp governance_effect_adjacent?(
         events,
         %Act{
           class: "mandate.devolve",
           consequence: %{
             "mandate_devolve" =>
               %{"child_mandate_ref" => child_ref, "amounts" => amounts} = command
           }
         } = act,
         index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    exact_event_at?(events, index + 1, "meter_devolved", "meter_devolved:" <> act.ref, %{
      "act_ref" => act.ref,
      "child_mandate_ref" => child_ref,
      "amounts" => amounts
    })
  end

  defp governance_effect_adjacent?(
         events,
         %Act{
           class: "surface.revise",
           consequence: %{
             "surface_revision" =>
               %{"previous_ref" => previous_ref, "surface" => canonical} = command
           }
         } = act,
         index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, surface} <- Surface.from_canonical(canonical) do
      exact_event_at?(events, index + 1, "surface_revised", surface.ref, %{
        "act_ref" => act.ref,
        "previous_ref" => previous_ref,
        "surface" => Surface.canonical(surface)
      })
    else
      {:error, _reason} -> false
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{
           class: "host_profile.revise",
           consequence: %{
             "host_profile_revision" =>
               %{"previous_ref" => previous_ref, "host_profile" => canonical} = command
           }
         } = act,
         index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, profile} <- HostProfile.from_canonical(canonical) do
      exact_event_at?(events, index + 1, "host_profile_revised", profile.ref, %{
        "act_ref" => act.ref,
        "previous_ref" => previous_ref,
        "host_profile" => HostProfile.canonical(profile)
      })
    else
      {:error, _reason} -> false
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{
           class: "definition.revise",
           consequence: %{
             "definition_revision" =>
               %{"previous_ref" => previous_ref, "definition" => canonical} = command
           }
         } = act,
         index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, definition} <- Definition.from_canonical(canonical) do
      exact_event_at?(events, index + 1, "definition_revised", definition.ref, %{
        "act_ref" => act.ref,
        "previous_ref" => previous_ref,
        "definition" => Definition.canonical(definition)
      })
    else
      {:error, _reason} -> false
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{class: "data.declassify", consequence: %{"evidence_declassification" => _draft}} =
           act,
         index
       )
       when map_size(act.consequence) == 1,
       do: declassification_effects_adjacent?(events, act, index)

  defp governance_effect_adjacent?(
         events,
         %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act,
         index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, canonical} <- Erasure.request_draft(draft),
         true <- canonical == draft,
         {:ok, erasure} <- Erasure.from_request_draft(canonical, act.ref) do
      exact_record_event_at?(events, index + 1, "erasure_requested", Erasure, erasure)
    else
      _invalid -> false
    end
  end

  defp governance_effect_adjacent?(
         events,
         %Act{class: "scope.open", consequence: %{"scope_open" => draft}} = act,
         index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, opening} <- Opening.from_governed_draft(draft, act.ref, act.committed_at) do
      exact_record_event_at?(events, index + 1, "scope_opened", Opening, opening)
    else
      {:error, _reason} -> false
    end
  end

  defp governance_effect_adjacent?(events, %Act{class: "duty.dispose"} = act, index),
    do: duty_disposition_effects_adjacent?(events, act, index)

  defp governance_effect_adjacent?(_events, %Act{class: class}, _index)
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

  defp governance_effect_adjacent?(_events, %Act{} = act, _index) do
    if act.row.delegate or act.row.govern, do: :unsupported, else: true
  end

  defp event_at(events, index), do: Enum.find(events, &(&1.batch_index == index))

  defp exact_record_event_at?(events, index, type, module, record) do
    exact_event_at?(events, index, type, record.ref, module.canonical(record))
  end

  defp exact_event_at?(events, index, type, identity, data) do
    case event_at(events, index) do
      %{type: ^type, identity: ^identity, data: ^data} -> true
      _missing_or_different -> false
    end
  end

  defp declassification_effects_adjacent?(
         events,
         %Act{consequence: %{"evidence_declassification" => draft}} = act,
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
      _invalid -> false
    end
  end

  defp duty_disposition_effects_adjacent?(events, act, act_index) do
    with {:ok, disposition} <- Disposition.from_consequence(act.consequence) do
      case disposition.meter_resolution do
        :none ->
          duty_disposed_at?(events, act, disposition, act_index + 1)

        operation when operation in [:settle, :release] ->
          duty_meter_resolved_at?(events, act, disposition, operation, act_index + 1) and
            duty_disposed_at?(events, act, disposition, act_index + 2)
      end
    else
      {:error, _reason} -> false
    end
  end

  defp duty_meter_resolved_at?(events, act, disposition, operation, index) do
    case event_at(events, index) do
      %{type: "meter_duty_resolved"} = event ->
        event.identity == "meter_duty_resolved:" <> act.ref and
          event.data["disposition_act_ref"] == act.ref and
          event.data["duty_ref"] == disposition.duty_ref and
          event.data["operation"] == operation

      _missing_or_interposed ->
        false
    end
  end

  defp duty_disposed_at?(events, act, disposition, index) do
    case event_at(events, index) do
      %{type: "duty_disposed", identity: identity} = event ->
        identity == act.ref and event.data["disposition_act_ref"] == act.ref and
          event.data["cause_key"] == disposition.cause_key

      _missing_or_interposed ->
        false
    end
  end

  defp validate_authority_cancellation_batch(
         before,
         state,
         events,
         %Act{class: class} = cause_act,
         act_index
       )
       when class in ["mandate.revoke", "mandate.restrict"] do
    reason =
      if class == "mandate.revoke", do: :mandate_revoked, else: :mandate_restricted

    with {:ok, target_mandate_ref, cascade?} <-
           cancellation_authority_change(state, cause_act, reason),
         {:ok, affected_acts} <-
           affected_pending_acts(
             before,
             state,
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

  defp validate_authority_cancellation_batch(_before, _state, events, cause_act, _index) do
    if Enum.any?(events, fn event ->
         event.type == "dispatch_cancelled" and event.data["cause_ref"] == cause_act.ref
       end),
       do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref}},
       else: :ok
  end

  defp affected_pending_acts(
         before,
         state,
         events,
         before_index,
         target_mandate_ref,
         cascade?
       ) do
    before
    |> pending_dispatch_refs_before(events, before_index)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, affected} ->
      with {:ok, act} <- fetch(state.acts, act_ref, :act),
           {:ok, affected?} <-
             mandate_affected_by_change?(
               state,
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
    |> Enum.filter(&(&1.batch_index < before_index))
    |> Enum.sort_by(& &1.batch_index)
    |> Enum.reduce(before.dispatch_ready, fn event, pending ->
      case event.type do
        "dispatch_ready" -> MapSet.put(pending, event.data["act_ref"])
        "dispatch_cancelled" -> MapSet.delete(pending, event.data["act_ref"])
        "attempt_started" -> MapSet.delete(pending, event.data["act_ref"])
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
        case normalize_amounts_or_empty(act.reservations) do
          {:ok, amounts} when map_size(amounts) > 0 ->
            release =
              {"meter_released", "meter_released:" <> act.ref,
               %{
                 "act_ref" => act.ref,
                 "mandate_ref" => act.mandate_ref,
                 "amounts" => amounts
               }}

            {:cont, {:ok, [release, cancellation | reversed]}}

          {:ok, _empty} ->
            {:halt, {:error, {:empty_meter_reservation, act.ref}}}

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
        event.type == "dispatch_cancelled" and event.data["cause_ref"] == cause_act.ref
      end)
      |> Enum.sort_by(& &1.batch_index)
      |> Enum.map(& &1.data["act_ref"])

    expected_act_refs = Enum.map(affected_acts, & &1.ref)

    actual_act_refs == expected_act_refs and
      expected_events
      |> Enum.with_index(first_index)
      |> Enum.all?(fn {{type, identity, data}, index} ->
        exact_event_at?(events, index, type, identity, data)
      end)
  end

  defp validate_suspension_batch(state, events) do
    events
    |> Enum.filter(&(&1.type == "meter_suspended"))
    |> Enum.reduce_while(:ok, fn event, :ok ->
      act_ref = event.data["act_ref"]

      outcome? =
        Enum.any?(events, fn candidate ->
          candidate.type == "outcome_recorded" and candidate.data["act_ref"] == act_ref and
            candidate.data["status"] == :ambiguous
        end)

      duty? =
        Enum.any?(events, fn candidate ->
          candidate.type == "duty_opened" and candidate.data["act_ref"] == act_ref
        end) or Enum.any?(state.duties, fn {_key, duty} -> duty.act_ref == act_ref end)

      if outcome? or duty?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:meter_suspension_without_outcome_or_duty, act_ref}}}
    end)
  end

  defp validate_recontainment_batch(events) do
    events
    |> Enum.filter(&(&1.type == "meter_recontained"))
    |> Enum.reduce_while(:ok, fn event, :ok ->
      act_ref = event.data["act_ref"]
      outcome_ref = event.data["outcome_ref"]
      outcome = Enum.find(events, &(&1.batch_index == event.batch_index - 1))
      duty = Enum.find(events, &(&1.batch_index == event.batch_index + 1))

      valid_outcome? =
        outcome && outcome.type == "outcome_recorded" && outcome.identity == outcome_ref &&
          outcome.data["act_ref"] == act_ref && outcome.data["status"] in [:succeeded, :failed] &&
          present_ref?(outcome.data["contradicts_outcome_ref"])

      attempt_ref = if outcome, do: outcome.data["attempt_ref"]
      cause_key = {:contradicted_outcome, act_ref, attempt_ref, outcome_ref}

      valid_duty? =
        duty && duty.type == "duty_opened" && duty.data["cause_key"] == cause_key

      if valid_outcome? and valid_duty?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:meter_recontainment_batch_incomplete, act_ref, outcome_ref}}}
    end)
  end

  defp validate_duty_meter_resolution_batch(events) do
    events
    |> Enum.filter(&(&1.type == "meter_duty_resolved"))
    |> Enum.reduce_while(:ok, fn event, :ok ->
      disposition_act_ref = event.data["disposition_act_ref"]
      act = Enum.find(events, &(&1.batch_index == event.batch_index - 1))
      disposal = Enum.find(events, &(&1.batch_index == event.batch_index + 1))

      valid_act? =
        act && act.type == "act_committed" && act.identity == disposition_act_ref &&
          act.data["class"] == "duty.dispose"

      valid_disposal? =
        disposal && disposal.type == "duty_disposed" &&
          disposal.identity == disposition_act_ref &&
          disposal.data["disposition_act_ref"] == disposition_act_ref

      if valid_act? and valid_disposal?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:duty_meter_resolution_batch_incomplete, disposition_act_ref}}}
    end)
  end

  defp validate_required_recontainments(before, events) do
    events
    |> Enum.filter(fn event ->
      event.type == "outcome_recorded" and
        present_ref?(event.data["contradicts_outcome_ref"]) and
        Map.get(before.reservation_states, event.data["act_ref"]) == :released
    end)
    |> Enum.reduce_while(:ok, fn outcome, :ok ->
      matches =
        Enum.filter(events, fn event ->
          event.type == "meter_recontained" and
            event.data["act_ref"] == outcome.data["act_ref"] and
            event.data["outcome_ref"] == outcome.identity
        end)

      case matches do
        [_one] -> {:cont, :ok}
        _other -> {:halt, {:error, {:contradiction_recontainment_missing, outcome.identity}}}
      end
    end)
  end

  defp events_for_act(events, type, act_ref) do
    Enum.filter(events, &(&1.type == type and Map.get(&1.data, "act_ref") == act_ref))
  end

  defp finish(state, snapshot, constitution, audited_at) do
    with :ok <- complete_foundation(state, constitution),
         :ok <- complete_decisions(state),
         :ok <- complete_acts(state),
         :ok <- complete_suspensions(state),
         :ok <- complete_meter_recontainments(state),
         :ok <- complete_mandate_restrictions(state),
         :ok <- complete_meter_ownership(state),
         :ok <- complete_uncertain_outcomes(state),
         :ok <- complete_declassifications(state),
         :ok <- complete_erasure_duties(state),
         :ok <- complete_dispatch_expirations(state, audited_at),
         :ok <- complete_required_duties(state, snapshot, constitution, audited_at),
         :ok <- meters_conserved(state) do
      {:ok, report(state, snapshot, constitution, audited_at)}
    else
      {:error, reason} -> {:error, {:semantic_audit_incomplete, reason}}
    end
  end

  defp remember_required_duties(state, time) do
    required = Derive.required_duties(state, state.constitution, time)

    causes =
      Enum.reduce(required, state.required_duty_causes, fn cause, known ->
        Map.put_new(known, cause.cause_key, cause)
      end)

    %{state | required_duty_causes: causes}
  end

  defp complete_foundation(%State{genesis: nil}, _constitution), do: {:error, :genesis_missing}

  defp complete_foundation(state, constitution) do
    required_principals = MapSet.new(state.genesis.principal_refs)
    actual_principals = state.principals |> Map.keys() |> MapSet.new()

    required_mandates =
      [state.genesis.emergency_mandate_ref | state.genesis.root_mandate_refs]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    actual_roots =
      state.mandates
      |> Enum.filter(fn {ref, mandate} ->
        is_nil(mandate.parent_ref) and not Map.has_key?(state.mandate_predecessors, ref)
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    cond do
      is_nil(state.host_profile) ->
        {:error, :host_profile_missing}

      is_nil(state.surface) ->
        {:error, :surface_missing}

      required_principals != actual_principals ->
        {:error, {:genesis_principals_incomplete, MapSet.to_list(required_principals)}}

      required_mandates != actual_roots ->
        {:error, {:genesis_root_mandates_incomplete, MapSet.to_list(required_mandates)}}

      true ->
        with :ok <- complete_constitution(state, constitution),
             do: complete_emergency_mandate(state, constitution)
    end
  end

  defp complete_constitution(state, constitution) do
    known_authorities = Map.keys(state.principals) ++ Map.keys(state.mandates)

    with {:ok, constitution_ref} <- Constitution.ref(constitution),
         true <- constitution_ref == state.genesis.constitution_ref,
         :ok <- Constitution.validate_duty_routes(constitution, known_authorities) do
      :ok
    else
      false -> {:error, :genesis_constitution_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp complete_emergency_mandate(
         %State{genesis: %{emergency_mandate_ref: nil}},
         _constitution
       ),
       do: :ok

  defp complete_emergency_mandate(state, constitution) do
    with {:ok, mandate} <-
           fetch(state.mandates, state.genesis.emergency_mandate_ref, :emergency_mandate),
         {:ok, maximum_duration} <- emergency_max_duration(constitution) do
      forbidden =
        MapSet.new(~w(mandate.delegate surface.revise host_profile.revise definition.revise))

      cond do
        mandate.delegation != %{"allowed" => false, "max_depth" => 0} ->
          {:error, :emergency_mandate_may_not_delegate}

        Enum.any?(mandate.classes, &MapSet.member?(forbidden, &1)) ->
          {:error, :emergency_mandate_may_not_rewrite_exception}

        mandate.expires_at - mandate.not_before > maximum_duration ->
          {:error, :emergency_mandate_duration_exceeded}

        true ->
          :ok
      end
    end
  end

  defp emergency_max_duration(constitution) do
    case map_field(constitution, :emergency_max_duration_ms) do
      maximum when is_integer(maximum) and maximum > 0 -> {:ok, maximum}
      nil -> {:error, :emergency_max_duration_required}
      _invalid -> {:error, :invalid_emergency_max_duration_ms}
    end
  end

  defp complete_decisions(state) do
    Enum.reduce_while(state.decisions, :ok, fn {ref, decision}, :ok ->
      act_ref = Map.get(state.acts_by_decision, ref)

      case {decision.outcome, act_ref} do
        {:admitted, nil} -> {:halt, {:error, {:admitted_decision_missing_act, ref}}}
        {:admitted, _act_ref} -> {:cont, :ok}
        {_other, nil} -> {:cont, :ok}
        {_other, _act_ref} -> {:halt, {:error, {:non_admitted_decision_has_act, ref}}}
      end
    end)
  end

  defp complete_acts(state) do
    Enum.reduce_while(state.acts, :ok, fn {_ref, act}, :ok ->
      cond do
        has_reservations?(act) and not Map.has_key?(state.reservation_states, act.ref) ->
          {:halt, {:error, {:act_reservation_missing, act.ref}}}

        act.row.attempt and not Map.has_key?(state.attempts_by_act, act.ref) and
          not MapSet.member?(state.dispatch_ready, act.ref) and
            not Map.has_key?(state.dispatch_cancellations, act.ref) ->
          {:halt, {:error, {:act_dispatch_state_missing, act.ref}}}

        Map.has_key?(state.dispatch_cancellations, act.ref) and has_reservations?(act) and
            Map.get(state.reservation_states, act.ref) != :released ->
          {:halt, {:error, {:cancelled_dispatch_reservation_not_released, act.ref}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp complete_suspensions(state) do
    Enum.reduce_while(state.reservation_states, :ok, fn
      {act_ref, :suspended}, :ok ->
        if Enum.any?(state.duties, fn {_key, duty} -> duty.act_ref == act_ref end),
          do: {:cont, :ok},
          else: {:halt, {:error, {:suspended_reservation_without_duty, act_ref}}}

      {_act_ref, _status}, :ok ->
        {:cont, :ok}
    end)
  end

  defp complete_meter_recontainments(state) do
    with :ok <-
           Enum.reduce_while(state.meter_recontainments, :ok, fn
             {act_ref, record}, :ok ->
               outcome = Map.get(state.outcomes, record.outcome_ref)
               duty = Map.get(state.duties, record.cause_key)
               reservation_status = Map.get(state.reservation_states, act_ref)

               valid? =
                 record.act_ref == act_ref and
                   match?(%Outcome{act_ref: ^act_ref}, outcome) and
                   Outcome.correction?(outcome) and
                   record.mandate_ref == outcome_mandate_ref(state, outcome) and
                   recontainment_record_complete?(record, duty, reservation_status)

               if valid?,
                 do: {:cont, :ok},
                 else: {:halt, {:error, {:incomplete_meter_recontainment, act_ref}}}
           end) do
      state.outcomes
      |> Map.values()
      |> Enum.filter(&requires_recontainment?(state, &1))
      |> Enum.reduce_while(:ok, fn outcome, :ok ->
        if Map.has_key?(state.meter_recontainments, outcome.act_ref),
          do: {:cont, :ok},
          else: {:halt, {:error, {:missing_meter_recontainment, outcome.ref}}}
      end)
    end
  end

  defp recontainment_record_complete?(record, %Duty{status: :open}, :suspended),
    do: record.status == :open and is_nil(record.disposition_act_ref)

  defp recontainment_record_complete?(record, %Duty{status: :disposed} = duty, status)
       when status in [:settled, :released] do
    record.status == :disposed and record.disposition_act_ref == duty.disposition_act_ref
  end

  defp recontainment_record_complete?(_record, _duty, _status), do: false

  defp requires_recontainment?(state, %Outcome{} = outcome) do
    case Map.get(state.acts, outcome.act_ref) do
      %Act{reservations: reservations} when reservations not in [%{}, []] ->
        Outcome.correction?(outcome)

      _other ->
        false
    end
  end

  defp requires_recontainment?(_state, _outcome), do: false

  defp outcome_mandate_ref(state, %Outcome{act_ref: act_ref}) do
    case Map.get(state.acts, act_ref) do
      %Act{mandate_ref: mandate_ref} -> mandate_ref
      _other -> nil
    end
  end

  defp complete_mandate_restrictions(state) do
    with :ok <- complete_successor_links(state),
         :ok <- complete_predecessor_links(state),
         :ok <- complete_restricted_mandates(state),
         :ok <- complete_restriction_acts(state) do
      acyclic_successions(state.mandate_successors)
    end
  end

  defp complete_successor_links(state) do
    Enum.reduce_while(state.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        with {:ok, predecessor} <- fetch(state.mandates, predecessor_ref, :mandate),
             {:ok, successor} <- fetch(state.mandates, successor_ref, :mandate),
             true <- Map.get(state.mandate_predecessors, successor_ref) == predecessor_ref,
             {:ok, act} <- fetch(state.acts, successor.source_ref, :act),
             :ok <-
               validate_restriction_act(
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

  defp complete_predecessor_links(state) do
    Enum.reduce_while(state.mandate_predecessors, :ok, fn
      {successor_ref, predecessor_ref}, :ok ->
        if Map.get(state.mandate_successors, predecessor_ref) == successor_ref,
          do: {:cont, :ok},
          else:
            {:halt,
             {:error, {:mandate_restriction_links_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp complete_restricted_mandates(state) do
    Enum.reduce_while(state.mandates, :ok, fn {ref, mandate}, :ok ->
      predecessor_ref = Map.get(state.mandate_predecessors, ref)

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

  defp complete_restriction_acts(state) do
    state.acts
    |> Map.values()
    |> Enum.filter(&(&1.class == "mandate.restrict"))
    |> Enum.reduce_while(:ok, fn act, :ok ->
      successors =
        Enum.filter(state.mandates, fn {successor_ref, mandate} ->
          mandate.source_ref == act.ref and
            Map.has_key?(state.mandate_predecessors, successor_ref)
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

  defp restriction_data(act, predecessor, successor) do
    %{
      "act_ref" => act.ref,
      "predecessor_ref" => predecessor.ref,
      "successor" => Mandate.canonical(successor)
    }
  end

  defp complete_meter_ownership(state) do
    expected_physical =
      state.meter_owners
      |> Enum.filter(fn {mandate_ref, owner_ref} -> mandate_ref == owner_ref end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    actual_physical = state.meters |> Map.keys() |> MapSet.new()

    with true <- map_size(state.meter_owners) == map_size(state.mandates),
         true <- expected_physical == actual_physical,
         :ok <- complete_meter_owner_refs(state) do
      complete_restriction_meter_owners(state)
    else
      false -> {:error, :mandate_meter_ownership_incomplete}
      {:error, _reason} = error -> error
    end
  end

  defp complete_meter_owner_refs(state) do
    Enum.reduce_while(state.mandates, :ok, fn {mandate_ref, _mandate}, :ok ->
      owner_ref = Map.get(state.meter_owners, mandate_ref)

      if is_binary(owner_ref) and Map.has_key?(state.mandates, owner_ref) and
           Map.has_key?(state.meters, owner_ref) and
           Map.get(state.meter_owners, owner_ref) == owner_ref,
         do: {:cont, :ok},
         else: {:halt, {:error, {:invalid_mandate_meter_owner, mandate_ref, owner_ref}}}
    end)
  end

  defp complete_restriction_meter_owners(state) do
    Enum.reduce_while(state.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        if Map.get(state.meter_owners, predecessor_ref) ==
             Map.get(state.meter_owners, successor_ref),
           do: {:cont, :ok},
           else:
             {:halt,
              {:error,
               {:mandate_restriction_meter_owner_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp blocked_mandate_refs(state) do
    blocked_owners =
      state.meter_recontainments
      |> Map.values()
      |> Enum.filter(&(&1.status == :open and map_size(&1.deficits) > 0))
      |> Enum.map(&Map.get(state.meter_owners, &1.mandate_ref))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    state.meter_owners
    |> Enum.filter(fn {_mandate_ref, owner_ref} -> MapSet.member?(blocked_owners, owner_ref) end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp blocked_effect_digests(state) do
    state.duties
    |> Map.values()
    |> Enum.flat_map(fn
      %Duty{
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

  defp complete_uncertain_outcomes(state) do
    state.outcomes
    |> Enum.filter(fn {_ref, outcome} ->
      outcome.status == :ambiguous or Outcome.correction?(outcome)
    end)
    |> Enum.reduce_while(:ok, fn {_ref, outcome}, :ok ->
      required_cause =
        if Outcome.correction?(outcome),
          do: {:contradicted_outcome, outcome.act_ref, outcome.attempt_ref, outcome.ref},
          else: {:ambiguous_outcome, outcome.act_ref, outcome.attempt_ref}

      if Map.has_key?(state.duties, required_cause),
        do: {:cont, :ok},
        else: {:halt, {:error, {:uncertain_outcome_without_duty, outcome.ref}}}
    end)
  end

  defp complete_declassifications(state) do
    with :ok <-
           Enum.reduce_while(state.declassifications, :ok, fn {ref, record}, :ok ->
             valid? =
               Map.get(state.declassifications_by_act, record.source_act_ref) == ref and
                 Map.get(state.declassifications_by_evidence, record.evidence_ref) == ref and
                 Map.has_key?(state.evidence, record.evidence_ref)

             if valid?,
               do: {:cont, :ok},
               else: {:halt, {:error, {:incomplete_declassification, ref}}}
           end) do
      Enum.reduce_while(state.acts, :ok, fn {_ref, act}, :ok ->
        if act.class != "data.declassify" or
             Map.has_key?(state.declassifications_by_act, act.ref),
           do: {:cont, :ok},
           else: {:halt, {:error, {:declassification_act_incomplete, act.ref}}}
      end)
    end
  end

  defp complete_erasure_duties(state) do
    state.erasures
    |> Map.values()
    |> Enum.filter(& &1.reduces_verifiability)
    |> Enum.reduce_while(:ok, fn erasure, :ok ->
      succeeded =
        state.outcomes
        |> Map.values()
        |> Enum.find(&(&1.act_ref == erasure.source_act_ref and &1.status == :succeeded))

      if is_nil(succeeded) do
        {:cont, :ok}
      else
        cause =
          {:erasure_reduces_verifiability, erasure.ref, erasure.source_act_ref,
           succeeded.attempt_ref, succeeded.ref}

        if Map.has_key?(state.duties, cause),
          do: {:cont, :ok},
          else: {:halt, {:error, {:erasure_outcome_without_verifiability_duty, erasure.ref}}}
      end
    end)
  end

  defp complete_dispatch_expirations(state, audited_at) do
    state.dispatch_ready
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn act_ref, :ok ->
      with {:ok, act} <- fetch(state.acts, act_ref, :act),
           {:ok, mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
           true <- act.mandate_revision == mandate.revision do
        if mandate.expires_at <= audited_at,
          do: {:halt, {:error, {:dispatch_expiration_not_recorded, act.ref}}},
          else: {:cont, :ok}
      else
        false -> {:halt, {:error, {:dispatch_expiration_mandate_mismatch, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @duty_causal_fields [
    :schema_version,
    :ref,
    :cause_key,
    :class,
    :act_ref,
    :attempt_ref,
    :mandate_ref,
    :subjects,
    :accountable,
    :evidence_refs,
    :missing,
    :containment,
    :closing_conditions,
    :disposition_authority_refs,
    :conflict_refs,
    :opened_at
  ]

  defp complete_required_duties(state, _snapshot, _constitution, audited_at) do
    required = Map.values(state.required_duty_causes)

    with :ok <- validate_required_duty_materializations(state, required, audited_at) do
      required_keys = required |> Enum.map(& &1.cause_key) |> MapSet.new()

      unexpected =
        state.duties
        |> Map.values()
        |> Enum.map(& &1.cause_key)
        |> MapSet.new()
        |> MapSet.difference(required_keys)
        |> MapSet.to_list()
        |> Enum.sort()

      case unexpected do
        [] -> :ok
        cause_keys -> {:error, {:duties_without_canonical_cause, cause_keys}}
      end
    end
  end

  defp validate_required_duty_materializations(state, required, audited_at) do
    Enum.reduce_while(required, :ok, fn cause, :ok ->
      case Map.fetch(state.duties, cause.cause_key) do
        {:ok, %Duty{} = actual} ->
          case expected_duty(cause, audited_at) do
            {:ok, expected} ->
              if duty_cause_matches?(actual, expected),
                do: {:cont, :ok},
                else: {:halt, {:error, {:duty_cause_materialization_mismatch, actual.ref}}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_required_duty, cause.cause_key, reason}}}
          end

        :error ->
          {:halt, {:error, {:required_duty_not_materialized, cause.cause_key}}}
      end
    end)
  end

  defp expected_duty(cause, audited_at) do
    cause
    |> Derive.materialization_attrs(audited_at)
    |> Duty.new()
  end

  defp duty_cause_matches?(actual, expected) do
    Map.take(Map.from_struct(actual), @duty_causal_fields) ==
      Map.take(Map.from_struct(expected), @duty_causal_fields)
  end

  defp meters_conserved(state) do
    Enum.reduce_while(state.meters, :ok, fn {mandate_ref, accounts}, :ok ->
      Enum.reduce_while(accounts, :ok, fn {meter_ref, account}, :ok ->
        case Meter.validate(account) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:meter_invalid, mandate_ref, meter_ref, reason}}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp report(state, snapshot, constitution, audited_at) do
    act_contexts =
      state.act_contexts
      |> Map.values()
      |> Enum.sort_by(& &1.ledger_revision)

    open_duties =
      state.duties
      |> Map.values()
      |> Enum.filter(&(&1.status == :open))
      |> Enum.sort_by(& &1.ref)
      |> Enum.map(&Duty.canonical/1)

    erasures =
      state.erasures
      |> Map.values()
      |> Enum.sort_by(& &1.ref)
      |> Enum.map(&erasure_report(state, &1))

    definitions =
      state.definitions
      |> Map.values()
      |> Enum.sort_by(&{&1.namespace, &1.name, &1.revision})
      |> Enum.map(&Definition.canonical/1)

    meter_recontainments =
      state.meter_recontainments
      |> Map.values()
      |> Enum.sort_by(& &1.act_ref)
      |> Enum.map(fn record ->
        %{
          act_ref: record.act_ref,
          mandate_ref: record.mandate_ref,
          outcome_ref: record.outcome_ref,
          cause_key: record.cause_key,
          amounts: record.amounts,
          recontained: record.recontained,
          deficits: record.deficits,
          status: record.status,
          disposition_act_ref: record.disposition_act_ref
        }
      end)

    mandate_restrictions =
      state.mandate_successors
      |> Enum.map(fn {predecessor_ref, successor_ref} ->
        successor = Map.fetch!(state.mandates, successor_ref)

        %{
          act_ref: successor.source_ref,
          predecessor_ref: predecessor_ref,
          successor: Mandate.canonical(successor)
        }
      end)
      |> Enum.sort_by(&{&1.predecessor_ref, &1.successor["ref"]})

    %{
      format: @format,
      format_version: @format_version,
      domain_ref: state.domain_ref,
      ledger_revision: snapshot.revision,
      head_digest: snapshot.head_digest,
      constitution_ref: Constitution.ref!(constitution),
      audited_at: audited_at,
      foundation: %{
        genesis: Genesis.canonical(state.genesis),
        host_profile: HostProfile.canonical(state.host_profile),
        host_profile_history:
          state.host_profiles
          |> Map.values()
          |> Enum.sort_by(& &1.revision)
          |> Enum.map(&HostProfile.canonical/1),
        surface: Surface.canonical(state.surface),
        surface_history:
          state.surfaces
          |> Map.values()
          |> Enum.sort_by(& &1.revision)
          |> Enum.map(&Surface.canonical/1),
        principal_refs: Enum.sort(Map.keys(state.principals)),
        root_mandate_refs: Enum.sort(state.genesis.root_mandate_refs)
      },
      act_contexts: act_contexts,
      mandate_restrictions: mandate_restrictions,
      meters: canonical_meters(state.meters),
      meter_owners: state.meter_owners,
      meter_recontainments: meter_recontainments,
      dispatch_cancellations:
        state.dispatch_cancellations
        |> Map.values()
        |> Enum.sort_by(& &1.act_ref),
      open_duties: open_duties,
      scopes:
        state.scopes
        |> Map.values()
        |> Enum.sort_by(& &1.ref)
        |> Enum.map(&Opening.canonical/1),
      definitions: definitions,
      definition_heads:
        state.definition_heads
        |> Enum.map(fn {{namespace, name}, ref} ->
          %{namespace: namespace, name: name, ref: ref}
        end)
        |> Enum.sort_by(&{&1.namespace, &1.name}),
      declassifications:
        state.declassifications
        |> Map.values()
        |> Enum.sort_by(& &1.ref)
        |> Enum.map(&Declassification.canonical/1),
      erasures: erasures,
      counts: %{
        mandates: map_size(state.mandates),
        mandate_restrictions: map_size(state.mandate_successors),
        revocations: map_size(state.revocations),
        declassifications: map_size(state.declassifications),
        decisions: map_size(state.decisions),
        acts: map_size(state.acts),
        attempts: map_size(state.attempts),
        outcomes: map_size(state.outcomes),
        duties: map_size(state.duties),
        scopes: map_size(state.scopes),
        definitions: map_size(state.definitions),
        erasures: map_size(state.erasures),
        meter_owners: map_size(state.meter_owners),
        meter_recontainments: map_size(state.meter_recontainments),
        meter_devolutions: MapSet.size(state.meter_devolutions),
        dispatch_cancellations: map_size(state.dispatch_cancellations)
      }
    }
  end

  defp erasure_report(state, erasure) do
    outcomes =
      state.outcomes
      |> Map.values()
      |> Enum.filter(&(&1.act_ref == erasure.source_act_ref))
      |> Enum.sort_by(&{state.outcome_meta[&1.ref].revision, &1.ref})

    status =
      case List.last(outcomes) do
        nil -> :requested
        outcome -> outcome.status
      end

    %{
      request: Erasure.canonical(erasure),
      status: status,
      outcome_refs: Enum.map(outcomes, & &1.ref)
    }
  end

  defp canonical_meters(meters) do
    Map.new(meters, fn {mandate_ref, accounts} ->
      canonical_accounts =
        Map.new(accounts, fn {meter_ref, account} ->
          {meter_ref,
           Map.new([:ceiling, :available, :reserved, :suspended, :spent, :delegated], fn key ->
             {Atom.to_string(key), Map.fetch!(account, key)}
           end)}
        end)

      {mandate_ref, canonical_accounts}
    end)
  end

  defp fetch_meter_accounts(state, mandate_ref) do
    with {:ok, owner_ref} <- fetch_meter_owner(state, mandate_ref) do
      fetch(state.meters, owner_ref, :meter_mandate)
    end
  end

  defp fetch_meter_owner(state, mandate_ref) do
    fetch(state.meter_owners, mandate_ref, :meter_owner)
  end

  defp put_meter_accounts(state, mandate_ref, accounts) do
    with {:ok, owner_ref} <- fetch_meter_owner(state, mandate_ref) do
      {:ok, %{state | meters: Map.put(state.meters, owner_ref, accounts)}}
    end
  end

  defp normalize_amounts(amounts) do
    with {:ok, normalized} <- normalize_amounts_or_empty(amounts),
         false <- map_size(normalized) == 0 do
      {:ok, normalized}
    else
      true -> {:error, :empty_meter_amounts}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_amounts_or_empty(amounts) when is_map(amounts) and not is_struct(amounts) do
    Enum.reduce_while(amounts, {:ok, %{}}, fn {meter_ref, amount}, {:ok, normalized} ->
      if is_binary(meter_ref) and meter_ref != "" and is_integer(amount) and amount > 0,
        do: {:cont, {:ok, Map.put(normalized, meter_ref, amount)}},
        else: {:halt, {:error, {:invalid_meter_amount, meter_ref}}}
    end)
  end

  defp normalize_amounts_or_empty(amounts) when is_list(amounts) do
    Enum.reduce_while(amounts, {:ok, %{}}, fn reservation, {:ok, normalized} ->
      meter_ref = map_field(reservation, :meter_ref)
      amount = map_field(reservation, :quantity)

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

  defp normalize_amounts_or_empty(_amounts), do: {:error, :invalid_meter_amounts}

  defp fetch(collection, key, kind) do
    case Map.fetch(collection, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {kind, :not_found, key}}
    end
  end

  defp optional_fetch(_collection, nil, _kind), do: {:ok, nil}
  defp optional_fetch(collection, key, kind), do: fetch(collection, key, kind)

  defp fetch_many(collection, keys, kind) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, records} ->
      case fetch(collection, key, kind) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp exact_keys(map, expected, context) do
    actual = Map.keys(map)
    missing = expected -- actual
    unknown = actual -- expected

    cond do
      unknown != [] -> {:error, {:unknown_fields, context, Enum.sort_by(unknown, &inspect/1)}}
      missing != [] -> {:error, {:missing_field, context, hd(missing)}}
      true -> :ok
    end
  end

  defp event_metadata(event) do
    %{
      revision: event.revision,
      batch_id: event.batch_id,
      batch_index: event.batch_index,
      recorded_at: event.recorded_at
    }
  end

  defp has_reservations?(%{reservations: reservations}), do: reservations not in [%{}, []]

  defp exact_row?(%Row{} = row, dimensions), do: Row.dimensions(row) == dimensions

  defp act_targets?(act, refs), do: Enum.all?(refs, &(&1 in act.target_refs))

  defp ledger_internal_act?(act) do
    Governance.ledger_internal?(act)
  end

  defp map_field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_field(_value, _key), do: nil

  defp present_ref?(value), do: is_binary(value) and value != ""

  defp semantic_error(revision, type, reason) do
    {:error, {:semantic_violation, %{revision: revision, event_type: type, reason: reason}}}
  end
end
