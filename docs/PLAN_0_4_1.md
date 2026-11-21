# Spectre 0.4.1: Unified Tool API + Conversational Directive

**Stato:** SPECIFICA PROPOSTA - 21 novembre 2026. Gli esempi marcati «API 0.4.1» descrivono contratti da implementare, non codice già rilasciato. Questo piano sostituisce il precedente piano su Component e Morph.

## 1. Architettura e risultato richiesto

Conservare **Stack -> Agent -> Server**, le Skill supervisionate indipendentemente sotto `Spectre.Server.Skills` e **un GAM Domain condiviso**. Realizzare due sole estensioni:

1. **Tool API unificata:** ogni libreria `spectre_*` o di terzi può dichiarare un tool una volta nello Stack, descriverlo al modello quando autorizzato e invocarlo dal Server, da una Skill o da Directive tramite la medesima API e la medesima pipeline. I tool possono essere cognitivi o governati.
2. **Directive conversazionale:** un normale Skill Server supporta domande libere, ragionamento, chiamate tool, correzioni, passaggi di argomento e missioni in background. Non classificare ogni turno di una conversazione che è già di proprietà di quella Skill.

| Layer | Possiede | Non deve duplicare |
| --- | --- | --- |
| Stack | Installable, tool ed effect descriptor, risorse | Authority e stato della conversazione |
| Agent | Routing deterministico, Skill montate e fallback | Loop LLM o worker delle Skill |
| Root/Skill Server | Context, command/outbox/inbox, worker, pending, checkpoint | Scheduler di Directive o registry parallelo |
| Tool API | Validazione/riferimenti chiusi, discovery, chiamata generica | Executor autonomo per JSON/AL |
| Directive | Stato conversazionale, reducer, scelte e richieste al Core | GenServer o GAM secondari |
| GAM | Atti, obblighi, autorizzazione delle conseguenze | Concedere privilegi solo perché un tool è installato |

**Non implementare in 0.4.1:** `spectre_morph`, evoluzione dinamica delle Skill, nuovi moduli BEAM generati da LLM, `Spectre.Server.Component`, nuova DSL `mission()` nel core, secondo scheduler/store/journal, nuovo registry di tool, riscrittura GAM, rimozione della compatibilità Instance/Run. Le API standalone dei satellite devono restare funzionanti.

### 1.1 Codice verificato da riutilizzare

- `lib/spectre/stack/installable.ex`: `tools/1`, `effects/1`, `child_specs/2`.
- `lib/spectre/stack/tools.ex`: descriptor V1, aggregazione `table!/1`, digest e collisioni.
- `lib/spectre/server/tool_compiler.ex`: genera helper privati nel Server; ottimo per callback statici, non per un nome tool scelto a runtime.
- `lib/spectre/server/tool.ex`: `request`, `normalize`, `prepare/invoke/project`, conversione `:governed -> :propose`. Questa resta la **sola** pipeline.
- `lib/spectre/server/runtime.ex`: command, outbox, worker, result, pending e checkpoint. Oggi `handle_flow/3` e `handle_pending/3` devono restituire un Context; `:cont` fallisce la validazione dei callback. `PreRoute` ha già un `:cont` locale ma non un protocollo comune.
- `lib/spectre/server/skills.ex`: ogni Skill con `server:` possiede un normale Server.Runtime, ma eredita il GAM del root.
- `lib/spectre/server/router.ex`: `ctx.routing.reason` distingue `:no_match`, `:ambiguous` ed errori di classificazione.
- `spectre_directive/lib/spectre_directive/loop/engine.ex`: reducer puro `new/next/respond/inform` con richieste `:reason/:invoke/:question/:policy/:confirmation`. L'attuale helper di Stack lascia ancora all'applicazione il boilerplate della continuazione.

Il problema preciso: **esistono tool installabili, ma manca un catalogo callable dinamicamente da un driver**; **esistono Skill Server paralleli, ma manca una forma esplicita di cessione del turno per conversazione aperta**; **esiste il reducer Directive, ma non il driver completo model -> tool -> model sul Server.**

## 2. Il flusso completo target

~~~text
Chat/HTTP/WhatsApp -> Root AgentServer (identity, ingress, consent/interrupt)
    |
    +-- targeted pending / interrupt validato -> attesa proprietaria, non router
    |
    +-- conversation owner attivo? -> Skill Server Directive
    |                                    | ctx     -> lavoro/risposta, niente router
    |                                    | :cont   -> yield una volta al root
    |
    +-- root handle_input -> :cont -> PreRoute -> router dichiarativo
                                        | route chiara -> root handle_flow o Skill deterministica
                                        | no_match -> root handle_flow(:unmatched)
                                        | ambiguous/error -> chiarimento/diagnostica
                                                            |
                                              delegate(:assistant) solo su no_match
                                                            |
                                               normale Skill Server Directive
                                                            |
                                    reason (generate) -> decision JSON / Kinetic AL
                                                            |
                                             Spectre.Server.call_tool
                                                            |
                                  Command :tool -> Tool.normalize -> outbox
                                         /                            \
                                invoke cognitivo                propose -> GAM
                                         \                            /
                                           observed correlated result
                                                            |
                                          Directive reducer/driver -> respond
~~~

Non usare un regex universale che cattura ogni messaggio e non inventare una route `/assistant`. La fallback è la normale `handle_flow(:unmatched,...)` del root, **soltanto** se il motivo è davvero `:no_match`. La Skill può diventare proprietaria dei turni successivi, ma deve poterli cedere con `:cont`.

## 3. Contratto di creazione tool (una sola registrazione)

### 3.1 Stack.Installable resta l'unico punto di ingresso

Un package definisce `tools/1` con tool e operations. Per eventuali effetti definisce `effects/1`, per clienti OTP `child_specs/2`. Formalizzare e documentare un behaviour pubblico per gli adapter **già esistenti**, senza ricrearli:

~~~elixir
# API PROPOSTA 0.4.1 - comportamento, non nuovo registry
defmodule Spectre.Tool.Adapter do
  @callback prepare(operation :: atom(), payload :: list(), trusted :: map()) ::
    {:ok, term()} | {:error, term()}

  @callback invoke(operation :: atom(), prepared :: term(), runtime :: map()) :: term()

  @callback project(operation :: atom(), raw_result :: term()) ::
    {:ok, term()} | {:error, term()}

  @optional_callbacks invoke: 3
end

# Per le operazioni governate continuare a usare il comportamento già esistente:
# Spectre.Server.GAM.EffectAdapter.execute_effect/3
~~~

`prepare/3` è puro e controlla l'input, `invoke/3` gira nel worker e fa soltanto la parte cognitiva, `project/2` costruisce dati portabili. Un package solo governato non deve implementare `invoke/3`. Gli adapter V1 che espongono già queste funzioni **continuano a funzionare senza aggiungere @behaviour**.

### 3.2 Descriptor V2, V1 compatibile senza modifiche

Congelare un `contract: 2` opzionale con i seguenti campi, mantenendo `contract: 1` esattamente com'è:

~~~elixir
def tools(_config) do
  %{
    invoice: %{
      contract: 2,
      adapter: Demo.InvoiceAdapter,
      description: "Consulta e invia fatture",
      default: nil,
      operations: %{
        list: %{
          path: :cognitive, retry: :safe, max_bytes: 65_536,
          description: "Elenca le fatture",
          input_schema: %{
            "type" => "object",
            "properties" => %{"status" => %{"type" => "string"}},
            "required" => ["status"],
            "additionalProperties" => false
          }
        },
        send: %{
          path: :governed, operation: :send_invoice, max_bytes: 65_536,
          description: "Invia una fattura esistente",
          input_schema: %{
            "type" => "object",
            "properties" => %{"invoice_id" => %{"type" => "string"}},
            "required" => ["invoice_id"],
            "additionalProperties" => false
          }
        }
      }
    }
  }
