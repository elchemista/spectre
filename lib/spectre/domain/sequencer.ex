defmodule Spectre.Domain.Sequencer do
  @moduledoc false

  use GenServer

  alias Spectre.{
    Act,
    Attempt,
    Candidate,
    Decision,
    Disclosure,
    Domain,
    Evidence,
    Governance,
    Id,
    Ingress,
    Mind,
    Outcome,
    Portable,
    Presentation,
    Row,
    Scope,
    SubmissionContext
  }

  alias Spectre.Attempt.Reconciler
  alias Spectre.Domain.{Bootstrap, Event, Projection, Recovery}
  alias Spectre.Evidence.Derivation
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Execution.Boundary
  alias Spectre.Kernel, as: GovernedKernel
  alias Spectre.Kernel.{Authority, Commit, Grant, Observation}
  alias Spectre.Ledger.Writer
  alias Spectre.Ledger.Store
  alias Spectre.Mind.Turn
  alias Spectre.Mandate.Ancestry
  alias Spectre.Payload.Store, as: PayloadStore
  alias Spectre.Scope.Opening
  alias Spectre.Scope.View, as: ScopeView
  alias Spectre.Secret.CheckoutReceipt

  @default_batch_size 64
  @default_batch_wait_ms 1
  @default_grant_ttl_ms 30_000
  @default_conflict_retries 8
  @default_ambiguous_retries 2
  @minimum_secret_bytes 32
  @maximum_reconciliation_delay_ms 86_400_000
  @sequencer_call_options [:timeout]
  @authentication_call_options [:timeout, :ingress_opts]
  @observation_call_options [:timeout, :ingress_opts]
  @configuration_options [
    :name,
    :registry,
    :domain_ref,
    :store,
    :ingress,
    :clock,
    :id_source,
    :late_observer,
    :mind,
    :generation,
    :grant_secret,
    :checkout_receipt_secret,
    :grant_ttl_ms,
    :batch_size,
    :batch_wait_ms,
    :conflict_retries,
    :ambiguous_retries,
    :ledger_opts,
    :payload_store,
    :executors,
    :broker,
    :constitution,
    :genesis,
    :principals,
    :host_profile,
    :surface,
    :root_mandates,
    :genesis_verifier
  ]

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :domain_ref,
      :store,
      :projection,
      :clock,
      :id_source,
      :late_observer,
      :mind,
      :mind_ref,
      :ingress,
      :ingress_ref,
      :generation,
      :grant_secret,
      :checkout_receipt_secret,
      :grant_ttl_ms,
      :batch_size,
      :batch_wait_ms,
      :conflict_retries,
      :ambiguous_retries,
      :ledger_opts,
      :payload_store,
      :execution_routes,
      :broker,
      :bootstrap_opts,
      :constitution
    ]
    defstruct @enforce_keys ++
                [
                  pending: [],
                  flush_token: nil,
                  flush_timer: nil,
                  reconciliation_token: nil,
                  reconciliation_timer: nil,
                  halted_reason: nil
                ]
  end

  @typedoc "A successful Admission response; internal Acts carry a nil Grant."
  @type admission_result :: %{
          decision: Decision.t(),
          act: Act.t() | nil,
          grant: Grant.t() | nil
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def start_link(_opts), do: {:error, :invalid_sequencer_options}

  @doc false
  @spec submit(
          GenServer.server(),
          SubmissionContext.t(),
          Candidate.t() | map() | keyword(),
          keyword()
        ) ::
          {:ok, admission_result()} | {:error, term()}
  def submit(server, context, candidate, opts \\ [])

  def submit(server, %SubmissionContext{} = context, candidate, opts)
      when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(server, {:submit, context, candidate, opts}, call_timeout(opts))
    else
      {:error, :invalid_submission_options}
    end
  end

  def submit(_server, _context, _candidate, _opts),
    do: {:error, :invalid_submission_input}

  @doc false
  @spec submit_scope_opening(
          GenServer.server(),
          SubmissionContext.t(),
          SubmissionContext.t(),
          Candidate.t() | map() | keyword(),
          keyword()
        ) :: {:ok, admission_result() | map()} | {:error, term()}
  def submit_scope_opening(server, parent_context, child_context, candidate, opts \\ [])

  def submit_scope_opening(
        server,
        %SubmissionContext{} = parent_context,
        %SubmissionContext{} = child_context,
        candidate,
        opts
      )
      when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(
        server,
        {:submit_scope_opening, parent_context, child_context, candidate, opts},
        call_timeout(opts)
      )
    else
      {:error, :invalid_governed_scope_opening_options}
    end
  end

  def submit_scope_opening(_server, _parent_context, _child_context, _candidate, _opts),
    do: {:error, :invalid_governed_scope_opening_input}

  @doc false
  @spec authenticate(GenServer.server(), String.t(), term(), keyword()) ::
          {:ok, SubmissionContext.t()} | {:error, term()}
  def authenticate(server, scope_ref, input, opts \\ [])

  def authenticate(server, scope_ref, input, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(server, {:authenticate, scope_ref, input, opts}, call_timeout(opts))
    else
      {:error, :invalid_authentication_options}
    end
  end

  def authenticate(_server, _scope_ref, _input, _opts),
    do: {:error, :invalid_authentication_options}

  @doc false
  @spec consume_grant(GenServer.server(), Grant.t(), keyword()) ::
          {:ok, Act.t(), Attempt.t(), CheckoutReceipt.t()} | {:error, term()}
  def consume_grant(server, grant, opts \\ [])

  def consume_grant(server, %Grant{} = grant, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:consume_grant, grant, opts}, call_timeout(opts)),
      else: {:error, :invalid_grant_consumption_options}
  end

  def consume_grant(_server, _grant, _opts), do: {:error, :invalid_grant}

  @doc false
  @spec execution_route(GenServer.server(), Act.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execution_route(server, act, opts \\ [])

  def execution_route(server, %Act{} = act, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(
        server,
        {:execution_route, act.executor_ref, act.executor_contract_ref, opts},
        call_timeout(opts)
      )
    else
      {:error, :invalid_execution_route_options}
    end
  end

  def execution_route(_server, _act, _opts), do: {:error, :invalid_execution_route}

  @doc false
  @spec record_outcome(GenServer.server(), Outcome.t() | map() | keyword(), keyword()) ::
          {:ok, Outcome.t()} | {:error, term()}
  def record_outcome(server, outcome, opts \\ [])

  def record_outcome(server, outcome, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(server, {:record_outcome, outcome, opts}, call_timeout(opts))
    else
      {:error, :invalid_outcome_options}
    end
  end

  def record_outcome(_server, _outcome, _opts), do: {:error, :invalid_outcome_options}

  @doc false
  @spec observe(GenServer.server(), SubmissionContext.t(), term(), keyword()) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def observe(server, context, input, opts \\ [])

  def observe(server, %SubmissionContext{} = context, input, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:observe, context, input, opts}, call_timeout(opts)),
      else: {:error, :invalid_observation_options}
  end

  def observe(_server, _context, _input, _opts), do: {:error, :invalid_observation_input}

  @doc false
  @spec begin_turn(
          GenServer.server(),
          SubmissionContext.t(),
          term(),
          [String.t()],
          keyword()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def begin_turn(server, context, input, context_evidence_refs, opts \\ [])

  def begin_turn(
        server,
        %SubmissionContext{} = context,
        input,
        context_evidence_refs,
        opts
      )
      when is_list(context_evidence_refs) and is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(
        server,
        {:begin_turn, context, input, context_evidence_refs, opts},
        call_timeout(opts)
      )
    else
      {:error, :invalid_turn_options}
    end
  end

  def begin_turn(_server, _context, _input, _context_refs, _opts),
    do: {:error, :invalid_turn_input}

  @doc false
  @spec record_derivation(
          GenServer.server(),
          SubmissionContext.t(),
          Turn.t(),
          Evidence.t() | map() | keyword(),
          keyword()
        ) :: {:ok, Evidence.t()} | {:error, term()}
  def record_derivation(server, context, turn, evidence, opts \\ [])

  def record_derivation(
        server,
        %SubmissionContext{} = context,
        %Turn{} = turn,
        evidence,
        opts
      )
      when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(
        server,
        {:record_derivation, context, turn, evidence, opts},
        call_timeout(opts)
      )
    else
      {:error, :invalid_derivation_options}
    end
  end

  def record_derivation(_server, _context, _turn, _evidence, _opts),
    do: {:error, :invalid_derivation_input}

  @doc false
  @spec record_executor_evidence(
          GenServer.server(),
          String.t(),
          String.t(),
          Evidence.t() | [Evidence.t()],
          keyword()
        ) :: {:ok, [Evidence.t()]} | {:error, term()}
  def record_executor_evidence(server, act_ref, attempt_ref, evidence, opts \\ [])

  def record_executor_evidence(server, act_ref, attempt_ref, evidence, opts)
      when is_binary(act_ref) and act_ref != "" and is_binary(attempt_ref) and attempt_ref != "" and
             is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(
        server,
        {:record_executor_evidence, act_ref, attempt_ref, evidence, opts},
        call_timeout(opts)
      )
    else
      {:error, :invalid_executor_evidence_options}
    end
  end

  def record_executor_evidence(_server, _act_ref, _attempt_ref, _evidence, _opts),
    do: {:error, :invalid_executor_evidence_input}

  @doc false
  @spec record_presentation(
          GenServer.server(),
          SubmissionContext.t(),
          Presentation.t() | map() | keyword(),
          keyword()
        ) :: {:ok, Presentation.t()} | {:error, term()}
  def record_presentation(server, context, presentation, opts \\ [])

  def record_presentation(server, %SubmissionContext{} = context, presentation, opts)
      when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(
        server,
        {:record_presentation, context, presentation, opts},
        call_timeout(opts)
      )
    else
      {:error, :invalid_presentation_options}
    end
  end

  def record_presentation(_server, _context, _presentation, _opts),
    do: {:error, :authenticated_scope_context_required}

  @doc false
  @spec open_scope(
          GenServer.server(),
          SubmissionContext.t(),
          Opening.t() | map() | keyword(),
          keyword()
        ) :: {:ok, Opening.t()} | {:error, term()}
  def open_scope(server, context, opening, opts \\ [])

  def open_scope(server, %SubmissionContext{} = context, opening, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      GenServer.call(server, {:open_scope, context, opening, opts}, call_timeout(opts))
    else
      {:error, :invalid_scope_opening_options}
    end
  end

  def open_scope(_server, _context, _opening, _opts),
    do: {:error, :authenticated_scope_context_required}

  @doc false
  @spec resume_scope(GenServer.server(), SubmissionContext.t()) ::
          {:ok, Opening.t()} | {:error, term()}
  def resume_scope(server, %SubmissionContext{} = context),
    do: GenServer.call(server, {:resume_scope, context})

  def resume_scope(_server, _context), do: {:error, :authenticated_scope_context_required}

  @doc false
  @spec projection(GenServer.server()) :: Projection.t()
  def projection(server), do: GenServer.call(server, :projection)

  @doc false
  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server), do: GenServer.call(server, :generation)

  @doc false
  @spec late_observer(GenServer.server()) :: {:ok, module()} | {:error, term()}
  def late_observer(server), do: GenServer.call(server, :late_observer)

  @doc false
  @spec mind(GenServer.server()) :: {:ok, module()} | {:error, term()}
  def mind(server), do: GenServer.call(server, :mind)

  @doc false
  @spec trusted_time(GenServer.server(), keyword()) :: {:ok, integer()} | {:error, term()}
  def trusted_time(server, opts \\ [])

  def trusted_time(server, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:trusted_time, opts}, call_timeout(opts)),
      else: {:error, :invalid_trusted_time_options}
  end

  def trusted_time(_server, _opts), do: {:error, :invalid_trusted_time_options}

  @impl GenServer
  def init(opts) do
    with {:ok, config} <- configuration(opts),
         {:ok, projection} <- recover_or_bootstrap(config),
         :ok <- Bootstrap.verify_projection(projection, config.bootstrap_opts),
         state = struct!(State, Map.put(config, :projection, projection)),
         {:ok, projection} <-
           repair_missing_duties(
             state,
             projection,
             config.ledger_opts,
             config.conflict_retries
           ),
         :ok <- validate_pending_execution_routes(projection, config) do
      {:ok, schedule_reconciliation(%{state | projection: projection})}
    else
      {:error, reason} -> {:stop, reason}
      :not_found -> {:stop, :domain_bootstrap_not_durable}
    end
  end

  @impl GenServer
  def handle_call(:projection, _from, %State{} = state),
    do: {:reply, state.projection, state}

  def handle_call(:generation, _from, %State{} = state),
    do: {:reply, state.generation, state}

  def handle_call(:late_observer, _from, %State{late_observer: nil} = state),
    do: {:reply, {:error, :late_observer_not_configured}, state}

  def handle_call(:late_observer, _from, %State{} = state),
    do: {:reply, {:ok, state.late_observer}, state}

  def handle_call(:mind, _from, %State{mind: nil} = state),
    do: {:reply, {:error, :mind_not_configured}, state}

  def handle_call(:mind, _from, %State{} = state),
    do: {:reply, {:ok, state.mind}, state}

  def handle_call({:resume_scope, context}, _from, %State{} = state) do
    reply =
      with {:ok, context} <- SubmissionContext.new(context),
           :ok <- validate_context_ingress(state, context),
           :ok <- SubmissionContext.verify_seal(context, state.grant_secret),
           true <- context.domain_ref == state.domain_ref,
           true <- context.host_generation == state.generation,
           {:ok, opening} <- Projection.scope_context(state.projection, context) do
        {:ok, opening}
      else
        false -> {:error, :scope_resume_context_not_current}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call(_request, _from, %State{halted_reason: reason} = state)
      when not is_nil(reason),
      do: {:reply, {:error, {:sequencer_halted, reason}}, state}

  def handle_call(
        {:execution_route, executor_ref, contract_ref, opts},
        _from,
        %State{} = state
      ) do
    reply =
      with :ok <- validate_known_options(opts, @sequencer_call_options, :execution_route),
           do: configured_execution_route(state, executor_ref, contract_ref)

    {:reply, reply, state}
  end

  def handle_call({:authenticate, scope_ref, input, opts}, _from, %State{} = state) do
    {:reply, authenticate_context(state, scope_ref, input, opts), state}
  end

  def handle_call({:trusted_time, opts}, _from, %State{} = state) do
    reply =
      with :ok <- validate_known_options(opts, @sequencer_call_options, :trusted_time),
           do: trusted_recorded_at(state.clock, state.projection)

    {:reply, reply, state}
  end

  def handle_call({:submit, context, candidate, opts}, from, %State{} = state) do
    case effective_ledger_opts(state, opts) do
      {:ok, ledger_opts} ->
        request = %{
          from: from,
          context: context,
          candidate: candidate,
          ledger_opts: ledger_opts,
          kind: :candidate
        }

        state = enqueue_submission(state, request)
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:submit_scope_opening, parent_context, child_context, candidate, opts},
        from,
        %State{} = state
      ) do
    case effective_ledger_opts(state, opts) do
      {:ok, ledger_opts} ->
        request = %{
          from: from,
          context: parent_context,
          child_context: child_context,
          candidate: candidate,
          ledger_opts: ledger_opts,
          kind: :governed_scope_opening
        }

        {:noreply, enqueue_submission(state, request)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_grant, grant, opts}, _from, %State{} = state) do
    case effective_ledger_opts(state, opts) do
      {:ok, ledger_opts} ->
        consume_grant_reply(state, grant, ledger_opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_outcome, input, opts}, _from, %State{} = state) do
    case effective_ledger_opts(state, opts) do
      {:ok, ledger_opts} ->
        record_outcome_reply(state, input, ledger_opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:observe, context, input, opts}, _from, %State{} = state),
    do: ingress_observation_reply(state, context, input, opts)

  def handle_call(
        {:begin_turn, context, input, context_evidence_refs, opts},
        _from,
        %State{} = state
      ),
      do: begin_turn_reply(state, context, input, context_evidence_refs, opts)

  def handle_call({:record_derivation, context, turn, evidence, opts}, _from, %State{} = state),
    do: derivation_reply(state, context, turn, evidence, opts)

  def handle_call(
        {:record_executor_evidence, act_ref, attempt_ref, evidence, opts},
        _from,
        %State{} = state
      ),
      do: executor_evidence_reply(state, act_ref, attempt_ref, evidence, opts)

  def handle_call({:open_scope, context, input, opts}, _from, %State{} = state) do
    case effective_ledger_opts(state, opts) do
      {:ok, ledger_opts} ->
        open_scope_reply(state, context, input, ledger_opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_presentation, context, input, opts}, _from, %State{} = state) do
    case effective_ledger_opts(state, opts) do
      {:ok, ledger_opts} ->
        record_presentation_reply(state, context, input, ledger_opts)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp consume_grant_reply(state, grant, ledger_opts) do
    case preflight_duty_repair(state, ledger_opts) do
      {:ok, current} ->
        case consume_attempt(current, grant, ledger_opts, current.conflict_retries) do
          {:ok, next_state, act, attempt, receipt} ->
            {:reply, {:ok, act, attempt, receipt}, schedule_reconciliation(next_state)}

          {:error, next_state, reason} ->
            {:reply, {:error, reason}, schedule_reconciliation(next_state)}
        end

      {:error, halted, reason} ->
        {:reply, {:error, reason}, halted}
    end
  end

  defp record_outcome_reply(state, input, ledger_opts) do
    case preflight_duty_repair(state, ledger_opts) do
      {:ok, current} ->
        case record_observation(current, input, ledger_opts, current.conflict_retries) do
          {:ok, next_state, outcome} ->
            {:reply, {:ok, outcome}, schedule_reconciliation(next_state)}

          {:error, next_state, reason} ->
            {:reply, {:error, reason}, schedule_reconciliation(next_state)}
        end

      {:error, halted, reason} ->
        {:reply, {:error, reason}, halted}
    end
  end

  defp ingress_observation_reply(state, context, input, opts) do
    with {:ok, ingress_opts} <- observation_options(opts) do
      case preflight_duty_repair(state, state.ledger_opts) do
        {:ok, current} ->
          case record_ingress_observation(current, context, input, ingress_opts) do
            {:ok, next_state, evidence, _observed_at} ->
              {:reply, {:ok, evidence}, schedule_reconciliation(next_state)}

            {:error, next_state, reason} ->
              {:reply, {:error, reason}, schedule_reconciliation(next_state)}
          end

        {:error, halted, reason} ->
          {:reply, {:error, reason}, halted}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp begin_turn_reply(state, context, input, context_evidence_refs, opts) do
    with {:ok, _mind} <- configured_mind(state),
         {:ok, ingress_opts} <- observation_options(opts),
         {:ok, context_evidence_refs} <-
           Portable.normalize_refs(context_evidence_refs, :context_evidence_refs) do
      case preflight_duty_repair(state, state.ledger_opts) do
        {:ok, current} ->
          begin_validated_turn(
            current,
            context,
            input,
            context_evidence_refs,
            ingress_opts
          )

        {:error, halted, reason} ->
          {:reply, {:error, reason}, halted}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp configured_mind(%State{mind: nil}), do: {:error, :mind_not_configured}
  defp configured_mind(%State{mind: mind}), do: {:ok, mind}

  defp begin_validated_turn(state, context, input, context_evidence_refs, ingress_opts) do
    with {:ok, context, _opening} <- live_scope_context(state, context),
         {:ok, context_evidence} <-
           scoped_evidence(state.projection, context.scope_ref, context_evidence_refs),
         {:ok, next_state, observed, opened_at} <-
           record_ingress_observation(state, context, input, ingress_opts),
         evidence <- merge_evidence(observed, context_evidence),
         {:ok, turn_ref} <- operational_id(next_state, "turn"),
         {:ok, turn} <- build_turn(next_state, context, turn_ref, evidence, opened_at) do
      {:reply, {:ok, turn}, schedule_reconciliation(next_state)}
    else
      {:error, %State{} = next_state, reason} ->
        {:reply, {:error, reason}, schedule_reconciliation(next_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp derivation_reply(state, context, turn, input, opts) do
    with {:ok, ledger_opts} <- effective_ledger_opts(state, opts),
         {:ok, evidence} <- Evidence.new(input) do
      case preflight_duty_repair(state, ledger_opts) do
        {:ok, current} ->
          record_validated_derivation(current, context, turn, evidence, ledger_opts)

        {:error, halted, reason} ->
          {:reply, {:error, reason}, halted}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp record_validated_derivation(state, context, turn, evidence, ledger_opts) do
    with {:ok, context, opening} <- live_scope_context(state, context),
         :ok <- Turn.verify_seal(turn, state.grant_secret),
         {:ok, now} <- trusted_recorded_at(state.clock, state.projection),
         {:ok, parents} <- validate_turn(state, context, opening, turn, now),
         :ok <- validate_derivation(evidence, context, turn, parents, now) do
      case record_evidence_batch(
             state,
             evidence,
             ledger_opts,
             state.conflict_retries,
             now
           ) do
        {:ok, next_state, %Evidence{} = durable} ->
          {:reply, {:ok, durable}, schedule_reconciliation(next_state)}

        {:error, next_state, reason} ->
          {:reply, {:error, reason}, schedule_reconciliation(next_state)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp executor_evidence_reply(state, act_ref, attempt_ref, input, opts) do
    with {:ok, ledger_opts} <- effective_ledger_opts(state, opts),
         {:ok, evidence, _shape} <- normalize_evidence_input(input),
         :ok <- validate_executor_evidence(state.projection, act_ref, attempt_ref, evidence) do
      case preflight_duty_repair(state, ledger_opts) do
        {:ok, current} ->
          commit_executor_evidence(current, act_ref, attempt_ref, evidence, ledger_opts)

        {:error, halted, reason} ->
          {:reply, {:error, reason}, halted}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp commit_executor_evidence(state, act_ref, attempt_ref, evidence, ledger_opts) do
    with :ok <- validate_executor_evidence(state.projection, act_ref, attempt_ref, evidence) do
      case record_evidence_batch(
             state,
             evidence,
             ledger_opts,
             state.conflict_retries
           ) do
        {:ok, next_state, durable} when is_list(durable) ->
          {:reply, {:ok, durable}, schedule_reconciliation(next_state)}

        {:error, next_state, reason} ->
          {:reply, {:error, reason}, schedule_reconciliation(next_state)}

        {:ok, next_state, _invalid} ->
          {:reply, {:error, :invalid_executor_evidence_result},
           halt(next_state, :invalid_executor_evidence_result)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp open_scope_reply(state, context, input, ledger_opts) do
    case open_scope_record(
           state,
           context,
           input,
           ledger_opts,
           state.conflict_retries
         ) do
      {:ok, next_state, opening} ->
        {:reply, {:ok, opening}, schedule_reconciliation(next_state)}

      {:error, next_state, reason} ->
        {:reply, {:error, reason}, schedule_reconciliation(next_state)}
    end
  end

  defp record_presentation_reply(state, context, input, ledger_opts) do
    case record_presentation_record(
           state,
           context,
           input,
           ledger_opts,
           state.conflict_retries
         ) do
      {:ok, next_state, presentation} ->
        {:reply, {:ok, presentation}, schedule_reconciliation(next_state)}

      {:error, next_state, reason} ->
        {:reply, {:error, reason}, schedule_reconciliation(next_state)}
    end
  end

  @impl GenServer
  def handle_info({:stop_halted, reason}, %State{halted_reason: reason} = state),
    do: {:stop, {:shutdown, {:sequencer_halted, reason}}, state}

  def handle_info({:stop_halted, _stale_reason}, %State{} = state),
    do: {:noreply, state}

  def handle_info({:flush, token}, %State{flush_token: token} = state) do
    ordered = Enum.reverse(state.pending)
    {requests, remaining} = Enum.split(ordered, state.batch_size)

    state = %{
      state
      | pending: Enum.reverse(remaining),
        flush_token: nil,
        flush_timer: nil
    }

    state = process_submission_groups(state, requests)
    state = state |> schedule_remaining() |> schedule_reconciliation()
    {:noreply, state}
  end

  def handle_info({:flush, _stale_token}, %State{} = state), do: {:noreply, state}

  def handle_info({:reconcile, token}, %State{reconciliation_token: token} = state) do
    state = %{state | reconciliation_token: nil, reconciliation_timer: nil}

    case repair_missing_duties(
           state,
           state.projection,
           state.ledger_opts,
           state.conflict_retries
         ) do
      {:ok, projection} ->
        {:noreply, schedule_reconciliation(%{state | projection: projection})}

      {:error, reason} ->
        {:noreply, halt(state, {:reconciliation_failed, reason})}
    end
  end

  def handle_info({:reconcile, _stale_token}, %State{} = state), do: {:noreply, state}

  defp call_timeout(opts), do: Keyword.get(opts, :timeout, :infinity)

  defp configuration(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_known_options(opts, @configuration_options, :sequencer_configuration),
         {:ok, domain_ref} <- required_non_empty_binary(opts, :domain_ref),
         {:ok, store} <- required_store(opts),
         {:ok, {ingress, ingress_ref}} <- required_ingress(opts),
         {:ok, payload_store} <- PayloadStore.normalize(Keyword.get(opts, :payload_store)),
         {:ok, clock} <- module_with_callback(opts, :clock, Spectre.Clock.System, :now, 0),
         {:ok, id_source} <-
           module_with_callback(opts, :id_source, Spectre.Id.UUIDv7, :generate, 0),
         {:ok, late_observer} <- late_observer_option(opts),
         {:ok, {mind, mind_ref}} <- mind_option(opts),
         {:ok, execution_boundary} <-
           Boundary.normalize(Keyword.get(opts, :executors, []), Keyword.get(opts, :broker)),
         {:ok, generation} <- generation_option(opts),
         {:ok, grant_secret} <- grant_secret_option(opts),
         {:ok, checkout_receipt_secret} <- checkout_receipt_secret_option(opts),
         {:ok, grant_ttl_ms} <- positive_option(opts, :grant_ttl_ms, @default_grant_ttl_ms),
         {:ok, batch_size} <- positive_option(opts, :batch_size, @default_batch_size),
         {:ok, batch_wait_ms} <-
           non_negative_option(opts, :batch_wait_ms, @default_batch_wait_ms),
         {:ok, conflict_retries} <-
           non_negative_option(opts, :conflict_retries, @default_conflict_retries),
         {:ok, ambiguous_retries} <-
           non_negative_option(opts, :ambiguous_retries, @default_ambiguous_retries),
         {:ok, ledger_opts} <- keyword_option(opts, :ledger_opts, []),
         {:ok, constitution} <- constitution_option(opts),
         {:ok, _now} <- trusted_now(clock) do
      {:ok,
       %{
         domain_ref: domain_ref,
         store: store,
         ingress: ingress,
         ingress_ref: ingress_ref,
         clock: clock,
         id_source: id_source,
         late_observer: late_observer,
         mind: mind,
         mind_ref: mind_ref,
         execution_routes: execution_boundary.routes,
         broker: execution_boundary.broker,
         generation: generation,
         grant_secret: grant_secret,
         checkout_receipt_secret: checkout_receipt_secret,
         grant_ttl_ms: grant_ttl_ms,
         batch_size: batch_size,
         batch_wait_ms: batch_wait_ms,
         conflict_retries: conflict_retries,
         ambiguous_retries: ambiguous_retries,
         ledger_opts: ledger_opts,
         payload_store: payload_store,
         bootstrap_opts: opts,
         constitution: constitution
       }}
    else
      false -> {:error, :invalid_sequencer_options}
      {:error, _reason} = error -> error
    end
  end

  defp required_non_empty_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      :error -> {:error, {:missing_sequencer_option, key}}
      {:ok, _invalid} -> {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp required_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.normalize(store)
      :error -> {:error, {:missing_sequencer_option, :store}}
    end
  end

  defp required_ingress(opts) do
    case Keyword.fetch(opts, :ingress) do
      {:ok, module} -> Ingress.resolve(module)
      :error -> {:error, {:missing_sequencer_option, :ingress}}
    end
  end

  defp module_with_callback(opts, key, default, callback, arity) do
    module = Keyword.get(opts, key, default)

    cond do
      not is_atom(module) or is_nil(module) ->
        {:error, {:invalid_sequencer_option, key}}

      not Code.ensure_loaded?(module) or not function_exported?(module, callback, arity) ->
        {:error, {:sequencer_callback_unavailable, key, module, callback, arity}}

      true ->
        {:ok, module}
    end
  end

  defp generation_option(opts) do
    case Keyword.fetch(opts, :generation) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _invalid} -> {:error, {:invalid_sequencer_option, :generation}}
      :error -> {:ok, :binary.decode_unsigned(:crypto.strong_rand_bytes(8))}
    end
  end

  defp late_observer_option(opts) do
    case Keyword.get(opts, :late_observer) do
      nil ->
        {:ok, nil}

      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :observe, 4),
          do: {:ok, module},
          else: {:error, {:sequencer_callback_unavailable, :late_observer, module, :observe, 4}}

      _invalid ->
        {:error, {:invalid_sequencer_option, :late_observer}}
    end
  end

  defp mind_option(opts) do
    case Keyword.get(opts, :mind) do
      nil -> {:ok, {nil, nil}}
      module -> Mind.resolve(module)
    end
  end

  defp grant_secret_option(opts) do
    case Keyword.fetch(opts, :grant_secret) do
      {:ok, value} when is_binary(value) and byte_size(value) >= @minimum_secret_bytes ->
        {:ok, value}

      {:ok, _invalid} ->
        {:error, {:invalid_sequencer_option, :grant_secret}}

      :error ->
        {:ok, :crypto.strong_rand_bytes(@minimum_secret_bytes)}
    end
  end

  defp checkout_receipt_secret_option(opts) do
    case Keyword.fetch(opts, :checkout_receipt_secret) do
      {:ok, value} when is_binary(value) and byte_size(value) >= @minimum_secret_bytes ->
        {:ok, value}

      {:ok, _invalid} ->
        {:error, {:invalid_sequencer_option, :checkout_receipt_secret}}

      :error ->
        {:ok, :crypto.strong_rand_bytes(@minimum_secret_bytes)}
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp keyword_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_list(value) ->
        if Keyword.keyword?(value),
          do: {:ok, value},
          else: {:error, {:invalid_sequencer_option, key}}

      _invalid ->
        {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp constitution_option(opts) do
    case Keyword.get(opts, :constitution, %{}) do
      value when is_map(value) and not is_struct(value) ->
        case Spectre.Portable.validate(value) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, {:invalid_constitution, reason}}
        end

      _invalid ->
        {:error, :invalid_constitution}
    end
  end

  defp recover_or_bootstrap(config) do
    case Recovery.recover(config.store, config.domain_ref, config.ledger_opts) do
      {:ok, projection} ->
        with :ok <- PayloadStore.verify_live_references(config.payload_store, projection) do
          {:ok, projection}
        end

      :not_found ->
        bootstrap(config)

      {:error, _reason} = error ->
        error
    end
  end

  defp bootstrap(config) do
    with {:ok, prepared} <- Bootstrap.prepare(config.domain_ref, config.bootstrap_opts),
         {:ok, recorded_at} <- trusted_now(config.clock) do
      case append_bootstrap(
             config,
             prepared.batch_id,
             prepared.payloads,
             recorded_at,
             config.ambiguous_retries
           ) do
        :ok -> recover_bootstrapped(config)
        :conflict -> recover_bootstrapped(config)
        {:error, _reason} = error -> error
      end
    end
  end

  defp append_bootstrap(config, batch_id, payloads, recorded_at, ambiguous_retries) do
    with :ok <- verify_payload_references(config.payload_store, payloads) do
      Writer.append(
        config.store,
        config.domain_ref,
        batch_id,
        payloads,
        0,
        Keyword.put(config.ledger_opts, :recorded_at, recorded_at)
      )
    end
    |> case do
      {:ok, _revision} ->
        :ok

      {:error, :conflict} ->
        :conflict

      {:error, :ambiguous} ->
        classify_bootstrap_ambiguity(
          config,
          batch_id,
          payloads,
          recorded_at,
          ambiguous_retries
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp classify_bootstrap_ambiguity(
         config,
         batch_id,
         payloads,
         recorded_at,
         ambiguous_retries
       ) do
    case Recovery.classify_ambiguous(
           config.store,
           config.domain_ref,
           batch_id,
           payloads,
           0,
           config.ledger_opts
         ) do
      {:ok, {:committed, _info}} ->
        :ok

      {:ok, :not_committed} when ambiguous_retries > 0 ->
        append_bootstrap(config, batch_id, payloads, recorded_at, ambiguous_retries - 1)

      {:ok, :not_committed} ->
        {:error, :ambiguous_bootstrap_unresolved}

      {:error, _reason} = error ->
        error
    end
  end

  defp recover_bootstrapped(config) do
    case Recovery.recover(config.store, config.domain_ref, config.ledger_opts) do
      {:ok, projection} ->
        with :ok <- PayloadStore.verify_live_references(config.payload_store, projection) do
          {:ok, projection}
        end

      :not_found ->
        {:error, :domain_bootstrap_not_durable}

      {:error, _reason} = error ->
        error
    end
  end

  defp enqueue_submission(%State{} = state, request) do
    pending = [request | state.pending]
    state = %{state | pending: pending}

    cond do
      state.flush_token == nil -> schedule_flush(state, state.batch_wait_ms)
      length(pending) >= state.batch_size -> expedite_flush(state)
      true -> state
    end
  end

  defp schedule_flush(%State{flush_token: nil} = state, delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:flush, token}, delay)
    %{state | flush_token: token, flush_timer: timer}
  end

  defp schedule_flush(%State{} = state, _delay), do: state

  defp expedite_flush(%State{flush_token: token, flush_timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer, async: true, info: false)
    send(self(), {:flush, token})
    %{state | flush_timer: nil}
  end

  defp schedule_remaining(%State{pending: []} = state), do: state

  defp schedule_remaining(%State{halted_reason: nil} = state), do: schedule_flush(state, 0)

  defp schedule_remaining(%State{} = state) do
    Enum.each(state.pending, fn request ->
      GenServer.reply(request.from, {:error, {:sequencer_halted, state.halted_reason}})
    end)

    %{state | pending: []}
  end

  defp schedule_reconciliation(%State{} = state) do
    state = cancel_reconciliation_timer(state)

    if state.halted_reason do
      state
    else
      case trusted_recorded_at(state.clock, state.projection) do
        {:ok, now} -> schedule_next_reconciliation(state, now)
        {:error, reason} -> halt(state, reason)
      end
    end
  end

  defp cancel_reconciliation_timer(%State{reconciliation_timer: nil} = state), do: state

  defp cancel_reconciliation_timer(%State{} = state) do
    Process.cancel_timer(state.reconciliation_timer, async: true, info: false)
    %{state | reconciliation_token: nil, reconciliation_timer: nil}
  end

  defp schedule_next_reconciliation(state, now) do
    deadline =
      case Reconciler.missing_openings(state.projection, state.constitution, now) do
        [] -> next_reconciliation_deadline(state.projection, now)
        [_cause | _rest] -> now
      end

    case deadline do
      nil ->
        state

      deadline ->
        delay = deadline |> Kernel.-(now) |> max(0) |> min(@maximum_reconciliation_delay_ms)
        token = make_ref()
        timer = Process.send_after(self(), {:reconcile, token}, delay)
        %{state | reconciliation_token: token, reconciliation_timer: timer}
    end
  end

  defp next_reconciliation_deadline(projection, now) do
    (dispatch_reconciliation_deadlines(projection, now) ++
       attempt_reconciliation_deadlines(projection, now) ++
       scope_reconciliation_deadlines(projection, now))
    |> Enum.min(fn -> nil end)
  end

  defp dispatch_reconciliation_deadlines(projection, now) do
    projection.dispatch_ready
    |> Enum.flat_map(fn act_ref ->
      with {:ok, act} <- Map.fetch(projection.acts, act_ref),
           {:ok, mandate} <- Map.fetch(projection.mandates, act.mandate_ref),
           true <- act.mandate_revision == mandate.revision,
           false <- Map.has_key?(projection.attempts_by_act, act.ref) do
        [max(mandate.expires_at, now)]
      else
        _invalid -> [now]
      end
    end)
  end

  defp attempt_reconciliation_deadlines(projection, now) do
    outcomes_by_attempt =
      MapSet.new(projection.outcomes, fn {_ref, outcome} -> outcome.attempt_ref end)

    projection.attempts
    |> Map.values()
    |> Enum.reject(&MapSet.member?(outcomes_by_attempt, &1.ref))
    |> Enum.flat_map(fn attempt ->
      case Map.fetch(projection.acts, attempt.act_ref) do
        {:ok, act} ->
          deadline = attempt.started_at + act.observation_window_ms
          if deadline > now, do: [deadline], else: []

        :error ->
          []
      end
    end)
  end

  defp scope_reconciliation_deadlines(projection, now) do
    projection.scopes
    |> Map.values()
    |> Enum.flat_map(fn
      %Opening{kind: kind, due_at: due_at} when kind in [:work, :vigil] and due_at > now ->
        [due_at]

      _other ->
        []
    end)
  end

  defp process_submission_groups(%State{} = state, requests) do
    requests
    |> Enum.chunk_by(& &1.ledger_opts)
    |> process_submission_group_list(state)
  end

  defp process_submission_group_list([], state), do: state

  defp process_submission_group_list([group | remaining], state) do
    {next_state, replies} = process_admission_group(state, group)
    Enum.each(replies, fn {from, reply} -> GenServer.reply(from, reply) end)

    if next_state.halted_reason do
      remaining
      |> List.flatten()
      |> Enum.each(fn request ->
        GenServer.reply(
          request.from,
          {:error, {:sequencer_halted, next_state.halted_reason}}
        )
      end)

      next_state
    else
      process_submission_group_list(remaining, next_state)
    end
  end

  defp process_admission_group(%State{} = state, requests) do
    ledger_opts = hd(requests).ledger_opts

    case preflight_duty_repair(state, ledger_opts) do
      {:ok, current} ->
        case admit(current, requests, ledger_opts, current.conflict_retries) do
          {:ok, next_state, plans} ->
            {next_state, finalize_admission(next_state, plans)}

          {:error, next_state, plans, reason} ->
            replies =
              Enum.map(plans, fn plan ->
                admission_error_reply(plan, reason)
              end)

            {next_state, replies}
        end

      {:error, halted, reason} ->
        replies = Enum.map(requests, &{&1.from, {:error, reason}})
        {halted, replies}
    end
  end

  defp admission_error_reply(plan, batch_reason) do
    reason = plan.error || batch_reason
    {plan.request.from, {:error, reason}}
  end

  defp admit(state, requests, ledger_opts, conflicts_left) do
    with {:ok, admitted_at} <- trusted_recorded_at(state.clock, state.projection) do
      {plans, _provisional, payloads} = plan_admission(state, requests, admitted_at)

      if payloads == [] do
        {:ok, state, plans}
      else
        case operational_id(state, "admission") do
          {:ok, batch_id} ->
            commit_planned_admission(
              state,
              requests,
              plans,
              payloads,
              batch_id,
              ledger_opts,
              conflicts_left,
              admitted_at
            )

          {:error, reason} ->
            {:error, state, plans, reason}
        end
      end
    else
      {:error, reason} -> {:error, state, error_plans(requests), reason}
    end
  end

  defp commit_planned_admission(
         state,
         requests,
         plans,
         payloads,
         batch_id,
         ledger_opts,
         conflicts_left,
         admitted_at
       ) do
    case append_exact(
           state,
           batch_id,
           payloads,
           state.projection.revision,
           ledger_opts,
           state.ambiguous_retries,
           admitted_at
         ) do
      {:ok, recovered} ->
        {:ok, %{state | projection: recovered}, plans}

      :conflict when conflicts_left > 0 ->
        retry_admission_after_conflict(state, requests, ledger_opts, conflicts_left - 1)

      :conflict ->
        halted = halt(state, :conflict_retries_exhausted)
        {:error, halted, plans, :conflict_retries_exhausted}

      {:error, {:durable_recovery_failed, reason}} ->
        halted = halt(state, reason)
        {:error, halted, plans, {:durable_recovery_failed, reason}}

      {:error, :ambiguous_commit_unresolved} ->
        halted = halt(state, :ambiguous_commit_unresolved)
        {:error, halted, plans, :ambiguous_commit_unresolved}

      {:error, reason} ->
        {:error, state, plans, reason}
    end
  end

  defp retry_admission_after_conflict(state, requests, ledger_opts, conflicts_left) do
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        admit(%{state | projection: projection}, requests, ledger_opts, conflicts_left)

      {:error, reason} ->
        plans = error_plans(requests)
        halted = halt(state, reason)
        {:error, halted, plans, {:durable_recovery_failed, reason}}
    end
  end

  defp plan_admission(state, requests, admitted_at) do
    Enum.reduce(requests, {[], state.projection, []}, fn request,
                                                         {plans, provisional, payloads} ->
      case plan_submission(state, request, provisional, admitted_at) do
        {:ok, plan, next_projection, new_payloads} ->
          {[plan | plans], next_projection, payloads ++ new_payloads}

        {:error, reason} ->
          plan = %{request: request, candidate: nil, error: reason}
          {[plan | plans], provisional, payloads}
      end
    end)
    |> then(fn {plans, projection, payloads} ->
      {Enum.reverse(plans), projection, payloads}
    end)
  end

  defp plan_submission(state, request, projection, admitted_at) do
    with {:ok, candidate} <- Candidate.new(request.candidate),
         {:ok, context} <- SubmissionContext.new(request.context),
         :ok <- validate_submission_boundary(state, projection, candidate, context),
         :ok <- validate_submission_kind(state, request, candidate, context) do
      case Map.fetch(projection.candidate_identities, candidate.identity_key) do
        {:ok, %{digest: digest}} when digest == candidate.material_digest ->
          {:ok, success_plan(request, candidate), projection, []}

        {:ok, _different} ->
          {:error, {:candidate_identity_conflict, candidate.identity_key}}

        :error ->
          evaluate_submission(state, request, candidate, context, projection, admitted_at)
      end
    end
  end

  defp validate_admitted_execution_route(_state, nil), do: :ok

  defp validate_admitted_execution_route(_state, %Act{row: %{attempt: false}}), do: :ok

  defp validate_admitted_execution_route(state, %Act{} = act) do
    case configured_execution_route(
           state,
           act.executor_ref,
           act.executor_contract_ref
         ) do
      {:ok, _route} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_submission_kind(
         state,
         %{kind: :governed_scope_opening, child_context: child_context},
         candidate,
         parent_context
       ) do
    with {:ok, child_context} <- SubmissionContext.new(child_context),
         :ok <- SubmissionContext.verify_seal(child_context, state.grant_secret),
         :ok <- validate_child_context_boundary(state, parent_context, child_context),
         {:ok, draft} <- candidate_scope_opening_draft(candidate),
         :ok <- validate_scope_opening_candidate(candidate, draft, parent_context, child_context) do
      :ok
    end
  end

  defp validate_submission_kind(_state, %{kind: :candidate}, candidate, _context) do
    if candidate.class == Governance.scope_open_class(),
      do: {:error, :governed_scope_context_required},
      else: :ok
  end

  defp validate_submission_kind(_state, _request, _candidate, _context),
    do: {:error, :invalid_submission_kind}

  defp validate_child_context_boundary(state, parent_context, child_context) do
    cond do
      child_context.domain_ref != state.domain_ref or
          child_context.domain_ref != parent_context.domain_ref ->
        {:error, :child_scope_domain_mismatch}

      child_context.ingress_ref != state.ingress_ref or
          child_context.ingress_ref != parent_context.ingress_ref ->
        {:error, :child_scope_ingress_mismatch}

      child_context.host_generation != state.generation or
          child_context.host_generation != parent_context.host_generation ->
        {:error, :child_scope_generation_mismatch}

      child_context.scope_ref == parent_context.scope_ref ->
        {:error, :child_scope_ref_must_differ_from_parent}

      true ->
        :ok
    end
  end

  defp candidate_scope_opening_draft(%Candidate{
         class: class,
         consequence: %{"scope_open" => draft} = consequence
       })
       when class == "scope.open" and map_size(consequence) == 1 do
    with {:ok, canonical} <- Opening.governed_draft(draft),
         true <- canonical == draft do
      {:ok, canonical}
    else
      false -> {:error, :noncanonical_governed_scope_draft}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_scope_opening_draft(_candidate),
    do: {:error, :invalid_governed_scope_opening_consequence}

  defp validate_scope_opening_candidate(candidate, draft, parent_context, child_context) do
    context_fields = [
      {"ref", child_context.scope_ref},
      {"domain_ref", child_context.domain_ref},
      {"parent_ref", parent_context.scope_ref},
      {"opened_by_ref", child_context.authenticated_principal_ref},
      {"submission_context_ref", child_context.ref},
      {"authentication_ref", child_context.authentication_ref},
      {"ingress_ref", child_context.ingress_ref},
      {"channel_ref", child_context.channel_ref},
      {"session_ref", child_context.session_ref},
      {"host_generation", child_context.host_generation}
    ]

    mismatch =
      Enum.find(context_fields, fn {field, expected} -> Map.get(draft, field) != expected end)

    cond do
      mismatch ->
        {field, _expected} = mismatch
        {:error, {:governed_scope_context_mismatch, field}}

      Row.dimensions(candidate.row) != Governance.scope_open_dimensions() ->
        {:error, :invalid_governed_scope_opening_row}

      candidate.executor_ref != Governance.kernel_executor_ref() or
          candidate.executor_contract_ref != Governance.kernel_contract_ref() ->
        {:error, :governed_scope_opening_not_ledger_internal}

      candidate.meter_requests != %{} or candidate.observation_window_ms != 0 ->
        {:error, :invalid_governed_scope_opening_execution}

      child_context.scope_ref not in candidate.target_refs ->
        {:error, :governed_scope_opening_target_missing}

      true ->
        :ok
    end
  end

  defp validate_submission_boundary(state, projection, candidate, context) do
    with :ok <- SubmissionContext.verify_seal(context, state.grant_secret) do
      cond do
        context.domain_ref != state.domain_ref ->
          {:error, {:submission_domain_mismatch, context.domain_ref, state.domain_ref}}

        context.ingress_ref != state.ingress_ref ->
          {:error, :submission_context_ingress_mismatch}

        context.host_generation != state.generation ->
          {:error, :submission_generation_mismatch}

        candidate.proposer_ref != context.authenticated_principal_ref ->
          {:error, :proposer_context_mismatch}

        candidate.scope_ref != context.scope_ref ->
          {:error, :scope_context_mismatch}

        true ->
          with {:ok, _opening} <- Projection.scope_context(projection, context), do: :ok
      end
    end
  end

  defp evaluate_submission(state, request, candidate, context, projection, admitted_at) do
    with {:ok, decision, act} <-
           GovernedKernel.evaluate(candidate, context, projection, admitted_at),
         :ok <- validate_admitted_execution_route(state, act),
         {:ok, payloads} <- Commit.payloads(projection, decision, act),
         {:ok, next_projection} <- apply_payloads(projection, payloads) do
      {:ok, success_plan(request, candidate), next_projection, payloads}
    end
  end

  defp success_plan(request, candidate),
    do: %{request: request, candidate: candidate, error: nil}

  defp error_plans(requests) do
    Enum.map(requests, fn request -> %{request: request, candidate: nil, error: nil} end)
  end

  defp apply_payloads(projection, payloads) do
    Enum.reduce_while(payloads, {:ok, projection}, fn payload, {:ok, current} ->
      provisional_revision = current.revision + 1

      case Projection.apply_payload(current, payload, provisional_revision) do
        {:ok, next} -> {:cont, {:ok, %{next | revision: provisional_revision}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp finalize_admission(state, plans) do
    Enum.map(plans, fn plan ->
      reply =
        if plan.error do
          {:error, plan.error}
        else
          admission_reply(state, plan)
        end

      {plan.request.from, reply}
    end)
  end

  defp admission_reply(state, %{request: %{kind: :governed_scope_opening}} = plan) do
    with {:ok, admission} <- admission_from_projection(state, plan.candidate),
         {:ok, opening} <- admitted_scope_opening(state.projection, admission, plan.candidate) do
      {:ok, Map.put(admission, :opening, opening)}
    end
  end

  defp admission_reply(state, plan),
    do: admission_from_projection(state, plan.candidate)

  defp admitted_scope_opening(_projection, %{decision: %{outcome: outcome}, act: nil}, _candidate)
       when outcome != :admitted,
       do: {:ok, nil}

  defp admitted_scope_opening(
         projection,
         %{decision: %{outcome: :admitted}, act: %Act{ref: act_ref}},
         %Candidate{consequence: %{"scope_open" => %{"ref" => scope_ref}}}
       ) do
    case Map.fetch(projection.scopes, scope_ref) do
      {:ok, %Opening{source_act_ref: ^act_ref} = opening} -> {:ok, opening}
      {:ok, %Opening{}} -> {:error, {:scope_opening_source_mismatch, scope_ref, act_ref}}
      :error -> {:error, {:governed_scope_opening_not_recovered, scope_ref}}
    end
  end

  defp admitted_scope_opening(_projection, _admission, _candidate),
    do: {:error, :invalid_governed_scope_admission}

  defp admission_from_projection(state, candidate) do
    with {:ok, identity} <-
           Map.fetch(state.projection.candidate_identities, candidate.identity_key),
         true <- identity.digest == candidate.material_digest,
         {:ok, decision} <- Map.fetch(state.projection.decisions, identity.decision_ref),
         {:ok, act} <- act_for_decision(state.projection, decision),
         {:ok, grant} <- maybe_mint_grant(state, act) do
      {:ok, %{decision: decision, act: act, grant: grant}}
    else
      :error -> {:error, :admission_not_recovered}
      false -> {:error, {:candidate_identity_conflict, candidate.identity_key}}
      {:error, _reason} = error -> error
    end
  end

  defp act_for_decision(_projection, %Decision{outcome: outcome}) when outcome != :admitted,
    do: {:ok, nil}

  defp act_for_decision(projection, %Decision{outcome: :admitted, ref: decision_ref}) do
    case Enum.find(projection.acts, fn {_ref, act} -> act.decision_ref == decision_ref end) do
      {_ref, act} -> {:ok, act}
      nil -> {:error, {:admitted_decision_missing_act, decision_ref}}
    end
  end

  defp maybe_mint_grant(_state, nil), do: {:ok, nil}
  defp maybe_mint_grant(_state, %Act{row: %{attempt: false}}), do: {:ok, nil}

  defp maybe_mint_grant(state, %Act{} = act) do
    cond do
      Map.has_key?(state.projection.attempts_by_act, act.ref) ->
        {:ok, nil}

      not MapSet.member?(state.projection.dispatch_ready, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      true ->
        with {:ok, now} <- trusted_recorded_at(state.clock, state.projection),
             :ok <- duties_materialized(state.projection, state.constitution, now),
             :ok <- mandate_still_active(state.projection, act, now),
             :ok <- verify_act_payloads(state, act),
             {:ok, nonce} <- operational_id(state, "grant") do
          Grant.mint(
            %{
              act_ref: act.ref,
              domain_ref: state.domain_ref,
              executor_ref: act.executor_ref,
              issued_at: now,
              expires_at: now + state.grant_ttl_ms,
              generation: state.generation,
              material_digest: act.material_digest,
              nonce: nonce
            },
            state.grant_secret
          )
        end
    end
  end

  defp consume_attempt(state, grant, ledger_opts, conflicts_left) do
    with {:ok, now} <- trusted_recorded_at(state.clock, state.projection),
         :ok <- duties_materialized(state.projection, state.constitution, now),
         {:ok, act} <- fetch_granted_act(state, grant, now),
         {:ok, broker} <- configured_broker(state),
         :ok <- broker_supports_act(state.projection, act, broker),
         :ok <- verify_act_payloads(state, act),
         :ok <- attempt_available(state.projection, act, grant),
         {:ok, attempt_ref} <- operational_id(state, "attempt"),
         {:ok, attempt} <- build_attempt(state, act, grant, attempt_ref, now),
         {:ok, payload} <- Event.record(:attempt, attempt),
         {:ok, _provisional} <- apply_payloads(state.projection, [payload]),
         {:ok, batch_id} <- operational_id(state, "attempt-batch") do
      expected_revision = state.projection.revision

      case append_exact(
             state,
             batch_id,
             [payload],
             expected_revision,
             ledger_opts,
             state.ambiguous_retries,
             now
           ) do
        {:ok, recovered} ->
          recovered_attempt(state, recovered, act.ref, attempt.ref)

        :conflict when conflicts_left > 0 ->
          retry_consumption_after_conflict(
            state,
            grant,
            ledger_opts,
            conflicts_left - 1
          )

        :conflict ->
          halted = halt(state, :conflict_retries_exhausted)
          {:error, halted, :conflict_retries_exhausted}

        {:error, {:durable_recovery_failed, reason}} ->
          halted = halt(state, reason)
          {:error, halted, {:durable_recovery_failed, reason}}

        {:error, :ambiguous_commit_unresolved} ->
          halted = halt(state, :ambiguous_commit_unresolved)
          {:error, halted, :ambiguous_commit_unresolved}

        {:error, reason} ->
          {:error, state, reason}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp verify_act_payloads(state, act) do
    refs = PayloadStore.act_payload_refs(state.projection, act)
    PayloadStore.verify_usable(state.payload_store, state.projection, refs)
  end

  defp fetch_granted_act(state, grant, now) do
    with {:ok, %Act{} = act} <- Map.fetch(state.projection.acts, grant.act_ref),
         :ok <-
           Grant.verify(grant, state.grant_secret, %{
             now: now,
             generation: state.generation,
             executor_ref: act.executor_ref,
             material_digest: act.material_digest,
             act_ref: act.ref,
             domain_ref: state.domain_ref
           }),
         :ok <- mandate_still_active(state.projection, act, now) do
      {:ok, act}
    else
      :error -> {:error, {:act_not_found, grant.act_ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_granted_act}
    end
  end

  defp attempt_available(projection, act, grant) do
    nonce_digest = nonce_digest(grant.nonce)

    cond do
      not act.row.attempt ->
        {:error, {:act_not_externally_attemptable, act.ref}}

      not MapSet.member?(projection.dispatch_ready, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      Map.has_key?(projection.attempts_by_act, act.ref) ->
        {:error, {:act_already_attempted, act.ref}}

      MapSet.member?(projection.consumed_nonces, nonce_digest) ->
        {:error, {:grant_nonce_already_consumed, nonce_digest}}

      true ->
        :ok
    end
  end

  defp build_attempt(state, act, grant, attempt_ref, now) do
    Attempt.new(%{
      ref: attempt_ref,
      act_ref: act.ref,
      executor_ref: act.executor_ref,
      material_digest: act.material_digest,
      generation: state.generation,
      grant_nonce_digest: nonce_digest(grant.nonce),
      started_at: now
    })
  end

  defp recovered_attempt(state, projection, act_ref, attempt_ref) do
    recovered_state = %{state | projection: projection}

    with {:ok, %Act{} = act} <- Map.fetch(projection.acts, act_ref),
         {:ok, %Attempt{} = attempt} <- Map.fetch(projection.attempts, attempt_ref),
         true <- Map.get(projection.attempts_by_act, act_ref) == attempt_ref,
         {:ok, now} <- trusted_recorded_at(state.clock, projection),
         {:ok, broker} <- configured_broker(recovered_state),
         :ok <- mandate_still_active(projection, act, now),
         :ok <- broker_supports_act(projection, act, broker),
         :ok <- verify_act_payloads(recovered_state, act),
         {:ok, receipt} <- mint_checkout_receipt(recovered_state, act, attempt, broker, now) do
      {:ok, recovered_state, act, attempt, receipt}
    else
      :error ->
        halted = halt(state, :attempt_not_recovered)
        {:error, halted, :attempt_not_recovered}

      false ->
        halted = halt(state, :attempt_projection_mismatch)
        {:error, halted, :attempt_projection_mismatch}

      _invalid ->
        halted = halt(state, :invalid_recovered_attempt)
        {:error, halted, :invalid_recovered_attempt}
    end
  end

  defp retry_consumption_after_conflict(state, grant, ledger_opts, conflicts_left) do
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        consume_attempt(
          %{state | projection: projection},
          grant,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp mint_checkout_receipt(state, act, attempt, broker, now) do
    CheckoutReceipt.mint(
      %{
        domain_ref: state.domain_ref,
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        executor_ref: act.executor_ref,
        material_digest: act.material_digest,
        generation: attempt.generation,
        grant_nonce_digest: attempt.grant_nonce_digest,
        broker_ref: broker.descriptor.ref,
        ledger_revision: state.projection.revision,
        issued_at: now,
        expires_at: now + state.grant_ttl_ms
      },
      state.checkout_receipt_secret
    )
  end

  defp broker_supports_act(projection, act, broker) do
    broker_profile = broker.descriptor.profile

    with {:ok, host_profile} <- Map.fetch(projection.host_profiles, act.host_profile_ref),
         true <- Boundary.profile_covers?(broker_profile, host_profile.mode) do
      :ok
    else
      :error -> {:error, {:act_host_profile_not_found, act.host_profile_ref}}
      false -> {:error, {:broker_profile_too_weak, broker_profile, act.host_profile_ref}}
    end
  end

  defp configured_execution_route(state, executor_ref, contract_ref) do
    with :ok <- Portable.validate_ref(executor_ref, :executor_ref),
         :ok <- Portable.validate_ref(contract_ref, :executor_contract_ref),
         {:ok, route} <- Map.fetch(state.execution_routes, {executor_ref, contract_ref}),
         {:ok, broker} <- configured_broker(state) do
      {:ok,
       %{
         executor: route.executor,
         executor_opts: route.executor_opts,
         broker: broker.broker,
         broker_opts: broker.broker_opts,
         broker_descriptor: broker.descriptor
       }}
    else
      :error -> {:error, {:executor_route_not_configured, executor_ref, contract_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_pending_execution_routes(projection, config) do
    Enum.reduce_while(projection.dispatch_ready, :ok, fn act_ref, :ok ->
      with {:ok, act} <- Map.fetch(projection.acts, act_ref),
           {:ok, _route} <-
             configured_execution_route(
               config,
               act.executor_ref,
               act.executor_contract_ref
             ) do
        {:cont, :ok}
      else
        :error -> {:halt, {:error, {:dispatch_act_not_found, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp configured_broker(%{broker: nil}), do: {:error, :broker_not_configured}
  defp configured_broker(%{broker: broker}), do: {:ok, broker}

  defp record_observation(state, input, ledger_opts, conflicts_left) do
    case Outcome.new(input) do
      {:ok, outcome} ->
        record_normalized_observation(state, outcome, ledger_opts, conflicts_left)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp record_normalized_observation(state, outcome, ledger_opts, conflicts_left) do
    case existing_outcome(state.projection, outcome) do
      {:ok, durable} ->
        {:ok, state, durable}

      :not_found ->
        append_observation(state, outcome, ledger_opts, conflicts_left)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp append_observation(state, outcome, ledger_opts, conflicts_left) do
    with {:ok, now} <- trusted_recorded_at(state.clock, state.projection),
         {:ok, payloads} <-
           Observation.payloads(state.projection, outcome, now, state.constitution),
         {:ok, _provisional} <- apply_payloads(state.projection, payloads),
         {:ok, batch_id} <- operational_id(state, "outcome") do
      expected_revision = state.projection.revision

      case append_exact(
             state,
             batch_id,
             payloads,
             expected_revision,
             ledger_opts,
             state.ambiguous_retries,
             now
           ) do
        {:ok, recovered} ->
          recovered_outcome(state, recovered, outcome)

        :conflict when conflicts_left > 0 ->
          retry_observation_after_conflict(
            state,
            outcome,
            ledger_opts,
            conflicts_left - 1
          )

        :conflict ->
          halted = halt(state, :conflict_retries_exhausted)
          {:error, halted, :conflict_retries_exhausted}

        {:error, {:durable_recovery_failed, reason}} ->
          halted = halt(state, reason)
          {:error, halted, {:durable_recovery_failed, reason}}

        {:error, :ambiguous_commit_unresolved} ->
          halted = halt(state, :ambiguous_commit_unresolved)
          {:error, halted, :ambiguous_commit_unresolved}

        {:error, reason} ->
          {:error, state, reason}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp retry_observation_after_conflict(state, outcome, ledger_opts, conflicts_left) do
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        record_observation(
          %{state | projection: projection},
          outcome,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp existing_outcome(projection, outcome) do
    case Map.fetch(projection.outcomes, outcome.ref) do
      {:ok, existing} ->
        if Outcome.canonical(existing) == Outcome.canonical(outcome),
          do: {:ok, existing},
          else: {:error, {:outcome_identity_conflict, outcome.ref}}

      :error ->
        :not_found
    end
  end

  defp recovered_outcome(state, projection, outcome) do
    case existing_outcome(projection, outcome) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        halted = halt(state, :outcome_not_recovered)
        {:error, halted, :outcome_not_recovered}

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, reason}
    end
  end

  defp record_evidence_batch(
         state,
         input,
         ledger_opts,
         conflicts_left,
         minimum_recorded_at \\ 0
       ) do
    with {:ok, evidence, shape} <- normalize_evidence_input(input),
         {:ok, current_time} <- trusted_recorded_at(state.clock, state.projection),
         now = max(current_time, minimum_recorded_at),
         :ok <- evidence_not_future(evidence, now),
         {:ok, payloads} <- evidence_payloads(state.projection, evidence),
         {:ok, _provisional} <- apply_payloads(state.projection, payloads) do
      if payloads == [] do
        recovered_evidence(state, state.projection, evidence, shape)
      else
        append_evidence(
          state,
          evidence,
          shape,
          payloads,
          ledger_opts,
          conflicts_left,
          now
        )
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp normalize_evidence_input(%Evidence{} = evidence) do
    with {:ok, evidence} <- Evidence.new(evidence), do: {:ok, [evidence], :one}
  end

  defp normalize_evidence_input(evidence) when is_list(evidence) and evidence != [] do
    evidence
    |> Enum.reduce_while({:ok, [], %{}}, fn input, {:ok, records, seen} ->
      with {:ok, record} <- Evidence.new(input),
           :ok <- evidence_ref_available(seen, record) do
        {:cont, {:ok, [record | records], Map.put(seen, record.ref, record)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records, _seen} -> {:ok, Enum.reverse(records), :many}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_evidence_input(_input), do: {:error, :invalid_evidence_input}

  defp evidence_ref_available(seen, record) do
    case Map.fetch(seen, record.ref) do
      :error ->
        :ok

      {:ok, existing} ->
        if Evidence.canonical(existing) == Evidence.canonical(record),
          do: :ok,
          else: {:error, {:evidence_identity_conflict, record.ref}}
    end
  end

  defp evidence_not_future(evidence, now) do
    case Enum.find(evidence, &(&1.observed_at > now)) do
      nil -> :ok
      record -> {:error, {:evidence_from_future, record.ref, record.observed_at}}
    end
  end

  defp evidence_payloads(projection, evidence) do
    evidence
    |> Enum.uniq_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, payloads} ->
      case evidence_payload(projection, record) do
        {:ok, nil} -> {:cont, {:ok, payloads}}
        {:ok, payload} -> {:cont, {:ok, [payload | payloads]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      {:error, _reason} = error -> error
    end
  end

  defp evidence_payload(projection, record) do
    case Map.fetch(projection.evidence, record.ref) do
      :error ->
        Event.record(:evidence, record)

      {:ok, existing} ->
        if Evidence.canonical(existing) == Evidence.canonical(record),
          do: {:ok, nil},
          else: {:error, {:evidence_identity_conflict, record.ref}}
    end
  end

  defp append_evidence(
         state,
         evidence,
         shape,
         payloads,
         ledger_opts,
         conflicts_left,
         recorded_at
       ) do
    case operational_id(state, "evidence") do
      {:ok, batch_id} ->
        commit_evidence(
          state,
          evidence,
          shape,
          payloads,
          batch_id,
          ledger_opts,
          conflicts_left,
          recorded_at
        )

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp commit_evidence(
         state,
         evidence,
         shape,
         payloads,
         batch_id,
         ledger_opts,
         conflicts_left,
         recorded_at
       ) do
    case append_exact(
           state,
           batch_id,
           payloads,
           state.projection.revision,
           ledger_opts,
           state.ambiguous_retries,
           recorded_at
         ) do
      {:ok, recovered} ->
        recovered_evidence(state, recovered, evidence, shape)

      :conflict when conflicts_left > 0 ->
        retry_evidence_after_conflict(
          state,
          evidence,
          shape,
          ledger_opts,
          conflicts_left - 1,
          recorded_at
        )

      :conflict ->
        halted = halt(state, :conflict_retries_exhausted)
        {:error, halted, :conflict_retries_exhausted}

      {:error, {:durable_recovery_failed, reason}} ->
        halted = halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}

      {:error, :ambiguous_commit_unresolved} ->
        halted = halt(state, :ambiguous_commit_unresolved)
        {:error, halted, :ambiguous_commit_unresolved}

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp retry_evidence_after_conflict(
         state,
         evidence,
         shape,
         ledger_opts,
         conflicts_left,
         recorded_at
       ) do
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        input = if shape == :one, do: hd(evidence), else: evidence

        record_evidence_batch(
          %{state | projection: projection},
          input,
          ledger_opts,
          conflicts_left,
          recorded_at
        )

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp recovered_evidence(state, projection, evidence, shape) do
    case fetch_recovered_evidence(projection, evidence) do
      {:ok, records} ->
        result = if shape == :one, do: hd(records), else: records
        {:ok, %{state | projection: projection}, result}

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, reason}
    end
  end

  defp fetch_recovered_evidence(projection, evidence) do
    Enum.reduce_while(evidence, {:ok, []}, fn expected, {:ok, records} ->
      case recovered_evidence_record(projection, expected) do
        {:ok, durable} -> {:cont, {:ok, [durable | records]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp recovered_evidence_record(projection, expected) do
    case Map.fetch(projection.evidence, expected.ref) do
      {:ok, durable} ->
        if Evidence.canonical(durable) == Evidence.canonical(expected),
          do: {:ok, durable},
          else: {:error, {:evidence_identity_conflict, expected.ref}}

      :error ->
        {:error, {:evidence_not_recovered, expected.ref}}
    end
  end

  defp record_ingress_observation(state, context, input, ingress_opts) do
    with {:ok, context, _opening} <- live_scope_context(state, context),
         {:ok, observed_at} <- trusted_recorded_at(state.clock, state.projection),
         {:ok, evidence} <-
           Ingress.observe(state.ingress, context, input, observed_at, ingress_opts) do
      case record_evidence_batch(
             state,
             evidence,
             state.ledger_opts,
             state.conflict_retries,
             observed_at
           ) do
        {:ok, next_state, durable} when is_list(durable) ->
          {:ok, next_state, durable, observed_at}

        {:ok, next_state, _invalid} ->
          {:error, halt(next_state, :invalid_ingress_evidence_result),
           :invalid_ingress_evidence_result}

        {:error, next_state, reason} ->
          {:error, next_state, reason}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp live_scope_context(state, input) do
    with {:ok, context} <- SubmissionContext.new(input),
         :ok <- validate_context_ingress(state, context),
         :ok <- SubmissionContext.verify_seal(context, state.grant_secret),
         true <- context.domain_ref == state.domain_ref,
         true <- context.host_generation == state.generation,
         {:ok, opening} <- Projection.scope_context(state.projection, context) do
      {:ok, context, opening}
    else
      false -> {:error, :scope_context_not_current}
      {:error, _reason} = error -> error
    end
  end

  defp scoped_evidence(_projection, _scope_ref, []), do: {:ok, []}

  defp scoped_evidence(projection, scope_ref, refs) do
    with {:ok, %ScopeView{} = view} <- ScopeView.from_projection(projection, scope_ref) do
      available = Map.new(view.evidence, &{&1.ref, &1})

      Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, records} ->
        case Map.fetch(available, ref) do
          {:ok, evidence} -> {:cont, {:ok, [evidence | records]}}
          :error -> {:halt, {:error, {:evidence_outside_scope, ref}}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp merge_evidence(left, right) do
    (left ++ right)
    |> Map.new(&{&1.ref, &1})
    |> Map.values()
    |> Enum.sort_by(& &1.ref)
  end

  defp build_turn(state, context, turn_ref, evidence, opened_at) do
    domain = Domain.handle(self(), state.domain_ref)

    with {:ok, scope} <- Scope.new(domain, context.scope_ref, context),
         {:ok, turn} <- Turn.new(scope, turn_ref, state.mind_ref, evidence, opened_at),
         do: Turn.seal(turn, state.grant_secret)
  end

  defp validate_turn(state, context, opening, turn, now) do
    cond do
      turn.domain_ref != state.domain_ref ->
        {:error, :turn_domain_mismatch}

      turn.scope_ref != context.scope_ref ->
        {:error, :turn_scope_mismatch}

      turn.mind_ref != state.mind_ref ->
        {:error, :turn_mind_mismatch}

      turn.submission_context_ref != context.ref ->
        {:error, :turn_submission_context_mismatch}

      turn.authenticated_principal_ref != context.authenticated_principal_ref ->
        {:error, :turn_principal_mismatch}

      not is_integer(turn.opened_at) or turn.opened_at < opening.opened_at or
          turn.opened_at > now ->
        {:error, :turn_time_invalid}

      turn.evidence_refs != Enum.sort(Enum.uniq(turn.evidence_refs)) ->
        {:error, :noncanonical_turn_evidence_refs}

      true ->
        validate_turn_evidence(state.projection, turn)
    end
  end

  defp validate_turn_evidence(projection, turn) do
    with :ok <- ErasureAnalysis.validate_evidence_available(projection, turn.evidence_refs),
         {:ok, durable} <- Projection.evidence_set(projection, turn.evidence_refs),
         true <- evidence_identity(durable) == evidence_identity(turn.evidence),
         {:ok, labels} <- Derivation.inherited_labels(durable),
         true <- labels == turn.context_labels do
      {:ok, durable}
    else
      false -> {:error, :turn_evidence_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_derivation(evidence, context, turn, parents, now) do
    cond do
      evidence.provenance not in [:derived, :generated] ->
        {:error, {:invalid_derivation_provenance, evidence.provenance}}

      evidence.parent_refs != turn.evidence_refs ->
        {:error, {:evidence_turn_parent_mismatch, evidence.ref}}

      evidence.source_ref != turn.mind_ref ->
        {:error, {:derived_evidence_source_mismatch, evidence.ref}}

      evidence.issuer_ref != context.authenticated_principal_ref ->
        {:error, {:derived_evidence_issuer_mismatch, evidence.ref}}

      evidence.observed_at < turn.opened_at or evidence.observed_at > now ->
        {:error, {:derived_evidence_time_invalid, evidence.ref}}

      evidence_binding(evidence, :domain_ref) != context.domain_ref ->
        {:error, {:derived_evidence_binding_mismatch, evidence.ref, :domain_ref}}

      evidence_binding(evidence, :scope_ref) != context.scope_ref ->
        {:error, {:derived_evidence_binding_mismatch, evidence.ref, :scope_ref}}

      evidence_binding(evidence, :authentication_ref) != context.authentication_ref ->
        {:error, {:derived_evidence_binding_mismatch, evidence.ref, :authentication_ref}}

      evidence_binding(evidence, :authenticated_principal_ref) !=
          context.authenticated_principal_ref ->
        {:error, {:derived_evidence_binding_mismatch, evidence.ref, :authenticated_principal_ref}}

      true ->
        Derivation.validate(evidence, parents)
    end
  end

  defp validate_executor_evidence(projection, act_ref, attempt_ref, evidence) do
    with {:ok, %Act{} = act} <- fetch_projection_record(projection.acts, act_ref, :act),
         {:ok, %Attempt{} = attempt} <-
           fetch_projection_record(projection.attempts, attempt_ref, :attempt),
         true <- attempt.act_ref == act.ref,
         :ok <- validate_executor_evidence_records(projection, act, attempt, evidence) do
      :ok
    else
      false -> {:error, :executor_evidence_attempt_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_executor_evidence_records(projection, act, attempt, evidence) do
    Enum.reduce_while(evidence, :ok, fn record, :ok ->
      case validate_executor_evidence_record(projection, act, attempt, record) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_executor_evidence_record(projection, act, attempt, evidence) do
    expected_bindings = %{"act_ref" => act.ref, "attempt_ref" => attempt.ref}

    cond do
      evidence.bindings != expected_bindings ->
        {:error, {:executor_evidence_binding_mismatch, evidence.ref}}

      evidence.source_ref != act.executor_ref or evidence.issuer_ref != act.executor_ref ->
        {:error, {:executor_evidence_source_mismatch, evidence.ref}}

      evidence.observed_at < attempt.started_at ->
        {:error, {:executor_evidence_before_attempt, evidence.ref}}

      evidence.provenance == :observed and evidence.parent_refs != [] ->
        {:error, {:observed_executor_evidence_has_parents, evidence.ref}}

      evidence.provenance == :observed ->
        :ok

      evidence.provenance in [:derived, :generated] ->
        validate_executor_derivation(projection, act, evidence)

      true ->
        {:error, {:invalid_executor_evidence_provenance, evidence.ref}}
    end
  end

  defp validate_executor_derivation(projection, act, evidence) do
    allowed = MapSet.new(act.evidence_refs)
    parents = MapSet.new(evidence.parent_refs)

    with true <- evidence.parent_refs != [],
         true <- MapSet.subset?(parents, allowed),
         {:ok, durable_parents} <- Projection.evidence_set(projection, evidence.parent_refs) do
      Derivation.validate(evidence, durable_parents)
    else
      false -> {:error, {:executor_evidence_parent_outside_act_inputs, evidence.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_projection_record(index, ref, kind) do
    case Map.fetch(index, ref) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, {kind, :not_found, ref}}
    end
  end

  defp evidence_identity(evidence) do
    Map.new(evidence, &{&1.ref, Evidence.digest(&1)})
  end

  defp evidence_binding(evidence, key) do
    Map.get(evidence.bindings, key, Map.get(evidence.bindings, Atom.to_string(key)))
  end

  defp record_presentation_record(state, context, input, ledger_opts, conflicts_left) do
    with {:ok, context} <- SubmissionContext.new(context),
         :ok <- validate_context_ingress(state, context),
         :ok <- SubmissionContext.verify_seal(context, state.grant_secret),
         true <- context.domain_ref == state.domain_ref,
         true <- context.host_generation == state.generation,
         {:ok, opening} <- Projection.scope_context(state.projection, context),
         {:ok, presentation} <- Presentation.new(input),
         {:ok, now} <- trusted_recorded_at(state.clock, state.projection),
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
            ) ++ optional_payload_ref(presentation.rendered_payload_ref)

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
         {:ok, _provisional} <- apply_payloads(state.projection, [payload]),
         {:ok, batch_id} <- operational_id(state, "presentation") do
      case append_exact(
             state,
             batch_id,
             [payload],
             state.projection.revision,
             ledger_opts,
             state.ambiguous_retries,
             recorded_at
           ) do
        {:ok, recovered} ->
          recovered_presentation(state, recovered, presentation)

        :conflict when conflicts_left > 0 ->
          retry_presentation_after_conflict(
            state,
            context,
            presentation,
            ledger_opts,
            conflicts_left - 1
          )

        :conflict ->
          halted = halt(state, :conflict_retries_exhausted)
          {:error, halted, :conflict_retries_exhausted}

        {:error, {:durable_recovery_failed, reason}} ->
          halted = halt(state, reason)
          {:error, halted, {:durable_recovery_failed, reason}}

        {:error, :ambiguous_commit_unresolved} ->
          halted = halt(state, :ambiguous_commit_unresolved)
          {:error, halted, :ambiguous_commit_unresolved}

        {:error, reason} ->
          {:error, state, reason}
      end
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
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        record_presentation_record(
          %{state | projection: projection},
          context,
          presentation,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp recovered_presentation(state, projection, presentation) do
    case existing_presentation(projection, presentation) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        halted = halt(state, :presentation_not_recovered)
        {:error, halted, :presentation_not_recovered}

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, reason}
    end
  end

  defp open_scope_record(state, context, input, ledger_opts, conflicts_left) do
    with {:ok, context} <- SubmissionContext.new(context),
         :ok <- SubmissionContext.verify_seal(context, state.grant_secret),
         {:ok, opening} <- Opening.new(input),
         :ok <- validate_direct_scope_opening(opening),
         {:ok, now} <- trusted_recorded_at(state.clock, state.projection),
         :ok <- validate_scope_opening_boundary(state, context, opening, now) do
      case existing_scope(state.projection, opening) do
        {:ok, durable} ->
          {:ok, state, durable}

        :not_found ->
          append_scope_opening(
            state,
            context,
            opening,
            ledger_opts,
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

  defp validate_direct_scope_opening(%Opening{kind: kind, source_act_ref: nil})
       when kind in [:session, :child],
       do: :ok

  defp validate_direct_scope_opening(%Opening{kind: kind}) when kind in [:work, :vigil],
    do: {:error, {:governed_scope_opening_required, kind}}

  defp validate_direct_scope_opening(%Opening{}),
    do: {:error, :invalid_direct_scope_opening}

  defp validate_scope_opening_boundary(state, context, opening, now) do
    cond do
      context.domain_ref != state.domain_ref or opening.domain_ref != state.domain_ref ->
        {:error, :scope_opening_domain_mismatch}

      context.ingress_ref != state.ingress_ref or opening.ingress_ref != state.ingress_ref ->
        {:error, :scope_opening_ingress_mismatch}

      context.scope_ref != opening.ref ->
        {:error, :scope_opening_context_scope_mismatch}

      context.authenticated_principal_ref != opening.opened_by_ref ->
        {:error, :scope_opening_principal_mismatch}

      context.ref != opening.submission_context_ref ->
        {:error, :scope_opening_context_ref_mismatch}

      context.authentication_ref != opening.authentication_ref or
        context.ingress_ref != opening.ingress_ref or
        context.channel_ref != opening.channel_ref or
          context.session_ref != opening.session_ref ->
        {:error, :scope_opening_context_binding_mismatch}

      context.host_generation != state.generation or
          opening.host_generation != state.generation ->
        {:error, :scope_opening_generation_mismatch}

      opening.opened_at > now ->
        {:error, {:scope_opening_from_future, opening.ref}}

      true ->
        :ok
    end
  end

  defp validate_context_ingress(state, context) do
    if context.ingress_ref == state.ingress_ref,
      do: :ok,
      else: {:error, :submission_context_ingress_mismatch}
  end

  defp existing_scope(projection, opening) do
    case Map.fetch(projection.scopes, opening.ref) do
      {:ok, existing} ->
        if Opening.canonical(existing) == Opening.canonical(opening),
          do: {:ok, existing},
          else: {:error, {:scope_identity_conflict, opening.ref}}

      :error ->
        :not_found
    end
  end

  defp append_scope_opening(
         state,
         context,
         opening,
         ledger_opts,
         conflicts_left,
         recorded_at
       ) do
    with {:ok, payload} <- Event.scope_opened(opening),
         {:ok, _provisional} <- apply_payloads(state.projection, [payload]),
         {:ok, batch_id} <- operational_id(state, "scope") do
      case append_exact(
             state,
             batch_id,
             [payload],
             state.projection.revision,
             ledger_opts,
             state.ambiguous_retries,
             recorded_at
           ) do
        {:ok, recovered} ->
          recovered_scope(state, recovered, opening)

        :conflict when conflicts_left > 0 ->
          retry_scope_after_conflict(
            state,
            context,
            opening,
            ledger_opts,
            conflicts_left - 1
          )

        :conflict ->
          halted = halt(state, :conflict_retries_exhausted)
          {:error, halted, :conflict_retries_exhausted}

        {:error, {:durable_recovery_failed, reason}} ->
          halted = halt(state, reason)
          {:error, halted, {:durable_recovery_failed, reason}}

        {:error, :ambiguous_commit_unresolved} ->
          halted = halt(state, :ambiguous_commit_unresolved)
          {:error, halted, :ambiguous_commit_unresolved}

        {:error, reason} ->
          {:error, state, reason}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp retry_scope_after_conflict(state, context, opening, ledger_opts, conflicts_left) do
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        open_scope_record(
          %{state | projection: projection},
          context,
          opening,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp recovered_scope(state, projection, opening) do
    case existing_scope(projection, opening) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        halted = halt(state, :scope_opening_not_recovered)
        {:error, halted, :scope_opening_not_recovered}

      {:error, reason} ->
        halted = halt(state, reason)
        {:error, halted, reason}
    end
  end

  defp append_exact(
         state,
         batch_id,
         payloads,
         expected_revision,
         ledger_opts,
         retries_left,
         recorded_at
       )
       when is_integer(recorded_at) and recorded_at >= 0 do
    latest_recorded_at = latest_recorded_at(state.projection)

    if recorded_at >= latest_recorded_at do
      append_exact_at(
        state,
        batch_id,
        payloads,
        expected_revision,
        ledger_opts,
        recorded_at,
        retries_left
      )
    else
      {:error, {:ledger_time_regression, recorded_at, latest_recorded_at}}
    end
  end

  defp append_exact(
         _state,
         _batch_id,
         _payloads,
         _expected_revision,
         _ledger_opts,
         _retries_left,
         recorded_at
       ),
       do: {:error, {:invalid_recorded_at, recorded_at}}

  defp append_exact_at(
         state,
         batch_id,
         payloads,
         expected_revision,
         ledger_opts,
         recorded_at,
         retries_left
       ) do
    with :ok <-
           verify_new_payload_references(state.payload_store, state.projection, payloads) do
      Writer.append(
        state.store,
        state.domain_ref,
        batch_id,
        payloads,
        expected_revision,
        Keyword.put(ledger_opts, :recorded_at, recorded_at)
      )
    end
    |> case do
      {:ok, _revision} ->
        recover_after_append(state, ledger_opts)

      {:error, :conflict} ->
        :conflict

      {:error, :ambiguous} ->
        classify_append_ambiguity(
          state,
          batch_id,
          payloads,
          expected_revision,
          ledger_opts,
          recorded_at,
          retries_left
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp classify_append_ambiguity(
         state,
         batch_id,
         payloads,
         expected_revision,
         ledger_opts,
         recorded_at,
         retries_left
       ) do
    case Recovery.classify_ambiguous(
           state.store,
           state.domain_ref,
           batch_id,
           payloads,
           expected_revision,
           ledger_opts
         ) do
      {:ok, {:committed, _info}} ->
        recover_after_append(state, ledger_opts)

      {:ok, :not_committed} when retries_left > 0 ->
        append_exact_at(
          state,
          batch_id,
          payloads,
          expected_revision,
          ledger_opts,
          recorded_at,
          retries_left - 1
        )

      {:ok, :not_committed} ->
        {:error, :ambiguous_commit_unresolved}

      {:error, _reason} ->
        {:error, :ambiguous_commit_unresolved}
    end
  end

  defp repair_missing_duties(state, projection, ledger_opts, conflicts_left) do
    with {:ok, now} <- trusted_recorded_at(state.clock, projection),
         {:ok, plan} <- Reconciler.repair_plan(projection, state.constitution, now) do
      if plan.payloads == [] do
        {:ok, projection}
      else
        commit_duty_repair(state, projection, plan, ledger_opts, conflicts_left, now)
      end
    end
  end

  defp preflight_duty_repair(state, ledger_opts) do
    case repair_missing_duties(
           state,
           state.projection,
           ledger_opts,
           state.conflict_retries
         ) do
      {:ok, projection} ->
        {:ok, %{state | projection: projection}}

      {:error, reason} ->
        tagged = {:preflight_duty_repair_failed, reason}
        {:error, halt(state, tagged), tagged}
    end
  end

  defp duties_materialized(projection, constitution, now) do
    with {:ok, plan} <- Reconciler.repair_plan(projection, constitution, now) do
      if plan.payloads == [], do: :ok, else: {:error, :required_duties_pending}
    end
  end

  defp commit_duty_repair(
         state,
         projection,
         plan,
         ledger_opts,
         conflicts_left,
         recorded_at
       ) do
    with {:ok, _provisional} <- apply_payloads(projection, plan.payloads) do
      repair_state = %{state | projection: projection}

      case append_exact(
             repair_state,
             plan.batch_id,
             plan.payloads,
             projection.revision,
             ledger_opts,
             state.ambiguous_retries,
             recorded_at
           ) do
        {:ok, recovered} ->
          {:ok, recovered}

        :conflict when conflicts_left > 0 ->
          retry_duty_repair_after_conflict(
            repair_state,
            ledger_opts,
            conflicts_left - 1
          )

        :conflict ->
          {:error, :duty_repair_conflict_retries_exhausted}

        {:error, {:durable_recovery_failed, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:duty_repair_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:duty_repair_failed, reason}}
    end
  end

  defp retry_duty_repair_after_conflict(state, ledger_opts, conflicts_left) do
    with {:ok, projection} <- recover_verified(state, ledger_opts) do
      repair_missing_duties(
        %{state | projection: projection},
        projection,
        ledger_opts,
        conflicts_left
      )
    end
  end

  defp recover_after_append(state, ledger_opts) do
    case recover_with_repair(state, ledger_opts) do
      {:ok, projection} -> {:ok, projection}
      {:error, reason} -> {:error, {:durable_recovery_failed, reason}}
    end
  end

  defp recover_with_repair(state, ledger_opts) do
    with {:ok, projection} <- recover_verified(state, ledger_opts) do
      repair_missing_duties(
        %{state | projection: projection},
        projection,
        ledger_opts,
        state.conflict_retries
      )
    end
  end

  defp recover_verified(state, ledger_opts) do
    case Recovery.recover(state.store, state.domain_ref, ledger_opts) do
      {:ok, projection} ->
        with :ok <- Bootstrap.verify_projection(projection, state.bootstrap_opts),
             :ok <- PayloadStore.verify_live_references(state.payload_store, projection) do
          {:ok, projection}
        end

      :not_found ->
        {:error, :domain_ledger_disappeared}

      {:error, _reason} = error ->
        error
    end
  end

  defp mandate_still_active(projection, act, now) do
    authority_view = Projection.authority_view(projection)

    with :ok <- Authority.containment_status(act, authority_view),
         {:ok, mandate} <- Map.fetch(projection.mandates, act.mandate_ref),
         true <- mandate.revision == act.mandate_revision,
         true <- now >= mandate.not_before and now < mandate.expires_at,
         :ok <- Authority.restriction_status(mandate, authority_view),
         :ok <- Authority.meter_debt_status(mandate, authority_view),
         :ok <- mandate_not_revoked(projection, mandate, now) do
      :ok
    else
      :error -> {:error, {:mandate_not_found, act.mandate_ref}}
      false -> {:error, {:mandate_not_dispatchable, act.mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp mandate_not_revoked(projection, mandate, now) do
    case Ancestry.status(projection.mandates, projection.revocations, mandate, now) do
      {:ok, :current} -> :ok
      {:ok, {:revoked, :direct, ref}} -> {:error, {:mandate_revoked, ref}}
      {:ok, {:revoked, :ancestor, ref}} -> {:error, {:mandate_ancestor_revoked, ref}}
      {:error, _reason} = error -> error
    end
  end

  defp authenticate_context(state, scope_ref, input, opts) do
    with :ok <- validate_authentication_options(opts),
         :ok <- Portable.validate_ref(scope_ref, :scope_ref),
         {:ok, context} <-
           call_ingress_authenticate(
             state.ingress,
             state.domain_ref,
             scope_ref,
             input,
             state.generation,
             Keyword.get(opts, :ingress_opts, [])
           ),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- validate_authenticated_context(state, scope_ref, context),
         {:ok, sealed} <- SubmissionContext.seal(context, state.grant_secret) do
      {:ok, sealed}
    end
  end

  defp call_ingress_authenticate(ingress, domain_ref, scope_ref, input, generation, opts) do
    case ingress.authenticate(domain_ref, scope_ref, input, generation, opts) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_ingress_authentication_response}
    end
  rescue
    exception -> {:error, {:ingress_authentication_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:ingress_authentication_failed, kind}}
  end

  defp validate_authenticated_context(state, scope_ref, context) do
    cond do
      context.domain_ref != state.domain_ref ->
        {:error, :authenticated_context_domain_mismatch}

      context.scope_ref != scope_ref ->
        {:error, :authenticated_context_scope_mismatch}

      context.ingress_ref != state.ingress_ref ->
        {:error, :authenticated_context_ingress_mismatch}

      context.host_generation != state.generation ->
        {:error, :authenticated_context_generation_mismatch}

      true ->
        :ok
    end
  end

  defp effective_ledger_opts(state, call_opts) do
    with :ok <- validate_known_options(call_opts, @sequencer_call_options, :sequencer),
         do: {:ok, state.ledger_opts}
  end

  defp validate_authentication_options(opts) do
    with :ok <- validate_known_options(opts, @authentication_call_options, :authentication) do
      case Keyword.get(opts, :ingress_opts, []) do
        value when is_list(value) ->
          if Keyword.keyword?(value), do: :ok, else: {:error, :invalid_ingress_options}

        _invalid ->
          {:error, :invalid_ingress_options}
      end
    end
  end

  defp observation_options(opts) do
    with :ok <- validate_known_options(opts, @observation_call_options, :observation) do
      case Keyword.get(opts, :ingress_opts, []) do
        value when is_list(value) ->
          if Keyword.keyword?(value), do: {:ok, value}, else: {:error, :invalid_ingress_options}

        _invalid ->
          {:error, :invalid_ingress_options}
      end
    end
  end

  defp validate_known_options(opts, allowed, context) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_options, context, unknown}}
    end
  end

  defp verify_payload_references(payload_store, payloads) do
    payloads
    |> Enum.flat_map(&content_payload_refs/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case PayloadStore.verify(payload_store, ref) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_new_payload_references(payload_store, projection, payloads) do
    refs = payloads |> Enum.flat_map(&content_payload_refs/1) |> Enum.uniq()
    PayloadStore.verify_new_references(payload_store, projection, refs)
  end

  defp content_payload_refs(payload) do
    case {field(payload, :type), field(payload, :data)} do
      {"evidence_recorded", data} when is_map(data) ->
        optional_payload_ref(field(data, :payload_ref))

      {"presentation_recorded", data} when is_map(data) ->
        optional_payload_ref(field(data, :rendered_payload_ref))

      _other ->
        []
    end
  end

  defp optional_payload_ref(nil), do: []
  defp optional_payload_ref(ref), do: [ref]

  defp trusted_now(clock) do
    case clock.now() do
      value when is_integer(value) -> {:ok, value}
      _invalid -> {:error, :invalid_trusted_time}
    end
  rescue
    exception -> {:error, {:trusted_clock_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:trusted_clock_failed, kind}}
  end

  defp trusted_recorded_at(clock, %Projection{} = projection) do
    with {:ok, now} <- trusted_now(clock) do
      {:ok, max(now, latest_recorded_at(projection))}
    end
  end

  defp latest_recorded_at(%Projection{} = projection) do
    projection.event_recorded_at
    |> Map.values()
    |> Enum.max(fn -> 0 end)
  end

  defp operational_id(state, _namespace) do
    {:ok, Id.generate(state.id_source)}
  rescue
    exception -> {:error, {:identifier_generation_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:identifier_generation_failed, kind}}
  end

  defp nonce_digest(nonce) do
    :crypto.hash(:sha256, nonce)
    |> Base.encode16(case: :lower)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil

  defp halt(%State{halted_reason: nil} = state, reason) do
    send(self(), {:stop_halted, reason})
    %{state | halted_reason: reason}
  end

  defp halt(%State{} = state, _reason), do: state
end
