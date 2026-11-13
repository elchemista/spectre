# Piano: tool registrati nello Stack per AgentServer 0.4

Stato: revisione 3, approvata alle condizioni della seconda review di Claude
Opus 5.5, qui recepite integralmente in R1 e P1-P4. Implementazione a fasi avviata.
Branch core: `feature/agent-server-gam`, versione 0.4.0. Nessun push o merge.

## Contesto e decisioni vincolanti

La base è Spectre 0.3.4, con Stack, router multistrategia, classifier separabile
dal modello generativo, fallback/understand, IntentDataset, semantic cache con
embedding e training preservati. Il branch 0.4 aggiunge Agent dichiarativo e
Server callback OTP, con un unico processo proprietario GenServer e il kernel
GAM importato dalla precedente implementazione 0.4. Non si riscrive GAM.

L'applicazione dichiara Stack e flow nell'Agent, implementa handle_flow,
handle_result, handle_pending e normali callback OTP nel Server. Classificazione,
embedding e generazione sono servizi cognitivi: non richiedono consenso GAM per
il solo fatto di usare un modello. GAM governa le azioni concrete, il consenso
quando richiesto dalla policy host, esecuzione, esiti e continuità. Installare un
package non concede autorità per inviare email, cancellare account o salvare dati.

Il consenso può restare sospeso durante altri intent e scadere tramite i timer
già implementati. Le transizioni sono registrate nel percorso lifecycle GAM;
un timeout non inventa un rifiuto dell'utente e non cancella un Act in esecuzione.

L'utente vuole helper di UNA parola: kinetic, mnemonic, lens. Queste funzioni
NON devono essere esportate/importate dai package. Vengono generate dal core
dalle registrazioni dello Stack. Il modello produce AL; nel suo handle_result
l'app chiama kinetic(ctx, response, on_result: :actions_ready). Nessuna AL fissa
nel flow e nessuna esecuzione automatica delle azioni appena interpretate.

## Stato reale dei contratti

- Spectre.Stack.Installable ha manifest/0, compile/3, child_specs/2 opzionale.
- Installation contiene già adapters, ma compile! delle installazioni native
  passa una mappa vuota; i mount legacy la popolano per i port noti.
- Stack.Binding attiva agent_extensions; non genera funzioni nel Server.
- Kinetic registra già Extension.action_planner -> Spectre.Kinetic.Planner.
  plan_response/3 interpreta risposta completa; SpectreKinetic.plan/3 è la API
  singola AL con runtime proprio. Non esiste Spectre.Kinetic.plan/3.
- Mnemonic ha recall/remember; Lens ha open/look/act e runtime supervisionato.
  I loro tipi nativi non sono automaticamente serializzabili dal checkpoint.
- Alcuni package (Lens, Kinetic, Beam) espongono il contratto senza dipendenza
  obbligatoria da Spectre. Non imporre loro `use` o @behaviour a runtime.
- Prism/Pulse nei checkout locali usano una vecchia architettura 0.4 differente;
  Ledger/Lab hanno contratti legacy. Non promettere compatibilità automatica
  cambiando solo un requisito di versione.

## Contratto da estendere

Estendere lo STESSO Spectre.Stack.Installable con callback opzionale tools/1,
invocato dopo compile/3 sulla configurazione immutabile. Default assenza = %{}.
Il callback restituisce descrittori, non AST, funzioni anonime o processi.
Installable resta l'unico punto di registrazione; eventuali moduli interni per
validazione/dispatch non costituiscono un registro o behaviour concorrente.

Ogni helper ha nome atomico validato e contratto versionato. Dichiara operazioni
chiuse, target di invocazione/adattamento, percorso cognitivo o governato per
OPERAZIONE, proiezione input/output e riferimenti logici alle risorse necessarie.
Per Kinetic il percorso cognitivo prepara candidati; per Mnemonic recall e
remember non hanno necessariamente lo stesso percorso. Per Lens act va risolta
la sottooperazione prima dell'ammissione; niente switch di autorità dall'input.

