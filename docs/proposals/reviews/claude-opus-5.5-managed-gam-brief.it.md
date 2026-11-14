# Review richiesta a Claude Opus 5.5: GAM gestito da Spectre

Lavora in sola lettura. Non implementare, non modificare file, non fare commit/push.
Rispondi in italiano, con conclusioni concrete e riferimenti file:riga. La richiesta
è una review indipendente del piano INSIEME al codice reale e alla demo, non una
conferma del piano. Indica esattamente cosa hai letto e cosa non hai verificato.

## Problema dell'utente e contesto storico vincolante

L'utente voleva conservare l'ergonomia di Spectre 0.3 (Stack, router dichiarativo,
strategie classifier/embedding/cache, flow, fallback, training, Skill), separando
la grossa Instance in Agent dichiarativo e Server con callback Elixir/OTP. La 0.4
importa un kernel GAM già organizzato: NON va ridisegnato. Sono state aggiunte
Skill con processi concorrenti che condividono il Domain dell'agente e autorità
ristretta per mount, e helper generati dalle registrazioni dei nove pacchetti.

Ora la demo Phoenix richiede 546 righe nei quattro moduli DemoSpectre.Host*, più
un Session che orchestra manualmente quasi tutto. L'utente contesta giustamente:
«Se GAM è automatico, perché devo programmarlo? Voglio agente semplice». Vogliamo
che Spectre assorba bootstrap/record/consenso/esecuzione registrata, lasciando
all'app identità affidabile, operazioni abilitate, regole business ed effetti.
Non basta spostare il grosso Host in un file libreria con mandato onnipotente.

Niente nuova DSL di policy obbligatoria; preferenza per callback ordinari nel
Server. Stack installa; Agent contiene flow/router/Skill; Server contiene il
comportamento. Il modello genera AL, Kinetic prepara proposte dal risultato
consolidato: non deve agire su token di streaming. Mnemonic ha molte operazioni,
non solo remember. Le Skill condividono Domain ma non acquisiscono tutti i poteri.
GAM interviene sulle conseguenze dichiarate, non chiede consenso per ogni regex
o classifier cognitivo configurato. Conservare tutto il funzionamento precedente.

## Percorsi

Workspace: `/home/dev/Sviluppo/spectre`.
Core: `spectre/`, branch feature/agent-server-gam, working tree modificato.
Demo: `demo_spectre/`, app separata, con dipendenze locali e test veri.
Satelliti: `spectre_kinetic/`, `spectre_mnemonic/`, `spectre_lens/`,
`spectre_beam/`, `spectre_pulse/`, `spectre_prism/`, `spectre_directive/`,
`spectre_ledger/`, `spectre_lab/`.

Leggi prima:
1. `spectre/docs/proposals/managed-gam-0.4.it.md` (piano candidato completo).
2. `/tmp/spectre-gam-manifest-review.txt` (manifesto corrente scaricato da
   https://spectre.guide/en/governed-act-model il 2026-11-14).
3. `spectre/docs/GAM.md`, `AGENT_SERVER.md`, `SKILLS.md`, `STACK_TOOLS.md`.

Poi verifica direttamente:
- Tutti i `demo_spectre/lib/demo_spectre/host*.ex` e `host/*.ex`, `session.ex`,
  `ai.ex`, `agent.ex`, `pending.ex`, `mail_actions.ex`, `skills/*server.ex`.
- La LiveView e gli hook UI in demo (usa Glob),
  `demo_spectre/test/browser/adversarial.spec.cjs` e `docs/VERIFICATION.md`.
- `spectre/lib/spectre/server.ex`, `server/gam.ex`, `server/runtime.ex`,
  `server/skills.ex`, `server/catalog.ex`, `server/planning.ex`, `server/tool.ex`,
  `server/tool_compiler.ex`, `server/checkpoint.ex`, `server/service_context.ex`,
  `server/gam/invocation.ex`, `server/gam/lifecycle.ex`.
- `spectre/lib/spectre/stack/installable.ex`, `stack/tools.ex` e l'effettivo
  adapter behaviour individuato nel codice; ActionConfig e catalogo Kinetic.
- I punti pertinenti del kernel vero: Domain bootstrap/configuration/startup,
  Mandate, Surface, HostProfile, Ingress, Presentation, Attempt/Executor,
  admission/execution/recovery/reconciliation. Non dedurre il funzionamento
  soltanto dal piano o dai commenti.
- Registrazioni e ServerTool Kinetic, Mnemonic, Beam, Pulse; altri pacchetti se
  necessari. I descriptor attuali non dichiarano un executor generico.

## Output richiesto

1. Verdetto: cosa approvi, cosa correggere prima di implementare.
2. Problemi P0/P1/P2 verificati con riferimenti al codice e impatto.
3. Architettura minima raccomandata e API d'esempio (marcare quelle proposte).
4. Mappa precisa: codice generico in Spectre, codice nel pacchetto, codice app.
5. Piano ordinato di implementazione e test mancanti, inclusi crash/recovery,
   consensi concorrenti e UI, lifecycle e conservazione delle Duty.
6. Limiti della review: nessun test è stato rieseguito da te se non lo esegui.

Contesta anche le assunzioni dell'assistente: non approvare per cortesia.
Non introdurre venti moduli pubblici nuovi o richiedere di programmare GAM per
usare un singolo agente. La complessità interna necessaria può restare interna.
Non stampare segreti o file di credenziali. Non serve leggere .env.
