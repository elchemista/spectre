# Spectre 0.4 runtime benchmarks

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

The main suite uses `Spectre.propose/3`: public facade → admission → durable
Act/Attempt → broker checkout → local executor → recorded Evidence/Outcome.
Erasure uses `Spectre.request_erasure/4` and deletes its file **inside the
executor**, not from the benchmark caller. A rejected, pending or ambiguous
operation fails the measurement instead of being counted as a fast success.

Jobs:

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

The fixture explicitly provisions a small Surface, finite Meter, root Mandate,
authentication Evidence and Scope. Its ingress trusts generated local inputs;
fixed secrets, a synthetic ID source and a development broker are **benchmark
fixtures**, not production setup examples. See
[host setup](../docs/host-setup.md) for the application trust boundary.

### Where the code lives

| File | Responsibility |
| --- | --- |
| `support/p1_fixture.exs` | Explicit foundation, isolated Store/Domain, authenticated Scope and candidate data shared with P1 |
| `support/workload.exs` | Public proposals, local executor, external receipt files and governed deletion |
| `support/metrics.exs` | Ledger traversal, process/backend memory, I/O counters and CSV output, outside timed cycles |
| `suite.exs` | Benchee lifecycle, scenarios, history checkpoints and CLI options |

`environment.txt` labels this workload `public_proposal_v1`. Earlier suite
results manually consumed Grants and recorded outcomes: those timings exclude
the public facade, Runner and broker, so they are **not equivalent baselines**.
No historical result files are rewritten to suggest otherwise.

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

## Focused measurements

These tools also use 0.4 contracts, but deliberately measure smaller boundaries:

| Tool | What is timed | What is not measured |
| --- | --- | --- |
| `mix run bench/p1.exs` | Individual/group commit with 1/10/100/N proponent processes; separate admission, checkout, receipt and recovery stages | Real executor/broker calls; its stream floor is repeated synthetic segments, not a streaming/voice pipeline |
| `mix run bench/history_growth.exs` | The same manual-stage lifecycle over 2,000 cycles in one Domain; `--profile` traces calls, `--compare` compares young/old Domains | Public facade and executor orchestration; use the suite for that comparison |
| `mix run bench/ledger_ets.exs` | ETS adapter append, batch lookup and export, with/without compression | GAM admission or valid agent history; payloads here are simple storage records |

The low-level P1 workload keeps its original authority/data defaults; fixture
startup now registers the Domain, as the public 0.4 facade requires. Do not mix
manual-stage and public-lifecycle rows when comparing latency or ledger bytes.
Adapter heap/reduction metrics refer to the store process; encoding work in the
caller and transient export allocations are not a whole-VM memory measurement.

## Authority reads independent of terminal history

```sh
mix run bench/authority_reads.exs
```

This pure microbenchmark compares exhaustive authority facts + resolution with
the operation-specific indexed path at 0, 1000 and 10000 closed Duties or
foreign-held Mandates. It checks identical results before measuring with
Benchee (latency, allocation and reductions in the calling process). `--quick`
only smoke-tests the jobs on smaller inputs.

Inputs are generated typed records, not authenticated ledger histories. Setup
exercises index updates but does not benchmark admission, durable I/O, authorized
Duty disposition, recovery or an entire agent. Flattened term sizes printed
before measurement are **not** exclusive heap ownership; shared subterms count
repeatedly. The historical State is still retained, and the holder index adds
references as Mandates accumulate. Constant query cost is not bounded Domain
memory. Use the long-lived growth suite above for whole-process measurements.
