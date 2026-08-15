# Migrating canonical Instance checkpoints from v2 to v3

The format remains `"spectre/instance-checkpoint"`. The current writer emits
checkpoint/state schema 3 and the reader accepts tagged checkpoint versions 2
and 3. Retired untagged 0.2.x formats are still rejected.

## New canonical sections

Version 3 adds:

- `inference_control` — revision-fenced cancel/steer commands;
- `inference_progress` — bounded text-free latest-value snapshots;
- `receipt_outbox` — bounded pointers for required receipt delivery.

When a v2 checkpoint is decoded, all three sections are created at revision
zero with empty values. Existing sections and their revisions are preserved.

New transitions use transition schema 2 and carry pre/post semantic state
digests. Existing transition schema 1 journal records remain readable. The
semantic state root excludes journal, applied-change cache and receipt outbox,
so receipt delivery acknowledgements do not change the state they prove.

Retained Run blobs inside the `runs` section are decoded through the Run v3
reader. A v2 Instance can therefore contain v1/v2 Run blobs and still migrate
in one restore operation.

## Required receipt mode

Checkpoint v3 does not enable receipts automatically. `receipt_mode` defaults
to `:disabled`.

Before selecting `:required`, configure:

- a durable `Spectre.Instance.CheckpointStore`;
- a `Spectre.Receipt.Sink` implementing append, lookup and content-addressed
  payload callbacks;
- retention for payload objects referenced by the outbox;
- alerting for pending/ambiguous outbox entries and checkpoint reconciliation.

An in-memory sink or Checkpoint Store is not durable merely because it passes
the structural conformance suite.

## Deployment procedure

1. Freeze and checksum real v2 checkpoint samples.
2. Run `Spectre.Foundation.Conformance.verify_checkpoint/1` and
   `verify_instance_checkpoint/2` with the new reader.
3. Quiesce v2 writers for each shared namespace. Version 2 readers cannot read
   v3 output.
4. Deploy all owners capable of claiming the same Instance before allowing a
   v3 write.
5. Restore representative active, boundary, Effect-awaiting and ready Runs.
   Confirm explicit recovery classification and no idle-shutdown leak.
6. Enable the observer lane, streaming and receipt modes independently. Their
   canonical sections may exist while each feature is disabled.
7. Keep the v2 backups until rollback is no longer required; a v3 writer does
   not downgrade in place.

## Capacity changes

Every canonical checkpoint serializes all sections. Configure bounded
`inference_progress_limit` and `receipt_outbox_limit`; do not use the observer
section for deltas. Provider recovery cursors remain inside the confidential
Run checkpoint and are size-limited separately.

Use `Spectre.Foundation.Conformance.matrix/0` as the executable source of truth
for writer/reader versions rather than inferring compatibility from the
application version.
