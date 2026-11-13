# Risposta degli implementatori alla seconda review

**Stato: in verifica Opus mirata.** Branch `feature/agent-server-gam`.

Questa risposta collega i rilievi N1–N9 della [seconda review di Claude Opus
5.5](claude-opus-5.5-final-review.it.md) alle modifiche e alle regressioni
presenti nel repository. Non è un'approvazione di Opus. La terza verifica
mirata e la suite finale sono in corso: i loro risultati devono essere
registrati separatamente, sul medesimo snapshot. La seconda review resta
immutata, comprese le sue osservazioni sui log disponibili in quel momento.

## N1 — Pending incerta senza blocco della conversazione

In [Runtime](../../../lib/spectre/server/runtime.ex), `uncertain_governed/4` e
`suspend_uncertain_pending/2` spostano la consent a `:uncertain` e liberano il
primo piano. L'outbox resta disponibile per la riconciliazione. La coda può
procedere con nuove richieste; la stessa pending non può essere confermata o
ripresa mentre l'esito è incerto. Un deadline non uccide il worker governato:
il risultato autentico tardivo conserva la continuazione e l'input originali.

La scadenza locale non cancella una pending `:resolving` o `:uncertain`, perché
non dimostra che l'effetto non sia avvenuto. I controlli temporali del
[bridge GAM](../../../lib/spectre/server/gam.ex) restano attivi prima
dell'osservazione e dell'ammissione. Dopo un errore di recovery, la pending
torna sospesa e il relativo timer viene riarmato. **Non è stata introdotta una
nuova API universale di riconciliazione immediata:** un worker ancora vivo può
completare; un comando governato può essere recuperato al restart, oppure un
risultato già registrato può essere consegnato attraverso il percorso previsto.

Regressioni in [final_review_runtime_test](../../../test/server/final_review_runtime_test.exs):

- `crashed confirm, explain and resume leave a nonblocking uncertain continuation`:
  i tre guasti non impediscono un successivo input e conservano l'outbox.
- `a confirm deadline frees the input queue and its eventual result keeps the original input`:
  il worker resta vivo anche oltre la TTL, un altro input procede, il risultato
  tardivo risolve la continuazione originale.

Questi test isolano il comportamento del Runtime con un bridge controllato;
non sostituiscono le prove di ammissione del kernel. Il bridge reale resta
coperto, tra gli altri, da `a slow interpreter cannot execute after the consent
deadline` in [server_gam_test](../../../test/server_gam_test.exs).

## N2 — Un no-effect può ricevere una correzione tardiva

[Operations](../../../lib/spectre/server/operations.ex) ritira una continuazione
solo su `:succeeded` o `:failed`. Conserva `:definitive_no_effect`, `:ambiguous`
e l'Act senza Outcome. Non cambia il significato degli esiti nel kernel.

[no_effect_correction_test](../../../test/server/no_effect_correction_test.exs)
contiene due regressioni reali:

- `a real no-effect result retains its continuation across restart for late succeeded`;
- `a real no-effect result retains its continuation across restart for late failed`.

Entrambe attraversano Domain, executor, bridge e Server: acquisiscono il
no-effect live, verificano il rilascio del journal, riavviano il Server e
registrano la correzione con `GAM.record_late_observation`, indicando il vero
`contradicts_outcome_ref`. La delivery usa la continuazione registrata. Un altro
restart e un altro id di trasporto non ripetono il callback. Act e Attempt
restano quelli originali, con entrambi gli Outcome conservati e nessuna nuova
esecuzione dell'executor.

## N3 — Migrazione esplicita dei soli riferimenti di routing

[Checkpoint](../../../lib/spectre/server/checkpoint.ex) accetta dal migratore
anche `{:ok, projection, route_mappings}`. La mappa associa la vecchia chiave
di dispatch a una chiave attualmente dichiarata. Ogni destinazione deve
risolvere una sola regola. Il controllo `preserve_reconciliation/2` precede la
rimappatura: il migratore non può cambiare identità, input originali, comandi,
pending, inbox, operations o fatti governati. È il codice del Checkpoint a
rimappare successivamente i soli riferimenti di routing nelle posizioni note,
conservando le vecchie chiavi in `previous_route_keys`.

Regressioni in [checkpoint_route_migration_test](../../../test/server/checkpoint_route_migration_test.exs):

- `an explicit mapping moves every durable routing hint while preserving governed facts`;
- `a renamed route remains fail closed without an explicit mapping`;
- `all mapping targets must identify exactly one currently declared route`;
- `mappings do not permit changing governed facts or the original active input`.

Il primo caso comprende input attivo, coda, origine della pending, outbox,
inbox di route/interrupt e operations; verifica anche un secondo salvataggio e
caricamento. **Senza una migrazione esplicita, un fingerprint incompatibile o
una route rinominata continuano a essere rifiutati.** La mappa non migra
autorità GAM e non rende automaticamente compatibile qualunque deploy.

## N4 — Una show tardiva non sostituisce un altro primo piano

