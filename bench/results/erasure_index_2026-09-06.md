# Incremental erasure availability — 2026-09-06

Comparison against `498307d`, using the same growing Domain and benchmark
fixture before and after the incremental index. ETS ledger, default payload
size, no forced GC. Each row describes the interval ending at that checkpoint,
not the cumulative average since bootstrap. `reductions/cycle` is the difference
between successive Sequencer reduction counters divided by completed cycles.

| Completed cycles | Before: after_erasure reductions/cycle | After: after_erasure reductions/cycle | After: inline reductions/cycle |
| ---: | ---: | ---: | ---: |
| 100 | 447,737 | 356,462 | 356,755 |
| 500 | 917,948 | 368,121 | 368,918 |
| 1,000 | 1,730,499 | 392,087 | 390,987 |
| 2,000 | 3,175,336 | 405,955 | 412,292 |

At the last checkpoint the erased lane requires about 87% fewer reductions
(7.8× less CPU work by this counter). The growing full-history closure cost is
absent in this workload; residual reductions still include allocation and GC.
Measured mean latency at that checkpoint changed from 79.47 to 21.49 ms/cycle.
Other development jobs ran during these measurements, so latency is indicative,
not a controlled release-performance qualification or a concurrency guarantee.

A separate call-count probe, enabled **after** building 100 cycles and completing
a real erasure, ran another 20 complete cycles. Both
`Erasure.Analysis.Closure.derive/2` and `Erasure.Analysis.Execution.state/2`
were called **zero** times. `test/core/erasure_hot_path_test.exs` preserves this
regression check without a machine-dependent timing threshold.

## Boundaries of the result

- New erasures can traverse their affected causal subgraph once. New edges
  propagate existing erasure dependencies, and a no-effect correction removes
  only that target's coverage. This is not a constant-cost promise for an event
  that genuinely changes the availability of many records.
- Whole-history tombstone construction and historical/pure unindexed analyses
  retain their exhaustive path. The index is not authority and is not serialized
  into the ledger. Tests compare it with exhaustive analysis at governed batch
  boundaries and generated graph prefixes.
- State, dependency indexes and ledger history still grow. These changes do
  **not** implement bounded memory, persisted checkpoints, granular backend
  reads, or a transactional current-state adapter. Heap samples without forced
  GC cannot establish steady retained memory.
- These lanes do not measure consent-heavy workloads or multi-node ownership.

## Reproduce

```sh
mix run bench/suite.exs --phase growth --stores ets --checkpoints 100,500,1000,2000
mix test test/core/erasure_hot_path_test.exs test/core/erasure_index_test.exs
```

Raw local outputs (ignored by Git):

- Before: `bench/results/local/erasure-before/20260906T203342-2253/`
- After: `bench/results/local/erasure-after/20260906T203820-5378/`

Each directory includes `resources.csv`, `events.csv` and `environment.txt`.
The reductions table uses the `sequencer_reductions` column of `resources.csv`.
