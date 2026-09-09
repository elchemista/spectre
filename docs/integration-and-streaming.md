# Input, streaming and cancellation

Spectre does not choose your chat protocol, voice codec, model SDK or streaming
buffer. Your application supplies those pieces.

Spectre's job is to preserve the boundary between **preparing something** and
**being allowed to do it**. That boundary matters just as much for spoken audio
as it does for a refund.

Use this guide when connecting a UI, webhook, model stream, TTS provider or
other long-running service.

## Intake is not authentication or authority

Imagine receiving a voice message. There are several jobs to do:

1. **Accept the transport input.** Your application verifies the connection,
   webhook signature or session.
2. **Identify the caller.** The Domain's fixed Ingress authenticates the actual
   principal and interaction.
3. **Record what was observed.** The ingress creates Evidence with the right
   source, labels and lifetime.
4. **Interpret it.** Your application might normalize text or obtain a transcript.
5. **Propose what to do.** A handler prepares a request using those facts.

A field named `principal_ref` in an incoming JSON object does not authenticate
that person. An input parser does not grant authority.

### Which building block should I use?

| Task | Spectre building block |
| --- | --- |
| Local parsing and normalization | `Spectre.Input.Pipeline` / `Input.Plug` |
| Authentication and input observations | `Spectre.Ingress` and its Evidence builder |
| Record an interpretation with its sources | `Spectre.Mind.evidence/3`, `Spectre.record_derivation/4` |
| Prepare an action | Agent handlers, or lower-level Mind/Candidate builders |
| Perform the admitted operation | `Spectre.Attempt.Executor` and `Spectre.Secret.Broker` |
| Record a receipt that arrives later | `Spectre.Attempt.Observer`, `Spectre.record_late_observation/4` |

The builders connect records correctly. They do not verify your identity
provider, telephone number or provider signature for you.

If remote transcription or inference is a governed action in your application,
request it through the normal execution path. A local Plug is not the place
to hide that call with unrestricted credentials.

## A reusable local pipeline

Here is a pipeline that normalizes text and rejects an empty result:

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

Read it as two steps: NormalizeText turns `"  HELLO  "` into `"hello"`;
RejectEmpty rejects whitespace-only input after normalization.

Create the pipeline once and connect its name to a flow's `pipe_through`.
Your application chooses the process in which local pipeline work runs.

A Plug returns:

- `{:cont, value}` to continue with a new value;
- `{:halt, value}` to stop the pipeline;
- `{:error, reason}` to report a failure.

A pipeline halt is not a kernel refusal. These are different stages.

Defaults limit each input/output to 65,536 canonical bytes, nesting depth 32
and 1,024 items per collection, with at most 64 stages. “Canonical bytes”
means the size of Spectre's encoded value, not just its visible text.
Limits on returned values do not sandbox the callback's own time or allocations.

Keep the original observation when it matters. A transcript is an interpretation
of audio; it should not overwrite the audio's provenance or uncertainty.

## Context windows do not weaken the kernel

You may choose how much recent information to expose to a Mind:

`context: [max_events: 100, max_evidence: 50, max_bytes: 256_000]`

This means “consider a bounded recent window when preparing the next proposal.”
It does not mean “forget older permissions and obligations.”

`max_events` counts ledger positions. `max_evidence` counts selected contextual
Evidence. The Turn reports the selected revision, limits and whether the
selection is partial. Zero limits are allowed.

Old revocations, unresolved Duties and relevant consent facts still matter to
kernel evaluation. This setting neither deletes history nor bounds the
Domain's internal memory.

## Streaming: three different units

A token, a proposal and an Attempt are not the same unit.

| Unit | Who chooses it? | Example |
| --- | --- | --- |
| Transport chunk | Your app/provider | One audio frame or text fragment |
| Proposed consequence | Your application's contract | Deliver one particular paragraph to one recipient |
| Attempt | The governed execution lifecycle | Start the admitted delivery operation |

**You do not need one Act per token.**

### Case 1: the content is already fixed

Suppose the full answer is known and an admitted Act covers delivering it to
the specified recipient. The executor may transport that content in multiple
chunks if its contract covers that delivery.

Chunking the network transfer does not create a different business operation
for every packet.

### Case 2: generation and delivery are separate decisions

Suppose output must be checked before a customer receives it.

A suitable workflow is:

1. Request generation.
2. Receive its output and recorded Evidence.
3. Prepare a delivery request for the material unit you want to send.
4. Submit it and, if admitted, deliver through the executor.

Your app can choose a paragraph, sentence or another suitable unit. It also
chooses buffering by size, time or user action.

The selected unit must still make the contract checkable. Approving individual
pieces does not necessarily establish a property of the combined message.
Sending first and reviewing later is not prior authorization.

