# Foundation Conformance

Spectre 0.3.1 exposes the compatibility boundary as an executable public
contract. Applications and satellite packages can verify
durable recovery and Stack composition without importing ExUnit or copying
Spectre's internal schemas.

## Durable formats

`Spectre.Foundation.Conformance.matrix/0` is the normative reader/writer
matrix for the running release:

| Format | Writer | Readers |
| --- | ---: | --- |
| conversational State | 5 | 2, 3, 4, 5 |
| Run checkpoint | 2 | 1, 2 |
| format-tagged canonical Instance checkpoint | 2 | 2 |

Run and State legacy readers migrate directly into current core structs. The
Instance v2 family introduced in 0.3.0 is format-tagged and deliberately
rejects retired untagged 0.2.x Instance schemas. Writers never emit a legacy
version.

Use the executable helpers in upgrade tests:

```elixir
alias Spectre.Foundation.Conformance

{:ok, state_report} = Conformance.verify_state(stored_state_json)
{:ok, run_report} = Conformance.verify_run(stored_run_checkpoint)
{:ok, instance_report} = Conformance.verify_checkpoint(stored_instance_json)

true = state_report.writer_version == 5
true = run_report.writer_version == 2
true = instance_report.writer_version == 2
```

Durable adapters and offline tooling should bind the checkpoint to the stream
they loaded, instead of accepting a structurally valid checkpoint from another
Instance:

```elixir
{:ok, report} =
  Conformance.verify_instance_checkpoint(stored_instance_json, instance_ref)

{:ok, ^report} =
  Conformance.verify_instance_checkpoint(stored_instance_json, instance_ref.key)
```

Passing a `Spectre.Instance.Ref` runs the complete Instance canonical validator,
including subject-bound operation data. Passing a non-empty opaque key is the
transport-oriented form: it verifies exactly the checkpoint's
`correlations[:instance_key]` binding. It intentionally does not compare
`flow.conversation_id`, because hosts may set that portable state scope through
the runtime's `:state_conversation_id` option.

Every report contains a digest of the current-writer representation. A report
is evidence that decoding, migration, current validation, and re-encoding all
succeeded; it does not replace the application's durable-store or restart
tests. Spectre 0.3.1 also corrects the tagged-map writer to use a stable entry
order. A 0.3.0 source checkpoint remains readable unchanged, while its report
digest is derived from the corrected 0.3.1 current-writer representation.

The append-only `0.2.6/foundation-conformance-v1.json` fixture still records
the historical 0.2.6 matrix `Instance 4 / readers 1–4`. That evidence is not
rewritten; it is distinct from the running 0.3.1 matrix above.

## Checkpoint Store adapter contract

`Spectre.Instance.CheckpointStore.Conformance.run/2` tests the public storage
boundary with real, restorable, format-tagged Instance checkpoints. Given an
empty isolated Ref, it verifies create and update writes, an exact retry with
semantic readback, rejection of a divergent stale write, and one winner from
two concurrent revision-three compare-and-swap attempts. A successful run
leaves the winning revision three in the adapter.

`read_after_restart/3` loads the same Ref through pre- and post-restart adapter
configurations and compares the validated checkpoint digest. Both functions
return data and have no ExUnit dependency, so adapter repositories can wrap
them in their own framework. They intentionally do not certify process or
database durability, distributed linearizability, legacy-key migration,
credentials, migrations, or deployment topology; those remain package-owned
tests.

See [Testing](TESTING.md) for an executable adapter-suite example.

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

The compiled module-first path remains the golden authoring path in 0.3.1.
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

Spectre 0.3.1 also freezes two checkpoints emitted by the released 0.3.0
format-tagged Instance writer. `instance-v2.json` covers an empty revision-zero
Instance; `instance-v2-advanced.json` covers a real revision-two Work waiting
on a declared trigger. The release suite pins their original bytes and SHA-256
digests, decodes them with the 0.3.1 reader, validates the restored state, and
re-encodes them semantically with the current writer. Re-encoded bytes need not
match the source bytes because 0.3.1 corrects canonical map-entry ordering;
their decoded meaning must match.

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

Spectre 0.2.9 appends the governance matrix: ChangeSet, governed Candidate
state, gate receipt, evaluation delta, Human Report generator, and conservative
GC plan are all version 1. The separate
`0.2.9/governance-v1.json` fixture crosses the production canonical and JSON
boundaries and pins their identities, including complete protected evaluation
case content. The gate also checks the public corpus-digest, compose, review,
approval, rollback, and GC entry points. Durable State, Run, and Instance
reader/writer contracts remain unchanged.

Spectre `0.3.0` appends Experience evidence/artifact, Reflection projection,
critic contract, Critique, OracleApproval and Forge Proposal identities. The
separate `0.3.0/reflective-runtime-v1.json` fixture pins the full path from
Definition and Activation through redacted Experience, Reflection, critique,
oracle approval, ChangeSet and Proposal. `verify_reflection/5` regenerates a
transported projection against all exact inputs; `verify_forge_proposal/1`
revalidates the complete Proposal lineage. Historical State, Run, Instance and
0.2.x fixture bytes are unchanged.

## What the gate does not authorize

Conformance proves structural compatibility. It does not grant authority,
approve a Definition, activate a Candidate, create a distributed owner lease,
or certify an application's external side effects. Those remain explicit host
responsibilities.
