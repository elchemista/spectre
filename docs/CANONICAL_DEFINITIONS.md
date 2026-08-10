# Canonical Definitions and Audit Projections

Spectre 0.2.1 can lower a compiled Agent or Skill into a portable, immutable
Definition envelope. This is the first reflective-runtime foundation: it gives
declared behavior an exact content identity and an inspectable Audit view
without changing Instance activation, Run identity, or execution ownership.

```elixir
{:ok, canonical} = Spectre.Definition.canonical(MyApp.SupportAgent)

definition_ref = Spectre.Definition.Canonical.ref(canonical)
"sha256:" <> _digest = Spectre.Definition.Ref.to_string(definition_ref)

{:ok, audit} = Spectre.Projection.generate(canonical)
audit.content == Spectre.Definition.Canonical.to_data(canonical)
```

## What the envelope contains

The envelope has explicit canonicalization, contract, and digest versions. Its
payload is split into uniquely typed components with a schema Ref and one of
three criticality classes:

- `:must_understand` for identity, routing, policies, prompts, requirements,
  mounted Skills, and compiled runtime behavior;
- `:advisory` for data a compatible runtime may preserve without changing
  safety semantics;
- `:descriptive` for authored metadata that can help routing or operators but
  never grants authority.

Authored `description:` and `metadata:` are kept separate from structured
`applicability:`. Skill requirements are recorded as requests; the canonical
component deliberately contains an empty `grants` list because lowering a
compiled Definition does not authorize it.

Mounted compiled Skills are lowered through the same IR. Each mount carries
its own `Definition.Ref`, complete canonical envelope, bindings, and compiled
module Ref. Executable modules and callbacks are represented as
`compiled_only` code Refs rather than copied functions.

## Portable canonical values

`Spectre.Canonical.Value` is the durable value codec. It does not use Erlang
external-term encoding. The format:

- uses explicit tags for primitives, atoms, lists, tuples, maps, and explicitly
  allowlisted structs;
- orders map entries by the canonical bytes of each key;
- rejects PIDs, ports, references, functions, improper lists, non-byte-aligned
  bitstrings, and non-finite floats;
- restores atoms with `String.to_existing_atom/1` only;
- applies byte, nesting, and collection limits on encode and decode.

```elixir
{:ok, bytes} = Spectre.Canonical.Value.encode(%{b: 2, a: 1})
{:ok, %{a: 1, b: 2}} = Spectre.Canonical.Value.decode(bytes)

{:ok, digest} = Spectre.Canonical.Value.digest(%{b: 2, a: 1})
```

Structs fail closed unless both sides explicitly allow their module:

```elixir
opts = [allowed_structs: [MyApp.PortableValue]]
{:ok, bytes} = Spectre.Canonical.Value.encode(value, opts)
{:ok, ^value} = Spectre.Canonical.Value.decode(bytes, opts)
```

The checked-in Definition fixture under
`test/fixtures/compatibility/0.2.1` is decoded and re-encoded by the OTP 28 and
OTP 29 CI jobs. Its bytes and Definition Ref must remain unchanged.

## Governed prompt snapshots

Compiled prompt assets are snapshotted into canonical
`Spectre.Prompt.Fragment` data with:

- stable fragment ID and schema version;
- target, scope, position, visibility, and trust class;
- requested and granted priority;
- budget class and optional token cap;
- provenance, source digest, and fragment digest;
- a closed placeholder schema;
- a compiled Predicate Ref when a condition exists.

The 0.2 asset migrator accepts only direct assign paths such as:

```text
Hello <%= @input.text %>
```

The canonical snapshot becomes:

```text
Hello {{input.text}}
```

with `input.text` declared in the placeholder schema. Any other EEx tag is
rejected. Runtime data therefore never contains EEx, quoted AST, or an
anonymous callback. Dynamic compiled providers remain `context:data` code Refs
and cannot become instructions or tasks.

Missing compiled assets are represented explicitly as missing snapshots; an
absolute host path is never part of Definition identity. Path traversal and
symlink escape continue to fail through the existing prompt resolver.

## Audit projection

`Spectre.Projection.Audit` is deliberately boring: its content is exactly
`Spectre.Definition.Canonical.to_data/1`. It does not summarize, infer, invoke
an LLM, or add fields. Projection identity includes:

- the Definition Ref;
- generator ID and version;
- the optional input-evidence digest;
- the projected content.

Changing a generator version therefore changes the projection digest even if
the resulting content happens to be equal.

## Security and scope

A digest proves integrity, not trust, publisher identity, approval, or current
authority. The lowering boundary rejects known credential-bearing configuration
keys and VM-local values, but applications must still keep all credentials and
clients in runtime-owned configuration.

Version 0.2.1 does not add a Definition Store, Resolver, Manifest V2,
activation CAS, runtime-authored Skills, or self-modification. It creates and
verifies canonical data and its Audit projection only. Existing module-first
Agents, Instance keys, Runs, checkpoints, and execution paths retain their
0.2.0 behavior.

Spectre 0.2.2 adds the first three publication primitives while retaining the
same activation boundary. Spectre 0.2.3 then separates stable Agent identity
from Definition identity and adds Candidate-backed activation plus Run pinning.
Continue with [Definition Store, Resolver, and Manifest V2](DEFINITION_STORE.md)
and [Stable Identity, Activation, and Definition-Pinned Runs](IDENTITY_ACTIVATION.md).
