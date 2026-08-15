# ADR 0006: Inference content and extension security boundaries

Status: accepted

## Context

Streaming makes provider text visible before the complete reply has passed the
ordinary sanitizer, policy and Action path. Legacy EEx prompt assets can also
interpolate runtime data into a base fragment with instruction trust, and
model-planned Action arguments previously relied only on an optional host
guard.

## Decision

### Provisional stream content

Every delta is explicitly `content_class: :provisional` when the incremental
sanitizer is enabled, or `:unsanitized` when the host opts out. A bounded
finite-state sanitizer handles control tags, comments and line markers split
across arbitrary transport chunks. It never promotes a delta to a deliverable
reply. The complete response still passes the normal full-response sanitizer,
Action planner and policy path before `%Spectre.Result{}` commits.

Observer events contain no text. Provider request ids, cursors, credentials,
raw failures and adapter metadata do not enter public events or receipts.

### Prompt trust and provenance

`Spectre.Input.Source` carries a closed trust class plus provenance and
authenticity evidence. Missing legacy evidence defaults to `:untrusted` and
authentication metadata never promotes content automatically. Effect results
carry equivalent evidence for later prompt materialization.

Canonical prompt fragments remain closed templates. The
`spectre.renderer.data/1` renderer and `Spectre.Prompt.data/1` escape dynamic
values inside an explicit data boundary. `Spectre.Doctor` audits legacy
`.text.heex` assets and warns when `@input`, `@recent_chat` or `@memory` is
interpolated without that boundary. The EEx asset form must use the fully
qualified `Spectre.Prompt.data/1` call because asset evaluation does not inject
a `Prompt` alias. This remains a staged compatibility control:
legacy EEx is not claimed to be intrinsically safe, and operators should make
the Doctor warning release-blocking before enabling untrusted traffic.

### Action arguments

Immediately before provider execution, model-planned arguments are validated
against the exact provider spec selected by schema hash. The core implements a
bounded JSON-Schema subset with limits for schema bytes, depth, properties,
enum/combinator cardinality and regular-expression work. A schema that signals
unsupported validation features fails closed. Legacy discovery-only maps such
as `%{arity: 2, version: 1}` retain their previous meaning.

This validation does not replace domain authorization. Host `before_action`
guards and provider-side checks still enforce subject ownership, monetary
limits, destination allowlists and other business invariants.

### Availability and control

- stream sessions are capped per Instance and node;
- buffers, deltas, responses, sanitizer lookahead and terminal retention are
  bounded;
- control commands are bearer-authorized and revision-fenced;
- restart, cancel and steering never reuse a stale generation or epoch;
- a consumer that never attaches and an Instance that dies both terminate the
  provider lifecycle explicitly.

## Non-goals

The core does not use an LLM-based prompt-injection detector, infer trust from
content, authorize a subscriber, or guarantee that a downstream model follows
the data marker. Admission classifiers and egress allowlists belong in narrow
packages using existing Input, Router, Action and Effect seams.
