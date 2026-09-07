# Testing and release validation

The useful question is not "how many tests?" but "which invalid history,
authority change or host failure would this test detect?" Coverage locates
unexercised code; it does not establish the four GAM laws.

## Development checks

From the repository, with Elixir `~> 1.19` and the supported OTP version:

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --seed 0
mix test --seed 42
mix test --cover
mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
mix hex.build
git diff --check
```

Benchee is development-only; provider/database libraries are not implicit
runtime dependencies. Tests use host doubles and deterministic fixtures, but
those doubles are not proof of a real PostgreSQL, Mnesia cluster, S3 or network
deployment. Run integration tests against the deployment you intend to claim.

## Trace the law through the whole lifecycle

| Property | Assertions beyond happy-path output |
| --- | --- |
| Authority never grows | Child coverage/Meters do not exceed ancestors; restriction/revocation survive replay; evidence cannot choose a new principal |
| Record before capability | No broker/executor call on refusal, incomplete/ambiguous commit or invalid receipt; Attempt is durable before checkout |
| Causality is not rewritten | Late observation after revocation/restart is recorded; no-effect and ambiguous results are not conflated; no blind executor retry |
| Duty does not self-extinguish | Deadline derives debt; timer alone never disposes it; responsible/conflicted actors cannot self-clear it |
| Information flow remains bound | Consent occurrence, assumption DAG, counterproofs, erased parents and labels survive complete-agent paths |
| Canonical facts are exact | Integer/float confusion, duplicate fields, wrong keys, malformed frames, wrong Domain and hash/identity mismatch are rejected |

Use a real admitted setup and normal ingress/governance paths where possible.
Manually inserting a root Mandate into a projection can test a pure helper; it
does not prove an application can obtain that authority through the runtime.
Assert callback order/cardinality, forbidden calls, ledger records and both
sides of the accounting transition, not just `{:ok, _}`.

## Agent integration tests

Exercise agents without Skills, with namespaced Skills, with Extension ports,
and after a governed Morph. Include regex/string-bag/custom binary routing,
ties, misses and adapter failures. The selected Candidate must still be denied
when the current authority or evidence does not cover it.

Stateful Instance tests need barriers, not timing guesses: hold a callback until
the test explicitly releases it, read state during the hold, change authority,
stop the Domain and deliver a late result. Verify that only an allowed successful
completion changes local state and that no stale worker resurrects a fenced Scope.

For [streaming integrations](integration-and-streaming.md), assert that governed
content is not delivered before admission, new input does not rewrite an old
Act's evidence basis, interrupted provider work stays uncertain when appropriate,
and local cancel is not a successful Outcome or Duty disposal.

The complete-agent suites are organized by scenario rather than one growing
file. Shared `ExUnit.CaseTemplate` fixtures live in `test/support/`; they start
isolated state for each test, not a shared Domain for the whole suite.

| Scenario | Test source under `test/core/` |
| --- | --- |
| Basic agents, Skills and Instance lifecycle | `full_agents_test.exs` |
| Information lineage, governance, Duties, consent and external payloads | `agents_information_test.exs`, `agents_governance_test.exs`, `agents_duty_test.exs`, `agents_consent_test.exs`, `agents_payload_test.exs` |
| Regex, string-bag, custom matching and input pipelines | `routed_agents_test.exs` |
| Routed checkpoints/Morph, provenance/isolation and durable recovery | `routed_agents_lifecycle_test.exs`, `routed_agents_provenance_test.exs`, `routed_agents_recovery_test.exs` |

Use `test/support/full_agent_case.ex` and `test/support/routed_agent_case.ex`
for common host wiring and ledger/accounting assertions. Keep scenario-specific
assertions alongside their tests, so the property under examination stays visible.

## Faults and differential checks

Inject failure before commit, after durable commit but before acknowledgement,
after Grant consumption, during broker checkout and after the external action
but before its receipt. Independently tamper with storage keys, batches, counts,
timestamps, digests and entire internally consistent histories. The last case
requires an external witness to detect: a hash chain alone cannot do it.

Compare indexed/incremental facts to the exhaustive pure derivation over the
same verified prefix. Compare live fold and offline export audit. Keep raw
state fixtures for helper tests, but include real transition sequences: otherwise
an index test can agree with an equally incomplete fixture.

## Performance and memory

The development benchmark suite can be run with:

```sh
mix run bench/suite.exs --quick
mix run bench/suite.exs --phase growth --stores ets,disk_compressed \
  --checkpoints 10,50,100,200,500,1000,2000 --payload-bytes 16384
mix run bench/authority_reads.exs --quick
```

These scripts are repository development assets, not Hex package commands.
See `bench/README.md` in the source checkout for all options and units.
Quick runs check the workloads, not p99 stability. The focused authority
microbenchmark is not a complete agent benchmark.

Measure completed cycles, CPU reductions, append counts/bytes, payload verify
calls, sequencer heap, backend ETS/process memory and physical ledger bytes
separately. Include external payloads, consent, completed erasure, concurrent
proponents, overload and recovery. A compressed store or flat CPU curve does
not imply bounded total memory. Record environment, revision, dirty status,
sample counts and whether explicit GC changed the measurement.

## Documentation is an executable artifact

The release-artifact tests check that published guides exist, are included in
the package and do not link to missing local files. Marked self-contained guide
examples are executed; wiring fragments are explicitly labeled as requiring
host-provisioned values. Keep code examples on the current branch's public API,
not on assumptions about the removed runtime.

ExDoc and Hex packaging must both succeed. The landing page, capability
inventory and trust assumptions must describe the same version. A clean
compiler, Credo and Dialyzer result cannot detect duplicated ExUnit names,
incorrect operator advice, network-effect ordering or quadratic runtime work.
