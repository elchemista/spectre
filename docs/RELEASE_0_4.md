# Verifying a 0.4 release candidate

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

## Publication handoff

Commit and review the candidate branches, update pins, and let the corresponding
remote workflows finish on those exact revisions. Before publishing, set source
references to the intended release tags and refresh dependency requirements in
dependency order: core and Ledger before Lab. The maintainer owns tags and Hex
publication; release verification does not perform them.
