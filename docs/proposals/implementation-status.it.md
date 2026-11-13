# Implementazione 0.4 — stato e verifica

Branch: `feature/agent-server-gam`, creato da `origin/main` (`1059bd8`, 0.3.4).
Versione della nuova linea: **0.4.0**, come deciso dall'autore.
Kernel importato: `6906258`, namespace `Spectre.GAM`, cartella `lib/spectre/gam`.

La [proposta consolidata](agent-server-gam-from-0.3.it.md) resta il contratto di
destinazione. Questo documento distingue l'implementazione verificabile dalle
attività di migrazione ancora necessarie. La guida operativa è
[Agent e Server](../AGENT_SERVER.md).

**Stato: correzioni finali completate e verificate.** Il core e il
lifecycle con timer sono implementati. I tre problemi della review e le race
aggiuntive sono chiusi dalla [review indipendente](reviews/cross-review-lifecycle-resolution.it.md).
Vedi [correzioni e regressioni](remaining-fixes-0.4.it.md) e
[verifica del branch](verification-0.4.it.md).
La suite finale conta **4.323 casi passati** sia su OTP 29 sia su OTP 28;
la copertura è **95,10%**, con soglia originaria 95% invariata.

**Decisione successiva sui package:** gli helper applicativi si chiamano
`kinetic`, `mnemonic`, `lens` ecc., come descritto nella
[sezione 4.3 della proposta](agent-server-gam-from-0.3.it.md#43-helper-dei-package-installati-kinetic-mnemonic-lens).
Il contratto è documentato; helper, primitiva condivisa e adapter dei package
non sono ancora implementati o certificati dai risultati della suite sopra.

| Area | Implementazione nel branch | Verifica |
| --- | --- | --- |
| Versione e baseline | 0.4.0; contratti 0.3 conservati come baseline del core | Il run iniziale di baseline contava 2.552 test passati; non è il risultato finale del branch |
| Kernel GAM | Importati 204 moduli e facciata; nessuna riscrittura delle leggi | Parità AST dopo namespace; suite GAM importate |
| Namespace e supervisione | `Spectre.GAM`, Domain condivisibili; supervisor GAM separato | Avvio applicazione e test kernel |
| Agent dichiarativo | `server`, route senza corpo, default dei flow e alias espliciti | Test DSL, routing, nested flow e scope |
| Stack/classifier | Binding locale/LLM separati, override dello Stack | Test dei contratti e integrazione con provider distinti |
| Server OTP | Un GenServer del runtime; delega di callback applicative nello stesso processo | Test call/cast/info, reference possedute, ctx e worker |
| Subject e owner | Registry locale con chiave canonica Agent/Subject; summon concorrenti riusano l'owner | Test di concorrenza, startup diretto, subject distinti e restart; non è un lock distribuito |
| Flow/fallback | `handle_flow`, `:unmatched`, cause distinte e `understand`; un miss ordinario non blocca un fallback funzionante | Routing legacy, provider indisponibili e LLM alternativo |
| Consenso | Input originale legato alla show; TTL predefinito 300.000 ms, oppure durata esplicita o `:infinity` | Conferme, rifiuti, input obsoleto, interprete lento, scadenza e ripristino sospeso |
| Attese actor/utente | `await_reply` in background; `await_input` esplicita in foreground; correlazione tramite `resolve_await` | Una risposta utente non viene assorbita da un'attesa actor; cancellazione e timeout |
| Timer applicativi e lifecycle GAM | Chiusura immediata/programmata, timer Runtime o OTP applicativi, `private`, audit host `requested/applied/ignored` | Regressioni GAM, crash/CAS, deadline, report ritardati e quarantena; rilievi finali chiusi dalla review incrociata |
| Effetto e continuazione | Candidate/Presentation/Act/Attempt/Outcome originali del kernel | Test dell'effetto reale con executor attestante |
| Journal e continuazioni | Identità esatta salvata prima dell'effetto; journal liberato dopo acquisizione durevole; `operations` conserva Act non terminali | Recovery senza nuovo effetto, risultati live/delivery correlati e osservazioni tardive |
| Checkpoint/inbox/outbox | CAS, proiezione portabile e fingerprint; migratore esplicito `{Modulo, :funzione}` | Restart, rifiuto di codice incompatibile e preservazione obbligatoria dei dati di riconciliazione |
| Store e dispatcher | Disk con checksum/fsync/rename; continuazioni dell'host, backoff, capacità e compattazione espliciti | Corruzione, conflitti, restart e delivery almeno una volta; callback non garantiti una sola volta |
| IntentDataset | Raccolta online non verificata, exact senza encoder e indice di soli vettori compatibili | Verifica, revisione testo, snapshot e profili; `dataset_lookup: false` distinto dal legacy `cache: false` |
| Training | Pipeline e comandi esistenti conservati | Training con artifact e companion dataset nei test |
| Vettore | Ricerca quantizzata/Hamming opzionale con reranking | Test della query e dei vettori già salvati |
| Streaming | Consolidamento prima delle proposte; envelope con runtime/interazione/generazione e `preview_end`; guard del trasporto | Chunk, terminali, interruzione del worker, stallo provider e assenza di effetti parziali |
| Memoria | Gestione contestuale e proiezione legacy centrata sulla cronologia | Recall/persist e mancato replay; non dimostra la compatibilità di ogni adapter legacy |
| Tooling | Generatore `--server`, chiavi di dispatch in routes, export e batch embed IntentDataset | File generati, label/profili, riuso vettori e output atomico senza training implicito |

Il migratore di checkpoint riceve `(proiezione_salvata, metadata)` e restituisce
`{:ok, proiezione_migrata}` o `{:error, motivo}`. I metadata comprendono Agent,
Server, versione dello schema e fingerprint `from`/`to`. Può adattare gli
assigns, non eliminare o alterare identità, inbox, outbox, attese, eventi acquisiti,
operations o quarantena. La variante `{:ok, proiezione_migrata, mapping_route}`
permette di rimappare esplicitamente soltanto gli hint di routing a destinazioni
dichiarate e univoche, dopo la verifica di immutabilità dei fatti; conserva la
provenienza delle chiavi precedenti e non riclassifica gli input. Senza migratore un fingerprint differente resta un
errore esplicito; non è una conversione automatica dei checkpoint 0.3.

Il TTL è verificato anche dopo l'interprete del consenso. Il journal conserva
la deadline originale; un ripristino non la prolunga. L'ingress deve autenticare
l'input e vincolare la validità della Evidence alla scadenza secondo il clock
dell'host. La scadenza arriva al Server come `{:consent, :expired}`.

Il risultato `{:governed_unknown, dettagli}` conserva l'obbligazione di
riconciliazione dopo un errore incerto; non equivale a fallimento dell'effetto.
Le delivery governate risolvono riferimenti reali al kernel invece di accettare
payload di esito inventati. Il dispatcher richiede registrazione e adapter
dell'host: la sola supervisione del processo non collega automaticamente tutte
le continuazioni.

## Limiti e lavoro di migrazione

- `Instance` e i suoi sottosistemi restano per compatibilità: non sono ancora
  eliminati. La loro presenza non costituisce un secondo owner quando si avvia
  il nuovo Server. La sostituzione generale richiede migrare tutti i consumer.
- Skill, Work/Vigil/Directive, reflection e Morph conservano percorsi legacy.
  Riconoscere una route Skill con il suo scope e la sua radice di prompt non
  trasferisce automaticamente workflow, stato privato, effetti e recovery al
  nuovo owner. Servono adapter e verifiche dei singoli contratti.
- I checkpoint legacy non vengono promossi automaticamente a prove di consenso
  GAM. Migrazione o riavvio controllato vanno decisi per ciascun tipo di attesa.
- Kinetic, Mnemonic, Beam e Directive dichiarano Spectre `~> 0.3.3`, che esclude
  0.4; per Kinetic e Beam è una dipendenza di test. I repository esterni non sono
  stati migrati da questo branch. La porta di proiezione pubblica non crea un
  cleaner incrementale Kinetic che il package non implementa.
- Prism e Pulse dichiarano `~> 0.4.0`, ma usano l'authoring della precedente
  linea 0.4: Collection/Observer/Turn e RequestBuilder dell'Agent. Il numero di
  versione non attesta compatibilità con il nuovo split Agent/Server; richiedono
  adattamento e test dei rispettivi package.
- Il bridge di memoria non ricostruisce tutto lo stato del vecchio Instance.
  Adapter che dipendono da route, effetti, awaitable o eventi completi richiedono
  verifica; i test di recall/persist non attestano Mnemonic in produzione.
- Il checkout `freelance` viene usato come riferimento; il suo codice e i suoi
  servizi di produzione non vengono modificati in questo branch. La migrazione
  completa Client/Freelancer, brief e anonimizzazione resta un'attività del pilota.
- Classi governate, mandati, credenziali, ingressi autenticati, isolamento e
  ricevute del canale sono configurazione reale dell'host. Non sono generati
  come autorizzazioni permissive per rendere eseguibile un esempio.
- La cancellazione di un trasporto e `preview_end` chiudono la generazione
  provvisoria; non provano l'annullamento di un effetto già impegnato. Un messaggio
  actor non è di per sé una osservazione autenticata dell'utente.
- La deduplicazione recente è limitata e la delivery è almeno una volta.
  Operations incerte, dead letter, capacità dello store e recupero dei fatti
  restano responsabilità operative da configurare e sorvegliare nell'host.
- Prestazioni e riduzione del coordinamento dell'applicazione non sono ancora
  dimostrate dal solo passaggio dei test del framework. Vanno misurate sul pilota.

## Revisione

La [review di implementazione Opus 5.5](reviews/claude-opus-5.5-implementation-review.it.md)
resta immutata. La [risposta tecnica ai rilievi](reviews/claude-opus-5.5-implementation-resolution.it.md)
descrive correzioni e regressioni ispezionabili; è scritta dagli implementatori,
non è una seconda approvazione di Opus. La verifica finale deve includere suite
completa, copertura e controlli statici sullo snapshot conclusivo. La presenza
del kernel e dei nuovi callback non completa la migrazione dell'ecosistema o
dell'applicazione `freelance`.
