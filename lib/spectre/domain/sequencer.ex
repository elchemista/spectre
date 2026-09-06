defmodule Spectre.Domain.Sequencer do
  @moduledoc """
  One ordered command mailbox per Domain.

  The sequencer owns only the operational work needed to preserve a single
  ledger order: admission grouping, queue flushes, reconciliation timers and
  command dispatch. It does not contain governed-act semantics. Pure admission
  lives in `Spectre.Kernel`; append/recovery lives in
  `Spectre.Domain.Transaction`; individual command workflows live below
  `Spectre.Domain.Command`; and external execution routing lives in
  `Spectre.Execution.Router`.

  Keeping this module as a thin GenServer is a trust-boundary property as well
  as a readability choice. Ingress, minds, brokers and executors may share its
  ordering point, but their callbacks cannot become ledger transitions merely
  by running in the same process.
  """

  use GenServer

  require Spectre.Portable

  alias Spectre.{
    Act,
    Attempt,
    Candidate,
    Decision,
    Evidence,
    Outcome,
    Portable,
    Presentation,
    SubmissionContext
  }

  alias Spectre.Domain.Admission.Command, as: AdmissionCommand
  alias Spectre.Domain.Command.Commit, as: CommandCommit
  alias Spectre.Domain.Command.Evidence, as: EvidenceCommand
  alias Spectre.Domain.Command.Execution, as: ExecutionCommand
  alias Spectre.Domain.Command.Input, as: InputCommand
  alias Spectre.Domain.Command.Observation, as: ObservationCommand
  alias Spectre.Domain.Command.Presentation, as: PresentationCommand
  alias Spectre.Domain.Command.Scope, as: ScopeCommand

  alias Spectre.Domain.{
    Configuration,
    Context,
    IngressWork,
    Projection,
    Query,
    Reconciliation,
    Startup,
    Transaction
  }

  alias Spectre.Domain.Sequencer.Control
  alias Spectre.Domain.Sequencer.State
  alias Spectre.Execution.Router
  alias Spectre.Kernel.Grant
  alias Spectre.Mind.Turn
  alias Spectre.Scope.Opening
  alias Spectre.Secret.CheckoutReceipt

  @maximum_reconciliation_delay_ms 86_400_000
  @sequencer_call_options [:timeout]
  @observation_call_options [:timeout, :ingress_opts]
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
      when is_list(opts),
      do: call(server, {:submit, context, candidate, opts}, opts, :invalid_submission_options)

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
    call(
      server,
      {:submit_scope_opening, parent_context, child_context, candidate, opts},
      opts,
      :invalid_governed_scope_opening_options
    )
  end

  def submit_scope_opening(_server, _parent_context, _child_context, _candidate, _opts),
    do: {:error, :invalid_governed_scope_opening_input}

  @doc false
  @spec authenticate(GenServer.server(), String.t(), term(), keyword()) ::
          {:ok, SubmissionContext.t()} | {:error, term()}
  def authenticate(server, scope_ref, input, opts \\ [])

  def authenticate(server, scope_ref, input, opts) when is_list(opts),
    do:
      call(
        server,
        {:authenticate, scope_ref, input, opts},
        opts,
        :invalid_authentication_options
      )

  def authenticate(_server, _scope_ref, _input, _opts),
    do: {:error, :invalid_authentication_options}

  @doc false
  @spec consume_grant(GenServer.server(), Grant.t(), keyword()) ::
          {:ok, Act.t(), Attempt.t(), CheckoutReceipt.t()} | {:error, term()}
  def consume_grant(server, grant, opts \\ [])

  def consume_grant(server, %Grant{} = grant, opts) when is_list(opts),
    do:
      call(
        server,
        {:consume_grant, grant, opts},
        opts,
        :invalid_grant_consumption_options
      )

  def consume_grant(_server, _grant, _opts), do: {:error, :invalid_grant}

  @doc false
  @spec execution_route(GenServer.server(), Act.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execution_route(server, act, opts \\ [])

  def execution_route(server, %Act{} = act, opts) when is_list(opts) do
    call(
      server,
      {:execution_route, act.executor_ref, act.executor_contract_ref, opts},
      opts,
      :invalid_execution_route_options
    )
  end

  def execution_route(_server, _act, _opts), do: {:error, :invalid_execution_route}

  @doc false
  @spec record_outcome(GenServer.server(), Outcome.t() | map() | keyword(), keyword()) ::
          {:ok, Outcome.t()} | {:error, term()}
  def record_outcome(server, outcome, opts \\ [])

  def record_outcome(server, outcome, opts) when is_list(opts),
    do: call(server, {:record_outcome, outcome, opts}, opts, :invalid_outcome_options)

  def record_outcome(_server, _outcome, _opts), do: {:error, :invalid_outcome_options}

  @doc false
  @spec observe(GenServer.server(), SubmissionContext.t(), term(), keyword()) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def observe(server, context, input, opts \\ [])

  def observe(server, %SubmissionContext{} = context, input, opts) when is_list(opts),
    do:
      call(
        server,
        {:observe, context, input, opts},
        opts,
        :invalid_observation_options
      )

  def observe(_server, _context, _input, _opts), do: {:error, :invalid_observation_input}

  @doc false
  @spec begin_turn(
          GenServer.server(),
          SubmissionContext.t(),
          term(),
          [String.t()],
          keyword()
        ) :: {:ok, {module(), Turn.t()}} | {:error, term()}
  def begin_turn(server, context, input, context_evidence_refs, opts \\ [])

  def begin_turn(
        server,
        %SubmissionContext{} = context,
        input,
        context_evidence_refs,
        opts
      )
      when is_list(context_evidence_refs) and is_list(opts) do
    call(
      server,
      {:begin_turn, context, input, context_evidence_refs, opts},
      opts,
      :invalid_turn_options
    )
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
    call(
      server,
      {:record_derivation, context, turn, evidence, opts},
      opts,
      :invalid_derivation_options
    )
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
      when Portable.is_non_empty_binary(act_ref) and Portable.is_non_empty_binary(attempt_ref) and
             is_list(opts) do
    call(
      server,
      {:record_executor_evidence, act_ref, attempt_ref, evidence, opts},
      opts,
      :invalid_executor_evidence_options
    )
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
    call(
      server,
      {:record_presentation, context, presentation, opts},
      opts,
      :invalid_presentation_options
    )
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

  def open_scope(server, %SubmissionContext{} = context, opening, opts) when is_list(opts),
    do:
      call(
        server,
        {:open_scope, context, opening, opts},
        opts,
        :invalid_scope_opening_options
      )

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
  def head(server), do: GenServer.call(server, :head)

  @doc false
  def query(server, %Spectre.Scope{} = scope, query),
    do: GenServer.call(server, {:query, scope, query})

  @doc false
  @spec scope_projection(GenServer.server(), SubmissionContext.t()) ::
          {:ok, Projection.t()} | {:error, term()}
  def scope_projection(server, %SubmissionContext{} = context),
    do: GenServer.call(server, {:scope_projection, context})

  def scope_projection(_server, _context), do: {:error, :authenticated_scope_context_required}

  @doc false
  @spec definition(GenServer.server(), SubmissionContext.t(), String.t()) ::
          {:ok, Spectre.Definition.t()} | {:error, term()}
  def definition(server, %SubmissionContext{} = context, ref)
      when Portable.is_non_empty_binary(ref),
      do: GenServer.call(server, {:definition, context, ref})

  def definition(_server, %SubmissionContext{}, ref),
    do: {:error, {:invalid_definition_ref, ref}}

  def definition(_server, _context, _ref),
    do: {:error, :authenticated_scope_context_required}

  @doc false
  @spec late_observer(GenServer.server()) :: {:ok, module()} | {:error, term()}
  def late_observer(server), do: GenServer.call(server, :late_observer)

  @doc false
  @spec trusted_time(GenServer.server(), keyword()) :: {:ok, integer()} | {:error, term()}
  def trusted_time(server, opts \\ [])

  def trusted_time(server, opts) when is_list(opts),
    do: call(server, {:trusted_time, opts}, opts, :invalid_trusted_time_options)

  def trusted_time(_server, _opts), do: {:error, :invalid_trusted_time_options}

  @impl GenServer
  def init(opts) do
    with {:ok, config} <- Configuration.new(opts),
         {:ok, projection} <- Startup.load(config),
         state = State.new(config, projection),
         {:ok, projection} <- Transaction.repair_missing_duties(state),
         {:ok, ingress_supervisor} <- Task.Supervisor.start_link() do
      {:ok,
       schedule_reconciliation(%{
         state
         | projection: projection,
           ingress_supervisor: ingress_supervisor
       })}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:projection, _from, %State{} = state),
    do: {:reply, state.projection, state}

  def handle_call(:head, _from, %State{} = state),
    do: {:reply, {:ok, Query.head(state)}, state}

  # Projection inspection is capability-free and remains available for crash
  # recovery. Every scoped or operational request is fenced as soon as a fatal
  # state has scheduled this process for termination.
  def handle_call(_request, _from, %State{halted_reason: reason} = state)
      when not is_nil(reason),
      do: {:reply, {:error, {:sequencer_halted, reason}}, state}

  def handle_call({:scope_projection, context}, _from, %State{} = state) do
    reply =
      with {:ok, _context, _opening} <- Context.validate_scope(state, context),
           do: {:ok, state.projection}

    {:reply, reply, state}
  end

  def handle_call({:query, scope, query}, _from, %State{} = state),
    do: {:reply, Query.scoped(state, scope, query), state}

  def handle_call({:definition, context, ref}, _from, %State{} = state) do
    reply =
      with {:ok, _context, _opening} <- Context.validate_scope(state, context),
           do: Projection.definition(state.projection, ref)

    {:reply, reply, state}
  end

  def handle_call(:late_observer, _from, %State{late_observer: nil} = state),
    do: {:reply, {:error, :late_observer_not_configured}, state}

  def handle_call(:late_observer, _from, %State{} = state),
    do: {:reply, {:ok, state.late_observer}, state}

  def handle_call({:resume_scope, context}, _from, %State{} = state) do
    reply =
      with {:ok, _context, opening} <- Context.validate_scope(state, context) do
        {:ok, opening}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:execution_route, executor_ref, contract_ref, opts},
        _from,
        %State{} = state
      ) do
    reply =
      with :ok <- validate_known_options(opts, @sequencer_call_options, :execution_route),
           do: Router.fetch(state.execution_boundary, executor_ref, contract_ref)

    {:reply, reply, state}
  end

  def handle_call({:authenticate, scope_ref, input, opts}, from, %State{} = state),
    do: IngressWork.authenticate(state, from, scope_ref, input, opts)

  def handle_call({:trusted_time, opts}, _from, %State{} = state) do
    reply =
      with :ok <- validate_known_options(opts, @sequencer_call_options, :trusted_time),
           do: Transaction.trusted_recorded_at(state)

    {:reply, reply, state}
  end

  def handle_call(
        request,
        _from,
        %State{pending_count: count, max_pending_submissions: limit} = state
      )
      when is_tuple(request) and elem(request, 0) in [:submit, :submit_scope_opening] and
             count >= limit,
      do: {:reply, {:error, :submission_queue_full}, state}

  def handle_call({:submit, context, candidate, opts}, from, %State{} = state) do
    case validate_call_options(opts) do
      :ok ->
        request = %{
          from: from,
          context: context,
          candidate: candidate
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
    case validate_call_options(opts) do
      :ok ->
        request = %{
          from: from,
          context: parent_context,
          child_context: child_context,
          candidate: candidate
        }

        {:noreply, enqueue_submission(state, request)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_grant, grant, opts}, _from, %State{} = state) do
    validated_command_reply(state, opts, &ExecutionCommand.consume(&1, grant))
  end

  def handle_call({:record_outcome, input, opts}, _from, %State{} = state) do
    validated_command_reply(state, opts, &ObservationCommand.record(&1, input))
  end

  def handle_call({:observe, context, input, opts}, from, %State{} = state),
    do: ingress_observation_reply(state, from, context, input, opts)

  def handle_call(
        {:begin_turn, context, input, context_evidence_refs, opts},
        from,
        %State{} = state
      ),
      do: begin_turn_reply(state, from, context, input, context_evidence_refs, opts)

  def handle_call({:record_derivation, context, turn, evidence, opts}, _from, %State{} = state),
    do: derivation_reply(state, context, turn, evidence, opts)

  def handle_call(
        {:record_executor_evidence, act_ref, attempt_ref, evidence, opts},
        _from,
        %State{} = state
      ),
      do: executor_evidence_reply(state, act_ref, attempt_ref, evidence, opts)

  def handle_call({:open_scope, context, input, opts}, _from, %State{} = state) do
    validated_command_reply(state, opts, &ScopeCommand.open(&1, context, input))
  end

  def handle_call({:record_presentation, context, input, opts}, _from, %State{} = state) do
    validated_command_reply(state, opts, &PresentationCommand.record(&1, context, input))
  end

  defp ingress_observation_reply(state, from, context, input, opts) do
    case observation_options(opts) do
      {:ok, ingress_opts} ->
        IngressWork.observe(state, from, context, input, ingress_opts, :observe)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp begin_turn_reply(state, from, context, input, context_evidence_refs, opts) do
    with {:ok, mind} <- configured_mind(state),
         {:ok, ingress_opts} <- observation_options(opts),
         {:ok, context_evidence_refs} <-
           Portable.normalize_refs(context_evidence_refs, :context_evidence_refs) do
      IngressWork.observe(
        state,
        from,
        context,
        input,
        ingress_opts,
        {:turn, mind},
        context_evidence_refs
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp attach_mind({:ok, state, turn}, mind), do: {:ok, state, {mind, turn}}
  defp attach_mind({:error, _state, _reason} = error, _mind), do: error

  defp configured_mind(%State{mind: nil}), do: {:error, :mind_not_configured}
  defp configured_mind(%State{mind: mind}), do: {:ok, mind}

  defp derivation_reply(state, context, turn, input, opts) do
    with :ok <- validate_call_options(opts),
         {:ok, evidence} <- Evidence.new(input) do
      run_after_duty_repair(
        state,
        &InputCommand.record_derivation(&1, context, turn, evidence)
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp executor_evidence_reply(state, act_ref, attempt_ref, input, opts) do
    with :ok <- validate_call_options(opts),
         {:ok, evidence, _shape} <- EvidenceCommand.normalize(input) do
      run_after_duty_repair(
        state,
        &InputCommand.record_executor_evidence(&1, act_ref, attempt_ref, evidence)
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, %State{} = state) when is_reference(ref) do
    case IngressWork.take(state, ref) do
      {:ok, job, state} ->
        {:reply, reply, state} = finish_ingress(state, job.operation, result)
        GenServer.reply(job.from, reply)
        {:noreply, state}

      :not_found ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    fail_ingress(state, ref, {:ingress_worker_failed, reason})
  end

  def handle_info({:ingress_timeout, ref}, %State{} = state),
    do: fail_ingress(state, ref, :ingress_timeout)

  def handle_info({:stop_halted, reason}, %State{halted_reason: reason} = state),
    do: {:stop, {:shutdown, {:sequencer_halted, reason}}, state}

  def handle_info({:stop_halted, _stale_reason}, %State{} = state),
    do: {:noreply, state}

  def handle_info({:flush, token}, %State{flush: {token, _timer}} = state) do
    batch_count = min(state.pending_count, state.batch_size)
    {batch, remaining} = :queue.split(batch_count, state.pending)
    requests = :queue.to_list(batch)

    state = %{
      state
      | pending: remaining,
        pending_count: state.pending_count - batch_count,
        flush: nil
    }

    state = process_submissions(state, requests)
    state = state |> schedule_remaining() |> schedule_reconciliation()
    {:noreply, state}
  end

  def handle_info({:flush, _stale_token}, %State{} = state), do: {:noreply, state}

  def handle_info({:reconcile, token}, %State{reconciliation: {token, _timer}} = state) do
    state = %{state | reconciliation: nil}

    case Transaction.repair_missing_duties(state) do
      {:ok, projection} ->
        {:noreply, schedule_reconciliation(%{state | projection: projection})}

      {:error, reason} ->
        {:noreply, Control.halt(state, {:reconciliation_failed, reason})}
    end
  end

  def handle_info({:reconcile, _stale_token}, %State{} = state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: IngressWork.stop_all(state)

  defp finish_ingress(%State{halted_reason: reason} = state, _operation, _result)
       when not is_nil(reason),
       do: {:reply, {:error, {:sequencer_halted, reason}}, state}

  defp finish_ingress(state, _operation, {:error, reason}),
    do: {:reply, {:error, reason}, state}

  defp finish_ingress(state, {:authenticate, scope_ref}, {:ok, context}),
    do: {:reply, Context.finish_authentication(state, scope_ref, context), state}

  defp finish_ingress(state, {:observe, context, _refs}, {:ok, evidence}),
    do: run_after_duty_repair(state, &InputCommand.finish_observation(&1, context, evidence))

  defp finish_ingress(state, {{:turn, mind}, context, refs}, {:ok, evidence}) do
    run_after_duty_repair(state, fn current ->
      current |> InputCommand.finish_turn(context, evidence, refs) |> attach_mind(mind)
    end)
  end

  defp fail_ingress(state, ref, reason) do
    case IngressWork.take(state, ref) do
      {:ok, job, state} ->
        IngressWork.stop(job)
        GenServer.reply(job.from, {:error, reason})
        {:noreply, state}

      :not_found ->
        {:noreply, state}
    end
  end

  defp call(server, request, opts, invalid_options) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, request, call_timeout(opts)),
      else: {:error, invalid_options}
  end

  defp call_timeout(opts), do: Keyword.get(opts, :timeout, :infinity)

  defp enqueue_submission(%State{} = state, request) do
    pending = :queue.in(request, state.pending)
    pending_count = state.pending_count + 1
    state = %{state | pending: pending, pending_count: pending_count}

    cond do
      is_nil(state.flush) -> schedule_flush(state, state.batch_wait_ms)
      pending_count >= state.batch_size -> expedite_flush(state)
      true -> state
    end
  end

  defp schedule_flush(%State{flush: nil} = state, delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:flush, token}, delay)
    %{state | flush: {token, timer}}
  end

  defp schedule_flush(%State{} = state, _delay), do: state

  defp expedite_flush(%State{flush: {_token, nil}} = state), do: state

  defp expedite_flush(%State{flush: {token, timer}} = state) do
    if timer, do: Process.cancel_timer(timer, async: true, info: false)
    send(self(), {:flush, token})
    %{state | flush: {token, nil}}
  end

  defp schedule_remaining(%State{pending_count: 0} = state), do: state

  defp schedule_remaining(%State{halted_reason: nil} = state), do: schedule_flush(state, 0)

  defp schedule_remaining(%State{} = state) do
    state.pending
    |> :queue.to_list()
    |> Enum.each(fn request ->
      GenServer.reply(request.from, {:error, {:sequencer_halted, state.halted_reason}})
    end)

    %{state | pending: :queue.new(), pending_count: 0}
  end

  defp schedule_reconciliation(%State{} = state) do
    state = cancel_reconciliation_timer(state)

    if state.halted_reason do
      state
    else
      case Transaction.trusted_recorded_at(state) do
        {:ok, now} -> schedule_next_reconciliation(state, now)
        {:error, reason} -> Control.halt(state, reason)
      end
    end
  end

  defp cancel_reconciliation_timer(%State{reconciliation: nil} = state), do: state

  defp cancel_reconciliation_timer(%State{reconciliation: {_token, timer}} = state) do
    Process.cancel_timer(timer, async: true, info: false)
    %{state | reconciliation: nil}
  end

  defp schedule_next_reconciliation(state, now) do
    deadline = Reconciliation.next_deadline(state.projection, now)

    case deadline do
      nil ->
        state

      deadline ->
        delay = deadline |> Kernel.-(now) |> max(0) |> min(@maximum_reconciliation_delay_ms)
        token = make_ref()
        timer = Process.send_after(self(), {:reconcile, token}, delay)
        %{state | reconciliation: {token, timer}}
    end
  end

  defp process_submissions(%State{} = state, requests) do
    {next_state, replies} = AdmissionCommand.run(state, requests)
    Enum.each(replies, fn {from, reply} -> GenServer.reply(from, reply) end)
    next_state
  end

  defp run_after_duty_repair(%State{} = state, command) when is_function(command, 1) do
    case CommandCommit.prepare(state) do
      {:ok, current} -> current |> command.() |> command_reply()
      {:error, halted, reason} -> {:reply, {:error, reason}, halted}
    end
  end

  defp validated_command_reply(%State{} = state, opts, command)
       when is_function(command, 1) do
    case validate_call_options(opts) do
      :ok -> run_after_duty_repair(state, command)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp command_reply({:ok, %State{} = state, value}),
    do: {:reply, {:ok, value}, schedule_reconciliation(state)}

  defp command_reply({:ok, %State{} = state, act, attempt, receipt}),
    do: {:reply, {:ok, act, attempt, receipt}, schedule_reconciliation(state)}

  defp command_reply({:error, %State{} = state, reason}),
    do: {:reply, {:error, reason}, schedule_reconciliation(state)}

  defp validate_call_options(call_opts),
    do: validate_known_options(call_opts, @sequencer_call_options, :sequencer)

  defp observation_options(opts) do
    with :ok <- validate_known_options(opts, @observation_call_options, :observation) do
      value = Keyword.get(opts, :ingress_opts, [])
      if Portable.keyword?(value), do: {:ok, value}, else: {:error, :invalid_ingress_options}
    end
  end

  defp validate_known_options(opts, allowed, context) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_options, context, unknown}}
    end
  end
end