end
~~~

Contratto V2:
- `description` e `input_schema` obbligatori per ogni operazione pubblicabile al modello; `output_schema` opzionale.
- Validare un **subset chiuso JSON Schema**: `type` (`object/string/integer/number/boolean/array`), `properties`, `required`, `items`, `enum`, `additionalProperties`. Una keyword non supportata è un **errore**, non un controllo ignorato.
- Schemi, identity e descrittori concorrono ai digest; la stessa definizione non cambia significato dopo il checkpoint. Validare schema **prima** di `prepare/3`, poi far validare il dominio all'adapter.
- Il formato nome esposto al modello è `"tool.operation"`, ricostruito dalla tabella chiusa installata; usare lookup string->ref precompilato, **mai** `String.to_atom` da input.
- `tools/1` continua a dichiarare capacità, `effects/1` a registrare gli executor GAM. Installazione o visibilità non danno nessuna authority.
- Un tool V1 può essere invocato programmaticamente ma, senza schema V2 o adapter descrittivo esplicito, non è automaticamente proposto al modello.

### 3.3 Unica API di discovery e invocation nel Server

~~~elixir
# API PROPOSTA 0.4.1, non disponibile oggi
{:ok, specs} = Spectre.Server.available_tools(ctx, audience: :model)
# [%{name: "invoice.list", description: "...", input_schema: %{...}}, ...]

ctx = Spectre.Server.call_tool(
  ctx, "invoice.list", %{"status" => "overdue"},
  on_result: :listed
)
# ritorna Context con un Command :tool in coda, NON il risultato sincrono

# Equivalente per codice applicativo con riferimento chiuso:
ctx = Spectre.Server.call_tool(
  ctx, {:invoice, :list}, %{"status" => "overdue"},
  on_result: :listed
)
~~~

`available_tools` legge il binding **dello stesso Server root/Skill** da un riferimento read-only del Context, con snapshot/digest verificati dal Runtime; non presume che tutte le Skill abbiano gli helper del root. Il modello vede solo le operations nella allowlist host/Skill. Default per `audience: :model`: **nessun tool esposto** fino a configurazione esplicita. Le callback host possono usare quelli dichiarati e permessi nel loro scope.

`call_tool` risolve il riferimento chiuso, valida schema e policy, e usa **esattamente** `Server.Tool.normalize`, `Command :tool`, l'outbox e `GAM` già esistenti. L'helper privato compilato `invoice(ctx, {:list, ...})` deve restare disponibile e passare nello **stesso** adapter. Anche un modello che inventa un nome installato ma non esposto viene rifiutato durante l'acquisizione, non solo nascosto dalla discovery.

### 3.4 Correlazione: niente tag dinamici che rompono gli strict contracts

L'attuale `continuation_contracts/0` valida tag dichiarati. Non associare due richieste diverse soltanto perché hanno entrambe `on_result: :tool`. Proporre un'opzione **host-only** `correlation:` per `call_tool`, `generate` e `await_reply`, con envelope ott-in:

~~~elixir
ctx = Spectre.Server.call_tool(ctx, "invoice.list", %{"status" => "overdue"},
  on_result: :directive_tool,
  correlation: %{"conversation" => "chat-7", "mission" => "m-1", "request" => "r-9"})

# callback con tag statico e correlazione verificata dal runtime:
def handle_result(:directive_tool, {:correlated, ref, result}, ctx),
  do: Spectre.Directive.Driver.tool_result(ctx, ref, result)
~~~

Il wrapper `{:correlated, ref, result}` viene usato **soltanto** quando `correlation:` è presente: nessuna modifica delle risposte delle API V1. Il Runtime lega ref a command id, installazione, session generation e owner; scarta risultati doppi, di sessione vecchia o di request superata. `correlation:` non è selezionabile dal LLM: proviene dal driver host. Lo strict schema deve poter validare il wrapper con un tag statico.

### 3.5 Kinetic AL e JSON, la stessa esecuzione

~~~text
JSON tool call -> decoder/schema ---\
                                     -> ToolRef + args + correlation
Kinetic AL (output consolidato) -----/              |
                                                   v
                                      Spectre.Server.call_tool
                                                   |
                                             Command :tool
                                           /                \
                                 cognitive invoke        propose -> GAM
                                           \                /
                                           observed Outcome
                                                   |
                                         handle_result / Directive
~~~

Kinetic è un **interprete di istruzioni**, non un secondo executor. Per le candidate Kinetic che corrispondono a tool, aggiungere un mapping verso i riferimenti dello stesso catalogo; gli effetti Kinetic già registrati con `effects/1` restano governati come prima. Non eseguire `execute_effect` da Directive e non trasformare token AL parziali in atti. Per la prima release è sufficiente **una chiamata tool per decisione LLM**; evolvere a più call solo con correlazione e budget testati.


## 4. Proposta concreta di :cont nei handler e ownership della conversazione

### 4.1 Callback e forme di ritorno (API 0.4.1 PROPOSTA)

Oggi il Server non accetta `:cont` da `handle_flow`/`handle_pending`: bisogna modificare `lib/spectre/server.ex` e l'acquisizione in `lib/spectre/server/runtime.ex` **prima** di costruire il driver.

~~~elixir
# Estensione dei contratti del behaviour Spectre.Server.
@callback handle_input(Spectre.Input.t(), Spectre.Server.Context.t()) ::
  Spectre.Server.Context.t() | :cont | {:cont, Spectre.Server.Context.t()}

@callback handle_flow(term(), Spectre.Input.t(), Spectre.Server.Context.t()) ::
  Spectre.Server.Context.t() | :cont | {:cont, Spectre.Server.Context.t()}

@callback handle_pending(map(), Spectre.Input.t(), Spectre.Server.Context.t()) ::
  Spectre.Server.Context.t() | :cont | {:cont, Spectre.Server.Context.t()}

# handle_result/3 continua a dover restituire Context: un risultato di
# worker non è un input utente che possa essere reinstradato.
~~~

`handle_input/2` è opzionale, default `:cont`. Serve per consentire al Server o alla Skill proprietaria di **offrire** l'input a un handler prima del routing normale. Le callback OTP native `handle_call/cast/info` non vengono toccate.

| Ritorno | Semantica |
| --- | --- |
| `ctx` | Handler ha consumato il turno; i comandi/stato vengono acquisiti normalmente |
| `:cont` | Handler declina il turno; stato immutato; **una sola** transizione al prossimo stadio |
| `{:cont, ctx}` | Come `:cont`, ma con sole modifiche di assigns/stato locale; `ctx.commands` deve essere vuoto e `dispatch_token` identico |
| Errore/crash | Quarantine e diagnostica esistenti, **mai** convertire in `:cont` |
| `handle_result -> :cont` | Errore di contratto, non un nuovo input |

### 4.2 Per ogni callback: quale è lo step successivo?

