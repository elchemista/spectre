# Runtime benchmarks

Benchee is a development-only dependency; it is not started with Spectre and
is not required in test or production releases.

```sh
mix deps.get
mix run bench/suite.exs --quick
```

The quick run checks that the workloads work. Its sample counts are deliberately
tiny: do not use its p95/p99 numbers to qualify production performance.

## Repeatable latency and storage comparison

```sh
mix run bench/suite.exs --stores ets,ets_compressed,disk,disk_compressed \
  --history 0,100 --operations 16 --time 5.0 --warmup 1.0
```

Each Benchee sample gets a fresh Domain with the requested number of completed
historical Acts. Bootstrap, history seeding and cleanup are outside the timer.
This avoids silently changing the history size between samples. Setup can take
much longer than the estimated Benchee measurement time, especially on Disk or
with a large `--history`.

Jobs exercise actual admission, Grant consumption, executor Evidence and Outcome:

- `individual`: `--operations` complete cycles, sequentially.
- `group`: the same number of cycles submitted concurrently to one Domain.
  Batching is real; scheduling can produce partial batches. Inspect actual
  batch deltas in `scenario_resources.csv`, not just configured batch size.
- `external`: sequential cycles with content-addressed receipt payloads in real
  temporary files. Includes file writes, reads, digest verification and an I/O
  call counter. Bodies contain a sequence prefix plus `--payload-bytes` repeated
  bytes (default 4096); they are synthetic, compressible data.
- `erasure`: **one** complete governed deletion, including a receipt and a Duty
  for reduced verifiability. Its target was recorded during setup.
- `recovery`: **one** Sequencer stop/start and full semantic recovery of the
  seeded inline history. The store process and OS filesystem cache remain warm;
  this is not a machine reboot or a cold-disk measurement.

Do not compare recovery/erasure throughput with multi-cycle jobs as if they
performed the same work. These are core lifecycle benchmarks, not an LLM, Mind,
Instance, network executor or end-user throughput benchmark.

## Long-lived Domain growth

```sh
mix run bench/suite.exs --phase growth --stores ets,disk_compressed \
  --checkpoints 10,50,100,200,500,1000,2000 --payload-bytes 16384
```

This phase keeps each Domain alive across all checkpoints, for inline receipts,
external receipts, and inline work after a completed erasure. Latencies are
measured per complete cycle in each interval, not averaged over the entire past.
No forced GC runs by default. Repeat with `--gc` to measure retained process
memory after explicit checkpoint GC; that diagnostic changes later GC behavior
and must not be mixed with the default run as an equivalent workload.

`--phase latency` runs only Benchee and the matching resource diagnostics;
`--phase all` (default) runs both phases. Each invocation creates a unique output
directory under `bench/results/local/` (gitignored). `--output PATH` changes its
parent directory. Temporary stores are owned by the fixture and removed after
successful runs; no application database/path is used.

## Output and units

| File | Contents |
| --- | --- |
| `latency.csv` | Benchee sample count, mean, p50/p95/p99 in milliseconds per job invocation |
| `latency.benchee` | Benchee's saved suite with raw timing samples |
| `scenario_resources.csv` | One separate diagnostic run per job/input: entries, batches, bytes, process and backend memory |
| `resources.csv` | Cumulative growth checkpoints plus interval timing and write/I/O deltas |
| `events.csv` | Entry count and canonical byte size by event type at each growth checkpoint |
| `environment.txt` | Options, Elixir/OTP, scheduler count, Git revision and dirty-file status |

All size columns are bytes, not MiB. `ledger_canonical_bytes` is the sum of
encoded Entry sizes, excluding physical framing and indexes. `ledger_file_bytes`
is the total regular-file length in the Disk store directory, including frames;
it is empty for ETS. Compression changes physical sizes, not canonical digests.
File lengths are not allocated filesystem blocks, backups, or write amplification.

`sequencer_bytes` is `Process.info(pid, :memory)` at an idle checkpoint.
`sequencer_after_gc_bytes` is populated only with `--gc`. Referenced binary bytes
are reported separately because binaries can be shared; do not sum them as
exclusive heap ownership. `store_process_bytes` and `store_ets_bytes` expose the
backend's process heap and owned ETS tables. VM memory and Linux RSS include
the benchmark harness, other processes and retained VM allocator capacity.
These are checkpoint measurements, **not peak-memory or queue-saturation probes**.

Ledger counting runs in a short-lived process, one verified batch at a time,
outside timed cycles. It still reads the store and can warm its cache; large
checkpoint traversals and diagnostic GC affect total wall time. The scenario
resource runs are separate from Benchee samples to avoid polluting their timings.
Benchee caller allocation/reduction measurements are disabled: they would not
measure work in the already-running Sequencer. Its reductions are sampled directly.

Run on a quiet machine, repeat measurements, and inspect sample counts. The
suite currently supports native ETS and Disk (compressed/uncompressed), not
PostgreSQL or Mnesia deployment qualification. It does not establish that
historical memory is bounded or that 100 users can run for months.

Older focused tools remain available: `bench/p1.exs`, `bench/history_growth.exs`
and `bench/ledger_ets.exs`. The P1 fixture defaults are preserved.
