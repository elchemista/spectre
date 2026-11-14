# Review indipendente: GAM gestito in Spectre 0.4

## 1. Verdetto

Approvo la direzione generale del piano. Prima di implementare servono però due correzioni P0 e alcune P1. Altrimenti la "configurazione compatta" finirebbe per fissare nel framework due errori che oggi stanno solo nella demo.

**Cosa approvo, verificato sul codice:**
- **Non spostare `DemoSpectre.Host` così com'è dentro la libreria.** Ne esiste già una seconda copia in `spectre/integration/stack_tools/support/host.ex:3-155` (Mind, Ingress, Host, Executor). È la prova che quella meccanica è generica.
- **Il kernel può restare invariato.** Il Runner esegue l'executor nel processo chiamante e non ritenta mai (`gam/attempt/runner.ex:16-21`, `:254-274`). La deduplica per `identity_key` esiste già (`gam/domain/admission/planner.ex:62-74`).
- **Serve un contratto di esecuzione esplicito, non la ricerca di `execute` per convenzione.** Oggi le firme dei pacchetti sono tutte diverse:
  - Kinetic: `actions.ex:27` → `execute/3` con `module:`
  - Beam: `beam/server_tool.ex:77` → `execute(args, ctx)`
  - Pulse: `pulse/server_tool.ex:75` → `execute(attrs, ctx)`
  - Mnemonic: `mnemonic/server_tool.ex:31` → `execute(op, req, ctx)`
  - Lens: `lens/server_tool.ex:52` → `execute(:act, args, ctx)`
- **I dettagli materiali vanno resi dal framework.** Nella demo il testo di Beam ignora gli argomenti (`host.ex:393-395`), quindi la presentazione può dire cose diverse dai dati congelati, e il kernel non può accorgersene.
- **Domain store, journal e checkpoint vanno tenuti separati.** Nessun retry di effetti non riconciliati.

**Cosa correggere prima di implementare:** P0-1 e P0-2 qui sotto. Poi riordinare la sequenza: modello di principal e autorità prima del contratto dei pacchetti.

## 2. Problemi verificati

### P0

**P0-1. Chi propone e chi approva sono lo stesso principal.**
- La sessione del browser è autenticata come il principal *agent*: `Events.register(... principal: proposer.ref)` (`host.ex:124-130`, principal definiti a `:22-25`).
- Il bridge impone `candidate.proposer_ref == authenticated_principal_ref` (`server/gam.ex:465-466`).
- Il bridge osserva la risposta di consenso con la **stessa** Scope (`server/gam.ex:99-104`).
- `recipient_refs` della Presentation è il proposer (`host.ex:309`, `:333`).
- Il kernel registra come approvatore il principal autenticato (`gam/presentation/approval.ex:74-79`, `:464-470`).

Risultato: il registro dice che l'agente ha proposto, ha visto la presentazione e ha approvato. Anche il testo dell'utente viene emesso come agente (`ingress.ex:44-49`). Il manifesto chiede di distinguere chi propone da chi autorizza. Il piano non ne parla; un runtime gestito costruito così renderebbe questa confusione il comportamento di default per ogni app.

**P0-2. L'autorità nasce dentro la sessione e le modifiche alla configurazione vengono ignorate.**
- Genesis e Mandate dipendono da `now` (`host.ex:21`, `:98-99`, `:117`).
- L'attestazione è un Allowlist costruito dall'app stessa (`host.ex:118`, `:159`).
- Il bootstrap avviene solo se il ledger non esiste (`gam/domain/startup.ex:35-46`). Al recovery si verifica solo l'attestazione registrata (`bootstrap.ex:74-76`); `bootstrap_opts` non viene più usato (`configuration.ex:241-246`).

Con storage durevole, abilitare un'operazione nuova non cambia il mandato registrato, e il riavvio ignora la nuova configurazione senza errori. Il runtime gestito deve:
- confrontare l'autorità configurata con il genesis/mandato registrato;
- se divergono, fermarsi con un errore esplicito e indicare una modifica governata dell'autorità (`gam/governed_act/authority_change.ex` esiste già).

Senza `authority: :development` dichiarato, non deve costruire da solo un genesis.

### P1

1. **Fuga della Scope.**
   - `demo_host:` (che contiene Scope, pid del Domain e mandato) viene passato come opzione del Server (`session.ex:58`).
   - Arriva così in `service_context.options` (`runtime.ex:1589-1610`), quindi agli adapter dei tool (`tool.ex:83-88`) e al planner/modello (`service_context.ex:4-7`).
   - Chi possiede la Scope può chiamare `GAM.observe` con un envelope `:presentation_response`, che l'Ingress accetta così com'è (`ingress.ex:26-36`).
   - Nel runtime gestito la Scope deve restare privata al runtime.