- **`handle_input/2`:** `:cont` -> continuare verso PreRoute/Router. Non ricominciare preparazione e ingress.
- **`handle_pending/3` su reply-pending:** `:cont` -> sospendere **l'attesa originaria** con id/revision, poi inviare l'input al Router una sola volta. La vecchia attesa resta riprendibile.
- **`handle_pending/3` su consent-pending:** nessun `:cont` può approvare o rifiutare il consenso. La policy attuale decide se e come sospendere. Decisioni `:confirm/:reject` restano vincolate a Presentation + pending id/revision e provenienza.
- **`handle_flow(route,...)` già scelta:** `:cont` -> rifiutare la route per **questo input** e chiamare il fallback `handle_flow(:unmatched,...)` una volta, **senza re-invocare il classificatore**. Il fallback riceve `ctx.routing.reason: {:declined_route, key}` (PROPOSTA), distinto da `:no_match`, così l'host decide esplicitamente se delegare a Directive. Un `:cont` dal fallback `:unmatched` è errore terminale, non un ciclo.
- **Skill con proprietà di conversazione:** `:cont` -> cede l'input originale al **root** tramite una receipt correlata. La Skill perde il focus automatico (non la memoria né le missioni), e il root esegue PreRoute/Router una sola volta.
- **`{:cont, ctx}`:** nessuna emissione di comandi, nessuna risoluzione pending nascosta, nessun effetto; l'aggiornamento state-only viene validato e checkpointato **prima** di cedere l'input.

### 4.3 Precedenza reale da preservare

Non reimpostare arbitrariamente l'ordine del runtime attuale. Proposta di ordine esplicito, con due casi:

**Input indirizzato** (es. decisione UI per un consent): preparazione e ingress -> verifica esatta di Skill + pending.id + pending.revision -> consegna esclusiva alla relativa attesa o errore `:stale_pending`. Nessun fallback cognitivo su una decisione esplicitamente riferita a un pending superato.

**Input ordinario**: preparazione e ingress -> global interrupts già previsti -> foreground pending con policy -> eventuale conversation owner -> `handle_input/2` -> PreRoute esistente -> router -> `handle_flow`/`:unmatched`. Quando un consent è foreground, non permettere al modello di intercettarlo come risposta ordinaria senza applicare la policy.

A ogni passo, il Runtime mantiene un marker dell'evento e del suo stadio; dopo `:cont` non torna indietro a uno stadio già visitato. Un errore del classifier non è `:no_match`, un turno reindirizzato non perde la provenienza autenticata.

### 4.4 Handoff root <-> Skill (non specifico di Directive)

I child Skill Server esistono già. Il **nuovo** pezzo è un handoff generico, con receipt di yield, per i messaggi di una conversazione che la Skill già possiede.

~~~elixir
# PROTOCOLLO INTERNO - pseudocodice, non tool del modello
# Root ha preparato e registrato l'evento E, con subject + conversation_key.
offer_to_owner(E, owner: {:skill, :assistant}, generation: 8, revision: 4)

# Skill elabora handle_input(E) nel suo Runtime e risponde SOLO dopo acquisizione:
{:accepted, event_id, owner_ref}
# oppure:
{:yielded, event_id, owner_ref, :cont}

# Root valida event_id, owner_ref, session_generation, revision:
# accepted -> fine dispatch (child continua con worker/risposta);
# yielded  -> route_once(E) sul root, senza re-inviare ingress o preparazione.
~~~

La receipt non deve bloccare il GenServer root aspettando un LLM: è un ack della **presa in carico**, non l'esito della missione. Il root mantiene un registro breve dei messaggi in handoff e marca il yield in modo idempotente; due yield o un yield tardivo non rilanciano due volte il Router. Se la Skill crasha nel mezzo, recovery dal checkpoint/receipt oppure failure esplicita, mai un replay cieco di effetti.

**Design gate obbligatorio:** provare prima `await_reply`/`await_input`, `handle_pending` e `route_current_input` della 0.4. Se un pending basta per un dialogo libero anche quando il modello non ha una domanda specifica, riusarlo. Se non basta, estendere il runtime con un solo **conversation lease** generico `{conversation_key, skill_mount, session_generation, revision}` e receipt di handoff. Il `conversation_key` è autenticato e assegnato dall'host/transport, non dal testo LLM. Niente seconda mappa di focus non sincronizzata e nessuna conoscenza di "Mission" nel core.

### 4.5 Scenario di test per :cont

~~~text
T1 "Analizza le fatture" -> root no_match -> delegate assistant -> owner :assistant
T2 "La F-10 era annullata" -> owner assistant -> inform(mission) -> NO router
T3 "Intanto, stato fatture" -> assistant :cont -> root router UNA volta
                             -> flow deterministico :invoices/:status
                             -> analisi m-1 prosegue nel child, senza prendere focus
T4 "Riprendi analisi" -> root risolve mission m-1 dello stesso subject -> delega/riattiva
T5 "Sì" a proposta di piano -> confirmation Directive, NON consenso GAM
T6 "Sì" a Presentation GAM -> richiede ref+revision corretti; no contaminazione
~~~

Per T4 il testo "riprendi" da solo non dà autorità di riaprire una missione di altro soggetto: il root/host risolve mission id e proprietario prima del resume. Misurare che T2/T3 producano esattamente il numero di routing pass previsto: **zero** per il turno consumato, **uno** per il turno ceduto.

### 4.6 Claim e release espliciti della conversazione

Per non lasciare implicito il passaggio iniziale da `delegate` a "questa Skill possiede i prossimi input", aggiungere **due helper generici** del Server, non specifici di Directive:

~~~elixir
# API 0.4.1 PROPOSTA: gli helper accodano comandi di lifecycle locali.
ctx = Spectre.Server.claim_conversation(ctx)
ctx = Spectre.Server.release_conversation(ctx)

# Opzione host-only proposta per più chat dello stesso subject.
# Il valore è validato dal transport autenticato; mai dal testo del modello.
{:ok, _} = Spectre.Server.input(root, "Continua", conversation: verified_key)
~~~

- `claim_conversation(ctx)` è disponibile da un Server/Skill che sta realmente trattando un input consegnato dal runtime. Il Runtime valida soggetto, mount, session generation e conversation key. Il claim è acquisito con checkpoint prima di pubblicare il lease al root. Ripetere lo stesso claim è idempotente; reclamare la conversazione di un altro soggetto è rifiutato.
- La prima delega da `handle_flow(:unmatched)` **non diventa automaticamente focus perpetuo**. Il driver Directive, quando accetta l'ingresso, chiama `claim_conversation`; il root riceve una receipt verificabile e consegna i turni seguenti allo stesso child.
- `release_conversation` termina il focus quando la conversazione finisce/cancella. `:cont` di child **sospende** il focus per cedere il turno al router, ma non cancella memoria, attese o missioni.
- Per applicazioni con una sola chat per Server, il conversation key di default è la sessione autenticata. Per più chat dello stesso subject l'host fornisce `conversation: verified_key`, che viene vincolato al subject; non è un valore arbitrario copiato dall'input esterno.
- Claim/release usano i command/checkpoint esistenti e receipt root/child; **non** creano un nuovo GAM Act e non fanno `GenServer.call` ricorsivo.
- Global interrupt e pending esplicitamente indirizzati mantengono la priorità. Dopo `:cont`, una Skill non ricattura automaticamente il messaggio seguente senza un nuovo claim/resume verificato.

**Nel codice generato da `use Spectre.Directive.Server`** il claim avviene automaticamente quando il driver prende in carico il primo input. Un package terzo può usare gli stessi helper.

## 5. Spectre.Directive: conversazione, reasoner e tool loop completi

### 5.1 Un normale Server per la Skill, nessun runtime nascosto

Lavorare in `spectre_directive`. Mantenere reducer puro (`SpectreDirective.Loop.Engine`), API standalone e helper reducer V1. Aggiungere un driver che implementa le callback del **normale `Spectre.Server`** e che può essere montato sotto `Spectre.Skill`:

