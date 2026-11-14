# Verifica implementazione GAM gestito — 2026-11-14

> Documento storico: il successivo completamento elimina il selettore
> development/produzione e il collegamento GAM manuale in AgentServer.
> Per il contratto attuale e `Spectre.GAM.submit/4` vedere
> [GAM automatico](../MANAGED_GAM.md). I risultati di verifica qui sotto
> descrivono la revisione precedente.

Branch core: `feature/agent-server-gam`; librerie: `feature/stack-tools-0.4`.
Modifiche locali, nessun commit/push/merge durante questa attività.

## Risultato

AgentServer accetta una configurazione GAM gestita e fornisce bootstrap, ingress,
Candidate/Presentation, journal e dispatch degli esecutori registrati. Il codice
applicativo mantiene flow, callback, servizi reali e configurazione delle operazioni.
La demo non contiene più i quattro moduli `DemoSpectre.Host*`.

`handle_action/2` può restringere/rifiutare la proposta o chiedere conferma; il
risultato viene acquisito nell'outbox. `handle_pending/3` e i callback OTP restano
disponibili. Il bridge manuale `gam: {Spectre.Server.GAM, config}` rimane supportato.
Gli override Candidate in modalità gestita non possono alterare l'involucro
autorizzativo della proposta standard.

## Decisioni implementative

- Contratto **additivo** `Stack.Installable.effects/1`, separato dagli helper
  `tools/1`: nessuna modifica incompatibile dei descriptor helper v1.
- Kinetic prepara sempre l'AL consolidato del modello. Il catalogo registrato
  fornisce l'adapter di esecuzione, incluso lo schema effettivo caricato.
- Mnemonic, Beam, Pulse e Lens `:act` dichiarano esecutori espliciti.
- Parametri, policy, identità, flow/Skill e namespace vengono congelati.
- Il kernel GAM rimane invariato; Scope e credenziali restano interne.
- Il consumer autenticato dalla propria app usa ack di rendering e decisioni
  distinte. Le prove di decisione sono monouso, legate alla presentazione.
- Il Domain resta disponibile durante il drenaggio dei worker già avviati.
- Il recupero da disco confronta autorità/configurazione con il record e rifiuta
  divergenze non gestite, preservando la storia.

## Limiti espliciti

Il profilo automatico implementato è `authority: :development`, con storage
effimero o disk. La proposta è formalmente a nome dell'identità umana configurata;
Agent/Skill conservano la provenienza dell'elaborazione. Non si finge che una
Scope del kernel accetti due principal diversi come proponente e approvatore.

Per una fonte di autorità di produzione già provisionata resta disponibile il
percorso manuale. Il consumer deve ottenere l'identità dal confine affidabile
dell'applicazione: il runtime non autentica da solo una persona reale. Codice
Elixir fidato può chiamare API esterne direttamente; non viene sandboxato.

La demo usa un modello deterministico e un encoder di intenti deterministico.
Lightpanda, Vettore, GAM, gli adapter e le interazioni browser sono reali; l'email
viene accettata nella casella locale. Questi test non provano consegna SMTP,
qualità semantica di un encoder neurale o integrazione di un provider LLM remoto.

## Difetti trovati durante la verifica

- Journal in memoria: CAS/delete tentavano di leggere una tupla come una mappa.
- Contratto Candidate: mancavano campi della conseguenza standard nel relativo
  schema di superficie.
- Schema Kinetic: quello ricavato durante compilazione poteva differire dallo
  schema definitivo caricato; il digest ora include il contratto effettivo.
- Proposte OTP senza input: mancava l'osservazione del trigger del callback.
- Input mirato a Skill bloccata: il proxy iniziale poteva bloccare il root;
  l'inoltro ora è asincrono e conserva la provenienza del trasporto.
- Errore di autorità al riavvio: l'avvio collegato poteva interrompere il caller;
  l'allocazione protetta con monitor dell'owner restituisce l'errore previsto.
- Cleanup dello store esterno: poteva precedere un worker di journal ancora
  attivo; lo shutdown ora drena prima e la demo rispetta questo ordine.
- Presentazione: il renderer iniziale esponeva sintassi Elixir; ora mostra campi
  leggibili e materiale completo accanto ai controlli di consenso.
- Diagnostica: gli status dei nuovi processi sono sanificati per evitare Scope,
  token e prove di consenso nei crash report.

## Verifiche

I risultati finali delle suite sono riportati anche nel documento della demo
`../../../demo_spectre/docs/VERIFICATION.md`. I log completi della sessione sono
in `/tmp/*managed*.log`; non sono artefatti necessari al funzionamento.

- Librerie modificate: Kinetic 1339, Mnemonic 538 (11 esclusi), Beam 199,
  Pulse 189, Lens 184 (20 esclusi): passati.
- Tutte e nove le librerie installabili: compilazione incrementale con
  warnings-as-errors passata.
- Moduli nuovi di effetto e Managed: Credo strict mirato passato; il controllo
  globale include segnalazioni preesistenti del repository.
- Documentazione ExDoc con warnings-as-errors e controllo format: passati.
- Core: **4442 passati** (1 doctest, 25 proprietà, 4416 test), 1 escluso.
- Demo: **27 passati**, compilazione con warnings-as-errors e format passati.
- Browser Chromium: **20/20 passati in una run finale pulita**, con JavaScript,
  LiveView e WebSocket attivi. Verificati anche tempi reali di scadenza,
  consensi concorrenti/replay, perdita ack, reconnect, cache e operazioni Mnemonic.
- Dialyzer: **0 errori, 0 esclusioni**, dopo la correzione di una specifica che
  descriveva prematuramente come validati i dati ancora in ingresso.

Log finali: `/tmp/spectre-managed-final-all-green.log`,
`/tmp/spectre-managed-final-release-types.log`,
`/tmp/spectre-managed-final-release-docs.log`,
`/tmp/demo-managed-final-disk-precommit.log`,
`/tmp/demo-managed-final-disk-browser.log`.

La review finale di Opus 5.5 e la relativa risoluzione vengono salvate in
`reviews/claude-opus-5.5-managed-implementation-*`.

La [risoluzione della review finale](reviews/claude-opus-5.5-managed-implementation-resolution.it.md)
distingue difetti confermati, ipotesi verificate sul Bridge e il rilievo non riprodotto.
Le correzioni sono state rieseguite nelle suite. Il controllo temporale preesistente
su failure/restart ora concede tre secondi alle operazioni preliminari; continua a
verificare che la scadenza originale sia conservata e rispettata.

Ultimo esito completo: **4442 passati** (1 doctest, 25 proprietà, 4416 test),
1 escluso, log `/tmp/spectre-managed-final-all-green.log`. Dopo Opus: demo
**27/27**, Chromium **20/20** su storage disk coerente, più ricontrollo mirato
memoria. Dialyzer finale senza errori; ExDoc strict passato nel core e in tutte
e cinque le librerie modificate. Nessun commit/push.
