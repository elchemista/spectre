# Choose storage and handle recovery

Start by asking **what you are storing**. Chat history, execution history and
private payloads have different jobs.

You can choose the backends. Spectre does not require ETS, a particular database,
or a bundled long-term memory service.

## Three stores, three jobs

| You need to keep… | Use this boundary | Example |
| --- | --- | --- |
| Governed history | `Spectre.Ledger.Store` | Permission decisions, Attempts, Outcomes and Duties |
| Application state | `Spectre.Store` | A local draft, published Definition or Instance checkpoint |
| Referenced content | `Spectre.Payload.Store` | Verify that an external document/audio blob exists and matches its digest |

The payload-store contract verifies content; your application implements actual
ingestion and deletion. Chat uses the separate `Spectre.History` contract,
and relevant knowledge uses `Spectre.Memory`.

One database may support several adapters, but implementing one contract does
not automatically implement the others.

Deleting old chat is not the same as deleting an unresolved Duty.

## Ledger adapters and batch reads

Choose a ledger backend according to the durability your application needs:

| Adapter | Good to know before choosing it |
| --- | --- |
| ETS | Volatile. Losing its owner loses the history. Compression does not make it durable. |
| Disk | Synced local append with checksummed frames. Needs a dedicated directory and suitable filesystem guarantees. |
| Mnesia | Transactional storage. Your application provisions the schema, copies and cluster. |
| Postgres | Uses your existing Repo. Your application supplies the driver, migration and database configuration. |
| Mock | Injects failures around another adapter for tests; not a production durability backend. |

### Which options belong to the backend?

There are two separate steps:

1. Start or provision the storage service.
2. Connect the Domain to it.

For ETS/Disk, supervise the owner, then pass `{Module, server: address}`.
Mnesia uses your schema/tables. PostgreSQL uses your already supervised Repo;
neither needs an ETS-style owner PID.

#### ETS and Disk

| Option | Meaning |
| --- | --- |
| `name` | Optional OTP registration for the store process |
| `server` | The running owner used in Domain wiring |
| `compressed: false` | Opt into compression when useful; it trades some CPU for space |
| Call `timeout` | How long the caller waits; a timeout does not establish whether an append committed |
| Disk `directory` (alias `path`) | Required dedicated directory with exclusive store ownership |
| Disk `tail_policy: :reject` | Reject an incomplete final frame; `:truncate` explicitly allows incomplete-tail recovery only |
| Disk `max_frame_bytes: 67_108_864` | 64 MiB per-frame bound, not a total ledger or RAM limit |

These owners also accept ordinary GenServer startup options:
`timeout`, `debug`, `spawn_opt`, `hibernate_after`.
Startup timeout is not a provider timeout.

#### Mnesia

Defaults are `storage: :disc_copies`, `nodes: [node()]` and
`wait_timeout: 30_000`. `:disc_only_copies` is also supported.

The three table options default to:

- `heads_table: :spectre_ledger_heads`;
- `batches_table: :spectre_ledger_batches`;
- `entries_table: :spectre_ledger_entries`.

Use distinct tables for distinct storage configurations. Start and provision
the Mnesia schema before calling `Spectre.Ledger.Store.Mnesia.ensure_tables/1`.
That helper creates the required tables, not your cluster.

#### PostgreSQL

Supply `repo: YourApp.Repo`. Spectre does not import Ecto or a PostgreSQL
driver, and does not start the Repo.

The defaults are `schema: "public"`, `table_prefix: "spectre_ledger"`,
`query_opts: []` and `transaction_opts: []`.
`query_module` defaults to the host-supplied `Ecto.Adapters.SQL`; a compatible
query adapter can replace it.

Generate and review a migration in the host project:

```sh
mix spectre.gen.postgres_ledger_migration
```

The task generates a file; your normal Repo workflow applies it. Optional
`--migrations-path`, `--schema` and `--table-prefix` select its location
and names. Keep the adapter settings and migration names identical.

Mnesia and PostgreSQL also accept `compressed: false` for stored entry bytes.
Compression preserves the canonical data and its digests.

