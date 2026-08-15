defmodule Spectre.Receipt.OutboxEntry do
  @moduledoc false

  alias Spectre.Receipt.Envelope
  alias Spectre.Run.Value

  @enforce_keys [:id, :digest, :payload_ref, :status, :inserted_revision]
  defstruct [
    :id,
    :digest,
    :payload_ref,
    :inserted_revision,
    :last_error_class,
    status: :pending,
    attempts: 0
  ]

  @type t :: %__MODULE__{}

  @spec new(Envelope.t(), String.t(), non_neg_integer()) :: t()
  def new(%Envelope{} = envelope, payload_ref, revision)
      when is_binary(payload_ref) and payload_ref != "" and is_integer(revision) and revision >= 0 do
    %__MODULE__{
      id: envelope.id,
      digest: Envelope.digest(envelope),
      payload_ref: payload_ref,
      inserted_revision: revision,
      status: :pending
    }
  end

  @spec validate(t()) :: :ok | {:error, term()}
  # Outbox pointers are the recovery barrier for receipt delivery; their
  # complete portable shape is reviewed at one boundary.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = entry) do
    cond do
      not valid_receipt_id?(entry.id) ->
        {:error, :invalid_receipt_outbox_id}

      not valid_digest?(entry.digest) ->
        {:error, :invalid_receipt_outbox_digest}

      entry.payload_ref != "receipt-payload:" <> entry.digest ->
        {:error, :invalid_receipt_outbox_payload_ref}

      not is_integer(entry.inserted_revision) or entry.inserted_revision < 0 ->
        {:error, :invalid_receipt_outbox_revision}

      entry.status not in [:pending, :ambiguous] ->
        {:error, :invalid_receipt_outbox_status}

      not is_integer(entry.attempts) or entry.attempts < 0 ->
        {:error, :invalid_receipt_outbox_attempts}

      not is_nil(entry.last_error_class) and
          (not is_atom(entry.last_error_class) or is_boolean(entry.last_error_class)) ->
        {:error, :invalid_receipt_outbox_error_class}

      true ->
        Value.validate(entry, [:receipt_outbox])
    end
  end

  def validate(_entry), do: {:error, :invalid_receipt_outbox_entry}

  defp valid_receipt_id?("receipt:" <> digest), do: valid_digest?(digest)
  defp valid_receipt_id?(_id), do: false

  defp valid_digest?(<<digest::binary-size(64)>>),
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_digest?(_digest), do: false
end
