# Spectre 0.4 LiveView showcase

The demo is a [separate repository](https://github.com/elchemista/demo_spectre),
created with Phoenix without a database. It is not part of the Spectre Hex package.

## Start locally

Clone the demo and follow its README. Default dependencies are exact Git commits
for core and all nine packages, so sibling checkouts are not required. Its checked-in
manifest and lockfile identify the tested set. For ecosystem development only,
`SPECTRE_LOCAL_DEPS=1` explicitly selects sibling paths instead.

```sh
git clone https://github.com/elchemista/demo_spectre.git
cd demo_spectre
mix setup
mix phx.server
```

Open `http://localhost:4000`. A supported Lightpanda binary must be installed
before startup; see the Lens standalone guide. The deterministic mode needs no
provider key. The demo opens only its own fixture pages and never sends SMTP.

## Separate Skill servers, one GAM

The demo uses `DemoSpectre.AgentServer`, Research's `OutreachServer` and
`KnowledgeServer`. These are three independent Server runtimes. The root starts
GAM automatically and passes its existing connection to both children:

```text
AgentServer ────────┐
OutreachServer ─────┼──→ same automatic GAM → one Domain / authority ledger
KnowledgeServer ────┘
```

Each Server keeps local assigns, workers, streams, pending intentions and a
checkpoint key. The children can run concurrently; the shared kernel orders
admission. Session startup configures the root's allowed operations once, while
the Agent's `governed:` mount references restrict each Skill. There is no
`DemoSpectre.Host`, Skill-specific Domain or manual ingress to implement.

The same ledger records Skill invocation provenance and all governed lifecycle
facts. Confirmation controls address the exact Skill and presentation: approving
Research's email cannot approve Knowledge's note, or even Research's subsequent
memory write. Expiry closes an intention without erasing a Duty. The inspector's
**Identità e processi** shows the distinct Skill PIDs and shared Domain; **Registro
GAM** shows the single authority projection. The sibling application's
`docs/SHARED_GAM.md` follows these connections through the actual source.

## Walk through it

1. **Apri sito di esempio**: the Research Skill opens and reads a local page using
   real Lens/Lightpanda, recalls memory, selects a model through Prism and
   streams a deterministic draft. Kinetic interprets the final AL into a proposal.
2. GAM presents the exact local email. The browser acknowledges rendering before
   a response can become consent. Confirm to put the message in the local mailbox,
   or cancel to leave the effect unexecuted.
3. A second request asks whether to save the result through Mnemonic. Email
   approval does not approve memory storage.
4. While a request is open, try **Diagnostica**, **Memoria** or **Salva nota**.
   Knowledge runs in its own GenServer, under the same GAM Domain. Root `status`
   remains available. Confirmation buttons pin the Skill, pending ID and revision.
5. **Sospendi** changes topic within Research and schedules an audited closure
   after 30 seconds. **Riprendi** before expiry asks for a fresh presentation.
6. The inspector shows tool results, local mail and redacted, paginated GAM
   records. Commit notifications trigger refresh; there is no periodic full-ledger
   polling. See [Diagnostics](DIAGNOSTICS.md) for authorization and trace limits.

The Stack installs Lens, Kinetic, Mnemonic, Prism, Beam, Directive, Pulse, Ledger
and Lab. Diagnostics exercises Beam endpoint discovery, Pulse protocol inspection,
Ledger checkpoint lookup and Lab validation. **Notifica Beam** exercises a bound
local delivery with its own GAM confirmation. This is representative capability
coverage, not a test of every operation or remote transport in each package.

## Optional model

The demo README documents `DEMO_MODEL=openrouter`, `OPENROUTER_API_KEY` and
`OPENROUTER_MODEL`. Only the explicit mode flag enables a remote call. The
OpenRouter path uses non-streaming Chat Completions; deterministic preview uses
the real Server streaming contract. Configure credentials in the environment,
not in chat or source. Provider credentials and live API behavior require a
separate check with the user's selected model.

## Scope and lifetime

Each connected chat owns a new Agent/Skill tree with an automatically created
GAM Domain. The authority ledger, command journal, checkpoints and Mnemonic data
use local disk storage. A reloaded chat receives a new session/subject; it does
not reattach old authority or silently recover a previous session. Closing the
LiveView tears down its process tree while retaining the recorded history.
Account login and reconnecting an existing session are outside this showcase.
The [GAM manifesto](https://spectre.guide/en/governed-act-model) and existing
kernel semantics are unchanged.

See the sibling README for source navigation, verification and current limits.

## Browser and adversarial verification

The sibling demo includes a repeatable Playwright suite for Chromium. It drives
actual LiveView forms, rendering acknowledgements and confirmation controls,
including stale/replayed consent, concurrent Skills, real expiry timers,
malformed client payloads, reconnects and lost presentation acknowledgements.
Run `npm ci`, `npx playwright install chromium ffmpeg` and
`npm run test:browser` from `demo_spectre` while its deterministic server runs.
The demo's `docs/VERIFICATION.md` records results, corrected bugs and limits.

For notes unrelated to the default contact query, use `memoria <search terms>`.
An empty recall result is not an assertion that the memory store is empty.

## Additional capability checks

The demo now also includes:

- **Esplora la memoria**: explicit Mnemonic search, recall or reflection; source
  cards and a governed **Dimentica…** action showing the selected record text.
- **Mappa**, **Conoscenze**, and `impara <text>` for graph inspection and separately
  consented reusable knowledge.
- **Hello + consenso**: model-generated AL → Kinetic → GAM presentation/button →
  real Logger action; cancel/replayed confirmation never creates a second log.
- **Prova parafrasi**: exact and quantized-vector IntentDataset lookup, with the
  actual winning strategy visible. Vettore is real; the test encoder is
  deterministic. Reviewed vectors are in the demo's `priv/intents/prepared.jsonl`.

The core tests exercise online collection, verification, re-embedding and
training artifacts. The demo disables automatic shared intent collection;
Mnemonic's per-session user memory remains separate from that intent dataset.

Contacts are selected from structured Lens links and observed semantic text, with
source provenance. Multiple distinct addresses stop before message generation.
The demo keeps consent and execution material bound to the selected observation.
