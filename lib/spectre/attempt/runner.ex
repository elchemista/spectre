defmodule Spectre.Attempt.Runner do
  @moduledoc """
  Orchestrates the executor-mediated half of a governed Act.

  The Runner consumes only the internal, acknowledged response returned by
  `Spectre.Domain.Sequencer.submit/3`. Refused or undecidable Decisions and
  ledger-internal Acts return immediately. For an executor-mediated Act the
  ordering is strict:

      consume Grant and durably acknowledge Attempt
      -> check out an ephemeral capability
      -> invoke the executor once
      -> record Evidence
      -> record Outcome

  No capability, raw Grant, nonce, exception reason or arbitrary provider reply
  is copied into a durable record. Once an Attempt exists, a malformed reply or
  a broker/executor exception is conservatively recorded as `:ambiguous`. The
  Runner never retries an executor. `Runner.Observation` owns normalization at
  the untrusted callback boundary; `Spectre.Attempt.Binding` owns only the
  immutable Act-to-Attempt identity checked by recovery and replay.
  """

  alias Spectre.GovernedAct.State

  alias Spectre.{Act, Attempt, Decision, Evidence, Outcome}
  alias Spectre.Attempt.Binding, as: AttemptBinding
  alias Spectre.Attempt.Runner.{Observation, Recovery, Result}
  alias Spectre.Domain.Sequencer
  alias Spectre.Execution.Boundary
  alias Spectre.GovernedAct.Admission.Binding, as: AdmissionBinding
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel.Grant
  alias Spectre.Secret.CheckoutReceipt

  @run_options [:sequencer_opts]

  @type admission ::
          {:ok,
           %{
             required(:decision) => Decision.t(),
             required(:act) => Act.t() | nil,
             required(:grant) => Grant.t() | nil
           }}
          | {:error, term()}

  @type run_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Runs at most one external attempt from an acknowledged admission response.

  The executor, broker and their private options are resolved from immutable
  Domain configuration by the exact executor/contract references frozen in the
  Act. Callers may supply only `:sequencer_opts`.

  The result never contains the Grant or capability.
  """
  @spec run(GenServer.server(), admission(), keyword()) :: run_result()
  def run(sequencer, admission, opts \\ [])

  def run(_sequencer, {:error, _reason} = error, opts) do
    with :ok <- validate_options(opts), do: error
  end

  def run(
        sequencer,
        {:ok, %{decision: %Decision{} = decision, act: act, grant: grant} = admission},
        opts
      ) do
    with :ok <- validate_options(opts),
         :ok <- exact_admission_shape(admission),
         {:ok, decision} <- Decision.new(decision) do
      route(sequencer, decision, act, grant, opts)
    end
  end

  def run(_sequencer, _admission, opts) do
    with :ok <- validate_options(opts), do: {:error, :invalid_admission_response}
  end

  @doc false
  @spec normalize_late_observation(
          Outcome.status(),
          map(),
          Act.t(),
          Attempt.t(),
          non_neg_integer()
        ) :: {:ok, map()} | {:error, term()}
  def normalize_late_observation(status, metadata, act, attempt, observed_at),
    do: Observation.normalize_late(status, metadata, act, attempt, observed_at)

  defp route(_sequencer, %Decision{outcome: outcome} = decision, nil, nil, _opts)
       when outcome != :admitted do
    result(decision, nil, nil, [], nil)
  end

  defp route(_sequencer, %Decision{outcome: outcome}, _act, _grant, _opts)
       when outcome != :admitted do
    {:error, :non_admitted_response_contains_capability}
  end

  defp route(
         sequencer,
         %Decision{outcome: :admitted} = decision,
         %Act{} = act,
         grant,
         opts
       ) do
    with {:ok, act} <- Act.new(act),
         :ok <- decision_act_binding(decision, act) do
      case GovernedExecution.mode(act) do
        {:ok, :executor_mediated} -> run_attempt(sequencer, decision, act, grant, opts)
        {:ok, :ledger_internal} -> internal_result(decision, act, grant)
        {:error, _reason} = error -> error
      end
    end
  end

  defp route(_sequencer, %Decision{outcome: :admitted}, _act, _grant, _opts),
    do: {:error, :admitted_response_missing_act}

  defp internal_result(decision, act, nil), do: result(decision, act, nil, [], nil)

  defp internal_result(_decision, _act, _grant),
    do: {:error, :internal_act_must_not_have_grant}

  defp run_attempt(sequencer, decision, act, nil, _opts) do
    case durable_attempt_result(sequencer, decision, act) do
      {:ok, %Result{}} = recovered -> recovered
      :dispatch_ready -> {:error, :executor_mediated_act_missing_grant}
      {:error, _reason} = error -> error
    end
  end

  defp run_attempt(sequencer, decision, act, %Grant{} = grant, opts) do
    with :ok <- grant_act_binding(grant, act) do
      case durable_attempt_result(sequencer, decision, act) do
        {:ok, %Result{}} = recovered ->
          recovered

        :dispatch_ready ->
          run_new_attempt(sequencer, decision, act, grant, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp run_attempt(_sequencer, _decision, _act, _grant, _opts),
    do: {:error, :executor_mediated_act_missing_grant}

  defp run_new_attempt(sequencer, decision, act, grant, opts) do
    result =
      with {:ok, config} <- execution_config(sequencer, act, opts),
           {:ok, consumed_act, attempt, receipt} <-
             consume_grant(sequencer, grant, act, config),
           {:ok, status, evidence, details_ref} <-
             cross_boundary(config, receipt, consumed_act, attempt) do
        finish_attempt(
          sequencer,
          decision,
          consumed_act,
          attempt,
          status,
          evidence,
          details_ref,
          config
        )
      end

    recover_after_failed_start(result, sequencer, decision, act)
  end

  defp recover_after_failed_start({:error, _reason} = error, sequencer, decision, act) do
    case durable_attempt_result(sequencer, decision, act) do
      {:ok, %Result{}} = recovered -> recovered
      _not_completed -> error
    end
  end

  defp recover_after_failed_start(result, _sequencer, _decision, _act), do: result

  defp durable_attempt_result(sequencer, decision, expected_act) do
    case safe_internal_call(fn -> Sequencer.projection(sequencer) end) do
      {:reply, %State{} = projection} ->
        Recovery.from_projection(projection, decision, expected_act)

      {:reply, _invalid} ->
        {:error, :invalid_projection_response}

      {:failure, kind} ->
        {:error, {:projection_boundary_failure, kind}}
    end
  end

  defp consume_grant(sequencer, grant, expected_act, config) do
    case safe_internal_call(fn ->
           Sequencer.consume_grant(
             sequencer,
             grant,
             config.sequencer_opts
           )
         end) do
      {:reply, {:ok, %Act{} = consumed_act, %Attempt{} = attempt, %CheckoutReceipt{} = receipt}} ->
        validate_consumed_attempt(consumed_act, attempt, receipt, expected_act, grant, config)

      {:reply, {:error, reason}} ->
        {:error, {:grant_consumption_failed, reason}}

      {:reply, _invalid} ->
        {:error, :invalid_grant_consumption_response}

      {:failure, kind} ->
        {:error, {:grant_consumption_boundary_failure, kind}}
    end
  end

  defp validate_consumed_attempt(consumed_act, attempt, receipt, expected_act, grant, config) do
    with {:ok, consumed_act} <- Act.new(consumed_act),
         true <- consumed_act == expected_act,
         {:ok, attempt} <- Attempt.new(attempt),
         :ok <- attempt_binding(attempt, consumed_act, :consumed_attempt_binding_mismatch),
         true <- attempt.generation == grant.generation,
         :ok <- checkout_receipt_binding(receipt, consumed_act, attempt, config) do
      {:ok, consumed_act, attempt, receipt}
    else
      false -> {:error, :consumed_attempt_binding_mismatch}
      {:error, reason} -> {:error, {:invalid_consumed_attempt, reason}}
    end
  end

  defp checkout_receipt_binding(receipt, act, attempt, config) do
    expected = %{
      act_ref: act.ref,
      attempt_ref: attempt.ref,
      executor_ref: act.executor_ref,
      material_digest: act.material_digest,
      generation: attempt.generation,
      grant_nonce_digest: attempt.grant_nonce_digest,
      broker_ref: config.broker_descriptor.ref
    }

    if Enum.any?(expected, fn {field, value} -> Map.fetch!(receipt, field) != value end),
      do: {:error, :checkout_receipt_binding_mismatch},
      else: :ok
  end

  defp cross_boundary(config, receipt, act, attempt) do
    case Boundary.invoke(config.broker, :checkout, [
           receipt,
           act,
           attempt,
           config.broker_opts
         ]) do
      {:ok, {:ok, capability}} ->
        execute_once(config, act, attempt, capability)

      {:ok, {:error, status, metadata}}
      when status == :ambiguous ->
        Observation.normalize(status, metadata, :broker, act, attempt)

      {:ok, _invalid} ->
        Observation.boundary_failure(:broker, :invalid_reply)

      {:error, kind} ->
        Observation.boundary_failure(:broker, kind)
    end
  end

  defp execute_once(config, act, attempt, capability) do
    case Boundary.invoke(config.executor, :execute, [
           act,
           attempt,
           capability,
           config.executor_opts
         ]) do
      {:ok, {:ok, metadata}} ->
        Observation.normalize(:succeeded, metadata, :executor, act, attempt)

      {:ok, {:error, status, metadata}}
      when status in [:failed, :definitive_no_effect, :ambiguous] ->
        Observation.normalize(status, metadata, :executor, act, attempt)

      {:ok, _invalid} ->
        Observation.boundary_failure(:executor, :invalid_reply)

      {:error, kind} ->
        Observation.boundary_failure(:executor, kind)
    end
  end

  defp finish_attempt(
         sequencer,
         decision,
         act,
         attempt,
         reported_status,
         evidence,
         details_ref,
         config
       ) do
    {status, outcome_evidence, observed_at, details_ref} =
      case observation_time(sequencer, attempt, config.sequencer_opts) do
        {:ok, observed_at} ->
          Observation.classify(
            reported_status,
            evidence,
            act,
            attempt,
            observed_at,
            details_ref
          )

        {:error, _reason} ->
          {:ambiguous, [], attempt.started_at,
           "spectre:attempt-boundary:clock:unusable-observation-time:v1"}
      end

    case record_evidence(sequencer, act, attempt, evidence, config.sequencer_opts) do
      {:ok, recorded_evidence} ->
        commit_attempt_outcome(
          sequencer,
          decision,
          act,
          attempt,
          status,
          outcome_evidence,
          recorded_evidence,
          details_ref,
          observed_at,
          config.sequencer_opts
        )

      {:error, _reason} ->
        commit_attempt_outcome(
          sequencer,
          decision,
          act,
          attempt,
          :ambiguous,
          [],
          [],
          "spectre:attempt-boundary:ledger:evidence-unacknowledged:v1",
          observed_at,
          config.sequencer_opts
        )
    end
  end

  defp commit_attempt_outcome(
         sequencer,
         decision,
         act,
         attempt,
         status,
         outcome_evidence,
         recorded_evidence,
         details_ref,
         observed_at,
         sequencer_opts
       ) do
    with {:ok, outcome} <-
           build_outcome(
             act,
             attempt,
             status,
             outcome_evidence,
             details_ref,
             observed_at
           ),
         {:ok, outcome} <- record_outcome(sequencer, outcome, sequencer_opts) do
      result(decision, act, attempt, recorded_evidence, outcome)
    end
  end

  defp build_outcome(act, attempt, status, evidence, details_ref, observed_at) do
    Outcome.new(%{
      act_ref: act.ref,
      attempt_ref: attempt.ref,
      status: status,
      evidence_refs: Enum.map(evidence, & &1.ref),
      observed_at: observed_at,
      details_ref: details_ref,
      contradicts_outcome_ref: nil
    })
  end

  defp record_evidence(_sequencer, _act, _attempt, [], _opts), do: {:ok, []}

  defp record_evidence(sequencer, act, attempt, evidence, opts) do
    case safe_internal_call(fn ->
           Sequencer.record_executor_evidence(
             sequencer,
             act.ref,
             attempt.ref,
             evidence,
             opts
           )
         end) do
      {:reply, {:ok, recorded}} when is_list(recorded) ->
        validate_recorded_evidence(evidence, recorded)

      {:reply, {:error, reason}} ->
        {:error, {:evidence_record_failed, reason}}

      {:reply, _invalid} ->
        {:error, :invalid_evidence_record_response}

      {:failure, kind} ->
        {:error, {:evidence_record_boundary_failure, kind}}
    end
  end

  defp validate_recorded_evidence(expected, recorded) do
    with {:ok, recorded} <- Observation.normalize_evidence(recorded),
         true <- evidence_identity(expected) == evidence_identity(recorded) do
      {:ok, recorded}
    else
      false -> {:error, :recorded_evidence_mismatch}
      {:error, _reason} -> {:error, :invalid_recorded_evidence}
    end
  end

  defp evidence_identity(evidence) do
    Map.new(evidence, fn item -> {item.ref, Evidence.digest(item)} end)
  end

  defp record_outcome(sequencer, outcome, opts) do
    case safe_internal_call(fn -> Sequencer.record_outcome(sequencer, outcome, opts) end) do
      {:reply, {:ok, %Outcome{} = recorded}} ->
        with {:ok, recorded} <- Outcome.new(recorded),
             true <- recorded == outcome do
          {:ok, recorded}
        else
          false -> {:error, :recorded_outcome_mismatch}
          {:error, reason} -> {:error, {:invalid_recorded_outcome, reason}}
        end

      {:reply, {:error, reason}} ->
        {:error, {:outcome_record_failed, reason}}

      {:reply, _invalid} ->
        {:error, :invalid_outcome_record_response}

      {:failure, kind} ->
        {:error, {:outcome_record_boundary_failure, kind}}
    end
  end

  defp observation_time(sequencer, %Attempt{started_at: started_at}, opts) do
    case safe_internal_call(fn -> Sequencer.trusted_time(sequencer, opts) end) do
      {:reply, {:ok, time}} when is_integer(time) and time >= started_at -> {:ok, time}
      {:reply, {:ok, time}} when is_integer(time) -> {:error, :outcome_observed_before_attempt}
      {:reply, {:error, reason}} -> {:error, {:trusted_time_unavailable, reason}}
      {:reply, _invalid} -> {:error, :invalid_trusted_time_response}
      {:failure, kind} -> {:error, {:trusted_time_boundary_failure, kind}}
    end
  end

  defp execution_config(sequencer, act, opts) do
    sequencer_opts = Keyword.get(opts, :sequencer_opts, [])

    with :ok <- validate_keyword(sequencer_opts, :sequencer_opts),
         {:ok, route} <- fetch_execution_route(sequencer, act, sequencer_opts),
         :ok <- Boundary.validate_runtime_route(route) do
      {:ok, Map.put(route, :sequencer_opts, sequencer_opts)}
    end
  end

  defp fetch_execution_route(sequencer, act, sequencer_opts) do
    case safe_internal_call(fn -> Sequencer.execution_route(sequencer, act, sequencer_opts) end) do
      {:reply, {:ok, route}} -> {:ok, route}
      {:reply, {:error, reason}} -> {:error, {:execution_route_unavailable, reason}}
      {:reply, _invalid} -> {:error, :invalid_execution_route_response}
      {:failure, kind} -> {:error, {:execution_route_boundary_failure, kind}}
    end
  end

  defp validate_options(opts) do
    with :ok <- validate_keyword(opts, :runner_opts) do
      case Keyword.keys(opts) -- @run_options do
        [] -> :ok
        unknown -> {:error, {:unknown_runner_options, unknown |> Enum.uniq() |> Enum.sort()}}
      end
    end
  end

  defp validate_keyword(value, field) when is_list(value) do
    if Keyword.keyword?(value), do: :ok, else: {:error, {:invalid_keyword_options, field}}
  end

  defp validate_keyword(_value, field), do: {:error, {:invalid_keyword_options, field}}

  defp exact_admission_shape(admission) do
    if map_size(admission) == 3,
      do: :ok,
      else: {:error, :invalid_admission_response}
  end

  defp decision_act_binding(decision, act) do
    case AdmissionBinding.mismatch(decision, act) do
      nil -> :ok
      {:decision_ref, _expected, _actual} -> {:error, :act_decision_ref_mismatch}
      {field, _expected, _actual} -> {:error, {:decision_act_field_mismatch, field}}
    end
  end

  defp attempt_binding(attempt, act, error) do
    if is_nil(AttemptBinding.mismatch(attempt, act)), do: :ok, else: {:error, error}
  end

  defp grant_act_binding(grant, act) do
    if grant.act_ref == act.ref and grant.executor_ref == act.executor_ref and
         grant.material_digest == act.material_digest,
       do: :ok,
       else: {:error, :grant_act_binding_mismatch}
  end

  defp safe_internal_call(function) do
    {:reply, function.()}
  rescue
    _exception -> {:failure, :exception}
  catch
    :exit, _reason -> {:failure, :exit}
    :throw, _reason -> {:failure, :throw}
  end

  defp result(decision, act, attempt, evidence, outcome) do
    Result.ok(decision, act, attempt, evidence, outcome)
  end
end
