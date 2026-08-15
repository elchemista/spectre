# Piano di implementazione: Inference Invocation, streaming OTP e Ledger v2

Stato: piano esecutivo della traccia core Spectre. Le modifiche a Prism e Ledger
sono esplicitamente differite e qui compaiono soltanto come contratti esterni.

Revisione corrente, rispetto alla prima stesura:

- distinzione esplicita fra terminale di inferenza e terminale di Run, e semantica di reply di `Spectre.stream/3` (§1.2.1);
- contenuto provvisorio e sanitizzazione incrementale (§1.8);
- ammissibilità fail-closed dello streaming (§1.9);
- costo di serializzazione dell'Instance e cap di ammissione delle sessioni (§1.10, §1.11);
- contratto pull sul `Transport` di Prism e capability per profilo (§4.1);
- fence ridotti per le receipt recuperate (§7.1);
- riuso dei meccanismi esistenti al posto di duplicati: control lane, digest portabile, envelope di evento, bus osservatori, supervisore dei runner;
- nuova sezione sicurezza con threat model e controlli innestati sui seam esistenti (§8);
- ri-slicing in cinque tracce rilasciabili separatamente (§10).

Repository coinvolti:

- `spectre`: autorità del Run, Invocation, fencing, budget, recovery e receipt;
- `spectre_prism`: selezione e meccanica provider-specifica di streaming;
- `spectre_ledger`: persistenza e verifica delle receipt.

Per questa consegna il solo repository modificabile è `spectre`. Il core deve
restare utilizzabile con adapter esterni che implementino i nuovi behaviour, ma
non vengono implementati adapter Prism, backend Ledger o bundle esterni.

## Stato della consegna Spectre

Aggiornato il 15 agosto 2026. Questo stato riguarda esclusivamente il core in
questo repository; le sezioni Prism, Ledger e verifier restano contratti futuri,
non garanzie dichiarate dalla release corrente.

- [x] ADR, threat model e separazione esplicita delle ownership;
- [x] recovery deterministica dei Run e migrazioni Run/checkpoint v3;
- [x] Invocation di inferenza one-shot con selezione congelata, fallback e
  receipt terminale;
- [x] behaviour streaming fail-closed, Enumerable one-shot e sessione
  temporanea `:gen_statem`;
- [x] steering restart-based, epoch fencing, cancellazione e recovery esplicita;
- [x] budget aggregato, snapshot per attempt, heartbeat e observer lane
  post-commit senza testo;
- [x] receipt envelope, state digest, sink conformance e outbox `required` nel
  core, senza dichiarare una catena Ledger v2;
- [x] sanitizzazione incrementale, provenance/trust del prompt e validazione
  bounded degli argomenti d'azione;
- [x] documentazione pubblica, guide di migrazione e fixture di compatibilità;
- [x] gate finali di formato, suite completa, copertura, Credo, Dialyzer,
  ExDoc, package e xref.

Verifica finale eseguita sul branch di consegna:

- compilazione forzata con warning trattati come errori: superata;
- suite completa: 2.338 risultati passati (1 doctest, 5 property e 2.332
  test), 1 escluso;
- copertura totale: 95,08%, sopra il gate del 95%;
- formatter e Credo release gate (`mix credo --all`): nessun rilievo;
- Dialyzer: 0 errori, 0 warning, 0 esclusioni;
- ExDoc con `--warnings-as-errors`: superato;
- contract test della superficie pubblica e del package: 8 passati;
- build Hex locale unpacked e audit dipendenze: superati;
- xref: analizzato il grafo compile-connected; resta il singolo ciclo già
  presente su `origin/main`, senza introdurre un nuovo ciclo.

Principio guida:

> Il core possiede la semantica e l'autorità dello stream; Prism possiede la meccanica del provider; Ledger conserva la prova durevole.

Il piano non introduce un secondo runtime. Lo stream live è un data plane OTP temporaneo; il Run e l'Instance restano il control plane canonico.

## 1. Decisioni normative

### 1.1 Prima slice supportata

La prima release di streaming deve avere un perimetro intenzionalmente stretto:

- un solo consumer autorevole per stream;
- output testuale;
- delta live effimeri e risultato terminale durevole;
- adapter one-shot ancora supportati;
- steering soltanto restart-based;
- nessun resume trasparente dello stesso Enumerable dopo restart;
- nessuna garanzia exactly-once sui delta osservati;
- nessun raw-delta pub/sub;
- `deterministic_replay: false` finché un verifier non prova i digest;
- consumer exit policy iniziale fissa a `:cancel`;
- gli stream adapter pull sono il percorso preferito; gli adapter push richiedono un buffer strettamente limitato;
- streaming ammesso soltanto per purpose puramente testuali: niente action planning, niente structured output (§1.9);
- delta provvisori e mai deliverable finché il terminale non è sanitizzato e validato (§1.8);
- numero di sessioni concorrenti limitato in modo esplicito per Instance e per nodo (§1.11).

### 1.2 Proprietà pubbliche dello stream

Il contratto pubblico è `Enumerable.t()`, non `%Stream{}`. Spectre restituisce una struct opaca che implementa `Enumerable` e che contiene anche i riferimenti necessari per cancel, steer e inspection:

```elixir
{:ok, stream} = Spectre.stream(instance, input, opts)

alias Spectre.Inference.StreamEvent

Enum.each(stream, fn
  %StreamEvent{kind: :delta, payload: text, content_class: :provisional} -> IO.write(text)
  %StreamEvent{kind: :inference_completed, payload: response} -> inspect(response)
  %StreamEvent{kind: :result, payload: %Spectre.Result{} = result} -> inspect(result)
  %StreamEvent{kind: :failed, payload: reason} -> inspect(reason)
end)
```

Lo stesso valore può essere usato da un processo di controllo:

```elixir
{:ok, next_stream} = Spectre.Inference.Stream.steer(stream, follow_up)
:ok = Spectre.Inference.Stream.cancel(stream, :user_requested)
```

La struct è one-shot: la prima enumerazione reclama il consumer. Una seconda enumerazione viene rifiutata con un evento terminale tipizzato `:already_consumed`.

L'atomicità del claim non richiede macchinari nuovi: `:gen_statem` serializza le call, quindi la transizione `:awaiting_consumer -> :opening` sul primo attach è già atomica. Il consumer token resta utile soltanto per *autorizzare* il possessore quando l'handle viene passato tra processi; va dichiarato come tale e non come meccanismo di mutua esclusione.

La struct non contiene un pid. `Spectre.Run.Value.validate/2` rifiuta pid, port, reference e function (`run/value.ex:24`) e la stessa validazione protegge Run, Result e metadata: un handle con pid dentro diventerebbe una mina non portabile alla prima contaminazione. La struct porta quindi identificatori (`inference_id`, `invocation_id`, `stream_epoch`) e la sessione si risolve da un `Registry` unique dedicato. `cancel/2`, `steer/3` e `resume_stream/3` sono lookup per id, non chiamate a pid.

#### 1.2.1 Due terminali distinti

`:inference_completed` è il terminale dell'**attempt di inferenza**. Non è il terminale del Run: dopo di esso restano post-processing, action planning, effetti, persistenza dello stato e commit canonico (§5.3). Un consumer che vedesse solo `:inference_completed` potrebbe osservare un successo seguito dal fallimento del Run.

Contratto:

- `:inference_completed` è emesso dopo l'ack dell'Instance sulla receipt dell'attempt;
- `:result` è emesso dopo il commit canonico del Run e porta il `Spectre.Result` completo;
- `:failed` può seguire `:inference_completed` se il post-processing fallisce;
- un consumer che ignora `:result` ottiene comunque un Enumerable ben terminato.

`Spectre.stream/3` cambia inoltre la semantica di reply del chiamante. Oggi `handle/3` e `turn/3` sono `GenServer.call` a cui si risponde soltanto al terminale del Run (`instance.ex:2542-2553`, `put_caller/3` e `reply_caller/3`). `stream/3` risponde **subito** con l'handle e non usa quel percorso: la reply del caller diventa l'evento `:result` dell'Enumerable. Chi vuole il valore fuori dall'enumerazione usa `Spectre.await_result/2` sullo stesso handle, che è idempotente e servito dalla retention terminale della sessione.

### 1.3 Steering ed epoch

La prima slice non aggiorna `expected_stream_epoch` in-band.

