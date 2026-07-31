defmodule Spectre.Operation.Runtime do
  @moduledoc """
  Pure transition engine for Work, Vigil and external operational controllers.

  Slow execution is deliberately absent from this module. It prepares fenced
  attempts and reduces their results; `Spectre.Instance` owns serialization,
  canonical commit, supervision and scheduling.
  """

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Artifact
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Monitor
  alias Spectre.Operation.Outcome
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Retry
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Update
  alias Spectre.Operation.Validator
  alias Spectre.Operation.Wait
  alias Spectre.Run.Value

  @result_limit 128
  @artifact_limit 256
  @update_limit 128
  @invalidation_limit 256

  @type event_spec :: %{required(:type) => atom(), optional(:payload) => term()}
  @type env :: map()

  @spec start(Loop.kind(), module(), term(), keyword(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def start(kind, controller, input, opts, env)
      when kind in [:work, :vigil, :directive] and is_atom(controller) and is_list(opts) and
             is_map(env) do
    with {:ok, definition} <- Definition.load(controller),
         :ok <- ensure_kind(definition, kind),
         :ok <- validate_controller_contract(definition, controller),
         :ok <- Validator.validate(definition.input, input, {:loop_input, definition.id}),
         :ok <- portable(input, [:loop, :input]),
         {:ok, init_reply} <- callback(controller, :init, [input, controller_context(nil, env)]),
         {:ok, state} <- normalize_init(init_reply),
         :ok <- Validator.validate(definition.state, state, {:loop_state, definition.id}),
         :ok <- portable(state, [:loop, :state]) do
      now = now(env)
      id = Keyword.get(opts, :id, Spectre.Identity.uuid7())
      correlation_id = Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7())
      origin = Keyword.get(opts, :origin)
      provenance = Keyword.get(opts, :provenance, origin_provenance(origin))

      with {:ok, budget} <- effective_budget(definition.budget, Keyword.get(opts, :budget), now),
           {:ok, cognitive} <- map_option(Keyword.get(opts, :cognitive, %{}), :cognitive),
           {:ok, metadata} <- map_option(Keyword.get(opts, :metadata, %{}), :metadata) do
        loop = %Loop{
          id: id,
          kind: kind,
          controller: controller,
          controller_id: definition.id,
          controller_version: definition.version,
          base_input: input,
          effective_input: input,
          state: state,
          subject_id: Map.fetch!(env, :subject_id),
          origin: origin,
          source_turn_id: Keyword.get(opts, :turn_id),
          correlation_id: correlation_id,
          causation_id: Keyword.get(opts, :causation_id),
          provenance: provenance,
          created_at: now,
          updated_at: now,
          expires_at: Keyword.get(opts, :expires_at),
          budget: budget,
          authorized_origins: authorized_origins(origin, opts),
          visibility: Keyword.get(opts, :visibility, :origin),
          destinations: List.wrap(Keyword.get(opts, :destinations, [])),
          cognitive: cognitive,
          metadata: Map.put(metadata, :publication, publication_policy(definition))
        }

        with :ok <- validate_loop_security(definition, loop),
             :ok <- Loop.validate(loop) do
          {:ok, loop, Control.new(loop.id), [event(:started, %{definition: definition.id})]}
        end
      else
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Prepares the next registered operation from committed loop state."
  @spec prepare(Loop.t(), Control.t(), env()) ::
          {:run, Loop.t(), Attempt.t(), Spec.t(), Request.t(), boolean(), [event_spec()]}
          | {:transition, Loop.t(), Control.t(), [event_spec()]}
          | {:error, term()}
  def prepare(%Loop{} = loop, %Control{} = control, env) when is_map(env) do
    cond do
      Loop.terminal?(loop) ->
        {:error, :loop_terminal}

      control.state != :active ->
        {:error, {:loop_not_active, control.state}}

      not is_nil(loop.attempt) ->
        {:error, {:loop_attempt_already_active, loop.attempt.id}}

      true ->
        with nil <- budget_exhaustion(loop, env),
             {:ok, definition} <- current_definition(loop),
             {:ok, request, reconcile?} <- next_request(loop, definition, env),
             {:ok, spec} <-
               Registry.resolve(Map.fetch!(env, :agent), definition, request.operation),
             :ok <- validate_request_input(spec, request, reconcile?),
             :ok <- portable(request, [:loop, loop.id, :request]) do
          attempt = build_attempt(loop, control, request, spec, env, reconcile?)

          next =
            loop
            |> Map.put(:status, if(reconcile?, do: :reconciling, else: :active))
            |> Map.put(:phase, request.phase || loop.phase)
            |> Map.put(:operation, request.operation)
            |> Map.put(:next_operation, request)
            |> Map.put(:attempt, attempt)
            |> Map.put(:wait, nil)
            |> Map.put(:attempts, loop.attempts + 1)
            |> Map.put(:budget, Budget.consume(loop.budget, attempts: 1))
            |> put_reconciliation_marker(request, reconcile?)
            |> Loop.touch(at: now(env))

          {:run, next, attempt, spec, request, reconcile?,
           [event(:attempt_started, attempt_event(attempt))]}
        else
          {dimension, consumed, limit} ->
            exhausted = terminal_budget(loop, dimension, consumed, limit, env)

            {:transition, exhausted, %{control | state: :terminal},
             [event(:budget_exhausted, budget_event(dimension, consumed, limit))]}

          {:wait, %Wait{} = wait} ->
            next = loop |> put_wait(wait) |> Loop.touch(at: now(env))
            {:transition, next, control, [event(:waiting, %{kind: wait.kind})]}

          {:blocked, blocker} ->
            wait = Wait.new(:human, reason: blocker, payload: blocker)

            next =
              loop
              |> Map.put(:blocker, blocker)
              |> put_wait(wait)
              |> Loop.touch(at: now(env))

            {:transition, next, control, [event(:blocked, %{wait_id: wait.id})]}

          {:complete, value} ->
            next = complete(loop, value, env)
            {:transition, next, %{control | state: :terminal}, [event(:completed)]}

          {:error, reason} ->
            next = fail(loop, reason, env)

            {:transition, next, %{control | state: :terminal},
             [event(:failed, %{reason: reason})]}
        end
    end
  end

  @doc "Applies one correlated Runner result and leaves completion evaluation for the next commit."
  @spec apply_result(Loop.t(), Control.t(), Result.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:duplicate, Loop.t()} | {:error, term()}
  def apply_result(%Loop{} = loop, %Control{} = control, %Result{} = result, env) do
    with :ok <- validate_result(loop, control, result, env),
         {:ok, definition} <- current_definition(loop),
         {:ok, spec} <- Registry.resolve(Map.fetch!(env, :agent), definition, result.operation) do
      case result.status do
        :ok -> reduce_success(loop, control, definition, spec, result, env)
        :error -> reduce_failure(loop, control, spec, result.error, result, env)
        :ambiguous -> reduce_ambiguous(loop, control, spec, result.error, result, env)
      end
    else
      {:duplicate, _result_id} -> {:duplicate, loop}
      {:error, _reason} = error -> error
    end
  end

  @doc "Evaluates deterministic completion only after the result transition was committed."
  @spec evaluate(Loop.t(), Control.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def evaluate(%Loop{status: :evaluating, attempt: nil} = loop, %Control{} = control, env) do
    context = controller_context(loop, env)

    case callback(loop.controller, :complete, [loop.state, context]) do
      {:ok, decision} ->
        apply_completion_decision(loop, control, decision, env)

      {:error, reason} ->
        next = fail(loop, {:completion_callback_failed, reason}, env)
        {:ok, next, %{control | state: :terminal}, [event(:failed, %{reason: reason})]}
    end
  end

  def evaluate(%Loop{} = loop, _control, _env),
    do: {:error, {:loop_not_awaiting_evaluation, loop.status}}

  @doc "Commits a durable control request without executing it reentrantly."
  @spec request_control(Loop.t(), Control.t(), Command.t(), env()) ::
          {:ok, Loop.t(), Control.t(), pid_action(), [event_spec()]}
          | {:duplicate, Loop.t(), Control.t()}
          | {:error, term()}
  def request_control(%Loop{} = loop, %Control{} = control, %Command{} = command, env) do
    with :ok <- Command.validate(command),
         :ok <- authorize_revision(loop, command.base_revision),
         {:ok, definition} <- current_definition(loop),
         :ok <- authorize_control(definition, command),
         {:ok, requested} <- normalize_control_request(Control.request(control, command)) do
      apply_control_request(loop, requested, env)
    else
      {:duplicate, duplicate} -> {:duplicate, loop, duplicate}
      {:error, _reason} = error -> error
    end
  end

  @type pid_action :: :keep_runner | {:terminate_runner, String.t()}

  @doc "Advances a pending pause/update/resume sequence once the loop is quiescent."
  @spec advance_control(Loop.t(), Control.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def advance_control(
        %Loop{attempt: nil} = loop,
        %Control{pending: %Command{} = command} = control,
        env
      ) do
    case command.action do
      :pause -> finish_pause(loop, control, command, env)
      :update -> apply_update(loop, control, command, env)
      :update_and_resume -> apply_update(loop, control, command, env)
      :resume -> finish_resume(loop, control, command, env)
      :stop -> finish_stop(loop, control, command, env)
      :renew -> finish_renew(loop, control, command, env)
      :trigger -> finish_trigger_command(loop, control, command, env)
    end
  end

  def advance_control(%Loop{} = loop, %Control{}, _env),
    do: {:error, {:loop_not_quiescent_for_control, loop.id}}

  @doc "Applies a correlated timer, event or human trigger to a waiting loop."
  @spec trigger(Loop.t(), Control.t(), term(), keyword(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def trigger(%Loop{} = loop, %Control{} = control, trigger, opts, env) do
    expected_generation = Keyword.get(opts, :generation)
    expected_wait = Keyword.get(opts, :wait_id)

    cond do
      Loop.terminal?(loop) ->
        {:error, :loop_terminal}

      control.state != :active ->
        {:error, {:loop_not_active, control.state}}

      loop.status != :waiting or not is_nil(loop.attempt) ->
        {:error, {:loop_not_waiting_for_trigger, loop.status}}

      not is_nil(expected_generation) and expected_generation != loop.trigger_generation ->
        {:error, {:stale_loop_trigger_generation, expected_generation, loop.trigger_generation}}

      not is_nil(expected_wait) and (is_nil(loop.wait) or expected_wait != loop.wait.id) ->
        {:error, {:stale_loop_wait, expected_wait}}

      true ->
        with {:ok, definition} <- current_definition(loop),
             :ok <- validate_delivered_trigger(definition, loop, trigger, expected_wait),
             :ok <- portable(trigger, [:loop, loop.id, :trigger]),
             {:ok, callback_result} <- trigger_callback(loop, trigger, env),
             {:ok, state, transition_opts} <- normalize_trigger(callback_result),
             :ok <- Validator.validate(definition.state, state, {:loop_state, definition.id}),
             :ok <- portable(state, [:loop, loop.id, :state]) do
          next =
            loop
            |> Map.put(:state, state)
            |> Map.put(:status, :queued)
            |> Map.put(:wait, nil)
            |> Map.put(:blocker, nil)
            |> Map.put(:phase, option(transition_opts, :phase, loop.phase))
            |> Map.update!(:trigger_generation, &(&1 + 1))
            |> Loop.touch(at: now(env))

          {:ok, next, control, [event(:triggered, %{trigger: trigger_class(trigger)})]}
        end
    end
  end

  @doc "Recovers portable loop state after an Agent restart and invalidates the old epoch."
  @spec recover(Loop.t(), Control.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def recover(%Loop{} = loop, %Control{} = control, env) do
    with {:ok, definition} <- current_definition(loop),
         :ok <- validate_checkpoint(loop, control, definition, env) do
      refreshed = refresh_definition_policy(loop, definition, env)
      refreshed? = refreshed != loop
      loop = refreshed
      refresh_events = if refreshed?, do: [event(:definition_policy_refreshed)], else: []

      cond do
        Loop.terminal?(loop) ->
          {:ok, loop, %{control | state: :terminal}, refresh_events}

        is_nil(loop.attempt) ->
          {:ok, loop, control, refresh_events}

        true ->
          case recover_active_attempt(loop, control, definition, env) do
            {:ok, next, next_control, events} ->
              {:ok, next, next_control, refresh_events ++ events}

            {:error, _reason} = error ->
              error
          end
      end
    end
  end

  @doc "Validates a restored loop and its control plane against the current code-owned definition."
  @spec validate_checkpoint(Loop.t(), Control.t(), env()) :: :ok | {:error, term()}
  def validate_checkpoint(%Loop{} = loop, %Control{} = control, env) when is_map(env) do
    with {:ok, definition} <- current_definition(loop) do
      validate_checkpoint(loop, control, definition, env)
    end
  end

  @doc "Reduces an unexpected DOWN for the currently fenced Runner."
  @spec runner_down(Loop.t(), Control.t(), Spec.t(), term(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def runner_down(
        %Loop{attempt: %Attempt{} = attempt} = loop,
        %Control{} = control,
        %Spec{} = spec,
        reason,
        env
      ) do
    crashed = %{
      attempt_id: attempt.id,
      operation: attempt.operation,
      reason: reason_class(reason),
      at: now(env)
    }

    loop = %{loop | last_crash: crashed}

    case Monitor.classify(attempt, spec, reason) do
      {:retry, delay} ->
        retry_transition(loop, control, spec, {:runner_crashed, reason}, delay, env)

      {:reconcile, ambiguity} ->
        reconcile_transition(loop, control, spec, ambiguity, env)

      {:fail, {:side_effect_outcome_unknown, _operation, _reason} = ambiguity} ->
        ambiguous_wait(loop, control, ambiguity, env)

      {:fail, failure} ->
        terminal = fail(clear_attempt(loop), failure, env)
        {:ok, terminal, %{control | state: :terminal}, [event(:attempt_crashed), event(:failed)]}
    end
  end

  def runner_down(%Loop{} = loop, _control, _spec, _reason, _env),
    do: {:error, {:loop_has_no_active_attempt, loop.id}}

  defp reduce_success(loop, control, definition, _spec, result, env) do
    request = loop.next_operation
    context = controller_context(loop, Map.put(env, :operation_result, result))

    with {:ok, reply} <-
           callback(loop.controller, :apply_result, [loop.state, request, result, context]),
         {:ok, state, opts} <- normalize_reducer(reply),
         :ok <- Validator.validate(definition.state, state, {:loop_state, definition.id}),
         :ok <- portable(state, [:loop, loop.id, :state]),
         :ok <- validate_significance(loop.kind, option(opts, :significance)),
         :ok <- validate_cost(result.usage, option(opts, :cost)),
         artifacts <- result.artifacts ++ List.wrap(option(opts, :artifacts, [])),
         :ok <- validate_artifacts(definition, loop, artifacts),
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
        |> append_artifacts(artifacts, artifact_limit(definition))
        |> append_invalidations(List.wrap(option(opts, :invalidations, [])))
        |> put_cognitive_result(result)
        |> put_significance(significance, result, env)
        |> Loop.touch(at: now(env))

      events = [
        event(:attempt_committed, %{attempt_id: result.attempt_id}),
        observation_event(loop.kind, significance, result)
      ]

      {:ok, next, control, Enum.reject(events, &is_nil/1)}
    end
  end

  defp reduce_failure(loop, control, spec, reason, result, env) do
    attempt = loop.attempt
    reason_class = reason_class(reason)

    if Retry.retry?(spec.retry, reason_class, attempt.retry_number + 1) and
         is_nil(Budget.exhausted(loop.budget, now(env))) do
      delay = Retry.delay(spec.retry, attempt.retry_number + 1)

      retry_transition(
        %{loop | last_result: result, last_error: reason},
        control,
        spec,
        reason,
        delay,
        env
      )
    else
      terminal =
        loop
        |> clear_attempt()
        |> Map.put(:last_result, result)
        |> Map.put(:last_error, reason)
        |> fail(reason, env)

      {:ok, terminal, %{control | state: :terminal}, [event(:attempt_failed), event(:failed)]}
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

  defp retry_transition(loop, control, spec, reason, delay, env) do
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

    {:ok, next, control, [event(:retry_scheduled, %{delay_ms: delay, retry: retry_number})]}
  end

  defp reconcile_transition(loop, control, spec, reason, env) do
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

  defp ambiguous_wait(loop, control, reason, env) do
    wait = Wait.new(:reconciliation, reason: reason, payload: %{operation: loop.operation})

    next =
      loop
      |> clear_attempt()
      |> Map.put(:status, :waiting)
      |> Map.put(:wait, wait)
      |> Map.put(:last_error, {:side_effect_outcome_unknown, reason})
      |> Loop.touch(at: now(env))

    {:ok, next, control, [event(:side_effect_outcome_unknown, %{wait_id: wait.id})]}
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

        {:ok, next, %{control | state: :terminal},
         [event(:budget_exhausted, budget_event(dimension, consumed, limit))]}

      true ->
        next = loop |> Map.put(:status, :queued) |> Loop.touch(at: now(env))
        {:ok, next, control, [event(:cycle_continues)]}
    end
  end

  defp apply_completion_decision(loop, control, {:complete, value}, env) do
    next = complete(loop, value, env)
    {:ok, next, %{control | state: :terminal}, [event(:completed)]}
  end

  defp apply_completion_decision(loop, control, {:blocked, blocker}, env) do
    with {:ok, definition} <- current_definition(loop),
         :ok <- validate_blocker(definition, blocker) do
      wait = Wait.new(:human, reason: blocker, payload: blocker)

      next =
        loop
        |> Map.put(:status, :waiting)
        |> Map.put(:wait, wait)
        |> Map.put(:blocker, blocker)
        |> Loop.touch(at: now(env))

      {:ok, next, control, [event(:blocked, %{wait_id: wait.id})]}
    else
      {:error, reason} ->
        next = fail(loop, reason, env)
        {:ok, next, %{control | state: :terminal}, [event(:failed, %{reason: reason})]}
    end
  end

  defp apply_completion_decision(loop, control, {:error, reason}, env) do
    next = fail(loop, reason, env)
    {:ok, next, %{control | state: :terminal}, [event(:failed)]}
  end

  defp apply_completion_decision(loop, control, decision, env) do
    next = fail(loop, {:invalid_completion_decision, decision}, env)
    {:ok, next, %{control | state: :terminal}, [event(:failed)]}
  end

  defp apply_control_request(loop, control, env) do
    command = control.pending

    cond do
      command.action == :stop ->
        action = if loop.attempt, do: {:terminate_runner, loop.attempt.id}, else: :keep_runner
        control = Control.bump_generation(control)
        finish_stop(loop, control, command, env, action)

      command.action == :pause and command.mode == :immediate ->
        immediate_pause(loop, control, command, env)

      command.action in [:pause, :update, :update_and_resume] and not Loop.quiescent?(loop) ->
        next = loop |> Map.put(:status, :pause_requested) |> Loop.touch(at: now(env))
        {:ok, next, control, :keep_runner, [event(:pause_requested, %{mode: command.mode})]}

      true ->
        case advance_control(loop, control, env) do
          {:ok, next, next_control, events} ->
            {:ok, next, next_control, :keep_runner, events}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp immediate_pause(loop, control, command, env) do
    attempt_id = loop.attempt && loop.attempt.id
    {resume_status, wait, next_operation} = immediate_pause_boundary(loop)
    control = Control.bump_generation(control)

    next =
      loop
      |> clear_attempt()
      |> Map.put(:status, :paused)
      |> Map.put(:wait, wait)
      |> Map.put(:next_operation, next_operation)
      |> Map.put(:last_error, immediate_pause_warning(loop))
      |> put_reconciliation_marker(next_operation, resume_status == :reconciling)
      |> put_resume_status(resume_status)
      |> Loop.touch(at: now(env))

    command = Command.applied(command)
    control = Control.finish(control, command)
    action = if attempt_id, do: {:terminate_runner, attempt_id}, else: :keep_runner
    {:ok, next, control, action, [event(:paused, %{mode: :immediate})]}
  end

  defp immediate_pause_warning(%Loop{attempt: %Attempt{side_effect: effect}})
       when effect in [:reconcilable, :non_idempotent],
       do: :interrupted_side_effect_requires_reconciliation

  defp immediate_pause_warning(_loop), do: nil

  defp immediate_pause_boundary(
         %Loop{
           attempt: %Attempt{side_effect: :reconcilable} = attempt
         } = loop
       ) do
    request =
      Request.new(attempt.operation, loop.receipt || :interrupted_before_result,
        phase: :reconciliation,
        metadata: %{interrupted_attempt_id: attempt.id}
      )

    {:reconciling, nil, request}
  end

  defp immediate_pause_boundary(%Loop{
         attempt: %Attempt{side_effect: :non_idempotent} = attempt
       }) do
    wait =
      Wait.new(:reconciliation,
        reason: :interrupted_non_idempotent_side_effect,
        payload: %{operation: attempt.operation, attempt_id: attempt.id}
      )

    {:waiting, wait, nil}
  end

  defp immediate_pause_boundary(%Loop{next_operation: %Request{} = request}),
    do: {:queued, nil, request}

  defp immediate_pause_boundary(_loop), do: {:queued, nil, nil}

  defp finish_pause(loop, control, command, env) do
    next =
      loop
      |> put_resume_status(loop.status)
      |> Map.put(:status, :paused)
      |> Loop.touch(at: now(env))

    control = Control.finish(control, Command.applied(command))
    {:ok, next, control, [event(:paused, %{mode: command.mode})]}
  end

  defp finish_resume(loop, control, command, env) do
    if loop.status == :paused and is_nil(loop.outcome) do
      resume_status = resume_status(loop)

      next =
        loop
        |> Map.put(:status, resume_status)
        |> clear_resume_status()
        |> Loop.touch(at: now(env))

      control = control |> Control.bump_generation() |> Control.finish(Command.applied(command))
      {:ok, next, control, [event(:resumed, %{boundary: resume_status})]}
    else
      reject_control(loop, control, command, {:loop_not_paused, loop.status}, env)
    end
  end

  defp finish_stop(loop, control, command, env) do
    case finish_stop(loop, control, command, env, :keep_runner) do
      {:ok, next, next_control, :keep_runner, events} ->
        {:ok, next, next_control, events}
    end
  end

  defp finish_stop(loop, control, command, env, action) do
    ambiguous? =
      match?(
        %Attempt{side_effect: side_effect} when side_effect in [:reconcilable, :non_idempotent],
        loop.attempt
      )

    category = if ambiguous?, do: :unknown_side_effect, else: :cancelled

    outcome =
      Outcome.new(category,
        reason:
          if(ambiguous?,
            do: {:stop_with_side_effect_outcome_unknown, loop.operation},
            else: command.payload || :stopped
          ),
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1,
        metadata: %{requested_reason: command.payload}
      )

    next =
      loop
      |> clear_attempt()
      |> clear_reconciliation_marker()
      |> Map.put(:status, :terminal)
      |> Map.put(:outcome, outcome)
      |> Map.put(:next_operation, nil)
      |> Map.put(:wait, nil)
      |> Map.put(:blocker, nil)
      |> Loop.touch(at: now(env))

    control = Control.finish(%{control | state: :terminal}, Command.applied(command))
    event_type = if ambiguous?, do: :side_effect_outcome_unknown, else: :cancelled
    {:ok, next, control, action, [event(event_type)]}
  end

  defp finish_renew(loop, control, command, env) do
    current_time = now(env)

    case command.payload do
      %{expires_at: expires_at} when is_integer(expires_at) and expires_at > current_time ->
        next = loop |> Map.put(:expires_at, expires_at) |> Loop.touch(at: now(env))
        control = Control.finish(control, Command.applied(command))
        {:ok, next, control, [event(:renewed, %{expires_at: expires_at})]}

      _invalid ->
        reject_control(loop, control, command, :invalid_renewal, env)
    end
  end

  defp finish_trigger_command(loop, control, command, env) do
    case trigger(loop, control, command.payload, [], env) do
      {:ok, next, _trigger_control, events} ->
        next_control = Control.finish(control, Command.applied(command))
        {:ok, next, next_control, events}

      {:error, reason} ->
        reject_control(loop, control, command, reason, env)
    end
  end

  defp apply_update(loop, control, command, env) do
    definition_result = current_definition(loop)

    update =
      Update.new(command.payload,
        id: command.id,
        correlation_id: command.correlation_id,
        causation_id: command.causation_id,
        provenance: command.provenance,
        base_context_revision: loop.context_revision,
        requested_at: command.requested_at,
        metadata: command.metadata
      )

    with {:ok, definition} <- definition_result,
         :ok <-
           Validator.validate(definition.update, update.payload, {:loop_update, definition.id}),
         true <- function_exported?(loop.controller, :apply_update, 4),
         {:ok, reply} <-
           callback(loop.controller, :apply_update, [
             loop.state,
             loop.effective_input,
             update,
             controller_context(loop, env)
           ]),
         {:ok, state, effective_input, opts} <- normalize_update(reply),
         :ok <- Validator.validate(definition.state, state, {:loop_state, definition.id}),
         :ok <-
           Validator.validate(definition.input, effective_input, {:loop_input, definition.id}),
         :ok <- validate_updated_fields(loop.effective_input, effective_input, definition),
         :ok <- validate_cognitive_update(option(opts, :cognitive, loop.cognitive)),
         :ok <- portable({state, effective_input, opts}, [:loop, loop.id, :update]),
         invalidations <- List.wrap(option(opts, :invalidations, [])),
         applied <- Update.applied(update, loop.context_revision + 1, invalidations),
         :ok <- Update.validate(applied) do
      context_revision = loop.context_revision + 1
      desired = command.desired_state || :paused

      next =
        loop
        |> Map.put(:state, state)
        |> Map.put(:effective_input, effective_input)
        |> Map.put(:context_revision, context_revision)
        |> Map.put(:status, if(desired == :active, do: :queued, else: :paused))
        |> Map.put(:phase, option(opts, :resume_from, option(opts, :phase, loop.phase)))
        |> Map.put(:next_operation, nil)
        |> Map.put(:wait, nil)
        |> Map.put(:blocker, nil)
        |> clear_reconciliation_marker()
        |> clear_resume_status()
        |> Map.put(:cognitive, option(opts, :cognitive, loop.cognitive))
        |> Map.put(:last_update, applied)
        |> Map.update!(:updates, &Enum.take([applied | &1], @update_limit))
        |> append_invalidations(invalidations)
        |> Map.update!(:trigger_generation, &(&1 + trigger_generation_increment(loop.kind)))
        |> Loop.touch(at: now(env))

      command = Command.applied(command)
      control = control |> Control.bump_generation() |> Control.finish(command)

      {:ok, next, control,
       [
         event(:update_applied, %{context_revision: context_revision}),
         event(if(desired == :active, do: :resumed, else: :paused))
       ]}
    else
      false -> reject_control(loop, control, command, :loop_updates_not_supported, env)
      {:error, reason} -> reject_control(loop, control, command, reason, env)
    end
  end

  defp reject_control(loop, control, command, reason, env) do
    reason = reason || :unspecified_control_rejection
    pause_after_rejection? = command.action in [:update, :update_and_resume]

    rejected =
      command
      |> Command.rejected(reason)
      |> then(fn rejected ->
        if pause_after_rejection?, do: %{rejected | desired_state: :paused}, else: rejected
      end)

    control = Control.finish(control, rejected)

    update =
      Update.new(command.payload,
        id: command.id,
        correlation_id: command.correlation_id,
        causation_id: command.causation_id,
        provenance: command.provenance,
        base_context_revision: loop.context_revision,
        requested_at: command.requested_at,
        metadata: command.metadata
      )
      |> Update.rejected(reason)

    next =
      loop
      |> then(fn current ->
        if pause_after_rejection? do
          if current.status == :paused do
            current
          else
            current
            |> put_resume_status(current.status)
            |> Map.put(:status, :paused)
          end
        else
          current
        end
      end)
      |> Map.put(:last_update, update)
      |> Map.update!(:updates, &Enum.take([update | &1], @update_limit))
      |> Loop.touch(at: now(env))

    {:ok, next, control, [event(:control_rejected, %{action: command.action, reason: reason})]}
  end

  defp recover_active_attempt(loop, control, definition, env) do
    attempt = loop.attempt

    with {:ok, spec} <- Registry.resolve(Map.fetch!(env, :agent), definition, attempt.operation) do
      recovered = %{
        loop
        | last_crash: %{attempt_id: attempt.id, reason: :agent_restarted, at: now(env)}
      }

      recovered
      |> recover_attempt_by_side_effect(control, spec, env)
      |> recover_pending_control(spec, env)
    end
  end

  defp recover_attempt_by_side_effect(loop, control, spec, env) do
    case spec.side_effect do
      side_effect when side_effect in [:none, :idempotent] ->
        next = loop |> clear_attempt() |> Map.put(:status, :queued) |> Loop.touch(at: now(env))
        {:ok, next, control, [event(:attempt_recovered, %{strategy: :retry})]}

      :reconcilable ->
        reconcile_transition(loop, control, spec, :agent_restarted, env)

      :non_idempotent ->
        ambiguous_wait(loop, control, :agent_restarted, env)
    end
  end

  defp recover_pending_control(
         {:ok, loop, %Control{pending: nil} = control, events},
         _spec,
         _env
       ),
       do: {:ok, loop, control, events}

  defp recover_pending_control(
         {:ok, loop, %Control{pending: %Command{} = command} = control, recovery_events},
         spec,
         env
       ) do
    transition =
      cond do
        spec.side_effect in [:none, :idempotent] ->
          advance_control(loop, control, env)

        command.action == :pause ->
          advance_control(loop, control, env)

        command.action in [:update, :update_and_resume] ->
          reject_control(
            loop,
            control,
            command,
            {:side_effect_outcome_unknown_during_recovery, spec.id},
            env
          )

        true ->
          advance_control(loop, control, env)
      end

    case transition do
      {:ok, next, next_control, control_events} ->
        {:ok, next, next_control, recovery_events ++ control_events}

      {:error, _reason} = error ->
        error
    end
  end

  defp next_request(
         %Loop{status: :reconciling, next_operation: %Request{} = request},
         definition,
         _env
       ),
       do: validate_next({:ok, request, true}, definition)

  defp next_request(%Loop{next_operation: %Request{} = request} = loop, definition, _env),
    do:
      validate_next(
        {:ok, request, reconciliation_request?(loop, request)},
        definition
      )

  defp next_request(loop, definition, env) do
    with {:ok, decision} <-
           callback(loop.controller, :next, [loop.state, controller_context(loop, env)]) do
      decision |> normalize_next() |> validate_next(definition)
    end
  end

  defp normalize_next({:run, %Request{} = request}), do: {:ok, request, false}
  defp normalize_next({:run, operation, input}), do: {:ok, Request.new(operation, input), false}
  defp normalize_next({:wait, %Wait{} = wait}), do: {:wait, wait}
  defp normalize_next({:blocked, blocker}), do: {:blocked, blocker}
  defp normalize_next({:complete, value}), do: {:complete, value}
  defp normalize_next({:error, reason}), do: {:error, reason}
  defp normalize_next(other), do: {:error, {:invalid_controller_next, other}}

  defp normalize_init({:ok, state}), do: {:ok, state}
  defp normalize_init({:error, reason}), do: {:error, reason}
  defp normalize_init(other), do: {:error, {:invalid_controller_init, other}}

  defp validate_next({:ok, %Request{} = request, reconcile?}, definition) do
    case validate_branch(definition, request) do
      :ok -> {:ok, request, reconcile?}
      {:error, _reason} = error -> error
    end
  end

  defp validate_next({:blocked, blocker}, definition) do
    case validate_blocker(definition, blocker) do
      :ok -> {:blocked, blocker}
      {:error, _reason} = error -> error
    end
  end

  defp validate_next({:wait, %Wait{} = wait}, definition) do
    case validate_wait(definition, wait) do
      :ok -> {:wait, wait}
      {:error, _reason} = error -> error
    end
  end

  defp validate_next(other, _definition), do: other

  defp validate_request_input(_spec, %Request{}, true), do: :ok

  defp validate_request_input(spec, %Request{} = request, false),
    do: Validator.validate(spec.input, request.input, {:operation_input, spec.id})

  defp normalize_reducer({:ok, state}), do: {:ok, state, %{}}
  defp normalize_reducer({:ok, state, opts}) when is_map(opts), do: {:ok, state, opts}

  defp normalize_reducer({:ok, state, opts}) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, state, Map.new(opts)},
      else: {:error, {:invalid_controller_reducer_options, opts}}
  end

  defp normalize_reducer({:error, reason}), do: {:error, reason}
  defp normalize_reducer(other), do: {:error, {:invalid_controller_reducer, other}}

  defp normalize_update({:ok, state, effective_input}),
    do: {:ok, state, effective_input, %{}}

  defp normalize_update({:ok, state, effective_input, opts}) when is_map(opts),
    do: {:ok, state, effective_input, opts}

  defp normalize_update({:ok, state, effective_input, opts}) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, state, effective_input, Map.new(opts)},
      else: {:error, {:invalid_controller_update_options, opts}}
  end

  defp normalize_update({:error, reason}), do: {:error, reason}
  defp normalize_update(other), do: {:error, {:invalid_controller_update, other}}

  defp normalize_trigger({:ok, state}), do: {:ok, state, %{}}
  defp normalize_trigger({:ok, state, opts}) when is_map(opts), do: {:ok, state, opts}

  defp normalize_trigger({:ok, state, opts}) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, state, Map.new(opts)},
      else: {:error, {:invalid_controller_trigger_options, opts}}
  end

  defp normalize_trigger({:error, reason}), do: {:error, reason}
  defp normalize_trigger(other), do: {:error, {:invalid_controller_trigger, other}}

  defp normalize_control_request({:ok, control}), do: {:ok, control}
  defp normalize_control_request({:duplicate, control}), do: {:duplicate, control}
  defp normalize_control_request({:error, _reason} = error), do: error

  defp build_attempt(loop, control, request, spec, env, reconcile?) do
    number = loop.attempts + 1
    id = Spectre.Identity.uuid7()

    %Attempt{
      id: id,
      loop_id: loop.id,
      loop_kind: loop.kind,
      operation: request.operation,
      request_id: request.id,
      number: number,
      epoch: Map.fetch!(env, :epoch),
      fencing_token: Spectre.Identity.uuid7(),
      base_revision: Map.fetch!(env, :canonical_revision),
      context_revision: loop.context_revision,
      control_generation: control.generation,
      trigger_generation: loop.trigger_generation,
      snapshot_id: Map.fetch!(env, :snapshot_id),
      idempotency_key: Value.token("operation", {loop.id, request.id}),
      started_at: now(env),
      timeout: spec.timeout,
      side_effect: spec.side_effect,
      retry_number: Map.get(request.metadata, :retry_number, 0),
      metadata: %{reconcile?: reconcile?}
    }
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

  defp current_definition(loop) do
    with {:ok, definition} <- Definition.load(loop.controller),
         :ok <- ensure_kind(definition, loop.kind),
         :ok <- ensure_definition_identity(definition, loop),
         :ok <- ensure_definition_compatibility(definition, loop),
         :ok <- validate_controller_contract(definition, loop.controller) do
      {:ok, definition}
    else
      {:error, _reason} = error -> error
    end
  end

  defp ensure_definition_identity(%Definition{id: id}, %Loop{controller_id: id}), do: :ok

  defp ensure_definition_identity(%Definition{id: current}, %Loop{controller_id: stored}),
    do: {:error, {:loop_definition_identity_mismatch, stored, current}}

  defp ensure_definition_compatibility(definition, loop) do
    if Definition.compatible?(loop.controller, loop.controller_version, definition.version),
      do: :ok,
      else: {:error, {:incompatible_loop_definition, loop.controller_version, definition.version}}
  end

  defp ensure_kind(%Definition{kind: kind}, kind), do: :ok

  defp ensure_kind(definition, expected),
    do: {:error, {:loop_definition_kind_mismatch, expected, definition.kind}}

  defp validate_controller_contract(definition, controller) do
    cond do
      definition.on_budget_exhausted == :controller and
          not function_exported?(controller, :budget_exhausted, 3) ->
        {:error, {:controller_callback_missing, controller, :budget_exhausted, 3}}

      definition.blockers != [] and not function_exported?(controller, :handle_trigger, 3) ->
        {:error, {:controller_callback_missing, controller, :handle_trigger, 3}}

      true ->
        :ok
    end
  end

  defp validate_loop_security(%Definition{security: security}, loop) do
    allowed_origins = option(security, :allowed_origins, [])
    allowed_destinations = option(security, :allowed_destinations, [])
    allowed_visibility = option(security, :allowed_visibility, [:origin, :subject])

    cond do
      allowed_origins != [] and
          Enum.any?([loop.origin | loop.authorized_origins], &(&1 not in allowed_origins)) ->
        {:error, {:operational_origin_not_authorized, loop.origin}}

      allowed_destinations != [] and
          Enum.any?(loop.destinations, &(&1 not in allowed_destinations)) ->
        {:error, :operational_destination_not_authorized}

      loop.visibility not in allowed_visibility ->
        {:error, {:operational_visibility_not_authorized, loop.visibility}}

      Enum.uniq(loop.authorized_origins) != loop.authorized_origins ->
        {:error, :duplicate_operational_authorized_origin}

      Enum.uniq(loop.destinations) != loop.destinations ->
        {:error, :duplicate_operational_destination}

      true ->
        :ok
    end
  end

  defp authorize_control(%Definition{security: security}, %Command{mode: :immediate}) do
    if option(security, :allow_immediate_pause, false),
      do: :ok,
      else: {:error, :immediate_loop_interruption_forbidden_by_definition}
  end

  defp authorize_control(_definition, _command), do: :ok

  defp publication_policy(%Definition{artifact_policy: policy}) do
    %{
      publish_results: option(policy, :publish_results, true),
      publish_artifacts: option(policy, :publish_artifacts, true)
    }
  end

  defp artifact_limit(%Definition{artifact_policy: policy}),
    do: option(policy, :max_count, @artifact_limit)

  defp validate_artifacts(definition, loop, artifacts) do
    allowed = option(definition.artifact_policy, :allowed_kinds, [])
    limit = artifact_limit(definition)

    if length(loop.artifacts) + length(artifacts) > limit do
      {:error, {:operation_artifact_limit_exceeded, limit}}
    else
      Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
        with :ok <- validate_artifact(artifact),
             :ok <- validate_artifact_kind(artifact, allowed) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_artifact(%Artifact{} = artifact), do: Artifact.validate(artifact)
  defp validate_artifact(artifact), do: portable(artifact, [:operation, :artifact])

  defp validate_artifact_kind(_artifact, []), do: :ok

  defp validate_artifact_kind(artifact, allowed) do
    kind =
      case artifact do
        %Artifact{kind: value} -> value
        %{kind: value} -> value
        %{"kind" => value} -> value
        _other -> nil
      end

    if kind in allowed,
      do: :ok,
      else: {:error, {:operation_artifact_kind_not_allowed, kind}}
  end

  defp validate_checkpoint(loop, control, definition, env) do
    with :ok <- Loop.validate(loop),
         :ok <- Control.validate(control),
         :ok <- validate_control_consistency(loop, control),
         :ok <- validate_checkpoint_subject(loop, env),
         :ok <-
           Validator.validate(
             definition.input,
             loop.base_input,
             {:loop_base_input, definition.id}
           ),
         :ok <-
           Validator.validate(
             definition.input,
             loop.effective_input,
             {:loop_input, definition.id}
           ),
         :ok <- Validator.validate(definition.state, loop.state, {:loop_state, definition.id}),
         :ok <- validate_loop_security(definition, loop),
         :ok <- validate_restored_artifacts(definition, loop),
         {:ok, _registry} <- Registry.all(Map.fetch!(env, :agent), definition),
         :ok <- validate_restored_request(loop, definition, env),
         :ok <- validate_restored_attempt(loop, definition, env) do
      validate_restored_wait(loop, definition)
    end
  end

  defp validate_control_consistency(loop, control) do
    cond do
      control.loop_id != loop.id ->
        {:error, :operation_control_loop_mismatch}

      Loop.terminal?(loop) and control.state != :terminal ->
        {:error, :terminal_loop_without_terminal_control}

      not Loop.terminal?(loop) and control.state == :terminal ->
        {:error, :nonterminal_loop_with_terminal_control}

      loop.status == :paused and control.state != :paused ->
        {:error, :paused_loop_without_paused_control}

      control.state == :paused and loop.status != :paused ->
        {:error, :paused_control_without_paused_loop}

      loop.status == :pause_requested and control.state != :pause_requested ->
        {:error, :pause_requested_loop_without_matching_control}

      control.state == :pause_requested and loop.status != :pause_requested ->
        {:error, :pause_requested_control_without_matching_loop}

      is_nil(control.pending) and loop.status == :pause_requested ->
        {:error, :pause_requested_loop_without_pending_command}

      match?(%Command{status: status} when status != :committed, control.pending) ->
        {:error, :invalid_pending_control_command_status}

      true ->
        :ok
    end
  end

  defp validate_checkpoint_subject(loop, env) do
    case Map.fetch(env, :subject_id) do
      {:ok, subject_id} when subject_id == loop.subject_id -> :ok
      {:ok, _other} -> {:error, :operational_loop_subject_mismatch}
      :error -> {:error, :operational_checkpoint_subject_missing}
    end
  end

  defp validate_restored_artifacts(definition, loop) do
    empty = %{loop | artifacts: []}
    validate_artifacts(definition, empty, loop.artifacts)
  end

  defp validate_restored_request(%Loop{next_operation: nil}, _definition, _env), do: :ok

  defp validate_restored_request(
         %Loop{next_operation: %Request{} = request} = loop,
         definition,
         env
       ) do
    with :ok <- validate_branch(definition, request),
         {:ok, spec} <- Registry.resolve(Map.fetch!(env, :agent), definition, request.operation) do
      validate_request_input(spec, request, reconciliation_request?(loop, request))
    end
  end

  defp validate_restored_attempt(%Loop{attempt: nil}, _definition, _env), do: :ok

  defp validate_restored_attempt(%Loop{attempt: %Attempt{} = attempt}, definition, env) do
    with {:ok, spec} <- Registry.resolve(Map.fetch!(env, :agent), definition, attempt.operation),
         true <- attempt.side_effect == spec.side_effect,
         true <- attempt.timeout == spec.timeout do
      :ok
    else
      false -> {:error, {:incompatible_operation_attempt, attempt.operation}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_restored_wait(%Loop{wait: nil}, _definition), do: :ok

  defp validate_restored_wait(%Loop{wait: %Wait{kind: :retry}}, _definition), do: :ok
  defp validate_restored_wait(%Loop{wait: %Wait{kind: :reconciliation}}, _definition), do: :ok

  defp validate_restored_wait(%Loop{wait: %Wait{kind: :human}, blocker: blocker}, definition) do
    validate_blocker(definition, blocker)
  end

  defp validate_restored_wait(%Loop{wait: %Wait{} = wait}, definition),
    do: validate_wait(definition, wait)

  defp refresh_definition_policy(loop, definition, env) do
    metadata = Map.put(loop.metadata, :publication, publication_policy(definition))

    refreshed = %{
      loop
      | controller_version: definition.version,
        metadata: metadata
    }

    if refreshed == loop do
      loop
    else
      touched = Loop.touch(refreshed, at: now(env))

      case touched.outcome do
        %Outcome{} = outcome -> %{touched | outcome: %{outcome | last_revision: touched.revision}}
        nil -> touched
      end
    end
  end

  defp callback(module, function, args) do
    arity = length(args)

    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:controller_not_loaded, module}}

      not function_exported?(module, function, arity) ->
        {:error, {:controller_callback_missing, module, function, arity}}

      true ->
        {:ok, apply(module, function, args)}
    end
  rescue
    error -> {:error, {:controller_callback_exception, module, function, error.__struct__}}
  catch
    kind, reason -> {:error, {:controller_callback_failure, module, function, kind, reason}}
  end

  defp controller_context(nil, env) do
    %{
      agent: Map.get(env, :agent),
      subject_id: Map.get(env, :subject_id),
      canonical_revision: Map.get(env, :canonical_revision, 0),
      committed: Map.get(env, :committed, %{}),
      now: now(env)
    }
  end

  defp controller_context(loop, env) do
    %{
      agent: Map.get(env, :agent),
      subject_id: loop.subject_id,
      loop_id: loop.id,
      loop_kind: loop.kind,
      input: loop.effective_input,
      base_input: loop.base_input,
      context_revision: loop.context_revision,
      loop_revision: loop.revision,
      phase: loop.phase,
      budget: loop.budget,
      cognitive: loop.cognitive,
      artifacts: loop.artifacts,
      results: loop.results,
      last_result: loop.last_result,
      committed: Map.get(env, :committed, %{}),
      trigger: Map.get(env, :trigger),
      now: now(env)
    }
  end

  defp complete(loop, value, env) do
    outcome =
      Outcome.new(:completed,
        result: value,
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1
      )

    loop
    |> clear_attempt()
    |> clear_reconciliation_marker()
    |> Map.put(:status, :terminal)
    |> Map.put(:outcome, outcome)
    |> Map.put(:wait, nil)
    |> Map.put(:blocker, nil)
    |> Loop.touch(at: now(env))
  end

  defp fail(loop, reason, env) do
    outcome =
      Outcome.new(:failed,
        reason: reason,
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1
      )

    loop
    |> clear_attempt()
    |> clear_reconciliation_marker()
    |> Map.put(:status, :terminal)
    |> Map.put(:outcome, outcome)
    |> Map.put(:last_error, reason)
    |> Loop.touch(at: now(env))
  end

  defp terminal_budget(loop, dimension, consumed, limit, env) do
    category = if consumed == :expired, do: :expired, else: :budget_exhausted
    exhaustion = budget_event(dimension, consumed, limit)
    {reason, metadata} = budget_outcome_behavior(loop, category, exhaustion, env)

    outcome =
      Outcome.new(category,
        reason: reason,
        limit: %{dimension: dimension, value: limit},
        consumed: %{dimension: dimension, value: consumed},
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1,
        metadata: metadata
      )

    loop
    |> clear_attempt()
    |> clear_reconciliation_marker()
    |> Map.put(:status, :terminal)
    |> Map.put(:outcome, outcome)
    |> Loop.touch(at: now(env))
  end

  defp budget_outcome_behavior(loop, category, exhaustion, env) do
    default = {{category, exhaustion.dimension}, %{behavior: :terminate}}

    case current_definition(loop) do
      {:ok, %Definition{on_budget_exhausted: :terminate}} ->
        default

      {:ok, %Definition{on_budget_exhausted: :controller}} ->
        case callback(loop.controller, :budget_exhausted, [
               loop.state,
               exhaustion,
               controller_context(loop, env)
             ]) do
          {:ok, decision} -> normalize_budget_decision(decision, default)
          {:error, reason} -> budget_behavior_error(default, reason)
        end

      {:error, reason} ->
        budget_behavior_error(default, reason)
    end
  end

  defp normalize_budget_decision(:terminate, default), do: default

  defp normalize_budget_decision({:terminate, reason}, {_default_reason, metadata} = default) do
    case portable(reason, [:loop, :budget_exhausted, :reason]) do
      :ok -> {reason, Map.put(metadata, :behavior, :controller)}
      {:error, invalid} -> budget_behavior_error(default, invalid)
    end
  end

  defp normalize_budget_decision(
         {:terminate, reason, extra_metadata},
         {_default_reason, metadata} = default
       )
       when is_map(extra_metadata) or is_list(extra_metadata) do
    extra_metadata = normalize_map(extra_metadata)

    case portable({reason, extra_metadata}, [:loop, :budget_exhausted]) do
      :ok -> {reason, metadata |> Map.merge(extra_metadata) |> Map.put(:behavior, :controller)}
      {:error, invalid} -> budget_behavior_error(default, invalid)
    end
  end

  defp normalize_budget_decision(invalid, default),
    do: budget_behavior_error(default, {:invalid_budget_exhaustion_decision, invalid})

  defp budget_behavior_error({reason, metadata}, error) do
    {reason, Map.merge(metadata, %{behavior_error: reason_class(error)})}
  end

  defp budget_event(dimension, consumed, limit),
    do: %{dimension: dimension, consumed: consumed, limit: limit}

  defp budget_exhaustion(%Loop{expires_at: expires_at} = loop, env) do
    current_time = now(env)

    if is_integer(expires_at) and expires_at <= current_time,
      do: {:duration_ms, :expired, expires_at},
      else: Budget.exhausted(loop.budget, current_time)
  end

  defp clear_attempt(loop) do
    %{loop | attempt: nil, operation: nil}
  end

  defp put_resume_status(loop, status)
       when status in [:queued, :evaluating, :waiting, :reconciling] do
    put_in(loop, [Access.key!(:metadata), :paused_from_status], status)
  end

  defp put_resume_status(loop, _status), do: put_resume_status(loop, :queued)

  defp resume_status(%Loop{metadata: metadata}) do
    case Map.get(metadata, :paused_from_status, Map.get(metadata, "paused_from_status")) do
      status when status in [:queued, :evaluating, :waiting, :reconciling] -> status
      _unknown -> :queued
    end
  end

  defp clear_resume_status(%Loop{} = loop) do
    metadata =
      loop.metadata |> Map.delete(:paused_from_status) |> Map.delete("paused_from_status")

    %{loop | metadata: metadata}
  end

  defp put_reconciliation_marker(%Loop{} = loop, %Request{} = request, true) do
    %{loop | metadata: Map.put(loop.metadata, :reconciliation_request_id, request.id)}
  end

  defp put_reconciliation_marker(%Loop{} = loop, _request, false),
    do: clear_reconciliation_marker(loop)

  defp clear_reconciliation_marker(%Loop{} = loop) do
    metadata =
      loop.metadata
      |> Map.delete(:reconciliation_request_id)
      |> Map.delete("reconciliation_request_id")
      |> Map.delete(:reconcile?)
      |> Map.delete("reconcile?")

    %{loop | metadata: metadata}
  end

  defp reconciliation_request?(%Loop{} = loop, %Request{} = request) do
    marker =
      Map.get(
        loop.metadata,
        :reconciliation_request_id,
        Map.get(loop.metadata, "reconciliation_request_id")
      )

    marker == request.id
  end

  defp put_wait(loop, wait),
    do: %{loop | status: :waiting, wait: wait, attempt: nil, operation: nil}

  defp maybe_increment_observations(%Loop{kind: :vigil} = loop),
    do: %{loop | observations: loop.observations + 1}

  defp maybe_increment_observations(loop), do: loop

  defp append_results(loop, values) do
    values = Enum.reject(List.wrap(values), &is_nil/1)
    %{loop | results: Enum.take(values ++ loop.results, @result_limit)}
  end

  defp append_artifacts(loop, artifacts, limit) do
    artifacts = Enum.reject(List.wrap(artifacts), &is_nil/1)
    %{loop | artifacts: Enum.take(artifacts ++ loop.artifacts, min(limit, @artifact_limit))}
  end

  defp append_invalidations(loop, invalidations) do
    invalidations =
      invalidations
      |> List.wrap()
      |> Kernel.++(loop.invalidations)
      |> Enum.uniq()
      |> Enum.take(@invalidation_limit)

    %{loop | invalidations: invalidations}
  end

  defp effective_budget(default, nil, now) do
    {:ok, Budget.new(%{limits: default.limits, resources: default.resources}, now)}
  rescue
    exception -> {:error, {:invalid_operational_budget, Exception.message(exception)}}
  end

  defp effective_budget(_default, configured, now) do
    {:ok, Budget.new(configured, now)}
  rescue
    exception -> {:error, {:invalid_operational_budget, Exception.message(exception)}}
  end

  defp authorize_revision(_loop, nil), do: :ok
  defp authorize_revision(%Loop{revision: revision}, revision), do: :ok

  defp authorize_revision(%Loop{revision: current}, supplied),
    do: {:error, {:stale_loop_control_revision, supplied, current}}

  defp authorized_origins(nil, opts), do: List.wrap(Keyword.get(opts, :authorized_origins, []))

  defp authorized_origins(origin, opts),
    do: Enum.uniq([origin | List.wrap(Keyword.get(opts, :authorized_origins, []))])

  defp validate_branch(%Definition{branches: branches}, %Request{branch: nil})
       when map_size(branches) >= 0,
       do: :ok

  defp validate_branch(%Definition{branches: branches}, %Request{} = request) do
    case Map.fetch(branches, request.branch) do
      {:ok, allowed} ->
        if request.operation in allowed,
          do: :ok,
          else: {:error, {:operation_outside_declared_branch, request.branch, request.operation}}

      :error ->
        {:error, {:undeclared_work_branch, request.branch}}
    end
  end

  defp validate_blocker(%Definition{blockers: blockers}, blocker) do
    id = blocker_id(blocker)

    if id in blockers,
      do: :ok,
      else: {:error, {:undeclared_operational_blocker, id}}
  end

  defp blocker_id(%{id: id}), do: id
  defp blocker_id(%{"id" => id}), do: id
  defp blocker_id(%{type: type}), do: type
  defp blocker_id(%{"type" => type}), do: type
  defp blocker_id({id, _payload}), do: id
  defp blocker_id(id) when is_atom(id) or is_binary(id), do: id
  defp blocker_id(_blocker), do: :invalid

  defp validate_wait(%Definition{kind: :vigil, waits: []}, %Wait{} = wait),
    do: {:error, {:undeclared_vigil_trigger, wait.kind}}

  defp validate_wait(%Definition{kind: :vigil, waits: waits}, %Wait{} = wait) do
    if wait.kind in waits,
      do: :ok,
      else: {:error, {:undeclared_vigil_trigger, wait.kind}}
  end

  defp validate_wait(%Definition{waits: waits}, %Wait{} = wait) do
    if wait.kind in waits,
      do: :ok,
      else: {:error, {:undeclared_operational_wait, wait.kind}}
  end

  defp validate_trigger(%Definition{kind: :vigil, triggers: triggers}, trigger) do
    type = trigger_class(trigger)

    if type in triggers,
      do: :ok,
      else: {:error, {:undeclared_vigil_trigger, type}}
  end

  defp validate_trigger(%Definition{triggers: []}, _trigger), do: :ok

  defp validate_trigger(%Definition{triggers: triggers}, trigger) do
    type = trigger_class(trigger)

    if type in triggers,
      do: :ok,
      else: {:error, {:undeclared_operational_trigger, type}}
  end

  defp validate_delivered_trigger(
         _definition,
         %Loop{wait: %Wait{id: wait_id, kind: :retry}},
         {:timer, wait_id},
         wait_id
       ),
       do: :ok

  defp validate_delivered_trigger(definition, _loop, trigger, _expected_wait),
    do: validate_trigger(definition, trigger)

  defp trigger_callback(loop, trigger, env) do
    context = controller_context(loop, Map.put(env, :trigger, trigger))

    if function_exported?(loop.controller, :handle_trigger, 3) do
      callback(loop.controller, :handle_trigger, [loop.state, trigger, context])
    else
      {:ok, {:ok, loop.state}}
    end
  end

  defp validate_updated_fields(before, updated, %Definition{update_fields: fields}) do
    cond do
      before == updated ->
        :ok

      :all in fields ->
        :ok

      is_map(before) and is_map(updated) ->
        changed =
          (Map.keys(before) ++ Map.keys(updated))
          |> Enum.uniq()
          |> Enum.filter(&(Map.get(before, &1) != Map.get(updated, &1)))

        case Enum.reject(changed, &(&1 in fields)) do
          [] -> :ok
          rejected -> {:error, {:work_update_fields_not_declared, rejected}}
        end

      true ->
        {:error, :work_update_replacement_not_declared}
    end
  end

  defp validate_cognitive_update(value) when is_map(value), do: :ok
  defp validate_cognitive_update(value), do: {:error, {:invalid_cognitive_constraints, value}}

  defp normalize_significance(:vigil, value) when value in [:significant, true],
    do: :significant

  defp normalize_significance(:vigil, value) when value in [:silent, false, nil], do: :silent
  defp normalize_significance(:vigil, _value), do: :silent
  defp normalize_significance(_kind, _value), do: nil

  defp validate_significance(:vigil, value)
       when value in [:significant, :silent, true, false, nil],
       do: :ok

  defp validate_significance(:vigil, value),
    do: {:error, {:invalid_vigil_significance, value}}

  defp validate_significance(_kind, _value), do: :ok

  defp validate_cost(usage, fallback) do
    cost = Map.get(usage, :cost, Map.get(usage, "cost", fallback))

    if is_nil(cost) or (is_number(cost) and cost >= 0),
      do: :ok,
      else: {:error, {:invalid_operation_cost, cost}}
  end

  defp observation_event(:vigil, :significant, result),
    do: event(:observation_significant, %{attempt_id: result.attempt_id})

  defp observation_event(:vigil, :silent, result),
    do: event(:observation_committed, %{attempt_id: result.attempt_id, significance: :silent})

  defp observation_event(_kind, _significance, _result), do: nil

  defp put_significance(loop, :significant, result, env) do
    metadata =
      Map.put(loop.metadata, :last_significant_change, %{
        at: now(env),
        result_id: result.id,
        revision: loop.revision + 1
      })

    %{loop | metadata: metadata}
  end

  defp put_significance(loop, _significance, _result, _env), do: loop

  defp put_cognitive_result(loop, %Result{} = result) do
    fallback? = Map.get(result.metadata, :cognitive_fallback, false)

    selection =
      case result.value do
        %{selection: selection} -> selection
        _other -> nil
      end

    cognitive =
      loop.cognitive
      |> Map.put(:fallback?, fallback?)
      |> maybe_put_map(:effective_selection, selection)

    %{loop | cognitive: cognitive}
  end

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp origin_provenance(nil), do: %{}
  defp origin_provenance(origin), do: %{origin: origin}

  defp trigger_generation_increment(:vigil), do: 1
  defp trigger_generation_increment(_kind), do: 0

  defp trigger_class(%{type: type}) when is_atom(type), do: type
  defp trigger_class({type, _value}) when is_atom(type), do: type
  defp trigger_class(type) when is_atom(type), do: type
  defp trigger_class(_trigger), do: :external

  defp attempt_event(attempt) do
    %{
      attempt_id: attempt.id,
      operation: attempt.operation,
      number: attempt.number,
      context_revision: attempt.context_revision
    }
  end

  defp event(type, payload \\ %{}), do: %{type: type, payload: payload}

  defp option(opts, key, default \\ nil) when is_map(opts),
    do: Map.get(opts, key, default)

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value), do: Map.new(value), else: %{}
  end

  defp map_option(value, _field) when is_map(value), do: {:ok, value}

  defp map_option(value, field) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, Map.new(value)},
      else: {:error, {:invalid_operational_map_option, field}}
  end

  defp map_option(_value, field), do: {:error, {:invalid_operational_map_option, field}}

  defp portable(value, path) do
    case Value.validate(value, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operational_value, reason}}
    end
  end

  defp reason_class(%{kind: kind}) when is_atom(kind), do: kind
  defp reason_class({kind, _detail}) when is_atom(kind), do: kind
  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class(_reason), do: :error

  defp now(env), do: Map.get(env, :now, System.system_time(:millisecond))
end
