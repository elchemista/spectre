# Storage, recovery and operations

Spectre has three different store boundaries. Implementing one does not satisfy
the others. All are host-selectable; ETS is not a required deployment backend.

| Boundary | Stores or checks | Guarantee required |
| --- | --- | --- |
| `Spectre.Ledger.Store` | Canonical, append-only Domain batches | Atomic visibility, exact revision CAS, batch identity and truthful durability acknowledgement |
| `Spectre.Store` | Portable application values, Definition publication, Instance checkpoints | Per-key CAS and retained deletion revisions; not authority |
| `Spectre.Payload.Store` | External content referenced by `payload:<sha256>` | Presence and digest correspondence; not the actual ingestion/deletion implementation |

## Ledger adapters and batch reads

| Adapter | Implementation boundary | Deployment caveat |
| --- | --- | --- |
| `Spectre.Ledger.Store.ETS` | Volatile owner with granular records and batch indexes; optional compression | Owner loss loses history; not suitable for durable obligations |
| `Spectre.Ledger.Store.Disk` | Checksummed canonical frames and synced append; compressed indexes, optional frame compression | Local filesystem durability and exclusive directory ownership still matter |
| `Spectre.Ledger.Store.Mnesia` | Atomic Mnesia transactions with configured tables/copies | The host provisions schema, copies, availability and cluster fencing |
| `Spectre.Ledger.Store.Postgres` | Transactional append/CAS using the application's Repo | The host provides Repo/driver, migration, credentials, database settings and backups |
| `Spectre.Ledger.Store.Mock` | Fault injection around another ledger adapter | Test double, not a durability backend |

Spectre does not import Ecto or a PostgreSQL driver. Run
`mix spectre.gen.postgres_ledger_migration` in the host project, review the
generated migration and apply it through your Repo's normal workflow. The task
does not migrate the database itself. Its options include `--migrations-path`,
`--schema` and `--table-prefix`; the adapter and migration must use matching names.

An adapter implements `append/5`, `load/2`, `lookup_batch/3` and `export/2`.
Optional `load_from/3` supports suffix reads; `head/2` plus `read_batch/3`
provide native, indexed batch paging. These are real callbacks, not an already
implemented persistent projection-snapshot API.

`Spectre.Ledger.Reader` captures a head and verifies one complete batch at a time.
Concurrent appends do not extend that traversal indefinitely. Missing a batch
before the captured head is corruption, not a successful end of stream. A
caller starting after Genesis must already have a verified predecessor.
Never split an atomic batch across semantic validation or release capability
from a partially traversed prefix.

## Commit, ambiguity and recovery

Normal append prepares and folds the new batch once, then confirms its exact
durable receipt before adopting the prepared state. It does not recheck every
old payload or replay the entire prefix after every successful append.
CAS conflict or uncertain confirmation enters recovery rather than pretending
the prepared state is committed. A stored batch identifier must match the exact
intended content; identity collisions are errors, not idempotent success.

The store must return `{:error, :ambiguous}` if it cannot establish whether an
append committed. The Domain resolves durable state before releasing a Grant.
An ambiguous append and an ambiguous external effect are different incidents:
the latter cannot be resolved by rerunning the executor.

At cold startup, Spectre verifies canonical/chain and semantic validity, the
recognized Genesis, required materializations and all currently live external
payload references. Native paging bounds the ledger input buffer to batches;
it does not bound the accumulated projection. Existing in-memory verified
prefixes permit incremental recovery without trusting arbitrary checkpoint data.

Disk's default `tail_policy: :reject` rejects an incomplete final frame.
Explicit `:truncate` may recover only that incomplete tail. Checksum, canonical,
Domain/batch identity and semantic failures are not permission to discard
committed data. Preserve the original file before operator-led repair.

## If someone edits the database

A malformed record, broken chain, missing batch or impossible transition must
fail verification. Recovery must not return a usable authority state and continue
dispatching from whatever could be decoded. Preserve the last verified head
and diagnose the original failure.

A hash chain cannot detect a complete, internally consistent rewrite by a party
able to rewrite the entire store, or prove that a valid export is the latest
prefix. Spectre currently supplies neither ledger signatures nor an external
head witness. Deploy independent anchors and authenticated storage according
to your threat model; a digest is not a signature.

Configure `recovery_policy: {MyPolicy, options}` for application-owned handling:

- `check/2` runs after core verification with Domain identity and recovered head
  (or nil before first bootstrap). It can reject an unexpected rollback or
  missing Domain using an independently maintained witness. A larger revision
  alone does not prove descent from a witnessed head.
