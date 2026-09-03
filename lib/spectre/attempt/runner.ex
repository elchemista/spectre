defmodule Spectre.Attempt.Runner.Result do
  @moduledoc """
  Ephemeral summary of one Zone X orchestration.

  A result deliberately excludes the Grant and the checked-out capability. The
  fields it does expose are either durable records or the exact Evidence
  records acknowledged by the Domain sequencer.
  """

  alias Spectre.{Act, Attempt, Decision, Evidence, Outcome}

  @enforce_keys [:decision, :act, :attempt, :evidence, :outcome]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          decision: Decision.t(),
          act: Act.t() | nil,
          attempt: Attempt.t() | nil,
          evidence: [Evidence.t()],
          outcome: Outcome.t() | nil
        }
end

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
  Runner never retries an executor.
  """

  alias Spectre.{Act, Attempt, Decision, Evidence, Outcome, Portable}
  alias Spectre.Attempt.Runner.Result
  alias Spectre.Domain.Sequencer
  alias Spectre.Execution.Boundary
  alias Spectre.Kernel.Grant
  alias Spectre.Outcome.Attestation
  alias Spectre.Secret.CheckoutReceipt

  @decision_act_fields [
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
    :host_profile_ref,
    :surface_revision
  ]

  @admission_keys [:decision, :act, :grant]
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
  def normalize_late_observation(status, metadata, act, attempt, observed_at)
      when status in [:succeeded, :failed, :definitive_no_effect, :ambiguous] and
             is_integer(observed_at) and observed_at >= 0 do
    with {:ok, act} <- Act.new(act),
         {:ok, attempt} <- Attempt.new(attempt),
         true <- attempt.act_ref == act.ref,
         true <- observed_at >= attempt.started_at,
         {:ok, evidence, details_ref} <- validate_observation(metadata, act, attempt) do
      {status, outcome_evidence, observed_at, details_ref} =
        classify_outcome(status, evidence, act, attempt, observed_at, details_ref)

      {:ok,
       %{
         status: status,
         evidence: evidence,
         outcome_evidence: outcome_evidence,
         observed_at: observed_at,
         details_ref: details_ref
       }}
    else
      false -> {:error, :late_observation_cause_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def normalize_late_observation(_status, _metadata, _act, _attempt, _observed_at),
    do: {:error, :invalid_late_observation}

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
      if act.row.attempt do
        run_attempt(sequencer, decision, act, grant, opts)
      else
        internal_result(decision, act, grant)
      end
    end
  end

  defp route(_sequencer, %Decision{outcome: :admitted}, _act, _grant, _opts),
    do: {:error, :admitted_response_missing_act}

  defp internal_result(decision, act, nil), do: result(decision, act, nil, [], nil)

  defp internal_result(_decision, _act, _grant),
    do: {:error, :internal_act_must_not_have_grant}

  defp run_attempt(sequencer, decision, act, %Grant{} = grant, opts) do
    with :ok <- grant_act_binding(grant, act),
         {:ok, config} <- execution_config(sequencer, act, opts),
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
  end

  defp run_attempt(_sequencer, _decision, _act, _grant, _opts),
    do: {:error, :executor_mediated_act_missing_grant}

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
         true <- attempt.act_ref == consumed_act.ref,
         true <- attempt.executor_ref == consumed_act.executor_ref,
         true <- attempt.material_digest == consumed_act.material_digest,
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
    case safe_boundary_call(:broker, fn ->
           config.broker.checkout(receipt, act, attempt, config.broker_opts)
         end) do
      {:reply, {:ok, capability}} ->
        execute_once(config, act, attempt, capability)

      {:reply, {:error, status, metadata}}
      when status == :ambiguous ->
        normalize_observation(status, metadata, :broker, act, attempt)

      {:reply, _invalid} ->
        boundary_observation(:broker, :invalid_reply)

      {:failure, :broker, kind} ->
        boundary_observation(:broker, kind)
    end
  end

  defp execute_once(config, act, attempt, capability) do
    case safe_boundary_call(:executor, fn ->
           config.executor.execute(act, attempt, capability, config.executor_opts)
         end) do
      {:reply, {:ok, metadata}} ->
        normalize_observation(:succeeded, metadata, :executor, act, attempt)

      {:reply, {:error, status, metadata}}
      when status in [:failed, :definitive_no_effect, :ambiguous] ->
        normalize_observation(status, metadata, :executor, act, attempt)

      {:reply, _invalid} ->
        boundary_observation(:executor, :invalid_reply)

      {:failure, :executor, kind} ->
        boundary_observation(:executor, kind)
    end
  end

  defp normalize_observation(status, metadata, boundary, act, attempt) do
    with {:ok, evidence, details_ref} <- validate_observation(metadata, act, attempt) do
      {:ok, status, evidence, details_ref}
    else
      {:error, _reason} -> boundary_observation(boundary, :invalid_metadata)
    end
  end

  defp validate_observation(
         %{evidence: evidence, details_ref: details_ref} = metadata,
         act,
         attempt
       )
       when not is_struct(metadata) do
    with true <- Map.keys(metadata) |> Enum.sort() == [:details_ref, :evidence],
         :ok <- Portable.validate_ref(details_ref, :details_ref),
         {:ok, evidence} <- normalize_evidence(evidence),
         :ok <- unique_evidence(evidence),
         :ok <- validate_boundary_evidence(evidence, act, attempt) do
      {:ok, evidence, details_ref}
    else
      false -> {:error, :invalid_observation_fields}
      {:error, _reason} = error -> error
    end
  end

  defp validate_observation(_metadata, _act, _attempt),
    do: {:error, :invalid_observation_metadata}

  defp normalize_evidence(%Evidence{} = evidence) do
    with {:ok, evidence} <- Evidence.new(evidence), do: {:ok, [evidence]}
  end

  defp normalize_evidence(evidence) when is_list(evidence) do
    Enum.reduce_while(evidence, {:ok, []}, fn
      %Evidence{} = item, {:ok, normalized} ->
        case Evidence.new(item) do
          {:ok, item} -> {:cont, {:ok, [item | normalized]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_observation_evidence}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_evidence(_evidence), do: {:error, :invalid_observation_evidence}

  defp unique_evidence(evidence) do
    refs = Enum.map(evidence, & &1.ref)
    if length(refs) == MapSet.size(MapSet.new(refs)), do: :ok, else: {:error, :duplicate_evidence}
  end

  defp validate_boundary_evidence(evidence, act, attempt) do
    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      with :ok <- exact_attempt_bindings(item, act, attempt),
           :ok <- explicit_executor_lineage(item, act) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp exact_attempt_bindings(%Evidence{} = evidence, act, attempt) do
    expected = %{"act_ref" => act.ref, "attempt_ref" => attempt.ref}

    if evidence.bindings == expected,
      do: :ok,
      else: {:error, {:executor_evidence_binding_mismatch, evidence.ref}}
  end

  defp explicit_executor_lineage(%Evidence{provenance: :observed}, _act), do: :ok

  defp explicit_executor_lineage(
         %Evidence{provenance: provenance, parent_refs: [_first | _rest] = parents} = evidence,
         act
       )
       when provenance in [:derived, :generated] do
    if MapSet.subset?(MapSet.new(parents), MapSet.new(act.evidence_refs)),
      do: :ok,
      else: {:error, {:executor_evidence_parent_outside_act_inputs, evidence.ref}}
  end

  defp explicit_executor_lineage(%Evidence{} = evidence, _act),
    do: {:error, {:invalid_executor_evidence_lineage, evidence.ref}}

  defp boundary_observation(boundary, kind) do
    {:ok, :ambiguous, [], boundary_details_ref(boundary, kind)}
  end

  defp boundary_details_ref(boundary, kind)
       when boundary in [:broker, :executor] and
              kind in [:exception, :exit, :throw, :invalid_reply, :invalid_metadata] do
    "spectre:attempt-boundary:#{boundary}:#{kind}:v1"
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
          classify_outcome(
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

  defp classify_outcome(status, evidence, act, attempt, observed_at, details_ref) do
    supporting = outcome_attestations(evidence, status, act, attempt, observed_at)
    causal = causal_outcome_attestations(evidence, act, attempt, observed_at)

    cond do
      status == :ambiguous ->
        {:ambiguous, causal, observed_at, details_ref}

      supporting != [] and
          not conflicting_outcome_attestation?(evidence, status, act, attempt, observed_at) ->
        {status, supporting, observed_at, details_ref}

      true ->
        {:ambiguous, causal, observed_at, "spectre:attempt-boundary:unattested-outcome:v1"}
    end
  end

  defp outcome_attestations(evidence, status, act, attempt, observed_at) do
    Enum.filter(evidence, &Attestation.supports?(&1, status, act, attempt, observed_at))
  end

  defp causal_outcome_attestations(evidence, act, attempt, observed_at) do
    Enum.filter(evidence, &Attestation.causal?(&1, act, attempt, observed_at))
  end

  defp conflicting_outcome_attestation?(evidence, status, act, attempt, observed_at) do
    Enum.any?(evidence, fn item ->
      Attestation.causal?(item, act, attempt, observed_at) and
        not Attestation.supports?(item, status, act, attempt, observed_at)
    end)
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
    with {:ok, recorded} <- normalize_evidence(recorded),
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
         :ok <- validate_execution_route(route) do
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

  defp validate_execution_route(route) when is_map(route) and not is_struct(route) do
    with true <-
           Map.keys(route) |> Enum.sort() ==
             [:broker, :broker_descriptor, :broker_opts, :executor, :executor_opts],
         :ok <- callback(route.executor, :execute, 4, :executor),
         :ok <- callback(route.broker, :checkout, 4, :broker),
         :ok <- validate_keyword(route.broker_opts, :broker_opts),
         :ok <- validate_keyword(route.executor_opts, :executor_opts),
         :ok <- Boundary.validate_broker_descriptor(route.broker_descriptor) do
      :ok
    else
      false -> {:error, :invalid_execution_route}
      {:error, _reason} = error -> error
    end
  end

  defp validate_execution_route(_route), do: {:error, :invalid_execution_route}

  defp callback(module, function, arity, boundary)
       when is_atom(module) and module not in [nil, true, false] do
    cond do
      not Code.ensure_loaded?(module) -> {:error, {boundary, :module_not_loaded}}
      not function_exported?(module, function, arity) -> {:error, {boundary, :callback_missing}}
      true -> :ok
    end
  end

  defp callback(_module, _function, _arity, boundary), do: {:error, {boundary, :invalid_module}}

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
    if Map.keys(admission) |> Enum.sort() == Enum.sort(@admission_keys),
      do: :ok,
      else: {:error, :invalid_admission_response}
  end

  defp decision_act_binding(decision, act) do
    mismatched =
      Enum.find(@decision_act_fields, fn field ->
        Map.fetch!(decision, field) != Map.fetch!(act, field)
      end)

    cond do
      act.decision_ref != decision.ref -> {:error, :act_decision_ref_mismatch}
      mismatched -> {:error, {:decision_act_field_mismatch, mismatched}}
      true -> :ok
    end
  end

  defp grant_act_binding(grant, act) do
    if grant.act_ref == act.ref and grant.executor_ref == act.executor_ref and
         grant.material_digest == act.material_digest,
       do: :ok,
       else: {:error, :grant_act_binding_mismatch}
  end

  defp safe_boundary_call(boundary, function) do
    {:reply, function.()}
  rescue
    _exception -> {:failure, boundary, :exception}
  catch
    :exit, _reason -> {:failure, boundary, :exit}
    :throw, _reason -> {:failure, boundary, :throw}
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
    {:ok,
     %Result{
       decision: decision,
       act: act,
       attempt: attempt,
       evidence: evidence,
       outcome: outcome
     }}
  end
end
