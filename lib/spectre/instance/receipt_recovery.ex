defmodule Spectre.Instance.ReceiptRecovery do
  @moduledoc false

  # Live delivery is protected by process capabilities. After restart those
  # capabilities intentionally no longer exist, so recovery accepts only an
  # exact outbox envelope whose durable Run-specific fences still match.

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Receipt.Envelope
  alias Spectre.Run
  alias Spectre.Run.StartContinuation

  @doc false
  @spec validate(InstanceState.t(), map(), Envelope.t()) :: :ok | {:error, atom()}
  def validate(%InstanceState{} = data, entry, %Envelope{} = envelope) do
    cond do
      envelope.id != entry.id or Envelope.digest(envelope) != entry.digest ->
        {:error, :required_receipt_envelope_mismatch}

      envelope.canonical_revision != entry.inserted_revision ->
        {:error, :required_receipt_revision_mismatch}

      true ->
        validate_run(data, envelope)
    end
  end

  defp validate_run(
         data,
         %Envelope{kind: :run_input_admitted, run_id: run_id, run_revision: run_revision}
       ) do
    case Map.get(data.runs, run_id) do
      %Run{
        revision: ^run_revision,
        status: :ready,
        cursor: :turn,
        start_continuation: %StartContinuation{}
      } ->
        :ok

      _mismatch ->
        {:error, :recovered_input_receipt_fence_mismatch}
    end
  end

  defp validate_run(
         data,
         %Envelope{
           kind: :inference_attempt_superseded,
           run_id: run_id,
           run_revision: run_revision,
           inference_id: inference_id,
           invocation_id: invocation_id,
           attempt_id: attempt_id,
           control_revision: control_revision,
           stream_epoch: stream_epoch
         }
       ) do
    case Map.get(data.runs, run_id) do
      %Run{
        revision: ^run_revision,
        status: :awaiting,
        cursor: :inference,
        inference_continuation: %{
          inference_id: ^inference_id,
          previous_attempts: previous_attempts
        }
      }
      when is_list(previous_attempts) ->
        validate_superseded_attempts(
          previous_attempts,
          attempt_id,
          invocation_id,
          control_revision,
          stream_epoch
        )

      _mismatch ->
        {:error, :recovered_supersession_receipt_fence_mismatch}
    end
  end

  defp validate_run(
         data,
         %Envelope{
           kind: kind,
           run_id: run_id,
           run_revision: run_revision,
           inference_id: inference_id,
           invocation_id: invocation_id,
           attempt_id: attempt_id,
           control_revision: control_revision,
           stream_epoch: stream_epoch
         }
       )
       when kind in [:inference_selected, :inference_attempt_started] do
    expected_status = if kind == :inference_selected, do: :selected, else: :dispatching

    case Map.get(data.runs, run_id) do
      %Run{
        revision: ^run_revision,
        status: :awaiting,
        cursor: :inference,
        waiting: %Invocation{
          id: ^invocation_id,
          inference_id: ^inference_id,
          attempt_id: ^attempt_id,
          control_revision: ^control_revision,
          stream_epoch: ^stream_epoch
        },
        inference_continuation: %{
          inference_id: ^inference_id,
          provider_status: ^expected_status
        }
      } ->
        :ok

      _mismatch ->
        {:error, :recovered_inference_receipt_fence_mismatch}
    end
  end

  defp validate_run(
         data,
         %Envelope{
           kind: kind,
           run_id: run_id,
           run_revision: run_revision,
           inference_id: inference_id,
           invocation_id: invocation_id,
           attempt_id: attempt_id,
           control_revision: control_revision,
           stream_epoch: stream_epoch
         }
       )
       when kind in [:inference_attempt_terminal, :inference_consumer_never_attached] do
    case Map.get(data.runs, run_id) do
      %Run{
        revision: ^run_revision,
        status: :awaiting,
        waiting: %Invocation{
          id: ^invocation_id,
          inference_id: ^inference_id,
          attempt_id: ^attempt_id,
          control_revision: ^control_revision,
          stream_epoch: ^stream_epoch
        }
      } ->
        :ok

      %Run{revision: ^run_revision, status: :failed, metadata: metadata} ->
        case Map.get(metadata, :inference_terminal) do
          %{
            inference_id: ^inference_id,
            invocation_id: ^invocation_id,
            attempt_id: ^attempt_id,
            control_revision: ^control_revision,
            stream_epoch: ^stream_epoch
          } ->
            :ok

          _mismatch ->
            {:error, :recovered_inference_receipt_fence_mismatch}
        end

      _mismatch ->
        {:error, :recovered_inference_receipt_fence_mismatch}
    end
  end

  defp validate_run(
         data,
         %Envelope{
           kind: :policy_decision,
           run_id: run_id,
           run_revision: run_revision,
           payload: %{boundary_id: boundary_id}
         }
       ) do
    case Map.get(data.runs, run_id) do
      %Run{
        revision: ^run_revision,
        metadata: %{policy_decision: %{boundary_id: ^boundary_id}}
      } ->
        :ok

      _mismatch ->
        {:error, :recovered_policy_receipt_fence_mismatch}
    end
  end

  defp validate_run(
         data,
         %Envelope{
           kind: kind,
           run_id: run_id,
           run_revision: run_revision,
           invocation_id: invocation_id,
           payload: %{effect: %{id: effect_id}, idempotency_key: idempotency_key}
         }
       )
       when kind in [:effect_terminal, :action_terminal] do
    case Map.get(data.runs, run_id) do
      %Run{
        revision: ^run_revision,
        metadata: %{
          effect_terminal: %{
            invocation_id: ^invocation_id,
            effect_id: ^effect_id,
            kind: ^kind,
            idempotency_key: ^idempotency_key
          }
        }
      } ->
        :ok

      _mismatch ->
        {:error, :recovered_effect_receipt_fence_mismatch}
    end
  end

  defp validate_run(
         data,
         %Envelope{
           kind: :authority_decision,
           definition_ref: definition_ref,
           payload: %{
             axis: axis,
             to: value,
             lifecycle_revision: lifecycle_revision,
             authority_epoch: authority_epoch
           }
         }
       ) do
    with {:ok, lifecycles} <- Canonical.fetch(data.canonical, :lifecycles),
         %Lifecycle{revision: ^lifecycle_revision, authority_epoch: ^authority_epoch} = lifecycle <-
           Map.get(lifecycles, definition_ref),
         true <- Map.get(lifecycle, axis) == value do
      :ok
    else
      _mismatch -> {:error, :recovered_authority_receipt_fence_mismatch}
    end
  end

  defp validate_run(_data, _envelope),
    do: {:error, :unsupported_recovered_receipt_boundary}

  defp validate_superseded_attempts(
         previous_attempts,
         attempt_id,
         invocation_id,
         control_revision,
         stream_epoch
       ) do
    if Enum.any?(
         previous_attempts,
         &superseded_attempt?(
           &1,
           attempt_id,
           invocation_id,
           control_revision,
           stream_epoch
         )
       ),
       do: :ok,
       else: {:error, :recovered_supersession_receipt_fence_mismatch}
  end

  defp superseded_attempt?(
         previous,
         attempt_id,
         invocation_id,
         control_revision,
         stream_epoch
       ) do
    Map.get(previous, :attempt_id) == attempt_id and
      Map.get(previous, :invocation_id) == invocation_id and
      Map.get(previous, :control_revision) == control_revision and
      Map.get(previous, :stream_epoch) == stream_epoch and
      Map.get(previous, :outcome) == :superseded
  end
end
