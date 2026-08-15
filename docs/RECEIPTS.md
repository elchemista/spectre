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

The payload store is intentionally outside the canonical checkpoint. The
outbox contains only receipt id, envelope digest and a content-addressed
reference. Hosts must retain payload objects at least as long as an outbox
entry or receipt chain can reference them.

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
end
```

Run `Spectre.Receipt.Sink.Conformance.run/1` against an isolated sink instance.
The conformance suite verifies append, exact idempotency, lookup and payload
round-trip. It cannot certify database durability, transactions, retention,
encryption, tenancy or deployment topology.

## Privacy and claims

Receipt payloads are portable and validated. Public envelopes reject values
recognized by Spectre's sensitive-data policy. Confidential payloads still
require encryption and access control in the sink. Raw provider metadata,
credentials, errors, request ids and cursors are not receipt content.

The deterministic envelope id excludes delivery time and payload location; it
binds boundary identity, payload digest, state roots and lineage. Instance
receipts use `recorded_at` as a logical canonical coordinate.

Receipt capture plus state roots proves boundary evidence linkage. It does not
prove deterministic replay, exactly-once provider work or exactly-once external
Effects. Those claims remain false until separately verified.