~~~elixir
# API ERGONOMICA PROPOSTA 0.4.1; da implementare nel package Directive.
defmodule Demo.AssistantServer do
  use Spectre.Directive.Server,
    tools: Demo.Stack,
    mode: :conversation,
    protocol: :json,
    model: :configured_response_model,
    model_tools: ["invoice.list", "invoice.send"]
end
~~~

La macro `use Spectre.Directive.Server` deve espandere il normale `use Spectre.Server, tools: Demo.Stack`, registrare i propri handler e gli eventuali continuation contracts. Non avvia una missione OTP aggiuntiva dentro un altro GenServer; usa il **processo Skill Server** già supervisionato. Deve mostrare chiaramente come fare override di un handler e quando usare `super`. Callback `handle_result` dedicate del driver non possono sparire dietro un catch-all dell'applicazione.

### 5.2 Due modalità che condividono tool, worker e policy

**`mode: :conversation`:** risposta aperta multi-turno, modello che ragiona e sceglie tool, history bounded, possibilità di chiedere dettagli. Non forzare ogni messaggio in una Mission con Plan terminale; il package può avere `SpectreDirective.Conversation.State`, piccolo stato puro che usa lo stesso formato decisioni/tool e la stessa gestione degli input.

**`mode: :mission`:** usare il reducer già esistente, con id/plan_version/step/request e `new/next/respond/inform`. Una Mission può rimanere attiva in background e ricevere correzioni senza interrompere altri flow. Il root e le altre Skill sono disponibili mentre i suoi worker lavorano.

**Importante:** `mode: :conversation` è il default del driver, non un divieto di missioni: una chat può aprire più missioni del reducer e lasciarle lavorare in background. `mode: :mission` è la variante restrittiva per una Skill dedicata a un task pianificato.

~~~text
Directive handle_input -> state/conversation oppure mission
  |
  +-- conversazione -> prepara prompt + memoria opzionale + available_tools
  |                    -> generate(reason) nel worker
  |                    -> valida risposta consolidata:
  |                       - "say"     -> respond + salva stato
  |                       - "ask"     -> await_input + ripresa id/revision
  |                       - "tool"    -> call_tool -> on_result -> nuovo reason -> respond
  |                       - "yield"   -> :cont (stato solo; root router once)
  |
  +-- missione -> SpectreDirective.next:
                 :reason       -> generate -> parse -> respond(request.id)
                 :invoke       -> ToolRef chiuso -> call_tool -> observed result -> respond
                 :question     -> await_input -> respond(request.id)
                 :confirmation -> conferma del PIANO, non consenso GAM
                 :policy       -> host-selected handler, allow/deny/blocked
                 :done         -> final outcome, release focus
                 :blocked      -> sospesa, eventuale richiesta utente
                 :error        -> diagnostica o recovery bounded
~~~

### 5.3 JSON e Kinetic AL convergono prima del Server command

~~~json
{"type":"tool_call","id":"model-call-1",
 "name":"invoice.list","arguments":{"status":"overdue"}}
~~~

~~~json
{"type":"assistant_message","text":"Ci sono due fatture scadute."}
~~~

Il parser deve accettare soltanto decisioni documentate e validate. Chiamate native function-call del provider vanno normalizzate al medesimo formato. Se `protocol: :kinetic_al`, soltanto l'AL **consolidato** viene interpretato da Kinetic e trasformato in `ToolRef + args`. Non ci sono due executor e non basta un nome inventato dal modello per lanciare codice. Il modello non seleziona provider, credenziali, MFA o tool non esposti. Errori JSON/AL possono provocare un retry cognitivo bounded, mai un side effect parziale.

### 5.4 Come il driver usa i comandi e riceve i risultati

~~~elixir
# PSEUDOCODICE del driver, sufficiente per fissare il contratto.
def handle_result(:directive_reason, {:correlated, request, {:generated, output}}, ctx) do
  case Spectre.Directive.Decision.decode(output) do
    {:say, text} -> Spectre.Directive.Driver.complete_turn(ctx, request, text)
    {:ask, question} -> Spectre.Directive.Driver.ask(ctx, request, question)
    {:tool, ref, args} ->
      Spectre.Server.call_tool(ctx, ref, args,
        on_result: :directive_tool, correlation: request)
    {:yield, _} ->
      # Una decisione model non è da sola un :cont autorizzato:
      # validare ownership/situazione, poi il driver applica la policy.
      Spectre.Directive.Driver.request_yield(ctx, request)
    {:error, error} -> Spectre.Directive.Driver.invalid_decision(ctx, request, error)
  end
end

def handle_result(:directive_tool, {:correlated, request, observed}, ctx) do
  # Verifica request viva, result del command corretto, severity/outcome.
  # Alimenta reducer o history; se necessario avvia una nuova generate.
  Spectre.Directive.Driver.observe(ctx, request, observed)
end

# handle_input/2 / handle_pending/3 possono tornare :cont o Context.
# handle_result/3 NON può tornare :cont: per il yield su risultato asincrono
# si registra il desiderio di cedere il PROSSIMO input, non si fa rerouting.
~~~

Per `:invoke` conservare e verificare `mission_id + request.id + plan_version + command_id`. Una risposta governata `unknown` non equivale a `complete_step`; l'obbligo GAM resta aperto. Il driver non può rispondere `"inviato"` a una semplice admission, solo a un Outcome osservato.

### 5.5 Stato privato del driver, retention e recovery

La Skill Server già ha checkpoint; riusare quello, senza creare obbligatoriamente un Directive Store parallelo. Esempio di struttura portabile **illustrativa**:

~~~elixir
%{
  schema_version: 1,
  conversations: %{
    "chat-7" => %{mode: :conversation, revision: 12, history: [...], focus: :foreground}
  },
  missions: %{"m-1" => encoded_reducer_state},
  inflight: %{
    "command-ref" => %{conversation: "chat-7", mission: "m-1",
                       request: "r-9", attempt: 1}
  }
}
~~~

Niente PID, clients, provider secret, interi Context o history illimitata nel checkpoint. Lo stato reducer oggi ha un limite serializzato **900.000 byte**; misurarlo e applicare proiezione/retention/summarization esplicita. Reset invalida correlazioni vecchie. Un risultato tardivo non deve ridare a una missione il foreground né causare il retry di un effetto incerto. Separare il budget/lifetime della missione dalla singola interazione (nel prototipo il limite di 32 step e timeout ereditati fermavano catene di lavoro); nessun timeout infinito implicito.


## 6. Esempio completo, dalla libreria fino al risultato

**È la fixture target da rendere eseguibile dopo l'implementazione della 0.4.1.** Non è un esempio "magico" e non deve richiedere callback model/tool scritti dall'applicazione. `Demo.InvoiceAPI` è un fake deterministico; sostituirlo con una vera libreria di fatture non deve cambiare la struttura.

### 6.1 Creare il package e la registrazione di un tool

~~~elixir
# Nessun SDK esterno: fixture per poter verificare ogni passaggio.
defmodule Demo.InvoiceAPI do
  def list("tenant-1", "overdue"),
    do: {:ok, [%{"id" => "F-10", "status" => "overdue"}]}
  def list(_, _), do: {:ok, []}

  def send("tenant-1", "F-10", idempotency_key),
    do: {:ok, %{"invoice_id" => "F-10", "receipt" => idempotency_key}}
  def send(_, _, _), do: {:error, :definitive_no_effect, :not_found}
end

