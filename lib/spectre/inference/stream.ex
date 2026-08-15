defmodule Spectre.Inference.Stream do
  @moduledoc """
  One-shot, pull-driven inference stream.

  The handle is intentionally process-free: it carries only logical fences
  plus a bearer token used to authorize attach and control operations. The
  live session is resolved through a unique Registry. It is an ephemeral
  capability, not a durable or persistable continuation. Recovery returns a
  replacement handle with a fresh epoch.

  Delta events are provisional. Only the terminal `%Spectre.Result{}` has
  passed the normal post-processing and canonical Run commit.
  """

  alias Spectre.Inference.StreamEvent
  alias Spectre.Instance.Registry, as: InstanceRegistry

  @enforce_keys [
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :control_revision,
    :stream_epoch,
    :consumer_token,
    :instance_ref
  ]
  # The public handle repeats ordering fences so it never needs a process id.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :control_revision,
    :stream_epoch,
    :consumer_token,
    :instance_ref,
    registry: Spectre.Inference.StreamRegistry,
    instance_registry: Spectre.Instance.Registry,
    demand: 8,
    next_timeout: 30_000
  ]

  @opaque t :: %__MODULE__{}

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    stream = struct!(__MODULE__, opts)

    if valid?(stream) do
      stream
    else
      raise ArgumentError, "invalid inference stream handle"
    end
  end

  @doc "Cancels the current stream attempt. The operation is idempotent."
  @spec cancel(t(), term()) :: :ok | {:error, term()}
  def cancel(%__MODULE__{} = stream, reason \\ :user_requested) do
    case InstanceRegistry.lookup_ref(stream.instance_ref, stream.instance_registry) do
      {:ok, instance} ->
        try do
          Spectre.Instance.cancel_stream(instance, stream, reason, timeout: stream.next_timeout)
        catch
          :exit, {:noproc, _call} -> :ok
          :exit, {:normal, _call} -> :ok
          :exit, {:timeout, _call} -> {:error, :stream_control_timeout}
          :exit, reason -> {:error, {:stream_control_exit, exit_class(reason)}}
        end

      # A missing owner means the old generation can no longer accept the
      # attempt. The data plane monitors that owner and interrupts itself, so
      # cancellation is already satisfied from the caller's perspective.
      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Commits restart-based steering and returns a replacement Enumerable.

  The current stream never follows the successor epoch; it terminates with
  `:superseded` when the Instance accepts the command.
  """
  @spec steer(t(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def steer(%__MODULE__{} = stream, input, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts) do
      with {:ok, instance} <-
             InstanceRegistry.lookup_ref(stream.instance_ref, stream.instance_registry) do
        Spectre.Instance.steer_stream(instance, stream, input, opts)
      end
    else
      {:error, :invalid_stream_options}
    end
  end

  @doc """
  Waits for the committed terminal Run result without exposing deltas.

  When no Enumerable has claimed the handle, this call becomes its one
  authoritative consumer and drains provider events internally. When an
  Enumerable is already active, it only waits for that consumer's terminal
  result. Repeated calls are idempotent for the session's retention window.
  """
  @spec await_result(t(), timeout()) :: {:ok, Spectre.Result.t()} | {:error, term()}
  def await_result(%__MODULE__{} = stream, timeout \\ :timer.minutes(5)) do
    with :ok <- validate_timeout(timeout),
         {:ok, pid} <- lookup_session(stream) do
      awaiter_ref = make_ref()

      try do
        :gen_statem.call(
          pid,
          {:await_result, stream.consumer_token, awaiter_ref},
          timeout
        )
      catch
        :exit, {:timeout, _call} ->
          :gen_statem.cast(pid, {:abandon_result_waiter, stream.consumer_token, awaiter_ref})
          {:error, :stream_await_timeout}

        :exit, {:noproc, _call} ->
          {:error, :stream_not_found}

        :exit, {:normal, _call} ->
          {:error, :stream_expired}

        :exit, reason ->
          {:error, {:stream_session_exit, exit_class(reason)}}
      end
    end
  end

  @doc false
  @spec enumerable(t()) :: Enumerable.t()
  def enumerable(%__MODULE__{} = stream) do
    Elixir.Stream.resource(
      fn ->
        %{
          stream: stream,
          claim: make_ref(),
          sequence: 0,
          terminal?: false,
          cancel_on_cleanup?: true
        }
      end,
      &next_batch/1,
      &cleanup/1
    )
  end

  @doc false
  @spec session_key(t()) :: {String.t(), String.t()}
  def session_key(%__MODULE__{} = stream), do: {stream.invocation_id, stream.stream_epoch}

  @doc false
  @spec lookup_session(t()) :: {:ok, pid()} | {:error, :stream_not_found}
  def lookup_session(%__MODULE__{} = stream) do
    case Registry.lookup(stream.registry, session_key(stream)) do
      [{pid, _metadata}] when is_pid(pid) -> {:ok, pid}
      [] -> {:error, :stream_not_found}
    end
  end

  defp next_batch(%{terminal?: true} = state), do: {:halt, state}

  defp next_batch(%{stream: stream, claim: claim} = state) do
    with {:ok, pid} <- lookup_session(stream),
         {:ok, events} <-
           call_session(
             pid,
             {:next, stream.consumer_token, self(), claim, stream.demand},
             stream.next_timeout
           ),
         {:ok, sequence} <- validate_batch(stream, events, state.sequence) do
      terminal? = Enum.any?(events, &StreamEvent.terminal?/1)

      {events,
       %{
         state
         | sequence: sequence,
           terminal?: terminal?,
           cancel_on_cleanup?: not terminal?
       }}
    else
      {:error, reason} ->
        event = local_terminal(stream, normalize_enumeration_failure(reason), state.sequence + 1)
        {[event], %{state | terminal?: true, cancel_on_cleanup?: true}}
    end
  end

  defp cleanup(%{terminal?: true, cancel_on_cleanup?: false}), do: :ok

  defp cleanup(%{stream: stream}) do
    _ = cancel(stream, :consumer_halted)
    :ok
  end

  defp call_session(pid, message, timeout) do
    :gen_statem.call(pid, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :stream_next_timeout}
    :exit, {:noproc, _call} -> {:error, :stream_not_found}
    :exit, {:normal, _call} -> {:error, :stream_expired}
    :exit, reason -> {:error, {:stream_session_exit, exit_class(reason)}}
  end

  defp local_terminal(stream, kind, sequence)
       when kind in [:failed, :interrupted, :stream_expired] do
    StreamEvent.new(kind,
      inference_id: stream.inference_id,
      invocation_id: stream.invocation_id,
      attempt_id: stream.attempt_id,
      run_revision: stream.run_revision,
      generation: stream.generation,
      dispatch_id: stream.dispatch_id,
      control_revision: stream.control_revision,
      stream_epoch: stream.stream_epoch,
      # Locally synthesized terminal events still preserve the monotonic
      # sequence observed by this Enumerable. They are not authoritative Run
      # receipts, but consumers must never see ordering move backwards.
      sequence: sequence,
      payload: kind,
      content_class: :control
    )
  end

  defp normalize_enumeration_failure(:stream_expired), do: :stream_expired
  defp normalize_enumeration_failure(:stream_not_found), do: :stream_expired
  defp normalize_enumeration_failure(_reason), do: :interrupted

  defp validate_batch(_stream, [], sequence), do: {:ok, sequence}

  defp validate_batch(
         stream,
         [%StreamEvent{kind: :already_consumed} = event],
         sequence
       ) do
    with :ok <- StreamEvent.validate(event),
         true <- matching_fences?(stream, event),
         true <- event.sequence > sequence do
      {:ok, event.sequence}
    else
      {:error, _reason} -> {:error, :invalid_stream_event}
      false -> {:error, :stream_fence_violation}
    end
  end

  defp validate_batch(stream, events, sequence) when is_list(events) do
    Enum.reduce_while(events, {:ok, sequence}, fn
      %StreamEvent{} = event, {:ok, previous} ->
        validate_next_event(stream, event, previous)

      _event, _acc ->
        {:halt, {:error, :invalid_stream_event}}
    end)
  end

  defp validate_batch(_stream, _events, _sequence), do: {:error, :invalid_stream_event_batch}

  defp validate_next_event(stream, event, previous) do
    case StreamEvent.validate(event) do
      :ok ->
        if matching_fences?(stream, event) and event.sequence == previous + 1 do
          {:cont, {:ok, event.sequence}}
        else
          {:halt, {:error, :stream_fence_violation}}
        end

      {:error, _reason} ->
        {:halt, {:error, :invalid_stream_event}}
    end
  end

  defp matching_fences?(stream, event) do
    event.inference_id == stream.inference_id and
      event.invocation_id == stream.invocation_id and
      event.attempt_id == stream.attempt_id and
      event.run_revision == stream.run_revision and
      event.generation == stream.generation and
      event.dispatch_id == stream.dispatch_id and
      event.control_revision == stream.control_revision and
      event.stream_epoch == stream.stream_epoch
  end

  defp valid?(stream) do
    nonempty_identifiers?(stream) and valid_ordering_fences?(stream) and
      valid_enumeration_options?(stream)
  end

  defp nonempty_identifiers?(stream) do
    Enum.all?(
      [
        stream.inference_id,
        stream.invocation_id,
        stream.attempt_id,
        stream.run_id,
        stream.generation,
        stream.dispatch_id,
        stream.stream_epoch,
        stream.consumer_token
      ],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp valid_ordering_fences?(stream) do
    is_integer(stream.run_revision) and stream.run_revision >= 0 and
      is_integer(stream.control_revision) and stream.control_revision >= 0
  end

  defp valid_enumeration_options?(stream) do
    is_integer(stream.demand) and stream.demand > 0 and
      (stream.next_timeout == :infinity or
         (is_integer(stream.next_timeout) and stream.next_timeout > 0))
  end

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_timeout(_timeout), do: {:error, :invalid_stream_timeout}

  defp exit_class(reason) when is_atom(reason), do: reason
  defp exit_class({reason, _detail}) when is_atom(reason), do: reason
  defp exit_class(_reason), do: :exit
end

defimpl Enumerable, for: Spectre.Inference.Stream do
  def reduce(stream, accumulator, reducer) do
    stream
    |> Spectre.Inference.Stream.enumerable()
    |> Enumerable.reduce(accumulator, reducer)
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end

defimpl Inspect, for: Spectre.Inference.Stream do
  import Inspect.Algebra

  def inspect(stream, opts) do
    fields = [
      inference_id: stream.inference_id,
      invocation_id: stream.invocation_id,
      attempt_id: stream.attempt_id,
      stream_epoch: stream.stream_epoch,
      control_revision: stream.control_revision
    ]

    concat(["#Spectre.Inference.Stream<", to_doc(fields, opts), ">"])
  end
end
