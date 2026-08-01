# Spectre vNext / v0.2.0 — implementation handoff

Ultimo aggiornamento: 2026-07-31

## Stato della sessione

- Repository: `/home/dev/Sviluppo/spectre/spectre`
- Branch attivo: `agent/v0.2.0-concept`
- Documento sorgente: `SPECTRE_VNEXT_CONCEPT(2)(1).md`
- Target richiesto: `v0.2.0`
- Stato: implementazione e hardening completati localmente; resta soltanto la
  scelta dell'utente su commit, push e pubblicazione.
- Nessun commit o push è stato eseguito in questa sessione.
- Le modifiche preesistenti dell'utente a `.gitignore` e il concept non tracciato
  devono essere preservati.

## Istruzioni vincolanti dell'utente

1. Implementare prima tutto il nucleo previsto dal concept.
2. Eseguire compilazione e test completi soltanto dopo aver terminato
   l'implementazione.
3. I test finali devono includere Work reali con funzioni registrate, oltre a
   runtime, supervisor, monitor, retry, recovery, Vigil e controllo.
4. `Atom.to_string/1` è ammesso e va mantenuto dove esprime una normale
   serializzazione atom -> stringa.
5. Non creare atom da stringhe dinamiche con `String.to_atom/1` o primitive
   equivalenti; quando la conversione è necessaria deve usare
   `String.to_existing_atom/1` e gestire esplicitamente l'atom sconosciuto.

La precedente rimozione trasversale di `Atom.to_string/1` è stata annullata.
Le conversioni sono tornate all'API idiomatica, mentre il solo generatore
dinamico di moduli nei test è stato sostituito con un catalogo finito di atom
letterali. Anche il decoder portabile risolve i moduli esclusivamente tra atom
già esistenti e moduli disponibili, senza creare atom a runtime.

## Piano completato

1. Stato canonico, snapshot, merge, journal e checkpoint Agent.
2. Runtime operativo condiviso.
3. Work, Runner temporanei, scheduler, supervisor, monitor e fencing.
4. Pausa, aggiornamento, ripresa, stop, retry e riconciliazione.
5. Vigil, trigger, timer, significatività e recovery.
6. Flow integration, viste, eventi e disambiguazione.
7. Porte per funzioni, Action/Lens, planner/Kinetic, cognizione/Prism e
   memoria/Mnemonic.
8. Consegna proattiva governata.
9. API, documentazione e versione `0.2.0`.
10. Compilazione, test completi, coverage e hardening finali.

## Implementato

### Stato canonico dell'Agent

Sono stati aggiunti:

- `Spectre.Instance.Canonical`
- sezioni canoniche separate `flow`, `work`, `vigil`, `directive`, `control`,
  `correlations`, `events`;
- revisioni canoniche e revisioni per sezione;
- snapshot con permessi espliciti di lettura/scrittura;
- change set correlati;
- rifiuto dei merge stale sulla stessa sezione;
- idempotenza dei change id e rilevazione di conflitti;
- journal limitato delle transizioni;
- checkpoint JSON stretto e versionato;
- restore del checkpoint nell'Instance;
- commit dello stato Flow nella sezione canonica.

File principali:

- `lib/spectre/instance/canonical.ex`
- `lib/spectre/instance/canonical/*.ex`
- `lib/spectre/instance/checkpoint_store.ex`

### Checkpoint durevole

È presente un adapter CAS con:

- `load/2`;
- `compare_and_swap/5`;
- persistenza asincrona serializzata fuori dal GenServer;
- barriera pubblica `flush_checkpoint/2`;
- stato pubblico del checkpoint;
- coalescing della revisione pending;
- monitor del task di persistenza;
- restore automatico dallo store configurato.

API aggiunte su `Spectre.Instance` e `Spectre`:

- `checkpoint/1`;
- `flush_checkpoint/2`;
- `checkpoint_status/1`.

### Runtime operativo condiviso

È stata creata la famiglia `Spectre.Operation.*`, comprendente:

- Definition, Spec e registry chiuso;
- Loop, Request, Wait, Attempt, Result, Progress, Outcome e Update;
- Budget e Retry;
- Controller e Runtime deterministico;
- Executor, Execution ed ExecutionContext;
- Runner temporaneo e DynamicSupervisor;
- Monitor e classificazione del crash;
- Control e comandi durevoli;
- viste e riferimenti pubblici;
- eventi committed e subscription locale;
- policy di autorizzazione per operazione;
- artifact, memoria selettiva e delivery governata.

