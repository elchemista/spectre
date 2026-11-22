# Verifying Spectre 0.4.1

Use a fixed set of commits for core and every companion package. Package
versions are independent; [Installation](INSTALLATION.md) explains dependency
selection and source pins.

## Required checks

1. Run the supported BEAM matrix, core suite, persisted GAM projection suite,
   formatting, warning-free compilation, configured Credo, Dialyzer and ExDoc.
2. Run Ledger against real PostgreSQL, including lost connections, missing rows,
   restart and explicit storage recovery.
3. Run the complete Stack integration and the demo's precommit/browser checks
   with the candidate dependency revisions.
4. Freeze ecosystem and demo dependency pins to those commits, then verify a
   clean checkout. Keep local overrides out of the committed dependency set.
5. Inspect generated documentation, package contents, version/changelog metadata
   and source links before tagging.

[Testing](TESTING.md) contains the commands; [Production](PRODUCTION.md) contains
the runtime and deployment responsibilities. CI never publishes packages.

## Compatibility boundaries to exercise

- RAM-only agents work without Ledger or a database.
- An unnamed Activity gets its own execution reference. Two missions can run
  while the Root answers chat. Targeted replies, revision and cancellation
  preserve correlation. An admitted effect retains its original Outcome.
- A 0.4.0 checkpoint can resume on 0.4.1 after the host verifies a changed
  definition with `checkpoint_migrator:`. Run the pinned checkpoint fixture
  and rehearse the same migration against a copy of production storage.
- Ledger-backed Domains release historical projection records after use;
  active work and full-history queries can still consume memory.
- An external approval satisfies consent only for its frozen request. It cannot
  expand the requesting agent's execution authority.
- Transport acceptance, rendering acknowledgement, consent, admission and external
  success remain different events.
- A database outage follows the configured policy. Starting a fresh RAM Domain
  cannot reuse old grants or consent, and does not merge its history back later.
- Payload callbacks control application content. Governance facts still obey GAM
  verification, and legacy inline records remain readable.
- Instance/Run compatibility fixtures retain their recorded formats. Moving an
  application to Server requires the explicit [migration](MIGRATING_TO_0_4.md).

## Build the local package

From the Core checkout, use a fresh directory.

```sh
package_dir="$(mktemp -d)"
mix hex.build --unpack --output "$package_dir/spectre"
```

`--unpack` writes the files and package metadata into a directory so they can
be inspected. This is the same packaging step used by Core CI. When cutting the
release, tag the verified Core revision as `0.4.1`, match each satellite's
independent version, and update its pinned compatibility workflow before
publishing dependent packages. Directive's native Activity API is in its
`0.2.0` package.
