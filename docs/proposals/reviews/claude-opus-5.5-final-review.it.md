# Seconda review indipendente: Spectre 0.4.0 Agent/Server/GAM

Ho letto solo la copia immutabile in `/tmp/spectre-agent-server-final-review/source`, i documenti indicati e i log in `validation/`. Non ho eseguito shell né test, e non ho potuto ricalcolare gli sha256 di `inventory.json`. L'inventario ora elenca `server/pre_route.ex` e `intent_dataset/embedding.ex`, che mancavano alla prima review.

## Verdetto sul core implementato

Il core è molto migliorato. Il kernel GAM resta quello originale:
- l'idempotenza per `identity_key` passa da `admission_from_projection`;
- dopo un Attempt esistente il Runner non rilancia l'executor.

Il bridge rispetta journal-prima-dell'effetto, show governata e Evidence dell'ingress. La quarantena e il legame del consenso a sequenza e revisione sono solidi.

**Non lo considero ancora pronto come core stabile, per un motivo concreto.** La correzione di A1 introduce un blocco: un crash o un deadline in `confirm_pending`, `explain_pending` o `resume_pending` blocca la conversazione fino al riavvio del processo (N1). C'è anche un buco operativo nella migrazione dei checkpoint (N3).

Dopo N1, una suite completa verde e il gate di coverage, è ragionevole una RC o preview del core.

**Stato dei log** (nessun run completo verde attuale):
- Coverage: **94,69% contro soglia 95%**, gate fallito (`spectre-agent-server-coverage-final.log:155-158`). Il log non riporta il conteggio dei test.
- `STATUS.txt`: il run completo copiato aveva 40 fallimenti nel routing legacy. Dopo i fix sono passati 815 test mirati; il rerun completo è "pending".
- Verdi solo run mirati: routing 815, review regressions 12, planning boundaries 12, fastembed reale 1.
- Credo pulito; build della documentazione riuscita.

## Tabella A1–A13

