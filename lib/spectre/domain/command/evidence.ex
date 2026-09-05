defmodule Spectre.Domain.Command.Evidence do
  @moduledoc """
  Idempotently records observed or derived Evidence.

  Input shape is normalized once, duplicate identities must be byte-equivalent,
  and every payload is applied provisionally before append. A successful result
  always comes from the recovered ledger projection, never from caller input.
  """

  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.{Event, Transaction}
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Evidence

  @doc "Records one Evidence value or an ordered non-empty list."
  @spec record(
          State.t(),
          Evidence.t() | [Evidence.t()] | term(),
          non_neg_integer()
        ) ::
          {:ok, State.t(), Evidence.t() | [Evidence.t()]} | {:error, State.t(), term()}

  def record(state, input, minimum_recorded_at \\ 0) do
    record_with_retries(state, input, state.conflict_retries, minimum_recorded_at)
  end

  defp record_with_retries(state, input, conflicts_left, minimum_recorded_at) do
    with {:ok, evidence, shape} <- normalize(input),
         {:ok, current_time} <- Transaction.trusted_recorded_at(state),
         now = max(current_time, minimum_recorded_at),
         :ok <- evidence_not_future(evidence, now),
         {:ok, payloads} <- evidence_payloads(state.projection, evidence) do
      if payloads == [] do
        recovered_evidence(state, state.projection, evidence, shape)
      else
        append_evidence(
          state,
          evidence,
          shape,
          payloads,
          conflicts_left,
          now
        )
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  @doc "Normalizes input while preserving whether the caller supplied one or many records."
  @spec normalize(Evidence.t() | [Evidence.t()] | term()) ::
          {:ok, [Evidence.t()], :one | :many} | {:error, term()}
  def normalize(%Evidence{} = evidence) do
    with {:ok, evidence} <- Evidence.new(evidence), do: {:ok, [evidence], :one}
  end

  def normalize(evidence) when is_list(evidence) and evidence != [] do
    evidence
    |> Enum.reduce_while({:ok, [], %{}}, fn input, {:ok, records, seen} ->
      with {:ok, record} <- Evidence.new(input),
           :ok <- evidence_ref_available(seen, record) do
        {:cont, {:ok, [record | records], Map.put(seen, record.ref, record)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records, _seen} -> {:ok, Enum.reverse(records), :many}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_input), do: {:error, :invalid_evidence_input}

  defp evidence_ref_available(seen, record) do
    case Map.fetch(seen, record.ref) do
      :error ->
        :ok

      {:ok, existing} ->
        if existing == record,
          do: :ok,
          else: {:error, {:evidence_identity_conflict, record.ref}}
    end
  end

  defp evidence_not_future(evidence, now) do
    case Enum.find(evidence, &(&1.observed_at > now)) do
      nil -> :ok
      record -> {:error, {:evidence_from_future, record.ref, record.observed_at}}
    end
  end

  defp evidence_payloads(projection, evidence) do
    evidence
    |> Enum.uniq_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, payloads} ->
      case evidence_payload(projection, record) do
        {:ok, nil} -> {:cont, {:ok, payloads}}
        {:ok, payload} -> {:cont, {:ok, [payload | payloads]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      {:error, _reason} = error -> error
    end
  end

  defp evidence_payload(projection, record) do
    case Map.fetch(projection.evidence, record.ref) do
      :error ->
        Event.record(:evidence, record)

      {:ok, existing} ->
        if existing == record,
          do: {:ok, nil},
          else: {:error, {:evidence_identity_conflict, record.ref}}
    end
  end

  defp append_evidence(
         state,
         evidence,
         shape,
         payloads,
         conflicts_left,
         recorded_at
       ) do
    input = shaped(evidence, shape)

    Commit.append(
      state,
      payloads,
      recorded_at,
      conflicts_left,
      &recovered_evidence(state, &1, evidence, shape),
      &record_with_retries(&1, input, &2, recorded_at)
    )
  end

  defp recovered_evidence(state, projection, evidence, shape) do
    case fetch_recovered_evidence(projection, evidence) do
      {:ok, records} ->
        {:ok, %{state | projection: projection}, shaped(records, shape)}

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, reason}
    end
  end

  defp fetch_recovered_evidence(projection, evidence) do
    Enum.reduce_while(evidence, {:ok, []}, fn expected, {:ok, records} ->
      case recovered_evidence_record(projection, expected) do
        {:ok, durable} -> {:cont, {:ok, [durable | records]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp recovered_evidence_record(projection, expected) do
    case Map.fetch(projection.evidence, expected.ref) do
      {:ok, durable} ->
        if durable == expected,
          do: {:ok, durable},
          else: {:error, {:evidence_identity_conflict, expected.ref}}

      :error ->
        {:error, {:evidence_not_recovered, expected.ref}}
    end
  end

  defp shaped([record], :one), do: record
  defp shaped(records, :many), do: records
end
