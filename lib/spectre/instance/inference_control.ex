defmodule Spectre.Instance.InferenceControl do
  @moduledoc false

  # The canonical control entry is a small revisioned state machine. A command
  # either advances the generation exactly once or is rejected before the
  # Instance contacts a live stream session.

  alias Spectre.Inference.Failure
  alias Spectre.Invocation
  alias Spectre.Operation.Control.Command

  @history_limit 128

  @doc false
  @spec new(non_neg_integer()) :: map()
  def new(generation) when is_integer(generation) and generation >= 0 do
    %{generation: generation, pending: nil, last_command: nil, history: []}
  end

  @doc false
  @spec apply_cancel(map(), Command.t()) :: :duplicate | {:ok, map()} | {:error, term()}
  def apply_cancel(control, %Command{} = command) do
    with :ok <- validate_inference_action(command, :cancel) do
      cond do
        seen?(control, command.id) ->
          :duplicate

        control.generation != command.base_revision ->
          {:error, {:stale_inference_control_revision, command.base_revision, control.generation}}

        not is_nil(control.pending) ->
          {:error, {:inference_control_pending, control.pending.id}}

        true ->
          applied = command |> Command.committed() |> Command.applied()
          {:ok, control |> Map.put(:generation, control.generation + 1) |> finish(applied)}
      end
    end
  end

  @doc false
  @spec begin_steer(map(), Command.t()) :: {:ok, map()} | {:error, term()}
  def begin_steer(control, %Command{} = command) do
    with :ok <- validate_inference_action(command, :steer),
         :ok <- validate_steer(control, command) do
      {:ok,
       %{
         control
         | generation: control.generation + 1,
           pending: Command.committed(command)
       }}
    end
  end

  @doc false
  @spec finish(map(), Command.t()) :: map()
  def finish(control, %Command{} = command) do
    %{
      control
      | pending: nil,
        last_command: command,
        history: Enum.take([command | control.history], @history_limit)
    }
  end

  @doc false
  @spec receipt_disposition(map() | nil, Invocation.t(), term()) ::
          :accept | :stale | {:cancel, atom()}
  def receipt_disposition(nil, %Invocation{}, _outcome), do: :accept

  def receipt_disposition(control, %Invocation{} = invocation, outcome) when is_map(control) do
    cond do
      control.generation == invocation.control_revision ->
        :accept

      cancel_for_invocation?(control.last_command, invocation.id) and
          match?({:error, {:cancelled, _reason}}, outcome) ->
        :accept

      cancel_for_invocation?(control.last_command, invocation.id) ->
        {:cancel, :control_committed_before_terminal_acceptance}

      true ->
        :stale
    end
  end

  @doc false
  @spec recover(map() | nil, Invocation.t()) ::
          :continue | {:cancelled, term()} | {:error, atom()}
  def recover(nil, %Invocation{control_revision: 0}), do: :continue
  def recover(nil, %Invocation{}), do: {:error, :missing_inference_control_fence}

  def recover(%{pending: %Command{}}, %Invocation{}),
    do: {:error, :pending_inference_control_on_recovery}

  def recover(
        %{generation: generation, pending: nil},
        %Invocation{control_revision: generation}
      ),
      do: :continue

  def recover(
        %{generation: generation, pending: nil, last_command: %Command{} = command},
        %Invocation{} = invocation
      )
      when generation == invocation.control_revision + 1 do
    if cancel_for_invocation?(command, invocation.id) and
         command.base_revision == invocation.control_revision do
      recovered_cancel_reason(command)
    else
      {:error, :inference_control_fence_mismatch}
    end
  end

  def recover(_control, %Invocation{}), do: {:error, :inference_control_fence_mismatch}

  @doc false
  @spec cancel_for_invocation?(Command.t() | nil, String.t()) :: boolean()
  def cancel_for_invocation?(
        %Command{action: :cancel, status: :applied, causation_id: invocation_id},
        invocation_id
      ),
      do: true

  def cancel_for_invocation?(_command, _invocation_id), do: false

  defp validate_inference_action(%Command{action: action}, expected) do
    cond do
      not Command.inference_action?(action) ->
        {:error, {:unsupported_inference_control_action, action}}

      action != expected ->
        {:error, {:unexpected_inference_control_action, expected, action}}

      true ->
        :ok
    end
  end

  defp validate_steer(control, command) do
    cond do
      control.generation != command.base_revision ->
        {:error, {:stale_inference_control_revision, command.base_revision, control.generation}}

      not is_nil(control.pending) ->
        {:error, {:inference_control_pending, control.pending.id}}

      seen?(control, command.id) ->
        {:error, {:duplicate_inference_control, command.id}}

      true ->
        :ok
    end
  end

  defp seen?(control, id) do
    match?(%Command{id: ^id}, control.last_command) or
      Enum.any?(control.history, &(&1.id == id))
  end

  defp recovered_cancel_reason(%Command{payload: payload})
       when is_map(payload) and not is_struct(payload) do
    case Map.fetch(payload, :reason) do
      {:ok, reason} ->
        {:cancelled, Failure.sanitize(reason)}

      :error ->
        case Map.fetch(payload, "reason") do
          {:ok, reason} -> {:cancelled, Failure.sanitize(reason)}
          :error -> {:error, :missing_recovered_cancel_reason}
        end
    end
  end

  defp recovered_cancel_reason(_command), do: {:error, :invalid_recovered_cancel_payload}
end