| # | Stato | Motivazione e riferimenti |
|---|---|---|
| **A1** | **Parziale** | **Corretto:** il deadline non uccide il worker governato (`runtime.ex:269-279`). Timeout e crash producono `{:governed_unknown, …}` e l'outbox resta (`:1700-1724`, `:202-216`). `timeout:` è rifiutato su `propose` (`command.ex:39-45`). Il risultato reale tardivo viene acquisito, e il test copre solo `propose`. **Nuovo buco:** per i comandi su pending il lock `:resolving` non viene mai rilasciato (N1). Inoltre non c'è un modo di riconciliare durante l'esecuzione: serve un riavvio o una delivery dell'host. |
| **A2** | **Chiuso** (residui bassi) | `Failure.capture` avvolge callback, limite di step e "nessun comando" (`runtime.ex:590-623`). La quarantena rimuove l'entry dall'inbox, la marca come vista ed è limitata (`failure.ex:19-47`). Testato anche attraverso il restart. Residui: un errore fuori dal capture va ancora in loop di crash, cioè `Checkpoint.save` a capacità esaurita (`checkpoint.ex:132`) e `restore_routing!` in `init` (vedi N3). Il default `on_callback_error: nil` lascia l'utente senza risposta. |
| **A3** | **Parziale** | Il fingerprint è in cache e si aggiorna in `code_change` (`checkpoint.ex:386-398`, `runtime.ex:246`). Il migratore MFA è esplicito e `preserve_reconciliation` funziona (`:403-451`). Il rifiuto di default è una scelta dichiarata e coerente, ma qualunque deploy che tocchi Agent, Server o Skill richiede un migratore. **Nuovo buco N3:** il migratore non può riparare il routing delle sezioni immutabili. |
| **A4** | **Chiuso** | Ogni evento ha la sua `sequence`. La pending conserva `revision` e `shown_at_sequence`, l'evento conserva `pending_snapshot`, e l'id deve differire dall'origine (`runtime.ex:384-395`, `:541-551`, `:830-838`). Il lock `:resolving` è in `:807-808` e `:964-967`. `received_at` ed `event_sequence` arrivano all'ingress (`gam.ex:459-470`). Residuo ergonomico in N7. |
| **A5** | **Chiuso** (residuo N2) | `{:governed, payload}` è sempre rifiutato (`delivery.ex:5`). I riferimenti si risolvono dalla vista dello Scope, con controllo di scope e principal (`gam.ex:310-330`). La chiave `gam-result:` è comune a live e delivery (`gam.ex:273-277`). `operations` conserva gli Act non terminali (`operations.ex`), e `settled_worker_result?` evita i doppioni tardivi. |
| **A6** | **Chiuso** | Le operation sono qualificate `{scope, via, name}` (`catalog.ex:33-37`). I metadata vengono da `effect.owner/scope` di origine fidata (`services.ex:86-100`). Owner, scope e schema sono validati prima di `open_turn` (`gam.ex:40-41`). Una validazione saltata con metadata vuoti riguarda solo codice app esplicito. |
| **A7** | **Chiuso** | La protezione si legge da `rule.opts[:protected]` (`arbitrate.ex:312-323`); includerla richiede un opt-in esplicito. |
| **A8** | **Chiuso** | La deadline è assoluta per ogni show (`gam.ex:359-365`). La scadenza è ricontrollata dopo l'interprete e prima dell'osservazione e della submit (`:60-75`). I timer sono ripristinati in `recover` (`runtime.ex:1504-1507`) e producono `{:consent, :expired}` una sola volta (`:1277-1301`). |
| **A9** | **Parziale** | `await_reply` è in background e `await_input` in primo piano (`server.ex:143-146`, `runtime.ex:895`); viene propagato l'evento che risolve (`:938`); `cancel` cancella le attese (`:1223-1226`). Residui: un primo piano può essere ancora sostituito da consent o show tardive (N4), e la delivery a un'attesa actor lascia worker e outbox (N5). |
| **A10** | **Chiuso** | Con coda non vuota il nuovo input va in coda e parte il pump (`runtime.ex:317-345`). Il pump prende la testa della coda (`:1182-1187`). L'interleaving in mailbox descritto nella prima review non è più possibile. |
| **A11** | **Parziale** | **Fatto:** release del journal, `seen_events` limitati (`inbox.ex`), dead letter limitati, `:store_capacity_exceeded` distinto, compattazione del dispatcher. **Resta:** snapshot intero con fsync a ogni save, scrittura amplificata e finestra di dedup consumata (N6). `operations` resta illimitato per scelta. La capacità esaurita genera un crash loop. |
| **A12** | **Chiuso** | Slot riempiti dopo ogni completamento (`outcome_dispatcher.ex:204`). Le consegne contano nella concorrenza. Rotazione con cursore, backoff persistito, dead letter e `retry` esplicito. |
| **A13** | **Chiuso** | La show recuperata dal journal resta `:suspended` (`gam.ex:229`, `runtime.ex:545`). Residuo: `foreground: nil` sovrascrive il primo piano altrui (N4). |

**L1–L6:**
- **L1:** chiuso.
- **L2:** chiuso; manca ancora il test dedicato.
- **L3:** chiuso. `TransportGuard` monitora il worker e manda sempre `preview_end`, anche senza anteprime: innocuo.
- **L4:** chiuso nel runtime. La compatibilità degli adapter legacy è dichiarata parziale.
- **L5:** parziale. Il default di `handle_pending` per la consent rifà la show a ogni messaggio e non conferma mai; è documentato.
- **L6:** chiuso.

## Nuovi bug

### N1 — Alta: crash o deadline di confirm/explain/resume bloccano la conversazione
**Sequenza:**
1. `execute` porta la pending a `:resolving` per tutti i comandi su pending, tranne il resume di un'attesa `:reply` (`runtime.ex:964-977`).
2. L'interprete, il presentation builder o lo scope resolver dell'host sollevano. Girano nel worker (`gam.ex:62,137,497`). Oppure la chiamata al Domain esce.
3. Arriva il `:DOWN` e scatta `uncertain_governed` (`:211-213`). Viene chiamato `handle_result(…, {:governed_unknown, …})`, ma la pending **resta `:resolving`** e il worker è rimosso.
4. Ogni input successivo vede `resolving_pending?` (`:319`, `:1693-1698`) e va in coda. `pump` e `finish` non avanzano (`:1128`, `:1177`). Superato `queue_limit`, si ottiene `{:error, :busy}`.
5. Non c'è uscita:
   - confirm, reject, explain e resume sollevano «already resolving» (`:807-808`);
   - la scadenza ignora `:resolving` e consuma il timer (`:1279-1280`);
   - `cancel` esclude i worker governati (`:1195-1200`).

