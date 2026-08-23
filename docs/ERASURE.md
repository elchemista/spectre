# Offline Instance erasure

`Spectre.erase_instance/3` is an offline, fenced coordinator for the data that
core can identify from one Instance. It requires the exact stable Instance key
as confirmation, refuses a live local Instance, acquires a non-preemptive
maintenance lease, and re-observes the checkpoint before the first mutation.

## Preflight

Build the read-only plan before draining anything:

```elixir
ref = Spectre.Instance.Ref.new(MyApp.SupportAgent, account_subject)

{:ok, plan} =
  Spectre.Privacy.erasure_plan(MyApp.SupportAgent, account_subject,
    checkpoint_store: MyApp.Checkpoints,
    owner: MyApp.InstanceOwner,
    journal: MyApp.Journal,
    receipt_sink: MyApp.Receipts
  )

true = plan.ready
[:journal, :receipt_payloads, :checkpoint] = plan.order
```

The plan only inspects configuration and exported callbacks. It never reads a
store, starts an Instance, acquires a lease, or deletes data. Run the Owner,
Checkpoint Store, Journal erasure, and Receipt Sink conformance suites in
isolated namespaces; the plan does not prove adapter durability.

## Execution order

After draining and stopping the Instance on every node, execute with the same
adapter configurations used by production:

```elixir
{:ok, proof} =
  Spectre.erase_instance(MyApp.SupportAgent, account_subject,
    checkpoint_store: MyApp.Checkpoints,
    owner: MyApp.InstanceOwner,
    journal: MyApp.Journal,
    receipt_sink: MyApp.Receipts,
    confirm: ref.key
  )
```

Core preflights every configured capability before mutation, then performs:

1. `Journal.Store.erase_instance/2` for stable and applicable legacy Refs;
2. `Receipt.Sink.delete_payload/2` for every distinct payload ref retained in
   the canonical required-receipt outbox;
3. `CheckpointStore.erase/3` for stable and applicable legacy keys, followed
   by independent marker read-back.

The proof has `scope: :configured_instance_data` and reports each component's
outcome and count. Its receipt component covers pending outbox payloads only;
delivered receipt records and all other host-owned data remain in the data map.

## Adapter requirements

Journal erasure must be idempotent and scoped to the supplied Ref:

```elixir
@callback erase_instance(Spectre.Instance.Ref.t(), keyword()) ::
            {:ok, :erased | :already_erased} | {:error, term()}
```

Receipt payload deletion must be idempotent and content-addressed:

```elixir
@callback delete_payload(String.t(), keyword()) ::
            {:ok, :deleted | :not_found} | {:error, term()}
```

Checkpoint erasure must atomically compare the observed revision and digest,
install a durable marker, reject later CAS writes, and expose that marker via
`erasure_status/2`. A marker for a previously absent key is intentional: it
records a deletion request and prevents later creation under that identity.

## Partial results and retry

The coordinator is fail-closed but cannot make independent stores
transactional. Once a component has been deleted, a later failure returns
`{:ambiguous, {:instance_erasure_partial, completed, reason}}`. Do not restore
completed components. Reconcile the failing adapter from its own durable
state, then retry the same Instance erasure; every callback and checkpoint
marker is idempotent.

After checkpoint success, `Spectre.summon/1` and supervised Instance startup
return `:instance_erased`. Re-admission requires an explicit host migration or
new Subject identity; deleting the marker to make a fresh Instance is outside
the core API and invalidates the anti-resurrection guarantee.

See [Instance data lifecycle](DATA_LIFECYCLE.md) for the stores that remain the
host's responsibility.
