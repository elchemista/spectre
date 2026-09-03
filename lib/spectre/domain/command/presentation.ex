defmodule Spectre.Domain.Command.Presentation do
  @moduledoc """
  Records a prepared Presentation against a current sealed Scope context.

  Source disclosure, erased Evidence and content payload availability are
  checked before append. Idempotency is by canonical Presentation identity and
  successful results are always read back from recovered ledger state.
  """

  alias Spectre.{Disclosure, Presentation, SubmissionContext}
  alias Spectre.Domain.{Context, Event, Projection, Transaction}
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Payload.Store, as: PayloadStore

  @doc "Validates and durably records a Presentation."
  @spec record(
          State.t(),
          SubmissionContext.t() | term(),
          Presentation.t() | term(),
          keyword(),
          non_neg_integer()
        ) ::
          {:ok, State.t(), Presentation.t()} | {:error, State.t(), term()}

  def record(state, context, input, ledger_opts, conflicts_left) do
    with {:ok, context} <- SubmissionContext.new(context),
         :ok <- Context.validate_ingress(state, context),
         :ok <- SubmissionContext.verify_seal(context, state.grant_secret),
         true <- context.domain_ref == state.domain_ref,
         true <- context.host_generation == state.generation,
         {:ok, opening} <- Projection.scope_context(state.projection, context),
         {:ok, presentation} <- Presentation.new(input),
         {:ok, now} <- Transaction.trusted_recorded_at(state.clock, state.projection),
         :ok <- validate_presentation_boundary(context, opening, presentation, state, now) do
      case existing_presentation(state.projection, presentation) do
        {:ok, durable} ->
          {:ok, state, durable}

        :not_found ->
          append_presentation(
            state,
            context,
            presentation,
            ledger_opts,
            conflicts_left,
            now
          )

        {:error, reason} ->
          {:error, state, reason}
      end
    else
      false -> {:error, state, :presentation_context_not_current}
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

  defp existing_presentation(projection, presentation) do
    case Map.fetch(projection.presentations, presentation.ref) do
      {:ok, existing} ->
        if Presentation.canonical(existing) == Presentation.canonical(presentation),
          do: {:ok, existing},
          else: {:error, {:presentation_identity_conflict, presentation.ref}}

      :error ->
        :not_found
    end
  end

  defp append_presentation(
         state,
         context,
         presentation,
         ledger_opts,
         conflicts_left,
         recorded_at
       ) do
    with {:ok, payload} <- Event.record(:presentation, presentation),
         {:ok, _provisional} <- Transaction.apply_payloads(state.projection, [payload]),
         {:ok, batch_id} <- Transaction.operational_id(state, "presentation") do
      append_result =
        Transaction.append_exact(
          state,
          batch_id,
          [payload],
          state.projection.revision,
          ledger_opts,
          state.ambiguous_retries,
          recorded_at
        )

      Commit.resolve(
        state,
        append_result,
        conflicts_left,
        &recovered_presentation(state, &1, presentation),
        &retry_presentation_after_conflict(state, context, presentation, ledger_opts, &1)
      )
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp retry_presentation_after_conflict(
         state,
         context,
         presentation,
         ledger_opts,
         conflicts_left
       ) do
    case Transaction.recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        record(
          %{state | projection: projection},
          context,
          presentation,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp recovered_presentation(state, projection, presentation) do
    case existing_presentation(projection, presentation) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        halted = Control.halt(state, :presentation_not_recovered)
        {:error, halted, :presentation_not_recovered}

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, reason}
    end
  end
end
