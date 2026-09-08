# Input, streaming, steering and cancellation

Spectre is a library of governed boundaries, not a drop-in media server.
The application chooses input formats, codecs, voice/VoIP sessions, TTS/model
providers, buffering, worker placement and when to submit a proposal. There is
no mandatory media schema, stream process or chunk-per-Act policy.

This division is intentional. The core must reject invalid authority,
provenance and accounting regardless of the application's transport.
See [architecture](architecture.md) and [the governed surface](../GOVERNED_SURFACE.md).

## Intake is not authentication or authority

| Stage | Existing building block | Application responsibility |
| --- | --- | --- |
| Local normalization | `Spectre.Input.Pipeline`, `Spectre.Input.Plug` | Parse/normalize a portable value; protect raw input and resource use |
| Authentication | `c:Spectre.Ingress.authenticate/5`, `Spectre.SubmissionContext` | Verify the actual user/session and bind the fixed Domain ingress |
| Observation | `c:Spectre.Ingress.observe/4`, `Spectre.Ingress.evidence/3` | Attest what was observed; choose issuer, proposition, lifetime and labels |
| Interpretation | `Spectre.Mind.evidence/3`, `Spectre.record_derivation/4` | Preserve the original and distinguish interpretation from observation |
| Proposal | `Spectre.Mind.candidate/2`, `Spectre.Agent.candidate/4` | Construct the exact governed consequence and its evidence/authority references |
| External attempt | `Spectre.Attempt.Executor`, `Spectre.Secret.Broker` | Implement the declared contract and report bounded, bound observations |
| Later reconciliation | `Spectre.Attempt.Observer`, `Spectre.record_late_observation/4` | Authenticate later receipts; resolve uncertainty without blindly retrying |

An arbitrary inbound `principal_ref` is not authentication. The Ingress is
host-selected at Domain startup, not selected by a request. Its evidence builder
forces context bindings and observed provenance; it does not verify an IdP,
telephone number, webhook signature or provider receipt on the host's behalf.

An input Plug is not an effect executor. If remote transcription or model
inference is part of the declared governed Surface, call it through a governed
Act, not from a Plug with ambient credentials. Same-BEAM callbacks are not
technically sandboxed, so the host must close alternate effect paths.

## A reusable local pipeline

Prepare once and run it in the caller/worker selected by the application:

<!-- spectre:example input_pipeline -->
```elixir
defmodule Guide.RejectEmpty do
  @behaviour Spectre.Input.Plug

  @impl true
  def call("", _opts), do: {:error, :empty_input}
  def call(value, _opts), do: {:cont, value}
end

{:ok, pipeline} =
  Spectre.Input.Pipeline.new(
    [{Spectre.Input.Plugs.NormalizeText, case: :downcase}, Guide.RejectEmpty],
    max_bytes: 4_096
  )

{:ok, "hello"} = Spectre.Input.Pipeline.run(pipeline, "  HELLO  ")
{:error, _reason} = Spectre.Input.Pipeline.run(pipeline, "   ")
```

`init/1` is optional; `call/2` returns `{:cont, value}`, `{:halt, value}` or an
error. A halt is a local pipeline result, not a kernel refusal. Values at every
boundary must be portable and fit the configured limits. Defaults are 65,536
canonical bytes, depth 32 and 1,024 items per collection, with at most 64 stages.
These limits do not bound arbitrary allocations or time inside a callback.

Keep the raw observation when it matters. A transcript, summary or normalized
interpretation can carry different uncertainty than the original audio or text;
do not overwrite that distinction to simplify an integration.

## Context windows do not weaken the kernel

The Domain option
`context: [max_events: 100, max_evidence: 50, max_bytes: 256_000]` bounds recent
Scope Evidence exposed to a Mind. `max_events` counts ledger positions, not
valid authority. The Turn reports the selected revision, limits and whether
selection is partial. Zero limits are allowed.