La configurazione dello Stack può scegliere binding, ma una chiamata helper o
un output del modello non può sostituire target, modalità, schema o proiettore.
Non usare un semplice apply(module, function, [ctx, input, opts]): gli adapter
esistenti hanno firme differenti. Un adapter di integrazione dichiarato dal
package prepara il contratto concreto usando contesto servizio e opzioni fidate.

Conservare i descrittori validati in Installation.adapters[:tools], includendoli
nel digest esistente. Non duplicare in manifest e config una seconda fonte di
verità. Testare compatibilità installazioni prive di tools, rebuild, manifest
serializzati e binding obsoleti. Per nuove capacità non ignorare errori o campi
sconosciuti; documentare versione/minimo core richiesto.

## Authoring e compilazione

```elixir
defmodule MyApp.AI do
  use Spectre.Stack
  install Spectre.Kinetic
  install Spectre.Mnemonic
  install Spectre.Lens
end

defmodule MyApp.SupportServer do
  use Spectre.Server, tools: MyApp.AI

  def handle_result(:model_response, {:generated, response}, ctx) do
    kinetic(ctx, response, on_result: :actions_ready)
  end
end
```

tools: è un nuovo collegamento di compilazione esplicito: il Server è un modulo
separato dall'Agent e deve conoscere le funzioni locali. Nessun registry globale
di compilazione e nessuna dipendenza circolare Server -> Agent. Un before_compile
core genera normali funzioni locali con ctx esplicito; collisioni con funzioni
applicative, callback, helper core, import e altre installazioni sono errori.
Verificare nomi validi e alias di installazione, senza conversioni di stringhe
non fidate in nuovi atomi. Helper optional, nessun obbligo di usarli nel Server.

Al runtime verificare che lo Stack dell'Agent effettivo sia compatibile con il
contratto compilato del Server. Mai risolvere risorse dal solo Stack lessicale
se l'Agent ne seleziona un altro. I digest partecipano al fingerprint/recovery.

## Dispatch, durata e GAM

1. L'helper risolve solo dati e accoda una richiesta logica nel ctx. Nessun I/O
   durante callback applicativo o compilazione. L'handler restituisce ctx.
2. Prima dell'acquisizione durabile della richiesta, normalizzare input in dati
   portabili e fissare descriptor/operation digest. Non serializzare PID, runtime
   Kinetic, encoder, tab live o credenziali. Conservare riferimenti logici.
3. Risolvere e validare la modalità dell'operazione da binding fidato. Una
   richiesta governata deve diventare il normale comando :propose PRIMA che
   possa essere eseguito un effetto. Riutilizzare bridge/executor/consenso/receipt
   e recovery esistenti. Non creare un secondo executor di effetti generic tool.
4. Le operazioni cognitive usano worker, outbox/inbox e correlazione esistenti;
   callback destinazione preservata. Politica retry esplicita: solo richieste
   ripetibili; nessun reinvio automatico di effetti con esito incerto.
5. Risolvere risorse dallo Stack.Runtime del servizio nel worker/executor. Il
   contesto applicativo non possiede i runtime. ctx.private resta solo volatile.
6. Proiettare il risultato PRIMA della scrittura inbox/checkpoint, non dentro
   handle_result: sarebbe troppo tardi. Errori di adattamento restano correlati.
7. Consegna risultato portabile tramite on_result; ripartenza non perde la
   continuazione. Timeout/cancel/restart conservano gli esiti incerti governati.

Il package descrive come invocare; il core decide quando il percorso consente
l'invocazione. Una registrazione governata collega un'operazione host ammessa,
non crea implicitamente grant o policy dal nome del tool.

## Generazione, streaming e Kinetic

Oggi planning:false pulisce AL; planning:true la interpreta già e il default
handle_result esegue le proposals. Per il percorso esplicito mantenere nella
risposta consolidata un campo interno portabile model_output con testo originale,
separato da text destinato alla risposta pubblica. Non affidarsi a inference,
scartato dal checkpoint. Non esporre model_output nei normali eventi/UI/risposte.

