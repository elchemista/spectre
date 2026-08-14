# Work, Vigil, and the operational runtime

Spectre 0.2.0 adds durable operational loops alongside conversational Runs.
They solve different problems:

- a `Spectre.Run` advances one conversational interaction;
- a `Spectre.Work` performs one precise, terminating procedure;
- a `Spectre.Vigil` observes repeatedly and waits between triggers;
- an external controller, such as Directive, can use the same runtime without
  adding a second state owner.

The Subject-scoped `Spectre.Instance` is the only local owner of canonical
state. A Runner receives a revision-fenced snapshot, executes exactly one
registered operation attempt, returns data, and terminates. It never commits
canonical state itself.

## Define and start a Work

Operations are closed-catalog declarations. They refer to loaded modules and
functions; a model cannot supply a new executor at runtime.

```elixir
defmodule MyApp.Pages do
  def fetch(%{page: page}, _context) do
    {:ok, %{page: page, body: MyApp.HTTP.fetch_page(page)}}
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent

  operation :fetch_page, {MyApp.Pages, :fetch},
    input: :map,
    output: :map,
    side_effect: :idempotent,
    retry: [max_attempts: 3, base_delay_ms: 100, max_delay_ms: 1_000]
end

defmodule MyApp.ReadPages do
  use Spectre.Work,
    id: :read_pages,
    version: 1,
    input: :map,
    state: :map,
    update: :map,
    update_fields: [:pages],
    budget: [steps: 100, attempts: 150]

  uses_operation(:fetch_page)

  @impl true
  def init(input, _context) do
    {:ok, %{queue: input.pages, pages: []}}
  end

  @impl true
  def next(%{queue: [page | _]}, _context) do
    run(:fetch_page, %{page: page}, phase: :reading)
  end

  def next(%{queue: []}, _context), do: complete(:pages_read)

  @impl true
  def apply_result(%{queue: [_ | rest]} = state, _request, result, _context) do
    {:ok, %{state | queue: rest, pages: [result.value | state.pages]}}
  end

  @impl true
  def complete(%{queue: [], pages: pages}, _context) do
    complete(Enum.reverse(pages))
  end

  def complete(_state, _context), do: :continue
end
```

Start it on a supervised Instance:

```elixir
subject = Spectre.Subject.new({:account, account_id})

{:ok, instance} =
  Spectre.instance(MyApp.SpectreSupervisor, MyApp.Agent, subject)

{:ok, ref, view} =
  Spectre.start_work(instance, MyApp.ReadPages, %{pages: [1, 2, 3]},
    origin: :web,
    correlation_id: request_id
  )
```

`uses_operation/1` imports only that stable operation from the Agent registry.
A Work can instead declare a private operation with `operation/3`. It cannot
see the rest of the Agent catalog implicitly, and a running Work cannot start
another Work.

## Controller contract

`Spectre.Work` and `Spectre.Vigil` implement
`Spectre.Operation.Controller`. Controller callbacks are deterministic state
reducers. Slow I/O, Actions, effects, and inference belong in registered
operations.

The main decisions returned by `next/2` are:

```text
{:run, request}       execute one registered operation
{:wait, wait}         persist a wait boundary without a live Runner
{:blocked, blocker}   persist a declared human blocker
{:complete, value}    terminate successfully
{:error, reason}      terminate with a typed failure
```

`apply_result/4` receives only a validated, fenced result. `complete/2`
decides completion from committed controller state. Definitions declare their
input, state, update schema, closed branches, blockers, waits, triggers,
security policy, publication policy, and budget.

An external controller with `kind: :directive` may additionally declare
`can_start: [:work]`. Its successful reducer can then propose Work starts as
part of the Result transition:

```elixir
def __spectre_loop_definition__ do
  Spectre.Operation.Definition.new(
    id: :research_mission,
    version: 1,
    kind: :directive,
    input: :map,
    state: :map,
    can_start: [:work]
  )
end

def apply_result(state, _request, result, _context) do
  intent =
    {:work, MyApp.ReadPages, %{pages: result.value.pages},
     [intent_id: :read_pages, id: state.work_id]}

  {:ok, %{state | phase: :waiting_for_pages}, start_loops: [intent]}
end
```