Uno steer restart-based esegue questa transizione:

1. l'Instance valida Run, Invocation e `control_revision` attesi;
2. l'Instance committa il comando di steering;
3. il vecchio attempt viene marcato `:superseded` e il suo fence revocato;
4. viene creata una nuova Invocation con nuovo `attempt_id`, `invocation_id`, Run revision e `stream_epoch`;
5. viene creata una nuova sessione in `:awaiting_consumer`;
6. `steer/3` restituisce un nuovo Enumerable;
7. il vecchio Enumerable emette `:superseded` e termina.

Il vecchio Enumerable non deve mai emettere eventi del nuovo epoch. Questo mantiene locale e immutabile il suo fence.

L'identità è divisa così:

- `inference_id`: identità logica stabile dell'inferenza;
- `attempt_id`: singolo tentativo provider;
- `invocation_id`: singolo boundary dispatchabile, derivato deterministicamente da Run, inference, attempt e control revision;
- `stream_epoch`: singola continuità di data plane.

La race tra terminale e steer è decisa dalla serializzazione dell'Instance:

- se il terminale viene accettato prima, lo steer restituisce `:invocation_terminal`;
- se lo steer viene committato prima, il terminale vecchio è stale;
- può esistere al massimo una risposta delta già in volo verso il consumer; al `next` successivo il vecchio Enumerable riceve `:superseded`;
- il nuovo provider attempt non viene esposto finché il successor intent non è durevole.

La cancellazione remota del vecchio provider può restare ambigua. Il fencing impedisce comunque che il vecchio risultato venga applicato. La receipt di supersession deve distinguere `provider_cancel_confirmed` da `provider_cancel_ambiguous` e il budget deve riservare il worst case finché l'uso non è riconciliato.

Il control lane non va inventato da zero. `Spectre.Operation.Control` e `Spectre.Operation.Control.Command` (`operation/control.ex`, `operation/control/command.ex`) hanno già la semantica richiesta: `generation` monotona, un solo comando `pending`, idempotenza per command id con esito `{:duplicate, control}`, `status: :pending -> :committed -> :applied -> :rejected`, history bounded, `base_revision` atteso, e una sezione canonica `:control` che esiste già. Il `control_revision` di questo piano **è** quella `generation`. Lo steer va modellato come un `Command` della stessa forma, scoped su `inference_id` invece che su `loop_id`, così il vocabolario di controllo del runtime resta uno solo.

Native in-place steering è fuori dalla prima slice. Potrà essere aggiunto in seguito con un evento di controllo in-band e aggiornamento esplicito di `control_revision`, senza cambiare la semantica restart-based.

### 1.4 Observer lane

I raw delta non attraversano Registry e non entrano nella mailbox dell'Instance.

La sessione invia all'Instance heartbeat fenced e throttled, ma questi messaggi sono interni e non committati. L'Instance mantiene due clock distinti:

- `inference_liveness_clock`: aggiornato per ogni heartbeat valido, anche quando il commit è throttled;
- `inference_progress_commit_clock`: limita gli snapshot canonici osservabili.

Lo snapshot non contiene testo. Contiene soltanto latest-value bounded:

```elixir
%Spectre.Inference.Progress{
  inference_id: inference_id,
  invocation_id: invocation_id,
  attempt_id: attempt_id,
  run_revision: run_revision,
  generation: generation,
  dispatch_id: dispatch_id,
  control_revision: control_revision,
  stream_epoch: stream_epoch,
  sequence: sequence,
  output_bytes: output_bytes,
  usage: estimated_usage,
  usage_quality: usage_quality,
  provider_cursor_digest: cursor_digest,
  state: :awaiting_consumer | :opening | :streaming | :committing,
  at: timestamp
}
```

Il publish verso osservatori avviene soltanto dall'Instance, dopo un commit canonico riuscito.

Il vincolo Work/Vigil/Directive vive in `Spectre.Operation.Event` (la struct), non nel bus: `Spectre.Operation.Events` è un `Registry` duplicate keyed by instance ref con filtri (`operation/events.ex:13-26`). Si introduce quindi un **envelope tipizzato nuovo sullo stesso registry**, non un terzo processo Registry nell'albero applicativo: un host che osserva un agente deve avere una sola `subscribe/2` da chiamare. Attenzione al nome: `Spectre.Instance.Events` è già occupato (ammissione e autorizzazione degli eventi, `instance/events.ex`), quindi il modulo pubblico non può chiamarsi così.

Il lane è locale e dichiaratamente lossy e pubblica solo:

- `:progress_committed`;
- `:attempt_superseded`;
- `:terminal_committed`;
- `:stream_interrupted`.

Il fatto pubblicato deve essere derivabile dallo snapshot canonico e deve riportare `canonical_revision`.

Liveness e osservabilità hanno frequenze diverse. Default provvisori, da validare con benchmark:

- heartbeat sessione -> Instance: `1_000 ms`;
- progress snapshot canonico: `5_000 ms` quando il lane osservatori è abilitato;
- terminale: sempre committato immediatamente.

Non si usa il precedente `500 ms` di Operation Progress come default inference: con Ledger required produrrebbe due digest/receipt al secondo per stream senza aggiungere un boundary non deterministico. Il progress commit interval resta configurabile.

I due valori esistenti sono l'invio throttled del Runner (`operation_progress_interval`, default `100 ms`, `operation/runner.ex:122`) e il commit dell'Instance (`operation_progress_commit_interval`, default `500 ms`, `instance.ex:3414`). Oggi sono lo stesso gate: un progress scartato dal throttle non aggiorna nulla, nemmeno la liveness. La separazione dei due clock proposta qui è quindi anche una correzione del lane operativo esistente e va applicata a entrambi, non solo all'inference.

Il subscriber non è autorizzato: `Operation.Events.subscribe/2` registra qualunque processo possieda il ref dell'Instance. Con snapshot che contengono solo byte e usage il rischio è basso, ma è un canale laterale da dichiarare esplicitamente nell'ADR, e diventa una decisione di sicurezza vera nel momento in cui qualcuno propone di far passare testo sul lane osservatori (§8.5).

Lo snapshot inference deve vivere in una sezione canonica separata dal Run. Un progress commit non incrementa `Run.revision`, `attempt_id`, `control_revision` o `stream_epoch`, altrimenti renderebbe stale la Invocation attiva.

L'elenco delle sezioni canoniche è oggi chiuso: progress e receipt outbox richiedono quindi un Canonical schema v3 con decoder backward-compatible per v2 e default vuoti per le nuove sezioni. Questa migrazione è distinta dal Run v3, anche se conviene consegnarle nella stessa release compatibile.

### 1.5 Budget mid-stream

L'Instance è proprietaria del budget aggregato; la sessione riceve uno snapshot immutabile per il singolo attempt.

```elixir
%Spectre.Inference.BudgetSnapshot{
  inference_id: inference_id,
  attempt_id: attempt_id,
  deadline_at: deadline_at,
  remaining: %{
    input_tokens: integer_or_nil,
    output_tokens: integer_or_nil,
    total_tokens: integer_or_nil,
    cost: number_or_nil,
    duration_ms: integer_or_nil
  },
  reserved: reserved_usage,
  pricing_ref: pricing_ref_or_nil,
  estimation_policy: :provider | :conservative | :unavailable
}
```

La sessione applica:

- hard deadline assoluto;
- limite byte/evento come safety bound;
- usage incrementale autorevole quando il provider lo fornisce;
- stima conservativa quando disponibile;
- cancellazione immediata quando un limite verificabile è superato.

L'Instance applica:

- riserva prima del dispatch;
- budget complessivo tra fallback e steering attempts;
- settlement idempotente del terminale;
- conservazione della riserva in caso di outcome `:ambiguous`;
- rilascio o correzione dopo reconciliation.

Il deadline assoluto non viene mai esteso da un heartbeat. Sono distinti:

- deadline totale: limite duro dell'attempt;
- provider stall timeout: rinnovato solo da progress provider valido quando esiste demand;
- consumer idle timeout: applicato quando non esiste demand;
- attach timeout: applicato prima che esista un consumer.

