# Spectre

Spectre is an Elixir framework for agents with declarative routing, an OTP
process for application behaviour, and governed execution of consequences.

**0.4.0 development branch:** this README describes the AgentServer architecture
on `feature/agent-server-gam`. It changes the authoring model from 0.3; it is not
an announcement of a published Hex release. Start with the
[0.3 → 0.4 migration guide](docs/MIGRATING_TO_0_4.md) for existing applications.

## Three application modules, one conversation owner

```text
Stack: installed capabilities, providers and resources
  ↓
Agent: classifiers, router, flows and intent examples
  ↓
Server: handle_flow / handle_result / handle_pending + OTP callbacks
  ├─ cognitive commands → workers → results
  └─ consequence proposals → GAM admission → Act → executor → Outcome
```

`Spectre.Stack` connects packages. `Spectre.Agent` declares what input means.
`Spectre.Server` supplies ordinary Elixir callbacks for what happens next.
`Spectre.Server.Runtime` is the GenServer that owns the conversation, pending
intentions, command outbox and recovery. Your Server callbacks execute inside
that owner; a second application GenServer is not required.

The **Governed Act Model (GAM)** kernel records authority and causality at the
host's declared governed boundary. A model can propose deleting an account;
the proposal is not permission and is not proof of deletion. Admission precedes
the recorded Act and capability release; observed Outcomes describe what
actually happened. Read the [GAM manifesto](https://spectre.guide/en/governed-act-model)
and [how Spectre integrates GAM](docs/GAM.md).

## Install this development line

Requires Elixir `~> 1.19`:

```elixir
{:spectre, github: "elchemista/spectre", branch: "feature/agent-server-gam"}
```

Run `mix deps.get`. Keep `mix.lock` under version control, or pin an exact
reviewed commit with `ref:`. Companion libraries use `feature/stack-tools-0.4`;
see [Installation](docs/INSTALLATION.md) for compatible dependency and runtime
setup. Published 0.3 documentation does not describe this branch's Server API.

## An agent that reads a website and asks before sending email

Send a new URL. Lens opens the page, an application parser finds its contact
email, the model drafts a message in Action Language, and Kinetic prepares the
email proposal. **GAM requires confirmation before the host executor sends it.**
The user can also ask for `status`, `info` or `history`.

This is the main application code, not a standalone no-configuration script.
`MyApp.MailActions`, `MyApp.Contacts` and `MyApp.TextModel` are application modules;
the [complete guide](docs/GETTING_STARTED.md) explains their small contracts and
the GAM host wiring. Install Lens and Kinetic from their companion branches.

```elixir
defmodule MyApp.OutreachAI do
  use Spectre.Stack

  install Spectre.Lens do
    backend(SpectreLens.Browsers.Lightpanda, instances: 1)
  end

  # MailActions declares SEND EMAIL and its typed arguments; planning does not send.
  install(Spectre.Kinetic,
    mode: :closed_moves,
    actions: MyApp.MailActions,
    modes: [send_email: :write]
  )
end

defmodule MyApp.OutreachServer do
  use Spectre.Server, tools: MyApp.OutreachAI, prompt_root: "priv/outreach/prompts"

  def init(_arg, ctx) do
    # Preserve restored work/history; initialize only missing values.
    {:ok,
     ctx
     |> assign(:job, ctx.assigns[:job])
     |> assign(:history, Map.get(ctx.assigns, :history, []))}
  end

  def handle_flow({:outreach, :new_link}, input, ctx) do
    # One active job: another link cannot replace an email awaiting approval.
    if ctx.assigns.job do
      respond(ctx, "A job is already open. Ask for status or finish its confirmation.")
    else
      ctx
      |> assign(:job, %{url: input.text, status: :reading})
      |> lens({:open, input.text}, on_result: :opened)
    end
  end

  def handle_flow({:outreach, :status}, _input, ctx) do
    status = if ctx.assigns.job, do: ctx.assigns.job.status, else: :idle
    respond(ctx, "Job status: #{status}")
  end

  def handle_flow({:outreach, :info}, _input, ctx),
    do:
      respond(
        ctx,
        "Send a URL. I find its contact email, draft a message and ask before sending."
      )

  def handle_flow({:outreach, :history}, _input, ctx) do
    lines = Enum.map_join(ctx.assigns.history, "\n", &"#{&1.url}: #{&1.status}")
    respond(ctx, if(lines == "", do: "No completed jobs yet.", else: lines))
  end

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Send a URL, or ask for status, info or history.")

  def handle_result(:opened, {:ok, tab}, ctx),
    do: ctx |> assign(:tab, tab) |> lens({:look, tab}, on_result: :looked)

  # Close the known tab even if reading failed, before moving to the model.
  def handle_result(:looked, result, ctx),
    do: ctx |> assign(:page_result, result) |> lens({:close, ctx.assigns.tab}, on_result: :closed)

  def handle_result(:closed, {:ok, _}, ctx) do
    with {:ok, view} <- ctx.assigns.page_result,
         # Application parser: returns {:ok, email} only for an address in the page.
         {:ok, email} <- MyApp.Contacts.email_from(view) do
      ctx
      |> assign(:job, Map.merge(ctx.assigns.job, %{email: email, status: :drafting}))
      |> generate(:contact,
        assigns: %{page: view.context, email: email},
        planning: false,
        on_result: :drafted
      )
    else
      :not_found -> finish(ctx, :no_email, "No contact email found on this page.")
      {:error, _} -> finish(ctx, :read_failed, "Could not inspect the contact page.")
    end
  end

  # The model generates AL; Kinetic interprets the consolidated response.
  def handle_result(:drafted, {:generated, response}, ctx),
    do: kinetic(ctx, response, on_result: :prepared)

  def handle_result(
        :prepared,
        {:prepared, %{actions: [%{operation: {:kinetic, :send_email}} = p]}},
        ctx
      ) do
    ctx
    |> assign(:job, %{ctx.assigns.job | status: :awaiting_confirmation})
    # GAM's host binding below presents the exact recipient and body for consent.
    |> propose(p.operation, p.args, proposal_metadata: p.metadata, on_result: :sent)
  end

  def handle_result(:prepared, {:prepared, _}, ctx),
    do: finish(ctx, :invalid_draft, "Expected exactly one email proposal; nothing was sent.")

  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: finish(ctx, :sent, "The mail service confirmed the send operation.")

  # Refusal, cancellation and uncertain-result handling: see the full guide.
  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  def handle_pending(%{kind: :consent} = pending, input, ctx) do
    case String.downcase(String.trim(input.text)) do
      "confirm" -> confirm_pending(ctx, pending.id)
      "cancel" -> reject_pending(ctx, pending.id)
      # Informational flows may run without replacing the pending email.
      word when word in ["status", "info", "history"] -> route_current_input(ctx)
      _ -> explain_pending(ctx, pending.id)
    end
  end

  def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

  defp finish(ctx, status, message) do
    entry = %{url: ctx.assigns.job.url, status: status}

    ctx
    |> assign(:history, Enum.take([entry | ctx.assigns.history], 20))
    |> assign(:job, nil)
    |> respond(message)
  end
end

defmodule MyApp.OutreachAgent do
  use Spectre.Agent, stack: MyApp.OutreachAI, server: MyApp.OutreachServer
  model(MyApp.TextModel)
  router(strategies: [:regex])

  flow :outreach do
    on(:new_link, regex: ~r/^https?:\/\/\S+$/i, collect_intent: false)
    on(:status, regex: ~r/^status$/i)
    on(:info, regex: ~r/^info$/i)
    on(:history, regex: ~r/^history$/i)
  end
end
```

The Stack generates `lens` and `kinetic`; there are no package helper imports.
Kinetic receives the **model result**, not a hand-written send command in a flow.
The email binding below applies regardless of how the proposal was recognized;
a regex match or an installed action is not permission to send.

```elixir
# Host-owned policy: sending mail always needs consent for this exact draft.
# MailPolicy builds the Candidate/Presentation; the Domain's authenticated
# ingress validates the original answer. These are application callbacks.
gam = [
  scope: authenticated_scope,
  store: MyApp.ServerStore,
  consent_ttl_ms: 300_000,
  bindings: %{
    {:kinetic, :send_email} => %{
      candidate: {MyApp.MailPolicy, :candidate},
      presentation: {MyApp.MailPolicy, :presentation},
      interpreter: {MyApp.MailPolicy, :interpret}
    }
  }
]

# The host supervises ServerStore, the GAM Domain and this named Stack runtime.
{:ok, _runtime} = Spectre.Stack.start_link(MyApp.OutreachAI, name: MyApp.OutreachRuntime)
{:ok, agent} = Spectre.summon(
  agent: MyApp.OutreachAgent,
  subject: authenticated_user.id,
  stack_runtime: MyApp.OutreachRuntime,
  checkpoint: {MyApp.ServerStore, "outreach:" <> to_string(authenticated_user.id)},
  gam: {Spectre.Server.GAM, gam},
  consumer: channel_pid
)

Spectre.Server.input(agent, "https://company.example/contact")
# Later messages from the same authenticated channel:
Spectre.Server.input(agent, "status")
# Only after the consent presentation has actually been delivered:
# Spectre.Server.input(agent, "confirm")
```

`MyApp.MailPolicy.presentation/3` must show the exact recipient and body, with
confirm/cancel choices. Its Candidate and the Domain contract bind approval to
that email; the admitted executor invokes the mail transport only after GAM
commits the Act. Finding an address on a page does not itself authorize contact.
See [the guide](docs/GETTING_STARTED.md) for the model prompt, result handling,
provider setup and what is intentionally omitted from this sketch.

## Capabilities retained from 0.3

- Regex, intent-dataset, embedding, local-classifier, LLM-classifier and custom
  routing strategies, with explicit unmatched/ambiguous handling.
- Separate classification and generation models, including custom adapters.
- Online collection of labelled examples with `collect_intent`, dataset lookup,
  training and evaluation. Text examples are useful without embeddings; vector
  search only indexes valid compatible embeddings.
- Streaming generation. Preview tokens are provisional; only consolidated
  output can become executable proposals.
- Installed Stack packages and their standalone APIs.

The change is ownership: routing stays declarative, application logic moves to
Server callbacks, and governed effects enter GAM. Consent and its lifetime are
pending state with correlation and recovery, not an unscoped match on “yes”.
Native `handle_call`, `handle_cast` and `handle_info` remain available. See
[Architecture](docs/ARCHITECTURE.md) and [Pending lifecycle](docs/PENDING_LIFECYCLE.md).

## Installed tools

`c:Spectre.Stack.Installable.tools/1` lets a package register operations.
`use Spectre.Server, tools: MyApp.AI` generates helpers from that Stack's
registered names. You do **not** import invented helper functions from each
package. The helper builds a command; the runtime resolves the installed
adapter/resource and applies its cognitive or governed contract.

| Package | Helper / role in the Server loop |
| --- | --- |
| [Kinetic](https://github.com/elchemista/spectre_kinetic/tree/feature/stack-tools-0.4) | `kinetic`: consolidate Action Language into proposals |
| [Mnemonic](https://github.com/elchemista/spectre_mnemonic/tree/feature/stack-tools-0.4) | `mnemonic`: recall; bind writes to governed operations |
| [Lens](https://github.com/elchemista/spectre_lens/tree/feature/stack-tools-0.4) | `lens`: browser observations and bound actions |
| [Prism](https://github.com/elchemista/spectre_prism/tree/feature/stack-tools-0.4) | `prism`: model selection and installed inference services |
| [Beam](https://github.com/elchemista/spectre_beam/tree/feature/stack-tools-0.4) | `beam`: endpoints and governed delivery |
| [Directive](https://github.com/elchemista/spectre_directive/tree/feature/stack-tools-0.4) | `directive`: portable task-state reduction |
| [Pulse](https://github.com/elchemista/spectre_pulse/tree/feature/stack-tools-0.4) | `pulse`: protocol/contacts and bound sends |
| [Ledger](https://github.com/elchemista/spectre_ledger/tree/feature/stack-tools-0.4) | `ledger`: current checkpoint metadata; durable store adapter |
| [Lab](https://github.com/elchemista/spectre_lab/tree/feature/stack-tools-0.4) | `lab`: checkpoint inspection and validation |

See [Stack tools](docs/STACK_TOOLS.md) for exact requests, results, bindings and
replay rules. The [nine-package integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md)
includes browsing, memory, model-generated AL, email, consent, topic changes,
timers and crash recovery. Its external transports are simulated; the package
adapters, persistence and GAM loop are real.

## Documentation

Start at [Start here](docs/START_HERE.md), then read
[Getting started](docs/GETTING_STARTED.md), [Agent and Server](docs/AGENT_SERVER.md),
[GAM](docs/GAM.md), [Routing](docs/ROUTING.md) and [Training](docs/TRAINING.md).
[Migration](docs/MIGRATING_TO_0_4.md) identifies breaking changes and compatibility
boundaries. [Changelog](CHANGELOG.md) records version history.

The old `Instance`/`Run` APIs remain in the repository for compatibility; using
them does not automatically migrate an application or its checkpoints to GAM.
The host still owns authentication, mandates, executors, credentials and actual
external-effect boundaries. Spectre is not a sandbox for arbitrary Elixir code.

Apache-2.0; see [LICENSE](LICENSE).
