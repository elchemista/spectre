# Provisioning a Domain

An Agent declaration is not a deployable authority boundary by itself. The host
must supply a foundation, fixed adapters and supervision. This checklist makes
that wiring explicit; it does not manufacture a permissive default Mandate.

## Prepare the foundation

1. Create immutable `Spectre.Principal` records for the relevant actors:
   grantors, proposers, executors, accountable parties and independent Duty
   disposition authorities. A record identifies an actor; the Ingress must
   still authenticate the actual caller.
2. Define the recognized consequence classes in `Spectre.Surface`, their rows
   of power, consequence contracts, executor contracts and any governance
   classes this Domain will use. Register only the surface you intend to mediate.
3. Define root `Spectre.Mandate` records with explicit holders, coverage,
   Conditions, Meter ceilings, time bounds and allowed delegation/revocation
   behavior. Cover the required Scopes and targets; authentication or object
   creation must not imply new authority.
4. Declare `Spectre.HostProfile` and a Constitution with the Duty rules and
   independent disposition routes required by the deployment. The Constitution
   is pinned for this Domain's lifetime.
5. Construct `Spectre.Genesis` against those exact references. Configure a
   `Spectre.Genesis.Verifier` that represents the host's external recognition.
   `Verifier.Allowlist` is an allowlist of recognized attestation references,
   not cryptographic verification of a signature.

Use each record's `new/1` and canonical API rather than hand-building raw ledger
maps. Validation establishes shape and consistency; it does not establish that
an external actor really consented or signed. Do not put credentials in any of
these portable records.

### Assemble the links without choosing policy

`Spectre.Foundation.new/2` removes the manual copying of content references into
Genesis. This fragment assumes the records above have already been explicitly
prepared; it is not a default foundation or an authority generator:

```elixir
{:ok, foundation} = Spectre.Foundation.new("domain:payments",
  genesis: %{
    ref: genesis_ref,
    issued_at: issued_at,
    attestation_ref: attestation_ref,
    emergency_mandate_ref: nil
  },
  constitution: constitution,
  principals: principals,
  root_mandates: root_mandates,
  surface: surface,
  host_profile: host_profile
)

foundation = Keyword.put(foundation, :genesis_verifier, MyApp.GenesisVerifier)
```

Supply all six bundle fields and all four Genesis metadata fields. An explicit
`nil` means no emergency Mandate. The root Mandates must already name the chosen
`genesis_ref` in `source_ref`; the builder does not rewrite them. It derives the
remaining Genesis links from the exact records and previews the ordinary
bootstrap fold at `issued_at`, including independent Duty disposition routes.
It does not pick expiry, budgets, Principals, clock or credentials, call a
verifier, write a ledger or start a process.

The result is an ordinary keyword list accepted by dynamic startup or the child
spec below. A successful preview is **not external recognition**: the host still
has to obtain the attestation and implement its verifier. Startup rechecks the
bundle at its trusted time and calls that verifier. Using the record constructors
and `Genesis.new/1` directly remains supported; neither helper is mandatory.

## Wire and supervise the boundaries

For a Domain that belongs to the application's static topology, use its
ordinary OTP child specification. This is a wiring fragment: `foundation`
contains the explicitly prepared Genesis, Constitution, Principals, Mandates,
Surface, HostProfile and verifier described above; `directory` is chosen by
the host. No authority records are invented by startup.

