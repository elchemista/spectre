defmodule Spectre.Operation.Runtime.Recovery do
  @moduledoc """
  Restart recovery and checkpoint validation for the operation runtime.

  Validates a restored loop and its control plane against the current
  code-owned definition, refreshes definition-owned policy metadata, and
  reduces an interrupted attempt by its declared side-effect class before
  advancing or rejecting any pending control command.
  """

  import Spectre.Operation.Runtime.Support
  import Spectre.Operation.Runtime.Transitions

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Outcome
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Operation.Runtime.Contract
  alias Spectre.Operation.Runtime.Controls
  alias Spectre.Operation.Runtime.Results
  alias Spectre.Operation.Validator
  alias Spectre.Operation.Wait

  @doc "Recovers portable loop state after an Agent restart and invalidates the old epoch."
  @spec recover(Loop.t(), Control.t(), map()) ::
          {:ok, Loop.t(), Control.t(), [map()]} | {:error, term()}
  def recover(%Loop{} = loop, %Control{} = control, env) do
    with {:ok, definition} <- Contract.current_definition(loop),
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

  @doc "Validates a restored loop and control plane against a loaded definition."
  @spec validate_checkpoint(Loop.t(), Control.t(), Spectre.Operation.Definition.t(), map()) ::
          :ok | {:error, term()}
  def validate_checkpoint(loop, control, definition, env) do
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
         :ok <- Contract.validate_loop_security(definition, loop),
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

      loop.status == :paused and control.state not in [:paused, :pause_requested] ->
        {:error, :paused_loop_without_paused_control}

      control.state == :paused and loop.status != :paused ->
        {:error, :paused_control_without_paused_loop}

      loop.status == :pause_requested and control.state != :pause_requested ->
        {:error, :pause_requested_loop_without_matching_control}

      # A safe pause/update stays pending while the active attempt's Result,
      # retry or reconciliation transition commits first; those intermediate
      # statuses are legitimately checkpointed and the pending command is
      # advanced on the next scheduled transition after restore.
      control.state == :pause_requested and
          loop.status not in [:pause_requested, :paused, :evaluating, :waiting, :reconciling] ->
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
    Contract.validate_artifacts(definition, empty, loop.artifacts)
  end

  defp validate_restored_request(%Loop{next_operation: nil}, _definition, _env), do: :ok

  defp validate_restored_request(
         %Loop{next_operation: %Request{} = request} = loop,
         definition,
         env
       ) do
    with :ok <- Contract.validate_branch(definition, request),
         {:ok, spec} <- Registry.resolve(Map.fetch!(env, :agent), definition, request.operation) do
      Contract.validate_request_input(spec, request, reconciliation_request?(loop, request))
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
    Contract.validate_blocker(definition, blocker)
  end

  defp validate_restored_wait(%Loop{wait: %Wait{} = wait}, definition),
    do: Contract.validate_wait(definition, wait)

  defp refresh_definition_policy(loop, definition, env) do
    metadata = Contract.policy_metadata(loop.metadata, definition)

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
        Results.reconcile_transition(loop, control, spec, :agent_restarted, env)

      :non_idempotent ->
        Results.ambiguous_wait(loop, control, :agent_restarted, env)
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
          Controls.advance(loop, control, env)

        command.action == :pause ->
          Controls.advance(loop, control, env)

        command.action in [:update, :update_and_resume] ->
          Controls.reject(
            loop,
            control,
            command,
            {:side_effect_outcome_unknown_during_recovery, spec.id},
            env
          )

        true ->
          Controls.advance(loop, control, env)
      end

    case transition do
      {:ok, next, next_control, control_events} ->
        {:ok, next, next_control, recovery_events ++ control_events}

      {:error, _reason} = error ->
        error
    end
  end
end
