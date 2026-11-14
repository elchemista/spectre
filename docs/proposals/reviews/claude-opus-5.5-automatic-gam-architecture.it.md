# Review architetturale: Managed GAM (AgentServer 0.4)

**Sintesi.** L'impianto regge: c'è un solo percorso, l'autorità la dichiara la configurazione, il Broker vincola ogni capability ad Act e Attempt, e il kernel resta intatto. È coerente con GAM. I problemi veri sono quattro:
- chi figura come grantor;
- cosa succede quando l'autorizzazione scade o va revocata;
- come viene normalizzata l'identità;
- l'esclusività dello storage su disco.

Più un errore di semantica nell'Executor. Nessuno richiede di ridisegnare kernel o manifesto.

## 1. Codice attuale vs piano

| Punto | Stato nel codice |
|---|---|
| 1. Managed sempre attivo | **Non ancora.** `runtime.ex:151` usa `gam: Keyword.get(opts, :gam)`, con default `nil`. `runtime.ex:1912` risponde `:gam_not_configured`. `runtime.ex:1919` accetta ancora un bridge passato come modulo. `server/gam.ex:5` documenta ancora `{Spectre.Server.GAM, config}`. |
| 2. Bootstrap | **Fatto in gran parte.** `authority:` viene rifiutato (`bootstrap.ex:56`). La scadenza è fissata al 31/12/9999 UTC, con `expires_at` incluso nel digest. Il profilo è `:mediated`. Genesis viene verificata due volte: con `genesis_verifier` e con `verify_foundation`. |
| 3. Broker | **Fatto.** `put_new` registra il claim, poi un `compare_and_swap` lo porta a `:consumed` prima dell'effetto. Passthrough non compare più sotto `lib/spectre/server`. |
| 4. Policy | **Parziale.** `validate_policy` (`managed.ex:419`) accetta ancora una mappa `confirm/message/expires_in/bind/reject`, non le forme `:default`, `:confirm`, `{:confirm, attrs}`, `{:reject, reason}` del piano. |
| 5. `GAM.submit` | **Assente.** |

Il `@moduledoc` di `managed.ex:5-7` è rimasto indietro: parla ancora di "explicit development profile" e dice "Manual host integration remains available".

## 2. Problemi concreti e soluzioni minime

### A. Il grantor è la persona sbagliata (`bootstrap.ex:322-341`)
Oggi la stessa identità fa da grantor, holder, controller di revoca e autorità sui duty. Se c'è un `subject`, il ledger registra quindi che *l'umano* ha concesso le operazioni. Ma secondo il piano (punto 2) chi dichiara l'autorità è la configurazione dell'app. Così il ledger afferma più di quanto sia vero.

**Fix:** mettere `grantor_ref: accountable.ref`, cioè l'organization "application", e lasciare `holder_ref: actor.ref`. Per la revoca usare `controller_refs: [accountable.ref, actor.ref]`. Cambia solo la Genesis prodotta dal bootstrap, non il kernel.

### B. Scadenza: chi riavvia dopo l'expiry è bloccato fuori (`bootstrap.ex:62`)
Se `expires_at <= now` il boot fallisce. Un server riavviato dopo la scadenza quindi non parte proprio. Non può leggere i pending, chiudere i duty o servire turni di sola cognizione.

**Fix:** controllare `expires_at > now` solo quando il dominio viene creato, cioè quando `authority.profile` non esiste ancora. Ai riavvii successivi basta il controllo del digest: il kernel rifiuta già i grant su un mandato scaduto. Il dominio si apre, ma senza autorità sugli effetti. È coerente con "nessun rinnovo al restart".

Due cose minori: accettare anche `%DateTime{}` e convertirlo in millisecondi; documentare che cambiare `expires_at` equivale a cambiare configurazione.

