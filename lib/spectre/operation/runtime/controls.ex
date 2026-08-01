defmodule Spectre.Operation.Runtime.Controls do
  @moduledoc """
  Control-plane command handling for the operation runtime.

  Commits durable control requests, advances pending pause/update/resume/stop
  sequences at quiescent boundaries, applies validated updates through the
  controller and rejects commands that can no longer be honored. Trigger
  commands re-enter `Spectre.Operation.Runtime.trigger/5`.
  """

  import Spectre.Operation.Runtime.Support
  import Spectre.Operation.Runtime.Transitions

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Outcome
  alias Spectre.Operation.Request
  alias Spectre.Operation.Runtime
  alias Spectre.Operation.Runtime.Contract
  alias Spectre.Operation.Update
  alias Spectre.Operation.Validator
  alias Spectre.Operation.Wait

  @type pid_action :: :keep_runner | {:terminate_runner, String.t()}

  @doc "Commits a durable control request without executing it reentrantly."
  @spec request(Loop.t(), Control.t(), Command.t(), map()) ::
          {:ok, Loop.t(), Control.t(), pid_action(), [map()]}
          | {:duplicate, Loop.t(), Control.t()}
          | {:error, term()}
  def request(%Loop{} = loop, %Control{} = control, %Command{} = command, env) do
    with :ok <- Command.validate(command),
         :ok <- Contract.authorize_revision(loop, command.base_revision),
         {:ok, definition} <- Contract.current_definition(loop),
         :ok <- Contract.authorize_control(definition, command),
         {:ok, requested} <- normalize_control_request(Control.request(control, command)) do
      apply_control_request(loop, requested, env)
    else
      {:duplicate, duplicate} -> {:duplicate, loop, duplicate}
      {:error, _reason} = error -> error
    end
  end

  @doc "Advances a pending pause/update/resume sequence once the loop is quiescent."
  @spec advance(Loop.t(), Control.t(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]} | {:error, term()}
  def advance(
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

  def advance(%Loop{} = loop, %Control{}, _env),
    do: {:error, {:loop_not_quiescent_for_control, loop.id}}

  @doc "Rejects a control command, pausing after rejected updates."
  @spec reject(Loop.t(), Control.t(), Command.t(), term(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]}
  def reject(loop, control, command, reason, env) do
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
      |> Map.update!(:updates, &Enum.take([update | &1], update_limit()))
      |> Loop.touch(at: now(env))

    {:ok, next, control, [event(:control_rejected, %{action: command.action, reason: reason})]}
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
        case advance(loop, control, env) do
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
      reject(loop, control, command, {:loop_not_paused, loop.status}, env)
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
        reject(loop, control, command, :invalid_renewal, env)
    end
  end

  defp finish_trigger_command(loop, control, command, env) do
    trigger_opts = [
      wait_id: option(command.metadata, :wait_id),
      generation: option(command.metadata, :generation)
    ]

    case Runtime.trigger(loop, control, command.payload, trigger_opts, env) do
      {:ok, next, _trigger_control, events} ->
        next_control = Control.finish(control, Command.applied(command))
        {:ok, next, next_control, events}

      {:error, reason} ->
        reject(loop, control, command, reason, env)
    end
  end

  defp apply_update(loop, control, command, env) do
    definition_result = Contract.current_definition(loop)

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
         :ok <- Contract.validate_updated_fields(loop.effective_input, effective_input, definition),
         :ok <- Contract.validate_cognitive_update(option(opts, :cognitive, loop.cognitive)),
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
        |> Map.update!(:updates, &Enum.take([applied | &1], update_limit()))
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
      false -> reject(loop, control, command, :loop_updates_not_supported, env)
      {:error, reason} -> reject(loop, control, command, reason, env)
    end
  end

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

  defp normalize_control_request({:ok, control}), do: {:ok, control}
  defp normalize_control_request({:duplicate, control}), do: {:duplicate, control}
  defp normalize_control_request({:error, _reason} = error), do: error
end
