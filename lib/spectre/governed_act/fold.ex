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
  alias Spectre.GovernedAct.State
  alias Spectre.GovernedAct.Transition.Admission
  alias Spectre.GovernedAct.Transition.Authority, as: AuthorityTransition
  alias Spectre.GovernedAct.Transition.Duty, as: DutyTransition
  alias Spectre.GovernedAct.Transition.Execution
  alias Spectre.GovernedAct.Transition.Foundation
  alias Spectre.GovernedAct.Transition.Information
  alias Spectre.GovernedAct.Transition.Scope, as: ScopeTransition
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Support

  @provisional_batch_id "spectre:provisional-batch"

  @type t :: State.t()
  @type reservation_status :: State.reservation_status()
  @type dispatch_cancellation :: State.dispatch_cancellation()
  @type meter_recontainment :: State.meter_recontainment()

  @spec new(String.t(), map()) :: t()
  def new(domain_ref, constitution \\ %{}), do: State.new(domain_ref, constitution)

  @doc """
  Folds an already ledger-verified sequence of Domain entries.

  Structural snapshot verification, including complete non-interleaved batch
  topology, belongs to the caller (`Domain.Projection` or `Audit`). This
  function owns only canonical event decoding and governed transition
  semantics, which keeps the two drivers independent at their I/O boundaries
  while making semantic drift impossible.
  """
  @spec replay_verified(String.t(), [Entry.t()], map()) :: {:ok, t()} | {:error, term()}
  def replay_verified(domain_ref, entries, constitution)
      when is_binary(domain_ref) and domain_ref != "" and is_list(entries) and
             is_map(constitution) and not is_struct(constitution) do
    with :ok <- Constitution.validate(constitution) do
      replay_batches(entries, new(domain_ref, constitution))
    end
  end

  def replay_verified(_domain_ref, _entries, _constitution),
    do: {:error, :invalid_governed_history}

  defp replay_batches(entries, initial) do
    entries
    |> Stream.chunk_by(& &1.batch_id)
    |> Enum.reduce_while({:ok, initial}, fn batch, {:ok, projection} ->
      case replay_batch(projection, batch) do
        {:ok, projection} -> {:cont, {:ok, projection}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> complete_replay()
  end

  defp complete_replay({:ok, projection}) do
    with :ok <- validate_complete(projection), do: {:ok, projection}
  end

  defp complete_replay({:error, _reason} = error), do: error

  @doc """
  Applies one complete committed batch to an already verified prefix.

  This is the same transition path as replay, not a second live semantics.
  The caller must establish durability first. The fold checks the exact Domain,
  predecessor digest, revisions, acquisition time and atomic batch coordinates;
  an in-memory result alone is never authority to release a capability.
  """
  @spec append_batch(t(), [Entry.t()]) :: {:ok, t()} | {:error, term()}
  def append_batch(%State{} = projection, [%Entry{} = first | _] = entries) do
    with :ok <- Support.validate_batch_coordinates(entries, projection.domain_ref, first.batch_id),
         true <- first.recorded_at >= projection.recorded_at,
         {:ok, next} <- replay_batch(projection, entries),
         :ok <- validate_complete(next) do
      {:ok, next}
    else
      false -> {:error, {:ledger_time_regression, first.recorded_at, projection.recorded_at}}
      {:error, _} = error -> error
    end
  end

  def append_batch(%State{}, []), do: {:error, :empty_ledger_batch}
  def append_batch(_projection, _entries), do: {:error, :invalid_governed_batch}

  defp replay_batch(projection, entries) do
    entries
    |> Enum.reduce_while({:ok, projection, []}, fn entry, {:ok, current, events} ->
      with {:ok, event} <- Event.decode_entry(entry),
           {:ok, next} <- apply_decoded_entry(current, entry, event) do
        {:cont, {:ok, next, [event | events]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, next, events} ->
        with :ok <- Batch.validate(projection, next, Enum.reverse(events)), do: {:ok, next}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Validates whole-prefix relationships after all events have been folded."
  @spec validate_complete(t()) :: :ok | {:error, term()}
  def validate_complete(%State{} = state), do: Completeness.validate(state)

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
    with {:ok, projection} <- advance(projection, event) do
      {:ok, %{projection | head_digest: entry.digest}}
    end
  end

  defp retain_metadata(metadata, event) do
    if Event.retain_metadata?(event) do
      with {:ok, value} <- Event.metadata(event),
           do: {:ok, Map.put(metadata, event.identity, value)}
    else
      {:ok, metadata}
    end
  end

  @doc "Applies and validates one timestamped payload batch to disposable governed state."
  @spec apply_payloads(t(), [map()], non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def apply_payloads(
        %State{} = projection,
        [_payload | _rest] = payloads,
        recorded_at
      )
      when is_integer(recorded_at) and recorded_at >= 0 do
    with {:ok, next, events} <- fold_payload_batch(projection, payloads, recorded_at),
         :ok <- Batch.validate(projection, next, events) do
      {:ok, next}
    end
  end

  # Idempotent command planners may discover that every requested record is
  # already durable. Treat their empty suffix as a no-op; the ledger writer
  # still rejects attempts to append an empty physical batch.
  def apply_payloads(%State{} = projection, [], recorded_at)
      when is_integer(recorded_at) and recorded_at >= 0,
      do: {:ok, projection}

  def apply_payloads(_projection, _payloads, _recorded_at),
    do: {:error, :invalid_domain_payloads}

  defp fold_payload_batch(projection, payloads, recorded_at) do
    payloads
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, projection, []}, fn {payload, batch_index},
                                                   {:ok, current, events} ->
      with {:ok, event} <-
             Event.decode_payload(
               payload,
               current.revision + 1,
               @provisional_batch_id,
               batch_index,
               recorded_at
             ),
           {:ok, next} <- advance(current, event) do
        {:cont, {:ok, next, [event | events]}}
      else
        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, next, events} -> {:ok, next, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp advance(projection, event) do
    with {:ok, projection} <- apply_decoded_event(projection, event, event.revision),
         {:ok, event_metadata} <- retain_metadata(projection.event_metadata, event) do
      {:ok,
       %{
         projection
         | revision: event.revision,
           recorded_at: event.recorded_at,
           event_metadata: event_metadata
       }}
    end
  end

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
