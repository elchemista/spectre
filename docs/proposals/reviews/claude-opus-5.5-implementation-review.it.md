# Review indipendente di Spectre 0.4 (`feature/agent-server-gam`)

## Verdetto

Il branch non è pronto per una 0.4.0 stabile. Ci sono tre bug alti nel percorso Server/GAM, già pubblicizzato come nuova API:

1. **Worker governati:** se un'operazione governata va in timeout o il worker crasha, il risultato diventa un fallimento e l'obbligo di riconciliazione sparisce.
2. **Callback in crash:** con checkpoint attivo, un'eccezione in un callback conversazionale rigioca all'infinito il risultato salvato nell'inbox e manda il processo in loop di crash.
3. **Deploy:** qualsiasi nuovo deploy rende illeggibili tutti i checkpoint esistenti.

Il kernel GAM, l'intercettazione OTP e il legame fra consenso e input originale reggono nei casi verificati.

Il codice è cambiato mentre lo leggevo. `runtime.ex` ora ha le fasi `interrupt` e `pre_route`, e `checkpoint.ex` ha `definition_fingerprint` e `restore_routing`. La review riguarda la versione attuale. È probabile che gli sha256 di `inventory.json` per questi due file non corrispondano più, ma non posso calcolarli in sola lettura. L'inventario non elenca `lib/spectre/server/pre_route.ex` né `lib/spectre/intent_dataset/embedding.ex`.

`validation.txt` non è una prova attuale. Il primo run completo aveva 8 fallimenti e il run finale risulta "pending". Nessuna mia conclusione si basa sul passaggio dei test.

---

## 1. Bug funzionali ad alta priorità

### A1 — Timeout o crash di un worker governato diventano `{:error, _}` e l'outbox viene perso
**Severità: Alta.** Viola la riga «Timeout dell'executor» della matrice §16 e il principio §9.1 «outcome nil non prova fallimento».

**Dove:**
- `Runtime.handle_info({_, ref, :timeout})` (`runtime.ex:178-189`) e il ramo `:DOWN` (`runtime.ex:191-201`);
- `receive_result/4` (`runtime.ex:988-1002`), che cancella `outbox[command_id]`;
- `Command.validate_args(:propose, ...)` (`command.ex:39-41`), che accetta un `timeout:` scelto dal Server.

**Sequenza riproducibile:**
1. Binding senza presentation, con un executor che impiega più di `worker_timeout` (default 30 s). In alternativa: `propose(ctx, :refund, args, on_result: :r, timeout: 50)` con executor da 200 ms.
2. Il runtime uccide il worker del bridge a metà di `GAM.propose`.
3. `handle_result(:r, {:error, :timeout})` viene chiamato e il default risponde «The request could not be completed».
4. L'entry viene rimossa dall'outbox, quindi `recover_governed` non partirà mai.
5. Se il candidate builder genera un `identity_key` nuovo per ogni turn, un nuovo tentativo dell'utente produce un secondo effetto.

Sul confirm il kernel limita il danno: `final_candidate` conserva l'`identity_key` e cambia il digest, quindi il kernel rifiuta il conflitto. All'utente arriva comunque un falso fallimento.

**Fix:**
- Per `:propose`, `:confirm_pending`, `:explain_pending` e `:resume_pending` non usare `Process.exit(:kill)`.
- Al deadline, lasciare l'entry nell'outbox, notificare `{:recovery_required, id, kind}` e consegnare un risultato tipizzato non terminale, per esempio `{:governed_unknown, %{command_id: id}}`. Oppure avviare `recover_command`.
- Trattare `:DOWN` allo stesso modo.
- Rifiutare `timeout:` per i comandi governati in `Command.validate`.

**Test mancante:** nessun test copre timeout o crash di un worker governato. `runtime_test.exs:155` copre solo `:generate`.

### A2 — Un'eccezione in un callback avvelena l'inbox: loop di crash dopo il restart
**Severità: Alta.**

**Dove:**
- `receive_result/4` (`runtime.ex:992-998`) salva l'inbox prima di chiamare `worker_result`;
- `recover/1` (`runtime.ex:1018-1022`) rigioca l'inbox;
- `conversation/4` (`runtime.ex:463-473`) e `acquire/3` (`:545-546`) sollevano senza isolamento;
- il default `handle_flow(route, _, _)` di `server.ex:47-48` solleva intenzionalmente;
- `Spectre.Server.child_spec` è `:permanent`.

