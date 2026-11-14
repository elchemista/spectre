# Risoluzione della review: GAM gestito in Spectre 0.4

Data: 2026-11-14. Solo pianificazione e analisi statica; nessuna modifica runtime,
nessun test eseguito per questa proposta, nessun commit/push/merge.

## Materiale e provenienza

- [Piano aggiornato](../managed-gam-0.4.it.md).
- [Bozza effettivamente revisionata](managed-gam-0.4-reviewed-draft.it.md).
- [Brief con contesto e percorsi del codice](claude-opus-5.5-managed-gam-brief.it.md).
- [Review integrale](claude-opus-5.5-managed-gam-review.it.md).
- Metadata: `claude-opus-5.5-managed-gam.metadata.json` contiene modello restituito
  `claude-opus-5-5`, tempi, esito e SHA-256 della bozza revisionata.
- [Domanda di follow-up sull'identità](claude-opus-5.5-managed-gam-followup-brief.it.md).
- [Risposta del follow-up](claude-opus-5.5-managed-gam-followup.it.md), anch'essa
  restituita da `claude-opus-5-5` (metadata salvati accanto al documento).

Il reviewer approva la direzione con riserve, non l'implementazione (che non
esiste). L'assistente ha verificato direttamente i punti principali prima di
aggiornare il piano. Non tutti i rilievi secondari sono stati riprodotti.

## Decisioni recepite

| Rilievo | Decisione nel piano |
| --- | --- |
| La demo attribuisce input/consenso al proposer agente | Fase 0 obbligatoria: correggere l'attribuzione e dimostrare il percorso supportato dal kernel prima della migrazione. |
| Bootstrap diverso da recovery | Configurazione iniziale distinta dal record recuperato; divergenze esplicite e modifiche governate, mai nuovo genesis implicito. |
| Scope e mandato nelle opzioni `demo_host` | Stato normativo privato al runtime; nessuna propagazione ai contesti tool/modello. |
| Troppe API pubbliche possibili | Estendere `gam:` esistente; callback opzionale di business e funzioni di trasporto; moduli generici interni. |
| Firme executor diverse | Behaviour esplicito; tool descriptor v2 distinto da `Stack.Contract.V2`; adattatori pacchetto. |
| Esiti tutti trattati come ambigui | Esiti espliciti con evidenza coerente; correlazione/idempotenza e reconcile secondo capacità reali. |
| Informazioni per consenso incomplete | Materiale derivato dalla conseguenza congelata, accanto ai controlli della UI. |
| Click convertito in stringa | API di decisione strutturata con riferimento, identità e mount verificati. |
| Contract ref costante | Digest del contratto/catalogo e verifica anche su consenso/recovery. |
| Domain legato alla LiveView | Ownership e shutdown definiti; record durevole indipendente dal trasporto, profilo effimero esplicito. |
| Vocabolario già presente in 0.3 | Riutilizzare i concetti di `Operation.Spec`, senza riattivare Instance o il vecchio runtime. |
| Lens ha anche `:act` governato | Includerlo esplicitamente nella migrazione dei pacchetti. |
| Esempio con args.to incompatibile | Esempio corretto con chiave stringa e identità completa dell'operazione; vista locale delle Skill da specificare. |
| Callback al replay | Decisione applicativa congelata nell'outbox; kernel continua a verificare validità e revoche correnti. |

## Precisazioni rispetto alla review

1. **Due principal nella stessa Scope non sono una soluzione già verificata.**
   `Scope.Opening` include principal, submission context e autenticazione nella
   matrice vincolante. `GovernedAct.View.scope_context/2` verifica la stessa
   matrice; `Domain.Context.validate_scope/3` la applica. Nel follow-up Opus
   riconosce l'errore e ritira la proposta: il protocollo corrente non supporta
   in quel modo proponente e approvatore come principal distinti.
2. **Non introduciamo una proibizione universale approvatore = proponente.**
   Il problema concreto è la falsa attribuzione del consenso umano nella demo.
   Il test corretto riguarda operazioni che richiedono approvazione umana e
   l'impossibilità di sostituirla con una decisione dell'agente. I ruoli e le
   condizioni dipendono dalla superficie dichiarata.
3. **Il kernel non deve confrontare il genesis nuovo come se fosse una nuova
   verità.** Il recovery che usa il record è corretto; è il livello gestito che
   deve rilevare e rendere esplicita una configurazione divergente. Non è un bug
   kernel da correggere con sovrascrittura della storia.
4. **I limiti delle Skill oggi sono una garanzia del runtime.** Non dichiarare
   che siano già mandati kernel per mount. Conservare i controlli e l'attribuzione;
   non ampliare il progetto introducendo delegazioni nuove senza necessità.
5. **Un actor pid o presentation_ref non autentica da solo un umano.** Le API
   `presented`/`decide` proposte devono mantenere un trasporto affidabile e una
   correlazione privata; non basta spostare `GenServer.cast` nella libreria.
6. **Una chiave act.ref non garantisce exactly-once.** Idempotenza e classificazione
   della ricevuta dipendono dall'adapter/servizio; l'incertezza va conservata.

## Ordine di lavoro risultante

1. Prova delle identità/consenso e configurazione dell'autorità.
2. Contratti effetti e compatibilità, runtime gestito e durabilità.
3. Builder e policy applicative, executor e trasporto consenso.
4. Pacchetti e migrazione demo/integration host.
5. Documentazione, regressioni e browser avversariale.

L'obiettivo resta eliminare `DemoSpectre.Host*`, senza sostituirli con un altro
modulo GAM obbligatorio dell'app. Eventuali blocchi del kernel devono essere
dichiarati prima dell'implementazione, non aggirati dentro il runtime.

## Esito del follow-up e chiarimento dell'utente

Durante la review l'utente ha chiesto di sfruttare direttamente AgentServer e i
return dei callback per registrare automaticamente azioni, mandato applicabile e
risultati. Il piano ora mette questa scelta all'inizio: estendere il GenServer
`Server.Runtime` e l'outbox già presenti. Il Domain resta il record condiviso;
nessun secondo motore o nuovo Host pubblico. Gli helper accodano i comandi e
l'ammissione precede l'effetto, non è un log costruito dopo una chiamata diretta.

Il follow-up suggerisce un percorso a kernel invariato sotto la Scope dell'umano:
proposte formalmente a suo nome, mandato corrispondente e consenso della stessa
identità verificata. È un'opzione semantica da dichiarare e testare, non equivalente
a un agente principal autonomo approvato da un altro principal. Il piano mantiene
questa decisione visibile e non estende il kernel senza discuterne.

Ulteriore precisazione: il follow-up teme che la provenienza Agent/Skill possa
restare fuori dal ledger; `Server.GAM.Invocation.record` usa già `GAM.observe`
per registrarla. Occorre verificarne il contenuto e la correlazione nel nuovo
profilo, non assumere che oggi non esista. Non si deve neppure impostare l'agente
come executor se l'effetto è realmente eseguito da un adapter distinto.

Protezione della Scope e verifica dell'evento di consenso diventano requisiti
P0. Né il kernel né un semplice token attestano da soli che una persona abbia
cliccato: il confine di autenticazione del trasporto resta necessario e deve
essere implementato dal framework con integrazione all'identità dell'app.
