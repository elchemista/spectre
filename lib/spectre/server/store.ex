defmodule Spectre.Server.Store do
  @moduledoc """
  AgentServer storage with compare-and-swap coordination and optional GAM storage.

  A successful mutation acknowledges a durable, atomic acquisition of the
  entire value. Implementations must reject nonportable values and distinguish
  an absent key from an unavailable or corrupt store. A checkpoint adapter can
  acquire its inbox, state and command outbox as one value.

  A provider can implement this one behaviour for coordination, canonical GAM
  history and its disposable persisted read model. Configure it with
  `gam: [storage: :ledger, store: {MyStorage, reference}]`. The same opaque
  reference is passed first to every callback. The host owns that reference and
  its lifecycle; selecting storage never starts another provider or database.

  The unified history group consists of `ledger_append/6`, `ledger_load/3`,
  `ledger_head/3`, `ledger_read_batch/4`, `ledger_lookup_batch/4` and
  `ledger_export/3`. `ledger_load_from/4` is an optional optimization. Implement
  all six `projection_*` callbacks to persist the read model, or omit the whole
  projection group to keep it in memory. Incomplete groups fail before Managed
  bootstrap writes its authority profile.

  These callbacks retain the contracts of `Spectre.GAM.Ledger.Store` and
  `Spectre.GAM.Domain.Projection.Store`: atomic idempotent appends, bounded
  indexed batch reads, generation-fenced projection changes and exact-cursor
  reads. An uncertain append acknowledgement is `{:error, :ambiguous}`. A
  projection is rebuilt from verified history and never supplies authority.
  Sharing a provider does not promise one transaction spanning the checkpoint,
  history and projection. Each resource keeps its own durability barrier.

  Existing `gam_domain/1` and `gam_ledger/1` adapters remain supported.
  `gam_domain/1` takes precedence; when absent or `:not_configured`, a unified
  callback group is selected before the history-only `gam_ledger/1` fallback.
  """

  alias Spectre.GAM.Domain.Projection.Store, as: ProjectionStore
  alias Spectre.GAM.Ledger

  @type store_ref :: term()
  @type entry :: %{revision: pos_integer(), value: term()}

  @doc "Reads the value and current revision for a key. Return `:not_found` for an absent key."
  @callback fetch(store_ref(), term()) :: {:ok, entry()} | :not_found | {:error, term()}

  @doc "Inserts a value atomically and returns its revision. Return `{:error, :exists}` when the key is taken."
  @callback put_new(store_ref(), term(), term()) :: {:ok, pos_integer()} | {:error, term()}

  @doc "Replaces a value at the expected revision. Return the new revision or `{:error, :conflict}` on a mismatch."
  @callback compare_and_swap(store_ref(), term(), pos_integer(), term()) ::
              {:ok, pos_integer()} | {:error, term()}

  @doc "Deletes a key at the expected revision. Return `{:error, :conflict}` when the revision cannot be matched."
  @callback delete(store_ref(), term(), pos_integer()) :: :ok | {:error, term()}

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

  @doc "Atomically appends one idempotent history batch after the expected revision."
  @callback ledger_append(
              store_ref(),
              Ledger.domain_ref(),
              Ledger.batch_id(),
              [map()],
              non_neg_integer(),
              keyword()
            ) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Loads a coherent canonical history snapshot; absence is distinct from failure."
  @callback ledger_load(store_ref(), Ledger.domain_ref(), keyword()) ::
              :not_found | {:ok, Ledger.snapshot()} | {:error, term()}

  @doc "Optionally loads the suffix after a verified complete-batch revision."
  @callback ledger_load_from(store_ref(), Ledger.domain_ref(), non_neg_integer(), keyword()) ::
              :not_found | {:ok, Ledger.snapshot()} | {:error, term()}

  @doc "Reads the committed history cursor without loading historical entries."
  @callback ledger_head(store_ref(), Ledger.domain_ref(), keyword()) ::
              :not_found | {:ok, Ledger.cursor()} | {:error, term()}

  @doc "Reads one complete, indexed history batch beginning at the requested revision."
  @callback ledger_read_batch(store_ref(), Ledger.domain_ref(), pos_integer(), keyword()) ::
              :not_found | {:ok, Ledger.snapshot()} | {:error, term()}

  @doc "Looks up the committed identity and cursor of an idempotent history batch."
  @callback ledger_lookup_batch(store_ref(), Ledger.domain_ref(), Ledger.batch_id(), keyword()) ::
              :not_found | {:ok, Ledger.batch_info()} | {:error, term()}

  @doc "Exports one coherent canonical history snapshot in the GAM ledger format."
  @callback ledger_export(store_ref(), Ledger.domain_ref(), keyword()) ::
              :not_found | {:ok, map()} | {:error, term()}

  @doc "Opens a fresh disposable projection generation, fencing earlier generations."
  @callback projection_open(store_ref(), String.t(), keyword()) ::
              {:ok, ProjectionStore.handle()} | {:error, term()}

  @doc "Reads the current projection generation and cursor."
  @callback projection_head(store_ref(), String.t(), keyword()) ::
              {:ok, %{handle: ProjectionStore.handle(), cursor: Ledger.cursor()}}
              | :not_found
              | {:error, term()}

  @doc "Atomically applies derived row changes and advances their exact predecessor cursor."
  @callback projection_commit(
              store_ref(),
              ProjectionStore.handle(),
              Ledger.cursor(),
              Ledger.cursor(),
              Enumerable.t(),
              keyword()
            ) :: :ok | {:error, term()}

  @doc "Fetches canonical row bytes at the exact projection generation and cursor."
  @callback projection_fetch(
              store_ref(),
              ProjectionStore.handle(),
              Ledger.cursor(),
              [ProjectionStore.key()],
              keyword()
            ) :: {:ok, %{optional(ProjectionStore.key()) => binary()}} | {:error, term()}

  @doc "Reads a count- and byte-bounded collection page at an exact projection cursor."
  @callback projection_page(
              store_ref(),
              ProjectionStore.handle(),
              Ledger.cursor(),
              atom(),
              keyword()
            ) :: {:ok, [{ProjectionStore.key(), binary()}], term() | nil} | {:error, term()}

  @doc "Reads an indexed projection selection with count and byte bounds."
  @callback projection_select(
              store_ref(),
              ProjectionStore.handle(),
              Ledger.cursor(),
              atom(),
              keyword(),
              keyword()
            ) :: {:ok, [{ProjectionStore.key(), binary()}], term() | nil} | {:error, term()}

  @optional_callbacks ledger_append: 6,
                      ledger_load: 3,
                      ledger_load_from: 4,
                      ledger_head: 3,
                      ledger_read_batch: 4,
                      ledger_lookup_batch: 4,
                      ledger_export: 3,
                      projection_open: 3,
                      projection_head: 3,
                      projection_commit: 6,
                      projection_fetch: 5,
                      projection_page: 5,
                      projection_select: 6
end
