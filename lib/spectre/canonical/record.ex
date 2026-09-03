defmodule Spectre.Canonical.Record do
  @moduledoc """
  Strict restoration boundary for durable Spectre records.

  Ledger values are canonical, string-keyed maps. A transition restores such a
  value through the record module's `from_canonical/1` callback exactly once;
  governed code then works with the returned struct. This module intentionally
  provides no atom-or-string field lookup and no fallback constructor.

  Record modules are passed explicitly because the set of governed event types
  is closed by `Spectre.Domain.Event`; discovering an arbitrary decoder must
  never extend kernel authority.
  """

  @type restored :: %{required(:ref) => String.t(), optional(atom()) => term()}

  @doc "Restores a record using its strict canonical decoder."
  @spec decode(module(), term()) :: {:ok, struct()} | {:error, term()}
  def decode(module, canonical) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :from_canonical, 1) do
      module.from_canonical(canonical)
    else
      _unavailable -> {:error, {:record_decoder_unavailable, module}}
    end
  end

  def decode(module, _canonical), do: {:error, {:record_decoder_unavailable, module}}

  @doc "Returns the already-restored record reference."
  @spec ref(restored()) :: String.t()
  def ref(%{ref: ref}) when is_binary(ref) and ref != "", do: ref

  @doc "Requires an event identity to equal its restored record reference."
  @spec match_identity(String.t(), restored() | String.t()) ::
          :ok | {:error, :domain_event_identity_mismatch}
  def match_identity(identity, %{ref: identity}) when is_binary(identity), do: :ok
  def match_identity(identity, identity) when is_binary(identity), do: :ok
  def match_identity(_identity, _record), do: {:error, :domain_event_identity_mismatch}
end
