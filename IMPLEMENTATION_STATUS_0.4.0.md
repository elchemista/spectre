# Spectre 0.4.0 — implementation checkpoint

Checkpoint del 2026-09-03 sul branch
`feature/v0.4.0-governed-act-runtime`.

Questo file descrive lo stato del codice al commit che lo contiene. Le fonti
normative restano, nell'ordine:

1. `GOVERNED_ACT_MODEL.md`;
2. `piano_merged.md`;
3. `piano_0.4.0.md` e `piano_claude_0.4.0.md` come materiale di supporto.

## Direzione confermata

- La linea 0.4.0 non mantiene compatibilita con il runtime 0.3.x.
- Il codice legacy non deve restare raggiungibile; l'importatore 0.3 e stato
  rimosso.
- Prima si completa tutto il codice funzionale del core e delle feature.
- Doctor, test, refactoring generale, Credo, Dialyzer, CI e documentazione
  pubblica restano deliberatamente fuori dal lavoro corrente.
- Le ottimizzazioni vengono decise dopo avere chiuso la correttezza funzionale.

## Stato sintetico

- Copertura stimata del **codice funzionale previsto dal piano**: circa 85%.
- Prontezza complessiva per un rilascio 0.4.0: circa 55%; mancano ancora la
  chiusura funzionale, le prove costituzionali e tutti i gate di qualita.
- Ultima verifica eseguita prima del checkpoint: `mix compile` riuscito e
  `git diff --check` pulito.
- Non sono stati eseguiti test, Credo, Dialyzer, Doctor o lavori di
  documentazione in questa fase.

Le percentuali sono stime di avanzamento, non una dichiarazione di conformita:
la conformita potra essere affermata soltanto dopo avere chiuso il codice e
superato i gate del piano.

## Codice implementato

### Confine, record e forma canonica

- Nuovo runtime 0.4 basato su Domain, Scope, Candidate, Decision, Act, Grant,
  Attempt, Outcome, Evidence, Mandate, Duty, Surface, HostProfile e Genesis.
- Record portabili, versionati, canonicalizzabili e con digest stabile.
- Decodifica canonica stretta al confine durevole tramite
  `Spectre.Portable.restore_canonical/4`; dopo il decode il core lavora con
  struct validate.
- `SubmissionContext` autenticato, sigillato, legato a Domain, Scope, ingress e
  generazione host; identita dichiarate dal Candidate non sostituiscono il
  contesto trusted.
- Identificatori operativi UUIDv7 tramite libreria dedicata.

### Ledger e recovery

- Un ledger append-only ordinato per Domain, catena di digest, revisioni e CAS.
- Group commit atomico delle Admission e rivalutazione sullo snapshot
  provvisorio del batch.
- Store Disk, ETS, Mnesia, PostgreSQL e Mock.
- L'adapter PostgreSQL usa il Repo fornito dall'applicazione e non introduce
  una dipendenza Ecto propria; il task Mix genera la migration richiesta.
- Classificazione degli append ambigui, rilettura per identity e recovery
  deterministico.
- Riparazione idempotente dei Duty derivabili durante recovery e prima di
  rilasciare nuove capacita.
- Corretto il backend Disk per preservare la semantica del contratto durevole.

### Kernel e authority

- Pipeline pura Authority -> Recognition -> Row -> Meter -> Decision -> Act.
- Tassonomia distinta `admitted`, `refused`, `undecidable` e `unknown_class`.
- Evidence esclusa dalla risoluzione dell'autorita.
- Vista di authority autenticata e ristretta allo Scope corrente.
- Delega sottrattiva, restriction, revocation forward-only, modalita cascade e
  retained-controller, devolution del solo saldo libero.
- Semantica comune di ancestry/revoca estratta in
  `Spectre.Mandate.Ancestry`.
- Validazione delle conseguenze risolta dalla Surface con identificatori di
  validator durevoli; il kernel non contiene una tabella cablata di classi di
  business.
- La route executor viene richiesta soltanto per un Act esterno ammesso: un
  Candidate rifiutato, indecidibile o di classe sconosciuta conserva quindi la
  propria Decision durevole anche se propone una route inesistente.

### Capacita ed esecuzione

- Grant effimero, MAC-bound, exact-bound, con expiry, generation e nonce.
- Consumo monouso del Grant e append durevole dell'Attempt prima della
  liberazione di credenziali o handle.
- Confine executor/broker condiviso in `Spectre.Execution.Boundary`.
- Runner che separa kernel e mondo, con Evidence executor-attested e Outcome.
- Nessun retry automatico dopo un possibile Attempt.
- Outcome definitivi, `definitive_no_effect`, ambigui, tardivi e correzioni
  causali.
- Meter con reserve, settle, release, suspend, recontain, resolve, delegate e
  devolve.
- Il sequencer non resta piu vivo ma inutilizzabile dopo un halt fatale: termina
  e lascia al supervisore il recovery.

### Duty e riconciliazione

- Cause stabili e derivazione pura/idempotente dei Duty.
- Duty per Outcome ambiguo, Attempt oltre finestra, Evidence disputata,
  promessa di Work/Vigil scaduta e riduzione di verificabilita.
