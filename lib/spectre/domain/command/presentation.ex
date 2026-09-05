defmodule Spectre.Domain.Command.Presentation do
  @moduledoc """
  Records a prepared Presentation against a current sealed Scope context.

  Source disclosure, erased Evidence and content payload availability are
  checked before append. Idempotency is by canonical Presentation identity and
  successful results are always read back from recovered ledger state.
  """

  alias Spectre.{Disclosure, Presentation, SubmissionContext}
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Command.Record, as: CommandRecord
  alias Spectre.Domain.{Context, Event, Transaction}
  alias Spectre.Domain.Sequencer.State
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Payload.Store, as: PayloadStore

  @doc "Validates and durably records a Presentation."
  @spec record(
          State.t(),
          SubmissionContext.t() | term(),
          Presentation.t() | term()
        ) ::
          {:ok, State.t(), Presentation.t()} | {:error, State.t(), term()}

  def record(state, context, input) do
    record_with_retries(state, context, input, state.conflict_retries)
  end

  defp record_with_retries(state, context, input, conflicts_left) do
    with {:ok, context, opening} <- Context.validate_scope(state, context),
         {:ok, presentation} <- Presentation.new(input),
         {:ok, now} <- Transaction.trusted_recorded_at(state),
         :ok <- validate_presentation_boundary(context, opening, presentation, state, now) do
      case CommandRecord.lookup(
             state.projection.presentations,
             presentation,
             :presentation_identity_conflict
           ) do
        {:ok, durable} ->
          {:ok, state, durable}

        :not_found ->
          append_presentation(
            state,
            context,
            presentation,
            conflicts_left,
            now
          )

        {:error, reason} ->
          {:error, state, reason}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp validate_presentation_boundary(context, opening, presentation, state, now) do
    cond do
      presentation.scope_ref != context.scope_ref ->
        {:error, :presentation_scope_context_mismatch}

      presentation.prepared_at < opening.opened_at ->
        {:error, {:presentation_precedes_scope, presentation.ref}}

      presentation.prepared_at > now ->
        {:error, {:presentation_from_future, presentation.ref, presentation.prepared_at}}

      true ->
        with :ok <-
               ErasureAnalysis.validate_evidence_available(
                 state.projection,
                 presentation.disclosure.source_evidence_refs
               ),
             :ok <-
               Disclosure.verify_sources(presentation.disclosure, state.projection.evidence) do
          refs =
            PayloadStore.evidence_payload_refs(
              presentation.disclosure.source_evidence_refs,
              state.projection
            ) ++ List.wrap(presentation.rendered_payload_ref)

          PayloadStore.verify_usable(state.payload_store, state.projection, refs)
        end
    end
  end

  defp append_presentation(
         state,
         context,
         presentation,
         conflicts_left,
         recorded_at
       ) do
    case Event.record(:presentation, presentation) do
      {:ok, payload} ->
        Commit.append(
          state,
          [payload],
          recorded_at,
          conflicts_left,
          &recovered_presentation(state, &1, presentation),
          &record_with_retries(&1, context, presentation, &2)
        )

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp recovered_presentation(state, projection, presentation) do
    CommandRecord.recover(
      state,
      projection,
      projection.presentations,
      presentation,
      :presentation_identity_conflict,
      :presentation_not_recovered
    )
  end
end
