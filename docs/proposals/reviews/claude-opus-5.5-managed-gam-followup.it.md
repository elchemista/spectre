# Follow-up: due principal nella stessa Scope

## 1. Correzione della mia proposta

**La proposta dei due principal nella stessa Scope era sbagliata. La ritiro.** Con il kernel attuale l'impossibilità si dimostra, non è solo un dubbio. La catena:

1. **Ogni contesto accettato in una Scope ha lo stesso principal e la stessa autenticazione dell'apertura.**
   - `scope/opening.ex:41-43`: la matrice lega `opened_by_ref` al principal autenticato, e vincola anche `authentication_ref`.
   - `governed_act/view.ex:139-145` e `domain/context.ex:65-69` applicano questo controllo a ogni comando con Scope.
   - Lo dice anche la doc di `resume_scope` (`gam.ex:307-308`): un'autenticazione diversa richiede una Scope nuova.
2. **Chi propone è il principal del contesto, e il mandato deve essere suo.**
   - `kernel.ex:423-427`: `candidate.proposer_ref == context.authenticated_principal_ref` e `candidate.scope_ref == context.scope_ref`.
   - `kernel/authority/coverage.ex:23-24`: `mandate.holder_ref == authenticated`.
3. **Il Candidate da approvare vive nella stessa Scope della Presentation** (`presentation.ex:176`).
4. **Anche la risposta di consenso vive in quella Scope, ed è firmata dal principal del contesto.**
   - `presentation/approval.ex:489-492`: `context.scope_ref == presentation.scope_ref`, e il principal deve essere tra i `recipient_refs`.
   - `:74-78`: `issuer_ref` è il principal del contesto.
   - `:465-476`: issuer, recipient e principal autenticato devono coincidere, e anche lo `scope_ref` nei binding.
5. **Le Evidence osservate hanno i binding forzati dal contesto** (`ingress.ex:71-81`, `:188-194`). Ogni scrittura passa da `Context.validate_scope` (`domain/command/input.ex:26`, `:35`, `:43`, `:57`, `:94`), e non c'è un'API pubblica che registri Evidence fuori da una Scope.

**Conclusione:** per ogni atto che richiede consenso, oggi vale sempre **proponente = approvatore = `opened_by_ref` della Scope = titolare del mandato**.

**Due altre strade sono chiuse:**
- **Child o governed Scope:** non aiutano. La child Scope può avere un altro principal (`governance.ex:439-453` controlla solo dominio, generazione e ref diversa), ma i punti 2-4 legano comunque Candidate, Presentation e risposta a una sola Scope, quindi a un solo principal.
- **Il test "approvatore ≠ proponente":** lo ritiro come legge universale, come chiedi. Va oltre: con atti soggetti a consenso il kernel attuale non potrebbe mai superarlo.

## 2. Il percorso lecito con le API attuali

Esiste un solo percorso compatibile: **l'umano è il principal della Scope, l'agente è la Mind.** Non si falsifica niente, perché l'umano si autentica davvero. Il prezzo è che anche la *proposta* risulta formalmente dell'umano, cioè fatta a suo nome.

Il giro esatto:

1. **Autenticazione.** L'host chiama `GAM.authenticate(domain, scope_ref, input)` (`gam.ex:172-194`).
   - `input` deve contenere la credenziale della sessione umana, presa dal confine affidabile (sessione `conn`), non generata dal runtime.
   - L'`Ingress.authenticate/5` dell'host restituisce `authenticated_principal_ref = human_ref` e `authentication_ref` = la sessione dell'utente.
   - Controlli del kernel: dominio, scope, ingress e generazione (`context.ex:113-129`), poi il seal.
2. **Apertura della Scope.** `GAM.open_scope(domain, context, kind: :session, opened_at: t)`. I campi di identità sono forzati dal contesto (`gam.ex:960-968`).
3. **Autorità.** Il mandato deve avere `holder_ref = human_ref` (`coverage.ex:24`). È una scelta di configurazione dell'autorità: va dentro P0-2, non richiede modifiche al kernel.
4. **Proposta.** I Candidate dell'agente passano per la Mind: `mind.ex:164` fissa `proposer_ref` al principal del contesto, e `:263`/`:303` lo controllano.
   - L'agente risulta come `mind_ref` nel Turn (`mind.ex:250-251`) e nelle Evidence derivate (`record_derivation`), e come `executor_ref` nel Candidate.
   - Il vincolo del bridge `proposer_ref == authenticated_principal_ref` (`server/gam.ex:465-466`) resta rispettato.
