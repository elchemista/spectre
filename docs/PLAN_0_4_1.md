# Spectre 0.4.1 - Tool API unificata e conversazione con Directive

**Stato:** piano di implementazione proposto, riscritto il 21 novembre 2026. Questo file descrive API da costruire e testare, non funzionalità già rilasciate.

## 1. Obiettivo della release

Conservare **Stack -> Agent -> Server**, le Skill supervisionate della 0.4 e il **GAM Domain condiviso**. Introdurre soltanto i contratti generici che mancano per:

1. **Creare e installare nuovi tool** da una libreria o dall'applicazione, tramite un unico contratto pubblico, senza patch specifiche al core.
2. **Scoprire e invocare tutti i tool installati tramite una sola API** del Server, da callback applicative, Skill e driver cognitivi. Un tool cognitivo e un tool governato attraversano lo stesso percorso di acquisizione, con GAM per i conseguenti effetti.
3. **Integrare spectre_directive come driver di conversazione**, capace di dialogo libero, ragionamento, tool calling, missioni multi-turno e lavoro in background. Il router deterministico resta disponibile ma non deve classificare ogni messaggio di una conversazione già posseduta.
4. Mantenere un solo owner operativo per ogni Server. Directive usa il runtime, i worker, i pending e i checkpoint esistenti; **non avvia implicitamente un secondo AgentServer, un altro journal o un altro scheduler**.

**Fuori scope per 0.4.1:** `spectre_morph`, attivazione/evoluzione dinamica delle Skill, generazione di moduli BEAM da risposte LLM, una nuova DSL `mission()` nel core, un registro tool parallelo, una riscrittura di GAM o la rimozione dei percorsi Instance/Run di compatibilità.

> Principio: il **core sa quali tool sono installati e come eseguirli**. Directive **decide quando usarli e come continuare la conversazione**. Le librerie satellite non devono implementare ciascuna un proprio loop.

## 2. Stato verificato: cosa riusare, cosa manca

Riferimenti al codice della 0.4 sul branch 0.4.1:

