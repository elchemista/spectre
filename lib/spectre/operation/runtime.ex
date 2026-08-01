defmodule Spectre.Operation.Runtime do
  @moduledoc """
  Pure transition engine for Work, Vigil and external operational controllers.

  Slow execution is deliberately absent from this module. It prepares fenced
  attempts and reduces their results; `Spectre.Instance` owns serialization,
  canonical commit, supervision and scheduling.

  The engine is split by concern: `Runtime.Contract` enforces the code-owned
  definition, `Runtime.Transitions` builds loop-state transitions,
  `Runtime.Results` reduces Runner results, `Runtime.Controls` handles the
  control plane and `Runtime.Recovery` validates restored checkpoints. This
  module keeps loop start, attempt preparation, trigger delivery and the
  public entry points.
  """

  import Spectre.Operation.Runtime.Support
  import Spectre.Operation.Runtime.Transitions

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Monitor
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime.Contract
  alias Spectre.Operation.Runtime.Controls
  alias Spectre.Operation.Runtime.Recovery
  alias Spectre.Operation.Runtime.Results
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator
  alias Spectre.Operation.Wait
  alias Spectre.Run.Value

  @type event_spec :: %{required(:type) => atom(), optional(:payload) => term()}
  @type env :: map()
  @type pid_action :: Controls.pid_action()

  @spec start(Loop.kind(), module(), term(), keyword(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def start(kind, controller, input, opts, env)
      when kind in [:work, :vigil, :directive] and is_atom(controller) and is_list(opts) and
             is_map(env) do
    with {:ok, definition} <- Definition.load(controller),
         :ok <- Contract.ensure_kind(definition, kind),
         :ok <- Contract.validate_controller_contract(definition, controller),
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
          metadata: Contract.policy_metadata(metadata, definition)
        }

        with :ok <- Contract.validate_loop_security(definition, loop),
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
             {:ok, definition} <- Contract.current_definition(loop),
             {:ok, request, reconcile?} <- next_request(loop, definition, env),
             {:ok, spec} <-
               Registry.resolve(Map.fetch!(env, :agent), definition, request.operation),
             :ok <- Contract.validate_request_input(spec, request, reconcile?),
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
            {terminal, rejected} = terminal_control(control)

            {:transition, exhausted, terminal,
             [event(:budget_exhausted, budget_event(dimension, consumed, limit)) | rejected]}

          {:wait, %Wait{} = wait} ->
            next = loop |> put_wait(wait) |> Loop.touch(at: now(env))
            {:transition, next, control, [event(:waiting, wait_event(wait, loop))]}

          {:blocked, blocker} ->
            wait = Wait.new(:human, reason: blocker, payload: blocker)

            next =
              loop
              |> Map.put(:blocker, blocker)
              |> put_wait(wait)
              |> Loop.touch(at: now(env))

            {:transition, next, control, [event(:blocked, wait_event(wait, loop))]}

          {:complete, value} ->
            next = complete(loop, value, env)
            {terminal, rejected} = terminal_control(control)
            {:transition, next, terminal, [event(:completed) | rejected]}

          {:error, reason} ->
            next = fail(loop, reason, env)
            {terminal, rejected} = terminal_control(control)

            {:transition, next, terminal, [event(:failed, %{reason: reason}) | rejected]}
        end
    end
  end

  @doc "Applies one correlated Runner result and leaves completion evaluation for the next commit."
  @spec apply_result(Loop.t(), Control.t(), Result.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:duplicate, Loop.t()} | {:error, term()}
  def apply_result(%Loop{} = loop, %Control{} = control, %Result{} = result, env) do
    case apply_result_with_start_loops(loop, control, result, env) do
      {:ok, next_loop, next_control, events, []} ->
        {:ok, next_loop, next_control, events}

      {:ok, _next_loop, _next_control, _events, _start_loops} ->
        {:error, :operation_start_loops_require_agent_commit}

      other ->
        other
    end
  end

  @doc false
  @spec apply_result_with_start_loops(Loop.t(), Control.t(), Result.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()], [map()]}
          | {:duplicate, Loop.t()}
          | {:error, term()}
  def apply_result_with_start_loops(
        %Loop{} = loop,
        %Control{} = control,
        %Result{} = result,
        env
      ) do
    Results.apply(loop, control, result, env)
  end

  @doc "Evaluates deterministic completion only after the result transition was committed."
  @spec evaluate(Loop.t(), Control.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def evaluate(%Loop{} = loop, %Control{} = control, env),
    do: Results.evaluate(loop, control, env)

  @doc "Commits a durable control request without executing it reentrantly."
  @spec request_control(Loop.t(), Control.t(), Command.t(), env()) ::
          {:ok, Loop.t(), Control.t(), pid_action(), [event_spec()]}
          | {:duplicate, Loop.t(), Control.t()}
          | {:error, term()}
  def request_control(%Loop{} = loop, %Control{} = control, %Command{} = command, env),
    do: Controls.request(loop, control, command, env)

  @doc "Advances a pending pause/update/resume sequence once the loop is quiescent."
  @spec advance_control(Loop.t(), Control.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def advance_control(%Loop{} = loop, %Control{} = control, env),
    do: Controls.advance(loop, control, env)

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
        with {:ok, definition} <- Contract.current_definition(loop),
             {:ok, correlation_mode} <-
               Contract.validate_trigger_correlation(
                 definition,
                 loop.wait,
                 expected_wait,
                 expected_generation
               ),
             :ok <- Contract.validate_delivered_trigger(definition, loop, trigger, expected_wait),
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

          {:ok, next, control,
           [
             event(:triggered, %{
               trigger: trigger_class(trigger),
               wait_id: loop.wait.id,
               generation: loop.trigger_generation,
               correlation: correlation_mode
             })
           ]}
        end
    end
  end

  @doc "Recovers portable loop state after an Agent restart and invalidates the old epoch."
  @spec recover(Loop.t(), Control.t(), env()) ::
          {:ok, Loop.t(), Control.t(), [event_spec()]} | {:error, term()}
  def recover(%Loop{} = loop, %Control{} = control, env),
    do: Recovery.recover(loop, control, env)

  @doc "Validates a restored loop and its control plane against the current code-owned definition."
  @spec validate_checkpoint(Loop.t(), Control.t(), env()) :: :ok | {:error, term()}
  def validate_checkpoint(%Loop{} = loop, %Control{} = control, env) when is_map(env) do
    with {:ok, definition} <- Contract.current_definition(loop) do
      Recovery.validate_checkpoint(loop, control, definition, env)
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
        Results.retry_transition(loop, control, spec, {:runner_crashed, reason}, delay, env)

      {:reconcile, ambiguity} ->
        Results.reconcile_transition(loop, control, spec, ambiguity, env)

      {:fail, {:side_effect_outcome_unknown, _operation, _reason} = ambiguity} ->
        Results.ambiguous_wait(loop, control, ambiguity, env)

      {:fail, failure} ->
        terminal = fail(clear_attempt(loop), failure, env)
        {terminal_ctrl, rejected} = terminal_control(control)
        {:ok, terminal, terminal_ctrl, [event(:attempt_crashed), event(:failed) | rejected]}
    end
  end

  def runner_down(%Loop{} = loop, _control, _spec, _reason, _env),
    do: {:error, {:loop_has_no_active_attempt, loop.id}}

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
    case Contract.validate_branch(definition, request) do
      :ok -> {:ok, request, reconcile?}
      {:error, _reason} = error -> error
    end
  end

  defp validate_next({:blocked, blocker}, definition) do
    case Contract.validate_blocker(definition, blocker) do
      :ok -> {:blocked, blocker}
      {:error, _reason} = error -> error
    end
  end

  defp validate_next({:wait, %Wait{} = wait}, definition) do
    case Contract.validate_wait(definition, wait) do
      :ok -> {:wait, wait}
      {:error, _reason} = error -> error
    end
  end

  defp validate_next(other, _definition), do: other

  defp normalize_trigger({:ok, state}), do: {:ok, state, %{}}
  defp normalize_trigger({:ok, state, opts}) when is_map(opts), do: {:ok, state, opts}

  defp normalize_trigger({:ok, state, opts}) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, state, Map.new(opts)},
      else: {:error, {:invalid_controller_trigger_options, opts}}
  end

  defp normalize_trigger({:error, reason}), do: {:error, reason}
  defp normalize_trigger(other), do: {:error, {:invalid_controller_trigger, other}}

  defp trigger_callback(loop, trigger, env) do
    context = controller_context(loop, Map.put(env, :trigger, trigger))

    if function_exported?(loop.controller, :handle_trigger, 3) do
      callback(loop.controller, :handle_trigger, [loop.state, trigger, context])
    else
      {:ok, {:ok, loop.state}}
    end
  end

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
end