This is a deliberation budget, not permission to forget an old revocation,
counterproof, unresolved Duty or consent assumption. Kernel checks still use
all relevant governed facts. The window does not compact the ledger or bound
the projection's lifetime memory.

## Streaming: three different units

1. A transport chunk is a byte/token/audio fragment chosen by the app/provider.
2. A proposal unit is an exact consequence whose required facts can be checked.
3. An Attempt is a recorded exercise of a committed Act, with its own Outcome
   and accounting.

These units need not be equal. Already-frozen, admitted content can be sent in
multiple transport chunks if the Act's contract covers that delivery. Conversely,
authorizing generation does not automatically authorize disclosure of whatever
content will later be produced to any recipient.

For generated output whose delivery needs separate approval, a possible host
flow is: govern generation, obtain bound output Evidence, construct a delivery
Candidate for a material unit, obtain admission, then deliver it through the
executor. This is an integration pattern, not a new Spectre stream API and not
a requirement to create one Act for every token.

The app can flush buffers by size, time, sentence or explicit user action. But
"validate every N chunks" is only meaningful when the selected units preserve
the declared Conditions, consent, lineage, recipients and budget. Approval of
isolated pieces does not prove a property of their concatenation. Sending first
and auditing later violates the mediated execution order.

`Spectre.Consequence.Contract` checks declared structure and bindings; it is not
a universal semantic classifier for generated language. An unknown future
result is not inherently forbidden: the consequence may be a governed inference
attempt. It simply does not imply authority for an undeclared downstream effect.

## Streaming constraints the integration must preserve

- **Lineage:** new steering/input/tool output is not retroactively a parent of
  an old Act. Derived executor Evidence is constrained by that Act's evidence
  basis. A changed basis can require a new proposal.
- **Disclosure:** labels inherited from confidential context do not disappear
  because an output chunk appears innocuous. Use the governed declassification
  path when justified; do not strip labels in the transport.
- **Consent:** approval binds material and occurrence. It is not reusable
  approval for future regenerated or expanded output.
- **Revocation:** authority is checked at admission and dispatch/consumption;
  a capability already checked out is not reauthorized on every byte. Database
  commit and network send are not atomic. Chunk boundaries cannot promise
  instantaneous remote cancellation.
- **Accounting:** the current Meter transitions settle/release/suspend the
  Act's exact reservations. There is no generic partial settlement API that
  reserves 100, bills 20 and refunds 80 from a stream counter. Model cost and
  delivery are distinct consequences when the application models them so.
- **Time:** `observation_window_ms` is declared before execution. A long stream
  needs an appropriate finite observation window; heartbeat/progress does not
  silently extend it or erase a Duty already derived at its deadline.
- **Uncertainty:** losing a worker or connection after an Attempt does not prove
  that the provider did nothing. Keep receipts, record late observations and
  retain uncertainty until properly resolved.

The current executor callback returns a final result. The Runner records its
Evidence after the callback returns; there is no public incremental executor
receipt/stream-session API. The application must not expose an internal writer
or Grant to manufacture such an API. A future bridge needs these same bindings
and lifecycle tests, not a bypass around the final-result contract.

## Steering, cancel and UI progress

There are no current public `Spectre.stream`, `Spectre.steer` or `Spectre.cancel`
functions. Those words describe application intentions with different effects:

| Intention | Safe interpretation |
| --- | --- |
| Stop local planning | Stop/discard unsubmitted Zone M work; do not claim a world effect was cancelled |
| Replace an unsubmitted proposal | Build a new Candidate against the new input; do not alter a committed Act |
| Steer after a commit | Preserve the old Act/Attempt and propose separately for the new basis |
| Stop a running provider/transport | Host contract determines the control effect and required authority; receipt uncertainty remains |
| Cancel before an Attempt | Respect the core's durable dispatch lifecycle; local UI state is not its record |
| Undo an external effect | A new compensating Act, if supported and authorized, not history deletion |

