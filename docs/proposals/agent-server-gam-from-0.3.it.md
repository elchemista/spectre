# Spectre: evoluzione della 0.3 con Agent dichiarativo, Server OTP e GAM

**Stato:** proposta architetturale di destinazione; implementazione 0.4 in corso nel branch `feature/agent-server-gam`. Vedi [stato verificato e limiti](implementation-status.it.md).

**Revisione:** separazione Agent/Server confermata dall'autore dopo le due revisioni di Claude Opus 5.5.

**Base applicativa:** Spectre 0.3.4, `origin/main` al commit `1059bd8`.

**Sorgente del kernel:** branch `feature/v0.4.0-governed-act-runtime`, commit `6906258`.

**Pilota:** `freelance`, commit esaminato `5b5e0d3`, lockfile originariamente su Spectre `9fad62e`.

Questa revisione sostituisce le precedenti proposte di authoring: il comportamento non vive nell'Agent e non viene descritto tramite una seconda DSL di policy. Le recensioni di Opus restano documenti storici separati; non tutte le sue raccomandazioni sono state adottate. Il binding rimane **Agent → Server**.

Sono stati esaminati codice e documentazione delle due linee, package e integrazione `freelance`. Non sono state eseguite le suite applicative per redigere la proposta. Il checkout di `freelance` contiene modifiche preesistenti estranee a questo lavoro. Gli esempi seguenti sono contratti proposti: la verifica sintattica non equivale a compilazione o esecuzione contro Spectre attuale.

