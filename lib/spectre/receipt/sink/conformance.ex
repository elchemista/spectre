defmodule Spectre.Receipt.Sink.Conformance do
  @moduledoc "Adapter-neutral checks for the idempotent receipt sink contract."

  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.Sink

  @spec run(Sink.config()) :: {:ok, map()} | {:error, term()}
  def run(config) do
    with {:ok, sink} <- Sink.normalize(config),
         envelope <- fixture("receipt-sink-conformance", 1),
         {:ok, :appended} <- Sink.append(sink, envelope, []),
         {:ok, duplicate} when duplicate in [:appended, :idempotent] <-
           Sink.append(sink, envelope, []),
         {:ok, ^envelope} <- Sink.lookup(sink, envelope.id, []),
         :not_found <- Sink.lookup(sink, envelope.id <> ":missing", []),
         {:ok, payload_ref} <- Sink.put_payload(sink, envelope, []),
         true <- payload_ref == Sink.payload_ref(envelope),
         {:ok, ^envelope} <- Sink.get_payload(sink, payload_ref, []),
         {:ok, erasure_report} <- verify_payload_erasure(sink, payload_ref) do
      {:ok,
       Map.merge(erasure_report, %{
         append: :verified,
         idempotency: :verified,
         lookup: :verified,
         payload_store: :verified
       })}
    else
      {:error, reason} -> {:error, {:receipt_sink_conformance_failed, reason}}
      other -> {:error, {:receipt_sink_conformance_failed, other}}
    end
  end

  defp verify_payload_erasure({module, _opts} = sink, payload_ref) do
    case Sink.payload_erasure_capability(sink) do
      :ok ->
        verify_exact_payload_erasure(sink, payload_ref)

      {:error, {:receipt_sink_callback_missing, ^module, :delete_payload, 2}} ->
        {:ok, %{payload_erasure: :not_exported, payload_neighbor_isolation: :not_exported}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_exact_payload_erasure(sink, payload_ref) do
    neighbor = fixture("receipt-sink-conformance-neighbor", 2)

    with {:ok, neighbor_ref} <- Sink.put_payload(sink, neighbor, []),
         false <- neighbor_ref == payload_ref,
         {:ok, ^neighbor} <- Sink.get_payload(sink, neighbor_ref, []),
         {:ok, :deleted} <- Sink.delete_payload(sink, payload_ref, []),
         :not_found <- Sink.get_payload(sink, payload_ref, []),
         {:ok, ^neighbor} <- Sink.get_payload(sink, neighbor_ref, []),
         {:ok, :not_found} <- Sink.delete_payload(sink, payload_ref, []),
         {:ok, :deleted} <- Sink.delete_payload(sink, neighbor_ref, []) do
      {:ok, %{payload_erasure: :verified, payload_neighbor_isolation: :verified}}
    end
  end

  defp fixture(correlation_id, sample) do
    Envelope.new!(
      kind: :nondeterminism_sample,
      correlation_id: correlation_id,
      payload_schema_ref: "spectre.receipt.conformance/1",
      payload: %{sample: sample},
      privacy: :internal
    )
  end
end
