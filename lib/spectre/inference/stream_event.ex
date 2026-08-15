defmodule Spectre.Inference.StreamEvent do
  @moduledoc """
  Fenced public event yielded by `Spectre.Inference.Stream`.

  Delta payloads are provisional until the complete response has passed the
  normal reply sanitizer and any configured guard. Consumers must not treat a
  provisional delta as a committed user-visible reply.
  """

  alias Spectre.Inference.Usage

  @kinds [
    :delta,
    :usage,
    :inference_completed,
    :result,
    :failed,
    :cancelled,
    :superseded,
    :interrupted,
    :ambiguous,
    :already_consumed,
    :stream_expired
  ]
  @content_classes [:provisional, :sanitized, :unsanitized, :control]

  @enforce_keys [
    :kind,
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_revision,
    :control_revision,
    :stream_epoch,
    :sequence
  ]
  # All ordering fences are explicit so an event can be audited in isolation.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :kind,
    :payload,
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :control_revision,
    :stream_epoch,
    :sequence,
    :at,
    content_class: :control,
    usage: %Usage{},
    metadata: %{}
  ]

  @type kind :: atom()
  @type t :: %__MODULE__{}

  @spec new(kind(), keyword()) :: t()
  def new(kind, opts) when kind in @kinds and is_list(opts) do
    event = %__MODULE__{
      kind: kind,
      payload: Keyword.get(opts, :payload),
      inference_id: Keyword.fetch!(opts, :inference_id),
      invocation_id: Keyword.fetch!(opts, :invocation_id),
      attempt_id: Keyword.fetch!(opts, :attempt_id),
      run_revision: Keyword.fetch!(opts, :run_revision),
      generation: Keyword.get(opts, :generation),
      dispatch_id: Keyword.get(opts, :dispatch_id),
      control_revision: Keyword.fetch!(opts, :control_revision),
      stream_epoch: Keyword.fetch!(opts, :stream_epoch),
      sequence: Keyword.fetch!(opts, :sequence),
      # Public deltas are ephemeral observations, not decision inputs. Using
      # the system clock directly keeps high-volume streams from exhausting
      # the bounded nondeterminism receipt with one timestamp per token.
      at: Keyword.get(opts, :at, System.system_time(:millisecond)),
      content_class: Keyword.get(opts, :content_class, default_content_class(kind)),
      usage: Usage.new(Keyword.get(opts, :usage)),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case validate(event) do
      :ok -> event
      {:error, reason} -> raise ArgumentError, "invalid stream event: #{inspect(reason)}"
    end
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{kind: kind}),
    do:
      kind in [
        :result,
        :failed,
        :cancelled,
        :superseded,
        :interrupted,
        :ambiguous,
        :already_consumed,
        :stream_expired
      ]

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  # Stream events carry the complete ordering fence. Keeping these predicates
  # together prevents partial validation from admitting a stale delta.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = event) do
    cond do
      event.kind not in @kinds ->
        {:error, :invalid_stream_event_kind}

      event.kind == :delta and
          (not is_binary(event.payload) or not String.valid?(event.payload)) ->
        {:error, :invalid_stream_event_delta}

      event.content_class not in @content_classes ->
        {:error, :invalid_stream_event_content_class}

      not Enum.all?(
        [
          event.inference_id,
          event.invocation_id,
          event.attempt_id,
          event.generation,
          event.dispatch_id,
          event.stream_epoch
        ],
        &(is_binary(&1) and &1 != "")
      ) ->
        {:error, :invalid_stream_event_identity}

      not is_integer(event.run_revision) or event.run_revision < 0 or
        not is_integer(event.control_revision) or event.control_revision < 0 ->
        {:error, :invalid_stream_event_revision_fence}

      not is_integer(event.sequence) or event.sequence < 0 ->
        {:error, :invalid_stream_event_sequence}

      not is_integer(event.at) or event.at < 0 ->
        {:error, :invalid_stream_event_timestamp}

      not match?(%Usage{}, event.usage) or not is_map(event.metadata) or
          is_struct(event.metadata) ->
        {:error, :invalid_stream_event_metadata}

      true ->
        Usage.validate(event.usage)
    end
  end

  def validate(_event), do: {:error, :invalid_stream_event}

  defp default_content_class(:delta), do: :provisional
  defp default_content_class(_kind), do: :control
end
