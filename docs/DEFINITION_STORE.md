# Definition Store, Resolver, and Manifest V2

Spectre 0.2.2 adds the publication boundary for canonical Definitions. A
`Spectre.Definition.Manifest` seals two separate contracts around one
`Spectre.Definition.Ref`:

- `Spectre.Authority.Envelope` records only capabilities actually granted by a
  trusted host ceiling;
- `Spectre.Execution.Closure` records the data, contract, generator, state, and
  compiled-build dependencies used when the Definition was composed.

The digest still proves integrity rather than trust. Publisher approval,
revocation, current-time policy, ownership fencing, and activation remain host
decisions.

## Compose a Manifest

Compiled Stack V1 declarations are requests, never grants. The read-only V1
adapter intersects those requests with an explicit ceiling and emits native
Manifest Contract V2 data:

```elixir
canonical = Spectre.Definition.canonical!(MyApp.SupportAgent)

manifest =
  Spectre.Definition.manifest!(MyApp.SupportAgent,
    authority_requests: %{
      state_reads: [:profile],
      prompt_budget_classes: [:standard]
    },
    authority_ceiling: %{
      operations: [:knowledge_lookup],
      actions: [:send_reply],
      state_reads: [:profile],
      prompt_budget_classes: [:standard]
    },
    publisher_ref: "publisher:my-app",
    provenance_refs: ["git:0123456789abcdef"]
  )
```

V1 Stack operations, actions, and resources become requests automatically;
`:authority_requests` supplies request classes V1 cannot express. Omitting
`:authority_ceiling` still produces an empty effective envelope. Authority
lists are canonical sets, and limits are reduced to the stricter requested or
ceiling value. `Spectre.Authority.Envelope.allows?/3` inspects the resulting
grant; it never consults the original request.

Manifest creation also snapshots the component contract registry. Unknown
`:must_understand` components fail closed. Unknown `:advisory` and
`:descriptive` components remain opaque and preserved, so older readers cannot
silently ignore new security semantics.

## Publish before activation

`Spectre.Definition.Store` is an adapter behaviour for immutable opaque blobs.
Core, rather than the adapter, owns canonical encoding, parent checks,
publication receipts, and verification:

```elixir
{:ok, store} =
  Spectre.Definition.Store.Memory.start_link(id: :support_definitions)

config = {Spectre.Definition.Store.Memory, server: store}

{:ok, receipt} =
  Spectre.Definition.Store.publish(config, canonical, manifest)

{:ok, resolution} =
  Spectre.Definition.Resolver.resolve(config, receipt.definition_ref)
```

The memory adapter is deliberately `:volatile`; it is suitable only for tests
and entirely ephemeral Instances. When an Instance has a configured
`Spectre.Instance.CheckpointStore`, `publish/4` and
`resolve_for_activation/3` reject a volatile Definition Store. A durable host
adapter must implement:

```elixir
@behaviour Spectre.Definition.Store

@impl true
def identity(opts), do: Keyword.fetch!(opts, :store_id)

@impl true
def durability(_opts), do: :durable

@impl true
def get(definition_ref, opts), do: MyBackend.get(definition_ref, opts)

@impl true
def put(definition_ref, bytes, opts), do: MyBackend.put_if_absent(definition_ref, bytes, opts)
```

`put/3` must be idempotent for identical bytes and reject different bytes under
the same Ref. After every successful callback, core reads the artifact back and
compares it byte-for-byte before returning its receipt.

Parent Definitions must already resolve. Therefore a process crash after
publish but before a future activation CAS leaves only an immutable orphan; it
cannot leave an activation pointing at an unpublished Definition.

## Resolve and detect drift

Resolution verifies the lookup Ref, Definition bytes, Manifest binding,
component contract snapshot, Manifest digest, and publication receipt. It then
reports compiled code observations explicitly:

```elixir
{:ok, resolution} =
  Spectre.Definition.Resolver.resolve(config, definition_ref,
    observed_builds: %{
      "beam:Elixir.MyApp.SupportAgent" => current_beam_digest
    }
  )

resolution.drift.status # :matched
```

Without trusted observations the status is `:unobserved`. Changed or missing
fingerprints return an error by default. `on_drift: :report` preserves the
drift as evidence but does not claim reproducibility or grant permission to
execute it.

`resolve_for_activation/3` is the publication protocol boundary for the next
activation milestone: it validates Store durability and re-reads the complete
artifact. Version 0.2.2 intentionally does not add Agent stable identity,
activation CAS, checkpoint schema 2, Candidate promotion, or self-modification.

## Conformance and compatibility

`Spectre.Definition.Store.Conformance` can be called from adapter test suites.
It checks immutable duplicate publication and verified read-back; its
`read_after_restart/4` check verifies that two configurations around an adapter
restart resolve identical data.

The Manifest V2 fixture under `test/fixtures/compatibility/0.2.2` is decoded and
re-encoded by both supported CI combinations: OTP 28/Elixir 1.19 and OTP
29/Elixir 1.20. It binds the unchanged canonical Definition fixture introduced
in 0.2.1.
