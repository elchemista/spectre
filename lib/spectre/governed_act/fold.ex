defmodule Spectre.GovernedAct.Fold do
  @moduledoc """
  Pure governed-act history fold.

  This is the single semantic reducer shared by the live Domain projection and
  the independent audit driver. It receives verified ledger entries or decoded
  provisional events and derives disposable state; it never performs I/O,
  grants authority, or talks to an executor.

  Keeping transition semantics here is important: runtime replay and offline
  audit may have different inputs and error presentation, but they must not
  maintain separate copies of the Governed Act Model.
  """

  alias Spectre.Constitution
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.{Batch, Completeness, MeterState}
  alias Spectre.Ledger.Entry
  alias Spectre.GovernedAct.Transition.Admission
  alias Spectre.GovernedAct.Transition.Duty, as: DutyTransition
  alias Spectre.GovernedAct.Transition.Execution
  alias Spectre.GovernedAct.Transition.Foundation
  alias Spectre.GovernedAct.Transition.Authority, as: AuthorityTransition
  alias Spectre.GovernedAct.Transition.Information
  alias Spectre.GovernedAct.Transition.Scope, as: ScopeTransition

  alias Spectre.GovernedAct.State

  @type t :: State.t()
  @type reservation_status :: State.reservation_status()
  @type dispatch_cancellation :: State.dispatch_cancellation()
  @type reservation_binding :: State.reservation_binding()
  @type meter_recontainment :: State.meter_recontainment()
  @type duty_meter_resolution :: State.duty_meter_resolution()

  @spec new(String.t(), map()) :: t()
  def new(domain_ref, constitution \\ %{}), do: State.new(domain_ref, constitution)

  @doc """
  Folds an already chain-verified sequence of Domain entries.

  Structural snapshot verification belongs to the caller (`Domain.Projection`
  or `Audit`). This function owns only canonical event decoding and governed
  transition semantics, which keeps the two drivers independent at their I/O
  boundaries while making semantic drift impossible.
  """
  @spec replay_verified(String.t(), [Entry.t()], map()) :: {:ok, t()} | {:error, term()}
  def replay_verified(domain_ref, entries, constitution)
      when is_binary(domain_ref) and domain_ref != "" and is_list(entries) and
             is_map(constitution) and not is_struct(constitution) do
    with :ok <- Constitution.validate(constitution) do
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
          with :ok <- validate_complete(projection), do: {:ok, projection}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def replay_verified(_domain_ref, _entries, _constitution),
    do: {:error, :invalid_governed_history}

  defp replay_batch(projection, entries) do
    with {:ok, decoded_entries} <- decode_batch_entries(entries),
         {:ok, next} <- apply_batch_entries(projection, decoded_entries),
         events = Enum.map(decoded_entries, &elem(&1, 1)),
         :ok <- Batch.validate(projection, next, events) do
      {:ok, next}
    end
  end

  defp apply_batch_entries(projection, decoded_entries) do
    Enum.reduce_while(decoded_entries, {:ok, projection}, fn {entry, event}, {:ok, current} ->
      case apply_decoded_entry(current, entry, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_batch_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, decoded_entries} ->
      case Event.decode_entry(entry) do
        {:ok, event} -> {:cont, {:ok, [{entry, event} | decoded_entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded_entries} -> {:ok, Enum.reverse(decoded_entries)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validates whole-prefix relationships after all events have been folded."
  @spec validate_complete(t()) :: :ok | {:error, term()}
  def validate_complete(%State{} = state), do: Completeness.validate(state)

  @spec apply_entry(t(), Entry.t()) :: {:ok, t()} | {:error, term()}
  def apply_entry(%State{} = projection, %Entry{} = entry) do
    with :ok <- validate_entry(projection, entry),
         {:ok, event} <- Event.decode_entry(entry) do
      apply_verified_entry(projection, entry, event)
    end
  end

  def apply_entry(_projection, _entry), do: {:error, :invalid_projection_entry}

  defp apply_decoded_entry(%State{} = projection, %Entry{} = entry, %Event{} = event) do
    with :ok <- validate_entry(projection, entry) do
      apply_verified_entry(projection, entry, event)
    end
  end

  defp validate_entry(projection, entry) do
    with :ok <- Entry.verify(entry),
         true <- entry.domain_ref == projection.domain_ref,
         true <- entry.revision == projection.revision + 1,
         true <- entry.prev_digest == projection.head_digest do
      :ok
    else
      false -> {:error, {:projection_chain_mismatch, entry.revision}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_verified_entry(projection, entry, event) do
    with {:ok, metadata} <- Event.metadata(event),
         {:ok, projection} <- apply_decoded_event(projection, event, entry.revision) do
      {:ok,
       %{
         projection
         | revision: entry.revision,
           head_digest: entry.digest,
           recorded_at: metadata.recorded_at,
           event_metadata: Map.put(projection.event_metadata, Event.key(event), metadata)
       }}
    end
  end

  @doc "Applies one validated event to an in-memory provisional projection."
  @spec apply_payload(t(), map(), non_neg_integer() | nil) :: {:ok, t()} | {:error, term()}
  def apply_payload(projection, payload, revision \\ nil)

  def apply_payload(%State{} = projection, payload, revision)
      when is_map(payload) and not is_struct(payload) do
    with {:ok, event} <- Event.decode(payload) do
      apply_decoded_event(projection, event, revision)
    end
  end

  def apply_payload(_projection, _payload, _revision), do: {:error, :invalid_domain_event}

  @foundation_event_types ~w(
    genesis_recorded
    principal_recorded
    principal_registered
    host_profile_recorded
    host_profile_revised
    definition_revised
    surface_recorded
    surface_revised
  )

  defp apply_decoded_event(projection, %Event{type: type} = event, revision)
       when type in @foundation_event_types,
       do: Foundation.apply(projection, event, revision)

  @authority_event_types ~w(mandate_issued mandate_restricted mandate_revoked)

  defp apply_decoded_event(projection, %Event{type: type} = event, revision)
       when type in @authority_event_types,
       do: AuthorityTransition.apply(projection, event, revision)

  defp apply_decoded_event(projection, %Event{type: "scope_opened"} = event, revision),
    do: ScopeTransition.apply(projection, event, revision)

  @information_event_types ~w(
    declassification_recorded
    evidence_recorded
    presentation_recorded
    erasure_requested
  )

  defp apply_decoded_event(projection, %Event{type: type} = event, revision)
       when type in @information_event_types,
       do: Information.apply(projection, event, revision)

  @admission_event_types ~w(decision_recorded act_committed)

  defp apply_decoded_event(projection, %Event{type: type} = event, revision)
       when type in @admission_event_types,
       do: Admission.apply(projection, event, revision)

  @execution_event_types ~w(dispatch_ready dispatch_cancelled attempt_started outcome_recorded)

  defp apply_decoded_event(projection, %Event{type: type} = event, revision)
       when type in @execution_event_types,
       do: Execution.apply(projection, event, revision)

  @duty_event_types ~w(duty_opened duty_disposed meter_duty_resolved)

  defp apply_decoded_event(projection, %Event{type: type} = event, revision)
       when type in @duty_event_types,
       do: DutyTransition.apply(projection, event, revision)

  defp apply_decoded_event(projection, %Event{type: "meter_reserved", data: data}, _revision),
    do: MeterState.reserve(projection, data)

  defp apply_decoded_event(projection, %Event{type: "meter_settled", data: data}, _revision),
    do: MeterState.transition(projection, data, :settle)

  defp apply_decoded_event(projection, %Event{type: "meter_released", data: data}, _revision),
    do: MeterState.transition(projection, data, :release)

  defp apply_decoded_event(projection, %Event{type: "meter_suspended", data: data}, _revision),
    do: MeterState.transition(projection, data, :suspend)

  defp apply_decoded_event(projection, %Event{type: "meter_recontained", data: data}, _revision),
    do: MeterState.recontain(projection, data)

  defp apply_decoded_event(projection, %Event{type: "meter_devolved", data: data}, _revision),
    do: MeterState.devolve(projection, data)

  defp apply_decoded_event(_projection, %Event{type: type}, _revision),
    do: {:error, {:unsupported_governed_act_event, type}}
end
