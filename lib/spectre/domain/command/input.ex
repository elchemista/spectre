defmodule Spectre.Domain.Command.Input do
  @moduledoc """
  Converts application input into durable Evidence and sealed Mind Turns.

  Transport and media handling stay outside Spectre. The configured ingress may
  interpret text, audio, telephony events or another application value; this
  command sees only opaque input, validated Evidence and a sealed context. It
  never lets a transport adapter submit an Act or acquire a capability.
  """

  alias Spectre.{Act, Attempt, Evidence, SubmissionContext}
  alias Spectre.Attempt.Evidence, as: AttemptEvidence
  alias Spectre.Domain.Command.Evidence, as: EvidenceCommand
  alias Spectre.Domain.{Context, Projection, Transaction}
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Evidence.Derivation
  alias Spectre.GovernedAct.Index
  alias Spectre.Mind.Context, as: MindContext
  alias Spectre.Mind.Derivation, as: MindDerivation
  alias Spectre.Mind.Turn
  alias Spectre.Scope.View, as: ScopeView

  @doc false
  def prepare_observation(state, context, context_refs) do
    with {:ok, context, _opening} <- Context.validate_scope(state, context),
         {:ok, _evidence} <- scoped_evidence(state.projection, context.scope_ref, context_refs),
         {:ok, now} <- Transaction.trusted_recorded_at(state) do
      {:ok, context, now}
    end
  end

  @doc false
  def finish_observation(state, context, evidence) do
    case Context.validate_scope(state, context) do
      {:ok, _context, _opening} -> EvidenceCommand.record(state, evidence)
      {:error, reason} -> {:error, state, reason}
    end
  end

  @doc false
  def finish_turn(state, context, observed, context_refs) do
    with {:ok, context, _opening} <- Context.validate_scope(state, context),
         {:ok, context_evidence} <-
           scoped_evidence(state.projection, context.scope_ref, context_refs),
         {:ok, opened_at} <- Transaction.trusted_recorded_at(state),
         {:ok, next, durable} <- EvidenceCommand.record(state, observed, opened_at) do
      seal_recorded_turn(next, context, merge_evidence(durable, context_evidence), opened_at)
    else
      {:error, %State{}, _reason} = error -> error
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp seal_recorded_turn(state, context, evidence, opened_at) do
    with {:ok, turn_ref} <- Transaction.operational_id(state),
         {:ok, turn} <- build_turn(state, context, turn_ref, evidence, opened_at) do
      {:ok, state, turn}
    else
      # Evidence is already committed. Keep its confirmed prefix even when
      # constructing the ephemeral Turn fails; never roll back the read model.
      {:error, reason} -> {:error, state, reason}
    end
  end

  @doc "Validates and records one Mind derivation against its sealed Turn."
  @spec record_derivation(
          State.t(),
          SubmissionContext.t() | term(),
          Turn.t(),
          Evidence.t()
        ) :: {:ok, State.t(), Evidence.t()} | {:error, State.t(), term()}
  def record_derivation(state, context_input, turn, evidence) do
    with {:ok, context, opening} <- Context.validate_scope(state, context_input),
         :ok <- Turn.verify_seal(turn, state.grant_secret),
         {:ok, now} <- Transaction.trusted_recorded_at(state),
         {:ok, parents} <- validate_turn(state, context, opening, turn, now),
         :ok <- validate_derivation(evidence, turn, parents, now) do
      EvidenceCommand.record(state, evidence, now)
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  @doc "Revalidates and records Evidence emitted by an executor Attempt."
  @spec record_executor_evidence(
          State.t(),
          String.t(),
          String.t(),
          [Evidence.t()]
        ) :: {:ok, State.t(), [Evidence.t()]} | {:error, State.t(), term()}
  def record_executor_evidence(state, act_ref, attempt_ref, evidence) do
    case validate_executor_evidence(state.projection, act_ref, attempt_ref, evidence) do
      :ok ->
        case EvidenceCommand.record(state, evidence) do
          {:ok, next_state, durable} when is_list(durable) ->
            {:ok, next_state, durable}

          {:error, next_state, reason} ->
            {:error, next_state, reason}

          {:ok, next_state, _invalid} ->
            {:error, Control.halt(next_state, :invalid_executor_evidence_result),
             :invalid_executor_evidence_result}
        end

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp scoped_evidence(_projection, _scope_ref, []), do: {:ok, []}

  defp scoped_evidence(projection, scope_ref, refs) do
    ScopeView.evidence(projection, scope_ref, refs)
  end

  defp merge_evidence(left, right) do
    (left ++ right)
    |> Map.new(&{&1.ref, &1})
    |> Map.values()
    |> Enum.sort_by(& &1.ref)
  end

  defp build_turn(state, context, turn_ref, evidence, opened_at) do
    {evidence, window} =
      MindContext.select(
        state.projection,
        context.scope_ref,
        evidence,
        state.context_limits
      )

    with {:ok, turn} <- Turn.new(context, turn_ref, state.mind_ref, evidence, opened_at),
         do: Turn.seal(%{turn | context_window: window}, state.grant_secret)
  end

  defp validate_turn(state, context, opening, turn, now) do
    expected_context = %{context | seal: nil}

    cond do
      turn.context != expected_context ->
        {:error, :turn_context_mismatch}

      turn.mind_ref != state.mind_ref ->
        {:error, :turn_mind_mismatch}

      not is_integer(turn.opened_at) or turn.opened_at < opening.opened_at or
          turn.opened_at > now ->
        {:error, :turn_time_invalid}

      true ->
        validate_turn_evidence(state.projection, turn)
    end
  end

  defp validate_turn_evidence(projection, turn) do
    evidence_refs = Turn.evidence_refs(turn)

    with :ok <- ErasureAnalysis.validate_evidence_available(projection, evidence_refs),
         {:ok, durable} <- Projection.evidence_set(projection, evidence_refs),
         true <- Evidence.digest_index(durable) == Evidence.digest_index(turn.evidence) do
      {:ok, durable}
    else
      false -> {:error, :turn_evidence_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_derivation(evidence, turn, parents, now),
    do: MindDerivation.validate(evidence, turn, parents, now)

  @spec validate_executor_evidence(map(), String.t(), String.t(), [Evidence.t()]) ::
          :ok | {:error, term()}
  defp validate_executor_evidence(projection, act_ref, attempt_ref, evidence) do
    with {:ok, %Act{} = act} <- Index.fetch_required(projection.acts, act_ref, :act),
         {:ok, %Attempt{} = attempt} <-
           Index.fetch_required(projection.attempts, attempt_ref, :attempt) do
      validate_executor_evidence_records(projection, act, attempt, evidence)
    end
  end

  defp validate_executor_evidence_records(projection, act, attempt, evidence) do
    with :ok <- AttemptEvidence.validate_all(evidence, act, attempt) do
      Enum.reduce_while(evidence, :ok, fn record, :ok ->
        executor_derivation_step(projection, record)
      end)
    end
  end

  defp executor_derivation_step(projection, %{provenance: provenance} = record)
       when provenance in [:derived, :generated] do
    case validate_executor_derivation(projection, record) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp executor_derivation_step(_projection, _record), do: {:cont, :ok}

  defp validate_executor_derivation(projection, evidence) do
    with {:ok, durable_parents} <- Projection.evidence_set(projection, evidence.parent_refs) do
      Derivation.validate(evidence, durable_parents)
    end
  end
end
