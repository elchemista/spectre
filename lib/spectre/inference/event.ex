defmodule Spectre.Inference.Event do
  @moduledoc "Committed, text-free observer event for an inference lifecycle."

  alias Spectre.Inference.Progress
  alias Spectre.Determinism
  alias Spectre.Run.Value

  @types [:progress_committed, :attempt_superseded, :terminal_committed, :stream_interrupted]

  @enforce_keys [
    :id,
    :type,
    :instance_key,
    :inference_id,
    :invocation_id,
    :canonical_revision,
    :timestamp
  ]
  defstruct [
    :id,
    :type,
    :instance_key,
    :inference_id,
    :invocation_id,
    :attempt_id,
    :stream_epoch,
    :canonical_revision,
    :timestamp,
    :progress,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(atom(), Progress.t(), keyword()) :: t()
  def new(type, %Progress{} = progress, opts) when type in @types and is_list(opts) do
    revision = Keyword.fetch!(opts, :canonical_revision)
    instance_key = Keyword.fetch!(opts, :instance_key)

    event = %__MODULE__{
      id:
        Value.token(
          "inference-event",
          {type, progress.inference_id, progress.invocation_id, revision}
        ),
      type: type,
      instance_key: instance_key,
      inference_id: progress.inference_id,
      invocation_id: progress.invocation_id,
      attempt_id: progress.attempt_id,
      stream_epoch: progress.stream_epoch,
      canonical_revision: revision,
      timestamp: Keyword.get(opts, :timestamp, Determinism.system_time(:millisecond)),
      progress: progress,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case validate(event) do
      :ok -> event
      {:error, reason} -> raise ArgumentError, "invalid inference event: #{inspect(reason)}"
    end
  end

  @doc false
  @spec new(atom(), keyword()) :: t()
  def new(type, opts) when type in @types and is_list(opts) do
    revision = Keyword.fetch!(opts, :canonical_revision)
    instance_key = Keyword.fetch!(opts, :instance_key)
    inference_id = Keyword.fetch!(opts, :inference_id)
    invocation_id = Keyword.fetch!(opts, :invocation_id)

    event = %__MODULE__{
      id: Value.token("inference-event", {type, inference_id, invocation_id, revision}),
      type: type,
      instance_key: instance_key,
      inference_id: inference_id,
      invocation_id: invocation_id,
      attempt_id: Keyword.get(opts, :attempt_id),
      stream_epoch: Keyword.get(opts, :stream_epoch),
      canonical_revision: revision,
      timestamp: Keyword.get(opts, :timestamp, Determinism.system_time(:millisecond)),
      progress: Keyword.get(opts, :progress),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case validate(event) do
      :ok -> event
      {:error, reason} -> raise ArgumentError, "invalid inference event: #{inspect(reason)}"
    end
  end

  @spec validate(t()) :: :ok | {:error, term()}
  # Durable inference events form a closed wire schema; keeping all field and
  # kind invariants together makes codec failures deterministic.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = event) do
    cond do
      event.type not in @types ->
        {:error, :invalid_inference_event_type}

      not Enum.all?(
        [event.id, event.instance_key, event.inference_id, event.invocation_id],
        &non_empty_binary?/1
      ) ->
        {:error, :invalid_inference_event_identity}

      not optional_binary?(event.attempt_id) or not optional_binary?(event.stream_epoch) ->
        {:error, :invalid_inference_event_fence}

      not is_integer(event.canonical_revision) or event.canonical_revision < 0 ->
        {:error, :invalid_inference_event_revision}

      not is_integer(event.timestamp) or event.timestamp < 0 ->
        {:error, :invalid_inference_event_timestamp}

      not is_map(event.metadata) or is_struct(event.metadata) ->
        {:error, :invalid_inference_event_metadata}

      event.type == :progress_committed and not match?(%Progress{}, event.progress) ->
        {:error, :invalid_inference_event_progress}

      event.type != :progress_committed and not is_nil(event.progress) and
          not match?(%Progress{}, event.progress) ->
        {:error, :invalid_inference_event_progress}

      true ->
        with :ok <- validate_progress(event),
             :ok <- Value.validate(event.metadata, [:inference_event, :metadata]) do
          Value.validate(event, [:inference_event])
        end
    end
  end

  defp validate_progress(%__MODULE__{progress: nil}), do: :ok

  defp validate_progress(%__MODULE__{progress: %Progress{} = progress} = event) do
    with :ok <- Progress.validate(progress) do
      if progress.inference_id == event.inference_id and
           progress.invocation_id == event.invocation_id and
           progress.attempt_id == event.attempt_id and
           progress.stream_epoch == event.stream_epoch and
           progress.canonical_revision == event.canonical_revision do
        :ok
      else
        {:error, :inference_event_progress_fence_mismatch}
      end
    end
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: non_empty_binary?(value)
end