### Does every generation need human approval?

No. The declared rules determine whether consent or approval is needed.
An admitted inference request may produce an answer that was not known in
advance. What it does not do is automatically authorize every later use or
recipient of that answer.

The consequence contract checks declared structure and bindings. It is not a
universal semantic judge of generated language.

## Streaming constraints the integration must preserve

### A changed input is a new basis

If the user steers the conversation halfway through, do not rewrite the
Evidence attached to an already committed Act. Prepare new work against the
new input.

Confidential source labels also do not disappear because a short output
fragment looks harmless.

### Approval and cancellation have limits

Approval belongs to particular material and a particular occurrence.
Do not reuse it for regenerated or expanded content.

Authority is checked at admission and dispatch. A capability already checked
out is not reauthorized on every byte. A database commit and a remote send
are not atomic, so a chunk boundary cannot guarantee instantaneous cancellation.

### Budget and time still need a contract

The current Meter API accounts for an Act's exact reservation. It does not
provide generic streaming settlement such as “reserve 100, use 20, refund 80”
based on a local byte counter.

Set an appropriate finite `observation_window_ms` for long-running work.
A progress heartbeat does not extend that window or close a Duty.

### The executor reports a final result

The current callback returns final Evidence and a result. The Runner records
those observations after the callback returns.

There is no public incremental executor-receipt or stream-session API.
Operational progress can use a host collector, but do not expose an internal
Grant or ledger writer to turn it into an alternate execution API.

## Steering, cancel and UI progress

There are no public `Spectre.stream`, `Spectre.steer` or `Spectre.cancel`
functions in 0.4. Your application implements the interaction it needs.

The important question is: **what exactly are you stopping?**

| Intention | What it means |
| --- | --- |
| Discard a draft | Stop local, unsubmitted work |
| Replace a proposed action | Prepare a new request; do not edit a committed Act |
| Stop waiting in the UI | Detach the watcher; the operation may still be running |
| Stop a provider | Use the host's explicit control mechanism and its authority requirements |
| Undo an effect | Propose a new compensating operation, if the service supports one |

A cancelled watcher is not proof of a cancelled payment, message or model call.
A killed worker is not proof of no effect. Record later receipts when they
arrive, and keep uncertainty until the facts support resolving it.

### What should a UI display?

Use Instance reads for the last completed local state and operation status.
Slow work runs in a monitored worker, so the Instance owner can answer reads.

Progress such as “working,” counts and elapsed time can go to a bounded host
collector. `Spectre.Agent.Observer` supplies payload-free phase events.

Showing generated text is different from showing “working.” A preview can itself
disclose information to a recipient; calling it a preview does not bypass your
delivery rules.

## A host-owned interaction, without a stream runtime

This works for a text, voice or delivery request. The media implementation stays
outside the kernel.

The example assumes a configured Instance and an input accepted by its ingress.
It submits once and gives the UI a reference to watch:

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

### On the next UI update

Read `Instance.info(instance, 1_000)` for process information and
`Instance.operation(instance, operation_ref, 1_000)` for that operation.

`operation` returns pending, the retained completed result, or an error.
**Do not call `advance` again to poll.**

For a deferred operation, `operation/3` can refresh the durable occurrence once
and run its result handler if the original turn is still current. It does not
resubmit the effect or start a background polling loop.

A later result from a superseded turn returns
`{:error, {:instance_continuation_superseded, result}}`. The facts are retained
in the result, but the old continuation cannot overwrite the newer local state.

Tickets have bounded retention. Keep durable Act/Attempt references when your
application needs to investigate an operation beyond that local window.

### If new input must interrupt current work

A new turn is authenticated input. Instance mutations are serialized, so the
turn can queue behind already accepted work.

If the host must interrupt a live provider sooner, it needs a separate explicit
provider-control path. If that control is governed, submit it through an
appropriately authorized independent Scope. A local `cancel` message must
not become an implicit credential.

If delivery succeeded but saving chat or a checkpoint failed, repair the
persistence problem. Do not send the answer again as a persistence retry.

## Integration acceptance checklist

Test your actual host boundary, including:

- another user's identity or Evidence cannot be injected through input;
- refused, undecidable and unknown-class requests do not call the executor;
- governed content is not sent before its applicable commit and Attempt;
- timeout, disconnection and provider death do not become “no effect”;
- steering cannot rewrite an old Act or overwrite newer local state;
- cancellation does not automatically release held resources or resolve a Duty;
- later receipts can still be recorded without executing the operation again.

The same tests apply to chat, voice and TTS. The transport remains your choice.

Next: [Instance lifecycle](agents-and-dsl.md#instance-lifecycle-and-checkpoint)
or [storage and recovery](storage-and-recovery.md).
