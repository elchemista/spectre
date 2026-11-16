# Testing Spectre 0.4

The CI workflow is the source of truth for release checks. It tests Elixir
`1.19.x` / OTP `28.x` and Elixir `1.20.x` / OTP `29.x`. Use separate build
paths when switching toolchains.

## Core checks

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
SPECTRE_TEST_PROJECTION=1 mix test test/gam
mix credo
mix dialyzer
mix docs --warnings-as-errors
```

CI uses the configured Credo priority threshold. `mix credo --strict` is an
additional advisory pass. The coverage gate is **95%**; keep meaningful tests
for behavior and failure paths rather than lowering the threshold or hiding
modules.

For the coverage CI cell, regenerate every export from the same source revision:

```sh
mix test --cover --export-coverage ram
SPECTRE_TEST_PROJECTION=1 mix test test/gam --cover --export-coverage projection
```

From the sibling Ledger checkout, with PostgreSQL installed:

```sh
SPECTRE_PATH=../spectre SPECTRE_CORE_COVERAGE_DIR=../spectre/cover \
  mix test test/postgres_server_store_test.exs --cover --export-coverage postgres
```

Then run `mix test.coverage` in core. Archive or remove earlier `cover/*.coverdata`
exports before starting a new source revision. The PostgreSQL tests create an
isolated temporary cluster; they exercise actual SQL, migrations, restart,
disconnected storage and explicit recovery.

## Examples and complete Stack

```sh
mix run docs/examples/agent_server_quickstart.exs
mix run docs/examples/external_approval.exs
```

The external-approval example uses two agents and independent Domains without
Pulse. In `integration/stack_tools`, run `mix test` with the sibling packages on
the branches listed in [Installation](INSTALLATION.md). It covers real
Server/GAM coordination with deterministic external providers.

The [demo's verification guide](https://github.com/elchemista/demo_spectre/blob/main/docs/VERIFICATION.md)
covers its PostgreSQL, fresh-process queries and browser tests. The
[ecosystem repository](https://github.com/elchemista/spectre_ecosystem) checks
pinned package combinations and clean checkouts.

## Optional native and performance tests

```sh
mix test test/instance_performance_test.exs --include perf
```

The native embedding CI job checks out the pinned ExFastembed revision in the
workflow and sets `SPECTRE_EX_FASTEMBED_PATH` and
`SPECTRE_REAL_EMBEDDING_TESTS=1`. Its command is:

```sh
mix test test/real_ex_fastembed_semantic_cache_test.exs --include real_ex_fastembed
```

Use the dedicated lockfile selected by that profile; keep native builds separate
from ordinary test builds. [Profiling](OTP_PROFILE_0_4.md) describes memory and
reduction probes. [Compatibility](COMPATIBILITY.md) links the retained adapter
conformance and immutable fixture contracts.

## Package checks

The package CI builds documentation with warnings treated as errors and checks
that generator templates and runnable examples are included while tests and
internal design records are excluded. These are local build checks; no CI job
publishes a package. Tags and publication are separate maintainer steps.