Un `maximum_output_tokens` viene sempre inviato al provider. Senza tokenizer o usage incrementale affidabile, Spectre non deve dichiarare enforcement token-exact durante lo stream: usa una riserva/worst-case e marca la misura `:estimated`. Anche un limite di costo è hard soltanto se il profilo selezionato porta una pricing ref verificabile e l'usage è disponibile; `cost_tier` da solo non basta.

### 1.6 Consumer mai attachato

La sessione nasce dopo che la Invocation è stata committata, ma il provider non viene aperto finché il consumer non reclama lo stream e produce il primo demand.

Lo stato `:awaiting_consumer` ha un timeout obbligatorio. Alla scadenza:

1. la sessione costruisce un terminal worker receipt fenced;
2. outcome: `:consumer_never_attached`;
3. `provider_started: false` e usage zero;
4. l'Instance valida la receipt;
5. l'Instance committa il Run terminale e il terminal receipt portabile;
6. ownership, state lock e timer vengono rimossi;
7. l'idle shutdown può tornare eleggibile.

Per la prima slice questo outcome usa il terminal failure path del Run con una ragione tipizzata; non richiede l'aggiunta immediata di un nuovo `Run.status`. La receipt conserva la classificazione semantica `:cancelled_before_provider_start`.

Un attach tardivo riceve `:stream_expired` o, durante la retention terminale della sessione, il terminale originale. Non può riaprire la Invocation.

Default provvisorio: `stream_attach_timeout: 30_000`, configurabile e sempre finito salvo opt-in esplicito.

### 1.7 Morte dell'Instance e restart

La sessione monitora sia consumer sia Instance.

Se muore il consumer:

- `after_fun` effettua cleanup nei casi normali;
- il monitor copre kill e crash che non eseguono `after_fun`;
- con la policy iniziale `:cancel`, la sessione chiede il terminale al control plane;
- cleanup e cancel sono idempotenti.

Se muore l'Instance:

- la sessione revoca il data plane locale;
- prova a cancellare il provider;
- consegna `:interrupted` al consumer se ancora raggiungibile;
- non prova a committare contro un nuovo owner;
- termina dopo una retention limitata.

La nuova Instance usa una nuova generation, quindi qualsiasi messaggio vecchio è stale. Il Run ripristinato segue la recovery matrix. Il vecchio Enumerable non riprende: il chiamante usa un'API esplicita `Spectre.resume_stream/3` per ottenere un nuovo Enumerable e un nuovo epoch.

### 1.8 Contenuto provvisorio e sanitizzazione incrementale

Oggi ogni testo che diventa `reply_text` passa da `Spectre.Reply.Sanitizer` (`runtime/action_planner.ex:76,129`), che rimuove `<think>`, `<al>`, `<intent>`, `<reply>` e le righe di controllo `INTENT:`/`AL:`. Streammare i delta grezzi consegnerebbe all'utente reasoning e markup di controllo; peggio, un marker può essere spezzato tra due delta, quindi un sanitizer per-delta non lo vedrebbe.

Regole normative:

- i delta sono **provvisori** per contratto: nessun contenuto streammato è deliverable finché il terminale non ha superato sanitizer e guard;
- la sessione applica un sanitizer incrementale con lookahead limitato: trattiene un suffisso lungo quanto il marker più lungo e lo rilascia solo quando non può più iniziare un token di controllo;
- il lookahead è un bound esplicito (`max_sanitizer_lookahead_bytes`), non un buffer libero;
- ogni `StreamEvent` porta `content_class: :provisional | :sanitized`;
- con `sanitize_reply: false` i delta sono marcati `:unsanitized`, mai promossi in silenzio.

Un planner che prende ownership della pulizia con `clean_reply/3` deve dichiarare se è incrementale. Se non lo è, lo streaming per quel purpose viene rifiutato, non degradato (§1.9).

### 1.9 Ammissibilità dello streaming (fail-closed)

Lo streaming è rifiutato, non degradato, quando:

- il purpose pianifica azioni (`plan_actions?`): l'output contiene markup destinato al planner, non testo per l'utente;
- la richiesta chiede structured output (`Inference.Constraints.structured_output?`);
- il profilo selezionato non dichiara `:stream` nel catalogo Prism (§4.1);
- il transport configurato non implementa il contratto pull (§4.1);
- un `clean_reply/3` non incrementale possiede la pulizia (§1.8).

`Spectre.stream/3` restituisce `{:error, {:streaming_unsupported, reason}}`. Nessun percorso torna silenziosamente a one-shot: il chiamante deve poter distinguere "non supportato" da "fallito".

### 1.10 Costo di serializzazione dell'Instance

Lo `state_lock` viene impostato al dispatch (`instance.ex:2065`), ogni altro turno riceve `:instance_state_locked` (`instance.ex:2095`) e finché il lock esiste `maybe_schedule/1` non avvia lavoro operativo (`instance.ex:2503`). Uno stream lungo serializza quindi il soggetto per tutta la sua durata.

È la semantica voluta — un soggetto, un turno — ma va vincolata e documentata:

- durata massima dura per stream (`stream_max_duration_ms`), distinta dal budget e mai estesa dal progress;
- il control lane (cancel/steer) è l'unica eccezione ammessa al lock;
- `busy?` e `live_runs?` (`instance.ex:2629-2637`) contano già invocation attive e Run non terminali: senza il terminale obbligatorio di §1.6, uno stream abbandonato bloccherebbe l'idle shutdown per sempre.

### 1.11 Ammissione delle sessioni

Per i runner operativi esiste già un tetto: `@default_max_operation_runners 8` (`instance.ex:78`, verifica a `instance.ex:2849`). Lo streaming non ha l'analogo: con `stream_attach_timeout: 30_000` un chiamante può accumulare sessioni mai attachate finché i timeout non scadono. Servono:

- `max_stream_sessions` per Instance, verificato **prima** di committare la Invocation;
- un cap di nodo sul DynamicSupervisor delle sessioni;
- `Spectre.stream/3` che restituisce `{:error, :stream_capacity_exhausted}` senza mettere in coda.

## 2. Architettura target

```text
Consumer process
    |
    | Enumerable pull / cancel / steer
    v
Spectre.Inference.StreamSession (:gen_statem, temporary)
    |                         |
    | normalized events       | heartbeat throttled
    v                         v
Prism StreamAdapter        Spectre.Instance
    |                      Run / fences / budget / receipt / commit
    | :httpc {self, once}
    v
Provider

Spectre.Instance -- post-commit event --> Spectre.Inference.Events observers
Spectre.Instance -- portable receipt --> ReceiptSink --> Spectre Ledger v2
```

L'Instance non è un data plane. Riceve soltanto:

- attach/control lifecycle;
- heartbeat throttled;
- terminal worker receipt;
- process DOWN.

La sessione è raggiungibile via `Registry` unique dedicato (chiave = `invocation_id`), non via pid nell'handle (§1.2). Il supervisore non è nuovo per concetto: `Spectre.Operation.RunnerSupervisor` (`operation/runner_supervisor.ex`) è già un DynamicSupervisor `:one_for_one` di processi temporanei a un tentativo, e `Spectre.Operation.Runner` implementa già la maggior parte del protocollo sessione — processo temporaneo, progress fenced e throttled, terminale inviato all'owner, cap di ammissione. Va generalizzato quel supervisore invece di clonarne uno parallelo, così lo streaming eredita gratis il modello di capacità e di monitoraggio.

## 3. State machine dello stream

```text
:reserved
    |
    v
:awaiting_consumer -- attach timeout --> :committing_terminal
    |
    | first demand
    v
:opening -- open timeout --> :cancelling
    |
    | provider stream_start
    v
:streaming -- provider terminal --> :committing_terminal
    |   |
    |   +-- consumer idle/stall/budget --> :cancelling
    |   +-- steer committed ------------> :superseded
    |
    v
:committing_terminal -- Instance ack --> :terminal

qualsiasi stato non terminale -- Instance DOWN --> :interrupted
qualsiasi stato non terminale -- consumer DOWN --> :cancelling
```

La sessione ha al massimo un `next` call pendente. Questo rende bounded anche la mailbox del consumer e limita a uno il delta logico in volo.

Una sola call pendente non significa un evento per call. Una call sincrona per token costerebbe un round-trip per delta; `Stream.resource/3` può emettere una **lista** per ogni `next_fun`, quindi il protocollo è a credito: il consumer chiede fino a `n` eventi logici e la sessione risponde con un batch (con attesa massima). La backpressure resta identica — il credito è il bound — ma il numero di messaggi cala di un ordine di grandezza.

