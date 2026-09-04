defmodule Spectre.Audit do
  @moduledoc """
  Independent driver for semantic verification of a Domain ledger export.

  The driver verifies the exported hash chain itself and never consumes a live
  Domain projection. It then invokes the same pure Governed Act fold used by
  recovery, followed by whole-history checks at the caller-supplied audit time.
  Sharing the pure semantics prevents runtime/auditor drift without sharing
  runtime state or trusting the sequencer.

  Genesis and host attestations remain visible trust anchors: a successful
  report does not claim to prove deployment isolation or an attestation scheme
  external to the ledger.
  """

  alias Spectre.Audit.Report
  alias Spectre.{Constitution, Ledger}
  alias Spectre.GovernedAct.{Fold, Integrity}

  @type report :: Report.t()

  @doc """
  Verifies a complete ledger snapshot against its pinned Constitution.

  `audited_at` is trusted audit time and cannot precede the newest durable
  acquisition time. Structural, transition and whole-history failures remain
  distinct in the returned error so callers can diagnose the failed boundary.
  """
  @spec verify(Ledger.snapshot() | map(), map(), non_neg_integer()) ::
          {:ok, report()} | {:error, term()}
  def verify(snapshot, constitution, audited_at)
      when is_map(constitution) and not is_struct(constitution) and
             is_integer(audited_at) and audited_at >= 0 do
    with :ok <- Constitution.validate(constitution),
         {:ok, verified} <- verify_ledger(snapshot),
         :ok <- audit_time_covers_ledger(verified, audited_at),
         {:ok, state} <- fold(verified, constitution),
         :ok <- validate_integrity(state, audited_at),
         {:ok, report} <- Report.build(state, audited_at) do
      {:ok, report}
    end
  end

  def verify(_snapshot, _constitution, _audited_at),
    do: {:error, :invalid_semantic_audit_input}

  defp verify_ledger(snapshot) do
    verification =
      if is_map(snapshot) and not is_struct(snapshot) and Map.has_key?(snapshot, "format"),
        do: Ledger.verify(snapshot),
        else: Ledger.verify_snapshot(snapshot)

    case verification do
      {:ok, verified} -> {:ok, verified}
      {:error, reason} -> {:error, {:ledger_integrity_failed, reason}}
    end
  end

  defp audit_time_covers_ledger(%{entries: []}, _audited_at), do: :ok

  defp audit_time_covers_ledger(%{entries: entries}, audited_at) do
    latest = entries |> List.last() |> Map.fetch!(:recorded_at)

    if audited_at >= latest,
      do: :ok,
      else: {:error, {:audit_time_precedes_ledger, audited_at, latest}}
  end

  defp fold(snapshot, constitution) do
    case Fold.replay_verified(snapshot.domain_ref, snapshot.entries, constitution) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:semantic_violation, %{reason: reason}}}
    end
  end

  defp validate_integrity(state, audited_at) do
    case Integrity.validate(state, audited_at) do
      :ok -> :ok
      {:error, reason} -> {:error, {:semantic_audit_incomplete, reason}}
    end
  end
end