`shown_pending_status/3` e l'acquisizione di `{:pending, data}` in
[Runtime](../../../lib/spectre/server/runtime.ex) lasciano sospesa una show
recuperata, proveniente da un worker incerto o arrivata quando un'altra
pending occupa il primo piano. L'aggiornamento di `foreground` conserva il
primo piano altrui.

Regressioni in [final_review_runtime_test](../../../test/server/final_review_runtime_test.exs):

- `a background resume cannot replace an existing foreground reply wait`;
- `a show arriving after its deadline stays suspended behind a newer foreground`
  (il deadline in questo caso è quello del worker);
- `a recovered show preserves a foreground created by application init`.

## N5 — Una delivery chiude anche worker e outbox dell'attesa

`pending_delivery_worker/2` recupera la registrazione del worker dell'attesa;
`retire_delivered_worker/2` in [Runtime](../../../lib/spectre/server/runtime.ex)
cancella timer e monitor e rimuove i worker correlati prima dell'acquisizione
del risultato. L'identità del comando permette al normale percorso di inbox
di rimuovere anche l'outbox. Un worker non governato ancora vivo viene fermato;
un worker governato non viene ucciso come se ciò dimostrasse assenza di effetto.

Regressioni in [final_review_runtime_test](../../../test/server/final_review_runtime_test.exs):

- `an actor result delivered by pending id removes its infinite wait across restart`:
  niente pending, worker o outbox residui; la delivery duplicata non riapre l'attesa.
- `external cognitive completion consumes the live command exactly once`:
  il completamento esterno di un comando cognitivo ritira il worker concorrente.

## N6 — Cleanup del journal riservato ai comandi governati

`release_worker_journal/2` in [Runtime](../../../lib/spectre/server/runtime.ex)
avvia la release solo per i tipi governati. Il risultato del worker
`:release_command` passa direttamente a `worker_result`, senza acquisire
un'altra entry nella inbox o consumare un id della finestra di dedup.

Regressione: `journal release runs only for governed commands and does not
enter the durable inbox` in
[final_review_runtime_test](../../../test/server/final_review_runtime_test.exs).
Verifica l'assenza di release dopo `generate` e che il completamento della
release governata non cambi `seen_events` o la revisione del checkpoint.
Questo elimina il lavoro aggiuntivo descritto da N6; non cambia il costo delle
scritture necessarie per acquisire durevolmente i risultati normali.

## N7 — Conferma obsoleta come risultato tipizzato

Prima di acquisire i comandi del callback,
`stale_confirmation/3` in [Runtime](../../../lib/spectre/server/runtime.ex)
controlla conferma/rifiuto contro pending, primo piano e revisione dell'evento.
Il caso obsoleto richiama `handle_result` con `{:consent, :stale_input}` e il tag
della continuazione, senza convertire quel caso in un errore di callback.

`a stale classifier reply cannot approve a newer presentation` in
[runtime_recovery_boundaries_test](../../../test/server/runtime_recovery_boundaries_test.exs)
verifica la risposta applicativa alla staleness, l'assenza di dead letter e
che una nuova risposta possa poi confermare la show corrente. Il messaggio
mostrato all'utente resta una scelta dell'implementazione di `handle_result`:
non viene dichiarata una risposta universale per ogni Server applicativo.

## N8 — Recovery fallita con stato sospeso coerente

`restore_failed_pending/3` in [Runtime](../../../lib/spectre/server/runtime.ex)
non ripristina `:foreground` da un vecchio `previous_status` quando il comando
è recuperato, la pending è incerta o il primo piano appartiene ad altro.
Rimuove il vecchio stato transitorio e riarma il timer della pending ripristinata.

Regressione: `a failed governed recovery keeps a restored consent consistently
suspended` in
[final_review_runtime_test](../../../test/server/final_review_runtime_test.exs).
Verifica `status: :suspended`, `foreground: nil` e un successivo input normale.

## N9 — Il piano attende l'esito senza confonderlo con un rifiuto

[Plan.continue](../../../lib/spectre/server/plan.ex) distingue
`{:governed_unknown, details}` e un risultato con Act presente ma Outcome
assente: risponde che l'operazione è in verifica, senza avanzare il piano.
Un successo reale fa proseguire il piano. Un risultato rifiutato, con Act e
Outcome assenti, conserva il percorso di mancata conferma.

Regressioni in [planning_boundaries_test](../../../test/server/planning_boundaries_test.exs):

- `uncertain plan continuations wait for an actual outcome before advancing`;
- `a refused decision with no Act does not become an uncertain execution`.

## Limiti e verifica ancora aperta

Questa mappa attesta modifiche ispezionabili, non il verdetto della terza review
né la conclusione della suite in corso. Non dichiara risolti per estensione i
residui già documentati: adapter di memoria legacy, migrazione dell'ecosistema
e del progetto freelance, gestione dell'host delle obbligazioni incerte,
capacità/throughput dello snapshot Disk e compatibilità di ogni package.
Restano esplicite l'autenticazione dell'ingress e la semantica at-least-once
dei comandi non governati recuperati. I riferimenti di routing migrati sono
informazioni di dispatch; i permessi continuano a essere verificati dal kernel.