- Containment conservativo e saldo sospeso finche non esiste una disposizione.
- Disposizioni `condition_met`, `ratify`, `repudiate`, `compensate`, `assign` e
  `accept_loss`, sempre registrate tramite un nuovo Act.
- Controllo dell'autorita indipendente per le disposizioni discrezionali.
- Reconciler temporizzato per finestre di osservazione, dispatch non piu
  valido e promesse di Scope.

### Scope, mente, consenso e dati

- Scope durevoli e generation-bound; Scope figli, Work e Vigil con promessa
  esplicita e scadenza finita.
- Apertura governata di Work/Vigil tramite `scope.open`.
- `Mind.Turn` capability-free, input come Evidence e unione conservativa delle
  label del contesto.
- Router, modello, planner e skill rappresentabili come proponenti senza
  authority propria; ogni Candidate prodotto torna al kernel.
- Disclosure governata e binding delle label della risposta al Turn.
- Presentation immutabile, consenso exact-bound e validazione di destinatario,
  dati, costo, scopo, rischio, reversibilita e alternative.
- Declassificazione governata dai proprietari delle label.
- Payload store content-addressed, erasure executor-mediated, tombstone
  anti-resurrezione e causalita del ledger preservata.

### Self-governance e API

- Issue/delegate/restrict/revoke/devolve dei Mandate attraversano il kernel.
- Revisioni di Surface, HostProfile e Definition attraversano il kernel e
  diventano efficaci solo dopo il relativo Act.
- Disposizione dei Duty, declassificazione, erasure e apertura Work/Vigil sono
  anch'esse conseguenze governate.
- Genesis verificata e bootstrap fail-closed; vincoli strutturali sui Mandate
  di emergenza.
- API pubblica orientata a propose/query: non espone Grant, append arbitrario o
  creazione libera di Evidence osservata.
- Fallback dichiarativi `silence`, Candidate template e governed handoff, senza
  eredita di authority/Evidence e senza ricorsione.
- Export canonico del ledger e comando `mix spectre.audit` gia presenti come
  base; il refactoring e la validazione completa dell'auditor sono rinviati.

## Codice funzionale ancora da chiudere

Alla ripresa bisogna continuare da questo ordine, senza passare ai gate di
qualita:

1. completare l'audit riga-per-riga delle transizioni del Reconciler e del
   recovery, in particolare la materializzazione obbligatoria dei Duty prima
   di ogni nuova capacita, le collisioni di identity e gli append ambigui;
2. verificare end-to-end la semantica di Work/Vigil: promessa, scadenza,
   `open_promise`, Evidence tardiva e disposizione, senza chiusure implicite;
3. verificare tutte le mutazioni di self-governance rispetto allo stato
   provvisorio del batch: Surface, HostProfile, Definition, Mandate,
   retained-controller ed emergenza;
4. chiudere l'audit funzionale di fallback/handoff, garantendo isolamento dal
   Candidate rifiutato e arresto dopo un solo fallback;
5. chiudere l'audit funzionale di erasure: richiesta, Attempt, Outcome,
   tombstone, riferimenti payload vivi, riduzione di verificabilita e divieto
   di resurrezione;
6. riesaminare Scope/delega nello stesso flusso: l'apertura non deve mai
   moltiplicare authority o Meter e l'eventuale delega deve restare una
   transazione governata separata e sottrattiva;
7. confrontare infine ogni requisito funzionale di `piano_merged.md` con una
   implementazione raggiungibile e aggiungere soltanto i pezzi realmente
   mancanti. Audio, VoIP e streaming restano classi/contratti dichiarati dal
   programmatore: il core deve imporre Act, row, finestra e Meter, non inventare
   pipeline di dominio specifiche.

Questioni da decidere durante questo audit, soltanto se il piano primario le
rende necessarie:

- se serva una piccola API esplicita per lo scambio cross-Domain di Candidate
  ed Evidence oppure se i confini pubblici correnti siano gia sufficienti;
- se Definition debba avere un riferimento congelato aggiuntivo sui record o
  se Surface revision + contratti canonici coprano gia il requisito 0.4;
- se `condition_met` debba avere un helper pubblico dedicato oltre al normale
  Candidate di disposizione.

Questi punti non autorizzano un redesign preventivo: vanno risolti con la forma
piu piccola che preserva gli invarianti GAM.

## Lavoro deliberatamente rinviato

Solo dopo la chiusura di tutto il codice funzionale:

- test unitari, integration, property, fault injection e suite costituzionali;
- test differenziale projection/auditor e conformance di tutti gli store;
- refactoring generale, inclusa la riduzione della duplicazione fra Projection
  e Audit e l'eliminazione dei getter atom/string interni rimasti;
- benchmark definitivo e tuning delle prestazioni;
- Doctor e check statico Zona M -> Zona X;
- Credo, Dialyzer e CI;
- documentazione pubblica, guide, `GOVERNED_SURFACE.md`, fixture e release gate.

## Punto esatto di ripresa

L'ultima modifica funzionale e in `Spectre.Domain.Sequencer`: la validazione
della route e stata spostata dopo la Decision pura e viene applicata soltanto
all'Act esterno ammesso. Il prossimo passo e riprendere da
`schedule_reconciliation/1`, `preflight_duty_repair/2` e
`recover_with_repair/2`, seguendo poi nell'ordine la lista “Codice funzionale
ancora da chiudere”.