`intent_id` is required and stable. If `:id` or `:correlation_id` is omitted,
the runtime derives it deterministically from the parent loop and intent.
Controller-supplied child options are limited to `:intent_id`, `:id`,
`:correlation_id`, `:expires_at`, `:budget`, `:cognitive`, and `:metadata`.
Origin, provenance, Subject visibility, authorized origins, destinations,
Turn ownership, and causation are inherited or assigned by the Agent.

The parent Result, parent state, child Work, child control state, correlations,
and their events are committed at one canonical revision. Child
initialization or validation failure rejects the whole transition.

Intents are idempotent: re-proposing an intent whose Work already exists with
the same parent and intent provenance is a committed no-op, reported in the
`:loops_started` payload with `already_started: true`. Only an id collision
with different provenance rejects the transition. A Work or
Vigil Definition cannot declare `can_start`, and direct `start_work` calls
from a Runner or its isolated executor are rejected. The supported boundary
is a Directive reducer intent; the Runner never owns the capability.

## Operation kinds

`Spectre.Operation.Spec` supports five provider-neutral kinds:

- `:function` invokes a registered module/function callback;
- `:action` dispatches through the Agent's registered Action provider;
- `:effect` dispatches through a registered extension effect executor;
- `:planner` may select only an entry in its declared catalog;
- `:cognitive` validates output against a finite domain and can use retry and
  a deterministic fallback.

Inputs, outputs, domain values, execution envelopes, artifacts, and checkpoint
data are validated for both semantics and portability. PIDs, ports,
references, and anonymous functions are rejected from canonical values.

An operation that can cross an external side-effect boundary must classify
that boundary:

```elixir
operation :publish, {MyApp.Publisher, :publish},
  side_effect: :reconcilable,
  reconcile: {MyApp.Publisher, :reconcile},
  retry: [max_attempts: 2]
```

The supported classifications are `:none`, `:idempotent`, `:reconcilable`,
and `:non_idempotent`. A crash does not prove whether a side effect happened.
Spectre retries only when the declaration and retry policy permit it. An
unknown non-idempotent outcome waits for reconciliation instead of being
reported as success or repeated automatically.

## Inspect and resolve loops

Views are read-only, privacy-safe projections:

```elixir
{:ok, view} = Spectre.loop(instance, ref)
{:ok, visible} = Spectre.loops(instance, origin: :web)

{:ok, selected} =
  Spectre.resolve_loop(instance,
    kind: :work,
    definition: :read_pages,
    status: [:active, :waiting, :paused]
  )
```

When a selector matches more than one loop, `resolve_loop/3` returns
`{:error, {:ambiguous_operation_loops, candidates}}`. It never guesses from
model output. Visibility is checked from Subject, origin, authorized origins,
and the loop's visibility policy.

The view exposes status, phase, progress, attempts, retries, partial results,
published artifacts, budget, last update, pending control, next trigger,
`wait_ref`, and reconciliation state. `artifact_policy` can independently set
`publish_results`, `publish_artifacts`, `publish_progress`, and
`publish_blocker`; all default to `true`. Redaction changes only the public
projection, never canonical state. `wait_ref` remains visible because it is a
fencing token rather than blocker or progress content.

## Correlate external triggers to one wait

A waiting view exposes the complete reply handle:

```elixir
wait_ref = view.wait_ref

{:ok, next_view} =
  Spectre.trigger_loop(instance, ref, {:human, :approved},
    wait_id: wait_ref.id,
    generation: wait_ref.generation
  )
```

The Definition can require both fields for human, external, event, and
reconciliation waits:

```elixir
security: %{trigger_correlation: :required}
```

`security: %{require_trigger_correlation: true}` is the compatible boolean
spelling. Missing fields return
`{:operation_trigger_correlation_required, missing_fields}`; mismatched fields
return the existing stale-wait or stale-generation error before the controller
runs. Correlation fences replay and does not replace Subject/origin
authorization.