| Area | Gia presente nella 0.4 | Lavoro 0.4.1 |
| --- | --- | --- |
| [Stack.Installable](../lib/spectre/stack/installable.ex), [Stack.Tools](../lib/spectre/stack/tools.ex) | `tools/1`, `effects/1`, descrittori immutabili, identità e digest d'installazione | Rendere esplicito il comportamento dell'adapter, esporre descrizioni/schema per i tool selezionabili da un modello |
| [Server.Tool](../lib/spectre/server/tool.ex), [ToolCompiler](../lib/spectre/server/tool_compiler.ex) | Helper privati generati a compile time, `prepare/invoke/project`, comando `:tool`, worker, conversione governed in `propose` | API pubblica di discovery e invocazione dinamica per nome, **sullo stesso percorso** |
| [Server.Command](../lib/spectre/server/command.ex), [Server.Runtime](../lib/spectre/server/runtime.ex) | Outbox/inbox, tag `on_result`, continuazioni, checkpoint, pending, reset | Verificare correlazione generica, ownership dell'input e durata del lavoro in background |
| [Server.Skills](../lib/spectre/server/skills.ex), [Skills](SKILLS.md) | Una Skill con `server:` ha il proprio GenServer, worker e checkpoint; condivide GAM col root | Riutilizzare, non sostituire; nessuna Skill speciale richiesta dal core |
| [Routing](ROUTING.md), [Pending lifecycle](PENDING_LIFECYCLE.md) | Regex, dataset, embedding, classificatori, router adapter, `current_flow`, interruzioni, `await_reply` | Dialogo libero con continuità esplicita e ritorno al router quando opportuno |
| [spectre_directive](https://github.com/elchemista/spectre_directive) | Reducer puro `new/next/respond/inform`, richieste `:reason/:question/:confirmation/:policy/:invoke`, helper Stack e runtime standalone | Driver AgentServer che gestisce automaticamente il ciclo, senza callback manuali per ciascun risultato |

**Gap concreto:** oggi una libreria può dichiarare `tools/1`, ma un driver come Directive non dispone di un'unica API pubblica per elencare i tool effettivamente disponibili e invocarli con un riferimento scelto a runtime. Gli helper privati, ad esempio `mnemonic(ctx, ...)`, sono adatti a codice Elixir statico, non a una selezione di tool restituita da un modello.

**Gap conversazionale:** `current_flow` e una preferenza del router, non la proprietà del prossimo messaggio. Un `pending` attende una risposta specifica; bisogna verificare se basta, con sospensione/ritorno al router, anche per una conversazione aperta. In un esperimento precedente una catena in background si arrestava dopo 32 risultati e un worker ereditava il timeout della richiesta originaria: sono casi da riprodurre, non garanzie di produzione.

## 3. Contratto unico per dichiarare un tool

**Non introdurre un secondo plugin system.** Il punto di ingresso resta `Spectre.Stack.Installable`:

- `tools/1`: catalogo immutabile delle operazioni invocabili.
- `effects/1`: registrazioni degli executor dei soli effetti governati.
- `child_specs/2`: eventuali risorse supervisionate dallo Stack.Runtime.
- `agent_extensions`: integrazioni esistenti, senza registrazione duplicata.

Per facilitare la creazione di una libreria, formalizzare un **behaviour pubblico per gli adapter tool** (nome proposto: `Spectre.Server.Tool.Adapter`) con le funzioni **già utilizzate**: `prepare/3`, `invoke/3`, `project/2`. Esso documenta argomenti, risultati, errori, serializzazione, idempotenza e separazione cognitivo/governato. Gli adapter 0.4 che espongono già le funzioni restano compatibili anche senza `@behaviour`.

### Metadati per tool calling: descriptor v2 opzionale

Conservare integralmente il descriptor **contract 1**. Solo per i tool che devono essere presentati a un modello, progettare un **contract 2 opt-in**, con metadata immutabili e portabili: descrizione, schema di input per operazione e, se utile, schema di output. Non cambiare le regole di esecuzione di `contract 1`.

Esempio di forma **proposta, non API corrente**:

~~~elixir
def tools(_config) do
  %{
    invoices: %{
      contract: 2,
      adapter: MyApp.InvoiceTool,
      default: nil,
      description: "Consulta e gestisce fatture",
      operations: %{
        list: %{
          path: :cognitive,
          retry: :safe,
          max_bytes: 65_536,
          description: "Elenca le fatture",
          input_schema: %{"type" => "object", "properties" => %{
            "status" => %{"type" => "string"}
          }}
        },
        send: %{
          path: :governed,
          operation: :send_invoice,
          max_bytes: 65_536,
          description: "Invia una fattura esistente",
          input_schema: %{"type" => "object", "properties" => %{
            "invoice_id" => %{"type" => "string"}
          }, "required" => ["invoice_id"]}
        }
      }
    }
  }
end
~~~

La forma esatta di `contract 2` va congelata **dopo** test su un tool di terze parti. La configurazione rimane data-only; schema e descrizione non autorizzano l'esecuzione. `send_invoice` richiede la normale registrazione `effects/1`, abilitazione host e ammissione GAM.

**Creare un tool** in questa release significa scrivere un adapter affidabile e installarlo nello Stack, non permettere al modello di inventare e caricare codice Elixir. Un futuro tool composto di soli dati potrà eventualmente referenziare operazioni già autorizzate; non e una dipendenza di 0.4.1.

## 4. Unica API runtime per tutti i tool

Proporre due funzioni pubbliche sul Server. Il naming definitivo e soggetto ai test di fase 0:

~~~elixir
# PROPOSTA - non presenti nella 0.4.0/branch 0.4.1 corrente

# Solo una proiezione descrittiva, senza credenziali o handle runtime.
{:ok, tools} = Spectre.Server.available_tools(ctx, audience: :model)

# Accoda il comando esistente :tool, non esegue I/O nella callback.
ctx =
  Spectre.Server.call_tool(
    ctx,
    :invoices,
    {:list, %{"status" => "overdue"}},
    on_result: {:directive, mission_id, request_id}
  )
~~~

### Invarianti dell'API

1. **Una sola tabella:** risoluzione sul `Stack.Tools.table!` della installazione del Server; non introdurre un nuovo registry globale di tool.
2. **Un solo percorso di esecuzione:** `call_tool` normalizza nello stesso `Server.Tool`, `Command :tool`, outbox, worker o `propose` usati dagli helper generati. I helper `invoices(ctx, ...)` restano disponibili e compatibili.
3. **Discovery non equivale ad autorizzazione:** `available_tools` restituisce solo descrizioni esplicitamente visibili nel contesto host/Skill; l'ammissione finale delle conseguenze resta GAM. Non esporre dati privati, config, credenziali o operazioni che la Skill non può nominare.
4. **Riferimenti chiusi:** il modello seleziona soltanto tool/operazioni già dichiarati nello Stack e ammessi all'interfaccia corrente. Nessun `String.to_atom`, MFA arbitraria, eval o nuovo adapter caricato da input LLM.
5. **Identita e correlazione:** il comando porta tool, operazione, installazione/digest, origine (Agent o Skill), interaction id e tag di continuazione. Due missioni o due installazioni non condividono accidentalmente i risultati.
6. **Errori espliciti:** tool inesistente, operazione sconosciuta, schema invalido, timeout, rifiuto GAM, errore dell'adapter ed esito incerto restano distinti. Nessun retry cieco di effetti non idempotenti.
7. **Compatibilita:** nessun cambiamento di semantica per `generate`, `propose`, `delegate`, `await_reply`, callback OTP e tool descriptor v1. Entrambe le chiamate devono funzionare sia nel root Server sia in un Skill Server.

Il catalogo v2 rende possibile serializzare la descrizione dei tool per il normale **JSON tool calling**. **Kinetic AL** resta un parser/adapter alternativo che produce gli stessi riferimenti e argomenti validati. **Non creare un executor JSON e un executor AL**.

## 5. Directive: aggiungere conversazione, non un altro runtime

In `spectre_directive`, mantenere il reducer puro e l'API standalone. Aggiungere un **driver AgentServer** (nome proposto `Spectre.Directive.Server`) che utilizza solo i comandi pubblici del core: `generate`, `call_tool`, `await_reply`, `respond`, e `propose` solo quando serve il percorso governato esistente.

Il driver deve essere riusabile dentro una normale **Skill con `server:`**, oppure come Server root, senza costringere l'applicazione a scrivere il loop `handle_result(:model...)` / `handle_result(:tool...)` ad ogni nuova applicazione. Il driver, e non il core, conosce `Mission`, `Plan`, `Request`, `WorkingContext` e il protocollo di decisione di Directive.

### Due modalità dello stesso driver

- **Conversazione aperta:** l'utente parla liberamente; il modello risponde, chiede dettagli, seleziona tool installati e mantiene contesto multi-turno. Non serve predefinire una route per ogni domanda.
- **Missione:** Directive mantiene obiettivo, piano, step, evidenza e richieste correlate. Puo fare lavoro prolungato in background mentre altre interazioni restano utilizzabili.

Non aggiungere un `mission()` DSL nel core. Se il reducer mission-oriented non rappresenta bene una conversazione non terminale, aggiungere nel **package Directive** un sottile stato/modalità conversazionale che riusa protocollo, working context e gestione delle richieste; non forzare ogni messaggio a iniziare/chiudere una nuova missione.

### Dispatch delle richieste Directive

| Richiesta del reducer | Il driver esegue |
| --- | --- |
| `:reason` | `generate` su modello host-configurato; valida output e decisione prima di `respond` sul reducer |
| `:invoke` | Risolve il target nel catalogo consentito, accoda `call_tool`, restituisce al reducer il **risultato osservato** |
| `:question` | Attesa utente correlata; distingue risposta, correzione, cambio argomento e ripresa |
| `:confirmation` | Conferma del piano secondo policy dell'app; **non e consenso GAM** |
| `:policy` | Policy del host con esiti espliciti allow, deny, blocked |
| `:done/:blocked/:error` | Risposta, sospensione o terminazione esplicita, con stato coerente |

La normale integrazione JSON e un adapter di parsing validato; l'opzione Kinetic AL usa Kinetic come interprete, ma entrambe passano da **`call_tool` e GAM**, con lo stesso tag originale della richiesta Directive. Un errore del modello o una risposta malformata non devono essere interpretati come comando.

### Esempio di ergonomia desiderata

~~~elixir
# ESEMPIO DI DESIGN, non compilabile sulla 0.4 corrente

defmodule MyApp.Stack do
  use Spectre.Stack
  install Spectre.Directive
  install MyApp.InvoiceTools
end

defmodule MyApp.ConversationServer do
  use Spectre.Directive.Server,
    tools: MyApp.Stack,
    mode: :conversation,
    tool_protocol: :json
end

defmodule MyApp.ConversationSkill do
  use Spectre.Skill, id: :assistant, server: MyApp.ConversationServer

  flow :assistant do
    on :start, regex: ~r/^\/assistant\b/i
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.Stack, server: MyApp.RootServer
  skill MyApp.ConversationSkill, as: :assistant
end
~~~

Il root può delegare esplicitamente la route o il vero no-match a `:assistant`. **Non convertire un errore del router/classificatore in no-match silenzioso.** In modalità assistente aperto, la Skill attiva deve poter ricevere i turni successivi senza ripetere la classificazione di ogni input. Le route esplicite e gli interrupt del root devono comunque continuare a funzionare.

## 6. Gate obbligatorio: ownership della conversazione

**Prima di aggiungere una API di focus al core, provare il percorso 0.4 esistente** con `await_reply`/`await_input`, `handle_pending`, `route_current_input` e delega alla Skill.

Scenario reale obbligatorio:

1. Utente: "Analizza le fatture" -> il root delega a Directive; parte una missione.
2. Utente: "La fattura X e annullata" -> Directive riceve la correzione senza riclassificare il turno.
3. Utente: "Intanto spiegami l'INPS" -> la conversazione cede una volta al router/altro handler; l'analisi continua.
4. Utente: "Riprendi l'analisi" -> rientra nella missione precedente con identità e stato corretti.
5. Utente: "Si" a una domanda di missione -> **non** conferma una diversa Presentation GAM.

**Esito gate A:** se i pending esistenti gestiscono correttamente il dialogo, non cambiare il core.

**Esito gate B:** se i pending possono rappresentare solo una domanda specifica e il root non può indirizzare una conversazione aperta verso lo Skill Server, aggiungere **solo un ownership/handoff generico di input** nel runtime già esistente, versionato e correlato a Skill, session e generazione. Non introdurre `Spectre.Server.Component`, un nuovo router, un focus globale parallelo o una seconda mailbox. L'owner deve poter consumare l'input o cederlo al router **una sola volta**. Prima restano obbligatori ingress, interrupt globali e pending/consensi esplicitamente indirizzati.

Questa eventuale estensione non appartiene a Directive: deve funzionare anche con una Skill terza, senza dipendenze dal package.

## 7. Background, stato e recovery

La Skill Directive usa il proprio GenServer come tutte le Skill della 0.4: worker e pending locali, stesso GAM del root, checkpoint con namespace della Skill. I lavori cognitivi lenti girano in worker; il GenServer non resta bloccato da chiamate modello o tool.

- Distinguere **proprietà del dialogo** da **durata del lavoro**: cambiare argomento non cancella una missione in background e il risultato tardivo non cattura un'altra conversazione.
- Riprodurre il limite sperimentale dei **32 step** e i timeout ereditati; correggere solo il budget/lifetime generico che impedisce una missione prolungata, con limiti e scadenze espliciti, mai `:infinity` implicito.
- Persistenza RAM-only supportata; disco e Ledger opzionali tramite gli store esistenti. Non aggiungere uno store o journal Directive obbligatorio nel percorso AgentServer.
- Salvare stato corrente, richieste e correlazioni necessarie, non ogni Context e ogni snapshot storico. La dimensione serializzata del reducer ha oggi un limite di **900.000 byte**: misurare, segnalare e applicare retention/proiezione; nessuna promessa di conversazioni illimitate.
- Reset, cancel e stop rifiutano risultati obsoleti; una richiesta governata ammessa non si annulla per magia. Effetti incerti mantengono le loro Duties e richiedono riconciliazione.
- Il checkpoint ripristinato e vincolato al contratto, al digest dello Stack, alla Definition e alla sessione: non reinterpretare stato incompatibile dopo una modifica di tool o deployment.

## 8. Piano di implementazione incrementale (con prove prima di ogni passo)

### Fase 0 - Esperimento minimo e decisioni API (NESSUNA modifica definitiva)

**Partire da questi file:** `lib/spectre/stack/tools.ex`, `lib/spectre/server/tool.ex`, `lib/spectre/server/tool_compiler.ex`, `lib/spectre/server/runtime.ex`, `lib/spectre/server/skills.ex`, `docs/STACK_TOOLS.md`, `spectre_directive/lib/spectre/directive/server_tool.ex`.

- Scrivere un fixture di libreria terza con due operazioni: lettura cognitiva e invio governato, usando soltanto gli attuali `tools/1`/`effects/1`.
- Eseguire la stessa richiesta attraverso helper compilato e prototipo di `call_tool`; confrontare identità, command/outbox, correlazione, errori e GAM.
- Provare lo scenario di ownership della sezione 6 con root + Skill Server; documentare se serve davvero un handoff generico.
- Congelare shape dell'API pubblica e schema descriptor v2; test di backwards compatibility contro descriptor v1.

**Gate:** nessuna implementazione aggiuntiva prima di aver identificato il punto esatto di riuso in `Server.Tool` e il minimo delta per una conversazione libera.

### Fase 1 - Tool API nel core

- Pubblicare il behaviour tool adapter, il catalogo descrittivo compatibile e `available_tools`.
- Implementare `call_tool` come una sola porta verso la normalizzazione esistente; gli helper generati restano wrapper dello stesso percorso.
- Testare tool disponibili/non disponibili, collisioni, schema, scope Skill, digest incompatibili, errori, replay safe/never, effect binding mancante e rifiuto/consenso GAM.
- Scrivere un esempio end-to-end che crea un tool terzo **senza branch speciali nel core**.

**Gate:** una applicazione, una Skill e un chiamante che sceglie il tool a runtime ottengono lo stesso risultato e gli stessi controlli.

### Fase 2 - Driver Directive: conversazione aperta

**Partire da:** `spectre_directive/lib/spectre_directive/loop/engine.ex`, `lib/spectre/directive/server_tool.ex`, `docs/SPECTRE_0_4.md`.

- Riutilizzare il reducer, senza copiarne l'engine nel core.
- Implementare il driver automatico model -> parse -> tool -> result -> model -> response.
- Fornire `mode: :conversation`, il formato JSON come primo protocollo e Kinetic AL come adapter opzionale.
- Collegare le continuazioni della Skill ai risultati con tag univoci, senza chiedere all'app di scrivere il loop.
- Superare il gate ownership della sezione 6; aggiungere al core solo il minimo handoff generico se il test fallisce.

**Gate:** utente parla liberamente, usa un tool, corregge i dati, cambia argomento e torna, senza riclassificazione inutile o fuga di authority.

### Fase 3 - Missioni Directive e lavoro in background

- Integrare `:reason/:invoke/:question/:confirmation/:policy` nel driver, mantenendo le semantiche del reducer.
- Usare lo stesso Skill Server, i worker, pending e checkpoint del core.
- Correggere i budget/lifetime soltanto se i test dimostrano blocchi reali; coprire >32 step, worker crash, timeout, reset, restart e cancellation.
- Testare GAM approved, rejected, expired e outcome uncertain; non completare uno step senza evidenza dell'effetto.

**Gate:** una missione continua mentre un'altra conversazione riceve risposta; dopo restart non duplica un effetto.

### Fase 4 - Conformance, prestazioni e documentazione

- Integrare almeno Kinetic, Mnemonic e un tool di fatturazione terzo; gli altri satellite conservano le API attuali.
- Test con 1/10/100 agenti, conversazioni lunghe, più di 32 step, molte chiamate tool, RAM-only, disco e storage outage/recovery.
- Misurare memoria processi/ETS/binary, mailbox, checkpoint, worker, I/O e latenza; confrontare baseline 0.4, dopo warm-up e GC.
- Eseguire formatter, compile warnings-as-errors, suite completa, Credo strict, Dialyzer e docs; integration test real-model opzionale e chiaramente etichettato.
- Documentare ogni API come **implemented** o **proposed**; non aggiornare esempi e guide con API che non compilano.

**Gate:** gli esempi reali e la matrice di failure passano; nessuna dipendenza da Morph o da un nuovo runtime di componenti.

## 9. Matrice di regressione obbligatoria

| Scenario | Risultato atteso |
| --- | --- |
| Installable v1 esistente con helper privato | Compila ed esegue senza cambiamenti |
| Tool descriptor v2 e API generica | Stessa normalizzazione, identità, worker e result del vecchio helper |
| Due pacchetti con tool/operazioni omonimi | Collisione rilevata; nessuna esecuzione ambigua |
| Tool JSON scelto dal modello ma inesistente | Errore di risoluzione, nessuna MFA o nuovo atom |
| Tool visibile ma effetto non autorizzato | Rifiuto al confine host/GAM; nessun executor chiamato |
| Kinetic AL e JSON per la stessa azione | Stesso tool ref e stesso GAM path, differenze solo nel parsing |
| Free chat senza route dedicata per ogni domanda | Risposta e continuazione corrette senza classificazione per ogni turno posseduto |
| Interrupt, topic change, resume, pending consent | Nessun doppio routing; consenso non intercambiabile con una risposta missione |
| Due Skill Server che lavorano in parallelo | Stato, pending, results e checkpoint isolati; Domain GAM condiviso |
| Missione >32 step, timeout e worker crash | Limiti espliciti e recupero coerente, niente loop infinito |
| Reset, duplicate delivery, late result, code drift | Risultato stale scartato, nessuna modifica di stato non autorizzata |
| Effetto ambiguo dopo crash o perdita risposta | Nessun retry cieco e nessun falso `succeeded` |
| RAM-only, disco, Ledger e restore | Nessun obbligo di DB; nessun successo durevole inventato |

## 10. Documentazione e definizione di done

Aggiornare nel core: [STACK_TOOLS.md](STACK_TOOLS.md), [CUSTOM_STACK_TOOLS.md](CUSTOM_STACK_TOOLS.md), [STACK.md](STACK.md), [AGENT_SERVER.md](AGENT_SERVER.md), [SKILLS.md](SKILLS.md), [ROUTING.md](ROUTING.md), [SERVER_CALLBACKS.md](SERVER_CALLBACKS.md), [MANAGED_GAM.md](MANAGED_GAM.md). Aggiornare in Directive: README, `docs/SPECTRE_0_4.md`, documentazione del reducer e un esempio di chat libera e missione lunga. Mantenere l'ordine didattico **Stack -> Agent -> Server**.

Per ogni helper nuovo mostrare: chi lo chiama, argomenti e risultato, owner dello stato, tag/result, worker, permessi e recovery. Distinguere **tool dichiarato**, **tool visibile al modello**, **operazione ammessa** e **effetto osservato**.

La release e pronta solo quando:
1. un package esterno crea un tool ed e invocabile con la stessa API da Server, Skill e Directive;
2. Directive gestisce conversazione libera e missione in background sullo stesso runtime 0.4;
3. i casi di reset, input ownership, GAM e replay superano i test;
4. compatibilità e misure di memoria/latency sono documentate.

**Non previsti da questo piano:** implementazione di Morph, modifica del kernel GAM, pubblicazione Hex, tag o merge automatico. Commit del documento e sviluppo del codice sono azioni separate.
