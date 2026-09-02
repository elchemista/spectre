defmodule Spectre.Genesis.Verifier.Allowlist do
  @moduledoc """
  Minimal verifier for deployments whose trust ceremony is managed externally.

  It accepts only attestation references explicitly configured by the host.
  This module proves allowlist membership, not signature validity or physical
  isolation, and should be described that way in the governed surface report.
  """

  @behaviour Spectre.Genesis.Verifier

  @impl true
  def verify(genesis, opts) do
    allowed = Keyword.get(opts, :attestation_refs, [])

    if is_list(allowed) and genesis.attestation_ref in allowed,
      do: :ok,
      else: {:error, :genesis_attestation_not_recognized}
  end
end