defmodule Demo.InvoiceTool do
  use Spectre.Stack.Installable,
    id: :demo_invoice, version: "1.0.0", contract: 1

  @impl true
  def tools(_config) do
    %{
      invoice: %{
        contract: 2, adapter: Demo.InvoiceAdapter,
        default: nil, description: "Operazioni su fatture",
        operations: %{
          list: %{
            path: :cognitive, retry: :safe, max_bytes: 65_536,
            description: "Cerca fatture per stato",
            input_schema: %{
              "type" => "object",
              "properties" => %{"status" => %{"type" => "string"}},
              "required" => ["status"], "additionalProperties" => false
            }
          },
          send: %{
            path: :governed, operation: :send_invoice, max_bytes: 65_536,
            description: "Invia una fattura già preparata",
            input_schema: %{
              "type" => "object",
              "properties" => %{"invoice_id" => %{"type" => "string"}},
              "required" => ["invoice_id"], "additionalProperties" => false
            }
          }
        }
      }
    }
  end

  @impl true
  def effects(_config) do
    %{send_invoice: %{
      contract: 1, adapter: Demo.InvoiceAdapter, operation: :send,
      side_effect: :non_idempotent, material: :arguments,
      partition: [:subject], schema_hash: nil, config: %{}
    }}
  end
end

defmodule Demo.InvoiceAdapter do
  @behaviour Spectre.Tool.Adapter
  @behaviour Spectre.Server.GAM.EffectAdapter

  def prepare(:list, [%{"status" => status}], _) when is_binary(status),
    do: {:ok, %{"status" => status}}

  def prepare(:send, [%{"invoice_id" => id}], _) when is_binary(id),
    do: {:ok, %{"invoice_id" => id}}

  def prepare(_, _, _), do: {:error, :invalid_invoice_arguments}

  # Il Server esegue questa read cognitiva in un worker supervisionato.
  def invoke(:list, %{"status" => status}, %{service_context: service}),
    do: Demo.InvoiceAPI.list(service.identity.subject, status)

  def project(:list, {:ok, data}), do: {:ok, {:ok, data}}
  def project(:list, {:error, reason}), do: {:ok, {:error, reason}}
  def project(_, _), do: {:error, :invalid_invoice_result}

  # Chiamata SOLO dall'executor dopo l'ammissione GAM, mai da Directive.
  def execute_effect(:send, %{"invoice_id" => id}, context),
    do: Demo.InvoiceAPI.send(context.identity.subject, id, context.command_id)
end
~~~

Il `:list` è `:cognitive` e usa `invoke/3`; il `:send` è `:governed`, risolto da `effects/1` e dal GAM. Il Server invoca la stessa interfaccia sia tramite codice statico sia tramite un tool name selezionato dal modello. La versione V2 dello schema è controllata, non sostituisce `prepare/3`.

### 6.2 Lo Stack installa gli stessi package, senza autorizzarli

~~~elixir
defmodule Demo.Stack do
  use Spectre.Stack
  install Demo.InvoiceTool
  install Spectre.Directive
  # In seguito si possono installare Spectre.Mnemonic, Spectre.Kinetic, ecc.
end
~~~

Lo Stack compila la tabella delle installazioni, gli schema V2 e i digest; non crea un secondo registro. Allo startup del Server i binding devono corrispondere a quelli del compiled Stack e gli effects governati devono avere una configurazione GAM valida.

### 6.3 Una Skill conversazionale normale, SENZA la route artificiale /assistant

~~~elixir
# API 0.4.1 PROPOSTA, da implementare nel package spectre_directive.
defmodule Demo.AssistantServer do
  use Spectre.Directive.Server,
    tools: Demo.Stack,
    mode: :conversation,
    model: :configured_response_model,
    protocol: :json,
    model_tools: ["invoice.list", "invoice.send"]
end

defmodule Demo.AssistantSkill do
  use Spectre.Skill, id: :assistant, server: Demo.AssistantServer
  # Deve poter essere montata e invocata dal root via delegate,
  # anche senza un flow fittizio /assistant.
end

defmodule Demo.Agent do
  use Spectre.Agent, stack: Demo.Stack, server: Demo.RootServer
  router strategies: [:regex]

  flow :invoices do
    on :status, regex: ~r/^stato fatture$/i
  end

  skill Demo.AssistantSkill, as: :assistant, governed: [:send_invoice]
end
~~~

**Gate specifico da verificare in codice:** se nella 0.4 una `Spectre.Skill` priva di flow non può essere montata/delegata, modificare **solo il contratto di delega esplicita** per supportare quel caso. Non simulare la soluzione aggiungendo un regex che cattura tutti i messaggi; sarebbe un bug architetturale, non una feature.

### 6.4 Root Server: routing deterministico, :cont e fallback dichiarato

~~~elixir
defmodule Demo.RootServer do
  use Spectre.Server, tools: Demo.Stack

  @impl true
  def handle_input(_input, _ctx), do: :cont
  # Nessun owner -> prosegue verso il router deterministico.

  @impl true
  def handle_flow({:invoices, :status}, _input, ctx) do
    Spectre.Server.call_tool(ctx, "invoice.list", %{"status" => "overdue"},
      on_result: :invoice_status)
  end

  @impl true
  def handle_result(:invoice_status, {:ok, invoices}, ctx),
    do: respond(ctx, "Fatture scadute: " <> inspect(invoices))

  @impl true
  def handle_flow(:unmatched, input, ctx) do
    case ctx.routing.reason do
      :no_match ->
        delegate(ctx, :assistant, input, on_result: :assistant_started)

      :ambiguous ->
        respond(ctx, "Puoi chiarire la richiesta?")

      {:classifier_error, _} ->
        respond(ctx, "Il router non è disponibile; riprova.")

      other ->
        respond(ctx, "Routing non risolto: " <> inspect(other))
    end
  end

  @impl true
  def handle_result(:assistant_started, {:delegated, _details}, ctx),
    do: no_response(ctx)

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
~~~

**Il Root non contiene nessun loop LLM o Tool JSON.** La callback di fallback è breve ed esplicita. La Skill deve possedere il dialogo dopo l'ack di delega; i turni successivi non vengono classificati ogni volta finché restano nel suo focus.

### 6.5 Driver Directive generato, senza callback manuali nell'app

L'ergonomia `use Spectre.Directive.Server` deve generare (nel package Directive, non nell'app) una implementazione equivalente a:

~~~elixir
# ESTRATTO DI DESIGN del package; NON codice richiesto all'applicazione
def handle_input(input, ctx) do
  case Spectre.Directive.Driver.offer(ctx, input) do
    {:handled, next_ctx} -> next_ctx
    :not_owned -> :cont
    {:yield, next_ctx} -> {:cont, next_ctx} # commands vuoto, stato solo
  end
end

def handle_result(:directive_reason, {:correlated, ref, generated}, ctx),
  do: Spectre.Directive.Driver.accept_model(ctx, ref, generated)

def handle_result(:directive_tool, {:correlated, ref, result}, ctx),
  do: Spectre.Directive.Driver.accept_tool(ctx, ref, result)

def handle_result(:directive_reply, {:correlated, ref, answer}, ctx),
  do: Spectre.Directive.Driver.accept_answer(ctx, ref, answer)
~~~

Il driver deve decidere quando produrre `generate`, `call_tool`, `respond` o `await_input`. Il model parser valida **prima** di chiamare il tool. La richiesta reducer corrente è correlata ai command id; non usare il testo `"sì"` come approvazione GAM generica. Callback `handle_result` dell'applicazione non devono intercettare per sbaglio i tag propri del driver.

### 6.6 Avvio, messaggi e traccia di esecuzione