### C. Revoca e duty non raggiungibili
Lo Scope è privato e il piano vieta un'alternativa manuale. Restano però senza alcun percorso:
- la revoca, con `revocation.mode: :cascade`;
- la decisione sui duty `ambiguous_outcome` e `disputed_evidence`, che hanno `disposition_authority_refs: [actor]`.

**Fix minimo:** due comandi del runtime, autenticati come il consumer e solo sul root: `Spectre.Server.GAM.revoke(server, reason)` e `dispose(server, duty_ref, decision)`. Passano per lo stesso meccanismo checkout → Scope. Senza questi, "duty sempre tracciati" significa duty che nessuno può chiudere.

### D. Normalizzazione dell'identità (`managed.ex:19`)
`Map.take(&1, [:subject, :conversation, :task])` crea due problemi:
- Chiavi stringa come `%{"subject" => "u1"}` vengono scartate in silenzio. L'attore diventa un `:service` anonimo, e su disco quel dominio collide con altri.
- Chiavi come `tenant` o `org` vengono perse. Due tenant con lo stesso `subject` producono lo stesso principal e lo stesso dominio.

**Fix:** normalizzare le chiavi stringa in atomi conosciuti e rifiutare quelle sconosciute con `{:error, :invalid_managed_identity}` invece di scartarle. In alternativa, includere nel digest l'intera identità canonicalizzata e tenere la whitelist solo per decidere se l'attore è umano o servizio.

### E. Le istanze anonime collidono su disco (`bootstrap.ex:123-128`)
Il dominio di default è `digest(agent, identity)`, quindi tutte le istanze anonime dello stesso agent hanno lo stesso `domain_ref`:
- **In memoria (ETS) funziona:** ogni istanza ha i suoi store, anche se nelle evidence i riferimenti si confondono.
- **Con `{:disk, path}` condiviso:** due Domain scrivono sullo stesso ledger e sullo stesso `commands.store`.

**Fix:**
1. Acquisire un lock esclusivo su `path`, ad esempio aprendo `path/LOCK` con `[:exclusive]` e rimuovendolo in `terminate`, oppure con `:global.set_lock({:managed_storage, abs_path})`. Il lock va preso **prima** di `LedgerDisk.start_link`.
2. Per le istanze in memoria, aggiungere al dominio di default un nonce casuale, così anche i riferimenti restano distinti.

### F. Cambiare configurazione blocca il deploy (`bootstrap.ex:228`)
Se si aggiunge un'operazione, il riavvio risponde `managed_authority_configuration_changed`. Rifiutare è corretto, perché evita di ampliare l'autorità in silenzio. Però l'errore oggi è opaco.

**Fix:** includere nell'errore il digest vecchio e quello nuovo, con il rimedio documentato: un nuovo `path`, archiviando il vecchio per l'audit. Non serve aggiungere migrazioni.

### G. Executor: rifiuto della capability classificato `:ambiguous` (`executor.ex:30-32`)
Se `Broker.consume` fallisce, l'effetto **non è mai partito**: CAS fallito, receipt scaduta, store non disponibile. Classificarlo `:ambiguous` apre duty fasulli. Anche nel caso di CAS con exit, l'adapter non è stato invocato.

**Fix:** `result(act, attempt, :definitive_no_effect, %{reason: :capability_refused})`.

Al contrario, se `Effect.execute` solleva un'eccezione l'effetto può essere avvenuto a metà. Lì serve un `rescue` → `:ambiguous`; oggi non c'è.

### H. Segreti rigenerati a ogni boot (`bootstrap.ex:368, 397`)
`checkout_receipt_secret` e `grant_secret` cambiano a ogni avvio:
- Gli Attempt rimasti a metà del checkout diventano ambigui. È corretto: niente esecuzione doppia.
- I claim `:claimed` restano nel journal senza garbage collection. È un problema minore.

**Da verificare con un test di restart:** un Act già confermato ma non ancora tentato deve dare un esito definito dopo il riavvio. O nuova conferma, o duty; mai un blocco silenzioso.

