# Testing Spectre 0.4.2

The CI workflow is the source of truth for release checks. It tests Elixir
`1.19.x` / OTP `28.x` and Elixir `1.20.x` / OTP `29.x`. Use separate build
paths when switching toolchains.

## Core checks

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
SPECTRE_TEST_PROJECTION=1 mix test test/server test/server_gam_test.exs
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
SPECTRE_TEST_PROJECTION=1 mix test test/server test/server_gam_test.exs --cover --export-coverage projection
```

Then run `mix test.coverage` in core. Only the two core exports contribute to
this gate; no Ledger, database or companion package is required. Archive or remove
earlier `cover/*.coverdata` exports before starting a new source revision.
The [ExGAM repository](https://github.com/elchemista/ex_gam) runs the standalone
kernel suite.

## Examples and complete Stack

```sh
mix run docs/examples/agent_server_quickstart.exs
mix run docs/examples/core_agents/run.exs
mix run docs/examples/external_approval.exs
```

The scripts cover local recognition, model-backed replies, a reusable Documents
flow and two-agent consent. For chat and parallel Directive work, run in the
Directive checkout with Core alongside it.

```sh
SPECTRE_PATH=../spectre mix run examples/agent_server_activity.exs
SPECTRE_PATH=../spectre mix test test/directive_activity_test.exs
```

For a durable upgrade, the Core `test/server/tool_runtime_test.exs` suite
contains a checkpoint captured with Spectre 0.4.0. The assertion checks that the
new Server acquires its original pending tool result with the same command ID.
`test/server/checkpoint_route_migration_test.exs` covers invalid migrations and
checks the stored values stay intact.

The external-approval example uses two agents and independent Domains without
Pulse. The multipackage suite belongs to
[spectre_ecosystem](https://github.com/elchemista/spectre_ecosystem/tree/main/integration/stack_tools),
where it exercises the packages against a selected core revision. Package-specific
integration tests run in their owning library: PostgreSQL in
[spectre_ledger](https://github.com/elchemista/spectre_ledger), approval transport
in Pulse, browser adapters in Lens, and the corresponding tests in other packages.

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
