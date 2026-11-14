# Risoluzione review finale di Opus 5.5

Review completata sul codice allegato:
[parere originale](claude-opus-5.5-managed-implementation-complete-review.it.md).
I metadata registrano il modello effettivo `claude-opus-5-5` e l'hash del bundle.
Un precedente tentativo con strumenti aveva raggiunto il limite di letture senza
produrre un verdetto: non è considerato una review riuscita.

Le segnalazioni sono state verificate sul codice corrente. Il reviewer non aveva
il Bridge completo; le sue ipotesi sono state confrontate anche con quel codice.
Non si considera una segnalazione automaticamente vera perché proviene da Opus.

## Rilievi principali

| Rilievo | Verifica e intervento |
| --- | --- |
| Override `nil` rimuove conferma dinamica | Non riprodotto: il validatore di callback già rifiutava ogni `nil`. Rafforzata comunque la validazione della conferma effettiva e aggiunta regressione per policy/route protette. Nessuna conferma richiesta può essere eliminata dall'override. |
| Prova consumabile emessa prima di validare il target | Confermato. Il Runtime verifica prima pending, mount e presentazione; il Gate consente di sostituire una prova non consumata per evitare blocchi dopo busy/errori. Restano monouso e legate al riferimento. |
| Rendering ambiguo con newline, annidamento, bidi e chiavi collidenti | Confermato. Stringhe quotate e controlli escaped; strutture annidate delimitate/indentate; collisioni risolte con chiavi esatte e tipizzate, senza troncamento. |
| Scope/token nel contesto degli override | Confermato. Il contesto interno usa una proiezione minima; i callback applicativi ricevono una whitelist pubblica e template privi di capacità. Anche il renderer personalizzato è avvolto e conserva il materiale effettivo. |
| Risposta persa se la Skill muore fra lookup e inoltro | Confermato. Relay supervisionato con `GenServer.call`, scadenza limitata e cattura dell'uscita; il root resta responsivo e il chiamante riceve un errore. Token non validi ricevono risposta esplicita. |

## Ipotesi che richiedevano il Bridge

- **H1, bind della scadenza:** `confirm` non chiaro restituisce un errore;
  explain/resume producono un nuovo show. Il recovery di show ritorna sospeso.
  Il bind è comunque idempotente sulla stessa scadenza, limitato a pending di
  consenso; non può estendere il termine già fissato.
- **H2, policy sovrascrivibile:** corretto. La policy congelata vince sulle nuove
  opzioni di continuazione; input invalidi vengono rifiutati prima dell'effetto.
- **H3, recovery salta il consenso:** non confermato. Il journal `:show` conserva
  Presentation/show e ripristina un pending sospeso. Il journal `:effect` contiene
  il Candidate finale con presentation/approval e lo sottopone al kernel senza
  ricostruirlo dai binding. `resolve_command_result` legge il risultato già
  registrato. Un test disk → resume → nuovo show → singolo effetto lo verifica.
- **H4, durabilità incoerente:** introdotta una regola esplicita. Il profilo
  effimero non accetta store/checkpoint esterni; con stato durevole si usa il
  profilo disk. La demo è stata migrata su disco per autorità, journal e checkpoint.
- **H5, envelope del Candidate:** il confronto include ora consenso, disclosure,
  meter requests, finestra di osservazione e presentazione. Le Evidence visibili
  del Turn devono restare presenti. Un override non cambia il materiale approvato.

## Altre correzioni e compatibilità

- Gate: chiusure, sospensione e sostituzione della presentazione rimuovono le
  correlazioni obsolete, comprese quelle con scadenza infinita. La storia GAM
  resta intatta; il limite di capacità non viene occupato da richieste chiuse.
- Il Runtime gestito fornisce un checkpoint coerente predefinito. Un esempio
  standard senza checkpoint esplicito può spiegare/sospendere/riprendere i pending
  senza richiedere altro codice all'applicazione.
- Interpreti personalizzati: una ricevuta dell'input dell'effettivo consumer,
  legata a presentazione e digest della sorgente, permette di interpretare frasi
  personalizzate. Il testo non diventa automaticamente consenso: deve passare
  dall'interprete configurato. Le decisioni strutturate restano legate alla stance.
- Il digest consente la normalizzazione dell'input senza conservare il testo
  originale prima di eventuali filtri. La ricevuta non entra nel contesto dei tool.
- Le prove di trasporto vengono escluse dal checkpoint; dopo un riavvio serve
  una nuova presentazione/decisione. La correlazione pubblica e il digest restano.
- Il mandato del profilo di sviluppo ha una durata finita di 30 giorni, che un
  riavvio non proroga. Autorità di produzione e rinnovi seguono il percorso
  manuale con fonte esterna, senza cancellare la storia.

## Test aggiunti

Regressioni per override Candidate/Presentation e segreti, rendering ostile,
target di consenso errato seguito da un consenso valido, Skill bloccata/morta,
relay con token falsificato, scadenze finite/infinite, policy congelata, callback
OTP, durabilità incoerente, ripristino del consenso e interpreti personalizzati.

Le suite complete e il browser sono stati rieseguiti dopo le correzioni; i numeri
conclusivi e i limiti sono riportati nel
[resoconto dell'implementazione](../managed-gam-implementation.it.md) e nel documento
`demo_spectre/docs/VERIFICATION.md` del workspace.
