defmodule Spectre.Inference.Progress do
  @moduledoc "Bounded, text-free latest-value progress for an inference attempt."

  alias Spectre.Inference.Usage
  alias Spectre.Run.Value

  @states [:awaiting_consumer, :opening, :streaming, :committing, :terminal]
  @qualities [:provider, :estimated, :unavailable]

  @enforce_keys [
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :control_revision,
    :stream_epoch,
    :sequence,
    :state,
    :at
  ]
  # This projection repeats every live fence by design.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :control_revision,
    :stream_epoch,
    :sequence,
    :provider_request_digest,
    :provider_cursor_digest,
    :state,
    :at,
    :canonical_revision,
    output_bytes: 0,
    usage: %Usage{},
    usage_quality: :unavailable
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    progress = struct!(__MODULE__, Keyword.put_new(opts, :usage, %Usage{}))
    progress = %{progress | usage: Usage.new(progress.usage)}

    case validate(progress) do
      :ok -> progress
      {:error, reason} -> raise ArgumentError, "invalid inference progress: #{inspect(reason)}"
    end
  end

  @spec validate(t()) :: :ok | {:error, term()}
  # Progress is a compact canonical heartbeat schema. Its correlated fences
  # must be validated as one unit before observers can trust it.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = progress) do
    cond do
      not Enum.all?(
        [
          progress.inference_id,
          progress.invocation_id,
          progress.attempt_id,
          progress.generation,
          progress.dispatch_id,
          progress.stream_epoch
        ],
        &(is_binary(&1) and &1 != "")
      ) ->
        {:error, :invalid_inference_progress_identity}

      not is_integer(progress.run_revision) or progress.run_revision < 0 or
        not is_integer(progress.control_revision) or progress.control_revision < 0 ->
        {:error, :invalid_inference_progress_fence}

      progress.state not in @states ->
        {:error, :invalid_inference_progress_state}

      progress.usage_quality not in @qualities ->
        {:error, :invalid_inference_usage_quality}

      not is_integer(progress.sequence) or progress.sequence < 0 ->
        {:error, :invalid_inference_progress_sequence}

      not is_integer(progress.output_bytes) or progress.output_bytes < 0 ->
        {:error, :invalid_inference_progress_bytes}

      not optional_binary?(progress.provider_request_digest) or
          not optional_binary?(progress.provider_cursor_digest) ->
        {:error, :invalid_inference_progress_provider_digest}

      not is_nil(progress.canonical_revision) and
          (not is_integer(progress.canonical_revision) or progress.canonical_revision < 0) ->
        {:error, :invalid_inference_progress_canonical_revision}

      not is_integer(progress.at) or progress.at < 0 ->
        {:error, :invalid_inference_progress_timestamp}

      true ->
        Value.validate(progress, [:inference_progress])
    end
  end

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value) and value != ""
end
