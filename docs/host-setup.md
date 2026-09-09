# Connect an agent to your application

You have a handler that proposes an order lookup. Now it needs a real place
to run, a permission to use, and an executor that can talk to your order service.

That is **host setup**. “Host” means your Elixir application—not a Spectre
hosting service.

You normally do this once for a shared Domain, not once for every message.
Several conversations can use separate Instances in the same Domain.

## Before you start

The [small Agent](agents-and-dsl.md#a-small-agent) used three values that
did not come from the DSL:

| Value | What it connects |
| --- | --- |
| `definition` | The particular agent version your application has activated |
| `scope` | The authenticated interaction in which it will work |
| `class_bindings` | Each requested action to existing permission and execution records |

This guide explains where they come from. For the complete option list, use
[configuration](configuration.md#domain-options) as a reference.

A Domain has shared rules, accounting and an ordered history. An Instance has
local conversation/job state. Creating a new Instance does not replenish the
Domain's budget. The Agent's `namespace` does not automatically create a tenant
or authenticate one.

## From a draft to your first governed save

If you used `spectre.gen.agent`, the next generator creates the application
files needed to turn its greeting draft into a save request:

```sh
mix compile
mix spectre.gen.host MyApp.Hello --class greeting.save --dry-run
mix spectre.gen.host MyApp.Hello --class greeting.save
```

The Agent must already be compiled. `--dry-run` shows the target files without
writing them. The generator refuses existing paths; there is no force-overwrite
option. It does not edit the original Agent or your supervision tree.

### What the generator gives you

| File | Your part |
| --- | --- |
| `lib/my_app/hello/host.ex` | Choose the initial authority, store and host adapters |
| `lib/my_app/hello/executor.ex` | Implement the actual save |
| `test/my_app/hello_governed_test.exs` | Connect a test backend and verify the full path |

Start with `MyApp.Hello.Host.missing_setup/0`. It returns the unfinished
configuration fields. Until those fields are supplied, `domain_options/0`
returns `{:error, {:incomplete_host_setup, missing}}` instead of starting
a partly configured Domain.

The generated test fails with that checklist. Complete it; do not skip the
test. An empty checklist means the placeholders are filled, not that your
chosen permissions or backend are automatically correct.

### Complete the save contract

The generated `application_surface(revision)` describes one class:
`greeting.save`. Its consequence contains the target to save to and the
greeting text. Its Row says the operation attempts an external write.

In `Executor.configuration/0`, supply:

- `executor_ref`: the actor performing the save;
- `contract_ref`: the registered contract that implementation follows;
- `execute`: your function receiving the Act, Attempt, broker capability and
  backend options.

The execution result must use the existing `Spectre.Attempt.Executor`
contract and include the relevant receipt Evidence. There is no additional
scaffold-specific backend behaviour to implement.

The command prints the Agent change for you to apply: declare
`:save_greeting`, then return a request containing the rendered text and
`state.greeting_box_ref`. Validate that target in `init/1`.

Activate the changed Definition before starting its Instance.

### What the test should establish

The full path is:

```text
greeting input → handler → prepared save request
  → advance → permission decision → recorded Act/Attempt
  → your backend saves → recorded Outcome
```

The test should show that a turn alone does not save, one admitted advance
saves once, and the resulting history audits successfully. Use real test
backend readers/counters rather than a callback that always returns success.

Saving a greeting is not sending it to a person. If you also deliver it, that
is another operation to model. A timed-out save must not be repeated simply
because the caller did not receive a response.

For an existing Domain, reuse its foundation and governed revision procedures;
do not bootstrap another Domain for each Instance.

## Prepare the foundation

The foundation answers: **who are the actors, what can be done, and who is
initially allowed to do it?**

Prepare these records with their `new/1` constructors:

### 1. Identify the actors

A `Spectre.Principal` identifies an actor: a proposer, executor, accountable
party, or someone allowed to resolve an obligation.

Creating a Principal record is not authentication. Your ingress must still
verify who is actually making the request.

### 2. Declare the actions

A `Spectre.Surface` lists governed action classes, their powers and consequence
contracts. For example, `orders.lookup` reads one specified order.

Start with the operations you intend to mediate. Add the governance classes
needed to publish or revise records deliberately; do not hand their permission
to every business agent.

### 3. Grant limited initial authority

Root `Spectre.Mandate` records state who may act, on which targets and Scopes,
for which purposes, within which time and resource limits.

A login is not a Mandate. A route match is not a Mandate. The selected request
must actually fit one.

### 4. Decide how unresolved work is handled

The Constitution defines Duty rules and who can dispose of those Duties.
The HostProfile records the host's declared execution assumptions.

Choose the required independent authorities up front. The Constitution is
fixed for the Domain's lifetime in 0.4.

### 5. Recognize this exact starting point

Genesis links the initial records. A configured `Spectre.Genesis.Verifier`
checks the host's recognition of that foundation.

The supplied `Verifier.Allowlist` recognizes listed attestation references.
It is not a signature verifier. Constructors check shape and consistency, not
whether an external person signed or consented.

Do not put credentials into foundation records.

### Assemble the links without choosing policy

Once those records exist, `Spectre.Foundation.new/2` avoids manually copying
all their content references into Genesis:

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

The variables are the records you just prepared. In the Genesis metadata:

- `ref` identifies this Genesis; root Mandates must already name it as their
  `source_ref`.
- `issued_at` is the explicit starting time.
- `attestation_ref` names the external recognition the verifier will check.
- `emergency_mandate_ref: nil` explicitly says no emergency Mandate is used.

The helper derives the remaining links and checks the initial fold. It returns
ordinary startup options. It does not call a verifier, start processes, write
the ledger, or choose an expiry or budget.

Actual startup verifies the foundation again at the trusted host time.
Using the individual constructors and `Genesis.new/1` directly is also supported.

## Wire and supervise the boundaries

For a Domain that starts with your application, put its store before the Domain
in your supervision tree:

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

`foundation` is the keyword list from the previous step.
`directory` is the host-chosen location for this ledger.
The remaining values connect application code:

| Option | What the connected code does |
| --- | --- |
| `ingress` | Authenticates callers and records accepted input observations |
| `mind: Spectre.Agent` | Selects the Agent handler API |
| `executors` | Implements the governed external operations |
| `broker` | Gives an admitted Attempt access to its scoped capability |
| `clock` | Supplies trusted time |
| `store` | Persists and reads the Domain ledger |

OTP starts children in order. With `:rest_for_one`, a store failure also
restarts the later Domain; a Domain failure does not restart the earlier store.
Choose the strategy for your actual dependencies.

Spectre's application must be running so its default Registry exists.
After startup, `Spectre.lookup_domain(domain_ref)` gets the current handle.

### The adapter forms are not all identical

`ingress` and `clock` are modules. The broker and Genesis verifier accept a
module or `{module, options}`. `executors` is a list of modules or such tuples.

Optional boundaries include `payload_store` for external content verification,
`late_observer` for later receipts, and `recovery_policy` for witness checks
and incident notification. See [Domain options](configuration.md#domain-options)
when wiring one.

Supervise database, payload and credential services in your application.
Do not start a volatile ETS ledger from a short-lived HTTP request process.

Leave generated secrets and Domain generation IDs to normal startup.
Hard-coded test values and the Passthrough broker are not production credential
management.

### When the Domain is created later

Use `Spectre.start_domain/3` for dynamic provisioning, such as creating a
tenant. It starts the Domain under Spectre's Domain supervisor. It does not
start your database or credential services.

Use one ownership path for a Domain, not both. The
[lower-level example](#host-integration) shows dynamic startup with a custom Mind.

## Authenticate, open and use a Scope

The Domain exists. Now bind one interaction to it.

1. Call `Spectre.authenticate/4` through the Domain's fixed ingress.
   The result is a verified SubmissionContext, not a claims map supplied by
   the user.
2. Open the interaction with `Spectre.open_scope/3`.
   `resume_scope/2` is for an already recorded, compatible opening.
3. Activate the agent's Definition using the normal
   `Spectre.revise_definition/4` path.
4. Start the Instance using that Scope and Definition.

An open Scope is not permission for every action class. The chosen Mandate
still needs to cover the request.

Constructing a Definition—or storing it with `Spectre.Definition.Store`—is
not the same as activating it in the Domain.

### After a Domain restart

A new Domain generation invalidates old runtime authentication. Obtain fresh
authentication and open a new Scope occurrence with appropriate authority.

Do not put a stale Scope in a permanent child specification and expect restart
to renew it. A host-owned startup wrapper can obtain the new authentication
and Scope before starting the Instance.

Old unresolved effects remain in the ledger. Recover or obtain later
observations; do not replay old `propose` calls to recreate them.

Work and Vigil have a separate governed opening that records their finite
promise. See [starting reusable jobs](agent-recipes.md#reusable-skills-workers-and-vigils).

## Connect a handler to a governed action

The Agent proposed:

`{:request, "orders.lookup", %{"order_id" => "42"}, state}`

Here is the host-side connection for that class. The referenced Mandate,
Principals, purpose and executor contract must already be supplied by the host.

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

### Read the Surface first

`attempt: true` means the operation crosses the external execution boundary.
`read: true` means it reads a resource. This is the
[Row](architecture.md#what-is-a-row), not permission to read any order.

The contract's `shape` describes the accepted consequence fields.
In `"order_id" => "target_ref"`, **`"target_ref"` is a marker**: take the
value of `order_id` and check it as the operation's target. It is not a
literal value the handler should send.

So changing `"42"` to `"43"` changes the target being authorized. If the
Mandate covers only order 42, a perfect regex match for order 43 is not enough.

This Surface fragment defines one class. Add the other needed classes to your
full Surface and activate it through Genesis or a governed revision.

### Then read the binding map

| Binding | Question it answers |
| --- | --- |
| `requested_mandate_ref` | Which existing permission should be checked? |
| `executor_ref` | Who will attempt the operation? |
| `executor_contract_ref` | Which registered execution contract applies? |
| `accountable_ref` | Who is accountable for the consequence? |
| `purpose_ref`, `purpose_params` | What declared purpose and parameters justify this use? |
| `observation_window_ms` | When is an observation expected? This is not the HTTP timeout or a retry interval |

Other request data may describe affected parties (`subject_refs`), resource
quantities (`meter_requests`), information recipients (`disclosure`) and
consent (`consent`, `presentation_ref`).

The builder supplies the occurrence identity, authenticated proposer/Scope
and Row. It also connects the Turn's Evidence. A class binding cannot replace
`identity_key`, `row`, `class` or `consequence`.

If two sources fix the same field, they must agree. Spectre reports a conflict
rather than silently choosing one.

## Business limits are explicit

A consequence contract checks structure and extracts bindings. It is not an
arbitrary policy language.

For “refund at most €50,” decide what the limit represents:

- a conserved spend budget belongs in Meter accounting;
- a business fact must be established by an appropriate Condition and Evidence.

Declare the units—for example integer cents—and bind the payload amount to
the quantity being reserved. A field named `amount` is not automatically
a Meter quantity.

Likewise, a `max_tokens` provider option is not automatically a token budget.
The Surface, request/executor contract and accounting must agree.

Router scores and model explanations do not replace these checks.

## Read and diagnose

Use narrow queries for the information you need:

- `Spectre.head/1`: current verified revision and digest;
- `authority/2`: available authority;
- `acts/2`, `duties/2`: recorded operations and outstanding obligations;
- `erasures/1`, `declassifications/1`: information-lifecycle records.

`view/1` is broader and can be expensive. General cursor pagination is not
implemented; do not invent a `limit` option.

Errors are structured terms. Your UI translates known codes and gives a safe
generic message for unknown ones. Avoid printing arbitrary provider errors,
input or credential values to users.

Doctor can check whether declared ports have actual wiring:

<!-- spectre:example doctor_config -->
```elixir
config :spectre, :doctor,
  ingress: MyApp.Ingress,
  port_wiring: %{MyApp.SupportAgent => wired_ports}
```

`wired_ports` is the same grouped adapter map used at Instance startup, such
as the History backend and tenant/conversation options.

Do not pass `Agent.ports()` as proof of wiring: that lists requirements, not
the live connections you supplied. Omitting `port_wiring` skips that check.

Doctor checks configuration, not remote connectivity or identity. Audit checks
recorded history, not whether an external provider is honest.
For incidents, continue with [storage and recovery](storage-and-recovery.md).

## Host integration

### Lower-level alternative: a custom Mind

You can use a custom Mind instead of the Agent handler API. This example is
for that alternative; `mind` is not `Spectre.Agent`.

The foundation and adapters have already been prepared.
`authenticated_request` is what your ingress verifies; `select_proposal`
is your application's choice among the Mind's proposed alternatives.

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

The ETS store in this example is volatile. Use the supervised durable form
above when records must survive a restart.

Finally, `{:ok, result}` means the API call completed. Check its Decision and
Outcome before telling a user the operation succeeded.