5. **Presentation.** `prepare_presentation` + `show_presentation` nella stessa Scope (`gam.ex:417-475`), con `recipient_refs = [human_ref]` e `approval_source_refs = [ingress_ref]`.
6. **Consenso.** `GAM.observe(scope, input)` → `Ingress.observe/4` dell'host → `Approval.response_evidence(context, presentation, show_act, :supports, t, …)`.
   - Il kernel verifica: `issuer` = umano, show riuscito prima del consenso, freschezza, recipient e binding (`approval.ex:414-485`).
7. **Ammissione** del Candidate con `presentation_ref`, come oggi.

**Attenzione: questo percorso rende la P1-1 (fuga della Scope) bloccante.** Chi possiede l'handle della Scope umana può chiamare `GAM.observe` e produrre un consenso *attribuito all'umano*, e il kernel non può distinguerlo da uno vero. Oggi l'Ingress della demo accetta l'envelope così com'è (`ingress.ex:26-36` della demo). Quindi `Ingress.observe` deve rifiutare una `:presentation_response` senza una prova di gesto umano fresca e legata ad `authentication_ref` e a `presentation_ref`. Per esempio un token monouso emesso al rendering e restituito dal click del browser. La Scope poi non deve mai arrivare a tool, planner o modello.

**Non dichiaro il piano implementabile a kernel invariato finché non passano questi test** (da scrivere, non eseguiti):
- (a) Candidate proposto tramite Mind/bridge sotto la Scope umana e ammesso con mandato `holder = human`.
- (b) La risposta tramite `observe` produce un'Approval valida con `issuer_ref = human_ref`.
- (c) Una risposta senza prova di gesto viene rifiutata dall'Ingress.
- (d) Un tool o adapter senza handle non riesce a produrre una risposta.
- (e) Va verificato se il bridge Spectre propone tramite Turn/Mind o con `GAM.propose` diretto. Nel secondo caso l'attribuzione all'agente esiste solo a livello runtime (Invocation), non nel ledger. Il codice che lo decide non l'ho letto.

## 3. Blocco dimostrato e punto da chiarire

**Bloccato** (servirebbe cambiare il kernel, quindi è fuori perimetro): *"l'agente propone come principal proprio e l'umano approva come principal distinto"*. È escluso dai punti 1-4.

**Il punto minimo da chiarire con te:** registrare la proposta con `proposer_ref = umano`, e l'agente come `mind_ref` ed `executor_ref`, soddisfa il requisito della demo?
- **Sì:** il percorso del §2 basta, con P1-1 e la prova di gesto promosse a P0.
- **No:** è un limite di modello del kernel (un principal per Scope, consenso legato alla Scope). Va dichiarato come tale, non aggirato in Spectre.

## 4. Chi garantisce cosa

- **Kernel (dimostrato dal codice letto):**
  - il contesto è sigillato e legato a dominio, generazione, ingress e Scope;
  - il proponente è il principal autenticato e titolare del mandato;
  - le Evidence osservate hanno i binding forzati dal contesto;
  - l'Approval è attribuita al principal del contesto, che deve essere tra i recipient, dopo uno show riuscito e con freschezza valida;
  - Candidate, Presentation e risposta stanno nella stessa Scope.

  Il kernel **non** garantisce che il principal sia davvero un umano, né che il click sia un gesto umano.
- **Host (Ingress e app):**
  - che `authenticated_principal_ref` corrisponda all'umano autenticato;
  - che `observe` accetti un consenso solo con una prova di gesto umano fresca;
  - la sorgente e la configurazione dell'autorità (mandato all'umano).
- **Runtime Spectre:**
  - la Scope resta privata (mai in `service_context`, tool o modello);
  - il trasporto strutturato `decide`/`presented` con `presentation_ref`;
  - l'attribuzione dell'agente se non passa dalla Mind;
  - i limiti per mount (oggi solo runtime, P1-2).

Non ho eseguito nessun test e non ho modificato file. In questa sessione mancano lo strumento di scrittura e quello per chiudere la plan mode, quindi la risposta completa è tutta qui.