~~~elixir
# Avvio TARGET (le API qui sotto di start_link/input/decide sono già note
# nella 0.4; il driver e call_tool restano proposti).
{:ok, root} =
  Spectre.Server.start_link(
    agent: Demo.Agent,
    identity: %{subject: "tenant-1"},
    consumer: self(),
    gam: [operations: %{send_invoice: [confirm: true]}]
  )

{:ok, _i1} = Spectre.Server.input(root, "stato fatture")
# Router riconosce invoices.status. Root chiama invoice.list.
# Arriva una response con "F-10"; Directive non è stato chiamato.

{:ok, _i2} = Spectre.Server.input(root, "Controlla le fatture scadute")
# Router: vero no_match -> delegate(:assistant) -> Claim/owner.
# Directive: generate -> {"name":"invoice.list",...}
#          -> call_tool -> cognitive worker -> on_result -> generate -> risposta.

{:ok, _i3} = Spectre.Server.input(root, "E la fattura F-10?")
# Conversation owner = assistant: il router non viene richiamato.

{:ok, _i4} = Spectre.Server.input(root, "Invia la fattura F-10")
# Directive: invoice.send -> proposta governata -> GAM Presentation.
# NESSUN invio reale prima dell'ammissione/consenso.
~~~

L'approvazione non va inventata nel test. Il consumer deve ricevere la **vera Presentation** e usarne riferimento e revisione con le API già documentate (`Server.presented`, `Server.decide` indirizzato a `:assistant`). Verificare `approved` e `rejected` e gli outcome ambiguo/unknown; soltanto l'Outcome reale `:succeeded` giustifica `"fattura inviata"`.

La fixture deve registrare e confrontare i seguenti stadi, non soltanto il testo finale:

~~~text
compile Stack -> check digest/tools/effects
start root -> start Skill Supervisor -> assistant child PID -> same GAM Domain
input 1 -> input prepare -> router regex -> handle_flow(status)
        -> call_tool(invoice.list) -> Command :tool -> outbox -> worker
        -> Demo.InvoiceAdapter.invoke -> project -> handle_result -> response
input 2 -> no_match -> root delegate -> assistant accepts/claims conversation
        -> generate -> decision parse JSON -> resolve "invoice.list"
        -> call_tool -> prepare/schema -> worker -> correlated result
        -> Directive updates state -> generate -> response
input 3 -> owner assistant -> handle_input consumes -> no router
input 4 -> owner assistant -> tool invoice.send -> propose
        -> GAM authorization/Presentation -> presented -> decide
        -> executor.execute_effect -> Outcome -> Directive -> response
topic change -> owner assistant returns :cont -> verified yield receipt
             -> root pre-route + regex router EXACTLY ONCE
background mission continues -> result never steals focus
restart -> tool and continuation digest check -> stale outcome cannot advance
~~~

**Bug gate:** la fixture deve fallire se il comando JSON aggira `Tool.normalize` o GAM, se esiste un doppio GenServer di Directive, se il root usa il router durante ogni turno owned, o se dopo `:cont` l'input viene interpretato due volte.


## 7. Migrazione verificabile di TUTTI i package spectre_* all'API comune

Questa parte è parte integrante della release, non un "audit eventuale". Il Core nuovo **non deve avere case hardcoded sui nomi dei package**. Il solo contratto necessario per una callable operation è `Installable.tools/1` -> `Spectre.Tool.Adapter` -> `call_tool`; per i governed effects rimane `effects/1` -> `GAM.EffectAdapter`.

Per ogni repository: leggere la dichiarazione dei tools nel modulo `lib/spectre/<nome>.ex`, l'implementazione `lib/spectre/<nome>/server_tool.ex` e gli effect bindings. Proporre uno schema V2 per le operazioni che possono essere mostrate a un modello; le altre conservano V1 o diventano V2 **host-only**. L'API standalone e i provider spezializzati NON vengono soppressi.