**Sequenza riproducibile:**
1. Agent con `on :x`, Server senza la clausola `handle_flow({:support, :x}, …)`, `checkpoint:` configurato.
2. `input("x")`: il risultato di route viene salvato nell'inbox, `handle_flow` solleva e il processo crasha.
3. Al restart, `:recover` rigioca la stessa entry e il processo crasha di nuovo.
4. Sotto `Spectre.Supervisor.summon` si superano `max_restarts`, il `DynamicSupervisor` termina e cadono tutte le conversazioni.

Lo stesso accade con un `FunctionClauseError` in `handle_result` senza catch-all, con il limite di step superato, con un callback che non restituisce comandi e con `deliver/4`. In quest'ultimo caso il dispatcher riconsegna e il crash si ripete.

**Contrasto con la proposta:** §4.2 dice «il default registra il problema e usa il percorso di errore configurato».

**Fix:**
- `try/rescue/catch` attorno all'`apply` in `conversation/4`.
- In caso di eccezione: spostare l'entry in una quarantena portabile (`dead_letters`, con motivo e numero di tentativi), acquisirla come vista, chiamare `notify({:callback_error, interaction, kind})` e un percorso di errore configurabile.
- Retry limitati.
- Il default di un `handle_flow` mancante deve diventare un errore tipizzato, non una `raise`.

**Test mancante:** `runtime_test.exs:182` verifica solo che il processo muoia per un ctx obsoleto in un `handle_call`, dove l'inbox non è coinvolta.

### A3 — Il fingerprint md5 del codice rende ogni checkpoint illeggibile dopo un deploy
**Severità: Alta (operativa).**

**Dove:**
- `Checkpoint.definition_fingerprint/1` (`checkpoint.ex:317-352`) include `module.__info__(:md5)` di Agent, Server, estensioni, Skill e Stack, più `Definition.canonical`;
- `validate/2` (`:382-383`) confronta in modo stretto;
- `load/1` (`:79-81`) solleva dentro `init`.

**Sequenza riproducibile:**
1. Conversazione con una consent sospesa, input in coda o un comando governato nell'outbox.
2. Deploy di un hotfix qualsiasi del Server.
3. `start_link` fallisce con `checkpoint_definition_fingerprint_mismatch`.

L'unico modo di ripartire è che un operatore cancelli il checkpoint. Così si perdono anche gli obblighi di riconciliazione dei comandi governati, che il moduledoc dichiara «never retried automatically».

**Problema secondario:** il fingerprint viene ricalcolato a ogni `Checkpoint.save`, cioè più volte per ogni messaggio. Il calcolo comprende `Definition.canonical` e la visita dei moduli.

**Fix:**
- Separare versione dello schema e identità del codice.
- Se l'identità non corrisponde, caricare in modalità migrazione: conservare inbox e outbox governato per la riconciliazione, scadere le consent con un `{:consent, :expired}` esplicito, gestire gli eventi di routing non ripristinabili con una notifica, e chiamare un callback `migrate_checkpoint/2`.
- Calcolare il fingerprint una volta in `init`.

**Test mancante:** `checkpoint_routing_test.exs:138` verifica il rifiuto. Non esiste un test di migrazione o upgrade.

### A4 — L'input che conferma non è legato alla show a cui risponde
**Severità: Media-Alta.**

**Dove:**
- `validate_stateful_commands!` (`runtime.ex:578-589`) controlla solo che la pending sia in primo piano e che ci sia un evento qualsiasi;
- `run_pending/5` (`:786-804`);
- `Server.GAM.confirm/4` (`gam.ex:41-65`);
- il kernel controlla `observed_at >= show.committed_at` (`presentation/approval.ex:498`), ma `observed_at` è il momento di `GAM.observe`, non quello di arrivo dell'input.