Percorso di lettura: [architettura](#1-decisione-e-architettura), [contratto OTP](#5-contratto-otp-stato-e-avanzamento), [esempi](#7-esempi-di-authoring-e-integrazione-otp), [ciclo GAM](#8-gam-binding-evidence-consenso-ed-esecuzione), [piano di implementazione](#15-piano-di-implementazione-e-criteri-di-uscita), [DSL e opzioni](#appendice-a-dsl-e-opzioni).

## 1. Decisione e architettura

Evolvere la 0.3 conservando capacità, strategie ed ecosistema; estrarre il kernel GAM della 0.4. Sostituire Instance con un coordinamento OTP esplicito, senza due proprietari dello stato locale e senza due autorità per la stessa conseguenza.

| Componente | Responsabilità |
| --- | --- |
| `Spectre.Stack` | Installa package e risolve servizi, risorse e binding |
| `Spectre.Agent` | Dichiara classifier, Router, flow, intenti, Skill e metadata |
| `MyApp.SupportServer` con `use Spectre.Server` | Implementa comportamento, dialogo e callback OTP applicative |
| `Spectre.Server.Runtime` | È il modulo effettivo dell'unico GenServer locale; delega le callback applicative dopo la gestione del proprio protocollo |
| Reducer e dispatcher interni | Validano transizioni/comandi, coordinano continuazioni, worker e recovery |
| Router e servizi | Arbitraggio, classificazione, generazione, dataset, memoria e trasporto |
| GAM Domain | Evidence, mandati, ammissione, ledger, Acts, Attempts, Outcomes e Duty |

```text
Spectre.Stack ── binding e risorse ──┐
                                  v
MyApp.SupportAgent ── server: MyApp.SupportServer
  flow e intenti                  |
                                  v
                    Spectre.Server.Runtime
                    UN SOLO GenServer locale
                    ├─ stato locale e continuazioni
                    ├─ delega a SupportServer nello stesso processo
                    │    handle_flow / handle_pending / handle_result
                    │    handle_call / handle_cast / handle_info / ...
                    ├─ worker e sessioni stream supervisionati
                    └─ bridge GAM
                            |
                            v
                        GAM Domain
                    ammissione e ledger
                            |
                      broker / executor ── actor o servizio esterno
                            |
                  osservazioni ed esiti durabili
                            |
                   OutcomeDispatcher → ripresa
```

Agent e Stack sono definizioni, non processi attraversati in sequenza da ogni messaggio. `SupportServer` è il modulo di callback, non un secondo processo accanto al runtime. Il termine **AgentServer** nel piano indica questo GenServer vivo; la superficie di authoring si chiama `Spectre.Server`.

Il Domain può essere condiviso da più AgentServer. Avviare una nuova conversazione non crea un nuovo mandato o duplica un budget. Worker, stream e servizi hanno processi tecnici propri, ma non una copia autorevole della conversazione.

## 2. Dove interviene GAM

La distinzione centrale è fra **coordinamento locale**, **capacità cognitive configurate** e **conseguenze governate**. Essere dentro un callback del Server non trasforma automaticamente una chiamata in un Act.

| Passaggio | Responsabilità del runtime | Intervento GAM nel profilo concordato |
| --- | --- | --- |
| Normalizzare un messaggio, scegliere route | Identità dell'input, pipeline, arbitraggio | Nessuna ammissione per il solo routing |
| Classificare, calcolare embedding, consultare IntentDataset | Binding, timeout, correlazione, fallback | Fuori dall'ammissione ordinaria |
| Chiamare il modello per risposta o planning | Worker, stream, consolidamento | Cognizione ordinaria fuori dall'ammissione; non si crea un Act per token |
| Chiamare un actor per coordinamento interno | Messaggi OTP o helper asincrono | Nessuna cerimonia GAM aggiunta per il solo fatto di usare un actor |
| Preparare una proposta concreta | Catalogo chiuso, schema, binding e base della richiesta | Il bridge prepara il Candidate della classe governata |
| Presentare materiale per ottenere consenso governato | Dialogo nel Server, conservazione dell'attesa | Presentation e percorso di visualizzazione governato previsto dal kernel |
| Ricevere una risposta alla conferma | Collega input d'origine, destinatario e attesa | Evidence autenticata; rivalutazione sullo stato corrente |
| Eseguire cancellazione, pagamento o altra conseguenza governata | Coordina il risultato, non esegue direttamente | Decision, commit dell'Act, Attempt e rilascio della capacità secondo il kernel |
| Ricevere esiti o ricevute tardive | Riprende la continuazione corretta | Osservazione/esito registrato, eventuale Duty; nessun retry cieco |

Il manifesto non impone di governare ogni calcolo. La **HostProfile** deve però dichiarare cosa è incluso ed escluso. Se una specifica divulgazione di dati o un consumo è governato, il percorso cognitivo deve rispettare quel confine: chiamare una funzione `classify` non esenta dalla stessa conseguenza.

La superficie resta chiusa. Un'operazione esterna sconosciuta non diventa automaticamente non governata. Tutti i percorsi che producono la medesima conseguenza governata convergono sullo stesso confine, inclusi fallback, hook e messaggi da altri actor.

Il tracciamento di un turno, di una chiamata modello o di un callback può produrre telemetria e stato operativo locale. Questi eventi non sono automaticamente Evidence del ledger, Acts o contabilità GAM. Il kernel non viene ridisegnato né ridotto a una finestra di conferma.

### 2.1 Libertà del developer e garanzie reali

Il developer può implementare normale codice Elixir e usare il modello ad attori. Il runtime protegge i propri dati e messaggi dagli errori di composizione delle callback. Non offre una sandbox contro codice arbitrario eseguito nello stesso processo o nodo BEAM.

Per una conseguenza governata, l'executor è il percorso verso il servizio privilegiato. Se il codice applicativo dispone anche di credenziali o API che producono direttamente quell'effetto, esiste una via alternativa: macro, struct opache e nomi riservati non la eliminano. L'host stabilisce l'isolamento effettivo e dichiara le assunzioni del confine. Controlli statici e test aiutano a evitare errori ma non sostituiscono quell'isolamento.

## 3. Cosa si conserva e cosa cambia

| Area 0.3 | Si conserva | Cambia |
| --- | --- | --- |
| Stack | `install`, manifest, dipendenze, conflitti, risorse e DSL dei package | Binding separati dall'autorità GAM |
| Agent | Flow annidati, intenti, strategie, visibilità, classifier, Skill, pipeline | Le route dichiarano destinazioni; il comportamento va nel Server |
| Routing | Evidenze multiple, accordo, soglie, priorità, interrupt, custom pipeline | I/O coordinato senza nasconderlo nell'arbitratore |
| Classifier | Locale e LLM insieme; modello diverso dal responder; adapter custom | Nomi e binding più espliciti, accessibili anche dal Server |
| Dataset/training | Raccolta online, esempi senza vettore, indici, artifact, export/eval | Nome `IntentDataset`; `collect_intent`; raccolta distinta da verifica e training |
| Generazione/planner | Testo senza planning oppure proposte da catalogo chiuso | Funzione `generate` nel Server; proposte consolidate al confine comune |
| Policy | Conferma, rifiuto, chiarimenti, tentativi, risoluzione esterna | Codice Elixir nel Server e attese runtime; niente nuova DSL `policy` |
| Memoria | Recall e persistenza contestuale | Distinta da stato locale e ledger; errori non ripetono effetti |
| Streaming | Backpressure, sanitizzazione, epoch, cancellazione, terminali | Coordinato dal nuovo runtime; planning incrementale da completare |
| Beam/Pulse | Canali, identità, ack, comunicazione fra actor | Provenienza ed esiti distinti da semplici messaggi locali |
| Skill/Work/Vigil/Directive | Riutilizzo, scope, lavoro durevole e continuazioni | Stesso owner locale e stesso confine GAM per le operazioni migrate |
| Reflection/Morph | Proposte dichiarative e attivazione distinta | Nessuna eliminazione implicita durante il refactoring |

Si preservano le capacità, non ogni macro precedente nella nuova authoring. Le route legacy con `reason`, `act`, `run`, `action` e le vecchie policy richiedono un adapter di migrazione; non restano un secondo runtime autorevole.

## 4. Agent dichiarativo e Server applicativo

### 4.1 Agent

L'Agent risponde a «quali intenti riconosco, con quali strategie, in quali flow e con quale Server?». Non contiene il dialogo di conferma né il codice dell'effetto.

Il binding è dichiarato una sola volta: `use Spectre.Agent, server: MyApp.SupportServer`. Il Server riceve la Definition dal runtime. Non si aggiunge anche `agent:` al Server come secondo riferimento obbligatorio.

I flow annidati conservano la tassonomia 0.3. Per un flow semplice, il dispatch è `handle_flow({:support, :pricing}, input, ctx)`. Per un percorso annidato, il riferimento completo del flow deve essere conservato (per esempio `{[:support, :billing], :pricing}`); per Skill montate si conserva anche lo scope del mount. Non scegliere un callback usando soltanto un nome foglia ambiguo.

Le etichette già salvate in dataset e artifact non vengono convertite automaticamente da maiuscole a minuscole. Gli esempi nuovi usano atomi minuscoli per leggibilità; i codec di migrazione mantengono l'identità delle route.

### 4.2 Server

Il modulo applicativo usa `use Spectre.Server`: bootstrap, behaviour, funzioni di supporto e default, senza una DSL di dialogo o di esecuzione. Le funzioni `generate`, `classify`, `propose`, `respond`, `await_reply` e simili sono **funzioni Elixir ordinarie** che aggiungono comandi validabili al contesto.

Tre callback descrivono il percorso conversazionale:

| Callback | Significato | Ritorno proposto |
| --- | --- | --- |
| `handle_flow/3` | Esegue un intento scelto o gestisce `:unmatched` | `ctx` aggiornato con comandi |
| `handle_pending/3` | Interpreta input pertinente a un'attesa attiva | `ctx` aggiornato con comandi |
| `handle_result/3` | Riprende una richiesta, un'attesa o un'operazione | `ctx` aggiornato con comandi |

Le capacità cognitive restano sostituibili tramite i behaviour degli adapter. Non servono sette callback speciali per collegare capacità già installate. Se il developer vuole intercettare un input, un actor o un evento, dispone dei callback OTP e delle pipeline dichiarate. Il supporto legacy a handler pre-route resta distinto dal routing e dalle attese.

Un flow riconosciuto ma non implementato non viene degradato a «nessun match»: è un errore di binding/handler. Il default registra il problema e usa il percorso di errore configurato. `mix spectre.routes` e le verifiche di conformance dovranno mostrare destinazione e copertura; non si presume di provare staticamente pattern e guardie Elixir arbitrari.

### 4.3 Helper generati dallo Stack: `kinetic`, `mnemonic`, `lens`

La decisione di authoring è usare **funzioni helper generate dal framework dal
nome della tool registrata nello Stack**,
una sola parola: `kinetic`, `mnemonic`, `lens` e, dove esiste un'operazione
applicativa utile, `beam`, `pulse` o `directive`. Il package non deve esportare
funzioni omonime: il framework genera funzioni Elixir ordinarie con `ctx`
esplicito, collegate al binding registrato. Non si introduce una DSL di dialogo
o di esecuzione nel Server.

**Stato:** callback `Spectre.Stack.Installable.tools/1`, descrittori, helper,
dispatch e adapter dei nove package sono implementati. La guida operativa è
[STACK_TOOLS](../STACK_TOOLS.md); l'[integrazione eseguibile](../../integration/stack_tools/README.md)
mostra il contratto effettivo. Il [rapporto di verifica](stack-tools-0.4-verification.it.md)
distingue test reali e trasporti simulati.

Il nome pubblico dell'helper Kinetic è `kinetic`, non `plan_response`,
`prepare_actions` o `interpret`. Le API dirette della libreria, come
`SpectreKinetic.plan(kinetic_runtime, al)`, mantengono il proprio contratto.
Nel Server l'helper riceve la risposta del modello e prepara le azioni candidate:
non serve un secondo helper per scrivere a mano una singola istruzione AL e non
si introduce un nuovo oggetto `Plan` come risultato di Kinetic.

#### Registrazione, generazione e firme

Lo Stack installa configurazione, adapter e risorse e conserva descrittori
immutabili delle tool. Un descrittore specifica nome, operazioni disponibili,
funzione/adapter realmente esistente, iniezione del runtime, proiezioni e schemi,
versione del contratto e percorso cognitivo o governato. Non si deduce la
funzione da invocare dal solo nome del modulo.

Il punto di estensione è il behaviour esistente `Spectre.Stack.Installable`:
`tools(config)` riceve il risultato di `compile/3`. Le dichiarazioni sono
validate e conservate in `Installation.adapters[:tools]`; non si aggiunge un
secondo registro. La specifica normativa del piano fissa i contratti degli
adapter e prevale sulle firme schematiche illustrate qui sotto.

Per Kinetic, ad esempio, la registrazione può collegare la risposta completa del
modello all'adapter già esistente `Spectre.Kinetic.Planner.plan_response/3`;
`SpectreKinetic.plan/3` è invece l'API diretta della singola AL. Il framework
adatta gli argomenti al contratto registrato: non passa semplicemente il `ctx`
come primo argomento di una funzione che si aspetta un runtime Kinetic.

Il collegamento di compilazione è:

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server, tools: MyApp.AI

  # kinetic/3, mnemonic/3 e lens/3 vengono generati dalle registrazioni di AI.
end
```

`tools:` è un’opzione di compilazione: consente al compiler del Server di
conoscere i nomi e le arità da generare. Il binding Agent → Server rimane quello
già deciso. Non si cerca l'Agent con un registry globale di compilazione e non
si crea una dipendenza circolare Server → Agent. Un `before_compile` del Server
genera i wrapper locali dai descrittori dello Stack, senza import di inesistenti
funzioni `Spectre.Kinetic.kinetic/3` o analoghe.

Il corpo generato accoda una richiesta logica tramite la primitiva interna
`Spectre.Server.Tool.request/5`: contesto, nome, input, opzioni e descrittore
compilato con i relativi digest. L'applicazione usa soltanto l'helper a due o
tre argomenti; non costruisce quel descrittore a mano.
L'helper generato non invoca direttamente la libreria. Il runtime valida
capability e contratto sullo Stack effettivo di `ctx.agent`, quindi risolve
target e risorsa. Non usa silenziosamente una risorsa dello Stack di compilazione
per un Agent diverso. Binding mancanti/incompatibili e collisioni dei nomi o
delle arità con helper core, callback e funzioni applicative producono errori
espliciti; nessuna sovrascrittura implicita.

Ogni helper restituisce il `ctx` con la richiesta aggiunta. Il runtime acquisisce
la richiesta al ritorno del callback e soltanto allora avvia l'I/O; il valore
restituito dall'helper non è il risultato dello strumento.

| Helper | Input | Risultato tramite `on_result` |
| --- | --- | --- |
| `kinetic(ctx, response, opts)` | Risposta consolidata del modello, con output originale interno | Azioni candidate validate, in ordine, con operazione, argomenti e metadata di origine |
| `mnemonic(ctx, {:recall, query}, opts)` | Richiesta di memoria e scope risolto dal dispatch | Snapshot portabile dei ricordi e della loro provenienza |
| `mnemonic(ctx, {:remember, observation}, opts)` | Osservazione esplicita da memorizzare | Esito governato della scrittura, con identità stabile per correlazione; nessun retry cieco |
| `lens(ctx, {:look, tab_ref}, opts)` | Riferimento logico alla pagina | Vista portabile e provenienza della percezione |
| `lens(ctx, {:act, tab_ref, action}, opts)` | Operazione browser esplicita | Risultato del percorso previsto per quell'operazione; le conseguenze governate attraversano GAM |

Il nome del package rimane una parola; l'operazione resta visibile nel dato
passato a `mnemonic` e `lens`. Gli adapter espongono un insieme chiuso di
operazioni e schemi. Il modello non può fornire moduli, MFA o una scelta libera
fra «servizio cognitivo» ed «effetto»: il percorso è fissato dal binding fidato
dell'operazione.
Per Lens si risolve anche la sottooperazione concreta prima di scegliere quel
binding. Il contenuto di una pagina conserva la propria provenienza e rimane
marcato come materiale web non attendibile, distinto dagli input dell'utente.

#### Modello, Kinetic e callback del risultato

L'AL viene prodotto dal modello. Il punto naturale della chiamata `kinetic` è
quindi `handle_result`, dopo la generazione:

```elixir
defmodule MyApp.MailServer do
  use Spectre.Server, tools: MyApp.AI

  def handle_flow({:mail, :send}, _input, ctx) do
    generate(ctx, :mail, on_result: :mail_generated)
  end

  def handle_result(:mail_generated, {:generated, response}, ctx) do
    kinetic(ctx, response, on_result: :mail_actions)
  end

  # Questo esempio prepara le azioni e le conserva per il seguito del dialogo.
  def handle_result(:mail_actions, {:prepared, %{actions: proposals}}, ctx) do
    ctx
    |> assign(:mail_actions, proposals)
    |> respond("Azioni preparate.")
  end

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

Il risultato di `kinetic` usa un envelope distinto da `{:generated, ...}`.
Nel runtime attuale il default di quel formato può avviare le proposte:
riutilizzarlo per le azioni soltanto preparate introdurrebbe un'esecuzione
implicita. Il callback sceglie invece come proseguire: mostrare le azioni,
chiedere chiarimenti, richiamare un altro servizio o proporre le conseguenze a
GAM. Più azioni conservano ordine e identità; nessuna viene scartata per
ridurre il risultato a un solo elemento.

La generazione deve conservare un campo portabile interno `model_output`,
distinto da `text`, che rimane il testo pubblico ripulito. Kinetic estrae dal
primo l'AL, comprese catene ed errori di estrazione. Non legge
`response.inference.text`: quel campo tecnico può esistere live ma viene escluso
dal checkpoint attuale. Live e replay devono ricevere lo stesso input utile.
L'output originale non viene pubblicato automaticamente in reply, preview,
memoria conversazionale o proiezioni di monitoraggio. Eventuali persistenza e
retention seguono la configurazione dei dati interni dell'host.

La generazione semplice non deve eliminare l'unica copia dell'AL prima del
callback; il percorso integrato `planning: true` esistente resta distinto dal
percorso esplicito `handle_result -> kinetic`. Non si eseguono entrambi sullo
stesso risultato. Un helper fallisce con un risultato tipizzato quando la
risposta non è valida o il catalogo non risolve un'azione; non perde in silenzio
istruzioni malformate o ambigue.

#### Proprietà delle risorse e acquisizione

`ctx` contiene Agent, identità, input, routing, assigns, private, memoria,
attese e comandi. Il framework **non inserisce uno struct Kinetic inizializzato
in `ctx.assigns`**. L'adapter Kinetic usa il planner installato e il catalogo
chiuso dell'Agent. Le risorse persistenti che i package dichiarano, come Engine
Mnemonic e runtime Lens, vivono nella supervisione dello Stack. PID, encoder,
ETS, connessioni e Tab vivi rimangono nelle risorse o nei dati `private` volatili.

Il percorso comune è:

```text
helper(ctx, richiesta, on_result: tag)
  -> richiesta portabile acquisita nell'outbox
  -> worker risolve capability e risorsa installate
  -> adapter invoca l'operazione e proietta il risultato
  -> risultato portabile acquisito nell'inbox
  -> handle_result(tag, result, ctx)
```

Per un'operazione governata il dispatcher normalizza durevolmente la richiesta
nel percorso `propose` già esistente: ammissione GAM, eventuale consenso,
executor e funzione registrata, poi risultato acquisito. La funzione con
conseguenze non viene chiamata prima per chiedere consenso dopo. Un worker tool
generico non può aggiungere un percorso di retry che riesegue liberamente gli
effetti al restart. Versione/digest del binding partecipano al fingerprint della
richiesta; un replay non cambia silenziosamente il target registrato.

La proiezione è richiesta in entrambe le direzioni: **prima dell'outbox e prima
dell'inbox**. Un TabRef logico può ancora essere uno struct non ammesso dal
codec; l'helper usa la sua proiezione portabile prima di accodarlo. Packet,
Moment, View e Action dei package non vanno inseriti come struct grezzi nel
checkpoint. Il codec del package conserva i dati significativi e la versione,
senza conversioni superficiali o stringify silenzioso degli argomenti.
Convertire soltanto in `handle_result` arriva troppo tardi.

Le azioni Kinetic conservano provider, schema e origine dal catalogo chiuso del
dispatch. Per le scritture esplicite Mnemonic la chiave di idempotenza deriva
dal comando, non dal solo turno, che può contenere più scritture. Il recall
specifico di flow usa la route già risolta; non si applica al nuovo messaggio
il flow precedente del recall automatico. L'adapter evita la doppia ingestione
fra memoria automatica del turno e richieste esplicite `mnemonic`.

GAM conserva i propri contratti: generazione, classificazione e preparazione
cognitiva delle azioni non ricevono una nuova cerimonia di consenso. Le
conseguenze governate passano dai binding e dagli executor previsti; un risultato
Kinetic, una memoria o una pagina web non costituiscono consenso dell'utente.
La memoria di un effetto riuscito deriva dal suo Outcome verificato.

## 5. Contratto OTP, stato e avanzamento

### 5.1 Un vero GenServer, con delega

`Spectre.Server.Runtime` è il modulo che OTP invoca. Riceve per primo il protocollo interno e delega a `MyApp.SupportServer` i messaggi applicativi, **nello stesso processo**. `GenServer.call/3`, `cast/2`, `send/2`, monitor e task dell'applicazione restano utilizzabili.

Non si usa `defoverridable` per affidare all'applicazione l'intercettazione obbligatoria dei messaggi del framework. Un catch-all applicativo non deve richiedere `super` per far arrivare al runtime risultati, scadenze e ricevute interne. `super` rimane utile solo per delegare il comportamento applicativo predefinito.

L'avvio avviene tramite l'API Spectre con Agent e identità, oppure il relativo child spec. `GenServer.start_link(MyApp.SupportServer, ...)` non è l'API di avvio: il modulo callback effettivo è il runtime. `:sys.get_state` e l'introspezione mostrano lo stato del runtime; non si promette identità con un GenServer il cui modulo effettivo sia quello applicativo.

### 5.2 Contesto applicativo

| Parte del contesto | Significato | Trattamento del valore restituito |
| --- | --- | --- |
| `assigns` | Stato applicativo | Applicato come aggiornamento dell'applicazione |
| `identity` | Vista dell'identità autenticata e dello scope | Non riletta come autorità; il runtime conserva l'originale |
| `interaction`, input d'origine, route e motivo di fallback | Vista del dispatch corrente | Non sostituiscono correlazioni interne |
| Riepilogo dell'attesa | Materiale consultabile e id, senza potere esecutivo | Non riscrive direttamente l'attesa |
| Comandi e token del dispatch | Richieste preparate dalle funzioni di supporto | Validati prima di essere acquisiti dal runtime |

Il runtime conserva separatamente task ref, monitor, scadenze, continuazioni, riferimenti alle Presentation, revisioni e sessioni stream. Il Domain conserva lo stato governato. Modificare `ctx.identity` o `ctx.pending` non modifica questi proprietari; restituire un contesto di un vecchio dispatch è un errore esplicito, non un successo silenzioso.

Il token protegge dall'uso accidentale di contesti obsoleti, non da codice ostile nello stesso processo. Non serializzare nei checkpoint scope vivi, capability, segreti, PID o reference del runtime.

`assigns` può contenere dati effimeri utili a OTP. Il codec/checkpoint applicativo deve dichiarare la proiezione durevole: valori non portabili provocano errore se inclusi, non vengono convertiti o scartati silenziosamente. Dopo restart si ricreano monitor, client e attese tecniche tramite `init`/continuazioni.

### 5.3 Ritorni e comandi

Le callback OTP mantengono la forma OTP con `ctx` al posto dello stato applicativo:

- `handle_call`: `{:reply, value, ctx}` oppure reply differita con `{:noreply, ctx}`;
- `handle_cast`, `handle_info`, `handle_continue`: `{:noreply, ctx}`;
- forme `{:stop, reason, ctx}` e, dove consentito da OTP, `{:stop, reason, reply, ctx}`;
- azione finale `{:continue, value}`, `:hibernate` o timeout secondo il contratto descritto sotto.

Le callback conversazionali restituiscono invece il solo `ctx`. Gli helper restituiscono il contesto aggiornato: non mutano un processo in modo nascosto e non chiamano `GenServer.call(self(), ...)`.

Dopo il ritorno il runtime valida l'intero gruppo di comandi e il contesto, applica lo stato locale e registra i comandi da coordinare. La validazione del gruppo precede l'avvio dell'I/O; non implica una transazione atomica sugli effetti esterni. Se un comando è invalido, niente applicazione parziale delle richieste del dispatch e niente reply di successo al chiamante OTP.

Una reply OTP conferma al massimo l'acquisizione del comando quando l'operazione è asincrona; non prova che il modello abbia risposto o che l'effetto sia avvenuto. Per quel risultato si usa `handle_result`, oppure una reply differita esplicita. Un timeout del chiamante non annulla automaticamente un lavoro già acquisito.

Ogni ramo conversazionale indica come proseguire: generazione, proposta, attesa, risposta, re-routing o `no_response`. Un ritorno con soli assigns può essere valido per un evento di background, ma non deve lasciare un input in primo piano appeso senza un prossimo passo. Una risposta mentre esiste un'attesa può completare la risposta a quel messaggio mantenendo esplicitamente l'attesa aperta.

Questo risolve l'ambiguità originale fra `act` e `turn`: il ritorno del callback consegna al runtime il prossimo passo, senza una chiamata manuale a `turn`. La ripresa arriva tramite una continuazione correlata e `handle_result`/`handle_pending`. Non significa creare un nuovo messaggio utente o un Act GAM a ogni ritorno. Il vecchio `act(:understand)` si traduce in una richiesta di generazione/planning; un **Act GAM** mantiene invece il significato preciso di impegno governato del kernel.

### 5.4 Correlazione e messaggi da actor

Un comando in `handle_flow`/`handle_pending` eredita interazione e input d'origine. Un comando in `handle_info/cast/call` è di background salvo una correlazione esplicita registrata: non viene associato automaticamente all'ultima chat o conferma.

`call_actor(ctx, actor, request, timeout: ..., on_result: ...)` propone una chiamata in worker. `await_reply` registra una richiesta iniziata dall'applicazione e `resolve_await` la risolve per reference. Sono strumenti di coordinamento, non prove di identità del mittente.

Un messaggio Erlang non autentica chi lo ha mandato. Un tag o una reference da soli non diventano consenso, input utente autenticato o Outcome dell'executor. Le ricevute governate entrano dal Domain tramite executor/observer configurato; il runtime valida e consulta i riferimenti durabili prima della ripresa.

### 5.5 Proprietà dei messaggi

| Evento | Gestione |
| --- | --- |
| Risultato task/`:DOWN` relativo a una reference del runtime | Consumato dal runtime, con revisione/generazione verificate |
| Task o monitor creato dall'applicazione | Delegato al suo `handle_info` |
| Timer/stream con envelope interno | Verifica reference, operazione, generazione e stato atteso; sconosciuto/obsoleto scartato con diagnostica |
| Messaggio applicativo ordinario | Delegato; nessun avanzamento di un'operazione interna per sola somiglianza del payload |
| Notifica di Outcome | Risolta contro il Domain e la continuazione durabile; non accettata come record autorevole dal messaggio |

Il prefisso riservato serve a instradare, non ad autenticare. Duplicate e terminali obsoleti non avanzano il runtime. I messaggi tecnici nativi non posseduti dal runtime restano messaggi applicativi; il developer deve comunque correlare i propri protocolli.

Se il runtime usa `trap_exit`, documenta il comportamento: le uscite dei processi collegati dall'applicazione sono delegate, e il default mantiene l'arresto su uscita anomala salvo gestione esplicita dell'app. Non intercettare tutti i `:DOWN` o `:EXIT` indiscriminatamente.

### 5.6 Esecuzione e compatibilità OTP

Tutte le callback applicative, OTP e conversazionali, girano nel GenServer e devono restituire presto. Il lavoro lento usa i comandi/worker. Non spostare automaticamente `handle_call` in un task: cambierebbe ordering e semantica OTP. Una chiamata sincrona diretta a un altro actor è ammessa ma blocca il server e può causare un'attesa circolare; l'helper asincrono evita di occupare il processo mentre aspetta il risultato.

| Funzione OTP | Contratto da implementare e verificare |
| --- | --- |
| `init(arg, ctx)` | Estensione esplicita di Spectre: runtime inizializzato e stato ripristinato disponibili al callback. `{:ok, ctx}`, `:ignore`, `{:stop, reason}` e azioni iniziali supportate; l'avvio non inventa un'identità utente o un consenso |
| `handle_continue/2` | Continua applicativa distinta dalle continuazioni interne; entrambe passano dal medesimo owner |
| `:hibernate` | Supportata senza perdere timer, correlazioni o worker |
| Timeout intero / `:infinity` nei ritorni | Obiettivo: semantica OTP del processo, quindi anche il traffico interno conta e può interrompere l'attesa. Non equivale a inattività dell'utente. Se il primo adapter non supporta una forma, la rifiuta esplicitamente e la documenta; nessun divieto architetturale dedotto dalla review |
| Timer applicativi | `Process.send_after`/reference proprie per scadenze esplicite; `idle_timeout` dell'agente è un'altra policy |
| `terminate/2` | Cleanup applicativo e del runtime; non garantito su kill/crash del nodo. Nessun effetto governato nuovo nascosto nel cleanup |
| `code_change/3` | Delega con migrazione degli assigns e schema runtime separato. Supporto dichiarato solo dopo test di upgrade; altrimenti restart esplicito |
| `format_status` | Diagnostica con campi riservati rimossi dal framework; non esporre sigilli e credenziali nei crash report |

Il supporto effettivo deve avere una matrice di conformance; «GenServer estensibile» non equivale a promettere ogni opzione OTP prima di averla implementata. La nuova authoring accetta deliberatamente il compromesso: un callback applicativo lento rallenta anche il coordinamento del runtime.

## 6. Input, attese e fallback

### 6.1 Ordine del ciclo

```text
input normalizzato e autenticato dall'host
  → interruzioni esplicite ammesse
  → attesa in primo piano? handle_pending
       ├─ risposta pertinente → prosegui l'attesa
       ├─ chiarimento → rispondi mantenendola
       └─ nuovo argomento → sospendi, passa LO STESSO input al Router
  → handler pre-route compatibili, se applicabili
  → Router e sue richieste di evidenza
       ├─ route scelta → handle_flow({flow, intent}, input, ctx)
       └─ uscita senza route → handle_flow(:unmatched, input, ctx)
```

La precedenza fra interrupt, ownership pre-route e policy legacy richiede test di migrazione: la nuova proposta la rende esplicita invece di cambiarla incidentalmente. Un interrupt può annullare un'attesa locale; non annulla un effetto già avvenuto o una conseguenza già ammessa senza il percorso previsto.

Un input ricevuto durante classificazione/generazione entra in una coda limitata e viene elaborato al prossimo punto stabile; oltre il limite l'host riceve `:busy`. Le cancellazioni esplicite hanno un percorso dedicato. Lo steering che sostituisce uno stream è un'operazione esplicita con nuova generazione, non la reinterpretazione automatica di qualsiasi messaggio successivo. `call/cast/info` applicativi continuano a essere serviti mentre i worker lavorano.

Un contatore limita passi, inferenze, durata e re-routing. Tornare al Router non apre una seconda interazione per lo stesso input, non ripete recall/history e non duplica la raccolta del dataset.

### 6.2 Stato delle attese

Il runtime possiede un registro di attese e una sola attesa in primo piano per il contesto conversazionale. Ogni attesa conserva tipo, identità dell'interazione, continuazione, versione del codice, scadenza e riferimenti al materiale pertinente. Per il consenso aggiunge Candidate/digest, Presentation, show Act e destinatario.

Gli stati locali `foreground`, `suspended`, `expired`, `resolved` non sono nuove decisioni GAM. Il Server può richiederne la transizione tramite funzioni; non li riscrive modificando una mappa nel contesto.

Un cambio argomento sospende l'attesa. Un successivo «sì» non la conferma automaticamente. La ripresa esplicita riporta il materiale pertinente in primo piano e applica la policy di nuova visualizzazione; nel pilota si richiede una nuova visualizzazione dopo cambio argomento o restart. Una modifica materiale crea una nuova proposta/presentazione, non riusa il consenso precedente.

La funzione proposta `resume_pending(ctx, id)` richiede questa ripresa; non approva l'operazione. Un handler può chiamarla quando l'utente chiede esplicitamente di tornare alla cancellazione, dopo aver risolto senza ambiguità l'attesa pertinente. Identità e stato vengono nuovamente verificati dal runtime.

```text
utente: elimina il mio account
  → delete_account → proposta → presentazione → attesa A
utente: prima dimmi quanto costa il piano
  → handle_pending → nuovo argomento → sospendi A → pricing
utente: sì
  → nessuna approvazione automatica di A; normale riconoscimento/chiarimento
utente: torniamo alla cancellazione
  → ripresa esplicita di A → nuova visualizzazione del materiale
utente: confermo
  → risposta collegata a quella visualizzazione → GAM → effetto → esito
```

### 6.3 Fallback senza DSL di comportamento nell'Agent

`handle_flow(:unmatched, input, ctx)` è il punto pubblico per nessun match, ambiguità o impossibilità di completare il riconoscimento. `ctx.routing.reason` conserva la distinzione: `:no_match`, `:ambiguous`, `{:classifier_error, failure}`. Non usare `_` per far sparire un flow conosciuto ma non implementato.

L'intento legacy `:UNKNOWN`, se dichiarato, resta un intento selezionabile e ha un normale `handle_flow`; non è sinonimo di crash del provider. `understand` resta un prompt/comportamento del Server, disponibile anche per planning.

| Evento | Percorso |
| --- | --- |
| Miss del dataset | Continua la raccolta di evidenze; non è errore |
| Timeout/crash locale o dell'encoder | Evidenza indisponibile con causa conservata; arbitratore continua secondo policy |
| Conflitto/evidenza debole | Classifier LLM o chiarimento secondo arbitratore |
| Errore del modello | Fallback configurato per quello scopo; tentativi e causa primaria conservati |
| Nessuna route / ambiguità residua | `handle_flow(:unmatched, ...)` con motivo distinto |
| Generazione fallita dopo i fallback | `handle_result(tag, {:error, failure}, ctx)` |
| Consenso negato/scaduto | Evento del workflow, distinto dalla Decision del kernel |
| GAM refused/undecidable/unknown_class | Esito tipizzato; nessun fallback che conceda potere |

La trasformazione dell'arbitratore custom in una richiesta sospendibile è un cambio di contratto da adattare e testare, non un refactoring trasparente per ogni plugin.

## 7. Esempi di authoring e integrazione OTP

### 7.1 Stack e Agent

Lo Stack mantiene i package e le loro DSL. Il seguente frammento illustrativo conserva la forma della configurazione Prism 0.3; profili, credenziali e artifact effettivi restano configurazione dell'host. I rename interni dei package non sono prerequisiti del nuovo runtime.

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Prism do
    provider :openrouter,
      models: [fast: "classifier-model", balanced: "response-model"],
      classifier: :fast

    purpose(:response_generation, prefer: :balanced)
    default(:balanced)
  end

  install Spectre.Kinetic
  install Spectre.Mnemonic
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent,
    stack: MyApp.AI,
    server: MyApp.SupportServer

  # Override facoltativi dei binding dello Stack.
  classifier :local, MyApp.LocalClassifier,
    artifact_dir: "priv/spectre/intents"

  classifier :llm, MyApp.IntentModel, timeout: 8_000

  router strategies: [
    :regex, :intent_dataset, :embedding,
    :local_classifier, :llm_classifier
  ]

  flow :support, defaults: [collect_intent: true] do
    on :pricing,
      semantic_examples: ["Quanto costa?", "Quali sono i prezzi?"]

    on :delete_account,
      regex: ~r/^elimina il mio account$/i,
      collect_intent: false,
      protected: true
  end
end
```

Qui non esistono handler nel corpo delle route. L'Agent non contiene `prompt_root`, `policy` o logica di esecuzione. Il Router può usare LLM anche per riconoscere un intento protetto; riconoscimento non equivale a esecuzione.

### 7.2 Server: flow, dialogo e risultati

Le funzioni e i tipi delle callback in questo esempio sono API proposte. Gli executor, la Surface e i mandati vanno configurati dall'host come descritto nella sezione 8; `actions:` collega il catalogo/provider, non autorizza l'esecuzione.

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server,
    prompt_root: "priv/support/prompts",
    actions: MyApp.AccountActions

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx) do
    generate(ctx, :pricing, on_result: :pricing)
  end

  def handle_flow({:support, :delete_account}, _input, ctx) do
    propose(ctx, :delete_my_account,
      %{account_id: ctx.identity.account_id},
      confirmation: [
        template: :confirm_delete_account,
        interpreter: {__MODULE__, :interpret_confirmation}
      ],
      on_result: :deleted)
  end

  def handle_flow(:unmatched, input, ctx) do
    case ctx.routing.reason do
      :ambiguous ->
        respond(ctx, :clarify_intent)

      :no_match ->
        generate(ctx, :understand,
          input: input,
          planning: true,
          stream: true,
          preview: :auto,
          on_result: :understood)

      {:classifier_error, _failure} ->
        respond(ctx, :recognition_unavailable)
    end
  end

  @impl true
  def handle_pending(%{kind: :consent} = pending, input, ctx) do
    classify(ctx, input,
      context: pending,
      choices: [:confirm, :reject, :clarify, :new_topic, :ambiguous],
      on_result: {:confirmation, pending.id})
  end

  def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

  @impl true
  def handle_result(:pricing, {:generated, response}, ctx),
    do: respond(ctx, response.text)

  def handle_result(:pricing, {:error, _failure}, ctx),
    do: respond(ctx, :pricing_unavailable)

  def handle_result({:confirmation, id}, {:classified, :confirm}, ctx),
    do: confirm_pending(ctx, id)

  def handle_result({:confirmation, id}, {:classified, :reject}, ctx),
    do: reject_pending(ctx, id)

  def handle_result({:confirmation, id}, {:classified, :clarify}, ctx),
    do: explain_pending(ctx, id)

  def handle_result({:confirmation, id}, {:classified, :new_topic}, ctx),
    do: route_current_input(ctx, suspend: id)

  def handle_result({:confirmation, id}, _uncertain_result, ctx),
    do: explain_pending(ctx, id)

  def handle_result(:deleted, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, :account_deleted)

  def handle_result(:deleted, {:governed, %{outcome: %{status: :ambiguous}}}, ctx),
    do: respond(ctx, :deletion_under_verification)

  def handle_result(:deleted, {:governed, %{decision: %{outcome: :refused}}}, ctx),
    do: respond(ctx, :deletion_not_permitted)

  def handle_result(:deleted, {:governed, %{decision: %{outcome: :undecidable}}}, ctx),
    do: respond(ctx, :deletion_cannot_be_determined)

  def handle_result(:deleted, {:governed, %{decision: %{outcome: :unknown_class}}}, ctx),
    do: respond(ctx, :operation_not_supported)

  def handle_result(:deleted, {:consent, :rejected}, ctx),
    do: respond(ctx, :deletion_cancelled)

  def handle_result(:deleted, {:consent, :expired}, ctx),
    do: respond(ctx, :confirmation_expired)

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  # Funzione Elixir ordinaria, collegata come interprete del dialogo.
  # La scelta conservativa dell'esempio non è una legge universale di GAM.
  def interpret_confirmation(input, _presentation) do
    case input.text |> String.trim() |> String.downcase() do
      text when text in ["sì", "si", "confermo"] -> :confirm
      text when text in ["no", "annulla"] -> :reject
      _ -> :unclear
    end
  end
end
```

`confirm_pending` non usa la sola label del modello. Riprende l'input autenticato d'origine della richiesta `classify`, consulta l'interprete dichiarato per quell'attesa e applica i controlli di provenienza, materiale, destinatario, freschezza e visualizzazione. Nell'esempio, una label `:confirm` per un testo non accettato dall'interprete porta a chiarimento, non a consenso.

L'interprete può essere un'altra implementazione configurata, anche con elaborazione asincrona quando necessaria; non si impone una regex come legge GAM. Il suo ruolo è interpretare il messaggio originale entro un contratto dichiarato. Il runtime/Ingress costruiscono la prova autenticata e il kernel decide. Un testo del modello, una riga nel dataset o una mappa `approved: true` non sostituiscono quel percorso. Anche rifiuto e cambio argomento possono essere personalizzati; non si cancellano intenzioni dell'utente in modo silenzioso per un'etichetta dubbia.

`explain_pending` prepara una spiegazione legata al materiale dell'attesa e mantiene il dialogo aperto. Se la risposta sollecita di nuovo consenso, segue il percorso di Presentation/show pertinente; non è una consegna ordinaria usata per aggirare la presentazione. Se cambia il materiale, si prepara una nuova proposta.

Per `:understood` il default di `handle_result` gestisce la generazione consolidata: mostra il testo compatibile e inoltra le eventuali proposte al normale percorso `propose`, conservando ordine/dipendenze. Il developer può personalizzarlo. Zero proposte non inventa un'azione; una risposta che dipende dal successo dell'effetto attende il relativo esito. Gli esiti non mostrati nell'esempio restano tipizzati nel default, mai convertiti in successo.

### 7.3 OTP ordinario e altro actor

Queste clausole possono vivere nello stesso Server. I messaggi di prezzo dell'esempio sono coordinamento interno, fuori dalla superficie governata del pilota.

```elixir
@impl true
def handle_call(:price_version, _from, ctx) do
  {:reply, Map.get(ctx.assigns, :price_version), ctx}
end

@impl true
def handle_cast(:refresh_prices, ctx) do
  GenServer.cast(MyApp.PricingActor, :refresh)
  {:noreply, ctx}
end

@impl true
def handle_info({:price_list_changed, version}, ctx) do
  {:noreply, assign(ctx, :price_version, version)}
end

def handle_info(message, ctx), do: super(message, ctx)
```

Una variante del percorso pricing richiede un preventivo senza bloccare il server:

```elixir
def handle_flow({:support, :pricing}, _input, ctx) do
  call_actor(ctx, MyApp.PricingActor,
    {:quote, ctx.identity.account_id},
    timeout: 3_000,
    on_result: :quote)
end

def handle_result(:quote, {:ok, quote}, ctx) do
  generate(ctx, :pricing, assigns: %{quote: quote}, on_result: :pricing)
end

def handle_result(:quote, {:error, :timeout}, ctx) do
  respond(ctx, :pricing_unavailable)
end
```

`call_actor` esegue la chiamata in un worker e conserva interazione/generazione. Timeout e risposta tardiva non riscrivono una conversazione successiva. Per un protocollo a messaggi già esistente si possono invece usare reference proprie e `await_reply`/`resolve_await`, con scadenze e risoluzione idempotente. La reference correla, non autentica il mittente.

### 7.4 Intenzione sospesa, timeout applicativo e traccia GAM

Il Server applicativo controlla la policy di abbandono con normali callback OTP.
Dopo il cambio di argomento può conservare l'intenzione sospesa, fissarne la
scadenza e continuare con il medesimo input sul Router:

```elixir
def handle_result({:pending_choice, id}, {:classified, :new_topic}, ctx) do
  ctx
  |> close_pending_after(id, 60_000,
    reason: :topic_changed,
    policy_ref: "support:abandoned-confirmation")
  |> route_current_input(suspend: id)
end
```

Le operazioni di lifecycle sono una barriera ordinata: la scadenza è acquisita
prima della sospensione e del nuovo routing. Identità, revisione e generazione
della scadenza impediscono a un vecchio timer di chiudere una nuova attesa.
Un riavvio conserva la deadline assoluta; una nuova presentazione invalida la
vecchia scadenza. `cancel_pending_close` revoca soltanto la scadenza applicativa,
non la validità temporale del consenso GAM.

Il developer può scegliere `timer: :application`: la stessa deadline viene
registrata, mentre l'applicazione arma un normale `Process.send_after/3` dopo
l'acquisizione. Il proprio `handle_info/2` richiede la chiusura con gli stessi
guard, invece di modificare direttamente lo stato del protocollo:

```elixir
def handle_info({:intent_idle, id, revision, schedule_id}, ctx) do
  {:noreply,
   close_pending(ctx, id,
     if_revision: revision,
     if_schedule: schedule_id,
     reason: :idle_timeout)}
end
```

`get_pending(ctx, id)` permette di leggere anche un'attesa sospesa.
`ctx.private` contiene dati applicativi locali, quali ref di timer, monitor e
PID: `put_private`, `get_private` e `delete_private` li gestiscono senza
includerli nei checkpoint o nei servizi cognitivi. Gli assigns rimangono la
proiezione applicativa durabile. L'applicazione che possiede un timer nativo
ne cura il riarmo dopo il restart leggendo la deadline registrata.

GAM conserva i passaggi rilevanti attraverso il proprio Ingress ed Evidence:
richiesta della policy, acquisizione o mancata applicazione della transizione,
causa, deadline, intenzione, revisione e riferimenti Candidate/show. `requested`
è una richiesta; `applied` viene riportato soltanto dopo l'acquisizione locale;
`ignored` spiega un timer obsoleto o una transizione superata. Checkpoint e outbox
del report vengono acquisiti insieme; un errore di registrazione lascia lavoro
di riconciliazione, non un successo inventato. Il nuovo percorso richiede un
checkpoint e il collegamento esplicito dell'host al lifecycle Ingress.

La chiusura dell'attesa non produce consenso o rifiuto dell'utente, non annulla
un Act e non dispone una Duty. Un'operazione `resolving` o `uncertain` mantiene
fatti e correlazioni. Il timeout è un'osservazione dell'host, non una prova di
assenza dell'effetto. Classificazione e lookup ordinari mantengono il confine
cognitivo già definito: registrazione dei fatti e ammissione di conseguenze
restano responsabilità distinte del kernel originale.

Gli esempi operativi e il contratto del callback sono in
[Lifecycle delle attese](../PENDING_LIFECYCLE.md).

## 8. GAM: binding, Evidence, consenso ed esecuzione

### 8.1 Setup dell'host, non codice nascosto nella route

Il bootstrap GAM esistente deve fornire Domain/ledger, genesis e mandati, HostProfile, Surface, executor/broker, Ingress e observer. Non viene generato implicitamente da `protected: true` o da `actions:`.

La seguente è una **vista schematica del contratto**, non una nuova API di bootstrap già disponibile:

```text
operazione applicativa: delete_my_account
  classe della Surface: account.anonymize
  schema degli argomenti: account_id
  executor registrato: MyApp.AccountExecutor
  risorsa autorizzabile: account identificato nel Candidate
  consenso: richiesto dal contratto del pilota
  autorità: mandati reali dell'host, valutati dal Domain

presentazione del consenso:
  materiale e destinatario legati alla proposta
  visualizzazione: classe/contratto di show della Surface
  executor di delivery: MyApp.PresentationDelivery
  prova: Outcome del contratto di visualizzazione, non semplice enqueue

infrastruttura cognitiva del pilota:
  classifier / embedding / generazione / dataset: binding dello Stack
  ammissione ordinaria: fuori superficie, con esclusioni dichiarate
```

La classe `account.anonymize` è un nome applicativo illustrativo da registrare, non una classe magica già disponibile. Il binding deve essere validato contro la Surface reale. Non si presume che un solo mandato autorizzi anche ogni delivery o divulgazione: ciascuna operazione governata verifica il proprio contratto.

L'executor compie l'effetto reale (in `freelance`, `Accounts.anonymize_user_data`). Se un actor esegue materialmente l'operazione, l'executor parla a quell'actor attraverso il confine previsto. Una chiamata diretta del Server allo stesso actor privilegiato sarebbe un percorso alternativo, non «semplice coordinamento».

### 8.2 Significato di `protected: true`

È un requisito del percorso conversazionale: il runtime non può rilasciare una conseguenza proposta da quel percorso saltando il processo di conferma richiesto. Può comunque chiedere dati, spiegare, rifiutare, interrompere o rispondere senza produrre effetti. Non obbliga ogni ramo a eseguire un'azione.

Il flag non sceglie la classe GAM, non autentica l'utente e non sostituisce i requisiti dell'operazione concreta. Una proposta di `delete_my_account` generata da `understand` mantiene gli stessi requisiti del binding anche se la route di origine non era protetta. Il Server non può indebolire i requisiti dell'host passando opzioni meno restrittive.

Non si deducono dal flag un divieto di classificazione LLM o un diverso algoritmo di match. Raccolta nel dataset e protezione restano opzioni distinte; il percorso standard conserva i controlli di eleggibilità e la configurazione esplicita dell'esempio disabilita la raccolta per la cancellazione.

### 8.3 Ingress e prove

Il runtime mantiene un input envelope autenticato, immutabile per identità e correlazione. La vista `ctx.identity` viene da lì, non dagli assigns applicativi. Per ogni proposta governata il bridge seleziona e registra le Evidence necessarie alla decisione, incluse derivazioni/provenienza quando il contenuto deriva da più input.

La politica iniziale è registrare nel ledger la base pertinente alle proposte governate e le risposte alle Presentation, non tutta la chat indistintamente. Questo non permette di omettere informazioni materialmente necessarie o vincoli derivati dalle fonti. Un riferimento a un messaggio nel checkpoint locale non è da solo una Evidence autorevole.

La 0.4 implementa ingress, Evidence durabili e `Mind.Turn` sigillati. L'estrazione deve riusare/adattare quel percorso e le sue verifiche: il callback applicativo non costruisce sigilli o scrive il ledger. Le dipendenze da `Mind`, `Agent.Verification`, Scope e Definition fanno parte dell'analisi di estrazione, non sono considerate già risolte.

### 8.4 Sequenza di cancellazione

1. Input autenticato → classificazione → `handle_flow({:support, :delete_account}, ...)`.
2. `propose` prepara la richiesta concreta con l'account derivato dall'identità e la continuazione `:deleted`.
3. Il bridge valida catalogo, schema, classe, scope e base; registra le Evidence pertinenti. Dati mancanti tornano al dialogo senza eseguire.
4. Se il contratto richiede consenso, prepara materiale immutabile e Presentation. Una richiesta di consenso non sana un mandato assente o altri vincoli insoddisfatti.
5. La visualizzazione attraversa lo show Act del kernel e il relativo executor. Soltanto un esito valido di visualizzazione consente di collegare una risposta come consenso a quel materiale.
6. Il runtime conserva l'attesa e consegna gli input successivi a `handle_pending` secondo la precedenza definita.
7. `confirm_pending` risolve l'input d'origine della continuazione, non «l'ultimo messaggio». Verifica recipient, attesa attiva, materiale, tempi, mancato consumo precedente e interpretazione dichiarata; l'Ingress registra la response Evidence.
8. GAM rivaluta il Candidate sullo stato corrente. Solo l'ammissione consente il commit dell'Act e il successivo rilascio della capacità. Per l'effetto esterno l'Attempt precede il confine dell'executor.
9. L'executor compie l'anonimizzazione reale. Il Domain conserva osservazioni, Outcome ed eventuale Duty.
10. La continuazione riceve il risultato attraverso `handle_result`; una risposta di successo richiede un Outcome che lo supporti.

Il grafo del consenso riusa il contratto 0.4: **Presentation → show Act → Outcome di visualizzazione riuscita → response Evidence autenticata**. Un rifiuto dell'utente, una mancata risposta e un rifiuto del kernel non sono lo stesso evento.

### 8.5 Dialogo libero, materiale vincolato

Il Server può usare regex, classifier, embedding o altre capacità per capire se l'utente sta confermando, facendo una domanda o cambiando argomento. Questo lavoro cognitivo non diventa un consenso del modello.

Il materiale può essere preparato anche con un modello se il contratto dell'host lo consente: deve essere finalizzato, validato, legato alla proposta e presentato attraverso il percorso corretto prima di accettare una risposta. I template deterministici sono una scelta semplice per il pilota, non un obbligo generale aggiunto al manifesto.

Non si usa `respond` ordinario per sostenere retroattivamente che una Presentation è stata mostrata. Le spiegazioni che modificano destinatario, dati, costo, scopo o altri elementi materiali richiedono nuovo materiale; le riprese applicano la policy di visualizzazione corrente. L'eventuale approvazione esterna arriva da una sorgente autenticata riferita all'attesa, non da un cast generico con `approved: true`.

## 9. Risultati, ripresa e recovery

### 9.1 Non rinominare le leggi attraverso un unico `status`

La facciata conversazionale proposta usa envelope separati. I record GAM mantengono i valori verificati nella baseline 0.4:

| Dato | Valori / significato |
| --- | --- |
| `Decision.outcome` | `:admitted`, `:refused`, `:undecidable`, `:unknown_class` |
| `Outcome.status` | `:succeeded`, `:failed`, `:definitive_no_effect`, `:ambiguous` |
| Stato locale dell'interazione | Attesa, coda, sospensione, generazione; non nuovi valori di Outcome |
| Consenso nel workflow | Rifiutato, scaduto, sostituito; non automaticamente una Decision GAM |
| `outcome: nil` | Nessun Outcome disponibile; non prova di fallimento o assenza dell'effetto |

`{:governed, result}` conserva Decision, riferimenti di Act/Attempt, Outcome eventuale e provenienza; non nasconde risultato primario e fallback governato quando presenti. È un envelope proposto, non una modifica dei record del kernel. I vecchi `:done`/`:unclear` appartengono ad altre facciate e vanno mappati esplicitamente, non presentati come valori di `Outcome.status`.

`on_result` identifica la continuazione per risultati tipizzati, non solo il successo. Le osservazioni successive hanno identità/revisione proprie; una prima notifica senza Outcome non autorizza il replay. Il default non converte un caso ignoto in risposta di successo e non confonde indecidibilità con divieto.

### 9.2 Dispatcher durabile

Un servizio `OutcomeDispatcher` mantiene una relazione durabile fra operazione/Act, identità locale, versione del Server e continuazione. Quando arriva un aggiornamento verifica il Domain, ritrova o riavvia l'AgentServer e consegna l'evento pertinente.

Non si promette esecuzione exactly-once di callback o del mondo esterno. Il trasporto può consegnare più volte; event id, inbox/checkpoint e deduplicazione rendono idempotente l'avanzamento acquisito. Un crash durante `handle_result` può richiedere una nuova esecuzione del callback: per questo gli effetti governati sono comandi idempotentemente correlati, non I/O nascosto nel callback.

La perdita della continuazione non inventa un esito: l'evento resta riconciliabile, con handler/default per risultato orfano e diagnostica. Il successo già registrato non viene cancellato per consentire un nuovo tentativo. Le ricevute tardive restano registrabili anche dopo revoca senza ripristinare autorità.

### 9.3 Persistenza distinta

1. Checkpoint locale: assigns portabili, interazioni, attese, correlazioni e versione del codice.
2. Domain: ledger, proiezione, autorità ed esiti governati.
3. Servizi/host: IntentDataset, memoria, chat, outbox e payload.

Un checkpoint non ricrea capability o mandati. Monitor/reference tecniche sono ricreati; un'attesa verso un actor sopravvive soltanto se il protocollo usa un'identità durevole e una riconciliazione dichiarata. Non serializzare una `make_ref()` e aspettarsi che identifichi un actor dopo restart.

Per i checkpoint 0.3 distinguere stato inattivo, attese locali, policy pendenti, effetti incerti e stream/Work attivi. Non importare `approved` come consenso verificato e non costruire Acts retroattivamente autorizzati. La prima slice può richiedere restart pulito; la migrazione dei casi pendenti resta un requisito di rollout prima della sostituzione generale.

## 10. Streaming, delivery e hook

### 10.1 Raccolta delle proposte

```text
generate(ctx, ..., planning: true, stream: true)
  → worker/sessione stream: accumulo e sanitizzazione
  → eventuale testo pubblico provvisorio al consumer
  → terminale del provider e assemblaggio completo
  → validazione del catalogo/schema e consolidamento
  → handle_result(tag, {:generated, generation}, ctx)
  → proposte attraverso propose / GAM
  → esiti e continuazioni
```

Il runtime mantiene stato logico, generazione e correlazione; la sessione gestisce buffer, parser e backpressure. Non tutti i token passano dal mailbox del GenServer. I callback OTP applicativi non possono trasformare un terminale arbitrario in completamento di uno stream del runtime.

Una bozza può contenere testo e zero, una o più proposte. I frammenti non sono eseguibili. Il consolidamento richiede terminale valido, schema/catalogo e generazione corrente; duplicati non risottomettono l'operazione. Più proposte non implicano transazione atomica: ordine e dipendenze restano espliciti.

### 10.2 Preview

`stream: true` abilita la generazione incrementale; `preview: :auto | :required | :off` decide l'esposizione provvisoria. `:auto` mostra solo contenuto compatibile e filtrato, `:required` fallisce esplicitamente se mancano capacità necessarie, `:off` raccoglie internamente e consegna il finale. Il default della generazione rimane non streaming finché non richiesto/configurato.

L'anteprima può mostrare testo pubblico o una rappresentazione pubblica di una proposta, non ragionamento interno, AL o payload di controllo. È una divulgazione reale: il risultato finale non può renderla retroattivamente sicura. Materiale dichiarato governato rispetta il suo confine anche in preview. I delta non sono automaticamente una Presentation valida per ottenere consenso.

Il consumer conosce id della bozza e completamento/sostituzione/errore; non ricostruisce il risultato canonico concatenando token. Sui canali senza aggiornamenti serve una presentazione compatibile o consegna finale unica.

### 10.3 Limiti da implementare, non funzionalità eliminate

La 0.3 supporta inizialmente streaming testuale senza planning. Kinetic esaminato dichiara `incremental_cleaner?() == false`: non certifica sicuri chunk di testo misto AL. Per quel percorso si trattiene il contenuto fino al parsing completo. Lo streaming con planning e preview pubblica richiede un adapter/protocollo incrementale verificato e resta un requisito esplicito del piano, anche se successivo alla prima slice.

Nessuna simulazione di stream suddividendo una risposta sincrona già completa. Batch e streaming dello stesso output devono produrre proposte e continuazioni equivalenti. Non serve una nuova DSL `handle_stream`; progressi pubblici possono essere notifiche documentate al consumer o al Server, senza consentire di riscrivere lo stato tecnico della sessione.

Un fallback di modello apre una nuova generazione: non unisce i suoi chunk alla precedente. Se una preview era già visibile, la UI riceve interruzione/sostituzione. Fermare la UI o il trasporto non dimostra che il provider remoto abbia cessato il lavoro né annulla un effetto già ammesso.

### 10.4 Delivery e hook

Il runtime distingue preparazione, enqueue, tentativo e conferma secondo il contratto del canale. Un enqueue non prova visualizzazione o consegna. Per il consenso si usa il contratto di show/Outcome del Domain, non l'etichetta locale di un evento.

Beam, outbox e host conservano le rispettive responsabilità. I retry di consegne governate attraversano il contratto previsto; non si aggiunge un retry libero nell'outbox. Gli hook osservativi restano possibili. Un hook che cancella dati o produce un'altra conseguenza governata prepara una nuova proposta correlata; la scritta `after_delivery` non gli concede privilegi.

Il dialogo resta nel Server. Guardie e precondizioni del servizio che devono valere al momento dell'effetto vanno integrate nell'ammissione/executor secondo il loro contratto, senza spostarle tutte prima della richiesta di consenso. Una guardia tardiva che impedisce l'esecuzione mantiene fatti già registrati e il corretto esito di mancato tentativo/effetto.

## 11. IntentDataset, apprendimento online e ricerca semantica

Il nome pubblico proposto è **`Spectre.IntentDataset`**. Raccoglie esempi di testo associati a intenti: serve al riconoscimento durante il routing e alla preparazione dei classificatori. Il nome evita di confondere questa capacità con una cache di risposte, di risultati delle azioni o di autorizzazioni. Training, esempi online e ricerca semantica rimangono funzionalità centrali del framework.

### 11.1 Dati e indici hanno ruoli diversi

| Elemento | Contenuto e uso |
| --- | --- |
| Esempio raccolto | Testo, etichetta proposta, provenienza e scope; può non avere embedding e può essere ancora da validare |
| Esempio ammesso al routing | Etichetta valida, provenienza e requisiti di utilizzo soddisfatti; disponibile per lookup esatto |
| Esempio con embedding compatibile | Può contribuire anche alla ricerca per similarità tramite Vettore |
| Indice esatto | Proiezione sul testo normalizzato degli esempi ammessi; non calcola embedding della query |
| Indice semantico | Proiezione Vettore dei soli esempi ammessi con vettori validi e compatibili |
| Artifact del classifier | Modello/centroidi prodotti dal training; distinto dagli esempi e dagli indici di lookup |

Sono proiezioni dello stesso dataset, non tre copie indipendenti degli esempi. Un esempio senza embedding è utile e va conservato; non deve però apparire come candidato vettoriale. Un esempio appena raccolto non è automaticamente ammesso al routing soltanto perché è stato salvato. Stato di validazione dell'etichetta e disponibilità del vettore sono due proprietà indipendenti.

Il servizio conserva id, testo normalizzato e originale secondo la policy dati, etichetta, provenienza, scope, revisione e stato di ammissione. L'embedding è facoltativo nel dataset, obbligatorio nell'indice semantico, e porta il riferimento al profilo dell'encoder. Il lookup restituisce **evidenza di intento**, mai una risposta già pronta o un'azione già autorizzata. Il Router applica sempre visibilità, soglie e arbitraggio correnti.

Esempio: `"quanto costa?" -> :PRICING` può essere riconosciuto per testo esatto senza invocare l'encoder. `"qual è il prezzo?"` richiede invece una rappresentazione semantica compatibile per essere confrontato con quell'esempio. Avere un embedding nel record non obbliga a ricalcolarlo per un match esatto.

### 11.2 Raccolta e miglioramento durante l'uso

La 0.3 implementa già l'apprendimento online dopo una route accettata dal classificatore LLM, con `learn: true` e controlli di eleggibilità. La proposta mantiene il comportamento con il nome più esplicito `collect_intent: true`, disabilitato per default come l'opzione precedente. Il percorso standard diventa:

```text
input -> lookup nel dataset -> altre evidenze / classifier se necessario
  -> intento accettato dall'arbitratore
  -> se collect_intent: true e l'esempio è eleggibile, registra testo + intento
  -> riusa l'embedding compatibile già calcolato, se disponibile
  -> altrimenti prepara l'embedding secondo la policy configurata
  -> aggiorna la proiezione semantica quando il vettore è pronto
  -> richieste successive possono riconoscere lo stesso testo o testi simili
```

Il percorso online standard tenta di preparare subito il vettore per rendere utile anche la ricerca semantica. Se l'encoder è indisponibile, si può conservare l'esempio etichettato e segnalarne l'arricchimento pendente; non si inserisce una riga priva di vettore nell'indice semantico. Importazione offline e raccolta per training possono partire intenzionalmente da testi senza embedding.

AgentServer coordina la decisione di apprendere dopo il risultato di routing, una sola volta per evento eleggibile. Il servizio IntentDataset gestisce scritture, deduplicazione, revisioni e aggiornamento degli indici; eventuali job di embedding corrono fuori dal GenServer. Se una riga viene modificata mentre un job è in corso, il vettore del testo precedente non viene applicato alla nuova revisione.

Conservare i controlli 0.3 su route visibili e apprendibili, route protette, etichette speciali, limiti del testo e dati da escludere. Non imparare nuovamente un risultato prodotto dalla cache stessa: amplificherebbe la propria classificazione senza nuova evidenza. L'evento utile è l'accettazione dell'intento, non il successo di un effetto GAM. Un'azione riuscita non prova da sola che l'etichetta linguistica fosse corretta.

La raccolta automatica della 0.3 resta disponibile e la migrazione ne conserva il comportamento. La verifica del codice precisa un punto della prima proposta: il built-in salva normalmente gli esempi online con `verified?: false` e li esclude dai lookup salvo `semantic_cache_include_unverified?: true`. Quindi raccolta automatica non implica utilizzo immediato automatico. Il nuovo `lookup: [include_unverified: ...]` mantiene questa scelta e il default; `verify`/`relabel` restano percorsi espliciti, non necessariamente manuali. Non si impone un nuovo workflow `review` della 0.4 e non si elimina il filtro già presente nella 0.3. Modifica del testo, cancellazione e snapshot restano supportati. Gli esempi possono migliorare copertura e ridurre chiamate LLM, ma il miglioramento della precisione si misura su un corpus separato: non è garantito da ogni nuovo inserimento.

Un errore di scrittura o arricchimento conserva la causa e segue la policy del servizio. Non ripete l'azione originaria né riavvia il turno. Le API di valutazione continuano a poter disattivare l'apprendimento per non modificare il dataset durante le misure.

### 11.3 Training e preparazione offline

```text
IntentDataset: esempi raccolti/importati, anche senza embedding
  -> selezione e validazione delle etichette rispetto alla Definition
  -> embedding batch dei soli esempi da preparare o aggiornare
  -> esempi vettorizzati per l'indice semantico
  -> training del classifier locale, quando richiesto
  -> valutazione su corpus distinto
  -> pubblicazione e caricamento di revisioni compatibili
```

Preparare il dataset per la ricerca semantica e addestrare un classifier sono operazioni distinguibili. Il comando di training può continuare a produrre entrambi, come nella 0.3 con il companion `semantic_cache.jsonl`. Non è necessario riaddestrare il classifier per ogni esempio aggiunto all'indice. I job di training appartengono alla supervisione dei servizi dello Stack, non al lifecycle di una singola conversazione.

Mantenere dataset export, setup dei modelli, train, eval, artifact, snapshot e import legacy. Non rigenerare i vettori dell'intero dataset durante un turno o un riavvio. Gli artifact dichiarano encoder, preprocessing, dimensioni, schema, tassonomia e scope; la stessa dimensione non basta per considerare compatibili due encoder. Il cambio encoder crea una nuova proiezione verificata, senza mescolare vettori incompatibili.

### 11.4 Riutilizzare Vettore, compresa la distanza di Hamming

Spectre 0.3 usa già Vettore per la ricerca sugli esempi vettorizzati. Non si introduce un altro motore. Il repository Vettore esaminato, versione 0.3.6, offre `quantized_search/3`: usa le firme binarie dei vettori per selezionare candidati tramite Hamming e li riordina con la metrica della collezione sui vettori completi. Le firme sono preparate all'inserimento. Offre anche ricerca Flat, HNSW e combinazioni tramite `hybrid_search/3`.

Esempio dell'API Vettore esistente; `collection` contiene esempi vettorizzati e `query_embedding` è già stato ottenuto dall'encoder configurato:

```elixir
{:ok, matches} =
  Vettore.quantized_search(collection, query_embedding,
    candidates: 100,
    limit: 3
  )
```

Il percorso quantizzato esaminato scansiona le firme dei record: non promette ricerca sublineare. Hamming può ridurre il costo dei confronti nel primo passaggio; non genera l'embedding di un testo nuovo. Il runtime riusa l'embedding della query tra strategie compatibili e per l'apprendimento dello stesso esempio. Il lookup esatto può evitarne del tutto il calcolo. Non confondere `metric: :hamming` con il percorso di quantizzazione e reranking su una collezione cosine.

La selezione quantizzata è un'opzione dell'adapter del dataset, non una nuova strategia di intento da riscrivere nel Router. Si confrontano Flat, HNSW e quantizzazione su latenza, memoria e richiamo dei candidati. Il reranking esatto non recupera un candidato escluso dal primo passaggio: il corpus di regressione deve misurare anche questo. Score e soglie dell'arbitratore mantengono il significato dichiarato; la distanza binaria grezza non viene trattata come confidenza di classificazione.

Gli indici devono rispettare lo scope prima che il limite dei candidati escluda i risultati utili: collezioni partizionate o un percorso di filtro esplicitamente verificato. Una ricerca globale seguita da filtro sui soli tre risultati non è sufficiente. Il servizio supervisionato dello Stack conserva i riferimenti alle collezioni, gestisce aggiornamenti e recovery, senza ricreare l'indice per ogni AgentServer. Il lockfile Spectre esaminato usa Vettore 0.3.5: la versione effettiva e la compatibilità delle API vanno fissate e testate nella migrazione.

### 11.5 Nomi pubblici e compatibilità

| Nome 0.3 | Nome/uso proposto |
| --- | --- |
| `Spectre.Router.SemanticCache` | Facciata `Spectre.IntentDataset`; adapter legacy tramite bridge |
| Strategia `:semantic_cache` | `:intent_dataset`, con evidenze distinguibili `:intent_exact` e `:intent_similarity` |
| Opzione adapter `semantic_cache:` | `intent_dataset:`; il modulo serve lookup e le operazioni dati supportate |
| `cache: false` sulla route | `dataset_lookup: false`: esclude la route dai lookup del dataset, non dal classifier |
| `learn: true` | `collect_intent: true`: raccoglie esempi testo → intento eleggibili dopo classificazione accettata; non avvia training |
| `semantic_cache.jsonl` | Import compatibile; nuovo export versionato del dataset, con embedding opzionali |

Questi nomi sono proposti, non API già disponibili. Gli alias legacy convergono sullo stesso servizio e le configurazioni in conflitto producono un errore esplicito. Le opzioni di soglia, capacità, lookup esatto/semantico e mirror del dataset vengono migrate con una tabella completa, senza cambi di comportamento nascosti. Il vecchio adapter sola lettura rimane utilizzabile: non promette automaticamente apprendimento o gestione degli esempi.

La DSL non incorpora i dati di training. Dichiara fonte/binding e policy; gli esempi rimangono dati ispezionabili ed esportabili. Il developer non deve scrivere handler distinti per exact lookup, embedding, Vettore, snapshot e apprendimento: AgentServer li coordina mediante il servizio standard. La filiera viene verificata con dataset, artifact e boot di `freelance`.

## 12. Ecosistema e compatibilità

| Package | Ruolo da preservare | Verifica necessaria |
| --- | --- | --- |
| Prism | Modelli per scopi diversi, selezione, classifier ed embedding | Il profilo cognitivo non richiede l'executor GAM di inferenza; nessun cambio implicito dei destinatari governati |
| Kinetic | Interpretazione AL, planner, cataloghi e classificatori custom | Piani provider-neutral, schema eseguibile autorevole, isolamento dei cataloghi e gestione di dati mancanti |
| Mnemonic | Recall e memoria persistente | Scope coerente con l'agente, memoria distinta dallo stato, nessun replay dopo errore di memoria |
| Beam | Canali, normalizzazione e invio | Identità, ack, outbox e distinzione tra invio richiesto e confermato |
| Pulse | Comunicazione tra agenti | Correlazione, identità e valutazione autonoma dell'autorità da parte del destinatario |
| Directive | Missioni e dialoghi durevoli | Ownership del turno, attese e operazioni attraverso lo stesso confine governato |
| Lens / altri provider | Cataloghi e operazioni specifiche | Nessuna esecuzione governata tramite un percorso alternativo del planner |

Il checkout Kinetic esaminato usa ancora il contratto della linea 0.3; Prism ha già una linea adattata alla 0.4. Questa proposta richiede una matrice di compatibilità reale, non l'assunzione che tutti i package possano essere aggiornati insieme senza bridge.

Le integrazioni dipendono da behaviours e contratti versionati. La presenza di `install` nella sintassi non basta a dimostrare compatibilità funzionale o correttezza del lifecycle.

## 13. Migrazione applicativa: il pilota freelance

La migrazione si valuta sui percorsi reali di `freelance`, non soltanto su un Agent dimostrativo. Il pilota deve includere prezzi, raccolta del brief, cambi di argomento, richiesta di cancellazione, consenso e risultato tardivo.

| Codice attuale | Destinazione proposta |
| --- | --- |
| Stack e configurazioni dei package | Stack, con adapter dei manifest dove necessario |
| Intenti, esempi e strategie nei Client/Freelancer Agent | Agent dichiarativi; conservare etichette, scope e visibilità |
| Corpi delle route e prompt operativi | `handle_flow` nei rispettivi Server e `prompt_root` del Server |
| Dispatch, attese e avanzamento in `Freelance.Spectre.Turn` | Runtime comune; resta nel Server la logica specifica di prodotto |
| Policy di conferma | `handle_pending`, interpreti e helper; stato dell'attesa posseduto dal runtime |
| Chiamate a servizi ed eventi applicativi | Callback OTP o comandi asincroni del Server |
| Effetti in action, hook o rami di rifiuto | Inventario completo; gli effetti governati convergono sull'executor |
| Stato e timeout di Session | Lifecycle, timer e codec del runtime; identità stabile indipendente dal PID |
| Delivery/outbox | Contratto del canale conservato; collegamento esplicito a ricevute e continuazioni |

Nel codice esaminato, `Client.Actions.delete_my_account` restituisce un risultato applicativo, mentre l'effetto reale `Accounts.anonymize_user_data` compare in percorsi successivi, fra cui SideEffects e rami di Turn. Avvolgere soltanto l'action nominale lascerebbe fuori dal confine proprio la cancellazione. La migrazione parte dall'effetto reale e censisce tutti i suoi ingressi.

La consegna è altrettanto importante: il percorso attuale distingue enqueue e conferma del canale. Non chiamare l'hook governato sulla semplice restituzione di `Delivery.action_result`. La visualizzazione della richiesta di consenso prima dell'effetto è parte del contratto GAM; l'eventuale requisito di consegnare il messaggio finale prima di anonimizzare è una distinta scelta di prodotto da fissare sul pilota.

Le regex vuote e i percorsi `otherwise` nelle policy legacy richiedono test di baseline sulle risposte reali: non si assume che ogni «sì» abbia già oggi la semantica desiderata. Il confronto deve distinguere conservazione del comportamento, correzione di un difetto e nuova scelta di prodotto.

Il primo verticale comprende Agent separato, Server, prezzi tramite altro actor, `:unmatched` con `understand`, cancellazione reale, cambio argomento, ripresa e recovery dell'esito. Training, Skill e streaming incrementale possono arrivare nei passi successivi, ma sono requisiti della migrazione completa, non funzioni eliminate dal primo prototipo.

## 14. Estrarre il kernel senza importare tutta la 0.4

Riutilizzare record e invarianti del kernel, Domain/ledger, ammissione, broker, executor, observer, Presentation, Evidence e catena di approvazione. Le suite kernel devono mantenere gli stessi significati. Il nuovo runtime compone questi contratti; non ridefinisce `Decision`, `Act` o `Outcome` per adattarli alle callback.

Non importare automaticamente l'intero authoring della 0.4, il suo workflow di review, i relativi nomi pubblici o una gestione della conversazione incompatibile con Stack e capacità 0.3. Il bridge deve esplicitare gli adapter per input autenticato, Candidate, risultati, presentazioni e osservazioni tardive. Anche la sealed ingestion della 0.4 va riusata con le sue dipendenze reali: non basta costruire una mappa che somiglia a Evidence.

Le collisioni fra nomi legacy e record GAM richiedono namespace e codec versionati. `policy` di una Operation legacy, limite di iterazioni e cronologia chat non diventano automaticamente Mandate, Meter ed Evidence. La migrazione non crea prove mancanti né converte un vecchio flag di conferma in consenso GAM.

L'adapter 0.3 deve tradurre verso lo stesso runtime. Durante la transizione si possono mantenere vecchi moduli pubblici come facciate; non mantenere Instance e AgentServer come due proprietari attivi della medesima conversazione. Il vecchio esecutore non deve restare una via alternativa per le operazioni già governate.

## 15. Piano di implementazione e criteri di uscita

Ogni fase produce codice verificabile e una matrice di compatibilità aggiornata. I rename cosmetici dei package non bloccano il verticale. La numerazione descrive dipendenze logiche; parti indipendenti possono essere sviluppate insieme.

### Fase 0 — Baseline e contratti

- Fissare commit, package e fixture di `freelance`; misurare il coordinamento attuale.
- Scrivere i contratti di callback, ctx, comandi, continuazioni, risultati e checkpoint descritti qui.
- Inventariare gli effetti reali, gli hook, i canali e le identità autenticate; definire la Surface del pilota.
- Fissare esempi golden di routing, dialogo, training e streaming e la matrice dei checkpoint importabili.

**Uscita:** stessi input riproducibili sulla baseline; nessuna ambiguità fra autorizzazione, conferma e risultato; schema della prima versione pubblica approvato dal progetto.

### Fase 1 — Comandi e avanzamento comune

- Introdurre un reducer interno e comandi validabili per generate, classify, respond, propose, attese e chiamate asincrone.
- Il ritorno del callback consegna il ctx al runtime, che avanza automaticamente: niente chiamata manuale a `turn` per far proseguire un `act`.
- Collegare temporaneamente il vecchio percorso attraverso un adapter, senza cambiare il kernel o introdurre un secondo loop.
- Definire identità di input, interazione, comando, generazione e continuazione; distinguere errori di validazione e risultati asincroni.

**Uscita:** percorso deterministico e percorso modello avanzano senza coordinamento manuale; un risultato duplicato non duplica la transizione.

### Fase 2 — Runtime OTP e separazione Agent/Server

- Implementare `Spectre.Server.Runtime` come unico proprietario GenServer e `Spectre.Server` come behaviour/bootstrap minimo.
- Delegare callback applicative nello stesso processo; intercettare soltanto messaggi e reference realmente posseduti dal runtime.
- Implementare ctx applicativo, comandi background, correlazione esplicita e validazione del contesto restituito.
- Specificare e verificare init, continue, call/cast/info, timeout, hibernate, terminate, code_change e format_status.
- Rendere `server:` parte della Definition dell'Agent; separare i corpi legacy tramite adapter.

**Uscita:** un catch-all applicativo non perde esiti interni; task/monitor dell'app funzionano; nessun worker trasparente per i callback OTP; niente doppio owner con Instance.

### Fase 3 — Routing, attese e fallback

- Coordinare strategie e I/O dal runtime, mantenendo l'arbitratore e la pipeline sostituibili.
- Conservare classifier distinti, adapter custom, nested flow, scope Skill, visibilità e accordo fra evidenze.
- Implementare la precedenza interrupt → pending foreground → pre-route → Router e il dispatch pubblico.
- Sospendere e reinstradare lo stesso input senza duplicare history, recall o raccolta.
- Implementare `:unmatched`, cause distinte, `understand`, limiti dei fallback e coda limitata degli input.

**Uscita:** prezzi durante una conferma, chiarimento, rifiuto e nuovo argomento hanno percorsi riproducibili; un «sì» generico non risolve un'attesa sospesa.

### Fase 4 — Bridge GAM e consenso

- Estrarre il kernel e configurare il Domain condiviso con mandati, Surface ed executor del pilota.
- Collegare ingressi autenticati ed Evidence selettiva; preservare riferimenti e derivazioni necessari all'ammissione.
- Implementare binding delle operazioni, Presentation/show, attesa, interprete del consenso e rivalutazione.
- Collegare l'effetto reale di anonimizzazione al broker/executor; chiudere gli altri percorsi applicativi che lo producono.
- Normalizzare l'envelope applicativo dei risultati mantenendo i record e gli esiti originali del kernel.

**Uscita:** nessun effetto prima dell'ammissione; la prova di consenso riguarda il materiale effettivamente mostrato; una proposta equivalente da `understand` usa lo stesso confine.

### Fase 5 — Esiti, delivery e recovery

- Implementare il collegamento durevole Act → Agent/continuazione e l'OutcomeDispatcher.
- Conservare risultato prima della ripresa, consegna almeno una volta e avanzamento idempotente.
- Separare enqueue, ricevuta del canale, osservazione dell'effetto e completamento del dialogo.
- Versionare checkpoint, ricostruire attese e worker recuperabili, definire gestione di chiamate cognitive interrotte.
- Migrare gli hook; nessuna riesecuzione dell'effetto per crash di memoria, UI o callback.

**Uscita:** crash nei punti critici, duplicati, timeout e ricevute tardive non producono effetti duplicati o falsi successi. I checkpoint senza prove sufficienti chiedono una nuova conferma.

### Fase 6 — Stack, Skill e procedure

- Stabilizzare i contratti dei manifest e adapter per Prism, Kinetic, Mnemonic, Beam e Pulse.
- Implementare i descrittori di registrazione, la generazione degli helper `kinetic`, `mnemonic`, `lens` e la primitiva condivisa di dispatch descritti in 4.3; verificare binding allo Stack, operazioni chiuse e collisioni di nomi/arità, senza richiedere funzioni helper nei package.
- Conservare l'output originale del modello nel risultato portabile della generazione; collegare `handle_result -> kinetic -> handle_result` senza planning duplicato o esecuzione automatica.
- Implementare proiezioni versionate delle richieste prima dell'outbox e dei risultati prima dell'inbox, con la stessa forma live e dopo recovery.
- Supervisionare le risorse per runtime dello Stack; verificare che ctx/assigns e comandi durevoli non contengano runtime Kinetic, Tab, encoder o connessioni vivi.
- Adattare isolamento e idempotenza di Mnemonic, riferimenti Lens, trasporti Server, workflow manuali ed eventuali backend Store ai nuovi contratti, oltre ai vincoli di versione.
- Conservare mount, binding, stato privato e versioni delle Skill.
- Collegare Work/Vigil/Directive e operazioni allo stesso owner e confine degli effetti, mantenendo checkpoint e riconciliazione.
- Verificare isolamento dei cataloghi e compatibilità di prompt, artifact e risorse installate.

**Uscita:** le capacità vengono installate e riutilizzate senza copia di logica fra Server né duplicazione dell'autorità.

### Fase 7 — IntentDataset, training e Vettore

- Introdurre facciata e alias, migrare opzioni con equivalenza verificata e distinguere esempi, verifica, lookup e indice.
- Conservare raccolta online, operazioni sugli esempi, snapshot, export, train ed eval.
- Supportare arricchimento asincrono e revisione dei record; nessun vettore incompatibile o mancante nell'indice semantico.
- Fissare la versione Vettore e confrontare Flat, HNSW e quantizzazione/Hamming con reranking.

**Uscita:** dataset/artifact del pilota caricati; default di inclusione invariati; qualità e prestazioni misurate su corpus separato.

### Fase 8 — Streaming completo

- Collegare sessioni e worker con backpressure, correlazione, terminali e cancellazione.
- Accumulare le proposte, consolidarle e solo allora aprire il percorso governato.
- Implementare il contratto di preview pubblica e la capacità incrementale mancante di Kinetic; `:auto` resta onesto sugli adapter disponibili.
- Verificare equivalenza batch/stream, cambio modello, terminali duplicati e ripresa dopo crash.

**Uscita:** preview utilizzabile senza esporre contenuti interni o eseguire frammenti; comportamento finale equivalente al batch.

### Fase 9 — Migrazione e decisione di release

- Migrare i percorsi Client e Freelancer, il brief e le procedure effettivamente usate.
- Confrontare le metriche della sezione 17; rimuovere coordinamento duplicato e facciate interne non più necessarie.
- Pubblicare guida di migrazione, matrice delle capacità, warning e codec supportati.
- Eliminare il percorso Instance soltanto quando le capacità obbligatorie e i recovery del pilota hanno equivalenti verificati.

**Uscita:** comportamento dimostrato, responsabilità leggibili e vantaggio misurato. La release non si giustifica soltanto con la presenza del kernel GAM.

## 16. Matrice minima di accettazione

| Scenario | Risultato richiesto |
| --- | --- |
| Greeting deterministico | Nessuna chiamata modello o azione accidentale |
| Classifier diverso dal responder | Binding separati e scelta del provider verificabile |
| Risposta del modello seguita da `kinetic` | AL conservato fino al callback, azioni candidate preparate senza esecuzione implicita, ordine ed errori preservati |
| Helper su capability non installata | Errore esplicito prima dell'I/O; nessuna selezione arbitraria di un'altra risorsa |
| Richiesta/risultato di package e restart | Proiezioni portabili prima di outbox/inbox; callback equivalente al live, senza dipendere da campi tecnici esclusi dal checkpoint |
| Due richieste `mnemonic` nello stesso turno | Comandi distinti con chiavi stabili; un retry non duplica la singola scrittura e il flow segue il dispatch corretto |
| `lens` con TabRef e View | Riferimenti e snapshot proiettati; nessun handle vivo nel checkpoint, operazione risolta sul binding concreto |
| Classifier locale debole + LLM | Entrambi utilizzabili nello stesso flow, con arbitraggio |
| Adapter classifier custom | Collegabile senza cambiare DSL delle route o kernel |
| Timeout di una fonte di evidenza | Altre strategie e fallback continuano, con causa originale osservabile |
| Nessun match o ambiguità | Chiarimento/UNKNOWN/understand secondo configurazione, senza loop illimitato |
| Etichetta LLM invalida | Errore conservato, fallback dichiarato e nessun intento inventato |
| Domanda sul prezzo nel mezzo del brief | Risposta pertinente senza perdita dei dettagli raccolti |
| Risposta al dettaglio richiesto | Continuazione corretta, senza richiedere nuovamente lo stesso dato |
| Domanda durante consenso | Spiegazione senza auto-consenso o esecuzione |
| Consenso dell'utente | Collegato al materiale presentato e alla proposta esatta |
| Modello che scrive "accetto" | Non vale come consenso dell'utente |
| Proposta materiale modificata | Vecchio consenso non riutilizzato |
| Modello senza AL | Nessuna azione aggiunta dal runtime |
| Cataloghi client/freelancer | Il planner non recupera o esegue azioni dell'altro ruolo |
| Rifiuto GAM | Conversazione può proseguire; l'azione rifiutata non viene eseguita |
| Timeout dell'executor | Esito incerto conservato, nessun retry automatico dell'effetto |
| Crash della continuazione | Effetto già completato non ripetuto |
| Ricevuta tardiva dopo revoca | Registrabile senza ripristinare il potere revocato |
| Nuovo AgentServer nello stesso Domain | Nessuna duplicazione del budget |
| Errore di memoria/cache dopo risultato | Nessuna riesecuzione dell'azione |
| Training e riavvio | Artifact compatibili caricati senza embedding dell'intero dataset a ogni richiesta |
| Esempio senza embedding | Conservato in IntentDataset; ammesso al solo lookup esatto se validato, mai all'indice semantico |
| Lookup esatto | Nessuna chiamata encoder necessaria; restituisce evidenza di intento e rispetta la visibilità |
| `collect_intent: true` dopo classificazione LLM accettata | Esempio eleggibile salvato una sola volta e disponibile ai successivi lookup secondo policy; nessun training implicito |
| Esempio online non verificato | Raccolto ma escluso dal lookup per default, come nel built-in 0.3; inclusione o verifica esplicite |
| Errore nell'arricchimento del dataset | Esempio e causa conservati; nessun vettore inventato e nessun replay dell'azione |
| Testo dell'esempio modificato durante embedding | Risultato della vecchia revisione non associato al nuovo testo |
| Match proveniente dal dataset | Non viene appreso nuovamente come evidenza indipendente |
| Ricerca quantizzata Vettore | Hamming seleziona candidati, reranking mantiene la metrica dichiarata; richiamo e scope verificati |
| Cambio encoder | Artifact incompatibili rifiutati o migrati esplicitamente |
| Enqueue del messaggio | Non equiparato alla consegna confermata |
| Hook dopo delivery | Avviato dalla ricevuta corretta e governato se produce una conseguenza in superficie |
| Stream interrotto | Stato e risultato coerenti; nessuna unione di epoch diversi |
| Frammenti di proposta durante stream | Accumulabili ma non eseguibili né sottoposti a GAM prima del consolidamento |
| Anteprima pubblica | Filtrata, identificata come provvisoria, distinta dal risultato finale |
| Planner senza cleaner incrementale | Contenuto misto trattenuto; nessuna esposizione di AL o falsa dichiarazione di supporto |
| Batch e stream dello stesso output | Stesse proposte consolidate e continuazioni, senza duplicazioni |
| Fallimento dopo anteprima | Notifica di interruzione/sostituzione; fallback separato per tentativo |
| Terminale stream duplicato | Una sola sottomissione della proposta consolidata |
| Checkpoint 0.3 pendente | Nessuna autorizzazione o esecuzione inventata dalla migrazione |
| Catch-all `handle_info` applicativo | Non intercetta task, terminali e ricevute realmente posseduti dal runtime |
| Task/monitor creati dall'applicazione | I rispettivi messaggi arrivano al callback applicativo |
| `handle_call` applicativo | Esegue nello stesso GenServer, restituisce tuple OTP; nessun worker nascosto |
| Callback con ctx obsoleto o identità riscritta | Validazione rifiuta il contesto obsoleto; le copie applicative non modificano l'autorità |
| Comando da cast/info non correlato | Background; non eredita l'ultima conversazione per caso |
| Messaggio che imita una ricevuta | Tag/reference non provano identità, consenso o effetto |
| Timeout, continue, hibernate e lifecycle | Semantica dichiarata verificata con traffico interno ed esterno |
| Nuovo input mentre il runtime attende un worker | Coda limitata o busy esplicito; cancel/interrupt non restano bloccati |
| Cambio argomento durante consenso | Stesso input reinstradato una volta; attesa sospesa e history non duplicata |
| «Sì» dopo cambio argomento | Non conferma automaticamente l'intento sospeso |
| Proposta da `understand` equivalente a una route protetta | Stesso binding, stesso requisito di consenso e stesso executor |
| `protected: true` con handler di chiarimento | Nessun effetto obbligatorio o autorizzazione implicita |
| Classifier LLM su intento protetto | Riconoscimento consentito; non costituisce prova di consenso |
| Crash prima/dopo il commit della continuazione | Consegna ripetibile e transizione idempotente; nessuna promessa exactly-once del callback |
| Effetto reale in hook o ramo alternativo di freelance | Tutti i percorsi censiti convergono sull'executor governato |

Riutilizzare in particolare i test `prism_test`, `router_pipeline_test`, `agent_routing_test`, `kinetic_integration_test`, `turn_test`, `conversation_actions_test` e `client/project_intake_test` di `freelance`, insieme alle suite kernel della 0.4.

## 17. Misurare il vantaggio

"Meno codice" deve significare meno coordinamento scritto dall'host, non meno controlli né più codice nascosto nei callback.

Misurare prima e dopo:

- righe e rami di coordinamento in `Freelance.Spectre.Turn` e Session;
- quantità di adapter ripetitivi e configurazione duplicata;
- numero di chiamate manuali per turno, consenso, esecuzione e ripresa;
- chiamate modello/encoder per gli stessi input;
- latenza di routing caldo e freddo, tempo di startup e recovery;
- memoria di AgentServer, cache e Domain separatamente;
- crescita della proiezione GAM con lo storico;
- comportamento di code, timeout e input concorrenti;
- chiarezza del percorso letto da un developer senza conoscere gli interni del kernel.

Il file `Freelance.Spectre.Turn` esaminato contiene 885 righe, ma include anche logica di prodotto: non è un obiettivo trasferirle tutte nel framework. Il confronto deve separare coordinamento e business logic.

Estrarre GAM non risolve automaticamente i limiti della sua proiezione storica in memoria né introduce checkpoint durevoli della proiezione. Questi limiti della 0.4 restano da misurare e affrontare prima di rivendicare scalabilità operativa.

## 18. Decisioni fissate e dettagli ancora da implementare

Sono fissati: Agent → Server; Agent dichiarativo; dialogo in Elixir nel Server; un solo GenServer con delega; callback OTP disponibili; ritorni conversazionali in ctx e ritorni OTP nativi; Router senza policy di esecuzione; GAM sulle conseguenze dichiarate; IntentDataset e training conservati; proposte stream consolidate prima dell'esecuzione.

Restano da chiudere in implementazione, senza riaprire questa architettura:

1. Schema versionato di ctx/comandi/checkpoint e protocollo di correlazione, inclusa la compatibilità hot upgrade effettivamente testata.
2. Firma finale di startup, helper e callback estese come `init/2`; gli esempi esprimono il contratto desiderato, non una release già disponibile.
3. Mapping delle classi del pilota, mandati, identità autenticate, ricevute e politica di delivery prima/dopo l'anonimizzazione.
4. Codec dei checkpoint legacy e trattamento delle attese prive di prove GAM.
5. Contratti versionati dei package e delle strategie custom sospendibili.
6. Capability di preview incrementale, protocollo UI e limiti delle code.
7. Formato degli artifact IntentDataset, mapping delle opzioni e versione/configurazione Vettore.

Non serve inventare una macro per ciascuna voce: prima il contratto, poi eventuali abbreviazioni.

### 18.1 Come sono state recepite le review Opus

Sono adottati la separazione fra stato applicativo e runtime, la precedenza dei messaggi interni, le callback brevi, la correlazione delle continuazioni, i limiti delle garanzie in una BEAM condivisa e l'esigenza di collegare il consenso a materiale e input autentici.

Non sono adottati il binding inverso Server → Agent, un divieto generale di classifier LLM per intenti protetti, una legge universale di consenso tramite regex, l'obbligo di esprimere il dialogo in una DSL o una promessa di callback exactly-once. I timeout OTP restano un contratto da supportare e testare con la semantica dichiarata, non un divieto architetturale.

Le review originali rimangono consultabili e non vengono riscritte per farle coincidere con la proposta finale:

- [Prima review Opus 5.5](reviews/claude-opus-5.5-review.it.md) e [contesto fornito](reviews/claude-opus-5.5-brief.it.md).
- [Review Server/OTP Opus 5.5](reviews/claude-opus-5.5-server-otp-review.it.md) e [contesto fornito](reviews/claude-opus-5.5-server-otp-brief.it.md).

## 19. Fonti e riferimenti verificati

- [Manifesto GAM](https://spectre.guide/en/governed-act-model): significati e perimetro, indipendenti dall'implementazione.
- [Stack 0.3 alla baseline](https://github.com/elchemista/spectre/blob/1059bd8/docs/STACK.md): installazione, manifest, risorse e separazione dall'autorità.
- [Routing 0.3 alla baseline](https://github.com/elchemista/spectre/blob/1059bd8/docs/ROUTING.md): strategie, arbitraggio, classificatori e cache.
- [Architettura 0.3 alla baseline](https://github.com/elchemista/spectre/blob/1059bd8/docs/ARCHITECTURE.md): ownership, Run, Instance, inferenza e recovery.
- [Training 0.3 alla baseline](https://github.com/elchemista/spectre/blob/1059bd8/docs/TRAINING.md): dataset, artifact e vettori precomputati.
- [Apprendimento online 0.3](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/router/plugs/arbitrate.ex): eleggibilità e scrittura dopo classificazione LLM accettata.
- [Dataset e lookup legacy 0.3](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/router/semantic_cache/learned.ex): ramo esatto e selezione degli esempi per la ricerca semantica.
- [Streaming 0.3](https://github.com/elchemista/spectre/blob/1059bd8/docs/STREAMING_INFERENCE.md): limiti del planning, anteprima, risultato canonico e sanitizzazione.
- [Vettore](https://github.com/elchemista/vettore/blob/master/README.md) e [implementazione della ricerca alla revisione esaminata](https://github.com/elchemista/vettore/blob/6b16a97/lib/vettore/collection.ex): quantizzazione, Hamming, reranking e API collezioni. Il checkout locale esaminato è `/home/dev/Sviluppo/personal/vettore`, commit `6b16a97`.
- [Runner 0.3 alla baseline](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/runtime/runner.ex): handler DSL e normalizzazione dei ritorni custom.
- [Limiti attuali 0.4](https://github.com/elchemista/spectre/blob/6906258/docs/capabilities.md): proiezione storica, streaming e funzionalità assenti.
- [Superficie governata 0.4](https://github.com/elchemista/spectre/blob/6906258/GOVERNED_SURFACE.md): confini reali e assunzioni dell'implementazione da riutilizzare.
- [Stack attuale 0.4](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/agents/stack.ex) e [Extension](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/agents/extension.ex): contratto più ristretto rispetto allo Stack 0.3.
- [Wiring classifier 0.4](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/agents/agent/wiring.ex): restrizione locale/LLM da non trasferire al nuovo authoring.
- Riferimenti applicativi locali: `/home/dev/Sviluppo/startup/freelance/lib/freelance/spectre/stack.ex`, `client/agent.ex`, `freelancer/agent.ex`, `router_pipeline.ex`, `turn.ex`, `session.ex`, `delivery.ex`, `side_effects.ex`, `actions/provider.ex` e relative suite sotto `test/freelance/spectre/`.
- [Decision del kernel](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/core/decision.ex), [Outcome](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/core/outcome.ex) e [risultato della proposta](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/core/proposal/result.ex): campi e valori effettivi della linea 0.4 esaminata.
- [Prova di approvazione](https://github.com/elchemista/spectre/blob/6906258/lib/spectre/core/presentation/approval.ex): collegamento fra Presentation, show, Outcome e risposta Evidence.

## 20. Criterio finale

Leggendo l'Agent si capisce cosa viene riconosciuto. Leggendo il Server si capisce come prosegue il dialogo e quali servizi vengono richiesti. Leggendo Surface, binding ed executor si capisce quali conseguenze sono governate e dove vengono prodotte. Il runtime si occupa di avanzamento, concorrenza e ripresa; GAM mantiene le proprie invarianti.

Il risultato deve ridurre il coordinamento manuale senza eliminare le capacità che hanno reso utile la 0.3. Se il pilota richiede di riscrivere un nuovo `Freelance.Spectre.Turn` dentro ciascun Server, l'estrazione di Instance non è riuscita.

## Appendice A: DSL e opzioni

L'obiettivo è rendere visibile la distinzione fra dichiarazione, comportamento e autorità. Le tabelle sono una mappa di migrazione: i nomi proposti non sono già disponibili. Alias e adapter devono preservare il comportamento osservato, non soltanto accettare la vecchia sintassi.

### A.1. Superfici pubbliche

| Superficie | Contiene | Non le compete |
| --- | --- | --- |
| Stack | Installazione, provider, profili, servizi e risorse | Decidere per l'utente o concedere autorità |
| Agent | Binding `server`, classifier, Router, flow, intenti, Skill e metadata | Dialogo, prompt operativi, corpi delle route, esecuzione |
| Server | Callback, funzioni Elixir, `prompt_root`, catalogo `actions`, comandi tramite ctx | Modificare direttamente ledger o stato interno del runtime |
| Host GAM | Domain, mandati, Surface, executor, ingressi e osservazioni | Scegliere implicitamente il modello o il classifier |
| Servizi installati | Memoria, dataset, encoder, modelli, planner, canali | Duplicare il loop conversazionale |

`use Spectre.Server` genera il minimo necessario per collegare behaviour e default. Le operazioni conversazionali sono normali funzioni, non macro che riscrivono corpi dei callback. Non si richiede `super` per far funzionare il protocollo interno; il runtime lo gestisce prima della delega.

### A.2. Regole delle opzioni

- Default → opzioni del flow → opzioni della route; un valore più locale prevale solo nel proprio scope.
- Opzioni sconosciute, alias in conflitto e binding assenti producono errori espliciti. Non ignorare un'opzione scritta male.
- Una sola fonte per ciascun binding: l'Agent può sovrascrivere il servizio dello Stack, senza ricopiare provider e credenziali.
- Durate e unità documentate; per le nuove opzioni pubbliche usare millisecondi dove OTP usa millisecondi.
- Opzioni keyword senza `?` quando si rinominano; nessun cambiamento di semantica implicito durante il rename.
- Funzioni anonime utili a runtime non diventano automaticamente continuazioni persistibili. Le attese durevoli richiedono un riferimento serializzabile/versionato o un codec esplicito.
- Metadati come `protected` e `collect_intent` controllano aspetti distinti. Uno non cambia silenziosamente l'altro.
- `max_attempts` conta anche il primo tentativo; non convertirlo in numero di retry.
- Opzioni del provider sotto `adapter_options`, estensioni sotto il namespace del package; `metadata` non nasconde configurazione operativa non validata.
- Le liste sostituiscono quelle ereditate, salvo composizione esplicita come plug e injection; niente merge ricorsivo implicito delle strategie.

La precedenza dei binding/default deve essere ispezionabile: framework → Stack → Agent → flow → route, per i campi applicabili. Il Server dispone degli override di chiamata ammessi dal servizio. Questi override non allargano identità, catalogo o autorità GAM e non rimuovono vincoli delle estensioni, come un minimo di modello dichiarato nel flow.

Restano anche le opzioni meno visibili nell'esempio principale:

| Area | Conservazione e collocazione |
| --- | --- |
| Manifest Stack | `id`, `version`, `contract`, `spectre`, `provides`, dipendenze, conflitti, risorse e `agent_extensions`; contratto distinto dalla versione del package |
| Persistenza | `state_store`, `memory`, `checkpoint_store` nei rispettivi binding/configurazione runtime; non tre nomi dello stesso archivio |
| History | Preferire `history limit: ..., summarizer: {M, :f}` nella configurazione del servizio; preservare ciò che il limite conta nella baseline |
| Journal | Conservare `events`, `mode`, `on_error`, `include_input`, `sample_rate`, `buffer_size`, `overflow`; distinto dal ledger GAM |
| Pre-route | `turn_handler(s)` → `pre_route_handler(s)`; extension point distinto dai callback conversazionali |
| Pipeline input | Conservare `input_pipeline`, `plug`, halt e gestione errori; opzioni `trim`, `collapse_whitespace`, `case`, `unicode` |
| Prompt injection | Conservare `inject`, `into`, `position`, `from`, `when`, `required` nei servizi di composizione/Skill; non esecuzione di azioni |
| Prompt legacy `fail` | Migrare nel default di errore del Server o in una clausola `handle_result`; conservare risposta deterministica o inferenza effettiva senza aggiungerla implicitamente |

Questi binding non richiedono nuove macro nel Server. La migrazione della sintassi preesistente avviene nel builder della Definition, nello Stack o nell'adapter del servizio secondo l'owner.

### A.3. Agent e Router

| Nome/forma | Decisione |
| --- | --- |
| `server: MyApp.SupportServer` | Unico binding Agent → modulo applicativo; il runtime avvia il processo |
| `prompt_root` sull'Agent | Spostare sul Server che richiede i prompt |
| `router strategies: [...]` | Elenco esplicito delle sorgenti abilitate; non sostituisce accordo, soglie e arbitraggio |
| `flow`, `on`, flow annidati | Conservare; route senza corpo di esecuzione nella nuova authoring |
| `defaults: [...]` nel flow | Evita ripetizione dei metadata, con override esplicito sulla route |
| `regex` | Conservare; mostra chiaramente il criterio di riconoscimento |
| `semantic` o esempi equivalenti legacy | Canonico `semantic_examples`; migrare il campo realmente presente senza convertire dataset o artifact automaticamente |
| `priority`, visibilità, interrupt | Conservare semantica e scope; non appiattire in ordine testuale delle route |
| `protected: true` | Segnala il percorso di conferma per le proposte del flow; non è un mandato né identifica da solo la classe governata |
| `cache: false` | `dataset_lookup: false`; non disabilita ogni classifier o tutta la memoria |
| `learn: true` | `collect_intent: true`; raccolta di esempi eleggibili, non training né consenso |
| `:semantic_cache` | `:intent_dataset`; distinguere hit esatto e similarità nell'evidenza |
| `run`, `reason`, `act`, `action`, `reply` nei corpi legacy | Adapter verso Server/comandi; non restano la nuova authoring dell'Agent |
| `fallback do ...` / `policy do ...` | Comportamento nel Server; niente seconda DSL di dialogo |

`handle_flow(:unmatched, ...)` rende il fallback esplicito nel Server. Un catch-all `_` può essere scritto in Elixir, ma non è l'esempio raccomandato: nasconderebbe intenti dichiarati e non implementati. Non aggiungere route speciali per ogni variante di «sì» quando la risposta riguarda un'attesa attiva.

La configurazione avanzata della pipeline rimane disponibile. Il nome `strategies` non implica che ogni provider venga chiamato sempre né che vinca il primo match: la policy di arbitraggio decide quali evidenze richiedere e quando fermarsi.

Dettaglio delle opzioni di routing già sottoposte ad audit:

| Attuale | Proposto e semantica |
| --- | --- |
| `via` del Router | `strategies` |
| `via` della route | `match_with`: visibilità, non ordine di esecuzione né scelta obbligatoria del vincitore |
| `regex`, `bag`, `jaro` | Conservare come matcher dichiarati; non cambiare l'algoritmo sotto un nuovo nome |
| `embedding: [testi]` | `semantic_examples: [testi]`; esempi brevi di riconoscimento, distinti dal dataset di training |
| `check` / `checks` | Un solo `checks: [...]`, con gli stessi predicati e accessi ai metadata |
| `cache: false` | `dataset_lookup: false`; esclude sia esatto sia semantico, senza nascondere la route al classifier |
| `learn: true` | `collect_intent: true`; l'eleggibilità resta verificata, non prevale sulle esclusioni della route |
| `strength`, priorità e opzioni di adapter | Conservare dove definite; la forza dell'evidenza non concede autorità |
| `arbitrator` macro / opzione | Canonico `router arbitrator: ...`; la macro resta alias |
| `conflict`, `no_decision` dell'arbitratore | `on_conflict`, `on_no_decision`; conservare esiti e scelte `:llm`/`:clarify` |
| `classifier_accept`, `classifier_margin` | `local_classifier: [min_score: ..., min_margin: ...]` dentro l'arbitratore |
| `embedding_accept`, `embedding_margin` | `embedding: [min_score: ..., min_margin: ...]` nello stesso blocco |
| `bag_accept`, `jaro_accept` | `bag: [min_score: ...]`, `jaro: [min_score: ...]` |
| `terminal_labels` / `terminal_intents`, `high_confidence_threshold` | `terminal: [intents: [...], min_confidence: ...]`; conservare la formula e il metadata terminale della 0.3 |
| `classification_log?` | `log_decisions`; diagnostica del routing, non raccolta del dataset |
| `hard_short_circuit?` | `hard_short_circuit`; mantenere differenza fra built-in e adapter che richiedono tutte le evidenze |
| `llm_classifier?`, `llm_fallback?` | Normalizzazione dalle strategie per il percorso standard; opzioni esplicite dei plug per pipeline legacy, non doppie manopole pubbliche equivalenti |

Non rinominare `terminal` in `end_flow` senza verificarne i consumer: nella baseline viene calcolato da route accettata, confidenza e lista di intenti, e costituisce metadata per le uscite/escalation. Non è un comando che termina sempre un workflow.

Le soglie restano specifiche per provider/metrica. Nessun `confidence: 0.8` globale che equipari cosine, Hamming e punteggi del classificatore. La migrazione delle vecchie soglie locali e dell'arbitratore conserva entrambi i livelli quando eseguivano controlli differenti; le duplicazioni si eliminano solo dopo una prova di equivalenza.

Pipeline e strategie possono coesistere quando la pipeline consuma le strategie dichiarate; il compilatore non le aggiunge due volte. L’arbitratore rimane sostituibile e i risultati di non decisione confluiscono nel fallback del Server.

### A.4. Classifier, modello ed encoder

| Binding | Ruolo |
| --- | --- |
| `classifier :local, Module, ...` | Classifier locale e relativi artifact |
| `classifier :llm, Module, ...` | Adapter di classificazione, con modello proprio o risolto dallo Stack |
| Modello di risposta | Binding dello scopo di generazione; può differire da quello del classifier |
| Encoder | Binding con identità/versione/preprocessing/dimensioni; condivisibile quando compatibile |
| Planner Kinetic | Interpreta il piano e recupera candidati dal catalogo; distinto dal classifier di intenti |
| `timeout` del servizio | Limita quella richiesta; non scadenza del consenso o timeout dell'effetto |
| Soglia locale, soglia semantica, margine di ambiguità | Parametri del rispettivo adapter/arbitratore; non score intercambiabili |

Il Server può richiamare i servizi risolti per riconoscere una risposta a un'attesa o gestire un caso applicativo. Non deve reimplementare lookup/embedding/classifier per ottenere accesso a queste capacità. Le API di servizio restituiscono risultati tipizzati; quelle asincrone correlate rientrano tramite `handle_result`.

| Famiglia esistente | Collocazione proposta |
| --- | --- |
| `model`, `temperature`, `max_tokens` e opzioni del vendor | `adapter_options` nel binding del modello; nessuna eliminazione delle opzioni specifiche del provider |
| `with` / `function` per adapter | Forma canonica `{Module, :function}` come riferimento; il modulo solo usa il callback del behaviour |
| `llm_opts` del classifier | `adapter_options` del binding `:llm`, con separazione dei timeout Spectre |
| `local`, `classifier_local`, callback `classify` | Binding `classifier :local, ...`; callback effimeri rimangono disponibili tramite adapter/override compatibile |
| `artifact_dir` disperso nel Router | Sul binding locale; il servizio dataset può usare lo stesso artifact tramite riferimento esplicito |
| `context` del prompt classifier | `description`, per distinguerlo dal contesto runtime strutturato |
| `label_examples` | `examples_per_intent` |
| `classifier_history`, `classifier_history_limit` | `history: false` oppure `history: [limit: 5]` nel binding LLM |
| `recent_chat` | Override host `classifier_context: [recent_chat: ...]`; non è una nuova cronologia canonica |
| `classifier_assigns` | `assigns` sul prompt classifier; campi canonici riservati rimangono non sovrascrivibili |
| Timeout `llm_`, `local_classifier_`, `embedding_`, `semantic_cache_`, `router_adapter_`, `turn_handler_` | `timeout` nel rispettivo binding; i nomi legacy sono tradotti mantenendo la precedenza |
| `provider_timeout`, `router_timeout`, `input_timeout` | Limiti distinti per default delle chiamate, routing complessivo e input; non accorparli sotto un solo timeout ambiguo |

Quando manca un binding LLM dedicato, il bridge conserva il fallback al modello principale della baseline e rende visibile la scelta risolta. Il fallback del provider, la scelta dell’arbitratore di consultare un LLM e il comportamento `:unmatched` nel Server restano tre livelli distinti.

### A.5. IntentDataset: superficie completa

```elixir
intent_dataset MyApp.IntentDatasetStore,
  sources: ["priv/spectre/intents.jsonl"],
  lookup: [exact: true, semantic: true],
  search: [method: :quantized, candidates: 100, limit: 3, min_score: 0.88],
  collection: [index: :flat, metric: :cosine, compressed: true],
  collection_options: [gpu: :auto, gpu_fallback: :cpu],
  collect: [on_error: :continue, min_chars: 8, max_chars: 1_000]
```

L'adapter può essere quello standard dello Stack. `collect:` configura la raccolta ma non abilita da solo tutte le route: serve `collect_intent: true` dove desiderato. L'encoder deriva dal binding `embedding` compatibile; non si deve dichiarare lo stesso modello due volte. `method: :quantized` seleziona la ricerca Vettore, mentre `collection.index` configura la struttura della collezione: non confondere le due opzioni.

Il frammento dichiara il binding del servizio sull'Agent quando non è già fornito dallo Stack; non va inserito nel Server come nuova DSL. Dal Server si usa il servizio risolto e, per le operazioni asincrone, il normale contratto di comandi e risultati.

| Opzioni legacy | Mappatura proposta |
| --- | --- |
| `semantic_cache`, `semantic_lookup` | Binding `intent_dataset`; il riferimento sola lettura rimane tale |
| `semantic_cache?` | `lookup: false`; non cancella il dataset |
| `semantic_after_classifier?` | `lookup: [semantic: false]` quando disabilitava quel ramo, conservando la fase di consultazione legacy |
| `semantic_cache_source`, `mirror_training_dataset?` | `sources` e `include_training_examples`; nessun import implicito aggiuntivo durante migrazione |
| `semantic_cache_static?` | `include_static_examples` nell'override del servizio |
| `semantic_cache_threshold` / `semantic_cache_search_threshold` | `search: [min_score: ...]`, stessa scala della metrica dichiarata |
| `semantic_cache_top_k` | `search: [limit: ...]`; distinto da `candidates` del primo passaggio Hamming |
| `semantic_cache_index`, `semantic_cache_index_options` | `collection: [index: ...]`, `collection_options: [...]` |
| `semantic_cache_compressed?` | `collection: [compressed: ...]` |
| `semantic_cache_capacity` / `index_capacity` | `max_cached_indexes` / `max_index_revisions` nei rispettivi owner; non chiamarli numero massimo di esempi |
| `semantic_cache_online_capacity` | `max_online_examples`; questo limite riguarda effettivamente le righe raccolte, separatamente dagli indici |
| `semantic_cache_include_unverified?` | `lookup: [include_unverified: ...]`; mantenere il default `false` della baseline |
| `semantic_learn?` | `collect: [enabled: false]` come disattivazione host; non riabilita route con raccolta disattivata |
| `semantic_learn_min_chars`, `semantic_learn_max_chars` | `collect: [min_chars: ..., max_chars: ...]` |
| `semantic_learn_failure` | `collect: [on_error: :continue | :error]`, con traduzione dei valori legacy |
| `semantic_learn_protected?` | `collect: [include_protected: ...]` per eleggibilità dei dati, senza autorizzare azioni |
| `semantic_learn_even_on_cache_hit?` | Opzione avanzata di compatibilità `collect: [after_dataset_hit: ...]`; non abilitata dal nuovo percorso standard |
| `semantic_learn_confidence` | `collect: [initial_confidence: ...]`; conserva il dato legacy senza presentarlo come misura calibrata universale |

Il nuovo percorso standard non apprende un risultato del dataset come nuova prova indipendente. Un'eventuale opzione legacy di apprendimento dopo hit richiede tracciabilità della diversa evidenza LLM e un test dedicato; non viene eliminata senza una decisione di compatibilità.

**Distinzione verificata nel codice:** la raccolta 0.3 salva normalmente `verified?: false`; `Learned.Online.usable_row?/2` esclude queste righe dai lookup salvo l'opzione esplicita di inclusione. Quindi «classificazione accettata», «esempio raccolto» ed «esempio verificato» non sono sinonimi. `collect_intent` conserva la raccolta automatica; disponibilità immediata al routing e verifica rimangono una policy separata. Verificare un esempio non significa necessariamente richiedere revisione umana, ma richiede un percorso esplicito del servizio.

La facciata `Spectre.IntentDataset` mantiene `examples`, `get_example`, `put`, `update_example`, `relabel`, `verify`, `delete`, `snapshot`, `load_snapshot`, `clear`. Questi nomi sono già comprensibili; `relabel`/`verify` devono avere conseguenze esplicite sull'ammissione al routing e sulle revisioni. Nel built-in 0.3 `clear` elimina per default righe online e indici, non i file sorgente: mantenere questa distinzione. Per gli adapter custom migrare in base al contratto effettivo; non trasformare uno svuotamento di proiezione in cancellazione del dataset.

I comandi attuali di export/train/eval rimangono funzionanti. I nuovi comandi rivolti al dataset usano il namespace `spectre.intent_dataset.*`, quelli del classifier `spectre.classifier.*`. `embed` prepara i vettori del dataset, `train` produce l'artifact del classifier: non due nomi per lo stesso comando. Import e snapshot preservano anche esempi senza embedding.

### A.6. Callback e helper: contratti proposti

| Superficie | Uso e risultato |
| --- | --- |
| `handle_flow(route, input, ctx)` | Comportamento di un intento o fallback; restituisce ctx |
| `handle_pending(pending, input, ctx)` | Dialogo dell'attesa foreground; restituisce ctx |
| `handle_result(tag, result, ctx)` | Continuazione di un comando; restituisce ctx |
| `handle_call/cast/info`, `handle_continue` | Callback OTP delegate, tuple native con ctx; nessun worker implicito |
| `assign(ctx, key, value)` | Modifica stato applicativo; non riscrive identità o pending |
| `generate(ctx, prompt, opts)` | Generazione, planning opzionale e stream; risultato consolidato |
| `classify(ctx, input, opts)` | Classificazione sul binding dichiarato; label senza autorità |
| `kinetic(ctx, response, opts)` | Helper generato dalla registrazione Stack: interpreta l'AL del modello e prepara azioni candidate; nessuna esecuzione automatica |
| `mnemonic(ctx, operation, opts)` | Helper generato dalla registrazione Stack: recall/scrittura esplicita, con scope e risultato correlati |
| `lens(ctx, operation, opts)` | Helper generato dalla registrazione Stack: percezione/operazioni browser tramite binding e proiezioni portabili |
| `respond(ctx, content, opts)` | Richiesta di risposta; non prova automatica di consegna o show GAM |
| `propose(ctx, operation, args, opts)` | Proposta concreta, collegamento al percorso governato e continuazione |
| `confirm_pending` / `reject_pending` | Richiede la transizione usando attesa e input d'origine; non scrive una Decision |
| `explain_pending` | Mantiene il dialogo; materiale e nuova sollecitazione passano dal contratto di presentazione |
| `route_current_input(ctx, suspend: id)` | Sospende e ripassa lo stesso input al Router, senza nuovo evento utente |
| `resume_pending(ctx, id)` | Riporta un'attesa in primo piano e ripresenta il materiale secondo policy; non approva |
| `call_actor(ctx, actor, request, opts)` | Chiamata in worker, correlata; nessuna esenzione per effetti governati |
| `await_reply` / `resolve_await` | Registrazione/risoluzione di attese applicative; autenticazione distinta dalla correlazione |
| `on_result` | Tag della continuazione, non nome di una funzione scelta dal modello |

I helper accumulano comandi; il runtime li valida al ritorno del callback. Il developer può comporre funzioni Elixir proprie attorno a questi helper. Un codice applicativo che esegue I/O prima del ritorno non acquisisce atomicità, recovery o protezione GAM per effetto della sola presenza del ctx.

### A.7. Generazione, fallback e streaming

| Opzione/concetto | Significato |
| --- | --- |
| `planning: false` | Testo senza proposte; default esplicito del percorso |
| `planning: true` | Raccolta e validazione di proposte dal catalogo chiuso |
| `stream: false` | Nessuna richiesta di stream al provider |
| `stream: true` | Richiede il percorso streaming del binding; capacità effettiva verificata |
| `preview: :auto` | Anteprima solo se l'adapter separa in sicurezza il testo pubblico |
| `preview: :required` | Errore esplicito se il contratto non può essere soddisfatto |
| `preview: :off` | Nessuna anteprima; stream utilizzabile per accumulo interno |
| Fallback del modello | Configurato per scopo; conserva causa, tentativo e generazione |
| Errore terminale | `handle_result(tag, {:error, failure}, ctx)`; non sinonimo di nessun match |
| Token e frammenti AL | Dati provvisori; non proposte eseguibili né Evidence di consenso |
| `reply_sanitizer` | Binding conservato; preview non disattiva il filtro |
| `sanitize_reply: false` legacy | Override esplicito e fidato; non prova che l'output sia sicuro da mostrare |
| Limiti parser/chunk, buffer, retention, backpressure | Configurazione del servizio stream con unità esplicite; non persi nel cambio di API |
| `plan_actions?` legacy | Mapping esplicito verso `planning`, senza cambiare comportamento in base al solo planner installato |

Il protocollo di preview è separato dal successo finale. La scelta di fallback dopo output già visibile deve specificare sostituzione/interruzione; non concatenare due generazioni come se fossero una sola risposta.

### A.8. Azioni, conferme e hook

Il catalogo `actions:` del Server descrive ciò che il planner e i handler possono proporre. La Surface e i binding host determinano il significato governato e l'executor. Non aggiungere una macro `governed` nell'Agent per duplicare la configurazione di autorità.

Conservare anche provider multipli/scoped (`action_provider`) e porta `action_planner` nei binding dei servizi: `actions:` è soltanto la forma semplice dell'esempio. Il resolver esterno resta disponibile come sorgente autenticata collegata all'attesa. Hook `before_action` e `after_action` mantengono il momento del controllo e l'evento preciso di delivery; i nomi non devono spostarli implicitamente prima della proposta. Il bridge di `otherwise ask:` conserva la generazione che il vecchio percorso eseguiva, mentre la nuova authoring la esprime con normali funzioni del Server.

Il Server implementa il dialogo mediante `handle_pending` e normali funzioni. Opzioni come template, interprete, scadenza e numero massimo di chiarimenti sono dati di una richiesta di conferma, con default del servizio; non un linguaggio `accept/reject/otherwise` da imparare. La forma esatta delle opzioni resta da finalizzare, mantenendo distinti tentativi di dialogo, retry di modello e Attempts GAM.

Un rifiuto dell'utente è un evento di consenso. Un rifiuto del kernel è una Decision. Un errore o esito ambiguo dell'executor è un risultato dell'operazione. Il default deve mantenere queste distinzioni anche quando l'applicazione non personalizza ogni clausola.

Gli hook possono osservare esiti e richiedere nuovi comandi. Gli effetti governati richiesti da hook, `handle_info` o Work passano dagli stessi binding/executor; il nome del callback non concede un'eccezione.

### A.9. Skill, Work, Vigil e operazioni

| Superficie | Decisione |
| --- | --- |
| `skill`, `as`, `bind`, `namespace` | Conservare. `as` identifica il mount; `bind` collega azioni logiche a concrete; non confonderli con un rename dell'intento |
| `requires_action`, alias `requires_tool` | Canonico `requires_action`; tool resta terminologia del protocollo/provider |
| `requires_operation`, `uses_operation` | Conservare: richiedere un binding nella Skill e importare un'operazione in Work/Vigil sono ruoli diversi |
| `id`, `version`, stato privato della Skill | Conservare; non trasformare ogni Skill in un processo |
| `operation`, `call_operation` | Conservare per registro ed invocazione delle operazioni; stesso confine GAM delle action quando governate |
| `route_operation_events` | Conservare con tipi espliciti; non confondere reingresso come nuovo input e ripresa `on_result` |
| `operation input/output` | Preferire `input_schema` / `output_schema` nella nuova authoring, con alias ai validator legacy |
| `side_effect`, `retry`, `reconcile`, `fallback`, `catalog` | Conservare finché l'import GAM ne definisce il mapping. Nessuna rimozione dei contratti di idempotenza/riconciliazione per uniformare nomi |
| `policy`, `domain`, `risk`, `remember`, `metadata` delle Operation | Documentare scope e collisioni con termini GAM; non convertirli automaticamente in Grant, Domain vivo o decisione di ammissione |
| Work/Vigil `input`, `state`, `update`, `checkpoint` come schemi | `input_schema`, `state_schema`, `update_schema`, `checkpoint_schema`; codec e dati restano compatibili tramite mapping |
| `budget: [steps:, attempts:]` | Preferire `limits: [max_steps:, max_attempts:]` per limiti del loop; non un Meter GAM |
| `on_budget_exhausted` | `on_limit_exhausted` per quei limiti locali |
| `branches`, `blockers`, `waits`, `triggers`, `can_start`, `update_fields` | Conservare contratti e nomi per ora; i controlli deterministici non vanno nascosti nei prompt |
| `security`, `artifact_policy` | Mappatura esplicita nel piano GAM; niente secondo sistema di autorità implicito |
| `init`, `next`, `apply_result`, `apply_update`, `handle_trigger`, `checkpoint_compatible?` | Conservare nel behaviour operativo; non sono callback obbligatori dell'AgentServer conversazionale |
| `run`, `observe`, `wait`, `wait_for`, `blocked`, `complete`, `fail` di Work/Vigil | Conservare nel proprio namespace. `fail` qui termina una procedura: non è il vecchio prompt `fail` dell'Agent |

Non rinominare l'intero runtime operativo durante il solo lavoro sull'ergonomia. La proposta identifica i confini; migrazione dei record e nomi pubblici può essere graduale, senza cambiare checkpoint già pubblicati per una modifica cosmetica.

### A.10. Package di freelance: correzioni circoscritte

| Package | Revisione |
| --- | --- |
| Prism | Mantenere `provider`, profili, `purpose`, `prefer`, `default`. `classifier: :fast` nel provider sceglie un profilo, non un adapter; valutare separatamente `classifier_profile: :fast` nella futura DSL del package; l’esempio corrente conserva `classifier: :fast` |
| Prism | `intelligence: :balanced` è una preferenza di selezione del package, non una capacità garantita: valutare `model_profile: :balanced`; `prism: [minimum: ...]` resta vincolo distinto |
| Kinetic | Mantenere `top_k` come quantità di candidati recuperati; non chiamarlo numero massimo di azioni eseguibili |
| Kinetic | `allow_unmounted_actions` consente extra nel registro runtime durante la verifica, non esposizione automatica all'Agent. Preferire `allow_extra_registry_actions`, conservando filtro e validazione del catalogo montato |
| Kinetic | `classifier` dentro `install Spectre.Kinetic` è parte del suo interprete; non configurazione del classifier di intenti dell'Agent. Mantenerlo locale e documentare esplicitamente il namespace |
| Beam | `delivery: :caller_owned` può diventare `delivery_owner: :host`; mantenere outbox, ack e responsabilità osservate, senza trasferire retry implicitamente |
| Beam | `channel`, `adapter`, `capabilities`, `typing`, `await_ack`, `before_decode`, `planner_exposure` sono comprensibili: conservarli |
| Mnemonic | `plasticity?` può diventare `plasticity` nel package; non ridurlo a «memoria attiva». `isolate_by([:instance])` va mappato a identità dell'agente stabile, non al PID del nuovo server |
| Pulse e altre estensioni | Conservare installazione e contratti. Nessun rename inventato per opzioni non esaminate |

Queste sono proposte ai package, non macro del core. La compatibilità dei manifest e dei contratti deve precedere il cambio di sintassi. Il nuovo Agent non deve duplicare provider, modello, encoder e planner già collegati dallo Stack.

### A.11. Startup, tempo e lifecycle

| Concetto | Contratto |
| --- | --- |
| Identità stabile | Chiave di conversazione/agente definita dall'host; non il PID |
| `idle_timeout` | Inattività conversazionale, se offerta; diversa dal timeout OTP del processo |
| Timeout OTP intero / `:infinity` | Semantica del processo, influenzata anche dal traffico interno; supporto da verificare nell'adapter |
| Timer applicativi | `Process.send_after` e messaggi propri; cancellazione e restore a carico del contratto applicativo |
| Scadenza pending | Termine persistibile dell'attesa; non dipende soltanto da un timer volatile |
| `terminate` | Best effort, non garanzia di salvataggio in caso di kill |
| `code_change` | Migrazione distinta per schema runtime e dati applicativi; supporto dichiarato solo quando testato |
| `format_status` | Introspezione utile senza esposizione automatica di credenziali o input privati |

La Session 0.3 usa opzioni di inattività che vanno ricondotte al comportamento effettivo, senza inventare due timeout indipendenti soltanto per rendere i nomi più belli. La guida di migrazione deve documentare i timer reali e i loro trigger.

### A.12. Compatibilità e verifica dei rename

Gli alias legacy vengono normalizzati una sola volta. Se alias e nuovo nome sono entrambi presenti con valori discordanti, errore esplicito. Warning, documento di migrazione e versione di rimozione appartengono alla release che implementerà questi cambiamenti.

Gli esempi della sezione 7 sono il riferimento di leggibilità per la nuova architettura. Ogni nuova opzione deve avere un owner, un default, uno scope, un errore comprensibile e un test di comportamento quando modifica l'esecuzione. Non aggiungere DSL al Server per evitare di definire un contratto di funzione.

### A.13. Riferimenti dell'audit

- [DSL 0.3](https://github.com/elchemista/spectre/blob/1059bd8/docs/DSL.md) e [macro/normalizzazione Agent](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/agent.ex).
- [Routing](https://github.com/elchemista/spectre/blob/1059bd8/docs/ROUTING.md), [arbitraggio e raccolta online](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/router/plugs/arbitrate.ex), [metadata terminale](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/router/support.ex).
- [Provider](https://github.com/elchemista/spectre/blob/1059bd8/docs/PROVIDERS.md), [streaming](https://github.com/elchemista/spectre/blob/1059bd8/docs/STREAMING_INFERENCE.md), [timer Session](https://github.com/elchemista/spectre/blob/1059bd8/lib/spectre/otp/session.ex).
- [Stack](https://github.com/elchemista/spectre/blob/1059bd8/docs/STACK.md), [Skill](https://github.com/elchemista/spectre/blob/1059bd8/docs/SKILLS.md), [azioni/policy](https://github.com/elchemista/spectre/blob/1059bd8/docs/ACTIONS.md), [operazioni](https://github.com/elchemista/spectre/blob/1059bd8/docs/OPERATIONS.md).
- Applicazione: `Freelance.Spectre.Stack`, `Client.Agent`, `Freelancer.Agent`; stessa baseline della proposta principale. Package: sorgente Kinetic, in particolare `Catalog.verify_runtime/3`; configurazioni Prism/Beam/Mnemonic usate dall'applicazione.

Questa revisione è documentale. Non modifica parser, runtime, package, dipendenze o applicazione; nessuna nuova macro mostrata è dichiarata già funzionante.