`:gen_statem` non è ancora usato in `lib/` (tutto il runtime è GenServer). È stdlib, quindi non aggiunge dipendenze, ma è un idioma nuovo per il repository: gli state timeout (attach, open, stall, consumer idle) e `postpone` per il demand che arriva in `:opening` sono esattamente ciò che giustifica l'introduzione, e vanno citati nell'ADR come motivazione.

Stati terminali osservabili:

- `:completed`;
- `:failed`;
- `:cancelled`;
- `:superseded`;
- `:interrupted`;
- `:ambiguous`.

Il processo usa `restart: :temporary`: il retry semantico appartiene all'Instance, non al supervisor.

## 4. Contratto Core <-> Prism

Il behavior è definito nel core; Prism lo implementa senza possedere scheduling o continuity.

```elixir
defmodule Spectre.Inference.StreamAdapter do
  @callback capabilities(profile(), keyword()) :: MapSet.t()

  @callback open(descriptor(), keyword()) ::
              {:ok, adapter_state(), provider_metadata()}
              | {:error, term()}

  @callback request_transport_item(adapter_state()) ::
              {:ok, adapter_state()}
              | {:error, term()}

  @callback handle_transport(term(), adapter_state()) ::
              {:ok, [Spectre.Inference.ProviderEvent.t()], adapter_state()}
              | {:ignore, adapter_state()}
              | {:error, term(), adapter_state()}

  @callback cancel(adapter_state(), term()) ::
              :ok | {:error, term()}

  @callback resume(descriptor(), cursor(), keyword()) ::
              {:ok, adapter_state(), provider_metadata()}
              | {:error, term()}

  @callback reconcile(descriptor(), provider_request_id(), keyword()) ::
              {:ok, terminal_result()}
              | :pending
              | :not_found
              | {:error, term()}
end
```

`open/2` viene chiamato nel processo sessione, così il receiver predefinito di `:httpc` è il `:gen_statem`.

Eventi provider normalizzati:

```elixir
{:started, provider_request_id, cursor}
{:delta, provider_sequence, binary, cursor}
{:usage, usage, quality}
{:completed, response}
{:failed, reason}
```

Capability iniziali:

- `:one_shot`;
- `:stream`;
- `:pull_transport`;
- `:push_transport`;
- `:cancel`;
- `:resume`;
- `:reconcile`;
- `:incremental_usage`;
- `:native_steer` riservata, non usata nella prima slice.

### 4.1 Dove vivono capability e transport in Prism

Due dettagli del repository Prism che il contratto deve rispettare.

**La capability è già esprimibile.** I cataloghi degli adapter dichiarano per profilo `supports: [:text, :structured_output]` (`spectre_prism/lib/spectre/prism/adapters/open_router.ex:35`) e il core lo verifica in `Inference.Profile` (`inference/profile.ex:89-92`). Aggiungere `:stream` a quella lista è il meccanismo naturale: `capabilities/2` resta per le proprietà di sessione (resume, reconcile, incremental usage), ma la disponibilità dello streaming per un profilo si negozia dove si negoziano già le altre.

**Il transport è pluggabile e oggi non sa streammare.** `Spectre.Prism.Adapter.Transport` espone solo `request/5` (`prism/adapter/transport.ex`) e gli host possono iniettare la propria implementazione con `transport:` (Finch, Mint, Req). Se il pull `{self, :once}` resta nascosto dentro `Spectre.Prism.Adapter.HTTP`, un transport custom rompe lo streaming in silenzio.

Il contratto pull va quindi aggiunto come callback opzionali del `Transport`:

```elixir
@callback stream_open(method(), String.t(), headers(), body(), keyword()) ::
            {:ok, transport_ref()} | {:error, term()}

@callback stream_next(transport_ref()) :: :ok | {:error, term()}

@callback stream_close(transport_ref()) :: :ok

@optional_callbacks stream_open: 5, stream_next: 1, stream_close: 1
```

Negoziazione fail-closed: un transport che non esporta i tre callback declassa il profilo a `:one_shot` e `Spectre.stream/3` risponde `{:error, {:streaming_unsupported, :transport}}` (§1.9). Nessun fallback implicito a buffering completo della risposta.

### 4.2 Demand e bound

Consumer demand e transport demand non sono la stessa unità. Un evento SSE può attraversare più chunk o più eventi possono condividere un chunk. La sessione continua a richiedere transport item finché Prism produce almeno un evento logico.

Bound obbligatori:

- `max_transport_chunk_bytes`;
- `max_parser_residual_bytes`;
- `max_provider_event_bytes`;
- `max_events_per_transport_item`;
- buffer bounded per adapter push;
- nessuna policy drop per il testo.

Overflow termina con `:provider_stream_overflow` o `:consumer_too_slow`; non scarta silenziosamente contenuto.

## 5. Modello Run e Invocation

### 5.1 Run v3

Il writer passa a Run v3; il reader continua ad accettare Run v2.

Nuova continuazione portabile:

```elixir
%Spectre.Run.InferenceContinuation{
  inference_id: inference_id,
  purpose: :response_generation,
  descriptor: descriptor,
  frozen_selection: selection_or_nil,
  attempt: 1,
  previous_attempts: [],
  invocation: invocation_or_nil,
  control_revision: 0,
  stream_epoch: nil,
  provider_status: :not_started,
  provider_request_id: nil,
  resume_cursor: nil,
  budget: budget,
  postprocessor: :response_generation,
  recovery: recovery_state
}
```

Il descriptor non contiene PID, sessioni, callback, client o credenziali. Gli attuali `llm_opts` vengono divisi in configurazione portabile e runtime binding risolto localmente.

La separazione è già enforceable meccanicamente: `Spectre.Run.Value.validate/2` rifiuta pid, port, reference e function (`run/value.ex:24`) e `Invocation.from_effect/2` solleva su valore non portabile (`invocation.ex:84-87`). Va usato quel validatore, non una nuova convenzione.

Conseguenza da accettare esplicitamente: oggi `model:` può essere una funzione anonima e i `@runtime_opt_keys` includono `:instance_pid` e `:actions_module` (`runtime/llm.ex`). Se il binding provider non è risolvibile da un `model_profile_ref` portabile, il Run **non è recuperabile**. Questa classificazione va fatta all'ammissione e resa visibile (`recoverable?: false` sulla continuazione), non scoperta al restart quando non c'è più nulla da fare.

### 5.2 Invocation inference

`Spectre.Invocation.kind` diventa:

```elixir
:effect | :inference
```

Ogni provider attempt è una Invocation distinta. Selezione e dispatch intent sono committati prima della chiamata esterna in modalità required.

L'attuale `Invocation.Receipt` resta interno e viene rinominato concettualmente `Invocation.WorkerReceipt`; la receipt portabile è un tipo separato.

### 5.3 Pipeline

```text
input admitted
  -> prompt/descriptor
  -> selection frozen
  -> inference Invocation
  -> session/one-shot provider attempt
  -> terminal worker receipt
  -> portable boundary receipt
  -> post-processing/action planning
  -> canonical Run commit
```

Ordine dei call site da migrare:

1. response generation;
2. route classification;
3. policy prompts;
4. cognitive operations.

## 6. Receipt foundation nel core

### 6.1 Envelope

Il core contiene già otto tipi di receipt (`gate/receipt.ex`, `prompt/receipt.ex`, `router/receipt.ex`, `operation/delivery/receipt.ex`, `execution/migration/receipt.ex`, `invocation/receipt.ex`, più i ref associati). L'envelope non deve diventare il nono modello di evidenza parallelo: deve **avvolgerli come payload tipizzati per `kind`**, così l'evidenza esistente entra nella catena senza essere riscritta.

Per la forma, il precedente da seguire è `Spectre.Event.Envelope` (`event/envelope.ex`): ha già `schema_version`, id deterministico, `payload_schema_ref` risolto via `Spectre.Event.SchemaRegistry`, `provenance`, `authenticity`, `admission_receipt` e validazione di portabilità su `Spectre.Canonical.Value`. La classe di privacy si appoggia a `Spectre.SensitiveData` e `Spectre.Experience.Redactor` (denylist costituzionale non rimovibile), non a una nuova lista.

