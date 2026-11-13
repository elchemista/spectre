# Review incrociata — risoluzione lifecycle 0.4.0

**Esito: i tre rilievi e i casi aggiuntivi della chiusura differita sono chiusi.
Nessun blocker residuo nel perimetro riesaminato.**

Review indipendente in sola lettura sul freeze finale del 13 novembre 2026.
I sette file riesaminati corrispondono al manifest di 1.003 sorgenti e test,
digest `2227e7a1343803229397f6cd143618132cf232f90295ad6f9b3cf579ee38c3e9`.
Nessuna modifica o esecuzione Mix effettuata dal reviewer del runtime.

## Riscontri

1. **P1 — ripresa persa al restart: chiuso.** Entry e continuazioni conservano
   `execution_started: false`; il marker diventa durevolmente `true` prima
   dell'avvio governato. Il restore esclude wrapper lifecycle, comandi bloccati
   e lavoro certamente non avviato, preservando la riconciliazione prudente per
   comandi avviati e checkpoint legacy. La recovery delle continuazioni non
   avviate attraversa il controllo della deadline; il resume dei reply rimane
   locale. Riferimenti: `checkpoint.ex:109`, `runtime.ex:1915`, `runtime.ex:2196`.

2. **P2 — deadline persa dopo presentazione fallita: chiuso.** Resume/explain
   conservano la schedule precedente fino all'acquisizione di una nuova show
   riuscita. Gli errori conservano deadline, revisione, identità della schedule,
   owner e marker `fired`. Le regressioni GAM verificano fallimento del builder
   e della delivery, restart e chiusura alla deadline originale, senza
   approvazione, rifiuto o effetto inventati. Riferimenti: `runtime.ex:584`,
   `runtime.ex:650`, `pending_lifecycle.ex:211`, `gam_lifecycle_test.exs:823`.

3. **P2 — doppio worker lifecycle durante il recupero: chiuso.** Il controllo
   del worker attivo precede l'avvio del driver lifecycle. Le receipt sono
   correlate alla fase mediante `lifecycle_event_id`; una risposta della fase
   precedente non genera un nuovo errore applicativo. La regressione ritarda
   il worker della sospensione e verifica un solo avvio. Riferimenti:
   `runtime.ex:1678`, `runtime.ex:2196`, `lifecycle_resume_recovery_test.exs:441`.

4. **Chiusura differita dopo wake durante un'operazione: chiusa, inclusa la race
   del report `:ignored`.** Dopo un errore definitivo, il runtime riprende la
   schedule scaduta senza riarmi a zero millisecondi, anche con timer
   applicativo. L'identità deterministica evita duplicazioni durante il
   replay; gli esiti recovered/uncertain conservano l'obbligazione governata.

   Se il report precedente è ancora in corso, soltanto l'auto-close riceve il
   marker interno `lifecycle_independent`. Tale chiusura sopravvive al report
   `:ignored` e alla quarantena della callback; i normali comandi del flusso
   continuano a essere abortiti. Il checkpoint precede il drenaggio dei
   comandi rilasciati, rendendo recuperabile anche un crash in quel confine.
   Riferimenti: `runtime.ex:668`, `runtime.ex:794`, `runtime.ex:807`,
   `runtime.ex:1789`, `runtime.ex:2159`.

## Prove esaminate

Le regressioni CAS/crash intercettano il checkpoint dopo il commit e prima
della risposta al runtime. Coprono richiesta resume, continuazioni rilasciate
resume/explain/reply, deadline attraversata durante lo stop e replay inbox.
La matrice checkpoint copre marker `true`, `false`, assente legacy, wrapper,
comandi bloccati e reply locali.

Le ultime regressioni ritardano il report `:ignored` fino all'errore del builder
per entrambi gli owner del timer. Il caso con callback quarantinata verifica
la chiusura nello stesso processo, senza nuovo input o restart. La regressione
`:confirmation_unclear` verifica due richieste di chiusura, un report ignorato,
uno applicato e nessuna seconda conferma.

Il log finale degli autori `/tmp/spectre-resume-recovery-final.log` riporta
**23 passati**. Il reviewer ne ha esaminato contenuto e corrispondenza con le
regressioni. È un gruppo mirato e non rappresenta la suite completa.

## Controllo separato delle invarianti GAM

Un secondo subagente ha riesaminato le patch del runtime rispetto al bridge e
al kernel: nessun nuovo blocker GAM. Il marker interno sblocca esclusivamente
il child, che attraversa ancora lifecycle, receipt e controlli di Scope,
revisione e schedule. La quarantena conserva il rilascio durevole senza
riscrivere Evidence, Act o Outcome. I comandi governati incerti mantengono
l'obbligazione; la chiusura dell'intenzione non annulla Act o Duty.

## Limiti

L'approvazione riguarda le correzioni lifecycle riesaminate. Suite completa,
copertura, analisi statiche e matrice OTP finali sono documentate separatamente
dal coordinatore nella [verifica del branch](../verification-0.4.it.md).
Restano escluse le migrazioni legacy e delle applicazioni esterne già dichiarate.
La delivery e le callback restano almeno una volta.