**Sequenze:**
- **(a)** `handle_pending` → `classify(..., on_result: {:confirmation, id})` con un classifier lento. Nel frattempo un `handle_cast` chiama `resume_pending(id)`, che è consentito senza evento, e produce una nuova Presentation e una nuova show. Poi `{:classified, :confirm}` → `confirm_pending(id)`. Il "sì" digitato prima della nuova visualizzazione viene legato alla nuova show.
- **(b)** `Spectre.Server.deliver(server, "e", {:pending, id}, …)`. `delivery_worker/2` (`:1167-1175`) usa come evento `pending.origin`. Se in `handle_result` l'app chiama `confirm_pending(id)`, la validazione passa e l'interprete riceve l'input che aveva originato la proposta, anteriore alla presentazione.

**Fix:**
- Assegnare a ogni evento la sua `sequence`.
- Salvare nella pending `shown_at_sequence` e una revisione della presentation.
- Confirm e reject accettano solo un evento con `sequence > shown_at_sequence` e `id != origin.id`.
- Aggiungere uno stato `:resolving` che rifiuta `resume`, `explain`, `confirm` e `reject` concorrenti. Lo stesso stato chiude il caso: `cancel` stacca il confirm, un nuovo "sì" avvia un secondo confirm, il kernel lo rifiuta per conflitto e l'utente vede un errore mentre l'effetto è riuscito.
- Passare all'Ingress il `received_at` dell'input.

### A5 — `deliver/4` si fida del payload e non condivide l'identità con il percorso live
**Severità: Media.**

**Dove:** `Runtime.handle_call({_, :deliver, …})` (`runtime.ex:108-129`) deduplica per `event_id`; i risultati live usano `command_id` come chiave dell'inbox (`:989`). `OutcomeDispatcher.event_id/2` vale `"outcome:" <> digest({op, ref})`.

**Sequenze:**
1. Il confirm live restituisce `{:governed, succeeded}` e il Server risponde «Account deleted».
2. L'host traccia lo stesso Act nel dispatcher. `recover` trova la stessa revisione e `deliver` usa un `event_id` diverso, quindi `handle_result` viene eseguito due volte (doppia risposta, o doppio `propose` di follow-up).
3. Qualsiasi processo del nodo può fare `deliver(…, {:pending, id}, {:governed, %{outcome: %{status: :succeeded}}})`: la pending viene cancellata e `handle_result` riceve un esito inventato. La proposta §5.5 dice invece «non accettata come record autorevole dal messaggio».

**Fix:**
- `deliver` deve accettare un riferimento durevole (act_ref e revisione). Il runtime rilegge il risultato tramite il bridge (`GAM.recover_proposal`).
- La chiave d'inbox deve essere canonica per Act e revisione, sia per il percorso live sia per quello consegnato.

**Test mancante:** `outcome_dispatcher_test.exs` usa solo adapter finti e nessun Server reale.

### A6 — I metadata delle proposte del planner si perdono
**Severità: Media.**

**Dove:** `Plan.start/2` (`plan.ex:13-16`) passa `proposal_metadata: %{provider, schema_hash, owner, scope}`, ma `Server.GAM.propose/4` (`gam.ex:25-39`) non lo legge e il candidate builder riceve solo `[args, turn, context]`. Inoltre `Services.consolidate/3` (`services.ex:78`) usa solo `action.name` per le azioni `:local`.

**Conseguenze:**
- Due Skill montate con un'azione locale omonima finiscono sullo stesso binding.
- Il `schema_hash` visto dal modello non viene mai confrontato con quello del binding.

**Fix:**
- Passare i metadata al builder.
- Includere provider e scope nella chiave del binding.
- Rifiutare un `schema_hash` non corrispondente.

**Test mancante:** `stream_test.exs:114` controlla solo la forma del comando.

### A7 — Le route server `protected: true` vengono raccolte nel dataset
**Severità: Media (privacy e integrità del dataset).**

**Dove:** `Arbitrate.unprotected_route/2` (`arbitrate.ex:312-317`) legge `protected` dagli opts dell'handler, ma `route_handler/4` (`agent.ex:1656`) crea sempre `{:server, {path, label}, []}`. Il flag vive in `rule.opts`, come conferma `Server.Router.metadata/2`.

**Sequenza:** `flow :support, defaults: [collect_intent: true]` con `on :delete_account, regex: …, protected: true`, senza `collect_intent: false`. Una classificazione accettata scrive l'esempio.

**Fix:** leggere `route.rule.opts[:protected]`, oppure propagarlo negli opts dell'handler.

