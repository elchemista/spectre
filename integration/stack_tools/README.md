# Nine-package AgentServer integration

This standalone Mix project uses the sibling `feature/stack-tools-0.4` branches
and the core `feature/agent-server-gam` branch. It deliberately keeps satellite
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
6. GAM to admit the email and the Beam notification through host executors.
7. Pulse to inspect the installed protocol, Ledger to read the current durable
   checkpoint and Lab to validate its canonical encoding.
8. Mnemonic's governed remember operation to ask permission before saving.
   A topic change suspends that intent with a closure timer; resumption creates
   a fresh presentation, and an authenticated confirmation allows the write.
   The host freezes the memory subject in the Candidate so a later executor
   writes to the same partition that was read.

The test exercises real package adapters, callback continuations, checkpoint
CAS, GAM journal, consent Evidence and actual Outcomes. External model, browser
and email transports in `support/adapters.ex` are deterministic simulated
services. **No email is sent and no live site is visited.** Mnemonic and Ledger
perform real local persistence in temporary, isolated directories. Additional
scenarios kill the Server after model generation (replay uses durable AL without
calling the model again), kill/reopen Ledger from disk, reject a resumed consent,
and check that another subject cannot recall the saved report. The assertions
count executor admissions, so the fake transport's deduplication cannot hide a
second attempt. External AL is also checked against consumer events.

`support/host.ex` reuses the core kernel test fixture to provision a synthetic
Domain, typed consequence contracts, mandate, principals, ingress and executor.
It adds the email/notice/report classes. It is test authorization, not a
production host policy template. Production integrations must supply their own
contracts, authentication, scoped mandates, receipts and reconciliation.

Inspect `test/outreach_test.exs` for the assertions. Passing this integration
proves the tested loop and package contracts; it does not certify external
provider credentials, live browser protocols or an existing application's
migration. Run ExUnit suites serially when using this checkout: legacy package
tests share temporary fixture paths across VMs.