```elixir
%Spectre.Receipt.Envelope{
  schema_version: 1,
  id: deterministic_receipt_id,
  kind: kind,
  instance_ref: instance_ref,
  run_id: run_id,
  run_revision: run_revision,
  inference_id: inference_id,
  invocation_id: invocation_id,
  attempt_id: attempt_id,
  control_revision: control_revision,
  stream_epoch: stream_epoch,
  canonical_revision: canonical_revision,
  correlation_id: correlation_id,
  causation_id: causation_id,
  definition_ref: definition_ref,
  manifest_digest: manifest_digest,
  closure_digest: closure_digest,
  pre_state_digest: pre_digest,
  post_state_digest: post_digest,
  payload: payload_or_nil,
  payload_ref: encrypted_blob_ref_or_nil,
  privacy: privacy_class
}
```

Receipt kind iniziali:

- `:run_input_admitted`;
- `:inference_selected`;
- `:inference_attempt_started`;
- `:inference_attempt_terminal`;
- `:inference_attempt_superseded`;
- `:inference_consumer_never_attached`;
- `:policy_decision`;
- `:authority_decision`;
- `:effect_terminal`;
- `:action_terminal`;
- `:nondeterminism_sample`;
- `:canonical_commit`.

I progress heartbeat non sono boundary receipt. Se uno snapshot progress viene committato, il Ledger vede il digest del canonical commit ma non serve una receipt provider separata.

Collisione di nomi da risolvere prima di scrivere codice: `Spectre.Ledger.Receipt` **oggi esiste già e significa "ack di un append di checkpoint"** (`spectre_ledger/lib/spectre/ledger/receipt.ex`). I tre concetti vanno separati nominalmente in tutti e tre i repository:

- `Spectre.Invocation.WorkerReceipt` — evidenza interna con capability BEAM;
- `Spectre.Receipt.Envelope` — evidenza portabile di boundary;
- `Spectre.Ledger.AppendAck` — conferma di scrittura (rename del tipo attuale).

### 6.2 Sink modes

```elixir
receipt_mode: :disabled | :observational | :required
```

Behavior minimo:

```elixir
@callback append(Envelope.t(), keyword()) ::
  {:ok, :appended | :idempotent}
  | {:error, :ambiguous | term()}

@callback lookup(String.t(), keyword()) ::
  {:ok, Envelope.t()} | :not_found | {:error, term()}
```

In `:required` il core usa un outbox canonico bounded:

1. receipt intent e transizione vengono committati insieme;
2. viene attraversata una durability barrier del checkpoint;
3. il sink riceve un append idempotente;
4. l'ack rimuove o marca l'entry;
5. il restart drena l'outbox prima di lavoro confliggente;
6. outbox pieno blocca l'admission, non scarta evidenza.

L'outbox contiene **solo id, digest e riferimento**, mai il payload. `Canonical.Codec.encode/1` ri-serializza tutte le sezioni ad ogni commit e il checkpoint ha un tetto duro (`@max_json_bytes 8_000_000`, `canonical/codec.ex:12`; il Run ha il proprio a 2 MB, `run/codec.ex:33`): un outbox con contenuto dentro la sezione canonica competerebbe con quel budget e moltiplicherebbe il costo di ogni commit. Il payload è content-addressed nel sink. Massimo numero di entry esplicito e configurabile.

### 6.3 State digest

Implementare `Canonical.state_digest/1` con hash per sezione e root complessivo.

Non serve un algoritmo nuovo: `Spectre.Canonical.Value.digest/1` e `Spectre.Execution.PortableDigest` (`execution/portable_digest.ex`) fanno già canonicalizzazione deterministica e digest, con ordinamento stabile delle mappe. `state_digest/1` è un fold per sezione sopra a questi.

Il semantic state root include schema, revisione e sezioni autorevoli, ma esclude:

- transition journal;
- applied-change cache;
- receipt delivery/outbox metadata;
- clock OTP effimeri.

La sezione progress canonica è inclusa quando presente; per questo il suo commit interval deve restare ragionevole.

## 7. Recovery matrix

| Stato durevole | Capability provider | Azione |
|---|---|---|
| Awaiting consumer, provider non iniziato | qualsiasi | crea nuova sessione/Enumerable |
| Selezionato, non dispatchato | qualsiasi | dispatch sicuro |
| Dispatch incerto | `:reconcile` | lookup provider request |
| Stream attivo | `:resume` + cursor | nuovo epoch e nuovo Enumerable |
| Stream attivo | nessuna recovery | `:interrupted` o `:ambiguous` |
| Terminal receipt presente | qualsiasi | applicazione idempotente |
| Cancel richiesto senza conferma | nessuna reconcile | `:ambiguous` |
| Vecchio attempt superseded | qualsiasi | scarta ogni delta/terminale vecchio |

Regola fondamentale: un restart non unisce mai due stream. Il consumer vecchio vede `:interrupted`; un eventuale resume produce un nuovo Enumerable.

### 7.1 Fence ridotti per le receipt recuperate

La riga "terminal receipt presente -> applicazione idempotente" non è implementabile con il fence attuale. `Invocation.Receipt` fenza su `capability: reference()` (`invocation/receipt.ex:35`) e su `generation`, un uuid7 rigenerato ad ogni start dell'Instance (`instance.ex:763`): **nessuno dei due sopravvive al restart**, ed è giusto così per il percorso caldo, perché è quello che rende stale ogni messaggio di una sessione morta.

Serve quindi un secondo percorso di validazione, dichiarato e testato separatamente:

| Percorso | Fence richiesti |
|---|---|
| Receipt in-process (caldo) | invocation_id, run_id, run_revision, generation, dispatch_id, capability |
| Receipt recuperata (restart) | invocation_id, run_id, run_revision, attempt_id, digest dell'envelope durevole |

Il percorso recuperato non accetta mai una receipt che non sia già durevole nel sink o nell'outbox: la sua autenticità viene dal digest, non dalla capability BEAM. Va scritto esplicitamente nell'ADR, altrimenti in implementazione qualcuno indebolirà il fence del percorso caldo per far passare quello freddo.

## 8. Sicurezza: superficie di attacco e piano di contenimento

Principio guida di questa sezione:

> I controlli di sicurezza vivono nei seam di estensione già esistenti. Il core acquisisce soltanto ciò che nessun pacchetto può garantire dall'esterno: la propagazione della classe di fiducia.

### 8.1 Cosa il core già garantisce

Va scritto perché nessun pacchetto lo riscriva e nessuna review lo rimetta in discussione.

- **Trust model del prompt, enforced a compile time.** `Fragment` ha `@trust_classes [:instruction, :data]` (`prompt/fragment.ex:15`) e `Operation.trust/2` solleva `ArgumentError` se un provider dinamico punta a `:instructions` o `:task` (`prompt/operation.ex:127-130`). Il target `:context` è sempre `:data`; per gli adapter legacy il contenuto è racchiuso in `<spectre-context trust="data">` (`prompt/plan.ex:9-15`).
- **I dati runtime non introducono codice.** I fragment canonici rifiutano EEx e usano la grammatica chiusa `{{path.to.value}}`; `Fragment.close_template/1` migra solo il sottoinsieme sicuro e rifiuta i tag rimanenti (`prompt/fragment.ex:141-154`).
- **Path traversal chiuso** sugli asset: `contained_path/2` espande, verifica il contenimento e ri-canonicalizza i symlink (`runtime/prompt.ex:120-135`).
- **Il planner non può iniettare un'implementazione.** Il provider è ri-risolto dalla Definition compilata e lo `schema_hash` è verificato (`action/spec.ex:5-7`, `action/provider.ex:57-69`).
- **Bound espliciti**: `action_max_bytes`, `action_result_max_bytes`, `effect_payload_max_bytes`, `effect_result_max_bytes`, `@default_max_fragment_bytes 64_000`, `@default_max_prompt_bytes 256_000`.
- **Autorità non auto-generabile**: i grant sono l'intersezione della richiesta con un ceiling dell'host (`authority/envelope.ex`).
- **Identità esterna opaca**: nessun match per nome, numero o testo del messaggio (`external_identity.ex`).
- **Delivery proattiva gated**: consent revocabile e con scadenza per destinazione (`operation/delivery/consent.ex`).
- **Redaction deterministica** key-based con denylist costituzionale non rimovibile (`experience/redactor.ex`, `sensitive_data.ex`).
- **Sanitizer dei control token** su ogni `reply_text` (`reply/sanitizer.ex`).

