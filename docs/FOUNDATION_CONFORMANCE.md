# Foundation Conformance

Spectre 0.2.6 turns the compatibility boundary of the 0.2 foundations into an
executable public contract. Applications and satellite packages can verify
durable recovery and Stack composition without importing ExUnit or copying
Spectre's internal schemas.

## Durable formats

`Spectre.Foundation.Conformance.matrix/0` is the normative reader/writer
matrix for the running release. In 0.2.6 it records:

| Format | Writer | Readers |
| --- | ---: | --- |
| conversational State | 5 | 2, 3, 4, 5 |
| Run checkpoint | 2 | 1, 2 |
| canonical Instance checkpoint | 4 | 1, 2, 3, 4 |

Readers migrate directly into the current core structs. Older formats do not
create a parallel runtime model and writers never emit a legacy version.

Use the executable helpers in upgrade tests:

```elixir
alias Spectre.Foundation.Conformance

{:ok, state_report} = Conformance.verify_state(stored_state_json)
{:ok, run_report} = Conformance.verify_run(stored_run_checkpoint)
{:ok, instance_report} = Conformance.verify_checkpoint(stored_instance_json)

true = state_report.writer_version == 5
true = run_report.writer_version == 2
true = instance_report.writer_version == 4
```

Every report contains a digest of the current-writer representation. A report
is evidence that decoding, migration, current validation, and re-encoding all
succeeded; it does not replace the application's durable-store or restart
tests.

## Definition golden path

`verify_definition/2` accepts either validated structs or canonical bytes and
uses the same Definition and Manifest contracts as publication and activation:

```elixir
canonical = Spectre.Definition.canonical!(MyApp.Agent)
manifest = Spectre.Definition.manifest!(MyApp.Agent)

{:ok, report} =
  Spectre.Foundation.Conformance.verify_definition(canonical, manifest)

report.definition_ref
report.authority_digest
report.closure_digest
```

The compiled module-first path remains the golden authoring path in 0.2.x.
Runtime and generated definitions must lower into the same canonical envelope;
they do not receive a second publication or activation model.

## Satellite Stack matrix

One package can satisfy Contract V1 alone and still fail when combined with
the rest of an ecosystem. `Spectre.Stack.Conformance.run/2` verifies the whole
set with the real Stack compiler, including core-version requirements,
dependency ordering, missing requirements, declared conflicts, duplicate
packages, and capability collisions:

```elixir
{:ok, matrix} =
  Spectre.Stack.Conformance.run([
    Spectre.Prism,
    Spectre.Kinetic,
    Spectre.Mnemonic
  ])

matrix.stack_digest
matrix.packages
```

Entries may also be `{module, manifest}` pairs for immutable fixtures. The
optional `:configs` map is keyed by package id and must contain portable data.
The gate validates declarations and composition only; it does not start
provider clients or package child processes.

## Permanent fixture

`test/fixtures/compatibility/0.2.6/foundation-conformance-v1.json` pins the
SHA-256 digest of every core recovery fixture from 0.1.6 through 0.2.5, plus
the schema and Stack contract matrix. The integrated test verifies those
bytes, performs every migration, checks a full compiled Agent+Skill
Definition, and exercises corruption and composition failures.

The fixture is append-only evidence. A later release may add a new writer and
reader without rewriting the historical bytes or changing what an older
release produced.

Spectre 0.2.7 extends the live matrix with runtime Skill Definition,
applicability, prompt-budget, Routing projection, and index-profile schema
versions. It does not rewrite the 0.2.6 digest manifest or change any durable
State, Run, or Instance reader/writer contract. The separate
`0.2.7/runtime-skill-routing-v1.json` fixture pins the new derived identities.

Spectre 0.2.8 appends the data-execution schema matrix: Program, Handoff,
effective Prompt Receipt, Execution projection, migration receipt, and
rehearsal report are all schema 1. The separate
`0.2.8/data-driven-execution-v1.json` fixture pins a portable Program and its
no-Effect rehearsal identities. State, Run, and Instance writers/readers remain
unchanged, and neither prior fixture is rewritten.

## What the gate does not authorize

Conformance proves structural compatibility. It does not grant authority,
approve a Definition, activate a Candidate, create a distributed owner lease,
or certify an application's external side effects. Those remain explicit host
responsibilities.
