defmodule Spectre.Operation.Runtime.Results do
  @moduledoc """
  Result reduction and completion evaluation for the operation runtime.

  Applies fenced Runner results through the controller reducer, schedules
  retries and reconciliations for failed or ambiguous outcomes, and evaluates
  the deterministic completion decision after a result transition committed.
  """

  import Spectre.Operation.Runtime.Support
  import Spectre.Operation.Runtime.Transitions

  alias Spectre.Operation.Budget
  alias Spectre.Operation.Control
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Retry
  alias Spectre.Operation.Runtime.Contract
  alias Spectre.Operation.Runtime.StartLoops
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator
  alias Spectre.Operation.Wait

  @doc "Applies one correlated Runner result, returning proposed start-loop intents."
  @spec apply(Loop.t(), Control.t(), Result.t(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()], [map()]}
          | {:duplicate, Loop.t()}
          | {:error, term()}
  def apply(%Loop{} = loop, %Control{} = control, %Result{} = result, env) do
    with :ok <- validate_result(loop, control, result, env),
         {:ok, definition} <- Contract.current_definition(loop),
         {:ok, spec} <- Registry.resolve(Map.fetch!(env, :agent), definition, result.operation) do
      case result.status do
        :ok ->
          reduce_success(loop, control, definition, spec, result, env)

        :error ->
          without_start_loops(reduce_failure(loop, control, spec, result.error, result, env))

        :ambiguous ->
          without_start_loops(reduce_ambiguous(loop, control, spec, result.error, result, env))
      end
    else
      {:duplicate, _result_id} -> {:duplicate, loop}
      {:error, _reason} = error -> error
    end
  end

  @doc "Evaluates the controller completion decision for a quiescent loop."
  @spec evaluate(Loop.t(), Control.t(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]} | {:error, term()}
  def evaluate(%Loop{status: :evaluating, attempt: nil} = loop, %Control{} = control, env) do
    context = controller_context(loop, env)

    case callback(loop.controller, :complete, [loop.state, context]) do
      {:ok, decision} ->
        apply_completion_decision(loop, control, decision, env)

      {:error, reason} ->
        next = fail(loop, {:completion_callback_failed, reason}, env)
        {terminal, rejected} = terminal_control(control)
        {:ok, next, terminal, [event(:failed, %{reason: reason}) | rejected]}
    end
  end

  def evaluate(%Loop{} = loop, _control, _env),
    do: {:error, {:loop_not_awaiting_evaluation, loop.status}}

  @doc "Schedules a fenced retry wait for a recoverable failure."
  @spec retry_transition(Loop.t(), Control.t(), Spec.t(), term(), non_neg_integer(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]}
  def retry_transition(loop, control, spec, reason, delay, env) do
    retry_number = loop.attempt.retry_number + 1

    request =
      case loop.next_operation do
        %Request{} = request ->
          %{request | metadata: Map.put(request.metadata, :retry_number, retry_number)}

        _missing ->
          Request.new(spec.id, nil)
      end

    wait =
      Wait.new(:retry,
        due_at: now(env) + delay,
        payload: %{operation: spec.id, request_id: request.id, retry: retry_number},
        reason: reason,
        generation: loop.trigger_generation
      )

    next =
      loop
      |> clear_attempt()
      |> Map.put(:status, :waiting)
      |> Map.put(:wait, wait)
      |> Map.put(:next_operation, request)
      |> Map.put(:last_error, reason)
      |> Map.update!(:retries, &(&1 + 1))
      |> Map.put(:budget, Budget.consume(loop.budget, retries: 1))
      |> Loop.touch(at: now(env))

    {:ok, next, control,
     [
       event(
         :retry_scheduled,
         wait_event(wait, loop, %{delay_ms: delay, retry: retry_number})
       )
     ]}
  end

  @doc "Schedules the reconciliation operation for an ambiguous side effect."
  @spec reconcile_transition(Loop.t(), Control.t(), Spec.t(), term(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]}
  def reconcile_transition(loop, control, spec, reason, env) do
    request = Request.new(spec.id, loop.receipt || reason, phase: :reconciliation)

    next =
      loop
      |> clear_attempt()
      |> Map.put(:status, :reconciling)
      |> Map.put(:wait, nil)
      |> Map.put(:next_operation, request)
      |> Map.put(:last_error, {:outcome_ambiguous, reason})
      |> put_reconciliation_marker(request, true)
      |> Loop.touch(at: now(env))

    {:ok, next, control, [event(:reconciliation_required, %{operation: spec.id})]}
  end

  @doc "Parks the loop on a reconciliation wait for an unknowable side effect."
  @spec ambiguous_wait(Loop.t(), Control.t(), term(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]}
  def ambiguous_wait(loop, control, reason, env) do
    wait = Wait.new(:reconciliation, reason: reason, payload: %{operation: loop.operation})

    next =
      loop
      |> clear_attempt()
      |> Map.put(:status, :waiting)
      |> Map.put(:wait, wait)
      |> Map.put(:last_error, {:side_effect_outcome_unknown, reason})
      |> Loop.touch(at: now(env))

    {:ok, next, control, [event(:side_effect_outcome_unknown, wait_event(wait, loop))]}
  end

  defp reduce_success(loop, control, definition, _spec, result, env) do
    request = loop.next_operation
    context = controller_context(loop, Map.put(env, :operation_result, result))

    with {:ok, reply} <-
           callback(loop.controller, :apply_result, [loop.state, request, result, context]),
         {:ok, state, opts} <- normalize_reducer(reply),
         :ok <- Validator.validate(definition.state, state, {:loop_state, definition.id}),
         :ok <- portable(state, [:loop, loop.id, :state]),
         :ok <- Contract.validate_significance(loop.kind, option(opts, :significance)),
         :ok <- Contract.validate_cost(result.usage, option(opts, :cost)),
         artifacts <- result.artifacts ++ List.wrap(option(opts, :artifacts, [])),
         :ok <- Contract.validate_artifacts(definition, loop, artifacts),
         {:ok, start_loops} <-
           StartLoops.normalize(definition, loop, option(opts, :start_loops, [])),
         :ok <- portable(opts, [:loop, loop.id, :transition]) do
      usage = normalize_map(result.usage)
      cost = Map.get(usage, :cost, Map.get(usage, "cost", option(opts, :cost, 0)))

      significance = normalize_significance(loop.kind, option(opts, :significance))

      next =
        loop
        |> clear_attempt()
        |> Map.put(:state, state)
        |> Map.put(:status, :evaluating)
        |> Map.put(:phase, option(opts, :phase, loop.phase))
        |> Map.put(:last_result, result)
        |> Map.put(:last_error, nil)
        |> Map.put(:receipt, result.receipt || option(opts, :receipt))
        |> Map.put(:last_progress, option(opts, :progress, loop.last_progress))
        |> Map.put(:next_operation, nil)
        |> clear_reconciliation_marker()
        |> Map.update!(:cycles, &(&1 + 1))
        |> maybe_increment_observations()
        |> Map.update!(:budget, &Budget.consume(&1, steps: 1, cost: cost || 0))
        |> append_results(option(opts, :results, [result.value]))
        |> append_artifacts(artifacts, Contract.artifact_limit(definition))
        |> append_invalidations(List.wrap(option(opts, :invalidations, [])))
        |> put_cognitive_result(result)
        |> put_significance(significance, result, env)
        |> Loop.touch(at: now(env))

      events = [
        event(:attempt_committed, %{attempt_id: result.attempt_id}),
        observation_event(loop.kind, significance, result)
      ]

      {:ok, next, control, Enum.reject(events, &is_nil/1), start_loops}
    end
  end

  defp reduce_failure(loop, control, spec, reason, result, env) do
    attempt = loop.attempt
    reason_class = reason_class(reason)
    retryable? = Retry.retry?(spec.retry, reason_class, attempt.retry_number + 1)
    exhaustion = budget_exhaustion(loop, env)

    cond do
      retryable? and is_nil(exhaustion) ->
        delay = Retry.delay(spec.retry, attempt.retry_number + 1)

        retry_transition(
          %{loop | last_result: result, last_error: reason},
          control,
          spec,
          reason,
          delay,
          env
        )

      retryable? ->
        {dimension, consumed, limit} = exhaustion

        exhausted =
          loop
          |> clear_attempt()
          |> Map.put(:last_result, result)
          |> Map.put(:last_error, reason)
          |> terminal_budget(dimension, consumed, limit, env)

        {terminal_ctrl, rejected} = terminal_control(control)

        {:ok, exhausted, terminal_ctrl,
         [
           event(:attempt_failed),
           event(:budget_exhausted, budget_event(dimension, consumed, limit))
           | rejected
         ]}

      true ->
        terminal =
          loop
          |> clear_attempt()
          |> Map.put(:last_result, result)
          |> Map.put(:last_error, reason)
          |> fail(reason, env)

        {terminal_ctrl, rejected} = terminal_control(control)
        {:ok, terminal, terminal_ctrl, [event(:attempt_failed), event(:failed) | rejected]}
    end
  end

  defp reduce_ambiguous(loop, control, spec, reason, result, env) do
    loop = %{loop | last_result: result, last_error: reason}

    case spec.side_effect do
      :none -> reduce_failure(loop, control, spec, reason, result, env)
      :idempotent -> reduce_failure(loop, control, spec, reason, result, env)
      :reconcilable -> reconcile_transition(loop, control, spec, reason, env)
      :non_idempotent -> ambiguous_wait(loop, control, reason, env)
    end
  end

  defp apply_completion_decision(loop, control, decision, env)
       when decision in [:continue, false] do
    cond do
      control.state == :pause_requested ->
        next = loop |> Map.put(:status, :paused) |> Loop.touch(at: now(env))
        {:ok, next, control, [event(:safe_boundary_reached)]}

      match?({_, _, _}, budget_exhaustion(loop, env)) ->
        {dimension, consumed, limit} = budget_exhaustion(loop, env)
        next = terminal_budget(loop, dimension, consumed, limit, env)
        {terminal, rejected} = terminal_control(control)

        {:ok, next, terminal,
         [event(:budget_exhausted, budget_event(dimension, consumed, limit)) | rejected]}

      true ->
        next = loop |> Map.put(:status, :queued) |> Loop.touch(at: now(env))
        {:ok, next, control, [event(:cycle_continues)]}
    end
  end

  defp apply_completion_decision(loop, control, {:complete, value}, env) do
    next = complete(loop, value, env)
    {terminal, rejected} = terminal_control(control)
    {:ok, next, terminal, [event(:completed) | rejected]}
  end

  defp apply_completion_decision(loop, control, {:blocked, blocker}, env) do
    with {:ok, definition} <- Contract.current_definition(loop),
         :ok <- Contract.validate_blocker(definition, blocker) do
      wait = Wait.new(:human, reason: blocker, payload: blocker)

      next =
        loop
        |> Map.put(:status, :waiting)
        |> Map.put(:wait, wait)
        |> Map.put(:blocker, blocker)
        |> Loop.touch(at: now(env))

      {:ok, next, control, [event(:blocked, wait_event(wait, loop))]}
    else
      {:error, reason} ->
        next = fail(loop, reason, env)
        {terminal, rejected} = terminal_control(control)
        {:ok, next, terminal, [event(:failed, %{reason: reason}) | rejected]}
    end
  end

  defp apply_completion_decision(loop, control, {:error, reason}, env) do
    next = fail(loop, reason, env)
    {terminal, rejected} = terminal_control(control)
    {:ok, next, terminal, [event(:failed) | rejected]}
  end

  defp apply_completion_decision(loop, control, decision, env) do
    next = fail(loop, {:invalid_completion_decision, decision}, env)
    {terminal, rejected} = terminal_control(control)
    {:ok, next, terminal, [event(:failed) | rejected]}
  end

  defp validate_result(%Loop{last_result: %Result{id: id}}, _control, %Result{id: id}, _env),
    do: {:duplicate, id}

  defp validate_result(%Loop{attempt: nil}, _control, _result, _env),
    do: {:error, :loop_has_no_active_attempt}

  defp validate_result(%Loop{attempt: attempt} = loop, control, result, env) do
    with :ok <- Result.validate(result) do
      cond do
        result.attempt_id != attempt.id ->
          {:error, :operation_attempt_mismatch}

        result.loop_id != loop.id ->
          {:error, :operation_loop_mismatch}

        result.operation != attempt.operation ->
          {:error, :operation_id_mismatch}

        result.epoch != attempt.epoch or result.epoch != Map.fetch!(env, :epoch) ->
          {:error, :operation_epoch_mismatch}

        result.fencing_token != attempt.fencing_token ->
          {:error, :operation_fencing_mismatch}

        result.context_revision != loop.context_revision ->
          {:error, :operation_context_stale}

        result.control_generation != control.generation ->
          {:error, :operation_control_stale}

        result.trigger_generation != loop.trigger_generation ->
          {:error, :operation_trigger_stale}

        true ->
          :ok
      end
    end
  end

  defp normalize_reducer({:ok, state}), do: {:ok, state, %{}}
  defp normalize_reducer({:ok, state, opts}) when is_map(opts), do: {:ok, state, opts}

  defp normalize_reducer({:ok, state, opts}) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, state, Map.new(opts)},
      else: {:error, {:invalid_controller_reducer_options, opts}}
  end

  defp normalize_reducer({:error, reason}), do: {:error, reason}
  defp normalize_reducer(other), do: {:error, {:invalid_controller_reducer, other}}

  defp without_start_loops({:ok, loop, control, events}),
    do: {:ok, loop, control, events, []}
end
