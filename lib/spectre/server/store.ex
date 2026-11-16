defmodule Spectre.Server.Store do
  @moduledoc """
  Durable coordination storage with compare-and-swap revision fencing.

  A successful mutation acknowledges a durable, atomic acquisition of the
  entire value. Implementations must reject nonportable values and distinguish
  an absent key from an unavailable or corrupt store. A checkpoint adapter can
  acquire its inbox, state and command outbox as one value.
  """

  @type entry :: %{revision: pos_integer(), value: term()}
  @callback fetch(term(), term()) :: {:ok, entry()} | :not_found | {:error, term()}
  @callback put_new(term(), term(), term()) :: {:ok, pos_integer()} | {:error, term()}
  @callback compare_and_swap(term(), term(), pos_integer(), term()) ::
              {:ok, pos_integer()} | {:error, term()}
  @callback delete(term(), term(), pos_integer()) :: :ok | {:error, term()}

  @doc "Reads one byte- and count-bounded page of a tuple-key namespace. Cursors are opaque and exclusive."
  @callback list(term(), tuple(), keyword()) ::
              {:ok, [{term(), entry()}], term() | nil} | {:error, term()}
  @optional_callbacks list: 3

  @doc """
  Optionally supplies the canonical GAM ledger used by Managed `storage: :ledger`.

  This is a separate append-only contract, not the mutable coordination rows.
  Returning a backend does not grant authority or enable it for existing disk
  Domains. Adapters without this capability may return `:not_configured`.
  """
  @callback gam_ledger(term()) ::
              {:ok, Spectre.GAM.Ledger.Store.config()} | :not_configured | {:error, term()}
  @optional_callbacks gam_ledger: 1

  @doc """
  Supplies the Domain's canonical history and disposable persisted read model.

  Both resources describe the same Domain namespace. The projection is derived
  only from ledger-verified transitions, never a replacement source of authority.
  Older adapters may continue implementing only `gam_ledger/1`.
  """
  @callback gam_domain(term()) ::
              {:ok,
               %{
                 ledger: Spectre.GAM.Ledger.Store.config(),
                 projection: Spectre.GAM.Domain.Projection.Store.config()
               }}
              | :not_configured
              | {:error, term()}
  @optional_callbacks gam_domain: 1
end