### 8.2 Buchi verificati

**A. Il template base scavalca il trust boundary.**
`do_render_asset/4` legge il `.text.heex` e lo valuta con `EEx.eval_string` su assigns che includono `input`, `state`, `recent_chat`, `memory` e l'intero `ctx.assigns` (`runtime/prompt.ex:455-475`); il risultato diventa `Fragment.base/1` con `trust: :instruction` (`prompt/fragment.ex:96`). Un `<%= @input.text %>` o `<%= @recent_chat %>` — il modo normale di scrivere prompt in questo DSL — colloca quindi testo controllato dall'attaccante dentro un frammento a fiducia istruzione, saltando esattamente la barriera che `inject` protegge a compile time.

**B. Gli argomenti delle azioni non sono validati contro lo schema.**
`Action.Spec` porta `schema` e `schema_hash`, e l'hash è verificato, ma al dispatch si controlla solo la dimensione (`runtime/action_dispatcher.ex:38-40`). Un modello manipolato non può cambiare quale modulo esegue, ma può passare qualunque valore: destinatario, importo, identificatore di un altro subject, path. Il punto di veto esiste (`before_action`, `runtime/action_guards.ex`) ma è ad hoc e riscritto da ogni host.

**C. Nessuna etichetta di provenienza sul contenuto.**
Risultati d'azione e memoria rientrano nel turno successivo attraverso gli stessi assigns, quindi ricadono in A: è l'injection indiretta, la variante più difficile da notare. `Input.Source` ha `kind`, `mount`, `actor_id` ma nessuna classe di fiducia; `Event.Envelope` ha `authenticity` e `provenance` che però non arrivano fino al prompt.

### 8.3 Estensioni fuori dal core

Tutte impacchettabili come `Spectre.Stack.Installable`, quindi versionate e verificabili come gli altri satelliti.

| # | Seam esistente | Controllo |
|---|---|---|
| 1 | `Spectre.Input.Plug` (supporta già `{:halt, input}` e `{:error, reason}`; `rehearsable?/0` mantiene il replay) | Ammissione fail-closed: normalizzazione Unicode (confusables, bidi override, zero-width), limiti di lunghezza ed entropia, pattern noti di injection, marcatura `Input.put_meta(:trust, :untrusted)`. Deterministico, nessun LLM. |
| 2 | `Spectre.Router.Plug` su `Router.Context` (precedente: `router/plugs/terminalize.ex`) | Quarantena di routing: con rischio alto la route diventa una policy di conferma invece dell'azione diretta. |
| 3 | `before_action` guards (`runtime/action_guards.ex`) | Validatore di argomenti schema-driven, legge `Action.Spec.schema`. `{:error, _}` fail closed, `{:suppress, text}` degrada a risposta. Chiude **B**. |
| 4 | `Effect.Executor.Mount` e `Action.Provider.Mount` | Wrapper di egress: allowlist di domini, blocco di esfiltrazione via URL, rate limit per subject. La maggior parte degli exploit reali di agenti termina in una richiesta verso un dominio dell'attaccante. |
| 5 | `Spectre.Doctor` (report read-only a check nominati) | Check statici: asset che interpolano assigns non fidati (rilevabili con lo stesso `@legacy_placeholder` di `prompt/fragment.ex:20`), azioni `visibility: :planner` senza `protect`, executor senza allowlist, `sanitize_reply: false`, consent senza scadenza. |

### 8.4 Le due modifiche al core

1. **Trust sul contenuto interpolato, non solo sul frammento.** Un helper `Spectre.Prompt.data/1` che avvolge un valore nel boundary `trust="data"` con escaping, più un check che segnala `@input`, `@recent_chat` e `@memory` nudi dentro asset a trust istruzione — prima come diagnostica Doctor, poi eventualmente a compile time. Migra il caso comune senza rompere nulla e la strada lunga è già tracciata da `Fragment.close_template/1`. Chiude **A**.
2. **Classe di fiducia propagata.** Un campo `trust`/`provenance` su `Input.Source` e sul risultato d'azione, trasportato dal materializer fino al fragment. È l'abilitatore di tutto il resto: senza etichetta ogni plugin deve indovinare cosa è untrusted. Il precedente di forma è `Event.Envelope.authenticity`. Chiude **C**.

Nessuna delle due cambia il modello di esecuzione, le sezioni canoniche o il contratto Run.

### 8.5 Superficie aggiunta dallo streaming

- Oggi la decisione "questa risposta è consegnabile" avviene sul testo completo. I delta bypassano il sanitizer e, con un guard di sicurezza attivo, bypassano anche il punto di veto: da qui la regola di §1.8, i delta sono provvisori per contratto.
- Il lane osservatori non autorizza i subscriber: `Operation.Events.subscribe/2` registra qualunque processo abbia il ref (§1.4). Con soli byte e usage il rischio è basso; se qualcuno proporrà di far passare testo sul lane, diventa un canale di esfiltrazione e richiede autorizzazione esplicita.
- Il cap di sessioni (§1.11) e la durata massima (§1.10) sono controlli di disponibilità, non solo di igiene: senza di essi lo streaming è un amplificatore di denial of service per subject.
- Un `provider_request_id` e un cursore di resume sono identificatori del provider: non entrano in payload osservabili né in log non digested.

### 8.6 Cosa non fare

Nessun rilevatore di prompt injection LLM-based dentro il core: non è deterministico, non è replayable e romperebbe rehearsal e governance. Sta in un pacchetto, dietro `Input.Plug`, opt-in.

### 8.7 Ordine consigliato

1. check Doctor di sicurezza (giorni, zero rischio, dà segnale su codice reale);
2. guard di validazione argomenti (chiude B);
3. input plug di ammissione;
4. wrapper di egress;
5. propagazione del trust nel core (A e C), consegnata insieme alla prima release che tocca il prompt layer.

I punti 1 e 2 sono indipendenti da tutto il resto di questo piano e possono partire subito.

## 9. Fasi di implementazione

Deliverable trasversali, richiesti da ogni fase che tocca uno schema. Sono disciplina già consolidata in questo repository e il piano li dava per impliciti:

- fixture permanente congelata della release precedente prima di introdurre il nuovo writer;
- documento `docs/MIGRATING_TO_*.md` per ogni bump (Run 2 -> 3, checkpoint 2 -> 3);
- aggiornamento di `Spectre.Foundation.Conformance` e `docs/FOUNDATION_CONFORMANCE.md`;
- allineamento di `docs/ROADMAP.md`, che oggi pinna Run `2 / [1, 2]` e checkpoint `2 / [2]`;
- copertura mantenuta sopra la soglia di progetto (`test_coverage: [summary: [threshold: 95]]` in `mix.exs`);
- property test con `stream_data` (già dipendenza di test) per gli invarianti di sequenza e fencing.

### Fase 0 — ADR e test delle invarianti

Deliverable:

- ADR ownership Core/Prism/Ledger;
- ADR stream delivery e restart;
- ADR steering replacement semantics;
- ADR observer lane post-commit;
- ADR receipt modes e replay claims;
- ADR sicurezza: trust boundary del prompt, contenuto provvisorio, seam dei controlli (§8);
- fake stream adapter e fault-injection harness.

Gate:

- tutte le transizioni terminali e le race terminal-vs-steer sono descritte come test eseguibili;
- il threat model di §8 elenca per ogni buco il controllo che lo chiude e il test che lo prova.

### Fase 1 — Riparare la recovery Run esistente

Core:

- persistere input normalizzato o `StartContinuation` prima dell'enqueue: il Run viene già committato prima della coda, ma la entry `%{input, opts}` vive solo in memoria e il checkpoint conserva l'input logico con `raw: nil` (`run/codec.ex:120-122`, `logical_input/1`);
- ripristinare e schedulare Run `:ready` recuperabili: oggi `restore_runs/5` li ricarica (`instance.ex:4107`) ma `recover_operational_state/1` ricostruisce soltanto i loop operativi (`instance.ex:3518`);
- classificare Run `:awaiting` al restart;
- marcare `recoverable?: false` all'ammissione quando il binding non è portabile (§5.1);
- impedire Run non terminali senza continuazione dispatchabile;
- aggiungere crash test tra admission, enqueue, worker e commit.