### Writing another ledger adapter

Required callbacks are `append/5`, `load/2`, `lookup_batch/3` and `export/2`.

The important promises are:

- a batch becomes visible atomically;
- a write checks the exact expected revision;
- repeating a batch identity only succeeds for the same intended content;
- success means the backend's advertised durability boundary was reached;
- uncertainty about a write is reported as uncertainty.

The revision check is **compare-and-swap (CAS)**: “write this only if the
current revision is still the revision I read.” A conflict means another
writer changed it; it does not authorize repeating an external effect.

Optional `load_from/3` reads a suffix. `head/2` plus `read_batch/3` provide
indexed batch paging. Implement them with bounded reads, not a full load
followed by slicing.

A Reader captures a head and reads complete batches up to it. Concurrent new
appends do not keep extending that read. A missing batch before the captured
head is corruption, not the end of the stream.

These callbacks are not a persistent projection-checkpoint API.

## Commit, ambiguity and recovery

### Normal operation

Spectre checks the new batch, writes it, and confirms its exact receipt before
using the prepared state. It does not replay all history or check every old
payload after each successful append.

### The database connection disappears during a write

The backend may have committed the batch before the connection was lost.
Return `{:error, :ambiguous}` if that cannot be established.

Spectre checks durable state before releasing execution capability. It does
not treat its in-memory prepared result as proof of a commit.

This differs from a payment-service timeout: discovering whether a ledger
batch exists can resolve a write ambiguity. Repeating a payment cannot safely
resolve an effect ambiguity.

### The Domain starts after a restart

Cold recovery verifies the records, their chain, the permitted transitions,
the recognized foundation and currently live external payload references.

Batch paging limits the read buffer. The rebuilt projection still accumulates
its state. When a verified prefix is already in memory, recovery can read the
new suffix instead.

Disk's `:truncate` option only permits recovery of an incomplete final frame.
It does not permit dropping checksummed corruption, wrong-Domain records or
invalid semantic history. Preserve original files before operator-led repair.

## If someone edits the database

Malformed records, broken links, missing batches and impossible transitions
must stop verification. A partially decoded history is not usable authority.

There is also a limit to what a digest chain proves. Someone who can rewrite
the whole store and recompute a consistent chain may create a history that
passes internal checks. The chain alone cannot show that the export is the
latest one either.

Spectre does not supply ledger signatures or an independent head witness.
Your deployment can keep an independently trusted reference to the accepted
history and authenticate its storage.

### Connect your incident policy

Use `recovery_policy: {MyPolicy, options}`:

| Callback | What it can do |
| --- | --- |
| `check/2` | Reject a recovered head that disagrees with an independent witness |
| Optional `failed/2` | Queue an alert, quarantine or operator recovery action |

The callback receives the Domain identity and recovered/last verified head as
appropriate. Before first bootstrap, the head can be `nil`.
A higher revision alone does not prove continuation from your witnessed head.

Callbacks run in isolation with `recovery_timeout` (default 5,000 ms).
Runtime failure notification does not delay the failing sequencer.
Notifications are best effort, may repeat, and are not a durable incident log.

A policy cannot replace rejected state or override core verification.
Repair the underlying problem, then restart and verify again.

The live Domain trusts its already verified prefix. Periodic independent
audits are how you check for later edits to old stored bytes.

## Payloads, retention and erasure

### Keep erasable content out of inline history

For content that may need independent deletion, store the bytes externally
and use a verified payload reference.

`Spectre.Payload.Store.verify/2` checks presence and the content digest.
Normal incremental work checks introduced or relevant recovered-live references,
plus applicable use-time checks—not every historical blob on every append.

Cold startup checks all live references. With a remote store, that may mean
many calls, so measure recovery time with the actual backend.
There is no sampling option that treats unchecked content as verified.

### Who decides when to delete?

Your application owns retention policy, shared-payload consumer tracking,
scheduling, backups and the deletion implementation.

