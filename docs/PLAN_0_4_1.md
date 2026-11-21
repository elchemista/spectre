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

