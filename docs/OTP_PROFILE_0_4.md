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
