defmodule Spectre.Receipt.Sink.Conformance do
  @moduledoc "Adapter-neutral checks for the idempotent receipt sink contract."

  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.Sink

  @spec run(Sink.config()) :: {:ok, map()} | {:error, term()}
  def run(config) do
    with {:ok, sink} <- Sink.normalize(config),
         envelope <- fixture(),
         {:ok, :appended} <- Sink.append(sink, envelope, []),
         {:ok, duplicate} when duplicate in [:appended, :idempotent] <-
           Sink.append(sink, envelope, []),
         {:ok, ^envelope} <- Sink.lookup(sink, envelope.id, []),
         :not_found <- Sink.lookup(sink, envelope.id <> ":missing", []),
         {:ok, payload_ref} <- Sink.put_payload(sink, envelope, []),
         true <- payload_ref == Sink.payload_ref(envelope),
         {:ok, ^envelope} <- Sink.get_payload(sink, payload_ref, []),
         {:ok, :deleted} <- Sink.delete_payload(sink, payload_ref, []),
         :not_found <- Sink.get_payload(sink, payload_ref, []),
         {:ok, :not_found} <- Sink.delete_payload(sink, payload_ref, []) do
      {:ok,
       %{
         append: :verified,
         idempotency: :verified,
         lookup: :verified,
         payload_store: :verified,
         payload_erasure: :verified
       }}
    else
      {:error, reason} -> {:error, {:receipt_sink_conformance_failed, reason}}
      other -> {:error, {:receipt_sink_conformance_failed, other}}
    end
  end

  defp fixture do
    Envelope.new!(
      kind: :nondeterminism_sample,
      correlation_id: "receipt-sink-conformance",
      payload_schema_ref: "spectre.receipt.conformance/1",
      payload: %{sample: 1},
      privacy: :internal
    )
  end
end
