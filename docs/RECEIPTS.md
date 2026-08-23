# Boundary receipts

`Spectre.Receipt.Envelope` is the provider-neutral evidence record for an
admitted input, nondeterministic output or authority decision. It links the
boundary to pre/post canonical state digests and immutable Definition/closure
identity. It does not record every internal mutation and does not replace the
domain receipt carried as its typed payload.

## Configure delivery

Receipts are disabled by default. Observational mode appends after the
canonical boundary and never blocks the Run:

```elixir
{:ok, sink} = Spectre.Receipt.Sink.Memory.start_link()

{:ok, instance} =
  Spectre.Instance.start_link(
    agent: MyApp.Agent,
    subject: subject,
    receipt_mode: :observational,
    receipt_sink: {Spectre.Receipt.Sink.Memory, server: sink}
  )
```

Required mode also needs a durable Checkpoint Store. Its sink must implement
content-addressed payload callbacks:

```elixir
receipt_mode: :required,
receipt_sink: {MyApp.ReceiptSink, tenant: tenant_id},
checkpoint_store: {MyApp.InstanceCheckpoints, tenant: tenant_id},
receipt_outbox_limit: 256
```

The required sequence is payload staging, boundary plus outbox commit,
checkpoint durability barrier, idempotent sink append, then a canonical outbox
acknowledgement. Recovery drains pending required entries before conflicting
admission. A lost append acknowledgement is reconciled with `lookup/2`.

For a live Instance, pending delivery does not by itself reject another
admission. New work may queue while the durable boundary is in flight; only an
outbox at `receipt_outbox_limit` fails closed with `:receipt_outbox_full`.
This keeps admission independent of ordinary sink latency while preserving the
canonical boundary barrier.
Checkpoint restore and reconciliation validate the outbox against that same
configured limit rather than a separate fixed default.

The payload store is intentionally outside the canonical checkpoint. The
outbox contains only receipt id, envelope digest and a content-addressed
reference. Hosts must retain payload objects at least as long as an outbox
entry or receipt chain can reference them, and garbage-collect unreferenced
staging objects. A process failure after payload staging but before the outbox
commit can leave such an object behind.

## Implement a sink

```elixir
defmodule MyApp.ReceiptSink do
  @behaviour Spectre.Receipt.Sink

  @impl true
  def append(envelope, opts) do
    # Insert by envelope.id. An exact duplicate returns :idempotent;
    # the same id with different bytes is a conflict.
  end

  @impl true
  def lookup(id, opts), do: :not_found

  @impl true
  def put_payload(envelope, opts) do
    {:ok, Spectre.Receipt.Sink.payload_ref(envelope)}
  end

  @impl true
  def get_payload(ref, opts), do: :not_found

  @impl true
  def delete_payload(ref, opts), do: {:ok, :not_found}
end
```

Run `Spectre.Receipt.Sink.Conformance.run/1` against an isolated sink instance.
The conformance suite verifies append, exact idempotency, lookup, payload
round-trip, idempotent deletion, and deletion read-back. The deletion callback
is used by offline Instance erasure for payloads still retained in the required
outbox; see [Offline Instance erasure](ERASURE.md). The suite cannot certify
database durability, transactions, retention, encryption, tenancy, or
deployment topology.

## Privacy and claims

Receipt payloads are portable and validated. Every Instance-produced receipt
applies Spectre's constitutional key denylist before its payload digest is
computed, including for confidential receipts; redacted paths are recorded in
metadata without retaining the values. Public envelopes additionally reject
any sensitive value that reaches the generic envelope API. Ordinary admitted
input and model output remain confidential evidence, so confidential payloads
still require encryption and access control in the sink. Raw provider
metadata, credentials, errors, request ids and cursors are not receipt
content.

The deterministic envelope id excludes delivery time and payload location; it
binds boundary identity, payload digest, state roots and lineage. `recorded_at`
is always Unix time in milliseconds. Canonical ordering uses the separate
`canonical_revision` field. This identity is distinct from
`Spectre.Receipt.Envelope.digest/1`: the latter covers the complete serialized
envelope, including `recorded_at`, and therefore also determines
`Spectre.Receipt.Sink.payload_ref/1`. A retry before a durable outbox commit may
stage a second object under a different full-envelope digest; after the outbox
commit, recovery reuses the exact persisted digest and reference.

Receipt capture plus state roots proves boundary evidence linkage. It does not
prove deterministic replay, exactly-once provider work or exactly-once external
Effects. Those claims remain false until separately verified.

Schema v1 deliberately has no generic `:canonical_commit` receipt. Canonical
pre/post state roots travel on the receipt for the nondeterministic or authority
boundary that caused the commit; routine internal mutations are not duplicated
as history entries. The kind name is reserved for a future schema that defines
an emitter and verifier together, and schema v1 rejects it explicitly.