2. **I limiti per mount non sono applicati dal kernel.**
   - C'è un solo mandato con tutte le classi (`host.ex:93`).
   - Il limite per Skill vive solo in `server/gam.ex:560-565` e `server/skills.ex:94-113`; nel ledger c'è solo l'attribuzione (`server/gam/invocation.ex:1-8`).
   - Va dichiarato con onestà ("garanzia del runtime Spectre"), oppure spostato nel kernel con principal/mandati per mount.

3. **L'executor classifica tutto come `:ambiguous`** (`executor.ex:38-40`): apre Duty anche per errori di validazione già definitivi. Beam invece distingue già l'ambiguità (`beam/server_tool.ex:97-100`). Il contratto deve restituire `failed | definitive_no_effect | ambiguous` e usare `act.ref` come chiave di idempotenza.

4. **Collisione di nomi e vocabolario già esistente.**
   - `Spectre.Stack.Contract.V2` esiste già (Authority Envelope + Execution Closure, `stack/contract/v2.ex:1-9`, `:66-89`). "Descriptor v2" creerebbe confusione.
   - Il 0.3 ha già `Operation.Spec` con `executor`, `reconcile` e `side_effect: :none|:idempotent|:reconcilable|:non_idempotent` (`operation/spec.ex:13-30`). Va riusato questo vocabolario invece di inventarne un altro.

5. **Il consenso passa per testo sintetico.**
   - Il click invia la stringa "confermo" (`chat_live.ex:171`), riletta due volte da `Pending.handle` (`pending.ex:7-12`) e da `Host.interpret` (`host.ex:368-374`).
   - Il click non contiene `presentation_ref` (heex `:213-231`). La card dei pulsanti non mostra il contenuto, che sta in un messaggio separato della chat.
   - Il `handle_pending` di default si limita a spiegare (`server.ex:67`): senza codice dell'app non si può confermare nulla.

6. **Contract ref costante.** `"demo:executor-contract:v1"` è fisso (`executor.ex:12`) e `confirm` non riesegue `Catalog.validate` (`server/gam.ex:87-115`). Il contract ref va derivato dal digest del descriptor e dello `schema_hash`; così il routing dell'Act blocca da solo l'esecuzione sotto un catalogo cambiato.

7. **Duty e ciclo di vita.**
   - Il ledger è ETS volatile (`host.ex:132`); dichiararlo nell'HostProfile (`:66-70`) è onesto.
   - L'autorità di disposizione è un "operator" che non si autentica mai (`host.ex:74-80`), e nel Server non c'è nessuna API per le Duty (`GAM.dispose_duty` esiste in `gam.ex:779`).
   - Il Domain vive quanto una LiveView (`session.ex:22-42`). Allo stop, il Domain viene fermato mentre i worker governati restano vivi (`runtime.ex:361-363` contro `session.ex:148-151`).
   - Il checkpoint è su disco, mentre il ledger GAM è volatile (`session.ex:43-44`, `:61-62`).

### P2

- Il testo della presentazione arriva al feed attività prima dello show Act (`host.ex:347-351`, `chat_live.ex:246-250`).
- Binding e classe Pulse sono nel mandato ma inutilizzati: Pulse è installato senza `bind:` (`ai.ex:34`, `host.ex:9`, `:191`). Il mandato è più largo del necessario.
- **L'esempio API del piano non funziona così com'è** (piano righe 146-152):
  - gli argomenti Kinetic hanno chiavi stringa (`host.ex:211`), quindi `args.to` fallisce;
  - l'operazione Kinetic è `{{:skill, :outreach}, :kinetic, :send_email}` (`agent.ex:23`), non `:send_email`.
- `Catalog.validate` salta tutti i controlli se i metadati sono vuoti (`catalog.ex:39`).
- La UI chiede `GAM.view` completo ogni 700 ms (`session.ex:97`, `chat_live.ex:214-218`). Anche le ricerche nel bridge e nel lifecycle sono lineari (`server/gam.ex:317-358`, `lifecycle.ex:141-142`).
- Un timeout dello snapshot fa apparire la sessione come "terminata" anche se è viva (`chat_live.ex:219-221`).
- I file `<id>.ledger` non vengono mai cancellati.
- Lens dichiara "All browser actions are governed" (`lens/server_tool.ex:5`), ma `open`/`look` sono cognitive (`:38-40`). Inoltre il piano esclude Lens dal contratto, mentre Lens ha un `:act` governato (`:31`, `:52`).

