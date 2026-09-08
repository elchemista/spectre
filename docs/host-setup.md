# Provisioning a Domain

An Agent module says **what the program proposes**. Host setup says **who may
do it, through which services, and where the official facts are stored**.
This is usually application/platform work, shared by many agent Instances;
you do not build a new kernel or ledger for every chat message.

Start with [the Agent example](agents-and-dsl.md#a-small-agent) if you have not
written a handler yet. This guide supplies its missing `scope`, `definition`
and `class_bindings` variables. [Configuration reference](configuration.md#domain-options)
lists the supported startup options and actual defaults.

| Term | Plain meaning |
| --- | --- |
| Host | Your Elixir application and deployment; not a Spectre hosting service |
| Domain | Shared authority/accounting boundary with one ordered history |
| Principal | An identified actor: user, organization, proposer or executor |
| Scope | One authenticated interaction or promised unit of work inside a Domain |
| Foundation / Genesis | The explicitly recognized initial actors, rules and authority |
| Surface | The catalog of actions your app promises to mediate |
| Binding | A reference connecting a prepared request to those actual records |

For example, several support conversations can use separate Instances/Scopes
in one tenant Domain. They share the Domain's authority accounting; a new
Instance does not replenish its refund budget. Choosing Domain boundaries is
an application decision, not inferred from the Agent's `namespace`.

## Prepare the foundation

1. Create immutable `Spectre.Principal` records for the relevant actors:
   grantors, proposers, executors, accountable parties and independent Duty
   disposition authorities. A record identifies an actor; the Ingress must
   still authenticate the actual caller.
2. Define the recognized consequence classes in `Spectre.Surface`, their rows
   of power (the [boolean summary explained here](architecture.md#what-is-a-row)),
   consequence contracts, executor contracts and any governance
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

<!-- spectre:example foundation -->
```elixir
{:ok, foundation} = Spectre.Foundation.new(domain_ref,
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

foundation = Keyword.put(foundation, :genesis_verifier, genesis_verifier)
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

<!-- spectre:example supervised_domain -->
```elixir
domain_opts = Keyword.merge(foundation,
  domain_ref: domain_ref,
  store: {Spectre.Ledger.Store.Disk, server: MyApp.LedgerStore},
  ingress: ingress,
  mind: Spectre.Agent,
  executors: executors,
  broker: broker,
  clock: clock
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
up, `Spectre.lookup_domain(domain_ref)` returns the current handle.
The variables above are host choices: `ingress`, `broker` and `genesis_verifier`
have different contracts: `ingress` is a module; `broker` and
`genesis_verifier` accept a module or `{module, options}`. `executors` is a
list of modules or `{module, options}`, indexed by their executor/contract
identities. `clock` is a module exposing `now/0`. Do not assume every adapter
uses the same tuple form; [the option reference](configuration.md#domain-options)
spells this out.

Use `Spectre.start_domain/3` for a Domain provisioned dynamically, for example
when creating a tenant. That facade starts it under Spectre's Domain supervisor;
it does not move host services into that tree. Do not start the same Domain in
both supervisors. The [dynamic startup fragment](#host-integration)
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
see [reusable work and vigil](agent-recipes.md#reusable-skills-workers-and-vigils).

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

The contract is not a general predicate/JSON-Schema engine: arbitrary ranges,
comparisons and executable policy callbacks do not live in the ledger. For
money, declare the integer unit (for example cents) in the host's Meter/contract.
A payload field called `amount` is not automatically proven equal to the
quantity reserved from a Meter; bind them explicitly. Router confidence and
model-generated explanations cannot supply that missing accounting relation.

Do not put a policy callback in the Router and assume that makes it a kernel
rule. A route selects a handler. The Surface/Constitution and the pure core
decide what can be admitted, and the executor must actually honor its contract.

## Connect a handler to a governed action

The handler returned `{:request, "orders.lookup", %{"order_id" => "42"}, state}`.
It did not say which credentials to use or grant itself permission to read all
orders. Here is the host-side mapping for that class:

<!-- spectre:example lookup_bindings -->
```elixir
{:ok, lookup_power} = Spectre.Row.new(attempt: true, read: true)
{:ok, lookup_contract} = Spectre.Consequence.Contract.new(
  shape: %{"order_id" => "target_ref"}
)

{:ok, lookup_surface} = Spectre.Surface.new(
  revision: 1,
  declarations: %{"orders.lookup" => lookup_power},
  consequence_contracts: %{"orders.lookup" => lookup_contract}
)

class_bindings = %{
  "orders.lookup" => %{
    requested_mandate_ref: lookup_mandate.ref,
    executor_ref: executor_ref,
    executor_contract_ref: executor_contract_ref,
    accountable_ref: accountable_ref,
    purpose_ref: purpose_ref,
    purpose_params: purpose_params,
    observation_window_ms: 5_000
  }
}
```

This is one application class, not a complete foundation. `lookup_mandate`
is the already-created Mandate authorizing the relevant proposer, Scope,
class, targets and purpose. The executor/contract/accountability/purpose
references come from the host's actual registered records; `purpose_params`
is the map allowed by that Mandate. Add your other application and needed
governance classes to the full Surface before Genesis or through its governed
revision path. Constructing `lookup_surface` here does not activate it.

Read the fields as follows:

| Field | Why it exists |
| --- | --- |
| `attempt: true` | This class is an external attempt, so admission must lead through recorded dispatch/Attempt before execution |
| `read: true` | This action reads a resource; the chosen Mandate's power ceiling must allow reading |
| `shape` | Closed payload structure: exactly the fields declared by the consequence contract |
| `"target_ref"` | A contract marker, not a literal order ID: extract `order_id` as the exact target to check against the Mandate |
| `requested_mandate_ref` | Which existing permission to evaluate; a reference is not proof it applies |
| `executor_ref` | Which actor will attempt this class |
| `executor_contract_ref` | Which registered execution contract that actor must honor |
| `accountable_ref` | Which Principal is accountable for the consequence |
| `purpose_ref`, `purpose_params` | Declared reason and its permitted parameters; not a prompt or arbitrary metadata |
| `observation_window_ms` | How long the causal contract expects an observation; not an HTTP timeout and not a retry interval |

Other Candidate fields may be fixed by a named request or supplied by an
application preparation adapter:

| Field | Meaning |
| --- | --- |
| `subject_refs` | Parties affected by the consequence |
| `target_refs` | Resources acted on; derived from this example's contract, not guessed from a route name |
| `evidence_refs` | Recorded supporting facts; preparation binds the authenticated Turn's context |
| `meter_requests` | Exact nonnegative integer quantities requested from each Meter, in the host's declared units |
| `disclosure` | Destinations, source Evidence and labels for information leaving a boundary |
| `consent`, `presentation_ref` | Required consent material and its exact recorded presentation, when applicable |

The handler builder supplies the occurrence identity, proposer/Scope context
and Row. `class_bindings` cannot replace `identity_key`, `row`, `class` or
`consequence`. Independent sources of a fixed field must agree exactly;
conflicts are reported, not resolved by “last option wins”.

In the example, `"order_id" => "43"` changes the target checked by the kernel.
If the Mandate only covers `"42"`, the request is refused regardless of the
Router score. Adding `read: true` to the Surface does not create that Mandate.

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

<!-- spectre:example doctor_config -->
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


## Host integration

This is the dynamic counterpart of the supervision example. All foundation
records, adapters and the trusted `clock` have already been prepared above.
`scope_ref` names the new interaction; `authenticated_request` contains the
credentials/claims your fixed Ingress actually verifies. `now` is trusted host
time, `input` is the input accepted by that Ingress, and `select_proposal` is
your explicit policy for choosing among the custom Mind's proposals.

This lower-level form uses a **custom Mind**, not `mind: Spectre.Agent` (which
requires the Instance handler API). Choose one authoring path, not both.

<!-- spectre:example dynamic_domain -->
```elixir
{:ok, store_pid} = Spectre.Ledger.Store.ETS.start_link()
store = {Spectre.Ledger.Store.ETS, server: store_pid}

{:ok, domain} =
  Spectre.start_domain(domain_ref, store,
    constitution: constitution,
    genesis: genesis,
    principals: principals,
    host_profile: host_profile,
    surface: surface,
    root_mandates: root_mandates,
    genesis_verifier: genesis_verifier,
    ingress: ingress,
    mind: mind,
    executors: executors,
    broker: broker,
    clock: clock
  )

{:ok, context} = Spectre.authenticate(domain, scope_ref, authenticated_request)
{:ok, scope} = Spectre.open_scope(domain, context, opened_at: now)

{:ok, %{candidates: candidates}} = Spectre.turn(scope, input)
# Application policy selects a proposal; the list may contain alternatives.
candidate = select_proposal.(candidates)
{:ok, result} = Spectre.propose(scope, candidate)
```

The ETS store here is volatile. Use the supervised durable-store form for
promises that must survive a restart. `{:ok, result}` is a completed API call,
not proof of successful execution; inspect the Decision and Outcome.