kinetic accetta la risposta consolidata e usa il suo output originale. Il
risultato ha tag distinto da {:generated, ...}, per evitare l'esecuzione implicita
del default handler. Normalizzazione verso candidati con operazione, argomenti,
provider/schema/owner/scope dal catalogo chiuso già esistente. Invocazione
esplicita insieme a planning:true deve fallire chiaramente o avere un contratto
che impedisca doppia pianificazione; decidere e testare il primo comportamento.

Streaming: preview resta non autorevole e non esegue AL parziali. Conservare
consolidamento e policy del cleaner già esistenti; non promettere preview grezza
sicura con il cleaner Kinetic non incrementale.

## Sequenza di implementazione e confini

1. Review Opus 5.5 di questo piano, dei file sorgenti e del contesto GAM. Risolvere
   blocker e salvare risposta/verdetto/modello. Nessuna implementazione prima
   del passaggio della review richiesto dall'utente.
2. Core Installable.tools/1, validazione descrittori, Installation digest e test
   di conformità. Default retrocompatibile per package senza tool.
3. Generazione helper Server e validazione binding; test compilazione/alias,
   collisioni, moduli separati, Agent con Stack diverso.
4. Dispatch cognitivo e conversione governata prima dell'esecuzione, proiezioni,
   correlazione e recovery. Riutilizzare primitive esistenti, estrarre moduli
   piccoli anziché gonfiare Runtime.
5. Output modello originale interno, adapter Kinetic reale e fixture complete.
   Poi Mnemonic recall/remember e Lens open/look/act con risorse logiche,
   autorizzazione host per scrittura e proiezioni. Per Mnemonic usare command_id
   come identità dell'operazione (più scritture possono stare nello stesso turn).
6. Demo outreach eseguibile in modalità simulata, coerente con le API implementate:
   dedup contatti esatto, modello -> Kinetic -> proposta email -> esito reale,
   consenso salvataggio report, cambio argomento/timeout/ripresa. Nessuna email
   reale o visita web durante test. Claim/dedup concorrente resta dell'executor.
7. Documentazione, generator installable, matrice compatibilità: indicare package
   realmente adattati e limiti Prism/Pulse/Beam/Directive/Ledger/Lab. Migrazioni
   esterne necessarie si svolgono in branch dedicati di ciascun repo; core sempre
   sul branch feature/agent-server-gam richiesto, non modificare checkout altrui.
8. Review implementazione e verifiche mirate, poi suite core e controlli qualità.

## Criteri di accettazione

- Nessun import di helper inesistenti, nessun adapter applicativo obbligatorio
  per installare i tre package supportati, nessuna inizializzazione a compile time.
- Fixture di package aggiunto dall'esterno genera helper senza case hardcoded
  kinetic/mnemonic/lens nel core. Package late-bound continua compilabile solo.
- Registrazioni malformed, target/arità inesistenti, duplicati, override target,
  binding incompatibili e output non portabile falliscono in modo deterministico.
- Nessun effetto prima di GAM; consenso sospeso/negato/scaduto non esegue il tool;
  conferma esegue una sola operazione; crash/esito incerto non reinvia alla cieca.
- Recovery cognitiva conserva callback e riferimento risorsa; mismatch descriptor
  richiede migrazione esplicita. Due richieste/turn hanno idempotency key distinte.
- AL originale disponibile dopo checkpoint, testo pubblico pulito, nessun
  parsing doppio o esecuzione implicita del risultato Kinetic.
- Native OTP callback, pending timers e routing/dataset/training restano coperti.
- Test serializzati: non avviare VM ExUnit concorrenti (directory temporanee
  condivise). Non spacciare i precedenti 4323 test per verifica del nuovo lavoro.

## Riferimenti per la review

Leggere docs/proposals/agent-server-gam-from-0.3.it.md (soprattutto 4.3),
docs/AGENT_SERVER.md, docs/GOVERNANCE.md, docs/PENDING_LIFECYCLE.md e l'esempio
docs/proposals/examples/outreach_agent.exs. Il kernel è lib/spectre/gam/.
Controllare lib/spectre/stack/{installable,installation,package,binding,runtime}.ex,
lib/spectre/server.ex, server/{command,services,checkpoint,runtime,catalog}.ex.
I repo satellite sono directory sorelle ../spectre_kinetic, ../spectre_mnemonic,
../spectre_lens; leggere le API effettive prima di suggerire firme.

