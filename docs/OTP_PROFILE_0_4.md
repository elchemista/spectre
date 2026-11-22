# Profiling memory and OTP processes

Measure representative workloads in an isolated VM. Record process memory,
referenced binaries, reductions, mailbox lengths, ETS ownership and row counts.
Compare warmed steady-state samples and cleanup after owners stop. Full GC and
tracing affect timing; use them for diagnosis rather than production polling.

## Domain working set

Without a projection adapter, the Domain keeps its complete projection in RAM.
With Ledger's PostgreSQL projection, commands load their required records,
commit changed rows and release historical records. Active authority, Duties
and the relevant proof closure remain in scope. Full-history views can
materialize history temporarily. [Domain storage](DOMAIN_STORAGE.md) describes
the contract and recovery behavior.

A local finite probe on Elixir 1.20.4 / OTP 29, with four schedulers, measured:

| Workload | Completed records/effects | Domain memory after full GC |
| --- | --- | --- |
| Observations with 2 KiB input | 16 / 256 / 1,024 | 21,752 / 21,752 / 21,752 B |
| Completed governed effects | 8 / 64 / 128 | 21,752 / 21,752 / 21,752 B |

The effect sample used `history_limit: 2` and `max_seen_events: 16` for its warmed
Server coordination cache. The default cache fills differently. These figures
measure process memory, not total database or VM allocation. Sampled peaks were
higher; cold recovery still reads canonical history and rebuilds derived rows.

A separate two-Domain approval probe returned from 237 live processes after
load to its 218-process baseline after teardown. Gates and Store query workers
had no pending tasks. This is evidence for those workloads, not a proof of
unbounded uptime or absence of every leak.

## Compression and hibernation

`GAM.Ledger.Store.ETS` already supports `compressed: true`. A 1,000-event synthetic
probe reduced reported ETS allocation from 2,437,208 to 1,058,112 bytes. This
excludes some off-heap binary storage and trades CPU work for space; benchmark
your payloads before choosing it.

Server `hibernate_after: 100` reduced one idle Runtime sample from 143,048 to
4,472 bytes; it woke and handled another input. Hibernation compacts an idle
process. It does not passivate a Domain or discard application state, and
frequent polling prevents a long idle period.

## Reproduce workload profiles

### AgentServer Activities in 0.4.1

From the Core checkout, run the Activity profile in an isolated VM. Set the
temporary directory to a physical disk when measuring writes.

```sh
ERL_FLAGS='+S 2:2' mix run bench/profile_activity.exs ram 256
mkdir -p tmp
TMPDIR="$PWD/tmp" ERL_FLAGS='+S 2:2' mix run bench/profile_activity.exs disk 16
```

The profile starts a real AgentServer, opens a foreground wait, holds two
provider workers while serving unrelated Root turns, and repeats start/cancel
in three batches. It samples GC'd process memory, reductions, mailbox depth,
turn latency, worker lifetimes, checkpoint bytes and storage writes.

| Backend | Idle | One wait | Two workers | After start/cancel batches |
| --- | ---: | ---: | ---: | ---: |
| RAM, additional processes | 7 | 10 | 13 | 9 |
| RAM, memory | 74,864 B | 78,832 B | 137,520 B | 1,047,976 B |
| Disk, additional processes | 8 | 11 | 14 | 10 |
| Disk, memory | 89,520 B | 81,976 B | 119,968 B | 228,584 B |

On Elixir 1.20.4 / OTP 29 with two schedulers, the RAM run retained 256
terminal entries plus the Root entry from cycle 256 through 768. Total
process memory after GC leveled off around 1.05 MB from cycle 512 to 768 in
two runs. The 95th-percentile Root turn was 1.88 ms with two held workers.
The disk run exercised 48 starts and cancellations. Its coordination
file grew from 3,128 to 17,920 B while the BEAM reported about 29.5 MB of
physical writes on ext4. The Root checkpoint stayed near 2.9 KB in both
runs. Both returned to the initial live process count after stopping the Root.
Sampled mailbox depth was at most three and the Root served all 24 timed
inputs per sample while the two workers were held. The disk samples ran
alongside other checks. Use a quiet VM for latency or throughput comparisons.

### Durable Domain and Stack workloads

From Ledger, with PostgreSQL installed and local core selected:

```sh
SPECTRE_PATH=../spectre MIX_ENV=test ERL_FLAGS='+S 4:4' \
  PROFILE_OUTPUT=/tmp/spectre-profile PROFILE_BATCHES=20 \
  PROFILE_BATCH_SIZE=500 PROFILE_IDLE_MS=30000 mix run bench/otp_profile.exs
```

Add `PROFILE_EPROF=true` for a smaller CPU tracing run. `PROFILE_GAM_STORAGE=disk`
selects the alternative history backend. From `spectre_ecosystem/integration/stack_tools`:

```sh
ERL_FLAGS='+S 4:4' mix run bench/profile_stack.exs
```

The existing Instance compatibility profiler runs separately:

```sh
mix spectre.profile --iterations 3
mix spectre.profile --scenario restore_runs --runs 64 --iterations 5
```

It reports median owner/total reductions, post-GC footprint, startup duration
and an OTP `:tprof` allocation breakdown. Keep RAM, database, native providers
and toolchain versions explicit when comparing results. A slower database can
still delay serialized Domain commits and checkpoint durability barriers.