`Spectre.Payload.Retention.request/4` helps plan a request from the host's
last-use time/revision and `after_ms` / `after_events` thresholds.
When both are supplied, both must elapse. A hold retains the payload.

The planner does not delete anything or grant permission.

### What does Spectre record?

`Spectre.request_erasure/4` submits the deletion through normal authority
checks. The executor deletes the bytes and reports its observations.

An admitted request does not prove deletion. An uncertain Attempt may leave
presence unknown; a definitive no-effect result can make the payload live again.

The causal history and any Duty for reduced verifiability remain.
Resolve that Duty through its authorized, independent route.

Deleting a blob does not delete inline ledger text, provider copies, logs or
backups. Compression is not erasure. These mechanisms are not a legal-compliance
certificate.

## Application state is separate

Use `Spectre.Store` for a portable draft or checkpoint. It has per-key revision
checks; it is not an authority ledger.

This example saves a draft, deletes it, then refuses a stale writer:

<!-- spectre:example application_store -->
```elixir
{:ok, owner} = Spectre.Store.Memory.start_link()
store = {Spectre.Store.Memory, server: owner}

try do
  {:ok, 1} = Spectre.Store.compare_and_swap(store, "draft", 0, %{"text" => "hello"})
  {:ok, 1, %{"text" => "hello"}} = Spectre.Store.get(store, "draft")
  {:ok, 2} = Spectre.Store.delete(store, "draft", 1)
  {:deleted, 2} = Spectre.Store.get(store, "draft")
  {:error, :conflict} = Spectre.Store.compare_and_swap(store, "draft", 1, %{})
after
  GenServer.stop(owner)
end
```

The numbers are revisions:

- revision 0 means the key has not been written;
- the first save returns revision 1;
- deletion advances to revision 2;
- a writer still expecting revision 1 gets a conflict.

Keeping the deletion revision prevents an old writer from accidentally
recreating the deleted value.

The supplied Memory store uses compressed, volatile ETS. A durable backend
can implement the same callbacks.

`Definition.Store` publishes immutable Definitions but does not activate one
in a Domain. An Instance checkpoint saves local state, not authentication,
request tickets or execution credentials.

## Clock, overload and memory

### Time

The clock guard compares wall time with monotonic elapsed time from boot.
The default `clock_tolerance_ms: 60_000` rejects excessive drift. Small accepted
backward movements do not move ledger time backward.

A long idle interval is not, by itself, a clock jump.
`:infinity` disables the guard and should be an explicit host trust decision.
Initial time and independent restarts still need trustworthy host clocks.

### Too much concurrent work

Ingress defaults to 32 concurrent jobs and a 30-second callback timeout.
The submission queue defaults to 1,024 entries.

These are specific bounds, not a limit on every mailbox, query or allocation.
Some calls wait indefinitely by default. Set host timeouts and load limits
for your application; never interpret a caller timeout as proof of no commit.

### Long-lived memory

The host owns storage infrastructure and application retention.
Spectre owns the memory used by its internal projection.

That projection currently retains historical records and indexes. Compression
and paging help other costs but do not make it bounded. Switching from ETS to
PostgreSQL for the ledger does not externalize the projection.

General durable projection checkpoints and revision-fenced public pagination
are not implemented. A short chat/Mind window does not substitute for them.
See [current limits](capabilities.md#still-missing-or-requiring-consolidation).

## Export and audit

Audit checks a captured history without trusting the running projection:

```sh
mix spectre.audit domain.spectre
mix spectre.audit domain.spectre --at 1735689600000
```

The file is an export created with `Spectre.Audit.Export`. It includes the
canonical ledger, pinned Constitution and trusted capture time.

`--at` asks what is due at a later Unix-millisecond timestamp. It must not
precede capture.

Missing Duties already required at capture are errors. Causes becoming due
only later are reported in `pending_duty_causes`, separately from recorded
`open_duties`. Later dispatch expiry is also reported separately.

Audit does not extend or repair the export. A successful result means the
captured records are consistent under the stated trust assumptions—not that
every external assertion is independently proven.