## Specifica normativa v1 — risoluzione della prima review

Questa sezione precisa e, in caso di divergenza, sostituisce le scelte generiche
precedenti. Review originale: reviews/claude-opus-5.5-stack-tools-review.it.md.

### B1: schema e firme esatte

`tools(config)` restituisce una mappa chiusa della forma seguente (moduli di
integrazione illustrativi da implementare nei package, non API già esistenti):

```elixir
%{
  kinetic: %{
    contract: 1,
    adapter: Spectre.Kinetic.ServerTool,
    default: :interpret,
    operations: %{
      interpret: %{path: :cognitive, retry: :safe, max_bytes: 1_048_576}
    }
  }
}

%{
  mnemonic: %{
    contract: 1,
    adapter: Spectre.Mnemonic.ServerTool,
    default: nil,
    operations: %{
      recall: %{path: :cognitive, retry: :safe, max_bytes: 1_048_576},
      remember: %{path: :governed, operation: :save_report, max_bytes: 1_048_576}
    }
  }
}
```

Chiavi sconosciute rifiutate. `contract` deve essere 1; nomi helper/operazioni
sono atomi già dichiarati; helper identificatore Elixir valido, non riservato.
`default` è nil o una chiave in operations. Input non tuple seleziona default;
tuple non vuota seleziona la prima componente e passa le restanti al prepare
come lista. Default riceve il dato originale. Nessun fallback da tag sconosciuto
al default. `max_bytes` intero positivo <= limite codec core. Operazione host
governata: atom/string/tuple portabile non nil, fissata nel descrittore.

Adapter pubblico del package, senza un nuovo behaviour di registrazione:

- `prepare(operation, payload, trusted) -> {:ok, args} | {:error, reason}`:
  funzione pura, nel confine Failure.capture del Server prima dell'acquisizione;
  trusted contiene installation.config, agent e snapshot logico del routing.
  Nessun runtime, credenziale o funzione resolver in questo contesto. Per un
  comando governato args deve essere una mappa destinata al binding host.
- `invoke(operation, args, tool_context) -> term`: solo cognitive nel worker;
  tool_context contiene installation, service_context (con command_id e opzioni
  runtime) e configurazione package. Il package usa Stack.Runtime.resolve con
  riferimenti ricavati dallo Stack effettivo; niente resolver serializzato.
- `project(operation, raw) -> {:ok, portable_result} | {:error, reason}`:
  nel worker prima dell'inbox. portable_result include il tag pubblico voluto
  (per Kinetic `{:prepared, %{actions: ..., text: ...}}`). Errori/exception
  dell'adapter vengono ridotti a ragioni bounded e codificabili.

L'esistenza di prepare/3, project/2 e invoke/3 (quest'ultimo solo se ci sono
operazioni cognitive) è verificata all'avvio Server. A compile time si verifica
la forma: evitare ensure_compiled obbligatorio sugli adapter dello stesso
progetto. Il callback tools viene chiamato solo per compilare l'installazione;
build!/rebuild! validano i descrittori memorizzati senza reinvocarlo.

La modalità è fissata dal package nel descrittore. v1 non espone override di
path/retry dall'helper né un selettore universale di modalità nello Stack.
Il package può leggere opzioni di installazione che valida esso stesso:
Mnemonic accetta `bind: [remember: :save_report]`; il binding cambia il nome
host, non trasforma remember in cognitivo. Se non configurato, remember non
viene esposto; recall continua disponibile. Nessuna autorità implicita.

### B2: acquisizione governata e binding host

Il wrapper genera un comando logico :tool con helper/input/options e contratto
lessicale atteso. Il runtime normalizza dentro Failure.capture, usando
state.agent/state.server, non campi modificabili del ctx restituito. Coprire
conversazione, init e TUTTE le callback OTP: stessa normalizzazione prima di
acquire in ogni percorso. Dopo prepare e verifica codec la richiesta governata
diventa :propose, prima dell'outbox. Rivalidare il Command normalizzato.