### I. Opzioni pubbliche più larghe del piano
Bootstrap legge anche `:domain`, `:purpose`, `:bindings`, `:consent_ttl_ms`, `:show_timeout`, `:shutdown_timeout`, `:store`, e `:class` per operazione. Un refuso come `storge:` ricade in silenzio sullo storage in memoria.

**Fix:** in `setup_managed_gam` (`runtime.ex:108`), validare le chiavi fornite dall'utente *prima* di aggiungere quelle iniettate dal runtime, e rifiutare quelle sconosciute. Va deciso esplicitamente se `:domain` e `:store` restano pubbliche. Il piano non le nomina.

### J. Lo Scope esce dal processo (`managed.ex:54, 160, 174`)
`view/1` e `:checkout` restituiscono l'intero stato, compresi `scope`, `token` e `gate`. Non è un problema di sandbox: non è un obiettivo, e va bene così. È però incoerente con "nessun accesso Scope" e rende facile un bypass accidentale.

**Fix economico:** `handle_call(:view)` esegue `GAM.view` dentro Managed, e `:bridge` viene rimosso.

## 3. Valutazione del piano punto per punto

1. **Managed sempre attivo.** Concettualmente corretto. Con `operations: %{}` conviene un test che verifichi due cose: un turno di sola cognizione non produce Act di effetto, e il costo di boot resta accettabile (Domain, Gate, ledger e journal per ogni server). I figli che usano solo il bridge condiviso tramite `pin_domain` vanno bene.
2. **Bootstrap.** Corretto, salvo A, B, D, E. Il pin del digest Genesis completo è il meccanismo giusto per "niente rinnovo e niente ampliamento".
3. **Broker.** Corretto. Il claim sta nello stesso storage del journal dei comandi, non nella stessa transazione del ledger GAM. L'assunzione dichiarata nel HostProfile ("share the configured storage boundary") lo descrive onestamente. Nella modalità in memoria il Broker si dichiara `:mediated` con claim volatili. È accettabile solo perché il dominio muore insieme ai claim; va scritto nel moduledoc.
4. **Policy.** La garanzia "non riduce confirm" viene già dal kernel tramite `presentation_required_classes` (`bootstrap.ex:288`). È un buon segnale, purché la traduzione del piano non la aggiri. Il punto a rischio è `:bind` nella policy: va verificato in `Binding` che non possa riscrivere il payload presentato. Se non serve, va tolto dall'insieme ammesso.
5. **`GAM.submit` esterno.** Tre punti:
   - **Proposer.** Il proposer resta `actor`, che con un `subject` è l'umano. Per non far figurare l'umano come autore, la provenance `external_actor` deve stare nell'Invocation e nelle Evidence, con l'identificativo del submitter. Meglio ancora: un principal `:service` "application-submitter" aggiunto a `principal_refs` nella Genesis, che è modificabile perché fa parte del bootstrap, non del kernel.
   - **`submitters: [pid]`.** È scomodo: i pid devono esistere prima del server e non sopravvivono ai riavvii. Meglio accettare anche nomi registrati, risolti a ogni chiamata con `GenServer.whereis/1`.
   - **Idempotenza.** Serve `key:` opzionale, deduplicato con `put_new` sul journal. I chiamanti esterni ritentano, e senza deduplica si creano Act doppi.

## 4. Priorità

1. G (semantica degli esiti) ed E (lock su disco): danni reali in produzione.
2. A (grantor) e B (riavvio dopo la scadenza): correttezza dell'autorità.
3. C (revoca e duty raggiungibili) e D (identità).
4. I, J, F, e il moduledoc da aggiornare.

Non ho modificato nessun file. Ho letto i cinque file indicati più `managed/broker.ex` (l'Executor chiama `Broker.consume`) e un estratto di `runtime.ex` (righe 60-159) per confermare dove viene inizializzato il GAM. `Binding`, `Gate` e il kernel non li ho letti: i punti su `:bind` e sul restart (H) sono da verificare.