- Optional `failed/2` receives the phase, reason and last verified head. Use it
  to enqueue quarantine, operator notification or backup recovery. Its return
  cannot replace state or override a failed check.
- Callbacks are isolated and bounded by `recovery_timeout` (default 5,000 ms).
  Runtime failure notification does not delay the failing sequencer. Notifications
  are best effort and can repeat; they are not a durable incident log.

Repair belongs to the host. Restart and verify again after repair. Do not edit
history to make an audit pass, drop an open Duty or infer no effect from a
missing receipt. The running Domain trusts its verified prefix; independent
audits are needed to detect later tampering with old storage bytes.

## Payloads, retention and erasure

Prefer protected external payloads for content that may need deletion.
`Spectre.Payload.Store.verify/2` checks content-addressed bytes at the host
boundary. Cold startup checks every live reference; incremental work checks
introduced/recovered-live references and relevant use-time references. Unrelated
historical payloads are not polled on every append.

For remote stores, cold start can therefore require many remote checks. Budget
and measure recovery time with actual external references. There is no option
to declare an unverified payload valid by sampling a few others. Use separate
storage health monitoring between uses.

`Spectre.Payload.Retention.request/4` plans an erasure request from host-supplied
last-use time/revision and retention thresholds (`after_ms`, `after_events`).
When both thresholds are supplied, both must elapse; a hold retains the payload.
The host tracks all consumers of a shared payload and schedules the check.
This planner neither deletes bytes nor establishes authority. Host code writes
the original payload and supplies its verified reference; a governed erasure
executor performs deletion and supplies observations.

`Spectre.request_erasure/4` records the request through normal authority checks.
An admitted request alone does not prove deletion. An Attempt can make presence
uncertain; a definitive no-effect result can make the original payload live
again. Erasure lineage, unavailable evidence and the resulting verifiability
Duty are retained. Resolve that Duty through its independent authorized route.

Deleting an external blob does not delete inline ledger data, provider copies,
logs or backups. Metadata and hashes may remain sensitive. Compression is
lossless storage reduction, not erasure or anonymization. These are technical
mechanisms, not a legal-compliance certification; the host owns retention policy
and its legal assessment. See [the governed surface](../GOVERNED_SURFACE.md).

## Application state is separate

`Spectre.Store` encodes portable values and validates adapter responses.
Deletion retains a revision fence, so stale writers cannot resurrect a deleted
value. `Spectre.Store.Memory` uses compressed volatile ETS. A durable application
backend can implement the same callbacks without changing the ledger adapter.

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

`Spectre.Definition.Store` publishes immutable Definitions; it does not select a
governed head. `Spectre.Instance.Checkpoint` saves application Mind state; it is
not a Domain snapshot. No application CAS value can restore authority or a
reusable execution credential.

## Clock, overload and memory

`Spectre.Clock.Guard` anchors wall time against monotonic elapsed time at boot.
The default `clock_tolerance_ms: 60_000` rejects excessive backward/forward
drift and an incompatible recovered future prefix. Small accepted regressions
are clamped for nondecreasing ledger time. An idle interval is not itself a
clock jump. `:infinity` disables the guard; use it only with an explicit trust
decision. The initial clock reading and independent restarts still need external
trust and monitoring.

Current ingress work has configurable concurrency and callback timeouts
(`ingress_max_concurrency`, default 32; `ingress_timeout`, default 30,000 ms).
Submission buffering has `max_pending_submissions` (default 1,024). These limits
are not global mailbox backpressure: not every query/control path is bounded,
and many calls default to waiting indefinitely. A caller timeout never proves
that the command did not commit. Do not automatically retry a world action on it.

Compression and indexed reads reduce storage/CPU costs but do not provide a
bounded-history runtime. The sequencer's verified State still accumulates
historical facts/indexes. Moving a whole State into one ETS row would merely
relocate that cost. Granular current-state persistence, verified durable
projection checkpoints and fully paginated public queries remain release work.
Recent Mind windows are not a substitute for those changes.

## Export and audit

`Spectre.Audit.Export` packages a canonical ledger, pinned Constitution and
trusted capture time. `Spectre.Audit` verifies it without the live projection.
For a previously created export file:

```sh
mix spectre.audit domain.spectre
mix spectre.audit domain.spectre --at 1735689600000
```

`--at` must not precede capture. Missing Duties already required at capture are
errors. New causes due only at the later observation time are reported in
`pending_duty_causes`, separately from recorded `open_duties`; later dispatch
expiration is reported separately too. Audit does not repair or extend the
export. Successful verification establishes internal consistency under its
trust assumptions, not truth of every issuer's assertion.