Opzioni pubbliche ammesse: on_result per entrambe; timeout solo cognitive;
confirmation solo governate. Altre opzioni rifiutate, comprese tutte le chiavi
interne. La provenienza tool è metadata interno distinto da proposal_metadata
del catalogo: aggiungere una mappa con solo tool/op/digest a proposal_metadata
farebbe fallire Catalog.validate, che richiede owner/scope/schema_hash.
L'identità tool deve essere conservata in un campo/metadata riservato validato
dal runtime; il percorso Catalog delle proposte Kinetic resta invariato.

All'avvio con tool governati verificare che lo standard Server.GAM config abbia
bindings per le operazioni esposte, con candidate valido; altrimenti errore
esplicito. v1 non inferisce binding di bridge custom: richiede il bridge standard
per tali tool, preservando il supporto bridge custom per i comandi preesistenti.
Host configura comunque scope, binding, executor e policy GAM. Il package può
fornire funzioni candidate/executor pronte; non installa grant automaticamente.
«Nessun adapter applicativo» vale per cognitive e per l'adattamento tecnico;
la configurazione host dell'autorità e della policy resta necessaria.

### B3: retry e incertezza

Tool cognitivi hanno retry esplicito :safe o :never. :safe ammette riesecuzione
in recovery; :never acquisisce execution_started=true prima dello spawn.
Recovery di un :never iniziato consegna una sola completion durabile
`{:tool_unknown, %{command_id: id, tool: name, operation: op, reason: reason}}`;
non invoca il package e non dichiara fallimento certo. Timeout/DOWN producono
lo stesso tag. Il risultato tardivo non deve completare una seconda volta la
stessa continuazione; id completion stabile e inbox deduplicata. Con worker
interrotto, le risorse temporanee restano gestite dal lease del package/host.

Lens open è cognitivo :never (alloca una tab), look è :safe. In v1 TUTTI i tipi
di act ammessi (navigate/click/fill/submit/scroll) sono governati; tipo sconosciuto
rifiutato nel prepare, nessuna opzione per far passare submit come cognitivo.
Mnemonic remember esplicito è SOLO governato. Non promettere una idempotency_key
che la API corrente non accetta: command_id è correlazione, la recovery passa
da GAM e il package/executor deve riconciliare l'esito senza retry alla cieca.
L'eventuale aggiunta di dedup persistente in Mnemonic è separata, non condizione
occulta per dichiarare questa v1 funzionante. Memoria automatica legacy resta
un percorso distinto e documentato; test evitare doppia ingestion dell'esplicito.

### B4: codec e limiti

Esporre dal Checkpoint una funzione di validazione dei dati con lo STESSO
GAM.Canonical.Value e allowlist @records. Non usare Stack.Value.portable? come
prova sufficiente. Validare l'intero comando normalizzato (inclusi on_result e
confirmation) entro Failure.capture prima dell'acquisizione; limite per-tool
su args. Prima dell'acquisizione verificare anche la proiezione completa dello
stato risultante con il limite globale, così un payload valido singolarmente
non manda in loop il proprietario superando il budget del checkpoint aggregato.

Nel worker: invoke -> project -> validazione codec/limite -> risultato. Errori
diventano {:error, {:tool_result_not_portable, bounded_reason}} senza raw input.
Prima del salvataggio inbox validare la proiezione completa e, se il nuovo
risultato supera il budget aggregato, acquisire invece l'errore bounded riferito
allo stesso command_id. Non ricominciare il tool per un errore di serializzazione.
Per tool governati il payload dell'Outcome è proiettato dal package executor
PRIMA di essere acquisito come fatto GAM, senza alterare dopo l'hash dell'Outcome.

Outbox contiene solo dati: installation_id/helper/op/digest, args e opzioni.
Nessun %Stack.Ref{} o runtime live. Identità dei moduli adapter aggiunte al
fingerprint, oltre ai digest e agli md5 già esistenti di Stack/Server/Agent.