The 0.3.1 default remains `:legacy` for patch-release compatibility. An accepted
partially or wholly uncorrelated trigger records `correlation: :legacy` in its
committed `:triggered` event and emits
`[:spectre, :instance, :uncorrelated_operation_trigger]` telemetry. Supplying
both fields records `correlation: :exact`. New deployments should opt in to
`:required` explicitly; a future default change requires its own migration and
is not hidden in this patch release.

## Pause, update, resume, renew, and stop

Control commands are correlated, revision-fenced, idempotent transitions:

```elixir
{:ok, pause_requested} = Spectre.pause_loop(instance, ref)

{:ok, updated} =
  Spectre.update_and_resume_loop(instance, ref, %{pages: [4, 5]},
    command_id: update_id,
    correlation_id: turn_id,
    provenance: %{source: :chat}
  )

{:ok, resumed} = Spectre.resume_loop(instance, ref)
{:ok, renewed} = Spectre.renew_loop(instance, ref, expires_at)
{:ok, stopped} = Spectre.stop_loop(instance, ref, :cancelled_by_user)
```

A safe pause prevents the scheduler from starting another attempt and reaches
the next safe boundary. Immediate interruption additionally requires both
caller authorization and a Definition that permits it. Interruption fences
the old attempt; it does not assume that an external side effect was undone.

Only fields declared by `update_fields` can change. `apply_update/4` validates
and reduces the update, advances the context revision, records provenance, and
invalidates stale attempts or timers. `update_and_resume_loop/4` persists the
pause-update-resume sequence so restart cannot apply the update twice.

A terminal stop cannot be resumed. Pausing or stopping an external Directive
controller does not implicitly pause or stop independent Work loops.

## Define a Vigil

A Vigil uses the same operation runtime but remains registered while it waits.
No Runner needs to stay alive between observations.

```elixir
defmodule MyApp.WeatherVigil do
  use Spectre.Vigil,
    id: :weather_vigil,
    version: 1,
    input: :map,
    state: :map,
    waits: [:timer],
    triggers: [:timer],
    budget: [attempts: 1_000]

  uses_operation(:read_weather)

  @impl true
  def init(input, _context), do: {:ok, %{input: input, observe?: true}}

  @impl true
  def next(%{observe?: true, input: input}, _context), do: observe(:read_weather, input)
  def next(%{observe?: false}, context), do: wait_for(:timer.minutes(5), context)

  @impl true
  def apply_result(state, _request, result, _context) do
    significance = if important_change?(result.value), do: :significant, else: :silent
    {:ok, %{state | observe?: false}, significance: significance}
  end

  @impl true
  def handle_trigger(state, {:timer, _wait_id}, _context) do
    {:ok, %{state | observe?: true}}
  end

  defp important_change?(weather), do: weather.alert == true
end

{:ok, vigil_ref, _view} =
  Spectre.register_vigil(instance, MyApp.WeatherVigil, %{city: "Rome"})
```

Timer messages carry a trigger generation. Updating, pausing, or resuming the
Vigil invalidates messages from older generations. Significant and silent
observations are separate committed event types; significance does not by
itself authorize human delivery.

## Canonical checkpoints and recovery

The Instance checkpoint contains versioned Flow, Work, Vigil, external
controller, control, correlation, and event sections. Every commit advances a
global revision and only the revisions of sections it writes.

Configure a durable adapter implementing
`Spectre.Instance.CheckpointStore`:

```elixir
defmodule MyApp.Checkpoints do
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(instance_ref, opts), do: MyApp.Storage.load(instance_ref.key, opts)

  @impl true
  def compare_and_swap(instance_ref, json, expected, revision, opts) do
    MyApp.Storage.compare_and_swap(instance_ref.key, json, expected, revision, opts)
  end
end

{:ok, instance} =
  Spectre.instance(MyApp.SpectreSupervisor, MyApp.Agent, subject,
    checkpoint_store: {MyApp.Checkpoints, tenant: tenant_id},
    checkpoint_mode: :async
  )

{:ok, persisted_revision} = Spectre.flush_checkpoint(instance)
status = Spectre.checkpoint_status(instance)
```

