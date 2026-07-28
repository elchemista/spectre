defmodule Spectre.Journal do
  @moduledoc """
  Privacy-safe public journal boundary for optional Spectre extensions.

  Extension records accept operational metadata only. Message bodies,
  addresses, provider payloads, and credentials are rejected before they reach
  the configured journal store.
  """

  @sensitive_keys [
    :text,
    :message,
    :prompt,
    :reply,
    :phone,
    :address,
    :chat_id,
    :token,
    :api_key,
    :secret,
    :payload,
    :credentials
  ]

  @spec record(module(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def record(agent, event, metadata, opts \\ [])
      when is_atom(agent) and is_atom(event) and is_map(metadata) and is_list(opts) do
    with :ok <- validate_metadata(metadata) do
      Spectre.Journal.Recorder.record_extension(agent, event, metadata, opts)
    end
  end

  @spec validate_metadata(map()) :: :ok | {:error, term()}
  defp validate_metadata(metadata) do
    case Enum.find(Map.keys(metadata), &sensitive_key?/1) do
      nil -> :ok
      key -> {:error, {:sensitive_journal_metadata, key}}
    end
  end

  @spec sensitive_key?(term()) :: boolean()
  defp sensitive_key?(key) when is_atom(key), do: key in @sensitive_keys

  defp sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_keys, &(Atom.to_string(&1) == normalized))
  end

  defp sensitive_key?(_key), do: false
end
