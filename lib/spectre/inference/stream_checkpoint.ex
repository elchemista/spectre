defmodule Spectre.Inference.StreamCheckpoint do
  @moduledoc false

  alias Spectre.Run.Value
  alias Spectre.Inference.Usage

  @default_max_bytes 32_000
  @usage_qualities [:provider, :estimated, :unavailable]

  @enforce_keys [:provider_request_digest, :resume_cursor_digest]
  defstruct [
    :provider_request_id,
    :provider_request_digest,
    :provider_sequence,
    :resume_cursor,
    :resume_cursor_digest,
    usage: %Usage{},
    usage_quality: :unavailable,
    output_bytes: 0
  ]

  @type t :: %__MODULE__{
          provider_request_id: term(),
          provider_request_digest: String.t() | nil,
          provider_sequence: non_neg_integer() | nil,
          resume_cursor: term(),
          resume_cursor_digest: String.t() | nil,
          usage: Usage.t(),
          usage_quality: :provider | :estimated | :unavailable,
          output_bytes: non_neg_integer()
        }

  @doc false
  @spec new(term(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(provider_request_id, resume_cursor, opts \\ []) when is_list(opts) do
    usage = Usage.new(Keyword.get(opts, :usage))

    checkpoint = %__MODULE__{
      provider_request_id: provider_request_id,
      provider_request_digest: digest(provider_request_id),
      provider_sequence: Keyword.get(opts, :provider_sequence),
      resume_cursor: resume_cursor,
      resume_cursor_digest: digest(resume_cursor),
      usage: usage,
      usage_quality: Keyword.get(opts, :usage_quality, :unavailable),
      output_bytes: Keyword.get(opts, :output_bytes, usage.output_bytes)
    }

    with :ok <- validate(checkpoint),
         :ok <- validate_size(checkpoint, Keyword.get(opts, :max_bytes, @default_max_bytes)) do
      {:ok, checkpoint}
    end
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # A resume checkpoint is a fenced provider cursor. Validate every correlated
  # field together before any adapter sees it.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = checkpoint) do
    cond do
      checkpoint.provider_request_digest != digest(checkpoint.provider_request_id) ->
        {:error, :stream_checkpoint_provider_request_digest_mismatch}

      checkpoint.resume_cursor_digest != digest(checkpoint.resume_cursor) ->
        {:error, :stream_checkpoint_cursor_digest_mismatch}

      not is_nil(checkpoint.provider_sequence) and
          (not is_integer(checkpoint.provider_sequence) or checkpoint.provider_sequence < 0) ->
        {:error, :invalid_stream_checkpoint_provider_sequence}

      checkpoint.usage_quality not in @usage_qualities ->
        {:error, :invalid_stream_checkpoint_usage_quality}

      not is_integer(checkpoint.output_bytes) or checkpoint.output_bytes < 0 ->
        {:error, :invalid_stream_checkpoint_output_bytes}

      checkpoint.usage.output_bytes != checkpoint.output_bytes ->
        {:error, :stream_checkpoint_output_bytes_mismatch}

      true ->
        with :ok <- Usage.validate(checkpoint.usage) do
          Value.validate(checkpoint, [:inference_stream_checkpoint])
        end
    end
  rescue
    _exception -> {:error, :invalid_stream_checkpoint_usage}
  end

  @doc false
  @spec meaningful?(t()) :: boolean()
  def meaningful?(%__MODULE__{} = checkpoint) do
    not is_nil(checkpoint.provider_request_id) or not is_nil(checkpoint.resume_cursor) or
      not is_nil(checkpoint.provider_sequence) or checkpoint.usage != %Usage{}
  end

  defp validate_size(_checkpoint, limit) when not is_integer(limit) or limit <= 0,
    do: {:error, {:invalid_stream_checkpoint_max_bytes, limit}}

  defp validate_size(checkpoint, limit) do
    with {:ok, encoded} <- Value.encode(checkpoint) do
      size = :erlang.external_size(encoded)

      if size <= limit,
        do: :ok,
        else: {:error, {:stream_checkpoint_too_large, size, limit}}
    end
  end

  defp digest(nil), do: nil
  defp digest(value), do: Value.token("provider", value)
end