A generic "cancel" flag is not an authorized Duty disposition. Never invent a
global root Mandate or wildcard target just to make an example's cancellation
succeed. Epoch/generation fencing can reject stale proposals or local state
updates; it must not discard true late Evidence about an already-started effect.

An app may run local workers and show operational progress while they work.
Progress is not a successful Outcome. Displaying generated or confidential
content to a recipient can itself be a governed disclosure, even if the UI
calls it a preview. Keep operational status separate from material delivery.

The Instance now runs slow work in its existing monitored worker; its owner
keeps state/info reads responsive. This is independent of the semantic questions
above. Pure reads accept an explicit timeout (including `:infinity`). Do not
make a LiveView wait indefinitely merely to hide a blocked application callback.

## A host-owned interaction, without a stream runtime

The same handler API can prepare a voice, text or delivery request. No media type
is required in the kernel. A host can submit the exact selected ticket and then
poll its progress without resubmission:

<!-- spectre:example pending_operation -->
```elixir
{:ok, prepared} = Spectre.Instance.turn(instance, input, flow: flow)
[chosen] = prepared.requests

case Spectre.Instance.advance(instance, chosen, wait: 0) do
  {:pending, operation_ref} ->
    # Retain this ref in host state. A pending operation is not an ambiguity.
    {:watch, operation_ref}

  {:ok, completed} ->
    {:completed, completed.result}

  {:error, reason} ->
    {:failed, reason}
end
```

On a later UI tick, read `Instance.info(instance, 1_000)` and
`Instance.operation(instance, operation_ref, 1_000)`. The latter returns
`:pending`, the retained completed result, or an error. Neither read submits
another Candidate. Use the returned operation ref, not a new `advance` call.
The Instance reserves a ticket once; selecting one alternative invalidates its
siblings. For a deferred proposal, `operation/3` runs one recovery and, if its
turn is still current, the result handler in the mutation worker. Concurrent
reads report pending while that work runs; no background polling or executor
retry is started. A superseded continuation returns
`{:error, {:instance_continuation_superseded, result}}` without changing newer
state. Completed and deferred results have bounded retention, so tickets are
not an archive.

The provider/transport's executor can report operational progress to a
host-owned bounded collector. Use refs, counts and durations, not unapproved
prompt/output bytes. `Spectre.Agent.Observer` supplies payload-free phase
events; it is not a stream transport or a material-delivery authorization.
Keep provider buffers and byte delivery inside the host's executor contract.

Steering creates a new authenticated input and a new turn. Ordinary Instance
work is serialized; a new turn may queue behind work already accepted. If the
application must interrupt a live provider before that queue drains, the host
uses its explicit provider-control mechanism. When that control is an effect
on the declared Surface, submit it through an appropriate independent Scope;
do not turn a local `cancel` message into an implicit capability.

A cancelled UI watcher must not kill the executor and report success. A lost
connection is not proof of no effect. Preserve the old Act/Attempt refs and
authenticate later observations through `Spectre.record_late_observation/4`.
The result can repair the original record without being applied to a newer
conversation state. Checkpoint/chat persistence failure after delivery likewise
requires repair of persistence, not repetition of delivery.

See [Instance lifecycle](agents-and-dsl.md#instance-lifecycle-and-checkpoint) and
[capabilities](capabilities.md) for the implementation and qualification limits.

## Integration acceptance checklist

Test the full path with the host's contract, not just a mocked Mind result:

- Invalid authentication cannot bind a different principal or ingress.
- Input/routing/derived output cannot inject capability, observed provenance or
  an unrelated evidence parent.
- Refusal, unknown class and undecidable results never invoke the executor.
- No bytes cross a governed delivery boundary before the applicable commit and
  Attempt, including preview/error paths.
- Revocation, stale Scope, provider death, caller death and late receipts have
  distinct expected outcomes.
- Long-running work does not silently extend time or accounting; interruption
  does not release ambiguous reservations or close Duties.

These checks apply to text, voice and TTS alike; the transport implementation
remains the application's choice.