### B5: Kinetic e modello

Estrarre il percorso esistente Services.consolidate(true) in una API pubblica
core condivisa `Spectre.Server.Planning.prepare(text, service_context)` che
ricostruisce Spectre.Context, chiama Spectre.ActionPlanner.plan_response con
catalogo closed e produce le stesse proposal complete di metadata provider,
schema_hash, owner, scope. Services planning:true e l'adapter Kinetic chiamano
questa API; il satellite non usa direttamente moduli @moduledoc false.
Il port planner resta quello registrato da Kinetic, con configurazione Stack.

Generazione standard produce planning:boolean; con false include model_output,
con true lo omette. Il prepare Kinetic richiede planning:false e model_output
binario; true -> response_already_planned, campo assente -> model_output_required.
Risposta prepared non attiva il default handler generated. L'applicazione può
ispezionare le azioni e passarle a propose con il loro proposal_metadata.
model_output persiste solo internamente; niente esposizione automatica nei
response/preview/history pubblici. Test su streaming e restart reali.

Runtime Kinetic v1: parità con il planner esistente, che risolve runtime esplicito
oppure crea/chiude un runtime posseduto per chiamata. Nessuna nuova risorsa Stack
obbligatoria e nessuna struct Kinetic nel ctx. Ottimizzazione supervisor separata.

### B6: migrazioni satellite effettive

Branch dedicati dai checkout puliti, senza spostare core da feature/agent-server-gam:

| Package | Modifiche richieste per questa v1 |
| --- | --- |
| Kinetic | requisito core 0.4 per nuovo contratto, tools/1, ServerTool, uso Planning.prepare, test plan/model_output/candidati; runtime posseduto invariato |
| Mnemonic | requisito core, tools/1, ServerTool recall con opzioni agent/scope, proiezione Packet/Moment, remember governato con binding esplicito e executor/proiezione; niente falsa idempotenza |
| Lens | requisito core, tools/1 late-bound, ServerTool con input chiusi, mappe TabRef/View prima inbox, open never/look safe/act governato, lease/cleanup host documentato |

I test core usano fixture indipendenti. I test satellite verificano le API reali
contro il core locale. Non basta allargare il requisito nel manifest: aggiornare
anche dipendenza test/runtime secondo ciascun package. Resta non certificata
la compatibilità di tutti gli altri package fino a loro migrazione specifica.

### B7: generatore e compatibilità

Nome helper = chiave in tools, `as:` rinomina solo installation_id. Unicità dei
nomi in Definition.new! e rebuild. tools: richiede modulo letterale espanso e
Stack.Definition.fetch verificata. Wrapper locali privati arità 2/3; soppressione
mirata del warning unused SOLO per le funzioni generate, non globale. Collisioni
contro Module.defines?, env.functions, env.macros, callback e helper core per
ENTRAMBE le arità. Test warnings-as-errors con un package installato ma inutilizzato.

Verifica binding prima di Checkpoint.load e init applicativo. Snapshot lessicale
tool deve corrispondere a quello dello Stack effettivo dell'Agent; nessun uso
di risorse lessicali per Agent diverso. Descriptor e md5 adapter entrano nel
fingerprint. Non aggiungere nuovi kind Stack.Ref o registry globale.

### Gate di implementazione

Prima implementare e verificare il blocco core (Installable + compiler + runtime
con fixture), poi adapter reali sui tre satellite. Non dichiarare il percorso
end-to-end completo fino ai test satellite e alla simulazione outreach.
Richiedere ora a Opus una verifica B1-B7 di questa specifica; iniziare solo quando
non rimangono blocker. Correggere l'esempio Lens open: restituisce la mappa TabRef
direttamente. Allineare remember alla installazione bind: [remember: :save_report].

### R1: esiti della normalizzazione, per ogni ingresso

La seconda review approva la specifica a condizione di aggiungere questa regola.