```elixir
domain_opts = Keyword.merge(foundation,
  domain_ref: "domain:payments",
  store: {Spectre.Ledger.Store.Disk, server: MyApp.LedgerStore},
  ingress: MyApp.Ingress,
  mind: Spectre.Agent,
  executors: [MyApp.PaymentExecutor],
  broker: MyApp.CredentialBroker
)

children = [
  {Spectre.Ledger.Store.Disk, name: MyApp.LedgerStore, directory: directory},
  {Spectre.Domain, domain_opts}
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

OTP starts children in order. With `:rest_for_one`, failure of the earlier store
restarts the Domain after it; a Domain failure does not restart that store.
Choose the strategy and grouping for the actual resource dependencies. Spectre's
application must be started for its default Registry to exist. Once the tree is
up, `Spectre.lookup_domain("domain:payments")` returns the current handle.

Use `Spectre.start_domain/3` for a Domain provisioned dynamically, for example
when creating a tenant. That facade starts it under Spectre's Domain supervisor;
it does not move host services into that tree. Do not start the same Domain in
both supervisors. The [README startup fragment](../README.md#host-integration)
shows this dynamic form. Both forms use the same core and configuration:

| Configuration | Meaning |
| --- | --- |
| `store` (option or facade argument) | Domain ledger adapter; choose a durability boundary appropriate to its promises |
| `ingress` | Fixed authentication/observation adapter, not a per-request override |
| `mind` | Capability-free deliberation callback, when turns are used |
| `executors` | Host registry of accepted executor identities/contracts |
| `broker` | Act/Attempt-scoped capability checkout boundary |
| `payload_store` | Presence/digest verification for external content-addressed payloads |
| `late_observer` | Optional independently obtained observations about earlier Attempts |
| `clock` | Trusted time source, checked by the runtime clock guard |
| `recovery_policy` | Optional external witness check and incident notification |

Supervise the actual ledger/payload/credential services in the host application. Do not
start a volatile ETS store inside a request that will exit. Distinct backend
durability and ownership limits are described in [storage](storage-and-recovery.md).

The Domain creates a new generation and runtime seals at boot. Do not hard-code
test generations, test secrets or a passthrough credential broker into a real
deployment. `Spectre.Secret.Broker.Passthrough` is not a credential manager.

## Authenticate, open and use a Scope

`Spectre.authenticate/4` invokes the fixed Ingress for a Domain and Scope
reference. The resulting SubmissionContext binds the principal, ingress,
channel/session and current host generation. It is not a user-supplied claims
map and is not a new Mandate.

`Spectre.open_scope/3` records an ordinary opening from that context.
`Spectre.resume_scope/2` requires an already recorded, compatible opening.
Work/Vigil use the governed parent-Scope opening path with a finite promise;
see [agent authoring](agents-and-dsl.md#work-and-vigil).

An open Scope does not imply permission to execute every class. Build Candidates
against the actual Mandate coverage. Register/revise a Definition through
`Spectre.revise_definition/4` before binding an Instance to it; compiling or
publishing a Definition in `Spectre.Definition.Store` does not activate it.

After a Domain restart, authenticate again. Neither serializing a Scope nor
restoring an Instance checkpoint carries old authentication into a new generation.
`resume_scope` requires the original immutable opening's authentication and
generation to match. A new generation requires a new Scope occurrence, not
reauthentication attached to the old opening. Its Mandate coverage must also
be provided explicitly; opening it does not transfer authority from the old one.
Keep unresolved effects in the ledger and obtain later observations as needed;
do not recreate them by replaying a previous `propose` call blindly.

`{Spectre.Instance, scope: scope, definition_ref: definition.ref}` is also an
ordinary child specification, but `scope` must already be authenticated and
opened, and the exact Definition must be governed in that Domain. A bare
`scope_ref` is not sufficient. If the host wraps startup in its own child module,
that module must obtain fresh authentication and, after a Domain generation
change, open a new Scope with appropriate authority. Do not retain an old Scope
in a static child specification. There is no automatic credential or
authentication policy in `use`, `child_spec` or an Extension's `install` block.

## Business limits are explicit

`Spectre.Consequence.Contract` supplies closed structural constraints and
bindings, not an arbitrary predicate language. To model a limit such as
"refund at most X", decide whether X is a conserved Meter quantity or a
Condition supported by trusted Evidence. Specify who attests that Evidence,
its exact bindings and validity, and what contradictory Evidence means.

Do not put a policy callback in the Router and assume that makes it a kernel
rule. A route proposes a template. The Surface/Constitution and the pure core
decide what can be admitted, and the executor must actually honor its contract.

## Read and diagnose

`Spectre.head/1` returns the verified revision and head digest.
Scope queries include `view/1`, `authority/2`, `acts/2`, `duties/2`,
`erasures/1` and `declassifications/1`. They expose application facts, not
capabilities. Prefer a targeted query to repeatedly requesting the broad view.
General cursor pagination is not yet implemented; do not assume an arbitrary
`limit` option is supported.

Failures are structured terms, not a central catalog of UI messages.
Translate recognized codes in the application; use a constant fallback for
unknown reasons. Do not inspect arbitrary exceptions, input or provider data in
public errors. Keep protected diagnostics separate. `Spectre.Proposal.Result.status/1`
and the handler's `result.status` distinguish admission from execution; neither
an error message nor a timeout authorizes retry.

Configure and run `mix spectre.doctor` to inspect declared boundary wiring and
ordinary compiled dependencies. Export and audit the canonical history for
independent semantic checks. These tools do not prove real identities, trusted
provider behavior or absence of alternate network/credential paths.

For Extension ports, supply the actual named adapter map from host wiring:

```elixir
config :spectre, :doctor,
  ingress: MyApp.Ingress,
  port_wiring: %{MyApp.SupportAgent => wired_ports}
```

`wired_ports` has the same grouped form as Instance startup, for example
`[history: [chat: {MyApp.History, tenant_id: tenant, conversation_id: conversation}]]`.
Complete static adapter declarations need no redundant empty runtime binding.
Missing dynamic ports and misspelled names are reported. Omitting `port_wiring`
means the check was not performed.
Do not simply pass `MyApp.SupportAgent.ports()` as proof that you wired it:
declaration is not connection. Doctor validates module/configuration shape and
name coverage, not actual runtime usage, connectivity or suitability for a
particular boundary. That boundary still checks its own behaviour. It never
installs, resolves or starts anything.

For incident handling, clock behavior, timeouts and ambiguous writes, continue
with [storage and recovery](storage-and-recovery.md). For integration-specific
streaming and UI concerns, use [input and streaming](integration-and-streaming.md).
