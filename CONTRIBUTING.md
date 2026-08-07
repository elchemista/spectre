# Contributing

Thank you for helping improve Spectre. Bug reports, documentation corrections,
new adapters, and focused runtime changes are welcome.

## Development setup

```bash
git clone https://github.com/elchemista/spectre.git
cd spectre
mix deps.get
mix test
```

Spectre requires Elixir `~> 1.19`. Vettore is a normal runtime dependency.
ExFastembed is optional; the committed strategy fixture keeps the default test
suite offline and deterministic. The dedicated real-model profile in
[Testing](docs/TESTING.md) must pass for changes to embedding persistence,
semantic search, or the ExFastembed adapter.

## Before opening a pull request

Run the same local quality checks used for a release:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix credo --strict
mix dialyzer
git diff --check
```

New behavior should include executable tests for failures and boundary
conditions, not only the successful output. Changes to lifecycle state,
persistence, policy matching, providers, or side effects should assert callback
order and cardinality, forbidden calls, state on both sides of a commit, and
restart or replay behavior. Coverage and large case counts are supporting
signals; they are not substitutes for those invariant assertions.

## Compatibility

Public modules and functions documented by ExDoc are the supported API. Modules
with `@moduledoc false` and functions with `@doc false` are implementation
details and may change without deprecation during the `0.x` series.

For a breaking public change:

1. explain the migration in the pull request;
2. update the relevant guide and module documentation;
3. add an entry under `Unreleased` in `CHANGELOG.md`;
4. prefer a deprecation cycle when a safe compatibility shim is possible.

## Security reports

Do not open a public issue for a suspected vulnerability. Follow the private
reporting instructions in [SECURITY.md](SECURITY.md).
