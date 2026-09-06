# Authority selection microbenchmark — 2026-09-06

Command: `mix run bench/authority_reads.exs`.

Working tree based on `bf1578b`, with the incremental AuthorityIndex and
operation-specific authority reads. Elixir 1.20.2, OTP 29.0.1 with JIT,
Intel Core Ultra 5 125H, 18 available schedulers. Benchee: 0.2s warmup,
1s latency, 0.2s allocation, 0.2s reductions per job/input, parallelism 1.
This is a short local diagnostic with substantial timing variance, **not** P1
or release qualification. No Dialyzer/test run was launched alongside this run;
the machine was not otherwise isolated from background activity.

## What was measured

Both jobs resolve the same implicit Candidate request against the same typed
State. One builds exhaustive `Authority.Facts.from_state/1`; the other selects
the complete proposer branches with `Authority.Facts.for_candidate/2`. Exact
equality of the resulting authority is asserted before measurement, as is
equality of indexed and exhaustive full authority views.

There is one eligible Mandate. The independent input axes add either disposed
containment Duties or Mandates held by another principal. Setup exercises the
index's issue/open/dispose updates. Records are generated fixtures, **not an
authenticated ledger**, and no durable admission or independent disposition
authority is benchmarked. The test suite separately checks real ledger prefixes.

## Results

Benchee reduction figures are rounded as printed. Latency is median per
read-plus-resolution, expressed in microseconds, not per governed agent cycle.

| History | Count | Exhaustive median µs | Selected median µs | Exhaustive reductions | Selected reductions |
| --- | ---: | ---: | ---: | ---: | ---: |
| Closed Duties | 0 | 11.87 | 12.78 | 2.23 K | 2.23 K |
| Closed Duties | 1000 | 62.79 | 12.65 | 12.20 K | 2.14 K |
| Closed Duties | 10000 | 650 | 22.6 | 102.15 K | 2.14 K |
| Foreign Mandates | 0 | 12.88 | 20.95 | 2.23 K | 2.23 K |
| Foreign Mandates | 1000 | 7640 | 21.1 | 1.30 M | 2.14 K |
| Foreign Mandates | 10000 | 94020 | 12.7 | 13.04 M | 2.14 K |

At 10000 closed Duties, measured allocation per operation drops from 573.24 KiB
to 26.29 KiB. Benchee measures allocation in the query worker; it is not total
retained memory or a Sequencer heap sample. The selected authority fact value's
flattened term size is 1640 bytes for all these inputs.

The foreign-Mandate case exposes more than a map scan: the exhaustive resolver
tries to authorize each unrelated Mandate. The new selector does not choose an
authority; it excludes other holders before that work, retains complete ancestry,
and still returns ambiguity when multiple held Mandates are eligible.

## Limits and next step

- Historical State is still retained. Its flattened term size is about 9.0 MB
  with 10000 closed Duties and 13.5 MB with 10000 foreign Mandates. These sizes
  count shared subterms repeatedly and are not exclusive physical RAM.
- The active authority index remains 488 flattened bytes in the closed-Duty
  lane, but reaches 622720 bytes with 10000 foreign Mandates. The holder index
  retains references to historical Mandates; it is not bounded storage.
- A request with many Mandates held by its own proposer still needs to examine
  them, and deeper ancestry costs more. This is not constant-cost authorization
  for arbitrary relevant authority graphs.
- Latency has a long tail: selected closed-Duty/10000 p99 was 1.64 ms despite
  a 22.6 µs median; mean 48.6 µs, deviation ±472.89%. Work and allocation are
  approximately flat here, **not all latency**. Heap/GC pressure remains to be
  addressed by the granular current-state backend and bounded Sequencer state.
- The empty-history case can be slightly slower because it builds a small
  detached view; no promise is made of lower latency on every input.

The result closes an authority-read history scan, not the architectural work
on persistence, checkpoint recovery, current-state storage or long-lived agents.
