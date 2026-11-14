# Nine-package AgentServer integration

This standalone Mix project uses the sibling `feature/stack-tools-0.4` branches
(Lab uses `feature/diagnostics-0.4`) and the core `feature/agent-server-gam` branch. It deliberately keeps satellite
path dependencies out of Spectre's production dependencies.

From this directory:

```sh
mix deps.get
mix test
```

`support/workflow.ex` contains the complete Stack, Agent and Server. All helper
functions are generated from installed package descriptors. The workflow uses:

1. Directive to initialize a portable task and Prism to select a model.
2. Mnemonic to recall existing information from the Stack's isolated engine.
3. Lens to open, inspect and close a page through its real runtime and API.
4. The model service to produce AL using the page and memory context.
5. Kinetic to interpret that consolidated response into an action proposal.
6. GAM to admit the email and the Beam notification through automatic
   registered effect adapters.
7. Pulse to inspect the installed protocol, Ledger to read the current durable
   checkpoint and Lab to validate its canonical encoding.
8. Mnemonic's governed remember operation to ask permission before saving.
   A topic change suspends that intent with a closure timer; resumption creates
   a fresh presentation, and an authenticated confirmation allows the write.
   AgentServer freezes the memory subject and effect contract before admission,
   so execution writes to the same partition that was read.

The test exercises real package adapters, callback continuations, checkpoint
CAS, GAM journal, consent Evidence and actual Outcomes. External model, browser
and email transports in `support/adapters.ex` are deterministic simulated
services. **No email is sent and no live site is visited.** Mnemonic and Ledger
perform real local persistence in temporary, isolated directories. Additional
scenarios kill the Server after model generation (replay uses durable AL without
calling the model again), kill/reopen Ledger from disk, reject a resumed consent,
and check that another subject cannot recall the saved report. The assertions
count authoritative Acts and actual adapter attempts, so transport deduplication
cannot hide a second attempt. External AL is checked against consumer events.

`support/configuration.ex` declares the three allowed operations and requires
confirmation before saving. AgentServer creates its own shared GAM Domain,
Scope, authority records, receipt broker and effect executor automatically.
There is no environment selector, custom Host, synthetic kernel fixture or
hand-built Mandate. The application supplies the authenticated subject and
permissions; the kernel owns admission and records. The test consumer acknowledges
rendering before it submits a separate consent decision. The test supplies both
`subject` and `conversation`: explicit identity selects one domain; separate
chats use distinct conversation identifiers.

`Outreach.Server.handle_action/2` demonstrates an application restriction on the
email recipient. It can reject a proposal; it cannot widen the configured
permissions or skip the kernel. Disk storage retains the exact authority,
record and one-use capability claims through restart. The application owns its
local storage deployment and authenticated transport, not the GAM protocol.

Inspect `test/outreach_test.exs` for the assertions. Passing this integration
proves the tested loop and package contracts; it does not certify external
provider credentials, live browser protocols or an existing application's
migration. Run ExUnit suites serially when using this checkout: legacy package
tests share temporary fixture paths across VMs.

## Reusable Skill scenario

The suite also mounts the same nine-tool workflow as `Outreach.Skill` with its
own Server runtime. It asserts scoped Kinetic provenance, shared GAM attribution,
email/notice effects, and confirmation before saving the report. AgentServer
automatically records Skill invocation evidence; `skill_options` supplies
process-local startup data. The configuration permits the exact scoped Kinetic
operation for the mounted Skill. Ledger/Lab inspect the current runtime
checkpoint, avoiding a hard-coded root key. No live provider keys or real
outbound email are used.

The child uses the root's **same automatic GAM connection and authority ledger**;
it does not start another Domain or provision an independent mandate. Its state,
pending requests and checkpoint remain local. The test reads `Server.gam_view`
through the root consumer and asserts the email and save Acts plus Skill
invocation Evidence in that one projection. See the [Skill ownership and consent
contract](../../docs/SKILLS.md) for the concurrent two-Skill case exercised by the
[LiveView demo](../../docs/DEMO.md).
