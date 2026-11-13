# Spectre 0.4.0 — correzioni della review finale

**Tre rilievi risolti, comprese le race aggiuntive della chiusura differita.**

Branch locale: `feature/agent-server-gam`, creato da `origin/main` (`1059bd8`, 0.3.4).
Versione: **0.4.0**. Implementazione nel branch locale; nessun merge o pubblicazione.
Data: 13 novembre 2026.

Il core Agent/Server e il nuovo lifecycle con timer sono implementati. La review
incrociata finale aveva trovato i tre problemi sotto. Dopo la sospensione
richiesta, l'autore ha chiesto di completarli. Le correzioni e le regressioni
sono implementate; la [review indipendente conclusiva](reviews/cross-review-lifecycle-resolution.it.md)
non ha trovato blocker residui nel perimetro riesaminato. I risultati aggiornati
dei gate sono nella [verifica del branch](verification-0.4.it.md).
Le descrizioni dei problemi si riferiscono al codice precedente ai fix.

## 1. P1 — Ripresa persa al restart: risolto

Punti: `Checkpoint.recovering_pending_ids/1`, `Checkpoint.restore_state/2`,
`Runtime.release_lifecycle_following/2` e `Runtime.recover_outbox_entry/2`.

- Il ripristino considera governati anche un wrapper lifecycle `resume/explain`
  ancora in fase `requested` e una continuazione `blocked_by` non ancora avviata.
  Marca quindi la pending come `uncertain`. Quando il lifecycle riprende,
  interpreta quella pending come un'operazione governata già in corso,
  ignora la ripresa ed elimina la continuazione. Nessun resume GAM era partito.
- Esiste una seconda finestra: la continuazione è stata salvata sbloccata, ma il
  processo muore prima di eseguirla. Il restart tenta `recover_governed`, trova
  assente un journal che non era ancora stato creato e lascia la richiesta
  incerta invece di avviarla. Il resume di un'attesa `reply`, che è locale,
  può essere erroneamente trattato come un'operazione GAM.

Correzione implementata:

- Distinguere durevolmente una continuazione **certamente non avviata** da un
  comando governato effettivamente lanciato. Su disco esiste
  `execution_started: false` è acquisito con le nuove entry; `true` viene
  acquisito prima dell'avvio governato. `lifecycle_authorized` resta distinto.
- Escludere wrapper lifecycle, comandi bloccati e continuazioni certamente non
  avviate dalla selezione che imposta `uncertain`.
- Eseguire le continuazioni non avviate attraverso il normale percorso e i suoi
  controlli di deadline; riconciliare quelle avviate senza rieseguire alla cieca.
- Conservare il comportamento prudente per checkpoint legacy privi di una prova
  affidabile dello stato di esecuzione.

Regressioni aggiunte:

1. Pending sospesa, resume, blocco dell'ingress `requested`, kill e restart:
   la ripresa deve completarsi senza venire scartata.
2. Kill dopo il salvataggio della continuazione sbloccata e prima del suo avvio:
   il resume deve partire una volta, senza falsa incertezza permanente.
3. Stesso confine per `explain` e per il resume locale di un'attesa `reply`.
4. Deadline applicativa trascorsa durante lo stop: chiusura auditata senza
   avviare una nuova show. Matrice restore per marker `true`, `false`, assente
   legacy, wrapper lifecycle, comandi bloccati e reply locali.

## 2. P2 — Deadline persa dopo presentazione fallita: risolto

Punti: `PendingLifecycle.apply_operation/3` nel ramo `resume`, esecuzione
`resume_pending`/`explain_pending` in `Runtime`, e `Runtime.restore_failed_pending/3`.

Una consent ha una chiusura programmata. Si chiede resume/explain prima della
scadenza, ma il builder o la delivery della nuova presentazione fallisce.
`close_schedule` viene eliminata prima del successo; il recupero ripristina lo
status, ma non la deadline. L'intenzione può quindi restare aperta senza la
chiusura già programmata, anche dopo un restart.

Correzione implementata:

- Conservare la schedule fino all'acquisizione di una nuova show riuscita,
  oppure ripristinarla e riarmarla sul fallimento.
- Controllare **entrambi** i punti che la eliminano: driver lifecycle e Runtime.
- Lasciare a `cancel_pending_close` la cancellazione esplicita della deadline.
- Mantenere il marker `fired` quando necessario: preservare la deadline non deve
  introdurre un ciclo di riarmo a zero millisecondi.

Regressioni aggiunte: resume/explain fallisce, passa la deadline originale,
la pending viene chiusa per policy con la relativa traccia GAM; niente seconda
conferma oltre scadenza e niente falso rifiuto dell'utente.