**Test mancante:** `server_agent_test.exs:75` copre solo il caso con `collect_intent: false` esplicito.

### A8 — Scadenza del consenso: `expires_at` è un valore statico della config
**Severità: Media.**

**Dove:** `prepare_confirmation/6` (`gam.ex:141`) e `recover_command/3` (`:194`) usano `expires_at: config[:expires_at]`.

**Conseguenze:**
- Un host che configura un TTL (per esempio 300 000) ottiene `consent_expired` subito per ogni consenso.
- Con `nil` nessun consenso scade mai.
- Il runtime non emette mai `{:consent, :expired}`, e le pending sospese si accumulano senza limite nello stato e nel checkpoint.

**Fix:** `consent_ttl_ms` → `expires_at = now + ttl` a ogni show e resume, più un timer nel runtime che produce `handle_result(tag, {:consent, :expired})`.

### A9 — `await_reply` cattura l'input dell'utente e lascia attese orfane
**Severità: Media.**

**Dove:** `execute(:await_reply)` (`runtime.ex:661-699`) imposta `foreground: id`. Il default `handle_pending(%{kind: :reply})` (`server.ex:50-51`) risolve l'attesa con l'input dell'utente.

**Conseguenze:**
- Un'attesa verso un actor (§5.4) assorbe il messaggio successivo dell'utente, che non viene instradato.
- Sostituisce in primo piano una consent senza sospenderla: la consent resta con status `:foreground` ma non è più in primo piano.
- La risposta viene attribuita a `origin`, non all'input che l'ha risolta.
- Se un gruppo contiene `[await_reply, generate]`, `cancel_current` (`:919-948`) uccide anche il worker di attesa ma lascia la pending. Da quel momento ogni input passa a un `resolve_await` che non fa nulla e l'utente non riceve risposta.

**Fix:**
- Attesa in background di default; `foreground: true` solo per domande all'utente.
- Non sostituire una consent attiva.
- Propagare l'evento che risolve.
- `cancel_current` deve cancellare le pending `:reply` delle attese annullate.

### A10 — Un input nuovo può scavalcare la coda
**Severità: Media-Bassa.**

**Dove:** `handle_call(:input)` (`runtime.ex:96-99`) con `finish/1` e `pump/1` (`:893-915`). Quando l'evento corrente finisce, `finish` mette `current: nil` e accoda `:pump` nella mailbox.

**Sequenza:** in coda c'è Q1 e una chiamata `input(N)` è già in mailbox. N vede `current == nil` e parte subito, prima di Q1. L'ordine FIFO è violato.

**Fix:** se la coda non è vuota, accodare N e fare il pump. In alternativa, fare il pump in modo sincrono dentro `finish`.

### A11 — Crescita illimitata dello storage
**Severità: Media-Alta (operativa).**

**Dove:**
- le chiavi del journal GAM (`gam.ex:205-231`) non vengono mai cancellate;
- `seen_events` (`runtime.ex:1012`) non viene mai potato;
- le entry `delivered` del dispatcher non vengono mai compattate;
- `Disk.commit/4` (`disk.ex:92-105`) riscrive l'intero snapshot con fsync a ogni mutazione, con un tetto di 16 MB (`:23`).

I test usano lo stesso store per checkpoint e journal (`server_gam_test.exs:391-397`). Raggiunto il tetto, `Checkpoint.save` solleva (crash) e il journal restituisce `{:nonportable_store_value, …}`, un errore fuorviante. Se lo store è condiviso fra conversazioni, ogni salvataggio costa in proporzione a tutte le conversazioni.

**Fix:**
- Retention: cancellare il journal dopo che l'Outcome è stato acquisito e l'outbox è vuoto.
- Finestra limitata per `seen_events` (per revisione o per tempo).
- Compattazione del dispatcher.
- Un errore `:store_capacity_exceeded` distinto.
- Documentare uno store per conversazione, oppure un adapter append-log.

### A12 — Throughput del dispatcher e retry senza backoff
**Severità: Media.**

**Dove:** `launch_available/1` viene chiamato solo su `:poll` (`outcome_dispatcher.ex:113-116`). `complete/3` non riempie gli slot liberati. Il `launch` in modalità `:deliver` (`:216`) supera `max_concurrency`. Un'entry avvelenata viene ritentata a ogni intervallo.