**Uscite possibili:**
- Solo un riavvio, se c'è un checkpoint: `restore_state` imposta `:suspended` e poi parte `recover_governed`.
- Oppure `deliver({:command, id}, {:governed_ref, …})`, ma solo per un confirm con journal `:effect`.
- Per explain e resume, `resolve_command_result` confronta l'identità del Candidate dell'effetto con lo show Act e fallisce (`gam.ex:300`), quindi non esiste alcuna via in esecuzione.
- Senza checkpoint il blocco è permanente.

Con il timeout il blocco dura quanto il bridge resta appeso.

**Fix:**
- Al `:DOWN` di un worker governato con journal disponibile, avviare subito `start_governed_recovery`. È sicuro, perché ci sono journal e idempotenza del kernel.
- Se il journal non c'è, ripristinare `previous_status`.
- In alternativa, introdurre uno stato `:uncertain` che non blocca la coda e rifiuta le risoluzioni.
- Aggiungere un test con l'interprete che solleva, seguito da un nuovo input.

### N2 — Media: il registro `operations` si ritira su `:definitive_no_effect`, che il kernel considera correggibile
`Operations.terminal?` include `:definitive_no_effect` e rimuove l'operazione (`operations.ex:4-13,73-74`). Il kernel però ammette un'osservazione tardiva `:succeeded`/`:failed` con `contradicts_outcome_ref` verso un no-effect (`gam/facade/observation.ex:133-146`).

**Sequenza:** l'esito live è `definitive_no_effect`, l'operazione viene ritirata e il journal rilasciato. Poi il dispatcher consegna la correzione `succeeded`, che viene rifiutata con `:unknown_command_continuation` (`runtime.ex:1417-1418`). L'app resta convinta che l'effetto non sia avvenuto.

**Fix:** trattare come finali solo `:succeeded` e `:failed`, oppure conservare l'operazione finché l'host non la dimentica esplicitamente.

### N3 — Media-Alta (operativa): migrare un checkpoint con route rinominate o spostate è impossibile
**Sequenza:**
1. `pending.origin`, gli eventi di outbox, inbox e `operations` contengono un `checkpoint_route` con la `key` di dispatch (`checkpoint.ex:265-281`).
2. `preserve_reconciliation` vieta di toccare quelle sezioni (`:433-451`).
3. Dopo la migrazione, `restore_projection` chiama `restore_routing!`, che solleva su `checkpoint_route_not_found` (`:286-341`, `:227-236`) dentro `init`. Il risultato è un crash loop.

Un'operazione ambigua può restare in `operations` a tempo indeterminato. Quindi un deploy che rinomina una route o la sposta in un flow annidato rende illeggibile quel checkpoint, anche con un migratore. Il test di migrazione usa `event: nil` e `origin: nil` (`checkpoint_routing_test.exs:171-172`), quindi non copre il caso.

**Fix:** passare al migratore una mappa di rimappatura delle chiavi, oppure ripristinare la route non trovata come snapshot portabile, con notifica, invece di sollevare.

### N4 — Media-Bassa: il primo piano può essere sostituito senza sospendere la pending precedente
Il ramo `{:pending, …}` imposta `foreground` globalmente, a `id` oppure a `nil` se recuperata (`runtime.ex:553-554`). Il controllo del primo piano per `resume_pending` vale solo per `:reply` (`:810-815`).

**Sequenze:**
- Un `handle_cast` chiama `resume_pending(P2)` mentre P1, consent o `await_input`, è in primo piano.
- Oppure arriva tardi una show recuperata o andata in timeout.

**Conseguenza:** P1 resta con `status: :foreground` ma non è più in primo piano. Gli input finiscono alla pending sbagliata o vengono instradati. Non ci sono approvazioni false.

Contraddice in parte `AGENT_SERVER.md:128-132`, che dice «does not … replace an open consent».

### N5 — Media-Bassa: la delivery a un'attesa actor non chiude worker e outbox
`deliver(…, {:pending, id}, result)` su una pending `:reply` (`runtime.ex:1666-1669`) passa per una continuation senza `command_id`. Il worker `:await_reply` e l'entry di outbox restano (`:1359`).