## 3. Architettura minima raccomandata

Si aggiunge **una** nuova forma pubblica dell'opzione `gam:` già esistente, un callback opzionale del Server e due funzioni. Tutto il resto resta interno: supervisor, Ingress, Executor, Mind no-op, bootstrap, builder di Candidate e Presentation.

```elixir
# PROPOSTA — non esiste
Spectre.Server.start_link(
  agent: MyApp.Agent,
  consumer: self(),                       # il consumer esistente fa da trasporto
  identity: %{subject: user.id},
  gam: [
    domain: {"tenant-1", user.id},        # identità stabile: il Domain sopravvive alla sessione
    human: %{ref: user.id, authentication: conn_session_id},  # dal confine affidabile
    authority: :development | MyApp.Authority,   # nessun genesis auto-attestato in produzione
    operations: [send_email: [confirm: true], save_report: [confirm: true]],
    storage: {:disk, path} | :ephemeral   # :ephemeral solo con :development
  ]
)

# PROPOSTA — callback opzionale, invocato nel Runtime quando il comando viene acquisito.
# Il risultato viene salvato nell'outbox e mai rivalutato al replay.
def handle_action(%{operation: {_, :kinetic, :send_email}, args: %{"to" => to}}, ctx),
  do: if(to == ctx.assigns.email, do: :confirm, else: {:reject, :recipient_not_observed})

def handle_action(%{operation: :forget_memory, args: %{selector: id}}, ctx) do
  case ctx.assigns[:memory_choices][id] do
    nil -> {:reject, :search_first}
    text -> {:confirm, bind: %{text: text}}   # congela contesto, non allarga il mandato
  end
end

# PROPOSTE — trasporto
Spectre.Server.presented(server, presentation_ref)                     # ack di rendering
Spectre.Server.decide(server, skill, presentation_ref, :confirm | :reject)  # decisione strutturata
```

**Principi:**
- **Due principal per sessione:**
  - l'agente, con credenziale interna al runtime, usato per proposte, invocation e lifecycle;
  - l'umano, autenticato dall'app, usato solo da `decide/4`.

  `recipient_refs` della Presentation contiene l'umano. **Da verificare** con un test del kernel che un secondo principal possa autenticarsi nella stessa Scope (`transition/scope.ex` non è conclusivo).
- Lo show Act è eseguito da un executor interno che notifica il consumer con `{:present, %{ref, skill, pending_id, revision, material, message}}` e attende `presented/2`. È lo stesso schema di oggi (`executor.ex:44-54`), senza passare dalla Session.
- Le esistenti API di testo restano (`confirm_pending` da `handle_pending`) come scelta conversazionale opzionale; il default diventa la decisione strutturata.

**Contratto del pacchetto (PROPOSTA)** — descriptor dei tool `contract: 2`, da chiamare esplicitamente "tool descriptor v2" per non confonderlo con Stack Contract V2. Un'operazione governata dichiara:
- `side_effect` (stesso vocabolario di `Operation.Spec`);
- i campi `material` da presentare;
- `partition: [:subject]`;
- un adapter `execute(op, args, %{act_ref, installation, stack_runtime, identity})` che restituisce `{:ok, receipt} | {:error, :failed | :definitive_no_effect | :ambiguous, reason}`;
- opzionale `reconcile/3`;
- opzionale `describe/2` per il testo di default.

Il contract ref è il digest di descriptor e `schema_hash`. Kinetic dichiara una famiglia di operazioni `action` eseguita tramite `config.actions`. L'identità dell'operazione resta `Catalog.operation/2`, così origine, mount e replay non cambiano. **Non** serve unificare i cataloghi in uno solo.

## 4. Dove va il codice

| Oggi | Spectre (interno) | Pacchetto | App |
|---|---|---|---|
| `host.ex:19-183` bootstrap | ✔ (refs stabili, classi da `operations:`) | — | identità, scopo, fonte dell'autorità |
| `host.ex:187-207` bindings | derivati da descriptor e config | `bind:` | — |
| `:211-215` controllo destinatario | — | — | `handle_action` |
| `:220-223` beam/pulse | ✔ | — | — |
| `:227-235`, `:263-270` partizione | congelamento generico | `partition:` | — |
| `:239-242` messaggio "hello" | — | schema/guard dell'azione | `MailActions` |
| `:246-259` forget selector | — | — | `handle_action` con `bind:` |
| `:273-364` Candidate/Presentation | ✔ | `describe/2` | `message` opzionale |
| `:368-374` interpret | decisione strutturata | — | testo opzionale in `handle_pending` |
| `ingress.ex`, `mind.ex` | ✔ | — | — |
| `executor.ex:14-54` | ✔ | — | — |
| `executor.ex:56-85` | dispatch per classe | `execute/3` | effetti in `MailActions` |
| `session.ex:27-65`, `:111-162` | supervisione, `presented` | — | — |
| `session.ex:80-109`, `pending.ex`, UI | — | — | ✔ (Session sottile, solo UI) |