**Conseguenze:** al massimo `concurrency` operazioni recuperate per intervallo, quindi la latenza cresce linearmente con le entry pendenti.

**Fix:** rilanciare dopo ogni completamento, backoff per entry, dead-letter dopo K errori, contare anche le consegne nella concorrenza.

### A13 — Una show recuperata dal journal torna in primo piano senza nuova visualizzazione
**Severità: Media-Bassa.**

**Dove:** il ramo `:show` di `recover_command` (`gam.ex:182-197`) restituisce `{:pending, …}`, e `apply_worker_result` (`runtime.ex:427-436`) la mette in primo piano. Il test `server_gam_test.exs:305-306` conferma che si ottiene lo stesso Act di show pre-crash.

**Conseguenze:** la policy è incoerente con le pending ripristinate dal checkpoint, che tornano sospese, e con §6.2 («nuova visualizzazione dopo restart»).

**Fix:** status `:suspended` per le pending recuperate da journal.

### Rilievi bassi
- **L1 — Motivo `:unmatched` errato.** `Server.Router.unmatched_reason/2` (`router.ex:109-125`) guarda solo `:local_error` e `:llm_arbitration_failed`. Gli errori di embedding, cache e ricerca semantica arrivano come trace `*_skip` e producono `:no_match`: durante un guasto dell'encoder parte `understand`. Al contrario, un `:local_error` impone `classifier_error` anche quando l'LLM ha concluso «nessun match». **Fix:** usare `routing.errors` e i motivi `{:error, _}`.
- **L2 — Un errore nel controllo interrupt chiude il turno.** `{:error, _}` della fase interrupt (`runtime.ex:351-353`) va a `handle_result(:interrupt, …)`, anche se c'è una consent in primo piano. Un'evidenza indisponibile dovrebbe far proseguire il ciclo.
- **L3 — Ciclo di vita dello stream.** Se il runtime uccide il worker (timeout di default di 30 s anche per lo stream, oppure `cancel`), `adapter.cancel` non viene chiamato (`stream.ex:33-35`). Al consumer non arriva una notifica di interruzione o sostituzione dopo un'anteprima, come richiede la matrice §16. L'envelope dell'anteprima `{Spectre.Server, {:preview, …}}` è diverso da `{Spectre.Server, pid, event}`.
- **L4 — Memoria.** `remember` parte a ogni `respond` (più persistenze parziali per lo stesso input), e `cancel_current` uccide i worker `:remember`.
- **L5 — Ergonomia:**
  - `lookup: [exact: _]` produce `:intent_exact?`, letto solo da `IntentDataset.lookup/2`, non dai plug del Router;
  - `confirmation: [interpreter: …]` passato dal Server viene ignorato in silenzio: meglio sollevare un errore;
  - il default `handle_pending` per le consent rifà la show a ogni messaggio e l'utente resta bloccato;
  - `mix spectre.routes` non stampa la chiave di dispatch esatta (globale `{nil, label}`, annidata `{[..], l}`, montata `{{mount, flow}, l}`).
- **L6 — `summon` ignora `:subject` per gli Agent con Server.** Due summon creano due owner sullo stesso checkpoint e il secondo crasha per conflitto CAS.

---

## 2. Cosa ho verificato e regge

- **Un solo GenServer.** Le envelope riservate, i task e i `:DOWN` dei worker vengono consumati prima della delega. Task, monitor e `{ref, _}` dell'app arrivano all'app (`runtime_test.exs:116,126,144`).
- **Contesto e comandi.** Il ctx obsoleto viene rifiutato, l'identità restituita non cambia l'originale, e il gruppo di comandi viene validato prima di qualsiasi I/O.
- **Acquisizione atomica.** La rimozione dall'inbox e l'aggiunta all'outbox stanno nello stesso salvataggio CAS (`acquire/3`).
- **Comandi governati nell'outbox.** Dopo un crash non vengono mai rieseguiti alla cieca: passano solo da `recover_command`, che riparte da un journal scritto prima dell'effetto. Testato in `server_gam_test.exs:293,382`.
- **Consenso:**
  - la show deve essere riuscita;
  - l'interprete riceve l'input originale;
  - l'etichetta del classifier non vale come consenso (`:321`);
  - lo scope viene confrontato (`:235`);
  - il rifiuto produce Evidence contraria (`:259`);
  - il resume richiede una nuova identità di show;
  - un resume fallito lascia la pending sospesa (`:425`).