**Conseguenze:**
- Con `timeout: :infinity` restano per sempre.
- Se il processo riparte prima del timeout, `recover_reply_wait` non trova la pending e **riesegue** `await_reply` (`:1536-1542`). L'attesa risorge, e più tardi `handle_result(tag, {:error, :timeout})` arriva una seconda volta.

**Fix:** riusare il percorso di `resolve_await`, che trova il worker e cancella l'entry di outbox.

### N6 — Bassa-Media: release del journal per ogni comando
`release_command_journal` gira per qualsiasi risultato con `command_id`: generate, classify, call_actor (`runtime.ex:1366`). Il risultato del worker di release ha `command_id` nil e quindi riceve un uuid (`:1329`). Passa poi per inbox con **due save fsync dell'intero snapshot**, più uno slot di `seen_events` (`:1350-1365`).

La finestra di dedup degli id esterni si consuma più in fretta e lo store scrive circa il doppio.

**Fix:** fare la release solo per i tipi governati e non far passare i risultati di release dall'inbox.

### N7 — Bassa (ergonomia): un confirm obsoleto diventa un dead letter senza risposta
Un confirm legittimamente obsoleto, per esempio un classifier lento durante un resume, solleva (`runtime.ex:836-837`). Il risultato è la quarantena e nessuna risposta all'utente, perché il default `on_callback_error` è nil (`:631-642`). Il ctx non espone sequenza o snapshot per un controllo preventivo.

**Fix:** consegnare un risultato tipizzato, per esempio `{:consent, :stale_input}`.

### Rilievi minori
- **N8:** dopo un restart una pending `:resolving` diventa `:suspended` con `previous_status: :foreground`. Se la recovery fallisce, torna `:foreground` mentre `state.foreground` è nil (`runtime.ex:569-576`, `checkpoint.ex:66-69,92`). È un'incoerenza che non apre falle.
- **N9:** `Plan.continue` tratta `{:governed_unknown, _}` e `outcome: nil` come un rifiuto: risponde «could not be confirmed». Un successo reale tardivo poi prosegue il piano e risponde «completed» (`plan.ex:19-30`, ordine delle clausole in `server.ex:63-70`).
- **Riesecuzioni al recovery:** `call_actor` e gli altri comandi non governati nell'outbox vengono rieseguiti al recovery (`runtime.ex:1528-1529`). È at-least-once anche verso gli actor, e i documenti lo dicono solo per i callback.
- **Delivery su comandi in corso:** una delivery non governata su `{:command, id}` di un comando non governato ancora in corso produce due `handle_result`. Il confine di fiducia è comunque il nodo.
- **Batch embed:** `embedding.ex:193-207` scrive senza fsync prima del rename. È atomico verso gli altri processi, non durevole a un crash del sistema.

## Cosa ho verificato e regge
- **Envelope e callback:** le envelope riservate e il consumo di DOWN, timer e result prima della delega reggono. `terminate` non uccide i governati.
- **Kernel:** in recovery il kernel restituisce i fatti durevoli invece di rilanciare l'executor.
- **Recovery in `recover`:** l'ordine inbox → outbox → timer è corretto, con salto dei comandi attivi.
- **Store Disk:** sequenza globale persistita contro l'ABA, delete con CAS, owner fisico locale. Resta un caso marginale: uno snapshot v1 ricava la sequenza dal massimo residuo.
- **IntentDataset:**
  - exact prima della ricerca semantica;
  - `lookup: false`, `exact: false` e `dataset_lookup` per route coerenti nei plug;
  - profili degli embedding validati prima dell'encoder;
  - nessuna scrittura parziale.
- **Documentazione:** `implementation-status.it.md` e `AGENT_SERVER.md` non dichiarano complete le migrazioni dell'ecosistema, di freelance o dei pacchetti esterni. L'unica affermazione falsa che ho trovato è quella di N4. A1 e A3 vengono presentati come più completi di quanto siano per via di N1 e N3.

## Test mancanti prioritari
1. Interprete o presentation builder che sollevano durante confirm e resume, seguiti da un nuovo input (N1).
2. Correzione tardiva dopo `definitive_no_effect` (N2).
3. Migrazione con route rinominata e pending o operation presenti (N3).
4. Resume da background con un altro primo piano attivo (N4).
5. `deliver` a un'attesa actor e poi restart (N5).
6. Guasto della fase interrupt con consent attiva (L2).
7. Suite completa e coverage ≥95% sullo stesso snapshot.