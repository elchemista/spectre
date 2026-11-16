defmodule Spectre.GAM.Facade.Observation do
  @moduledoc false

  # These are receipts about an existing Attempt, not new execution requests.
  # The fixed host observer runs outside the Domain and receives no capability.
  # Recorded Evidence survives a later failure to record its Outcome; callers
  # must never interpret that failure as permission to execute again.
  require Spectre.GAM.Portable

  alias Spectre.GAM.Attempt.Runner
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.{Evidence, Outcome, Portable, Scope}
  alias Spectre.GAM.Facade.Access

  @outcome_options [:sequencer_opts]
  @late_observation_options [:observer_opts, :sequencer_opts]
  @outcome_statuses Outcome.statuses()
  @correction_outcome_statuses Outcome.correction_statuses()

  @doc "Records a supported, definitive Outcome for an Act visible in the authenticated Scope."
  @spec record(Scope.t(), Outcome.t() | map() | keyword(), keyword()) ::
          {:ok, Outcome.t()} | {:error, term()}
  def record(%Scope{} = scope, outcome, opts) when is_list(opts) do
    with :ok <- Access.validate_keyword(opts, :outcome_options),
         :ok <- Access.validate_known_options(opts, @outcome_options, :outcome),
         {:ok, outcome} <- Outcome.new(outcome),
         :ok <- late_outcome_has_evidence(outcome),
         {:ok, scope, :ok} <- Access.scoped_read(scope, {:outcome_scope, outcome.act_ref}),
         {:ok, sequencer_opts} <- Access.nested_keyword(opts, :sequencer_opts),
         :ok <- Access.validate_sequencer_options(sequencer_opts),
         {:ok, %Outcome{} = durable} <-
           Access.sequencer_result(
             fn -> Sequencer.record_outcome(scope.domain.server, outcome, sequencer_opts) end,
             :outcome_commit_failed
           ),
         true <- Outcome.canonical(durable) == Outcome.canonical(outcome) do
      {:ok, durable}
    else
      false -> {:error, :outcome_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def record(_scope, _outcome, _opts), do: {:error, :invalid_outcome}

  @doc "Collects a bound late observation with the configured observer and commits Evidence before Outcome."
  @spec record_late(Scope.t(), String.t(), term(), keyword()) ::
          {:ok, %{evidence: [Evidence.t()], outcome: Outcome.t()}} | {:error, term()}
  def record_late(%Scope{} = scope, attempt_ref, input, opts)
      when Portable.is_non_empty_binary(attempt_ref) and is_list(opts) do
    with :ok <- Access.validate_keyword(opts, :late_observation_options),
         :ok <- Access.validate_known_options(opts, @late_observation_options, :late_observation),
         {:ok, scope, {act, attempt}} <-
           Access.scoped_read(scope, {:late_observation, attempt_ref}),
         {:ok, observer_opts} <- Access.nested_keyword(opts, :observer_opts),
         {:ok, sequencer_opts} <- Access.nested_keyword(opts, :sequencer_opts),
         :ok <- Access.validate_sequencer_options(sequencer_opts),
         {:ok, observer} <-
           Access.sequencer_result(
             fn -> Sequencer.late_observer(scope.domain.server) end,
             :late_observer_unavailable
           ),
         {:ok, reported_status, corrected_ref, metadata} <-
           invoke_late_observer(observer, act, attempt, input, observer_opts),
         {:ok, observed_at} <-
           Access.sequencer_result(
             fn -> Sequencer.trusted_time(scope.domain.server, sequencer_opts) end,
             :late_observation_time_unavailable
           ),
         {:ok, observation} <-
           Runner.normalize_late_observation(
             reported_status,
             metadata,
             act,
             attempt,
             observed_at
           ),
         :ok <-
           validate_late_correction(scope, observation, act, attempt, corrected_ref),
         {:ok, recorded_evidence} <-
           record_late_evidence(
             scope.domain.server,
             act,
             attempt,
             observation.evidence,
             sequencer_opts
           ),
         {:ok, outcome} <-
           Runner.Observation.outcome(observation, act, attempt, corrected_ref),
         {:ok, durable} <-
           Access.sequencer_result(
             fn -> Sequencer.record_outcome(scope.domain.server, outcome, sequencer_opts) end,
             :late_outcome_commit_failed
           ),
         true <- Outcome.canonical(durable) == Outcome.canonical(outcome) do
      {:ok, %{evidence: recorded_evidence, outcome: durable}}
    else
      false -> {:error, :late_outcome_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def record_late(_scope, _attempt_ref, _input, _opts),
    do: {:error, :invalid_late_observation}

  defp late_outcome_has_evidence(%Outcome{status: :ambiguous}),
    do: {:error, :public_ambiguous_outcome_forbidden}

  defp late_outcome_has_evidence(%Outcome{evidence_refs: [_first | _rest]}), do: :ok
  defp late_outcome_has_evidence(%Outcome{}), do: {:error, :late_outcome_evidence_required}

  defp invoke_late_observer(observer, act, attempt, input, opts) do
    case Access.safe_call(
           fn -> observer.observe(act, attempt, input, opts) end,
           :late_observation_unavailable
         ) do
      {:ok, {:ok, status, corrected_ref, metadata}}
      when status in @outcome_statuses and
             (is_nil(corrected_ref) or is_binary(corrected_ref)) and is_map(metadata) ->
        {:ok, status, corrected_ref, metadata}

      {:ok, {:error, _reason}} ->
        {:error, :late_observation_unavailable}

      {:ok, _invalid} ->
        {:error, :invalid_late_observer_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_late_correction(_scope, _observation, _act, _attempt, nil), do: :ok

  defp validate_late_correction(scope, observation, act, attempt, corrected_ref) do
    with :ok <- Portable.validate_ref(corrected_ref, :contradicts_outcome_ref),
         true <- observation.status in @correction_outcome_statuses,
         {:ok, corrected} <- Access.scoped_query(scope, {:outcome, corrected_ref}),
         true <- corrected.status == :definitive_no_effect,
         true <- corrected.act_ref == act.ref and corrected.attempt_ref == attempt.ref do
      :ok
    else
      false -> {:error, :invalid_late_outcome_correction}
      {:error, _reason} = error -> error
    end
  end

  defp record_late_evidence(_sequencer, _act, _attempt, [], _opts), do: {:ok, []}

  defp record_late_evidence(sequencer, act, attempt, evidence, opts) do
    with {:ok, recorded} <-
           Access.sequencer_result(
             fn ->
               Sequencer.record_executor_evidence(
                 sequencer,
                 act.ref,
                 attempt.ref,
                 evidence,
                 opts
               )
             end,
             :late_evidence_commit_failed
           ),
         true <- Evidence.digest_index(recorded) == Evidence.digest_index(evidence) do
      {:ok, recorded}
    else
      false -> {:error, :late_evidence_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end
end
