# History growth after incremental read indexes — 2026-09-06

Status: **improved, not a performance go-ahead for release**. The ordinary
execution path no longer repeatedly derives every historical Duty. End-to-end
latency and memory nevertheless still grow with history. The paired experiment
below attributes most of this fixture's remaining latency gap to Sequencer GC.
It does not prove constant cost for all governed workflows.

## Reproduction and scope

```sh
ERL_FLAGS='+S 1:1 +A 1' mix run bench/history_growth.exs --compare --gc
```

Measured on the uncommitted worktree based on `24dba09`, Elixir 1.20.2 / OTP
29.0.1. Dialyzer and the test suite had finished before this run; no concurrent
build/analysis task was running. This is a local single-run diagnostic, not a
cross-machine or before/after release comparison.

The existing P1 fixture uses one long-lived Domain, ETS, individual commits,
one Scope, one Mandate, one authorization condition and no erasures or opened
Duties. Each cycle submits a Candidate, consumes its Grant, records executor
Evidence and records a successful Outcome. No history is reset between samples.

Each row summarizes the segment since the previous checkpoint, not just its
last cycle. `sequencer_bytes` is `Process.info(pid, :memory)`, not total live
data, VM RSS or ETS memory. Reductions are for the Sequencer only.

## Growth series

| Cycles reached | Ledger revision | Mean ms/cycle | p50 ms | p95 ms | p99 ms | Reductions/cycle | Sequencer bytes |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 90 | 8.035 | 5.816 | 28.475 | 28.475 | 431011 | 426616 |
| 50 | 410 | 7.113 | 7.040 | 7.908 | 8.265 | 424229 | 1115200 |
| 100 | 810 | 7.047 | 6.986 | 7.787 | 8.514 | 422568 | 2917936 |
| 150 | 1210 | 5.850 | 5.212 | 7.330 | 10.296 | 421890 | 7637584 |
| 200 | 1610 | 5.611 | 5.212 | 7.872 | 9.425 | 422467 | 4720672 |
| 500 | 4010 | 13.068 | 13.409 | 17.423 | 19.280 | 441202 | 9571336 |
| 1000 | 8010 | 15.804 | 15.571 | 22.790 | 25.193 | 452337 | 7998136 |
| 2000 | 16010 | 21.483 | 20.507 | 31.060 | 36.760 | 474035 | 16583968 |

The mean still rises from 5.611 ms in cycles 151–200 to 21.483 ms in cycles
1001–2000. The much smaller increase in reductions alone is not sufficient to
declare the history-dependent cost solved.

## Paired control and garbage collection

After the growth series, a second Domain runs ten warm-up cycles. Then 64 cycles
on each Domain alternate in the same VM, reversing execution order each pair.
The old Domain starts this comparison with 2000 completed cycles; the young one
with ten. This controls for changing load during the long growth series.

GC tracing is enabled only for this comparison, not the growth series above.
It records minor/major collection start/end timestamps on the two Sequencers;
it does not force collection or change heap settings. Paired timings include
the tracing overhead. Counts cover all 64 measured cycles per Domain.

| Domain | Mean ms/cycle | p50 ms | p95 ms | p99 ms | Minor GC | Major GC | GC ms/cycle |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Young | 6.690 | 6.566 | 8.714 | 9.714 | 3712 | 5 | 0.560 |
| Old | 22.868 | 21.358 | 34.017 | 36.277 | 114 | 57 | 15.022 |

Most of the observed gap is GC time: approximately 14.46 ms of the 16.18 ms
mean difference. The larger retained heap undergoes almost one major collection
per cycle in this run. This is evidence for separating retained history from
temporary command allocation, not evidence for forcing GC after every command.

Cold restart after the comparison: **2683.694 ms**, including replay of the
2064 completed cycles. Native suffix reads accelerate resumption from an
already verified in-memory prefix; they do not yet accelerate cold startup
through persisted snapshots.

## Still open

- Bound the hot state / separate historical records from the Sequencer's heap
  without discarding authority, revocations, counterproof or unresolved Duties.
- Remove remaining exhaustive paths for Duty opening validation, Presentation,
  erasure closure, historical containment and durable adapter operations.
- Re-run P1 individual/group commit with 1/10/100/N proponents and recovery
  under load. This single-proponent ETS diagnostic is not that release gate.
- Add long-history runs with real external payload references and complex
  governance. A configurable Mind context window is not a semantic-history cap.

The full derivation remains the differential-test oracle. Neither the ledger
nor the rules are truncated to the last N entries to achieve these numbers.