| Repository | Operazioni già presenti nella 0.4 da riusare | Modifica target + test obbligatorio |
| --- | --- | --- |
| [spectre_kinetic](https://github.com/elchemista/spectre_kinetic) | `kinetic.interpret` come parser di AL; action catalog ed effects | Catalog V2 per `interpret` solo host/driver; il risultato AL consolidato si normalizza in ToolRef oppure nella registered action host, che attraversa `propose/GAM`. Test equivalenza JSON/AL verso lo stesso target, zero esecuzioni duplicate |
| [spectre_mnemonic](https://github.com/elchemista/spectre_mnemonic) | `search/recall/reflect` e altre read; `remember/signal/forget` e write opzionalmente bound | V2 con schema esplicito per cue, scope e write payload. Subject/partition rimane fissato dall'host, mai dal modello; write solo da GAM. Test dati non-leak tra subject e stesso risultato v1 vs call_tool |
| [spectre_prism](https://github.com/elchemista/spectre_prism) | `prism.select` read-only; provider/inference selector separati | V2 per `select`, modello visibile solo con allowlist. I model provider restano `generate/classify` services, non MFA o credenziali invocabili dal modello. Test nessun selector bypass |
| [spectre_lens](https://github.com/elchemista/spectre_lens) | `open/look/act/close` con alcuni bound governati | V2 per URL/tab/action e ref portabili, stessa politica effettiva per open/look/act/close (non presumere lettura sempre libera). Test rollback impossibile di open ambigua, lease e stessi Outcome |
| [spectre_beam](https://github.com/elchemista/spectre_beam) | `endpoints` cognitivo, `deliver` governato | V2 per endpoint lookup e outbound; ingress del canale, socket e idempotency restano servizi Beam. Test ricevuta delivery, autorizzazione e invio una volta |
| [spectre_pulse](https://github.com/elchemista/spectre_pulse) | `protocol/contacts` cognitivi, `send` governato | V2 per discovery/protocol e messaggi; external approval continua nel protocollo Pulse e GAM. Test un ack tecnico NON approva una Presentation GAM |
| [spectre_ledger](https://github.com/elchemista/spectre_ledger) | `head/entries` read-only | V2 per introspezione sicura, invisibile al modello per default. Gli Store/Checkpoint/Domain backend restano **provider**, non tool generici di scrittura. Test isolamento del checkpoint corrente |
| [spectre_lab](https://github.com/elchemista/spectre_lab) | `inspect` e diagnostica redatta | V2 di introspezione, host-only per default. Test dati redatti, nessun accesso a checkpoint di una Skill sorella o un altro subject |
| [spectre_directive](https://github.com/elchemista/spectre_directive) | `new/next/respond/inform` reducer (pure helper) | Conservare tool V1 di compatibilità e introdurre il nuovo driver che **consuma** la stessa Tool API. Non esporre `directive.respond` come tool libero del modello; richiesta reducer correlata |
| Package nuovo di terze parti | Nessuno | Deve compilare uno Stack, essere scoperto/invocato da root e Skill e, se governato, seguire GAM senza **alcuna** clausola particolare nel core |

**Morph** resta intenzionalmente fuori dalla release: non aggiungere una API `Evolution` per fargli funzionare questa migrazione.

### 7.3 Esempi di riferimenti chiamabili con la stessa API

Queste sono **forme V2 TARGET**, non promesse sugli argomenti delle attuali API V1. Ogni satellite deve fornire il suo mapping esplicito V2 -> `ServerTool.prepare` esistente, con schema verificato e proiezione portabile. La policy host seleziona quali sono model-visible:

~~~elixir
# Tutti usano Spectre.Server.call_tool(ctx, name, JSON_args, on_result: tag).
call_tool(ctx, "prism.select",     %{"purpose" => "response_generation"}, on_result: :selected)
call_tool(ctx, "mnemonic.recall",  %{"cue" => "contratto"}, on_result: :recalled)
call_tool(ctx, "lens.look",        %{"tab_ref" => "tab-23"}, on_result: :viewed)
call_tool(ctx, "beam.endpoints",   %{}, on_result: :endpoints)
call_tool(ctx, "pulse.contacts",   %{}, on_result: :contacts)
call_tool(ctx, "ledger.head",      %{}, on_result: :ledger_head)
call_tool(ctx, "lab.inspect",      %{"mode" => "operational"}, on_result: :diagnostics)

# Governed: visibili al modello solo se l'host sceglie di esporli;
# l'operazione e il mandato restano verificati dal GAM.
call_tool(ctx, "beam.deliver", %{"endpoint" => "whatsapp",
  "outbound" => %{"text" => "Ciao"}}, on_result: :delivery)

call_tool(ctx, "pulse.send", %{"to" => "agent:billing",
  "act" => "request", "payload" => %{"invoice_id" => "F-10"}},
  on_result: :agent_message)
~~~

`kinetic.interpret` resta primariamente una funzione di parsing del driver, normalmente **non** offerta al modello come tool da invocare. `directive.next/respond` restano strumenti interni del reducer, **non** capacità da esporre all'utente. `ledger.head` e `lab.inspect` dovrebbero essere **host-only** per default.

**Il fatto che un nome sia mostrato qui non ne garantisce la disponibilità:** è il descriptor installato, il binding GAM e il model tool policy del Server a decidere. I nomi e i campi effettivi saranno fissati dai test sul rispettivo adapter.



### 7.1 Regola di migrazione per ogni package (non rompere i chiamanti)

L'attuale helper privato generato a compile time deve continuare a funzionare:

~~~elixir
# 0.4, input posizionale:
ctx = mnemonic(ctx, {:recall, "contratto"}, on_result: :memory)

# 0.4.1, input JSON V2:
ctx = Spectre.Server.call_tool(ctx, "mnemonic.recall",
  %{"cue" => "contratto"}, on_result: :memory)
~~~

Lo `ServerTool.prepare/3` di Mnemonic attuale non deve necessariamente ricevere lo stesso payload dai due ingressi: lo **strato di adattamento V2** può convertire la mappa JSON in una chiamata con argomenti posizionali legacy, **oppure** aggiungere una clausola nel suo adapter. Documentare e testare questa conversione. Non cambiare silenziosamente il significato dei dati V1.

### 7.2 Conformance richiesto per ciascun satellite

Per ogni package eseguire **tutte** queste prove, non solo un test di compilazione:

1. `tools/1` del package compilato, descriptor/digest validi e assenza di collisioni.
2. `available_tools` restituisce operazioni V2 **solo se** host le espone e lo scope Skill lo consente; le altre restano private.
3. `call_tool` da root e da un child Skill produce lo stesso `prepare/invoke/project` (o lo stesso `propose/GAM`) del vecchio helper V1.
4. Esistono test per argomenti malformati, tool inesistente, operation non registrata, domain error e risultato non portabile.
5. Per tool governato: denial, approval, timeout, esito ambiguo, replay protetto e provenance Skill; **non** chiamare `execute_effect` durante `prepare/invoke`.
6. Standalone API e resource/provider behaviors restano invariati; `spectre_ecosystem` esegue l'integrazione completa con core e package reali, non con test stub che imitano il contratto.

Se un adapter V2 richiede un `if package == :mnemonic` o `case tool == :lens` nel Core, il gate fallisce: la regola va espressa dal descriptor/adapter, oppure serve discutere un nuovo **contratto generico**, non un'eccezione per satellite.

## 8. Test di errore, sicurezza e proprietà del flusso

| Test concreto | Risultato richiesto |
| --- | --- |
| Il modello emette `"invoice.delete_all"` non installato | Lookup fallisce in modo controllato; nessun nuovo atom o MFA viene creato |
| Il modello chiede `invoice.send` installato ma non esposto | Rifiuto anche in fase di call, non solo mancata visibilità |
| Tool descritto ma effect host non registrato | Fail-closed all'avvio o prima del dispatch; nessun executor chiamato |
| JSON schema invalido o AL parziale | Il reasoner riceve errore bounded; nessun command di effetto |
| V1 helper e V2 call con input equivalente | Stessi adapter, command path, result tag, policy e digest corretto |
| Due package tentano il nome `invoice` | Errore deterministico di collisione alla compilazione Stack |
| `call_tool` cognitivo interrupted con `retry: :safe` | Recovery con identità corretta, senza doppio commit di stato |
| `call_tool` `retry: :never` con failure ambigua | Restituisce unknown, non esegue in automatico una seconda volta |
| Due Mission con `:directive_tool` in contemporanea | Tag statico ma ref diverso; result non attraversa mission/Skill/session |
| `handle_input -> :cont` | Una chiamata al router, zero comandi acquisiti |
| `handle_input -> {:cont, ctx}` con comandi | Contratto invalido, nessun comando eseguito |
| `handle_pending -> :cont` | Wait sospesa, ref conservato; nessun "sì" inventato come consenso |
| `handle_flow(route) -> :cont` | Un solo fallback, niente richiamo dello stesso classificatore |
| `handle_flow(:unmatched) -> :cont` | Errore terminale di dispatch, nessun ciclo |
| Child Skill fa `:cont` | Yield correlato al root, routing una sola volta, missione non cancellata |
| Child crasha dopo yield o manda yield duplicato | Il root non ripete il tool né la stessa route due volte |
| Router restituisce `{:classifier_error, reason}` | Errore diagnosticato, NON trattato come `:no_match` |
| Pending/Presentation di Skill A riceve risposta di Skill B | Stale/invalid authority, nessuna approvazione |
| Background mission >32 step mentre arriva una FAQ | FAQ risponde dal root, mission continua e non riprende foreground |
| Reset, restart, stale response, digest drift | Risultato scartato o recupero controllato, no restore di autorizzazioni vecchie |
| RAM-only, disk, Ledger e storage outage | RAM volatile corretta, nessun falso commit durevole |
| Strict `assigns_schema` / `continuation_contracts` | Nuovi envelope e tag statici validati, senza richiedere campi runtime privati |
| 1/10/100 agenti con chat e tool | Memoria, code e latenza misurate su workload ripetibili e dopo GC |

## 9. Piano di sviluppo per un agente implementatore: file, intervento e GATE

**Non implementare contemporaneamente tutti i punti. Ogni fase ha un test che deve diventare verde prima della successiva.** I test dovranno distinguere la 0.4 corrente dalle nuove API 0.4.1 e non dichiarare risultati che non sono stati misurati.

### Fase 0 - Baseline, prova minima e contratti

**Aprire prima:**

- `lib/spectre/stack/installable.ex`, `lib/spectre/stack/tools.ex`, `lib/spectre/stack/effects.ex`.
- `lib/spectre/server/tool.ex`, `tool_compiler.ex`, `command.ex`, `runtime.ex`, `contracts.ex`, `skills.ex`, `pre_route.ex`, `router.ex`.
- `spectre_directive/lib/spectre/directive/server_tool.ex`, `spectre_directive/lib/spectre_directive/loop/engine.ex`.

Costruire un fake V1 cognitivo/governato; registrare il risultato dell'helper compilato, command id, trace outbox, GAM outcome, reset e ripresa. Eseguire una callback che restituisce `:cont` e documentare l'attuale errore di contratto. Provare la delega di una Skill senza flow (se il compiler la rifiuta, registrare l'ostacolo).

**GATE 0:** baseline eseguibile, report dei gap reali, nessun cambiamento del kernel o dei package satellite.

### Fase 1 - Tool authoring V2

In `stack/tools.ex` e nel nuovo `Spectre.Tool.Adapter` introdurre schema e validator V2. Mantenere parser/descriptor V1 **identici** per chi già lo usa. Fissare il subset JSON Schema e rifiutare keyword sconosciute. Introdurre helper di creazione schema/descriptor **puro e opzionale**, per evitare boilerplate tra satellite, ma senza creare un altro registry/DSL obbligatorio.

~~~elixir
# API ERGONOMICA 0.4.1 PROPOSTA: helper puro sopra Stack.Tools.
def tools(_config) do
  Spectre.Tool.define!(:invoice,
    adapter: Demo.InvoiceAdapter,
    default: nil,
    description: "Fatture",
    operations: %{
      list: %{
        path: :cognitive, retry: :safe, max_bytes: 65_536,
        description: "Lista fatture",
        input_schema: %{
          "type" => "object",
          "properties" => %{"status" => %{"type" => "string"}},
          "required" => ["status"],
          "additionalProperties" => false
        }
      }
    })
end
# Ritorna %{invoice: descriptor_v2}; nessun registry o macro aggiuntivo.
~~~

**GATE 1:** fixture V2 valida e serializzabile, V1 invariata, zero registri di tool nuovi.

### Fase 2 - Invocazione API unica nel Runtime

In `server.ex`/`server/tool.ex`/`tool_compiler.ex`/`server/context.ex` implementare:

- `available_tools(ctx, audience: :model)` come proiezione filtered e deterministica.
- `call_tool(ctx, ref, args, opts)` come wrapper del comando `:tool` esistente, non invocazione sincrona.
- Name resolution da stringa verso ToolRef closed, nessun atom dinamico; permit/visibility re-check prima dell'acquisizione.
- `correlation` opt-in su generate/tool/await, con tagged reply `{:correlated, ref, result}` per strict continuation contracts.
- Firma immutable/digest e provenance già previsti dal core.

Testare root e child, shape di tool result con/senza correlazione, consent, rejection, unknown, restart.

**GATE 2:** due ingressi (helper v1 e call_tool v2) = **un solo Tool.normalize e un solo GAM**.

### Fase 3 - Prima migrazione satellite e verifica universalità

Migrare in ordine: **Prism (read-only) -> Ledger/Lab (diagnostica) -> Mnemonic (read/write) -> Kinetic (AL parser) -> Lens -> Beam -> Pulse**. Per ogni repo aggiungere suite v1-v2 e prova in Skill Server. Non incorporare logica del package nel core.

**GATE 3:** matrice della sezione 7 verde per almeno un package nuovo di terzi e per i satellite effettivamente migrati; gli altri V1 ancora funzionanti. Se fallisce un contratto, correggere nel punto comune o adapter, non bypassarlo.

### Fase 4 - Contratto :cont, root/Skill handoff

In `server.ex` + `server/runtime.ex` aggiungere `handle_input/2` e ritorni `:cont / {:cont, ctx}`, con state-only dispatch validation. Preservare precedenza degli interrupt, consent e dei pending. Sperimentare prima `await_reply/route_current_input`; aggiungere un lease di ownership minimo **solo se necessario** per la conversazione senza pending. Root/Skill handoff per yield con una receipt idempotente e one-pass router.

**GATE 4:** sequenza T1-T6 della sezione 4.5 verde, nessuna seconda classificazione, nessuna conferma GAM incrociata, test di duplicate yield e crash.

### Fase 5 - Nuovo driver Directive di conversazione

Nel package `spectre_directive` creare `Spectre.Directive.Server` e il driver automatico. Riutilizzare reducer/host tool. Codificare `mode: :conversation` senza forzare il `Plan`; implementare JSON tool protocol per primo. Aggiungere opzionale Kinetic AL che produce lo stesso ToolRef. Il driver deve poter gestire callback e tag senza codice custom in `Demo.AssistantServer`.

**GATE 5:** esempio completo della sezione 6, chat libera senza regex `/assistant`, root deterministico quando possibile, AI fallback soltanto su `:no_match`.

### Fase 6 - Missioni, background e recovery

Collegare tutte le request reducer `:reason/:question/:confirmation/:policy/:invoke` e plan patch, con correlazione fino all'Outcome osservato. Misurare e risolvere il limite sperimentale oltre 32 step, timeout ereditato e memoria; usare il normale worker/checkpoint della Skill. Testare due missioni, due Skill parallele, worker crash, interruzione durante consent, reset, restoration da disk e storage temporaneamente indisponibile.

**GATE 6:** la missione prosegue mentre il root risponde; niente risultati stale, niente side effect ripetuti, e il limite 900.000 byte è gestito e segnalato, non ignorato.

### Fase 7 - E2E satellite, profiling e documentazione

In `spectre_ecosystem` creare l'esempio realmente eseguibile con tool terzo, Root, Skill Directive e GAM. Eseguire formatter, compile warnings-as-errors, suite e coverage configurata, Credo strict, Dialyzer, docs check; provider reale solo in test opt-in e con autorizzazioni. Profiling agenti 1/10/100, separando processi/ETS/binary, worker, code, outbox e checkpoint, prima/dopo GC. Nessuna promessa di plateau senza misure.

Aggiornare nel core `docs/STACK_TOOLS.md`, `CUSTOM_STACK_TOOLS.md`, `STACK.md`, `SERVER_CALLBACKS.md`, `AGENT_SERVER.md`, `SKILLS.md`, `ROUTING.md`, `PENDING_LIFECYCLE.md`, `MANAGED_GAM.md`. Nel package Directive aggiornare README, `docs/SPECTRE_0_4.md`, API, runtime/OTP, esempi JSON e Kinetic.

**GATE 7:** test E2E realmente riproducibili e documentazione allineata alle API implementate. Non taggare o pubblicare Hex sulla base del solo piano.

## 10. Definition of Done (sintesi finale)

- [ ] Un package esterno dichiara `tools/1` e, se necessario, `effects/1` senza cambiare il Core.
- [ ] Un unico catalogo espone `available_tools` e invocazione `call_tool` per callback, Skill e Directive, con modello/schema/allowlist.
- [ ] Helper v1 e call_tool V2 producono lo stesso comando e usano lo stesso adapter/GAM; nessun secondo executor JSON/AL.
- [ ] Le nove integrazioni satellite sopra sono verificate o conservano compatibilità esplicita e testata nel percorso V1.
- [ ] `handle_input/handle_pending/handle_flow` comprendono `:cont` senza loop né comandi nascosti; root/Skill condividono handoff e consent corretti.
- [ ] Una Skill conversazionale usa Directive con `use Spectre.Directive.Server`, senza route `/assistant`, senza callback model/tool scritti dall'app.
- [ ] Directive parla liberamente, esegue tool, cambia argomento, riprende missioni e lavora in background con Session/Skill/GAM correttamente correlati.
- [ ] 32+ passaggi, restart/reset/cancel, esiti incerti, storage RAM-only e persistente sono verificati e misurati.
- [ ] Documenti, esempi, test di integrazione e release audit rispecchiano i comportamenti effettivamente implementati.

**Principio finale:** Stack installa; Agent riconosce; Server esegue e governa; Directive conversa e orchestra. `:cont` lascia proseguire **lo stesso input una volta sola**. Morph, nuovi runtime e nuove autorità non servono a questa release.
