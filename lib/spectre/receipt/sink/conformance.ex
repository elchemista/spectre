defmodule Spectre.Receipt.Sink.Conformance do
  @moduledoc """
  Adapter-neutral checks for the idempotent receipt sink contract.

  Successful reports distinguish optional payload erasure that is not exported
  from erasure that was verified. Failures identify the exact contract phase so
  adapter authors can diagnose a rejected callback without relying on the
  callback order inside this runner.
  """

  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.Sink

  @type phase ::
          :configuration
          | :append
          | :idempotency
          | :lookup
          | :missing_lookup
          | :payload_store
          | :payload_identity
          | :payload_readback
          | :payload_erasure_capability
          | :payload_neighbor_setup
          | :payload_neighbor_identity
          | :payload_erasure
          | :payload_erasure_readback
          | :payload_neighbor_isolation
          | :payload_erasure_idempotency
          | :payload_neighbor_cleanup

  @type report :: %{
          required(:append) => :verified,
          required(:idempotency) => :verified,
          required(:lookup) => :verified,
          required(:payload_store) => :verified,
          required(:payload_erasure) => :verified | :not_exported,
          required(:payload_neighbor_isolation) => :verified | :not_exported
        }

  @type failure :: {:receipt_sink_conformance_failed, phase(), term()}

  @doc "Runs the receipt and optional payload-erasure contract."
  @spec run(Sink.config()) :: {:ok, report()} | {:error, failure()}
  def run(config) do
    with {:ok, sink} <- normalize_sink(config),
         envelope = fixture("receipt-sink-conformance", 1),
         :ok <- expect(:append, Sink.append(sink, envelope, []), {:ok, :appended}),
         :ok <-
           expect_one_of(
             :idempotency,
             Sink.append(sink, envelope, []),
             [{:ok, :appended}, {:ok, :idempotent}]
           ),
         :ok <- expect(:lookup, Sink.lookup(sink, envelope.id, []), {:ok, envelope}),
         :ok <-
           expect(:missing_lookup, Sink.lookup(sink, envelope.id <> ":missing", []), :not_found),
         {:ok, payload_ref} <- put_payload(sink, envelope, :payload_store),
         :ok <- expect(:payload_identity, payload_ref, Sink.payload_ref(envelope)),
         :ok <-
           expect(
             :payload_readback,
             Sink.get_payload(sink, payload_ref, []),
             {:ok, envelope}
           ),
         {:ok, erasure_report} <- verify_payload_erasure(sink, payload_ref) do
      {:ok,
       Map.merge(erasure_report, %{
         append: :verified,
         idempotency: :verified,
         lookup: :verified,
         payload_store: :verified
       })}
    end
  end

  defp normalize_sink(config) do
    case Sink.normalize(config) do
      {:ok, sink} -> {:ok, sink}
      other -> failure(:configuration, outcome(other))
    end
  end

  defp verify_payload_erasure({module, _opts} = sink, payload_ref) do
    case Sink.payload_erasure_capability(sink) do
      :ok ->
        verify_exact_payload_erasure(sink, payload_ref)

      {:error, {:receipt_sink_callback_missing, ^module, :delete_payload, 2}} ->
        {:ok, %{payload_erasure: :not_exported, payload_neighbor_isolation: :not_exported}}

      {:error, reason} ->
        failure(:payload_erasure_capability, reason)
    end
  end

  defp verify_exact_payload_erasure(sink, payload_ref) do
    neighbor = fixture("receipt-sink-conformance-neighbor", 2)

    with {:ok, neighbor_ref} <- put_payload(sink, neighbor, :payload_neighbor_setup),
         :ok <- distinct_payload_refs(payload_ref, neighbor_ref),
         :ok <-
           expect(
             :payload_neighbor_setup,
             Sink.get_payload(sink, neighbor_ref, []),
             {:ok, neighbor}
           ),
         :ok <-
           expect(
             :payload_erasure,
             Sink.delete_payload(sink, payload_ref, []),
             {:ok, :deleted}
           ),
         :ok <-
           expect(
             :payload_erasure_readback,
             Sink.get_payload(sink, payload_ref, []),
             :not_found
           ),
         :ok <-
           expect(
             :payload_neighbor_isolation,
             Sink.get_payload(sink, neighbor_ref, []),
             {:ok, neighbor}
           ),
         :ok <-
           expect(
             :payload_erasure_idempotency,
             Sink.delete_payload(sink, payload_ref, []),
             {:ok, :not_found}
           ),
         :ok <-
           expect(
             :payload_neighbor_cleanup,
             Sink.delete_payload(sink, neighbor_ref, []),
             {:ok, :deleted}
           ) do
      {:ok, %{payload_erasure: :verified, payload_neighbor_isolation: :verified}}
    end
  end

  defp put_payload(sink, envelope, phase) do
    case Sink.put_payload(sink, envelope, []) do
      {:ok, payload_ref} -> {:ok, payload_ref}
      other -> failure(phase, outcome(other))
    end
  end

  defp distinct_payload_refs(payload_ref, neighbor_ref) do
    if payload_ref == neighbor_ref,
      do: failure(:payload_neighbor_identity, :payload_ref_collision),
      else: :ok
  end

  defp expect(_phase, actual, expected) when actual == expected, do: :ok
  defp expect(phase, actual, _expected), do: failure(phase, outcome(actual))

  defp expect_one_of(phase, actual, expected) do
    if actual in expected, do: :ok, else: failure(phase, outcome(actual))
  end

  defp outcome({:error, reason}), do: reason
  defp outcome(value) when is_atom(value), do: value
  defp outcome(_value), do: :unexpected_outcome

  defp fixture(correlation_id, sample) do
    Envelope.new!(
      kind: :nondeterminism_sample,
      correlation_id: correlation_id,
      payload_schema_ref: "spectre.receipt.conformance/1",
      payload: %{sample: sample},
      privacy: :internal
    )
  end

  defp failure(phase, reason),
    do: {:error, {:receipt_sink_conformance_failed, phase, reason}}
end
