# Streaming generation in AgentServer 0.4

A Server can show supported public previews while a model is generating, then
handle one consolidated result. The Runtime owns worker lifecycle and the
transport guard. Partial tokens are provisional text, never an executable plan
or evidence that an external action succeeded.

## Generate through a Server callback

```elixir
def handle_flow({:support, :explain}, _input, ctx) do
  generate(ctx, :explain,
    stream: true,
    preview: :auto,
    on_result: :explained)
end

def handle_result(:explained, {:generated, response}, ctx),
  do: respond(ctx, response.text)

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

Configure a real `Spectre.Inference.StreamAdapter` and the model binding in
Agent/Stack/runtime options, for example `stream_adapter: MyApp.StreamAdapter`
and `stream_adapter_opts: [...]`. `MyApp.StreamAdapter` is a host implementation,
not a built-in remote provider. Missing capability produces an error; a
synchronous completion is not disguised as a live stream.

Start the Server with a `consumer:` to receive correlated preview envelopes:

```elixir
{Spectre.Server, runtime_pid,
 {:preview, interaction_id, generation_id, text}}

{Spectre.Server, runtime_pid,
 {:preview_end, interaction_id, generation_id, :completed}}

{Spectre.Server, runtime_pid,
 {:preview_end, interaction_id, generation_id, {:error, reason}}}
```

Keep both ids when updating a UI; a new generation must not append to an old
preview. The normal generated-result continuation is authoritative. Do not
reconstruct it by concatenating previews, which may deliberately omit content.
Preview completion means generation finished, not that a proposed action ran.

## Public text and private model output

The stream worker validates provider events and accumulates the generation.
Sanitization and optional public projection determine what may appear in the
preview lane. `preview:` accepts `:auto`, `:off` and `:required`.

When `planning: true` is requested, previews require an appropriate incremental
`public_projection`; otherwise `:auto` buffers the plan and `:required` rejects
the unsupported preview combination. The application can still receive the
consolidated result. Do not publish raw AL to make a missing projection look
like working streaming.

With explicit Kinetic planning, the consolidated `response.model_output` belongs
to the planner continuation, while public text follows the configured projection
and cleanup. Keep the complete generation object for `kinetic(ctx, response, ...)`;
do not expose private model output as a consumer payload. Configure the public
projection appropriate to mixed model output, or disable previews.

```elixir
def handle_flow({:mail, :compose}, _input, ctx) do
  generate(ctx, :compose,
    stream: true, preview: :off, on_result: :composed)
end

def handle_result(:composed, {:generated, response}, ctx),
  do: kinetic(ctx, response, on_result: :prepared)
```

The fragment requires a Stack-installed Kinetic helper, model/stream adapter and
host action catalog. Kinetic prepares data after consolidation; the resulting
proposal must still pass the concrete host binding and GAM. See [Actions](ACTIONS.md).

## Transport limits and cancellation

The adapter decodes transport and emits normalized provider events. The worker
validates sequence and terminal behavior, bounds normalized batches and output,
and imposes a stall timeout. The default Server stream limits include
`max_output_bytes: 1_000_000` and `stream_stall_timeout: 30_000`.

The adapter receives raw transport/parser bounds under `:spectre_bounds`:
`max_transport_chunk_bytes` and `max_parser_residual_bytes`, each 256,000 by
default. Host options `stream_max_transport_chunk_bytes` and
`stream_max_parser_residual_bytes` override those values. The adapter must enforce
them; an Erlang mailbox is not by itself backpressure.

A pull-capable transport receives one credit at a time. Push transports must
satisfy their declared bounded-push contract. The monitored transport guard
requests cleanup when the generation worker is interrupted, including abrupt
worker death. Remote cancellation remains a request to the provider, not proof
that remote work or an already committed effect was cancelled.

The Server checkpoints coordination, not live transport handles. Unfinished
safe cognitive work may start again after restart; do not assume the legacy
Instance stream-resume protocol is implemented by the new Server path. Governed
effects reconcile through GAM independently of generation transport state.

## Shared provider contract and retained Instance streaming

`Spectre.Inference.StreamAdapter`, normalized provider events, sanitizer and
provider-conformance contracts remain useful across runtimes. Server ownership
and consumer envelopes differ from the retained `Spectre.stream(instance, ...)`
Enumerable/Run protocol. Native Instance steering, stream handles, observer
receipts and resume guarantees must be evaluated in that older API's context.

The complete [0.3 streaming reference](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/STREAMING_INFERENCE_0_3.md) preserves
adapter details and those Instance-specific guarantees. Use [Providers](PROVIDERS.md)
for shared resilience boundaries, [AgentServer](AGENT_SERVER.md) for current
ownership and [migration](MIGRATING_TO_0_4.md) when replacing an Instance.