Il Runner:

- possiede un solo attempt e una sola operazione;
- non possiede stato canonico;
- usa uno snapshot fenced;
- termina dopo il Result;
- è `restart: :temporary`;
- invia progress limitato;
- viene monitorato dall'Agent;
- ora possiede anche un watchdog Agent-side per il timeout dell'intero attempt,
  quindi non dipende soltanto dal timeout interno dell'executor.

### Work e Vigil

Sono stati aggiunti:

- `Spectre.Work`;
- `Spectre.Vigil`;
- Definition versionate;
- operazioni locali registrate con riferimenti stabili;
- import espliciti dal registry Agent tramite `uses_operation/1`;
- callback deterministici per init, next, reducer, complete, update e trigger;
- rami chiusi;
- blocker dichiarati;
- wait e trigger dichiarati;
- budget, retry, timeout e scadenza;
- artifact policy e security policy;
- significatività `:significant` / `:silent` per Vigil.

Correzione importante già applicata: il valore `{:ok, state}` restituito da
`init/2` viene ora normalizzato correttamente. Prima veniva accidentalmente
trattato come stato annidato.

Il registry globale dell'Agent non è più implicitamente visibile per intero a
ogni Work. Una Definition deve importare esplicitamente gli identificatori
globali ammessi oppure dichiarare un'operazione locale.

### Scheduler, controllo e recovery

L'Instance ora contiene:

- coda operativa separata dalla coda Flow;
- limite di Runner concorrenti;
- ownership `attempt -> Runner`;
- monitor dei Runner;
- timeout per attempt correlato a loop, attempt e fencing token;
- timer durevoli per wait/retry Vigil;
- invalidazione dei timer stale tramite generation;
- recovery degli attempt dopo restart dell'Agent;
- retry solo deciso dall'Agent;
- riconciliazione per side effect `:reconcilable`;
- attesa esplicita per side effect `:non_idempotent` con esito sconosciuto;
- rifiuto dei Result duplicati, stale, con epoch errata o fencing errato;
- backpressure dei progress prima del commit.

Sono presenti le API:

- `start_work`;
- `register_vigil`;
- `start_controller` per controller esterni, incluso Directive;
- `loop`, `loops`, `resolve_loop`;
- `pause_loop`, `update_loop`, `update_and_resume_loop`;
- `resume_loop`, `renew_loop`, `stop_loop`, `trigger_loop`.

Un Work Runner non può avviare direttamente un altro Work.

### Race pausa/ripresa

È stata corretta la semantica del punto di ripresa:

- la pausa safe conserva lo stato da cui riprendere;
- se il Result è già committed, una ripresa torna in `:evaluating` e non salta
  la funzione di completamento;
- una pausa da wait conserva il wait;
- l'interruzione immediata di un'operazione idempotente torna in coda;
- l'interruzione immediata di un side effect riconciliabile riprende in
  `:reconciling`;
- un side effect non idempotente interrotto entra in wait di riconciliazione e
  non viene ritentato automaticamente;
- resume rimuove il marker interno del confine di pausa;
- update invalida il vecchio confine e ricostruisce il percorso dal nuovo
  contesto.

### Budget

Sono implementati:

- passi;
- attempt;
- retry;
- durata;
- costo;
- risorse dichiarate;
- scadenza del loop;
- outcome terminale tipizzato con limite, consumo, stato parziale, artifact e
  ultima revisione;
- comportamento dichiarato `:terminate` oppure callback controller
  `budget_exhausted/3`.

### Validazione degli envelope

Sono stati aggiunti validatori semantici, oltre alla sola portabilità, per:

- Request;
- Wait;
- Attempt;
- Progress;
- Result;
- Execution;
- Outcome;
- Update;
- Artifact;
- Control e Command;
- Event;
- Loop e Budget.

Progress ora trasporta anche:

- `context_revision`;
- `control_generation`;
- `trigger_generation`.

Questo evita che una struct portabile ma semanticamente invalida possa arrivare
a un `case` non coperto e far crashare l'Agent.

### Flow integration

Sono stati aggiunti i verbi/handler:

- `reason`;
- `act`;
- `run` già esistente come confine deterministico;
- `work`;
- `reply`.

Gli eventi operativi committed possono rientrare nel normale router Flow
tramite `route_operation_events`, senza introdurre un secondo router. I Run
interni generati dagli eventi possono committare lo stato Flow; le continuazioni
interne preesistenti restano state-neutral.

### Vista ed eventi

Sono presenti:

- vista read-only dei loop;
- disambiguazione esplicita con lista dei candidati;
- filtro per Subject/origine/visibilità;
- eventi committed nella sezione canonica;
- subscription locale delivery-neutral;
- routing opzionale degli eventi nel Flow;
- redazione della Request successiva: l'input completo non viene esposto;
- redazione di risultati/artifact secondo `artifact_policy`;
- proiezione cognitiva limitata ai campi pubblicabili.

### Porte verso altre librerie

Il core contiene confini provider-neutral per:

- funzioni applicative registrate;
- Action/Effect attraverso il lifecycle esistente;
- planner a catalogo chiuso;
- operazioni cognitive con dominio finito, validazione, retry e fallback;
- vincoli cognitivi per loop;
- memoria post-commit selettiva e idempotente;
- controller esterni Directive sul runtime condiviso.

Non sono stati introdotti tipi Mission nel core.

### Delivery governata

Sono presenti primitive per:

- consenso;
- revoca e scadenza;
- destinazioni e canali autorizzati;
- deduplica;
- rate limit;
- quiet hours;
- digest;
- receipt persistite;
- separazione fra evento, autorizzazione e trasporto.

Il core non esegue direttamente il trasporto umano.

## Regola atom/string

- `Atom.to_string/1` è corretto per serializzare atom e non deve essere
  eliminato.
- `String.to_atom/1` non deve essere usato.
- Una stringa può diventare atom soltanto con `String.to_existing_atom/1`, in
  un percorso chiuso che gestisce il caso sconosciuto.
- I mapping chiusi delle sezioni canoniche restano intenzionali perché
  convalidano anche il dominio dei nomi, non per evitare `Atom.to_string/1`.

## Audit di chiusura completato

I punti individuati durante l'implementazione sono stati chiusi prima del gate
finale:

1. Completato l'audit statico di tutti i nuovi moduli dopo le ultime patch.
2. Verificati e rifiniti `Definition.imports` e le macro `uses_operation/1` per
   Work e Vigil.
3. Collegati `security` e `artifact_policy` in ogni percorso di
   start, update, restore e view.
4. Rafforzato il restore canonico con validazione semantica di tutte le mappe
   Work/Vigil/Directive, Control ed Event, non soltanto portabilità.
5. Chiusa la gestione degli errori ambigui del checkpoint: una write con
   esito ambiguo non deve essere ritentata automaticamente senza
   riconciliazione.
6. Validata la macchina a stati dei receipt di delivery, impedendo
   transizioni improprie, per esempio
   `denied -> delivered`.
7. Applicata la visibilità anche alla lista dei delivery receipt.
8. Rifinite validazione e idempotenza di consent, receipt, Event e Ref.
9. Verificato che ogni timer di attempt venga sempre cancellato in tutte le
   race Result/DOWN/pause/stop/restart.
10. Verificato il recovery di un comando di controllo pending in ogni stato.
11. Verificato che pausa/stop di Directive non propaghino implicitamente ai
    Work collegati.
12. Verificato il contratto di trigger per blocker Work e la necessità di
    `handle_trigger/3`.
13. Controllati i limiti delle liste canoniche: eventi, history, risultati,
    artifact e change id applicati.
14. Rifinite documentazione pubblica, migration guide ed esempi reali.
15. Portata la versione finale da `0.2.0-alpha.1` a `0.2.0` dopo la chiusura
    di implementazione e test.

## Audit sintattico e di compilazione

I moduli critici `Operation.Runtime`, `Operation.Loop`,
`Operation.Definition`, `Work`, `Vigil` e `Instance` sono stati formattati,
compilati ed esercitati. L'audit ha inoltre corretto:

- la race del monitor con Runner molto rapidi, separando start ed execute;
- la conservazione dell'idempotency key esplicita attraverso Action ed Effect;
- l'accettazione degli input map strutturati senza campo `text`;
- la normalizzazione di branch, comandi di controllo e code/tombstone;
- restore semantico, recovery dei controlli pending e fence dei checkpoint
  ambigui.

## Verifica finale

La suite completa con coverage ha prodotto:

- `1453` test passati;
- `1` test escluso intenzionalmente;
- `0` failure;
- coverage totale `90.32%`, sopra il gate del progetto.

Sono inoltre passati senza errori:

- `mix format --check-formatted`;
- `mix compile --warnings-as-errors`;
- `mix credo --all --format=oneline`;
- `mix dialyzer`;
- `mix docs`;
- il dry-run del pacchetto con `SPECTRE_HEX_BUILD=1 mix hex.build --unpack`,
  che produce correttamente `spectre 0.2.0`.