`checkpoint_status/1` is a passive monitoring projection. It reports whether a
store is configured, the checkpoint mode, canonical/persisted/inflight/pending
revisions, a redacted `error` class, and any reconciliation requirement. It
does not expose the adapter reason or checkpoint payload and does not reset the
Instance idle timer. `Spectre.Instance.info/1` has the same passive monitoring
semantics, and `trace_id/1` inherits them because it is derived from `info/1`.
Direct state, `ref/1`, `agent/1`, configuration, lifecycle, retained
Run/Event/Loop, Skill-state, and checkpoint-payload reads are host interactions
with the live Instance and continue to re-arm the idle timer. A positive
`canonical_revision - persisted_revision` is persistence lag; an error or
reconciliation requirement needs operator attention before assuming the last
write committed.

The store must return `{:error, {:ambiguous, reason}}` when it cannot know
whether a CAS write committed. Spectre erects a persistence fence and does not
retry that write automatically. The host must call
`Spectre.reconcile_checkpoint/2`, which loads and validates the stored
checkpoint before deciding whether the write committed, did not commit, or
conflicts.

Restore validates the entire semantic graph: loop kind and Definition
version, loop/control correspondence, event identity and revision, Subject
ownership, consent and receipt targets, correlation references, and portable
state. Active attempts are recovered with a new Agent epoch, snapshot,
attempt id, and fencing token.

### Bounded replay and audit windows

The retained windows are part of the 0.2.x contract:

- the canonical transition journal retains the newest 512 transitions;
- canonical change-id replay detection retains the newest 1,024 applied
  changes;
- each loop control plane retains the newest 128 completed commands;
- the committed operational-event projection retains the newest 512 events.

These are count-based, currently fixed limits. A duplicate canonical change
or completed control command is guaranteed to be recognized only while its
receipt remains in the corresponding window. Eviction permits the identifier
to be treated as new; it does not make an external side effect safe to repeat.
External effects still need their own durable idempotency or reconciliation
contract. The transition journal and event projection are audit/observation
retention, not additional deduplication stores.

## Events, Flow routing, and delivery

Operational events are committed records, not notifications. Read or
subscribe to them independently:

```elixir
events = Spectre.operation_events(instance, types: [:completed])

{:ok, _subscription} = Spectre.subscribe_operation_events(instance)

receive do
  {:spectre, :operation_event, event} -> inspect(event)
end
```

An Agent can route selected committed events back through its normal Flow
router:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent
  route_operation_events([:completed, :observation_significant])
end
```

This creates an ordinary internal Run; there is no second event matcher or
state owner.

Proactive delivery is a separate authorization step. Store consent, authorize
a destination, let Beam or the host perform transport, then record the
outcome:

```elixir
{:ok, consent} = Spectre.put_delivery_consent(instance, consent_attrs)

{:ok, receipt} =
  Spectre.authorize_delivery(instance, event.id, destination,
    event_types: [:completed],
    channels: [:email],
    max_deliveries: 3,
    window_ms: :timer.hours(1)
  )

case MyApp.Transport.deliver(destination, message) do
  {:ok, external_receipt} ->
    Spectre.record_delivery(instance, receipt.id, :delivered, external_receipt)

  {:error, reason} ->
    Spectre.record_delivery(instance, receipt.id, :failed, reason)
end
```

Consent, revocation, destination authorization, event type, channel, dedupe,
rate limit, quiet hours, and digest policy are checked before transport.
Receipt transitions are validated and retained in canonical state.

## Runtime invariants

- The Instance is the sole canonical owner.
- A Runner executes one operation attempt and is `:temporary` under dynamic
  supervision.
- Retry, recovery, merge, control, and completion decisions belong to the
  Instance and deterministic controller code.
- Results, progress, timers, and control commands are revision- and
  generation-fenced.
- Waiting loops do not require a live Runner.
- Checkpoints contain data, stable identifiers, and receipts—never process
  handles or anonymous functions.
- Atom serialization may use `Atom.to_string/1`; untrusted strings are never
  converted into new atoms.

See [Agent Instances and Subjects](INSTANCES.md),
[Architecture](ARCHITECTURE.md), and
[Migrating to 0.2.0](MIGRATING_TO_0_2.md) for the surrounding contracts.
