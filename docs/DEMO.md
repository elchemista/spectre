# Spectre 0.4 LiveView showcase

The [demo application](https://github.com/elchemista/demo_spectre) runs an
AgentServer, two mounted Skill Servers and on-demand Directive missions against
one shared GAM Domain. The native mission path uses Core 0.4.1 and Directive 0.2.0.
PostgreSQL/Ecto stores canonical history, persisted Domain records and scoped
Server checkpoints. The demo is a separate Phoenix application, outside the
Spectre package; its default deterministic model needs no provider key.

## Start locally

Follow the [demo requirements](https://github.com/elchemista/demo_spectre#run),
then:

```sh
git clone https://github.com/elchemista/demo_spectre.git
cd demo_spectre
docker compose up -d db
mix setup
export LIGHTPANDA_INSTALL_DIR="$HOME/.local/share/demo-spectre/browser-1.0.4"
bash scripts/install_browser.sh
export LIGHTPANDA_PATH="$LIGHTPANDA_INSTALL_DIR/lightpanda"
mix phx.server
```

Open `http://localhost:4000`. Compose provides PostgreSQL on loopback port 5433;
`mix setup` creates/migrates the development database and builds assets. The
installer verifies Lightpanda 1.0.4 for Linux x86_64. Other platforms can select a
supported executable through `LIGHTPANDA_PATH`.

The demo's source manifest pins the core and nine packages to exact Git commits,
and its lockfile records their dependency graph. Public-source verification uses
those revisions. For sibling development, `SPECTRE_LOCAL_DEPS=1` explicitly
selects the local checkouts instead. Run migrations before starting an upgrade;
application startup performs no DDL or automatic history deletion.

## Separate Skill Servers, one GAM

![Root, two Skill Servers, shared GAM and PostgreSQL](https://raw.githubusercontent.com/elchemista/demo_spectre/main/docs/assets/readme-architecture.svg)

Research's `OutreachServer` and `KnowledgeServer` have their own GenServers,
assigns, workers, streams, pending intentions and checkpoint identities. The
root starts GAM once and shares its connection with both children. Root operation
permissions and each mount's `governed:` references both constrain proposals.
Installing a tool or mounting a Skill does not grant more authority.

Confirmation controls identify the exact Skill and Presentation. Approving an
email cannot approve another Skill's note or the subsequent memory write.
Expiry closes the pending intention while preserving committed authority facts
and unresolved Duties. The demo's
[source walkthrough](https://github.com/elchemista/demo_spectre/blob/main/docs/SHARED_GAM.md)
connects these rules to the callbacks.

## Walk through it

1. **Apri sito di esempio** opens a local page through real Lens/Lightpanda.
   Research recalls memory, uses Directive and Prism, streams a deterministic
   draft, and lets Kinetic interpret the completed Action Language.
2. GAM presents the exact email recipient and body. **Confermo** writes to the
   local mailbox; **Annulla** leaves that effect unexecuted. Rendering the card
   is not consent. No SMTP service is configured.
3. A separate request asks to save the result through Mnemonic. Email approval
   does not approve memory storage.
4. Leave a confirmation open and try **Diagnostica**, **Memoria**, **Salva nota**
   or root `status`. The other Servers continue independently. The inspector
   shows distinct PIDs, one Domain and redacted paginated GAM records.
5. **Sospendi** schedules closure after 30 seconds. **Riprendi** creates a fresh
   Presentation; an older button cannot approve its new revision.
6. **Notifica Beam**, **Hello + consenso**, **Esplora la memoria**, **Mappa** and
   **Prova parafrasi** exercise local delivery, the Logger action, Mnemonic and
   exact/vector IntentDataset lookup. The vector store is real; its test encoder
   is deterministic, and private memory is separate from the reviewed dataset.

The Stack installs Lens, Kinetic, Mnemonic, Prism, Beam, Directive, Pulse, Ledger
and Lab. This is representative local integration coverage, with Pulse protocol
inspection rather than a remote transport. External approval by a second
AgentServer is documented in [External approvals](EXTERNAL_APPROVALS.md),
including an exchange without Pulse; a personal approver chat is not part of
this UI.

## Chat and native website missions

Run with sibling Core and Directive checkouts using `SPECTRE_LOCAL_DEPS=1`.
Restart the Phoenix server after updating either dependency so its VM loads
the compiled modules.

1. Start with conversation. The Root's chat prompt uses bounded history. The
   LLM classifier can recognize a website mission in ordinary language.
2. Ask the agent to analyze a supported public HTTP(S) site and prepare a draft.
   Include the URL and what the email should accomplish. Directive runs as an
   Activity while Root chat stays available. Lens observes the site. The mission
   proposes `save_draft` when it has an observed contact.
3. The first GAM Presentation asks to save the exact draft. The second, when
   the request includes delivery, asks to send the saved content. Delivery
   reaches Phoenix's local Swoosh mailbox at `/dev/mailbox`.
4. If the Activity stops before admission of the send, use
   `riprendi invio DRAFT_REF` in the same browser session. Copy `DRAFT_REF` from
   **Casella**. The new Activity loads the saved draft and requests a fresh
   consent. If the previous send was admitted, reconcile its recorded Outcome
   before deciding what to do next.

[Activity controls](AGENT_SERVER.md#run-a-background-activity),
[Managed consent lifecycle](MANAGED_GAM.md).

## History, payloads and lifetime

Each browser connection starts a fresh identity, Domain and Server tree.
Closing it stops that tree but retains PostgreSQL history and local Mnemonic
files. Reloading creates a new session; it does not reattach an old account.
The demo uses local browser sessions. The Skill walkthrough uses its bundled
fixture. The native website mission applies the demo's public URL policy.

The [PostgreSQL examples](https://github.com/elchemista/demo_spectre#postgresql-and-history)
show bounded Ecto queries, canonical verification and paginated Domain reads
after Session shutdown. These trusted administrative reads may contain private
operation data; the LiveView diagnostic projection excludes that content.

Payload storage is optional and application-owned. The demo includes `put/3`
and `fetch/3` callbacks using private files and random opaque references, without
encryption. Unconfigured payloads remain in ordinary storage; an application can
choose its own encryption or object store. See [Payload storage](PAYLOAD_STORAGE.md).

## Verification and optional provider

The [verification guide](https://github.com/elchemista/demo_spectre/blob/main/docs/VERIFICATION.md)
covers `mix precommit`, real PostgreSQL integration and the Chromium/Lightpanda
suite. Browser checks include simultaneous Skills, stale/replayed consent,
expiry, malformed events, reconnection and lost rendering acknowledgements.

The optional `DEMO_MODEL=openrouter` mode uses credentials from the environment
and sends rendered prompts, observed page content and recalled memory to the
selected provider. It is non-streaming; the default provider exercises the Server
streaming contract without remote calls. The demo README documents these choices
and their configuration.
