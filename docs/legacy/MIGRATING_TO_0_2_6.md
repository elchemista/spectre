# Migrating to 0.2.6

Spectre 0.2.6 adds executable conformance and migration gates for the durable
foundations completed in 0.2.1 through 0.2.5. It does not change any State,
Run, Instance checkpoint, canonical Definition, Manifest, Candidate, or Stack
writer schema.

## Compatibility

- State writers remain at version 5; readers accept versions 2 through 5.
- Run writers remain at version 2; readers accept versions 1 and 2.
- Instance checkpoint writers remain at schema 4; readers accept schemas 1
  through 4.
- canonical Definition remains canonicalization 1 / contract 1.
- Manifest remains schema 1 / contract 2.
- Stack module input remains Contract V1 and lowers into sealed Contract V2.

No checkpoint namespace quiescence is required solely for this upgrade.
Existing 0.2.5 deployment guidance still applies to schema-4 Skill state.

## Upgrade procedure

1. Pin `spectre` to tag `0.2.6` and compile with warnings as errors.
2. Run `Spectre.Foundation.Conformance.verify_state/1`, `verify_run/1`, and
   `verify_checkpoint/1` against representative production backups.
3. Build every deployed Agent through `Spectre.Definition.canonical!/1` and
   `manifest!/1`, then call `verify_definition/2` on each pair.
4. In each satellite or umbrella integration suite, call
   `Spectre.Stack.Conformance.run/2` with the complete installed package set,
   not one package at a time.
5. Run the application's restart, owner-fence, ambiguous persistence, and
   side-effect idempotency tests before deployment.

Treat every error as a failed upgrade gate. Do not discard a field, weaken a
version requirement, or bypass a collision to force a report to pass.

## Package maintainers

Satellite repositories can use `Spectre.Stack.Conformance` from their test
suites without a production dependency on ExUnit. Publish the tested core
requirement and the resulting package matrix with the package release. Core
does not need, and must not gain, a reverse dependency on satellite packages.

## Preparing for 0.3

The 0.2.6 matrix is the compatibility baseline for later reflective runtime
work. New runtime-authored structures must lower into the existing canonical
Definition, Manifest, authority, closure, activation, event, and Skill-state
models. See [Preparing for 0.3](MIGRATING_TO_0_3.md).
