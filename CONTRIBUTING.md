# Contributing

Thank you for helping improve Spectre. Bug reports, documentation corrections,
new adapters, and focused runtime changes are welcome.

## Development setup

```bash
git clone https://github.com/elchemista/spectre.git
cd spectre
git switch feature/v0.4.0-governed-act-runtime
mix deps.get
mix test
```

The branch above is the unreleased 0.4 development line. For a published
release, use its tag instead; do not assume the default branch has the same API
as the guide you are reading.

Spectre requires Elixir `~> 1.19`. The current 0.4 runtime dependency is UUIDv7;
Benchee is development-only. Provider, embedding and database-driver libraries
are not bundled runtime dependencies. Start with [Architecture](docs/architecture.md)
and [Testing and release](docs/testing-and-release.md). Base changes on the
current GAM runtime, not removed 0.3 APIs.

## Before opening a pull request

Run the same local quality checks used for a release:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
mix run scripts/check_documentation_links.exs doc
mix hex.build
git diff --check
```

New behavior should include executable tests for failures and boundary
conditions, not only the successful output. Changes to lifecycle state,
persistence, policy matching, providers, or side effects should assert callback
order and cardinality, forbidden calls, state on both sides of a commit, and
restart or replay behavior. Coverage and large case counts are supporting
signals; they are not substitutes for those invariant assertions.

Update the public guides and [capability inventory](docs/capabilities.md) with API
changes. Keep host-owned integration policy distinct from kernel guarantees.
Self-contained marked guide examples are executed by the release-artifact tests;
wiring fragments must identify the host-provisioned values they require.

## Compatibility

Public modules and functions documented by ExDoc are the supported API. Modules
with `@moduledoc false` and functions with `@doc false` are implementation
details and may change without deprecation during the `0.x` series.

For a breaking public change:

1. explain the migration in the pull request;
2. update the relevant guide and module documentation;
3. add an entry under `Unreleased` in `CHANGELOG.md`;
4. do not preserve the removed 0.3 runtime through compatibility shims; for later
   public changes, discuss whether a safe deprecation path is appropriate.

## Security reports

Do not open a public issue for a suspected vulnerability. Follow the private
reporting instructions in [SECURITY.md](SECURITY.md).
