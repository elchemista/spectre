defmodule Spectre.Operation.Control.Command do
  @moduledoc "Durable, idempotent command shared by operation and inference control lanes."

  alias Spectre.Run.Value

  @operational_actions [
    :pause,
    :update,
    :resume,
    :stop,
    :renew,
    :trigger,
    :update_and_resume
  ]
  @inference_actions [:steer, :cancel]
  @actions @operational_actions ++ @inference_actions
  @modes [:safe, :immediate]

  @enforce_keys [:id, :loop_id, :action, :correlation_id, :provenance, :requested_at]
  defstruct [
    :id,
    :loop_id,
    :action,
    :payload,
    :mode,
    :desired_state,
    :correlation_id,
    :causation_id,
    :provenance,
    :base_revision,
    :requested_at,
    :committed_at,
    :completed_at,
    :rejection,
    status: :pending,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          loop_id: String.t(),
          action: atom(),
          payload: term(),
          mode: :safe | :immediate,
          desired_state: :active | :paused | :terminal | nil,
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          provenance: map(),
          base_revision: non_neg_integer() | nil,
          requested_at: non_neg_integer(),
          committed_at: non_neg_integer() | nil,
          completed_at: non_neg_integer() | nil,
          rejection: term(),
          status: :pending | :committed | :applied | :rejected,
          metadata: map()
        }

  @doc """
  Builds a pending control command for `loop_id`.

  Operational loops accept `:pause`, `:update`, `:resume`, `:stop`, `:renew`,
  `:trigger` and `:update_and_resume`. Inference control accepts `:steer` and
  `:cancel`. Each runtime rejects commands from the other domain. The desired
  state is derived from the action unless `:desired_state` is given. Missing
  ids and `requested_at` default to fresh UUIDv7s and the current time. Raises
  `ArgumentError` on an invalid mode.
  """
  @spec new(String.t(), atom(), keyword()) :: t()
  def new(loop_id, action, opts \\ [])
      when is_binary(loop_id) and loop_id != "" and action in @actions and is_list(opts) do
    mode = Keyword.get(opts, :mode, :safe)
    unless mode in @modes, do: raise(ArgumentError, "invalid loop control mode")

    %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      loop_id: loop_id,
      action: action,
      payload: Keyword.get(opts, :payload),
      mode: mode,
      desired_state: Keyword.get(opts, :desired_state) || desired_state(action),
      correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
      causation_id: Keyword.get(opts, :causation_id),
      provenance: Keyword.get(opts, :provenance, %{}),
      base_revision: Keyword.get(opts, :base_revision),
      requested_at: Keyword.get(opts, :requested_at, System.system_time(:millisecond)),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc false
  @spec operational_action?(term()) :: boolean()
  def operational_action?(action), do: action in @operational_actions

  @doc false
  @spec inference_action?(term()) :: boolean()
  def inference_action?(action), do: action in @inference_actions

  @doc """
  Marks the command as `:committed`, stamping `committed_at` with the current time.
  """
  @spec committed(t()) :: t()
  def committed(%__MODULE__{} = command) do
    %{command | status: :committed, committed_at: System.system_time(:millisecond)}
  end

  @doc """
  Marks the command as `:applied`, stamping `completed_at` with the current time.
  """
  @spec applied(t()) :: t()
  def applied(%__MODULE__{} = command) do
    %{command | status: :applied, completed_at: System.system_time(:millisecond)}
  end

  @doc """
  Marks the command as `:rejected` with `reason`, stamping `completed_at` with
  the current time.
  """
  @spec rejected(t(), term()) :: t()
  def rejected(%__MODULE__{} = command, reason) do
    %{
      command
      | status: :rejected,
        rejection: reason,
        completed_at: System.system_time(:millisecond)
    }
  end

  @spec desired_state(atom()) :: :active | :paused | :terminal | nil
  defp desired_state(:pause), do: :paused
  defp desired_state(:update), do: :paused
  defp desired_state(:update_and_resume), do: :active
  defp desired_state(:resume), do: :active
  defp desired_state(:stop), do: :terminal
  defp desired_state(:steer), do: :active
  defp desired_state(:cancel), do: :terminal
  defp desired_state(_action), do: nil

  @doc """
  Validates the command's identity, action, mode, timestamps and portability.

  Returns `:ok`, or `{:error, reason}` naming the first invalid field or the
  status whose timestamps are inconsistent.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = command) do
    cond do
      not valid_binary?(command.id) or not valid_binary?(command.loop_id) ->
        {:error, :invalid_loop_control_identity}

      command.action not in @actions ->
        {:error, :invalid_loop_control_action}

      command.mode not in @modes ->
        {:error, :invalid_loop_control_mode}

      command.mode == :immediate and command.action != :pause ->
        {:error, :immediate_mode_only_supported_for_pause}

      command.desired_state not in [:active, :paused, :terminal, nil] ->
        {:error, :invalid_loop_control_desired_state}

      not valid_binary?(command.correlation_id) ->
        {:error, :invalid_loop_control_correlation}

      not is_nil(command.causation_id) and not valid_binary?(command.causation_id) ->
        {:error, :invalid_loop_control_causation}

      not is_map(command.provenance) ->
        {:error, :invalid_loop_control_provenance}

      not optional_revision?(command.base_revision) ->
        {:error, :invalid_loop_control_base_revision}

      not non_negative_integer?(command.requested_at) ->
        {:error, :invalid_loop_control_requested_at}

      not optional_revision?(command.committed_at) ->
        {:error, :invalid_loop_control_committed_at}

      not optional_revision?(command.completed_at) ->
        {:error, :invalid_loop_control_completed_at}

      command.status not in [:pending, :committed, :applied, :rejected] ->
        {:error, :invalid_loop_control_status}

      not is_map(command.metadata) ->
        {:error, :invalid_loop_control_metadata}

      true ->
        with :ok <- validate_status_timestamps(command) do
          portable(command)
        end
    end
  end

  @spec validate_status_timestamps(t()) :: :ok | {:error, atom()}
  defp validate_status_timestamps(%__MODULE__{status: :pending} = command) do
    if is_nil(command.committed_at) and is_nil(command.completed_at) and is_nil(command.rejection),
      do: :ok,
      else: {:error, :invalid_pending_loop_control_timestamps}
  end

  defp validate_status_timestamps(%__MODULE__{status: :committed} = command) do
    if ordered_time?(command.committed_at, command.requested_at) and
         is_nil(command.completed_at) and is_nil(command.rejection),
       do: :ok,
       else: {:error, :invalid_committed_loop_control_timestamps}
  end

  defp validate_status_timestamps(%__MODULE__{status: :applied} = command) do
    if ordered_time?(command.committed_at, command.requested_at) and
         ordered_time?(command.completed_at, command.committed_at) and is_nil(command.rejection),
       do: :ok,
       else: {:error, :invalid_applied_loop_control_timestamps}
  end

  defp validate_status_timestamps(%__MODULE__{status: :rejected} = command) do
    if ordered_time?(command.committed_at, command.requested_at) and
         ordered_time?(command.completed_at, command.committed_at) and
         not is_nil(command.rejection),
       do: :ok,
       else: {:error, :invalid_rejected_loop_control_timestamps}
  end

  @spec ordered_time?(term(), term()) :: boolean()
  defp ordered_time?(value, floor),
    do: is_integer(value) and is_integer(floor) and value >= floor

  @spec portable(t()) :: :ok | {:error, {:nonportable_loop_control, term()}}
  defp portable(command) do
    case Value.validate(command, [:loop_control, command.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_loop_control, reason}}
    end
  end

  @spec valid_binary?(term()) :: boolean()
  defp valid_binary?(value), do: is_binary(value) and value != ""

  @spec optional_revision?(term()) :: boolean()
  defp optional_revision?(nil), do: true
  defp optional_revision?(value), do: non_negative_integer?(value)

  @spec non_negative_integer?(term()) :: boolean()
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