Gate:

- nessun input ammesso viene perso;
- nessun Run orfano blocca permanentemente idle shutdown.

### Fase 2 — Receipt envelope, state root e outbox

Core:

- introdurre `Spectre.Receipt.Envelope`;
- introdurre `ReceiptSink` e i tre modes;
- implementare receipt IDs deterministici;
- implementare state root per sezione;
- introdurre Canonical schema v3 con reader v2 e sezioni bounded per inference progress e receipt outbox;
- implementare memory sink con conformance suite;
- implementare outbox required e durability barrier;
- definire privacy/blob references.

Gate:

- dopo ogni crash simulato una required receipt è nel sink oppure recuperabile dall'outbox.

### Fase 3 — One-shot inference come Invocation

Core:

- Run v3 con reader v2;
- `InferenceContinuation`;
- `Invocation.kind: :inference`;
- descriptor portabile e runtime bindings separati;
- selezione congelata prima del provider;
- fallback come attempt distinti;
- terminal receipt prima del post-processing;
- migrazione response generation, classifier e policy.

Prism:

- dichiarare capability `:one_shot`;
- bridge degli adapter attuali nel nuovo lifecycle.

Gate:

- kill in ogni boundary non duplica né perde un attempt;
- gli adapter sincroni esistenti continuano a funzionare.

### Fase 4 — Contratto streaming Prism

Core:

- aggiungere `StreamAdapter` e tipi `ProviderEvent`;
- conformance suite capability-based.

Prism:

- callback opzionali di streaming sul behaviour `Transport` e negoziazione fail-closed (§4.1);
- capability `:stream` dichiarata nel catalogo per profilo;
- transport async `:httpc` con `{stream, {self, :once}}`;
- parser SSE incremental bounded;
- OpenRouter stream normalization;
- Ollama stream normalization;
- cancellation best-effort con outcome esplicito;
- usage e provider request ID normalizzati.

Gate:

- un server TCP/SSE locale di test prova split event, multi-event chunk, oversize, error response, disconnect e cancel race.

### Fase 5 — Enumerable e `:gen_statem`

Core:

- `%Spectre.Inference.Stream{}` one-shot che implementa `Enumerable`, con identificatori e non pid;
- `Stream.resource/3` come facade, con `next_fun` a credito che emette batch;
- `StreamSession` temporary `:gen_statem`;
- Registry unique delle sessioni per lookup di cancel/steer/resume;
- supervisor runtime generalizzato a partire da `Operation.RunnerSupervisor`;
- cap di ammissione `max_stream_sessions` per Instance e per nodo (§1.11);
- sanitizer incrementale con lookahead bounded e `content_class` sugli eventi (§1.8);
- rifiuto fail-closed dei purpose non ammissibili (§1.9);
- attach token come autorizzazione dell'handle, non come mutua esclusione;
- monitor consumer e Instance;
- un solo `next` call pendente;
- fencing di ogni evento;
- terminal response trattenuta fino all'ack dell'Instance;
- attach/consumer/provider/cancel timeout;
- terminal retention bounded.

Gate:

- mailbox e memoria restano bounded con consumer fermo;
- `Enum.take/2`, eccezioni e `Process.exit(pid, :kill)` chiudono correttamente la sessione;
- `:inference_completed` non è osservabile prima dell'ack dell'Instance e `:result` non lo è prima del commit canonico;
- nessun delta esce con `content_class: :sanitized` senza essere passato dal sanitizer incrementale;
- superato il cap di sessioni, `Spectre.stream/3` rifiuta invece di accodare.

### Fase 6 — Steering, progress, budget e recovery

Core:

- control lane revision-fenced durante Invocation attiva;
- restart-based `steer/3` che restituisce un nuovo Enumerable;
- vecchio stream terminale `:superseded`;
- `Inference.Budget` e `BudgetSnapshot`;
- riserva e settlement idempotenti;
- hard deadline e stall/consumer timeout distinti;
- `Inference.Progress` heartbeat;
- liveness clock ephemerale;
- progress snapshot canonical throttled;
- `Inference.Events` pubblicato post-commit;
- `:consumer_never_attached` terminale;
- `resume_stream/3` e recovery matrix.

Prism:

- expose resume/reconcile capability quando realmente disponibile;
- pricing/usage quality metadata;
- native steering soltanto come capability riservata.

Gate:

- tutte le race steer/terminal/cancel/restart sono coperte;
- nessun evento del nuovo epoch appare nel vecchio Enumerable;
- nessun heartbeat estende il deadline assoluto;
- observer lane non pubblica fatti non committati.

### Fase 7 — Ledger v2

Ledger:

- catena receipt separata dalla catena checkpoint;
- sequence receipt distinta dalla canonical revision;
- memory backend e conformance;
- PostgreSQL schema/migration;
- append atomico, CAS, idempotency e ambiguous reconciliation;
- content-addressed payload objects;
- Bundle v2 con checkpoint chain + receipt chain;
- verifier di chain, object, state root e manifest refs;
- Bundle v1 e API checkpoint invariati.

Manifest iniziale:

```text
capture: nondeterministic_boundaries
receipt_mode: observational|required
state_digest_linkage: true
deterministic_replay: false
exactly_once_external_effects: false
```

Gate:

- delete, reorder, substitution o corruption di entry/blob falliscono la verifica;
- append ack perso viene riconciliato idempotentemente.

### Fase 8 — Determinism port e replay verifier

Core:

- port per clock, UUID e random decision-relevant;
- callback replayable pure, source-driven o receipt-backed;
- copertura incrementale di deadline, policy, delivery e random branches.

Verifier:

1. verifica Ledger e payload;
2. risolve Definition/manifest/closure pinned;
3. alimenta input e boundary outcome registrati;
4. ricalcola transizioni;
5. confronta ogni post-state digest;
6. segnala la prima divergenza.

Gate:

- `deterministic_replay` resta false finché fixture e fault suite non riproducono i digest.

## 10. Sequenza PR consigliata

Una sequenza lineare di diciotto PR accoppia quattro progetti indipendenti e mette il lavoro più costoso e meno urgente — receipt required e Ledger v2 — prima di qualunque valore osservabile. Le tracce sono separabili e vanno rilasciate separatamente.

### Traccia A — recovery (patch, nessuno schema nuovo)

1. Core: ADR, fake adapter e fault harness.
2. Core: durable admitted input, restored Run scheduling, classificazione `recoverable?`.
3. Core: check Doctor di sicurezza (§8.7 punto 1) e guard di validazione argomenti (§8.7 punto 2).

Chiude una classe di leak già confermata e due buchi di sicurezza senza toccare formati. Rilasciabile da sola.

### Traccia B — inference come Invocation (minor)

4. Core: Run v3 con reader v2, fixture congelata e doc di migrazione.
5. Core: `InferenceContinuation`, `Invocation.kind: :inference`, descriptor portabile.
6. Core: selezione congelata, fallback come attempt distinti, terminal receipt prima del post-processing.
7. Prism: capability bridge per adapter one-shot.

`receipt_mode: :disabled`. Nessuno streaming. Prova il lifecycle senza complessità di trasporto.

### Traccia C — streaming (minor, dipende solo da B)

8. Core: `StreamAdapter` behavior e conformance capability-based.
9. Prism: contratto `Transport` pull, `:httpc {self, :once}`, parser SSE bounded.
10. Core: Enumerable + `StreamSession` `:gen_statem`, Registry sessioni, cap di ammissione.
11. Core: sanitizer incrementale, `content_class`, ammissibilità fail-closed.
12. Core: attach terminal, monitor, handshake di commit e due terminali distinti.
13. Core: steering restart-based ed Enumerable sostitutivo.
14. Core: budget snapshot, settlement, heartbeat e observer lane.
15. Prism: adapter di produzione OpenRouter e Ollama.
16. Core: resume/reconcile e recovery matrix.

`receipt_mode` al massimo `:observational`. Non dipende da Ledger v2.

### Traccia D — evidenza (parallela, non blocca C)

17. Core: receipt envelope, state root e memory sink.
18. Core: Canonical schema v3 con reader v2 e sezioni bounded.
19. Core: outbox required e durability barrier.
20. Ledger: catena receipt in memoria e conformance, rename `AppendAck`.
21. Ledger: PostgreSQL e Bundle v2 sopra la catena esistente.
22. Core + Ledger: integrazione required e reconciliation.
23. Tutti: determinism port e replay verifier.