1. Rifiuti di dominio: prepare restituisce errore o solleva eccezione, codec o
   limite per-tool rifiuta il payload, tag di operazione sconosciuto. Al posto
   del comando tool si acquisisce, nello stesso ordine degli altri comandi,
   una completion durabile con command_id e risultato
   `{:error, {:tool_rejected, tool, op, bounded_reason}}`, consegnata a on_result
   tramite inbox. Nessuna invocazione dello strumento. Seguire il modello
   resolve_await -> receive_result. Semantica identica per conversazione, init,
   callback OTP ed error handler; l'errore response_already_planned arriva così
   all'applicazione come bounded_reason, non finisce in quarantena.
2. Errori di programmazione: opzioni non ammesse, helper assente dallo snapshot,
   mismatch di contratto. Conservare semantica validate_context!: quarantena
   in conversazione, stop con ragione in init, eccezione nelle callback OTP.
   Nessun salvataggio prima dell'errore; handle_call non invia una risposta
   mentre scarta silenziosamente i comandi. Error handler conserva il proprio
   percorso di failure già esistente. Testare entrambi i tipi per ogni ingresso.
3. Verifica aggregata dello stato include returned.assigns. Fallimenti dovuti
   allo stato applicativo aggregato sono errori di programmazione, intercettati
   prima del commit: la callback non viene acquisita e le sue modifiche non
   vengono conservate. La quarantena conversazionale conserva solo la failure
   bounded, non il payload che ha causato il superamento del limite.

P1: provenienza tool nell'entry outbox riservata, non opzioni passate al bridge;
rifiutare tentativi di forgiarla anche da propose/4 diretto.
P2: includere returned.assigns nei test di limite aggregato e restart.
P3: adapter Kinetic verifica che il planner effettivo sia Spectre.Kinetic.Planner;
override incompatibile restituisce errore di dominio prima di pianificare.
P4: default handle_result per tool_unknown informa che l'operazione è sotto
verifica, come governed_unknown; mai dichiarare successo/fallimento certo.

Evidenza: reviews/claude-opus-5.5-stack-tools-followup.it.md, conclusione:
«Una volta aggiunto il paragrafo R1, per me la specifica è PASS e
l'implementazione a fasi può procedere come descritta.»

## Avanzamento verificato del primo incremento

Implementato sul branch core `feature/agent-server-gam`:

- callback opzionale Installable.tools/1 dopo la compilazione della config;
- schema chiuso dei descrittori e delle operazioni, senza invocare gli adapter;
- memorizzazione in Installation.adapters[:tools], inclusione nei digest e
  revalidazione delle installazioni ricostruite;
- unicità dei nomi tra package, indipendente dall'alias di installazione;
- conformance dei moduli installabili; manifest grezzi restano verifiche di soli
  dati e non eseguono callback;
- retrocompatibilità delle installazioni senza tools, documentazione del
  contratto e 13 nuovi test.

Verifica del 2026-11-13: suite completa **4336 passati** (4310 test, 25 property,
1 doctest), 1 escluso; suite mirata finale **38 passati** dopo l'estrazione di
un helper privato richiesta da Credo. Format, compilazione warnings-as-errors,
Credo e Dialyzer passati (0 errori, 0 skip in Dialyzer). Log suite completa:
`/tmp/spectre-stack-tools-core-tests.log`. Non è una nuova misura di coverage.

Restano le fasi 3–7: generazione helper Server, normalizzazione/dispatch/recovery,
output modello originale e Planning.prepare, adapter reali Kinetic/Mnemonic/Lens,
simulazione outreach eseguibile e verifica end-to-end. Nessun package satellite
è stato modificato da questo primo incremento; nessuna API helper viene già
presentata come operativa.

## Implementazione dei package e del loop

Il primo incremento descritto sopra e la sua verifica restano una fotografia
storica. Il seguito implementa il compiler degli helper, la normalizzazione
prima dell'outbox, gli adapter dei nove package e lo store Ledger per checkpoint
e journal GAM. Le API effettive sono in [STACK_TOOLS](../STACK_TOOLS.md), con
esempio eseguibile in [integration/stack_tools](../../integration/stack_tools/README.md).
Risultati e limiti aggiornati sono nel [rapporto di verifica](stack-tools-0.4-verification.it.md).
