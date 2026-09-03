defmodule Spectre.Domain.Event do
  @moduledoc """
  Canonical envelope and decoder for facts stored in a Domain ledger.

  This module is deliberately smaller than the semantics that consume an
  event. It owns the wire grammar shared by writers, live projections and the
  independent auditor: exact keys, event identity bindings and acquisition
  time. It does not decide whether an event is authorized or whether its
  transition is valid; those are governed-act semantics.

  Keeping the durable grammar here gives both replay paths the same strict
  boundary while allowing them to fold the decoded event independently.
  """

  alias Spectre.Domain.Event.Builder
  alias Spectre.Ledger.Entry

  defmodule Metadata do
    @moduledoc """
    Trusted ledger position attached to a decoded Domain event.

    Record-specific metadata maps used to be repeated by projections and the
    auditor. A single value indexed by `{event_type, identity}` keeps replay
    ordering, batch adjacency and acquisition time in one consistent shape.
    """

    @enforce_keys [:revision, :batch_id, :batch_index, :recorded_at]
    defstruct [:revision, :batch_id, :batch_index, :recorded_at]

    @type t :: %__MODULE__{
            revision: pos_integer(),
            batch_id: String.t(),
            batch_index: non_neg_integer(),
            recorded_at: non_neg_integer()
          }
  end

  @record_events %{
    genesis: {"genesis_recorded", Spectre.Genesis},
    principal: {"principal_recorded", Spectre.Principal},
    host_profile: {"host_profile_recorded", Spectre.HostProfile},
    surface: {"surface_recorded", Spectre.Surface},
    mandate: {"mandate_issued", Spectre.Mandate},
    declassification: {"declassification_recorded", Spectre.Declassification},
    evidence: {"evidence_recorded", Spectre.Evidence},
    presentation: {"presentation_recorded", Spectre.Presentation},
    decision: {"decision_recorded", Spectre.Decision},
    act: {"act_committed", Spectre.Act},
    attempt: {"attempt_started", Spectre.Attempt},
    outcome: {"outcome_recorded", Spectre.Outcome},
    duty: {"duty_opened", Spectre.Duty},
    scope: {"scope_opened", Spectre.Scope.Opening},
    erasure: {"erasure_requested", Spectre.Erasure}
  }

  @manual_fields %{
    "principal_registered" => ~w(act_ref principal),
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
  @envelope_fields ~w(type identity data schema_version)

  @enforce_keys [:type, :identity, :data]
  defstruct [:type, :identity, :data, :revision, :batch_id, :batch_index, :recorded_at]

  @type t :: %__MODULE__{
          type: String.t(),
          identity: String.t(),
          data: map(),
          revision: pos_integer() | nil,
          batch_id: String.t() | nil,
          batch_index: non_neg_integer() | nil,
          recorded_at: non_neg_integer() | nil
        }

  @type key :: {String.t(), String.t()}

  @doc "Returns the stable lookup key for an event identity within its class."
  @spec key(t()) :: key()
  def key(%__MODULE__{type: type, identity: identity}), do: {type, identity}

  @doc "Returns ledger metadata from an event decoded with `decode_entry/1`."
  @spec metadata(t()) :: {:ok, Metadata.t()} | {:error, :missing_event_metadata}
  def metadata(%__MODULE__{
        revision: revision,
        batch_id: batch_id,
        batch_index: batch_index,
        recorded_at: recorded_at
      })
      when is_integer(revision) and revision > 0 and is_binary(batch_id) and batch_id != "" and
             is_integer(batch_index) and batch_index >= 0 and is_integer(recorded_at) and
             recorded_at >= 0 do
    {:ok,
     %Metadata{
       revision: revision,
       batch_id: batch_id,
       batch_index: batch_index,
       recorded_at: recorded_at
     }}
  end

  def metadata(%__MODULE__{}), do: {:error, :missing_event_metadata}

  @doc "Builds the exact plain-map envelope persisted as an Entry payload."
  @spec envelope(String.t(), String.t(), map()) :: map()
  def envelope(type, identity, data)
      when type in @known_events and is_binary(identity) and identity != "" and is_map(data) and
             not is_struct(data) do
    %{
      "type" => type,
      "identity" => identity,
      "data" => data,
      "schema_version" => 1
    }
  end

  @doc false
  @spec record_event(atom()) :: {:ok, {String.t(), module()}} | {:error, term()}
  def record_event(kind) do
    case Map.fetch(@record_events, kind) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, {:unknown_domain_record_kind, kind}}
    end
  end

  @doc "Decodes and validates an event envelope without ledger metadata."
  @spec decode(map()) :: {:ok, t()} | {:error, term()}
  def decode(payload) when is_map(payload) and not is_struct(payload) do
    with :ok <- exact_keys(payload, @envelope_fields, :domain_event),
         :ok <- supported_version(payload["schema_version"]),
         {:ok, type} <- known_type(payload["type"]),
         :ok <- valid_identity(payload["identity"]),
         :ok <- valid_data(payload["data"]),
         :ok <- validate_manual_data(type, payload["identity"], payload["data"]) do
      {:ok,
       %__MODULE__{
         type: type,
         identity: payload["identity"],
         data: payload["data"]
       }}
    end
  end

  def decode(_payload), do: {:error, :invalid_domain_event}

  @doc "Decodes an Entry payload and binds its trusted ledger metadata."
  @spec decode_entry(Entry.t()) :: {:ok, t()} | {:error, term()}
  def decode_entry(%Entry{} = entry) do
    with {:ok, event} <- decode(entry.payload),
         :ok <- validate_acquisition_time(event, entry.recorded_at) do
      {:ok,
       %{
         event
         | revision: entry.revision,
           batch_id: entry.batch_id,
           batch_index: entry.batch_index,
           recorded_at: entry.recorded_at
       }}
    end
  end

  def decode_entry(_entry), do: {:error, :invalid_domain_event_entry}

  @doc "Builds a canonical envelope for a typed Domain record."
  @spec record(atom(), struct()) :: {:ok, map()} | {:error, term()}
  defdelegate record(kind, record), to: Builder

  @spec meter(:reserve | :settle | :release | :suspend, Spectre.Act.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate meter(operation, act), to: Builder

  @spec meter_recontained(Spectre.Act.t(), Spectre.Outcome.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate meter_recontained(act, outcome, recontained, deficits), to: Builder

  @spec meter_duty_resolved(
          Spectre.Act.t(),
          Spectre.Act.t(),
          Spectre.Duty.t(),
          :settle | :release,
          map()
        ) :: {:ok, map()} | {:error, term()}
  defdelegate meter_duty_resolved(cause_act, disposition_act, duty, operation, amounts),
    to: Builder

  @spec meter_devolved(Spectre.Act.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defdelegate meter_devolved(act, child_mandate_ref, amounts), to: Builder

  @spec surface_revised(Spectre.Act.t(), String.t(), Spectre.Surface.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate surface_revised(act, previous_ref, surface), to: Builder

  @spec host_profile_revised(Spectre.Act.t(), String.t(), Spectre.HostProfile.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate host_profile_revised(act, previous_ref, profile), to: Builder

  @spec definition_revised(Spectre.Act.t(), String.t() | nil, Spectre.Definition.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate definition_revised(act, previous_ref, definition), to: Builder

  @spec principal_registered(Spectre.Act.t(), Spectre.Principal.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate principal_registered(act, principal), to: Builder

  @spec dispatch_ready(Spectre.Act.t()) :: map()
  defdelegate dispatch_ready(act), to: Builder

  @spec dispatch_cancelled(
          Spectre.Act.t(),
          Spectre.Act.t() | Spectre.Duty.t() | Spectre.Mandate.t(),
          atom()
        ) :: {:ok, map()} | {:error, term()}
  defdelegate dispatch_cancelled(act, cause, reason), to: Builder

  @spec mandate_revoked(String.t(), String.t(), integer()) ::
          map() | {:error, :invalid_mandate_revocation_event}
  defdelegate mandate_revoked(identity, mandate_ref, effective_at), to: Builder

  @spec mandate_restricted(Spectre.Act.t(), String.t(), Spectre.Mandate.t()) ::
          {:ok, map()} | {:error, term()}
  defdelegate mandate_restricted(act, predecessor_ref, successor), to: Builder

  @spec duty_disposed(String.t(), term(), String.t()) ::
          map() | {:error, :invalid_duty_disposition_event}
  defdelegate duty_disposed(identity, cause_key, disposition_act_ref), to: Builder

  @spec scope_opened(Spectre.Scope.Opening.t()) :: {:ok, map()} | {:error, term()}
  defdelegate scope_opened(opening), to: Builder

  defp supported_version(1), do: :ok

  defp supported_version(version) when is_integer(version),
    do: {:error, {:unsupported_domain_event_schema_version, version}}

  defp supported_version(_version), do: {:error, :invalid_domain_event_schema_version}

  defp known_type(type) when type in @known_events, do: {:ok, type}
  defp known_type(type), do: {:error, {:unknown_domain_event, type}}

  defp valid_identity(identity) when is_binary(identity) and identity != "", do: :ok
  defp valid_identity(_identity), do: {:error, :invalid_domain_event_identity}

  defp valid_data(data) when is_map(data) and not is_struct(data), do: :ok
  defp valid_data(_data), do: {:error, :invalid_domain_event_data}

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
            ],
       do: prefixed_identity(identity, type, act_ref)

  defp validate_manual_identity(
         "meter_duty_resolved",
         identity,
         %{"disposition_act_ref" => act_ref}
       ),
       do: prefixed_identity(identity, "meter_duty_resolved", act_ref)

  defp validate_manual_identity(
         "duty_disposed",
         identity,
         %{"disposition_act_ref" => act_ref}
       ) do
    if identity == act_ref,
      do: :ok,
      else: {:error, {:domain_event_identity_mismatch, identity, act_ref}}
  end

  defp validate_manual_identity(_type, _identity, _data), do: :ok

  defp prefixed_identity(identity, prefix, ref) when is_binary(ref) and ref != "" do
    expected = prefix <> ":" <> ref

    if identity == expected,
      do: :ok,
      else: {:error, {:domain_event_identity_mismatch, identity, expected}}
  end

  defp prefixed_identity(_identity, _prefix, ref),
    do: {:error, {:invalid_domain_event_act_ref, ref}}

  defp validate_acquisition_time(%__MODULE__{} = event, recorded_at)
       when is_integer(recorded_at) and recorded_at >= 0 do
    data = event.data

    case event.type do
      "genesis_recorded" ->
        not_future_time(event.type, "issued_at", data, recorded_at)

      "host_profile_recorded" ->
        not_future_time(event.type, "declared_at", data, recorded_at)

      "host_profile_revised" ->
        not_future_time(event.type, "declared_at", data["host_profile"], recorded_at)

      "definition_revised" ->
        not_future_time(event.type, "declared_at", data["definition"], recorded_at)

      "declassification_recorded" ->
        exact_event_time(event.type, "recorded_at", data, recorded_at)

      "evidence_recorded" ->
        not_future_time(event.type, "observed_at", data, recorded_at)

      "presentation_recorded" ->
        not_future_time(event.type, "prepared_at", data, recorded_at)

      "decision_recorded" ->
        exact_event_time(event.type, "decided_at", data, recorded_at)

      "act_committed" ->
        exact_event_time(event.type, "committed_at", data, recorded_at)

      "attempt_started" ->
        exact_event_time(event.type, "started_at", data, recorded_at)

      "outcome_recorded" ->
        not_future_time(event.type, "observed_at", data, recorded_at)

      "duty_opened" ->
        not_future_time(event.type, "opened_at", data, recorded_at)

      "mandate_revoked" ->
        exact_event_time(event.type, "effective_at", data, recorded_at)

      "dispatch_cancelled" ->
        not_future_time(event.type, "cancelled_at", data, recorded_at)

      "scope_opened" ->
        scope_acquisition_time(event.type, data, recorded_at)

      "erasure_requested" ->
        not_future_time(event.type, "requested_at", data, recorded_at)

      _other ->
        :ok
    end
  end

  defp validate_acquisition_time(_event, _recorded_at),
    do: {:error, :invalid_event_acquisition_time}

  defp scope_acquisition_time(type, data, recorded_at) do
    if is_nil(data["source_act_ref"]),
      do: not_future_time(type, "opened_at", data, recorded_at),
      else: exact_event_time(type, "opened_at", data, recorded_at)
  end

  defp exact_event_time(type, field_name, data, recorded_at) when is_map(data) do
    case Map.get(data, field_name) do
      ^recorded_at -> :ok
      value -> {:error, {:event_time_mismatch, type, field_name, value, recorded_at}}
    end
  end

  defp exact_event_time(type, field_name, data, recorded_at),
    do: {:error, {:event_time_mismatch, type, field_name, data, recorded_at}}

  defp not_future_time(type, field_name, data, recorded_at) when is_map(data) do
    case Map.get(data, field_name) do
      value when is_integer(value) and value <= recorded_at -> :ok
      value -> {:error, {:event_from_future, type, field_name, value, recorded_at}}
    end
  end

  defp not_future_time(type, field_name, data, recorded_at),
    do: {:error, {:event_from_future, type, field_name, data, recorded_at}}

  defp exact_keys(map, expected, context) when is_map(map) and not is_struct(map) do
    actual = Map.keys(map)
    unknown = actual -- expected
    missing = expected -- actual

    cond do
      unknown != [] -> {:error, {:unknown_fields, context, Enum.sort_by(unknown, &inspect/1)}}
      missing != [] -> {:error, {:missing_field, context, List.first(missing)}}
      true -> :ok
    end
  end

  defp exact_keys(_map, _expected, context), do: {:error, {:invalid_fields, context}}
end
