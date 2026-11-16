# State and memory in AgentServer 0.4

The Server's durable state and recalled memory have different roles. A checkpoint
records coordination and application assigns. Memory supplies contextual data;
it does not carry authority or establish that an effect occurred.

| Data | Owner / representation |
| --- | --- |
| Application values needed after restart | Portable `ctx.assigns` in the Server checkpoint. |
| Timers, monitors and local actor handles | `ctx.private`, never checkpointed. |
| Conversation history | Runtime-owned bounded conversation projection. |
| Recalled knowledge | Portable memory projection, consumed as contextual data. |
| Memory engine/client | Named Stack runtime resource. |
| Permission to save/disclose protected memory | Host governed operation and GAM facts, not a memory score. |

Mounted Skill Servers use the root's same automatic GAM Domain and authority
ledger, while each keeps its own assigns, conversation, pending intentions and
checkpoint. Sharing GAM does not automatically merge conversations or memory
partitions: the installed memory policy determines what each query can recall.
Writes must satisfy root operation authority and mount `governed:` restrictions;
each exact presentation needs its own decision. Email consent never authorizes
a later memory save. See [Skills](SKILLS.md) and the [two-Skill demo](DEMO.md).

## Explicit recall and governed writes

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Mnemonic, automatic: false, bind: [remember: :save_report] do
    isolate_by [:agent, :subject]
  end
end

defmodule MyApp.ResearchServer do
  use Spectre.Server, tools: MyApp.AI

  def handle_flow({:research, :recall}, input, ctx),
    do: mnemonic(ctx, {:recall, input.text}, on_result: :remembered)

  def handle_flow({:research, :save}, _input, ctx),
    do: mnemonic(ctx, {:remember, ctx.assigns.report}, on_result: :saved)

  def handle_result(:remembered, {:ok, packet}, ctx),
    do: ctx |> assign(:memory, packet) |> respond("Relevant memory is available.")

  def handle_result(:saved, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "The report was saved.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

This is a composition fragment: the Agent must declare those routes, the host
must populate a portable report and bind `:save_report` to a registered memory
effect. Configure `operations: %{save_report: [confirm: true]}` when saving
requires user approval. Spectre supplies the Candidate and admission path. `automatic: false` avoids silently using the
legacy automatic memory-write path in an application that wants explicit
permission for every saved report.

## Keep the partition and engine stable

Start a named Stack runtime and pass the same name to the Server and admitted
memory executor:

```elixir
{:ok, _runtime} = Spectre.Stack.start_link(MyApp.AI, name: MyApp.AIRuntime)

{:ok, server} = Spectre.summon(
  agent: MyApp.ResearchAgent,
  subject: "customer-42",
  identity: %{subject: "customer-42", conversation: "thread-a"},
  stack_runtime: MyApp.AIRuntime,
  gam: [operations: %{save_report: [confirm: true]}]
)
```

The Agent and allowed operations are application setup. Explicit Mnemonic tools fail
when the named runtime needed to resolve the installed engine is missing.
Isolation keys such as `:subject` or `:conversation` come from authenticated
identity, not from model-generated arguments.

For governed writes, the runtime freezes that partition into its payload.
The admitted executor reconstructs memory context from the frozen payload and
resolves the same engine. It must not substitute the current user's mutable
context when an older operation resumes. The
[subject-isolated integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md) shows the
complete host wiring and verifies no cross-subject recall.

A stable command id helps correlate a write; it is not a promise of whole-request
idempotency in Mnemonic. An uncertain write needs reconciliation instead of
blind replay. A recalled packet cannot itself authorize disclosure to another
person or scope. The host's declared governed surface determines that boundary.

## Existing automatic memory adapters

The Server includes a bridge to retained memory adapters for ordinary recall
and chat-history persistence. It supplies a history-oriented legacy State
projection, not the complete old Instance state. Adapters depending on arbitrary
Instance fields, hidden global engines or complete legacy Effect state require
an audit before reuse.

Automatic adapter writes are not all magically converted into GAM Acts. Choose
explicit bound helpers when the host's governed surface includes the save.
Likewise, a direct database or memory-library call in a callback can bypass the
framework boundary; trusted application code remains responsible for using the
intended host path.

The old Session/State-adapter APIs and their cross-store persistence warning
semantics are preserved in [the 0.3 memory reference](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/MEMORY_0_3.md).
Do not apply those return tuples to Server Context or treat their checkpoint as
a Server checkpoint. See [migration](MIGRATING_TO_0_4.md), [AgentServer](AGENT_SERVER.md)
and [GAM](GAM.md).
