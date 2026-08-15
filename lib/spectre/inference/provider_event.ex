defmodule Spectre.Inference.ProviderEvent do
  @moduledoc "Normalized event emitted by a streaming provider adapter."

  alias Spectre.Inference.Response
  alias Spectre.Inference.Usage

  @kinds [:started, :delta, :usage, :completed, :failed]

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :payload,
    :provider_sequence,
    :cursor,
    :provider_request_id,
    :usage_quality,
    usage: %Usage{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(atom(), keyword()) :: t()
  def new(kind, opts \\ []) when kind in @kinds and is_list(opts) do
    event = %__MODULE__{
      kind: kind,
      payload: Keyword.get(opts, :payload),
      provider_sequence: Keyword.get(opts, :provider_sequence),
      cursor: Keyword.get(opts, :cursor),
      provider_request_id: Keyword.get(opts, :provider_request_id),
      usage: Usage.new(Keyword.get(opts, :usage)),
      usage_quality: Keyword.get(opts, :usage_quality),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate!(event)
  end

  @spec delta(String.t(), keyword()) :: t()
  def delta(text, opts \\ []) when is_binary(text),
    do: new(:delta, Keyword.put(opts, :payload, text))

  @spec completed(Response.t() | String.t() | map(), keyword()) :: t()
  def completed(response, opts \\ []),
    do: new(:completed, Keyword.put(opts, :payload, Response.new(response)))

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = event) do
    if event.kind in @kinds do
      with :ok <- validate_payload(event),
           :ok <- validate_sequence(event),
           :ok <- validate_metadata(event) do
        Usage.validate(event.usage)
      end
    else
      {:error, :invalid_provider_event_kind}
    end
  end

  def validate(_event), do: {:error, :invalid_provider_event}

  defp validate_sequence(%__MODULE__{provider_sequence: nil}), do: :ok

  defp validate_sequence(%__MODULE__{provider_sequence: sequence})
       when is_integer(sequence) and sequence >= 0,
       do: :ok

  defp validate_sequence(_event), do: {:error, :invalid_provider_event_sequence}

  defp validate_metadata(%__MODULE__{usage_quality: quality, metadata: metadata})
       when quality in [nil, :provider, :estimated, :unavailable] and is_map(metadata) and
              not is_struct(metadata),
       do: :ok

  defp validate_metadata(%__MODULE__{usage_quality: quality})
       when quality not in [nil, :provider, :estimated, :unavailable],
       do: {:error, :invalid_provider_event_usage_quality}

  defp validate_metadata(_event), do: {:error, :invalid_provider_event_metadata}

  defp validate!(event) do
    case validate(event) do
      :ok ->
        event

      {:error, reason} ->
        raise ArgumentError, "invalid provider stream event: #{inspect(reason)}"
    end
  end

  defp validate_payload(%__MODULE__{kind: :delta, payload: payload})
       when is_binary(payload) do
    if String.valid?(payload), do: :ok, else: {:error, :invalid_provider_event_payload}
  end

  defp validate_payload(%__MODULE__{kind: :completed, payload: %Response{} = response}),
    do: Response.validate(response)

  defp validate_payload(%__MODULE__{kind: :failed, payload: payload}) when not is_nil(payload),
    do: :ok

  defp validate_payload(%__MODULE__{kind: kind}) when kind in [:started, :usage], do: :ok
  defp validate_payload(_event), do: {:error, :invalid_provider_event_payload}
end
