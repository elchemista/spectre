defmodule Spectre.Audit do
  @moduledoc """
  Independent driver for semantic verification of a Domain ledger export.

  The driver verifies the exported hash chain itself and never consumes a live
  Domain projection. It then invokes the same pure Governed Act fold used by
  recovery, followed by whole-history checks at the trusted capture time.
  A later observation time may expose additional obligations, but cannot make
  an immutable export acquire new Duty or dispatch-cancellation records.
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

  This strict form treats `audited_at` as both capture and observation time:
  every obligation required by then must be materialized. Use `verify/4` for
  an export captured earlier. Neither time can precede the newest durable
  acquisition time. Structural, transition and whole-history failures remain
  distinct in the returned error so callers can diagnose the failed boundary.
  """
  @spec verify(Ledger.snapshot() | map(), map(), non_neg_integer()) ::
          {:ok, report()} | {:error, term()}
  def verify(snapshot, constitution, audited_at),
    do: verify(snapshot, constitution, audited_at, audited_at)

  @doc """
  Verifies completeness at `captured_at` and observes that prefix at `audited_at`.

  Both times are supplied by a trusted host; `audited_at >= captured_at`.
  Missing Duties or cancellations already required at capture remain errors.
  Later obligations are reported separately as `pending_duty_causes` and
  `expired_dispatches`, never inserted into the ledger or counted as recorded
  open Duties. The report says nothing about events outside this prefix.
  """
  @spec verify(Ledger.snapshot() | map(), map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, report()} | {:error, term()}
  def verify(snapshot, constitution, captured_at, audited_at)
      when is_map(constitution) and not is_struct(constitution) and
             is_integer(captured_at) and captured_at >= 0 and
             is_integer(audited_at) and audited_at >= 0 do
    with :ok <- Constitution.validate(constitution),
         {:ok, verified} <- verify_ledger(snapshot),
         :ok <- audit_time_covers_ledger(verified, captured_at),
         :ok <- observation_covers_capture(captured_at, audited_at),
         {:ok, state} <- fold(verified, constitution),
         :ok <- validate_integrity(state, captured_at) do
      Report.build(state, captured_at, audited_at)
    end
  end

  def verify(_snapshot, _constitution, _captured_at, _audited_at),
    do: {:error, :invalid_semantic_audit_input}

  defp observation_covers_capture(captured_at, audited_at) do
    if audited_at >= captured_at,
      do: :ok,
      else: {:error, {:audit_time_precedes_capture, audited_at, captured_at}}
  end

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
