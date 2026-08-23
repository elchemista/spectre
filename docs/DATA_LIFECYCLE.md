# Instance data lifecycle

Spectre owns the lifecycle of canonical Instance state, but a deployment may
copy related data across several host adapters. A deletion request is complete
only when the operator has inventoried every configured and host-owned copy.
`Spectre.erase_instance/3` coordinates the core-visible subset; it is not a
whole-person compliance certificate.

## Data map

| Data | Typical identity | Owner | Core erasure coverage |
| --- | --- | --- | --- |
| Canonical Instance checkpoint | stable and legacy `Instance.Ref` keys | `CheckpointStore` | yes; durable anti-resurrection markers |
| Journal records | exact Instance Ref | `Journal.Store` | yes when `erase_instance/2` is configured |
| Pending required-receipt payloads | content-addressed payload refs in the checkpoint outbox | `Receipt.Sink` | yes when `delete_payload/2` is configured |
| Delivered receipt records | receipt id and Instance ref inside the envelope | host receipt ledger | no; apply the ledger's retention/erasure policy |
| Application State and Memory | application-defined Subject identity | host adapters | no |
| Definition artifacts | Definition ref, shared by many Instances | `Definition.Store` | no; never delete by Subject alone |
| Telemetry, logs, traces, exports | deployment-defined correlation | observability systems | no |
| Replicas and backups | store/deployment-defined | infrastructure | no; retain tombstones through the stale-writer window |
| Provider-side prompts and responses | provider request identity | provider/host | no |

Journal and receipt adapters must bind their private indexes to the exact
Instance Ref. Subject values are intentionally not passed to erasure callbacks.
Definition artifacts are shared and therefore stay outside subject erasure.

## Retention responsibilities

The host must define retention for every row in the map, including delivered
receipt envelopes after their temporary outbox payload has been deleted.
Deleting a checkpoint does not discover data copied to an application store,
analytics system, provider, export, replica, or backup. Keep the checkpoint
erasure marker longer than every stale writer and backup that could otherwise
reintroduce the Instance.

Use `Spectre.Privacy.erasure_plan/3` during deployment validation. It performs
no adapter I/O and reports whether maintenance ownership and the configured
journal, receipt-payload, and checkpoint callbacks are present. `Spectre.Doctor`
exposes the same callback posture as read-only operational checks.

See [Offline Instance erasure](ERASURE.md) for the execution and reconciliation
runbook.