## 5. Piano ordinato e test mancanti

1. **Test kernel**: secondo principal nella stessa Scope; risposta di approvazione da un principal diverso dal proposer.
2. **Modello autorità e principal**: drift tra config e genesis registrato → errore esplicito; `:development` dichiarato nell'HostProfile.
3. **Runtime gestito**: Domain con identità stabile, Scope privata, regola di coerenza della durabilità, ordine di shutdown (stop intake → drain dei worker governati con limite → stop Domain).
4. **Tool descriptor v2**: contract ref dal digest, classificazione degli esiti, compatibilità v1 (il percorso manuale invariato; v1 rifiutato in modalità gestita).
5. **Builder standard + `handle_action`** acquisito nel Runtime e salvato nell'outbox.
6. **Trasporto**: `presented`/`decide` con `presentation_ref`; il default di `handle_pending` resta conversazionale.
7. **Adapter dei pacchetti**: Kinetic, Mnemonic, Beam, Pulse e Lens `:act`; test di compilazione indipendente dei nove pacchetti.
8. **Migrazione della demo e dell'host di integrazione.**
9. Aggiornamento della documentazione.
10. Suite completa e browser.

**Test da aggiungere:**
- crash prima e dopo il commit dell'Act;
- crash dopo l'invio senza ricevuta → Duty aperta che sopravvive al riavvio;
- Domain fermato durante l'executor;
- riavvio con operazione aggiunta o rimossa → errore di drift;
- contract ref cambiato con un consenso aperto → nessuna esecuzione;
- tool adapter che tenta `GAM.observe` → nessuna Scope disponibile;
- approvazione con lo stesso principal del proposer → rifiutata;
- `decide` con un `presentation_ref` di un'altra Skill o di una revisione vecchia;
- doppio `decide` concorrente;
- ack arrivato dopo il timeout dello show;
- Duty disposta da un'autorità autorizzata e da una non autorizzata;
- errore di validazione → `definitive_no_effect`, senza Duty;
- a ogni passo: cache semantica, fallback, IntentDataset e training invariati.

## 6. Limiti della review

**Letto per intero:**
- il piano e il manifesto (dal file in `/tmp`, non riscaricato);
- `GAM.md`, `STACK_TOOLS.md`;
- nella demo: `host.ex`, `host/*.ex`, `session.ex`, `pending.ex`, `agent.ex`, `ai.ex`, `mail_actions.ex`, `agent_server.ex`, i due `*_server.ex` delle Skill, `chat_live.ex`, `VERIFICATION.md`;
- nel core: `server/gam.ex`, `invocation.ex`, `catalog.ex`, `planning.ex`, `plan.ex`, `skills.ex`, `tool.ex`, `service_context.ex`, `context.ex`, `stack/tools.ex`, `installable.ex`, `contract/v2.ex`;
- nel kernel: `attempt/runner.ex`, `executor.ex`, `runner/recovery.ex`, `presentation/approval.ex`;
- i ServerTool di Kinetic, Beam e Mnemonic.

**Letto in parte:**
- `runtime.ex`, righe 1-200, 290-430, 520-1000, 1300-1320, 1480-1940, 2240-2360, 2880-2938;
- `server.ex`, `ingress.ex`, `startup.ex`, `reconciliation.ex`, `operation/registry.ex`, Pulse e Lens;
- lo spec browser (righe 1-140 e 280-370), app.js e l'heex tramite grep;
- `SKILLS.md`, `AGENT_SERVER.md`, `operation/spec.ex`, `configuration.ex`, `bootstrap.ex`, `lifecycle.ex`, `host_profile.ex` solo tramite grep.

**Non verificato:**
- `tool_compiler.ex`, `checkpoint.ex`, Sequencer, Mandate, Surface, `Presentation` completo, Reconciler, AuthorityChange, `ActionConfig`, Prism, Directive, Ledger, Lab;
- i test ExUnit della demo e il comportamento delle chiavi atom nel ledger Disk dopo un riavvio.

**Nessun test, compilazione o comando è stato eseguito.** I numeri di baseline del piano non sono miei. Non ho potuto scrivere il file di piano né chiudere la plan mode perché in questa sessione non ho strumenti di scrittura: la review è tutta qui sopra.