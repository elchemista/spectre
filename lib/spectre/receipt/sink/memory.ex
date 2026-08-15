defmodule Spectre.Receipt.Sink.Memory do
  @moduledoc """
  Process-backed receipt sink for development, tests, and conformance suites.

  Pass `server: pid_or_name` in sink options. Duplicate ids with identical
  envelopes are idempotent; a divergent envelope is rejected.
  """

  @behaviour Spectre.Receipt.Sink

  alias Spectre.Receipt.Envelope

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{receipts: %{}, payloads: %{}} end, Keyword.take(opts, [:name]))
  end

  @impl true
  def append(%Envelope{} = envelope, opts) do
    Agent.get_and_update(server(opts), fn state ->
      case Map.fetch(state.receipts, envelope.id) do
        :error ->
          receipts = Map.put(state.receipts, envelope.id, envelope)
          {{:ok, :appended}, %{state | receipts: receipts}}

        {:ok, ^envelope} ->
          {{:ok, :idempotent}, state}

        {:ok, _different} ->
          {{:error, :receipt_id_conflict}, state}
      end
    end)
  end

  @impl true
  def lookup(id, opts) do
    case Agent.get(server(opts), &Map.get(&1.receipts, id)) do
      %Envelope{} = envelope -> {:ok, envelope}
      nil -> :not_found
    end
  end

  @impl true
  def put_payload(%Envelope{} = envelope, opts) do
    ref = Spectre.Receipt.Sink.payload_ref(envelope)

    Agent.get_and_update(server(opts), fn state ->
      case Map.fetch(state.payloads, ref) do
        :error -> {{:ok, ref}, put_in(state, [:payloads, ref], envelope)}
        {:ok, ^envelope} -> {{:ok, ref}, state}
        {:ok, _different} -> {{:error, :receipt_payload_conflict}, state}
      end
    end)
  end

  @impl true
  def get_payload(ref, opts) do
    case Agent.get(server(opts), &Map.get(&1.payloads, ref)) do
      %Envelope{} = envelope -> {:ok, envelope}
      nil -> :not_found
    end
  end

  @spec all(keyword()) :: [Envelope.t()]
  def all(opts), do: opts |> server() |> Agent.get(&Map.values(&1.receipts))

  defp server(opts), do: Keyword.fetch!(opts, :server)
end
