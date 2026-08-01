defmodule Spectre.Operation.Control do
  @moduledoc "Portable control plane for pause, update, resume and terminal stop."

  alias Spectre.Operation.Control.Command

  @states [:active, :pause_requested, :paused, :stopping, :terminal]
  @history_limit 128

  @enforce_keys [:loop_id]
  defstruct [
    :loop_id,
    :pending,
    :last_command,
    state: :active,
    generation: 0,
    history: [],
    desired_state: :active,
    pause_mode: :safe,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          loop_id: String.t(),
          state: :active | :pause_requested | :paused | :stopping | :terminal,
          generation: non_neg_integer(),
          pending: Command.t() | nil,
          last_command: Command.t() | nil,
          history: [Command.t()],
          desired_state: :active | :paused | :terminal,
          pause_mode: :safe | :immediate,
          updated_at: non_neg_integer() | nil
        }

  @doc """
  Creates the control plane for one loop, starting in `:active` state.
  """
  @spec new(String.t()) :: t()
  def new(loop_id) when is_binary(loop_id) and loop_id != "", do: %__MODULE__{loop_id: loop_id}

  @doc """
  Commits a control command as the single pending command.

  Replays of an already seen command id return `{:duplicate, control}`;
  a terminal control plane, a target mismatch or an already pending command
  return `{:error, reason}`. Pause-like commands move the state to
  `:pause_requested`.
  """
  @spec request(t(), Command.t()) :: {:ok, t()} | {:duplicate, t()} | {:error, term()}
  def request(%__MODULE__{} = control, %Command{loop_id: loop_id} = command) do
    cond do
      loop_id != control.loop_id ->
        {:error, :loop_control_target_mismatch}

      terminal?(control) ->
        {:error, :loop_terminal}

      command_seen?(control, command.id) ->
        {:duplicate, control}

      not is_nil(control.pending) ->
        {:error, {:loop_control_pending, control.pending.id}}

      true ->
        command = Command.committed(command)

        state =
          if command.action in [:pause, :update, :update_and_resume],
            do: :pause_requested,
            else: control.state

        {:ok,
         %{
           control
           | pending: command,
             state: state,
             desired_state: command.desired_state || control.desired_state,
             pause_mode: command.mode,
             updated_at: System.system_time(:millisecond)
         }}
    end
  end

  @doc """
  Records a command as finished, clearing the pending slot.

  The finished command becomes `last_command` and the head of the bounded
  history; the control state follows the command's `desired_state`.
  """
  @spec finish(t(), Command.t()) :: t()
  def finish(%__MODULE__{} = control, %Command{} = command) do
    state =
      case command.desired_state do
        :active -> :active
        :paused -> :paused
        :terminal -> :terminal
        nil -> control.state
      end

    %{
      control
      | pending: nil,
        last_command: command,
        history: Enum.take([command | control.history], @history_limit),
        state: state,
        desired_state: command.desired_state || control.desired_state,
        updated_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Forces the control plane terminal, rejecting any still-pending command.

  A loop can reach a terminal outcome while a safe pause or update command is
  still pending; the command can no longer be applied, so it is finished as
  rejected before the terminal state is committed.
  """
  @spec terminalize(t(), term()) :: t()
  def terminalize(%__MODULE__{} = control, reason \\ :loop_terminal) do
    control =
      case control.pending do
        nil -> control
        %Command{} = pending -> finish(control, Command.rejected(pending, reason))
      end

    %{
      control
      | state: :terminal,
        desired_state: :terminal,
        updated_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Increments the fencing generation, invalidating attempts fenced on the
  previous value.
  """
  @spec bump_generation(t()) :: t()
  def bump_generation(%__MODULE__{} = control),
    do: %{
      control
      | generation: control.generation + 1,
        updated_at: System.system_time(:millisecond)
    }

  @doc """
  Returns `true` when the control plane has reached its terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state == :terminal

  @doc """
  Returns `true` when a command id is pending, last applied, or in history —
  the idempotency check behind `{:duplicate, control}` replies.
  """
  @spec command_seen?(t(), String.t()) :: boolean()
  def command_seen?(%__MODULE__{} = control, id) do
    match?(%Command{id: ^id}, control.pending) or
      match?(%Command{id: ^id}, control.last_command) or
      Enum.any?(control.history, &(&1.id == id))
  end

  @doc """
  Validates the whole control plane: scalar fields, embedded commands,
  history identity and state/pending consistency.

  Returns `:ok` or `{:error, reason}` naming the first violated invariant.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = control) do
    cond do
      not (is_binary(control.loop_id) and control.loop_id != "") ->
        {:error, :invalid_operation_control_loop_id}

      control.state not in @states ->
        {:error, :invalid_operation_control_state}

      not (is_integer(control.generation) and control.generation >= 0) ->
        {:error, :invalid_operation_control_generation}

      not is_list(control.history) ->
        {:error, :invalid_operation_control_history}

      length(control.history) > @history_limit ->
        {:error, :operation_control_history_too_large}

      control.desired_state not in [:active, :paused, :terminal] ->
        {:error, :invalid_operation_control_desired_state}

      control.pause_mode not in [:safe, :immediate] ->
        {:error, :invalid_operation_control_pause_mode}

      not is_nil(control.updated_at) and
          (not is_integer(control.updated_at) or control.updated_at < 0) ->
        {:error, :invalid_operation_control_updated_at}

      true ->
        validate_commands(control)
    end
  end

  @spec validate_commands(t()) :: :ok | {:error, term()}
  defp validate_commands(control) do
    with :ok <- validate_command(control.pending, control.loop_id, [:committed], :pending),
         :ok <-
           validate_command(control.last_command, control.loop_id, [:applied, :rejected], :last),
         :ok <- validate_history(control.history, control.loop_id),
         :ok <- validate_command_identity(control) do
      validate_control_state(control)
    end
  end

  @spec validate_command(term(), String.t(), [atom()], atom()) :: :ok | {:error, term()}
  defp validate_command(nil, _loop_id, _statuses, _field), do: :ok

  defp validate_command(%Command{loop_id: loop_id} = command, loop_id, statuses, field) do
    with :ok <- Command.validate(command),
         true <- command.status in statuses do
      :ok
    else
      false -> {:error, {:invalid_operation_control_command_status, field, command.status}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_command(%Command{}, _loop_id, _statuses, _field),
    do: {:error, :operation_control_command_target_mismatch}

  defp validate_command(_invalid, _loop_id, _statuses, _field),
    do: {:error, :invalid_operation_control_command}

  @spec validate_history([Command.t()], String.t()) :: :ok | {:error, term()}
  defp validate_history(history, loop_id) do
    Enum.reduce_while(history, :ok, fn command, :ok ->
      case validate_command(command, loop_id, [:applied, :rejected], :history) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_command_identity(t()) :: :ok | {:error, term()}
  defp validate_command_identity(control) do
    history_ids = Enum.map(control.history, & &1.id)

    cond do
      Enum.uniq(history_ids) != history_ids ->
        {:error, :duplicate_operation_control_command}

      is_nil(control.last_command) and control.history != [] ->
        {:error, :operation_control_last_command_missing}

      not is_nil(control.last_command) and
          (control.history == [] or hd(control.history) != control.last_command) ->
        {:error, :operation_control_last_command_mismatch}

      not is_nil(control.pending) and control.pending.id in history_ids ->
        {:error, :pending_operation_control_command_already_finished}

      true ->
        :ok
    end
  end

  @spec validate_control_state(t()) :: :ok | {:error, term()}
  defp validate_control_state(control) do
    cond do
      control.state == :terminal and not is_nil(control.pending) ->
        {:error, :terminal_operation_control_with_pending_command}

      control.state in [:pause_requested, :stopping] and is_nil(control.pending) ->
        {:error, :transitional_operation_control_without_pending_command}

      true ->
        :ok
    end
  end
end
