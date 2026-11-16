# Domain memory and storage recovery

Without a projection store, GAM keeps the original complete in-memory projection.
No Ledger package or database is required. `gam: [storage: :ledger]` uses the
configured Ledger resource's canonical history and per-record projection store.
The application owns its Repo and migrations; startup never creates a database.

![Domain memory and storage recovery: architecture](assets/domain-storage-1.svg)

[Diagram source](assets/domain-storage-1.mmd).

This is the projection-backed path. RAM-only operation retains the complete
projection; canonical history remains authoritative in either mode.

## What stays in RAM

With a projection store, the Domain keeps its Genesis authority roots and active
frontiers. For each command it loads the required records and indexed dependency
groups, applies the same pure GAM kernel and Fold, persists changed rows, then
releases historical records. Consumed nonces, old admissions, revocations,
counterproofs and erasure relationships remain queryable; an unloaded record is
not treated as proof of absence. Missing required rows return an error.

There is no mandatory history quota. Active Duties, configured authority and a
command's relevant proof/lineage closure can grow. Full `GAM.view`, projection
and diagnostics calls can materialize complete history temporarily. For archive
pages, use `Projection.Store.page/5` from trusted application code, as shown in
the Ledger guide and `DemoSpectre.History.records/3`.

The Domain remains the serialized owner of admission and commits. Indexed I/O
uses the Repo pool and adapter timeouts; a slow database can delay that Domain.
AgentServer runs governed work in workers, so its ordinary status handling is
separate. Checkpoint durability barriers still wait for storage. This change
does not promise latency independent of the database.

## Custom storage

`Spectre.GAM.Domain.Projection.Store` requires `open/2`, `head/2`, `commit/5`,
`fetch/4`, `page/4` and `select/5`. Selections cover exact groups and ordered
ranges. Each page and record read is fenced by Domain, owner generation and exact
revision; row changes and the cursor commit atomically. Its canonical ledger
must provide native `head/2` and `read_batch/3` for streaming recovery.

Cold startup rebuilds disposable projection rows from verified canonical batches.
A saved cursor is not a trusted snapshot. Canonical history is never deleted by
this rebuild. Existing PostgreSQL projection installations must apply
`Spectre.Ledger.DomainStore.upgrade_sql/1` through an application migration;
the demo includes that migration. Fresh installations use `migration_sql/1`.

## When storage disappears

The default policy waits: failed verification cannot authorize execution.
The Managed owner remains available after a Domain storage failure. The host
can repair storage and retry, or explicitly choose a new RAM Domain. Optional
`recover/2` on `Spectre.GAM.Domain.Recovery.Policy` selects the lifecycle action:

```elixir
defmodule MyApp.StorageRecovery do
  @behaviour Spectre.GAM.Domain.Recovery.Policy

  def check(_verified_head, _options), do: :ok

  # Example application policy. Choose :memory only when losing continuity is
  # acceptable; backups or operator intervention may suit your application.
  def recover(_incident, _options), do: {:retry, 1_000}
end

# Server options:
gam: [storage: :ledger, recovery_policy: MyApp.StorageRecovery]
```

The callback may return `:wait`, `{:retry, milliseconds}` or `:memory`. It runs
with `recovery_timeout` (default 5 seconds). `failed/2` remains a best-effort
notification; its return value never replaces GAM state. Enqueue long repairs
in application supervision instead of performing them in the callback.

The configured consumer may also call
`Spectre.Server.recover_storage(server, :retry | :memory)`. `:retry` rebuilds the
same Domain from verified history; it cannot repair missing canonical batches.
It requires recoverable storage: an ephemeral Domain, including one created by
RAM fallback, returns `:ephemeral_history_cannot_be_recovered` for `:retry`.
`:memory` keeps the running Agent and Managed owner, creates a fresh Domain and
RAM coordination/checkpoint state, and preserves the Agent identity. Old grants,
consents and governed outbox work cannot authorize this fresh Domain. External
effects with uncertain results must be reconciled by the application.

The consumer receives
`{:storage_recovered, %{previous_domain: old, domain: current}}`. There is no
automatic merge or write-back of divergent RAM history when the database returns.
Restore a coherent backup to preserve continuity, or deliberately use a new
Domain after administrative deletion. Loss of arbitrary data cannot be inferred
continuously from a surviving head; verify after database maintenance.

## Application content

The storage contract does not impose a payload hash, encryption or archive.
The top-level `Spectre.Server.start_link/1` option
`payload_store: {MyApp.Payloads, options}` lets the application choose opaque
references and its own backend. See [Payload storage](PAYLOAD_STORAGE.md).
Governance facts remain subject to the existing GAM contracts.