Il controllo ha individuato e corretto anche il caso in cui il wakeup era già
stato ignorato durante un'operazione in corso. Dopo un errore definitivo la
chiusura scaduta viene accodata durevolmente, con identità deterministica,
senza resettare `fired` o creare un nuovo timer. Vale per entrambi gli owner.
Se il report precedente è ancora in corso o la sua callback viene quarantinata,
il child interno di chiusura sopravvive e viene eseguito nello stesso processo;
i normali comandi del flusso dipendenti restano abortiti. Gli esiti di effetti
incerti continuano a preservare l'obbligazione governata.

## 3. P2 — Doppio worker lifecycle durante il recupero: risolto

Punti: `Runtime.recover/1` e ordine dei rami in `Runtime.recover_outbox_entry/2`.

Il recupero di una completion nell'inbox può acquisire la callback e avviare il
lifecycle successivo. Il successivo giro sull'outbox controlla la presenza di
`lifecycle` **prima** di `active_command?`, avviando un secondo worker per lo
stesso comando. Una receipt `requested` che arriva dopo il passaggio a `report`
può essere interpretata come errore di registrazione e causare callback spurie.
La registrazione GAM è idempotente, ma questo non elimina il problema nel driver.

Correzione implementata:

- Controllare il worker già attivo prima di avviare il ramo lifecycle.
- Verificare la correlazione della receipt con la fase attesa; una receipt già
  acquisita non deve diventare un nuovo errore applicativo.

Regressione aggiunta: kill durante la completion di schedule; il restart
recupera la callback, avvia suspend e non crea un secondo worker `requested`.
Ritardare una receipt per verificare l'assenza di errori e callback duplicate.

## Baseline prima delle correzioni

Questi erano i risultati prima delle nuove regressioni. Sono conservati come
baseline; il risultato conclusivo è nella [verifica aggiornata](verification-0.4.it.md).

| Controllo | Risultato |
| --- | --- |
| Suite completa Elixir 1.20.4 / OTP 29.1.1 | **4.308 passati**: 4.282 test, 25 proprietà, 1 doctest; 1 escluso |
| Copertura | **95,08%**, soglia originaria 95% invariata |
| Suite completa Elixir 1.19.5 / OTP 28.5 | **4.308 passati, zero failure**, 1 escluso |
| Compilazione | `--warnings-as-errors` passata |
| Dialyzer completo | **0 errori, 0 esclusioni**, 61,43 secondi |
| Credo completo | Nessun rilievo con le regole CI |
| Formattazione | Passata dopo rimozione di due righe vuote finali; AST identico allo snapshot recensito |
| Documentazione | `mix docs --warnings-as-errors` passata |
| Pacchetto | Costruito localmente con `mix hex.build --unpack`; nessuna pubblicazione |
| Integrazione Server/GAM/native OTP | 192 casi passati prima dei nuovi rilievi |

Il profilo embedding reale era stato verificato separatamente con successo;
i budget prestazionali opzionali non sono stati rieseguiti in questo giro.
Non è dimostrata una riduzione di codice o un miglioramento delle prestazioni
dell'applicazione freelance.

## Review conclusiva

Tre review Opus precedenti sono conservate con correzioni e regressioni.
L'ultima chiamata Opus sul lifecycle è stata interrotta dal limite di utilizzo
(`You've hit your 5-hour limit`): **nessun verdetto tecnico finale prodotto**.
L'autore ha scelto esplicitamente la review incrociata dei subagenti. I due
reviewer indipendenti hanno trovato i problemi sopra; il primo ha negato
l'approvazione per il P1. Gli altri controlli di Scope, Evidence host,
id/digest/payload, separazione dal consenso e equivalenza dei validatori GAM
non hanno prodotto ulteriori blocker nel perimetro esaminato.

I rilievi sono ora chiusi dalla [review incrociata sul freeze finale](reviews/cross-review-lifecycle-resolution.it.md),
con un controllo separato delle invarianti GAM. Sono state aggiunte regressioni
reali GAM e prove CAS/crash sui confini di acquisizione, comprese deadline e
ricevute ritardate. Le callback restano almeno una volta; nessuna pubblicazione
o merge è stato eseguito.

## Migrazioni ancora separate dai bug

Resta il lavoro già dichiarato nello [stato di implementazione](implementation-status.it.md):

- sostituzione generale di Instance/Session e migrazione al nuovo owner delle
  procedure Skill, Work/Vigil/Directive e reflection/Morph;
- adattamento e verifica dei package esterni, inclusi i vincoli di versione e
  le vecchie API di authoring; cleaner incrementale Kinetic non già fornito;
- compatibilità completa degli adapter memoria che dipendono dal vecchio stato;
- migrazione dell'applicazione freelance, dei suoi flussi e dei servizi reali;
- misure del nuovo runtime sul pilota.

I percorsi legacy sono conservati per compatibilità. La loro presenza e la
suite verde non attestano la migrazione completa di quelle integrazioni.

Guida del nuovo meccanismo: [Lifecycle delle attese](../PENDING_LIFECYCLE.md).
Proposta: [Agent/Server e GAM](agent-server-gam-from-0.3.it.md).