### Traccia E — sicurezza (pacchetti, fuori dal core)

24. Input plug di ammissione.
25. Wrapper di egress su executor e action provider.
26. Router plug di quarantena.
27. Core: propagazione della classe di fiducia e `Prompt.data/1`, insieme alla prima release che tocca il prompt layer.

Ogni PR mantiene funzionante il percorso one-shot preesistente.

## 11. Test matrix obbligatoria

### Enumerable e backpressure

- stream mai enumerato;
- doppia enumerazione;
- `Enum.take/2` interrompe presto;
- consumer lento;
- consumer bloccato;
- consumer exception;
- consumer `:kill`;
- un logical event su più transport chunk;
- più logical event in un chunk;
- parser residual oversize;
- push adapter overflow;
- nessun drop silenzioso.

### Fencing

- generation vecchia;
- Run revision vecchia;
- dispatch ID vecchio;
- invocation/attempt vecchio;
- control revision vecchia;
- stream epoch vecchio;
- sequence duplicate, gap e reorder;
- terminale duplicato;
- terminale dopo supersession.

### Steering

- steer prima del primo demand;
- steer mentre `next` è pendente;
- delta già risposto mentre arriva steer;
- terminale accettato prima dello steer;
- steer committato prima del terminale;
- cancellazione provider confermata;
- cancellazione provider ambigua;
- nuovo Enumerable mai attachato;
- nessun evento nuovo nel vecchio Enumerable.

### Budget

- provider usage incrementale autorevole;
- usage assente con stima;
- output token cap inviato al provider;
- budget superato mid-stream;
- deadline assoluto non rinnovato;
- stall timeout rinnovato da progress valido;
- heartbeat stale non rinnova nulla;
- fallback con budget residuo;
- steer con old usage ambiguo;
- settlement duplicato idempotente.

### Observer lane

- heartbeat valido aggiorna liveness anche se commit throttled;
- heartbeat stale ignorato;
- commit failure non falsifica liveness;
- nessun publish prima del commit;
- progress event porta canonical revision;
- nessun raw text nel progress;
- subscriber lento non influenza consumer autorevole;
- observer registry down non altera il Run.

### Recovery e crash injection

- crash dopo input admission;
- crash dopo selection commit;
- crash prima del provider open;
- crash dopo provider open ma prima di provider request ID durable;
- crash dopo delta;
- crash dopo terminal provider ma prima della receipt;
- crash dopo receipt ma prima del Run commit;
- crash dopo commit ma prima dell'ack al consumer;
- Instance DOWN con consumer attachato;
- Instance DOWN senza consumer;
- old session message contro nuova generation;
- resume provider;
- reconcile provider;
- provider non recuperabile -> interrupted/ambiguous.

### Compatibilità

- restore Run v2;
- adapter `complete/2` legacy;
- Prism senza streaming;
- transport custom senza i callback di stream;
- Ledger Bundle v1;
- receipt mode disabled;
- receipt mode observational;
- receipt mode required.

### Contenuto e sanitizzazione

- marker di controllo spezzato tra due delta;
- marker che occupa esattamente il confine del lookahead;
- lookahead saturo (`max_sanitizer_lookahead_bytes`) senza chiusura del marker;
- `sanitize_reply: false` produce `content_class: :unsanitized`;
- planner con `clean_reply/3` non incrementale: streaming rifiutato, non degradato;
- purpose con action planning: `{:error, {:streaming_unsupported, _}}`;
- purpose con structured output: stesso rifiuto;
- profilo senza capability `:stream`: stesso rifiuto.

### Sicurezza

- prompt asset che interpola `@input`, `@recent_chat` o `@memory` viene segnalato dal check Doctor;
- contenuto avvolto da `Prompt.data/1` non è promuovibile a trust istruzione;
- provider dinamico che punta a `:instructions` continua a fallire in compilazione;
- argomenti d'azione fuori schema: guard fail-closed, effetto non eseguito;
- argomenti d'azione entro schema ma fuori scope del subject: veto;
- egress verso dominio non in allowlist: bloccato con outcome tipizzato;
- risultato d'azione che contiene markup di controllo non diventa istruzione al turno successivo;
- cap di sessioni saturo: rifiuto, nessuna coda, nessun leak di slot;
- durata massima dello stream superata: terminale, state lock rilasciato, idle shutdown di nuovo eleggibile;
- nessun identificatore provider in chiaro in log, telemetria o eventi osservatori.

## 12. Invarianti di accettazione finali

- Nessun provider attempt parte prima che selection e intent siano durevoli in required mode.
- Al massimo un terminale viene accettato per attempt e control revision.
- Il vecchio Enumerable non segue mai implicitamente un nuovo epoch.
- Restart e steering non concatenano silenziosamente stream differenti.
- Un consumer mai attachato produce sempre un terminale e libera lo slot.
- L'Instance non riceve raw delta.
- Il consumer autorevole non usa pub/sub e non ha mailbox unbounded.
- Nessun buffer overflow scarta testo silenziosamente.
- `:inference_completed` è visibile soltanto dopo l'ack della receipt; `:result` soltanto dopo il commit canonico del Run.
- Heartbeat e progress commit sono separati; liveness non dipende dal Ledger.
- Il deadline totale non viene esteso dal progress.
- Il budget aggregato resta nell'Instance e ogni attempt usa uno snapshot immutabile.
- Outcome di cancel remoto ambiguo resta esplicitamente ambiguo.
- Required receipt failure blocca o riconcilia; non degrada silenziosamente.
- Bundle v1 e Run v2 restano leggibili.
- Deterministic replay non viene dichiarato prima della prova dei digest.
- Nessun contenuto streammato è deliverable prima di sanitizer e guard.
- Contenuto di provenienza non fidata non raggiunge mai il trust istruzione.
- Un'azione non viene eseguita con argomenti che il suo schema non ammette.
- Ogni capability mancante — profilo, transport, planner — produce un rifiuto tipizzato, mai un fallback silenzioso.
- Il numero di sessioni e la durata di uno stream sono limitati e osservabili.
- Nessun identificatore provider o segreto compare in receipt, log, telemetria o eventi osservatori.

## 13. Rollout

Ordine di attivazione consigliato:

0. check Doctor di sicurezza e guard di validazione argomenti attivi in staging (indipendenti dal resto);
1. feature flag interna con fake adapter;
2. one-shot Invocation per tutti gli adapter;
3. streaming locale in test;
4. OpenRouter/Ollama opt-in;
5. observer lane opt-in;
6. receipt observational;
7. Ledger required in staging con fault injection;
8. streaming production opt-in;
9. default streaming soltanto dopo metriche di buffer, timeout, ambiguity e recovery.

Metriche minime:

- sessioni per stato;
- attach timeout;
- consumer idle/stall timeout;
- buffer/parser high-water mark;
- delta e byte rate;
- stale fence rejection per tipo;
- cancel confirmed/ambiguous;
- budget estimate quality;
- heartbeat accepted/throttled/stale;
- progress commit rate;
- outbox depth e age;
- recovery resume/reconcile/interrupted;
- terminal commit latency;
- sessioni rifiutate per cap e per durata massima;
- delta trattenuti dal lookahead e marker di controllo intercettati;
- streaming rifiutato per capability mancante, per classe;
- veti dei guard di argomenti e blocchi di egress, per classe.

Tutte le metriche usano la disciplina già in uso nel runtime: identificatori digested (`id_digest/1`) e classi di ragione, mai valori grezzi.

## 14. Definition of done

La traccia Spectre di questa consegna è completa quando:

- recovery, Invocation di inferenza, streaming, receipt sink e hardening sono
  integrati nel core Spectre;
- i gate di ogni fase passano;
- la fault matrix è automatizzata;
- la documentazione pubblica distingue delta provvisori, terminale di inferenza, terminale di Run e restart;
- i behaviour esterni di stream e receipt sono verificabili e fail-closed;
- il core non dichiara garanzie Ledger v2 non provate da un sink esterno;
- non rimangono Run o Invocation non terminali senza una recovery action deterministica;
- i buchi A, B e C di §8.2 hanno un controllo attivo e un test che lo prova;
- nessuno schema è stato bumpato senza fixture congelata e documento di migrazione.

----