L'audit statico finale non trova chiamate a `String.to_atom/1`,
`binary_to_atom/2` o `list_to_atom/1` in `lib/` e `test/`. Le conversioni atom
verso stringa continuano invece a usare normalmente `Atom.to_string/1`; le
conversioni inverse residue usano esclusivamente `String.to_existing_atom/1`
in percorsi chiusi o con errore gestito.

I test coprono value object e Definition, Runtime puro, Work reali con funzioni
registrate, Instance end-to-end, Runner/supervisor/monitor, crash e timeout,
stale/duplicate/epoch/fencing, pausa e relative race, update/restart,
side-effect reconciliation, budget, Vigil, checkpoint CAS ambiguo, Flow event
routing, visibilità e delivery governata.

La suite `test/flow_work_vigil_system_test.exs` aggiunge un Agent di esempio
completo e verifica nello stesso sistema il verbo Flow `work/2`, un Work
paginato aggiornabile, una Vigil persistente, fallimento isolato, routing degli
eventi nel Flow e recovery congiunto da checkpoint. Durante questo passaggio è
stato corretto anche il validatore della Definition, che non accettava ancora
gli handler pubblici `reason/2`, `act/2` e `work/2` già supportati da DSL e
Runner.

Il coverage con ordine casuale ha inoltre individuato una race nel cleanup del
buffer Journal applicativo. Il test ora scollega esplicitamente il buffer
standalone prima dell'`on_exit`, evitando di lasciare il child supervisionato
arrestato per i test successivi.

## Scenario end-to-end Work verificato

Lo scenario operativo richiesto dall'utente copre:

1. Agent con funzione applicativa registrata;
2. Work che la importa esplicitamente con `uses_operation/1`, oppure la
   dichiara localmente;
3. `init/2` che crea uno stato paginato;
4. `next/2` che restituisce una Request;
5. Runner separato per ogni pagina;
6. `apply_result/4` che committa stato e cursore;
7. `complete/2` che termina deterministicamente;
8. assert che ogni tentativo abbia snapshot, attempt id, epoch e fencing nuovi;
9. assert che il Runner precedente sia terminato;
10. assert che la vista mostri risultato e outcome corretti.

## Scenario Agent completo Flow + Work + Vigil

L'Agent eseguibile aggiunto ai test copre anche:

1. avvio del Work dal normale Flow con risposta immediata;
2. conversazione ancora utilizzabile mentre un Runner Work è bloccato;
3. lettura dello stato e update-and-resume del Work da due Turn successivi;
4. aggiunta deduplicata di una pagina e completamento di tutte le operazioni;
5. registrazione della Vigil da un Flow senza un secondo runtime;
6. attesa senza Runner, pausa, rifiuto dei trigger in pausa, ripresa e trigger;
7. distinzione tra osservazione silenziosa e significativa;
8. routing di `completed`, `failed` e `observation_significant` nel Flow;
9. fallimento Work isolato, seguito da un nuovo Turn valido;
10. checkpoint e ripristino simultaneo di stato Flow, Work attivo e Vigil in
    attesa, con nuovo epoch, snapshot e fencing.

## Stato del worktree

Il worktree è volutamente dirty. Oltre ai file esistenti modificati, sono nuovi
e non tracciati:

- `SPECTRE_VNEXT_CONCEPT(2)(1).md` — documento dell'utente, non rimuovere;
- `lib/spectre/instance/canonical.ex`;
- `lib/spectre/instance/canonical/`;
- `lib/spectre/instance/checkpoint_store.ex`;
- `lib/spectre/operation/`;
- `lib/spectre/work.ex`;
- `lib/spectre/vigil.ex`;
- `docs/OPERATIONS.md` e `docs/MIGRATING_TO_0_2.md`;
- test canonici, operativi, di controllo e dei provider boundary.

Non usare reset distruttivi e non sovrascrivere `.gitignore`.

## Handoff finale

1. Leggere questo file e `SPECTRE_VNEXT_CONCEPT(2)(1).md`.
2. Controllare il branch `agent/v0.2.0-concept` e il worktree dirty.
3. Conservare `Atom.to_string/1` e mantenere vietata la creazione dinamica di
   atom da input runtime.
4. Rieseguire i gate dopo qualunque ulteriore modifica al codice.
5. Decidere separatamente se creare commit, push, tag o pubblicazione: nessuna
   di queste azioni è stata eseguita automaticamente.
