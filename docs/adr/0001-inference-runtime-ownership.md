# ADR 0001: Ownership of inference runtime boundaries

Status: accepted

## Context

Inference used to be a synchronous call hidden inside a conversational Move.
Streaming, cancellation, recovery and durable evidence require a lifecycle
owner, but they do not justify a second Agent runtime or a generic History
subsystem.

Spectre, provider packages such as Prism, and evidence packages such as Ledger
have different responsibilities. Blurring them would let transport state
mutate a Run, or make Spectre depend on one HTTP client or database.

## Decision

The boundaries are:

| Component | Owns | Does not own |
| --- | --- | --- |
| Spectre core | Run/Invocation lifecycle, selection fence, budgets, stream session, demand, cancellation, steering, canonical commits, receipt policy and recovery classification | HTTP/SSE implementation, provider credentials, external receipt persistence |
| Provider adapter | Opening/resuming a provider request, parsing transport data into normalized events, best-effort remote cancellation, provider request/cursor extraction | Run revisions, canonical state, consumer authorization, retry/steering policy |
| Receipt sink | Idempotent payload storage, append and lookup of portable envelopes | Runtime scheduling, Run continuation, provider calls, replay claims |

`Spectre.Invocation.kind` is therefore `:effect | :inference`. Every provider
attempt is one inference Invocation. The Instance commits selection and
dispatch intent before releasing provider work when receipts are required.

The core defines `Spectre.Inference.StreamAdapter` and
`Spectre.Receipt.Sink`. External libraries implement those behaviours without
becoming runtime owners. This repository deliberately contains no Prism
transport and no Ledger backend.

## Consequences

- One-shot and streaming inference use the same Run and Invocation lifecycle.
- A missing provider or sink capability fails closed with a typed error.
- The core can be tested with fake adapters and the in-memory receipt sink.
- Provider request identifiers and resume cursors may exist in confidential
  recovery state, but observer events, telemetry and receipt payloads expose
  only digests.
- `Spectre.Receipt.Sink.Memory` proves the adapter contract, not process or
  database durability.
- Exactly-once external effects and deterministic replay are not implied.

## Rejected alternatives

- Moving stream ownership into a provider package: transport restart would
  bypass Run fences and canonical budgets.
- Broadcasting authoritative deltas through pub/sub: Registry dispatch has no
  demand and cannot bound a slow subscriber's mailbox.
- Adding GenStage/Broadway to the core: one authoritative consumer does not
  justify the dependency or buffering model.
- Adding a generic History subsystem: boundary receipts and state digests are
  sufficient for evidence without recording every internal mutation.
