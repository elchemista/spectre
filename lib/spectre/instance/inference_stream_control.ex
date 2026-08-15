defmodule Spectre.Instance.InferenceStreamControl do
  @moduledoc false

  # Validates the untrusted live Stream handle before the Instance mutates
  # canonical control state. Command construction and consumer-token checks
  # stay side-effect free, making cancel, steer, and resume share one boundary.

  alias Spectre.Inference.Failure
  alias Spectre.Inference.Stream
  alias Spectre.Input
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Operation.Control.Command
  alias Spectre.Run
  alias Spectre.Run.Value

  @doc false
  @spec validate_resume(Run.t(), map(), Stream.t()) :: :ok | {:error, atom()}
  def validate_resume(run, recovery, old_stream) when is_map(recovery) do
    expected_digest = Map.get(recovery, :previous_consumer_token_digest)

    cond do
      run.id != old_stream.run_id or
          run.inference_continuation.inference_id != old_stream.inference_id ->
        {:error, :stale_stream_handle}

      Map.get(recovery, :previous_invocation_id) != old_stream.invocation_id or
          Map.get(recovery, :previous_stream_epoch) != old_stream.stream_epoch ->
        {:error, :stale_stream_handle}

      not is_binary(expected_digest) or
          expected_digest != token_digest(old_stream.consumer_token) ->
        {:error, :invalid_stream_consumer_token}

      true ->
        :ok
    end
  end

  def validate_resume(_run, _recovery, _old_stream),
    do: {:error, :stream_resume_unavailable}

  @doc false
  @spec current_ownership(InstanceState.t(), Stream.t()) ::
          {:ok, map(), Run.t()} | {:error, atom()}
  def current_ownership(%InstanceState{} = data, %Stream{} = stream) do
    ownership = Map.get(data.stream_sessions, stream.invocation_id)
    invocation_ownership = Map.get(data.invocations, stream.invocation_id)

    cond do
      is_nil(ownership) or is_nil(invocation_ownership) ->
        {:error, :invocation_terminal}

      not secure_token?(ownership.stream.consumer_token, stream.consumer_token) ->
        {:error, :invalid_stream_consumer_token}

      ownership.stream != stream ->
        {:error, :stale_stream_handle}

      true ->
        current_run(data, ownership, stream)
    end
  end

  @doc false
  @spec normalize_steer_input(term(), keyword(), InstanceState.t()) ::
          {:ok, Input.t()} | {:error, term()}
  def normalize_steer_input(input, opts, %InstanceState{} = data) do
    logical = input |> Input.new() |> Spectre.Run.Codec.logical_input()

    max_bytes =
      Keyword.get(
        opts,
        :stream_steer_max_bytes,
        Keyword.get(data.base_opts, :stream_steer_max_bytes, 32_000)
      )

    cond do
      not is_binary(logical.text) or logical.text == "" ->
        {:error, :empty_stream_steer_input}

      byte_size(logical.text) > max_bytes ->
        {:error, {:stream_steer_input_too_large, byte_size(logical.text), max_bytes}}

      true ->
        {:ok, logical}
    end
  rescue
    exception -> {:error, {:invalid_stream_steer_input, exception.__struct__}}
  end

  @doc false
  @spec cancel_command(Run.t(), Stream.t(), term(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def cancel_command(run, stream, reason, opts) do
    portable_reason = Failure.sanitize(reason)

    command_id =
      Keyword.get_lazy(opts, :command_id, fn ->
        Value.token(
          "inference-cancel",
          {stream.invocation_id, stream.control_revision, portable_reason}
        )
      end)

    command =
      Command.new(stream.inference_id, :cancel,
        id: command_id,
        payload: %{reason: portable_reason},
        correlation_id: run.id,
        causation_id: stream.invocation_id,
        base_revision: stream.control_revision,
        provenance: %{source: :stream_control},
        metadata: %{
          target_kind: :inference,
          invocation_id: stream.invocation_id,
          stream_epoch: stream.stream_epoch
        }
      )

    case Command.validate(command) do
      :ok -> {:ok, command}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:invalid_stream_cancel, exception.__struct__}}
  end

  @doc false
  @spec steer_command(Run.t(), Stream.t(), Input.t(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def steer_command(run, stream, steer_input, opts) do
    command_id =
      Keyword.get_lazy(opts, :command_id, fn ->
        Value.token(
          "inference-steer",
          {stream.invocation_id, stream.control_revision, steer_input}
        )
      end)

    command =
      Command.new(stream.inference_id, :steer,
        id: command_id,
        payload: %{input: steer_input},
        correlation_id: run.id,
        causation_id: stream.invocation_id,
        base_revision: stream.control_revision,
        provenance: %{source: :stream_control},
        metadata: %{target_kind: :inference, stream_epoch: stream.stream_epoch}
      )

    case Command.validate(command) do
      :ok -> {:ok, command}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec token_digest(String.t()) :: String.t()
  def token_digest(token) when is_binary(token) and token != "",
    do: Value.token("stream-consumer-token", token)

  defp current_run(data, ownership, stream) do
    case Map.get(data.runs, ownership.run_id) do
      %Run{
        status: :awaiting,
        cursor: :inference,
        waiting: %Invocation{id: invocation_id},
        inference_continuation: continuation
      } = run
      when invocation_id == stream.invocation_id and
             continuation.control_revision == stream.control_revision ->
        {:ok, ownership, run}

      %Run{} ->
        {:error, :invocation_terminal}

      nil ->
        {:error, :unknown_stream_run}
    end
  end

  defp secure_token?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_token?(_left, _right), do: false
end