- **Nessuna Instance nascosta.** `grep Instance|Session|Work|Vigil` su `lib/spectre/server` non trova nulla, e `Runner.reply` non avvia Instance.
- **Streaming:** l'anteprima del planning viene trattenuta senza una projection; l'ordine dei terminali è validato per batch (`ProviderProtocol.validate_batch`); c'è il controllo di coerenza sul testo terminale.
- **Disk e IntentDataset:**
  - Disk: checksum, fsync e rename; owner fisico anche con alias via symlink;
  - IntentDataset: lookup esatto prima della ricerca semantica, e gli errori del provider non diventano miss (`intent_dataset_test.exs:160`).
- **Servizi:** il prompt root del Server funziona (`server_prompt_test`); `pending_context` arriva al classifier LLM; gli override nominati locale/LLM convivono con lo Stack (`server_agent_test.exs:129,153`).

---

## 3. Lavoro di integrazione ancora necessario (gap, non bug)

- **Migrazioni:** migrazione completa di freelance; Skill, Work, Vigil, reflection e Morph verso il nuovo owner; codec dei checkpoint 0.3.
- **Proposte da actor o background:** oggi falliscono sempre in modo chiuso, perché `GAM.open_turn(scope, nil)` non ha una base di input. Serve un percorso Ingress per gli actor.
- **Dispatcher non collegato:** il bridge non chiama mai `track`, e manca un registry per identità che permetta di «ritrovare o riavviare» il Server.
- **Mancano ancora:**
  - dichiarazione della HostProfile;
  - cleaner incrementale Kinetic;
  - test di `code_change` e upgrade;
  - matrice di conformance OTP (§5.6);
  - misure di prestazioni.
- **Handler pre-route legacy:** `Spectre.Turn.Handlers.dispatch` può ancora produrre effetti fuori da GAM. È compatibilità, ma va inventariata.
- **`protected: true`:** nel nuovo runtime è solo metadata, coerente con la scelta dichiarata. Valutare un fail-closed quando una route protetta propone un binding senza conferma.

---

## 4. Test di regressione da aggiungere

1. Propose e confirm con executor più lento di `timeout`/`worker_timeout`: niente `{:error, :timeout}`, outbox conservato, nessun secondo effetto. (A1)
2. `handle_flow` mancante, o `FunctionClauseError` in `handle_result`, con checkpoint, poi restart: il processo resta vivo, l'entry finisce in quarantena, `notify` viene emesso. (A2)
3. Ricompilare il Server con un checkpoint contenente una consent e un propose nell'outbox: avvio in modalità migrazione. (A3)
4. Un `resume_pending` in background durante un classify: il confirm viene rifiutato. `deliver({:pending, id})` seguito da `confirm_pending`: rifiutato. (A4)
5. Esito live più `deliver` per lo stesso Act: un solo `handle_result`. `deliver` con un payload inventato: non accettato. (A5)
6. Due Skill con un'azione locale omonima in un piano: binding distinti; `schema_hash` diverso: rifiutato. (A6)
7. Route protetta con `collect_intent` ereditato: nessun esempio scritto. (A7)
8. TTL della consent con scadenza e `{:consent, :expired}`. (A8)
9. `await_reply` con una consent attiva, e `cancel` durante `[await_reply, generate]`. (A9)
10. Ordine FIFO con un input che arriva prima del `:pump`. (A10)
11. Superamento di `max_bytes` dello store: errore distinto e journal potato. (A11)
12. Dispatcher con N entry e concorrenza 1: latenza limitata. (A12)

---

## 5. Prontezza al rilascio

- **0.4.0 stabile: no.** A1–A3 colpiscono proprio le garanzie promesse dalla nuova API (esiti incerti, recovery, durabilità) e non sono coperte da test.
- **Release candidate o preview:** possibile dopo la correzione di A1–A3 e A7, con A4, A5, A8, A9 e A11 dichiarati come limiti noti in `implementation-status.it.md`, e dopo un run completo verde nuovo, visto che quello attuale risulta pending.
- **Migrazione multi-package e freelance:** non va dichiarata completa.