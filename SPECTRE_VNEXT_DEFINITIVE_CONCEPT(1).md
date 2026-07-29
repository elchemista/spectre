# Spectre vNext — Concept architetturale definitivo

**Stato:** north star dell’ecosistema — freeze architetturale
**Versione concettuale:** 1.0.0
**Data:** 28 luglio 2026
**Scopo:** descrivere l’architettura futura desiderata e la migrazione dal codice attuale

> Questo documento definisce il modello concettuale di Spectre vNext. Non dichiara
> che tutte le API qui mostrate siano già implementate.

## 1. Visione

Spectre vNext è un linguaggio e runtime per costruire **agenti vivi, nativi della
BEAM e realmente fondati sull’Actor Model**.

Un Agent non è un wrapper attorno a un modello e non è una sequenza di tool.
È un Actor con identità, mailbox e stato privato che:

- riceve stimoli da persone, sistemi e altri Agent;
- mantiene più lavori concorrenti senza perdere l’ordinamento del proprio stato;
- decide quali lavori ammettere e quali mosse compiere;
- controlla policy, consenso, budget e autorità prima degli effetti;
- conserva verità operative, impegni e memoria senza confonderli;
- riprende lavori durevoli dopo pause, crash e aggiornamenti;
- comunica risultati e notifiche attraverso canali governati;
- può ricostruire e spiegare ciò che è accaduto senza conservare chain-of-thought.

Le librerie dell’ecosistema non sono cervelli concorrenti. Forniscono facoltà e
servizi all’Agent.

> Le librerie forniscono facoltà e servizi. Lo Stack le installa. Flow, Work,
> Skill e policy stabiliscono dove possono essere usate. L’Agent resta l’unico
> proprietario delle decisioni e dello stato.

## 2. Principi non negoziabili

1. Esiste un solo proprietario dello stato di ogni Agent Instance.
2. Un’Instance è l’unità di stato, ordinamento e failure, non una definizione
   globale condivisa da tutti gli utenti.
3. Il default è una Instance per coppia `AgentRef + subject`, condivisa tra i
   canali autorizzati dello stesso subject.
4. Una Instance usa un solo Actor OTP e può mantenere molte Run concorrenti.
5. La macchina a stati è la Run; l’Actor ne è proprietario e scheduler.
6. Ogni Run può avere al massimo una Invocation o un Effect attivo.
7. Nessuna libreria modifica direttamente lo stato dell’Agent.
8. Nessuna Operation installata è automaticamente visibile o autorizzata.
9. La policy è l’unica autorità sui side effect.
10. Le scritture operative diventano vere soltanto al commit.
11. Secret, PID e connessioni non entrano in prompt, planner, Journal o memoria.
12. Beam non sostituisce `Spectre.turn/3`; è soltanto il bordo multicanale.
13. Pulse trasporta comunicazioni tra Agent, ma non possiede Task, memoria o
    autorizzazioni applicative.
14. La chiamata pubblica termina al primo confine osservabile, non alla fine di
    un lavoro che può durare ore o giorni.
15. Ogni decisione importante deve poter essere provata, riprodotta e spiegata
    a partire da IR, input, policy e Receipt.
16. Due identità di canale non diventano mai lo stesso Subject per euristica:
    il collegamento richiede prova di controllo e consenso esplicito.

## 3. Il modello completo

| Concetto | Responsabilità |
|---|---|
| `Stack` | Installa e risolve package, servizi, Operation, Action e risorse |
| `Agent Definition` | Modulo compilato con identità, Flow, Work, Skill, Vigil, Ledger, Relation e policy |
| `Agent Instance` | Actor OTP per un’unità di stato, ordinamento e failure |
| `Subject` | Persona o entità per cui l’Instance mantiene continuità |
| `SubjectLink` | Collegamento autorizzato fra un Subject e un’identità esterna verificata |
| `Stimulus` | Messaggio, evento, wake, risultato, timeout o Envelope Pulse |
| `Flow` | Reazione strutturata a uno Stimulus |
| `Work` | Spazio decisionale per perseguire un obiettivo |
| `Task` | Identità durevole di un Work concreto |
| `Run` | Continuazione attiva e riprendibile di Flow o Task |
| `Move` | Prossima transizione consentita in una Run |
| `Operation` | Capacità read-only o limitata offerta da una facoltà |
| `Action` | Capacità applicativa che può produrre un Effect |
| `Invocation` | Richiesta concreta di esecuzione |
| `Effect` | Side effect staged, autorizzabile e committabile |
| `Receipt` | Evidenza tipizzata di ciò che è realmente avvenuto |
| `Commitment` | Promessa durevole verso una persona o un Agent |
| `Vigil` | Definizione di un’intenzione proattiva risvegliabile |
| `Enrollment` | Attivazione autorizzata di una Vigil per subject e origin |
| `Ledger` | Verità operativa durevole e interrogabile |
| `Outbox` | Governo durevole di notifiche e consegne |
| `Steward` | Control plane conversazionale dell’Agent |
| `Presentation` | Collegamento tra elementi presentati e risposte successive |
| `Journal` | Evidenza di eventi, decisioni, effetti, costi e risultati |
| `Rehearsal` | Esecuzione della stessa IR senza side effect reali |
| `Skill` | Pacchetto riusabile di Flow e Work |
| `Relation` | Contratto tipizzato fra Agent per una delega |
| `DelegationGrant` | Autorità, budget e limiti concessi a un altro Agent |
| `Group` | Pattern di collaborazione fra Agent con identità e autorità indipendenti |

Questi concetti appartengono a quattro piani distinti:

| Piano | Concetti |
|---|---|
| Definizione | Stack, Agent Definition, Flow, Work, Skill, Vigil, Ledger, Relation, Group |
| Esecuzione | Agent Instance, Stimulus, Run, Move, Invocation, Effect, Receipt |
| Continuità | SubjectLink, Task, Commitment, Enrollment, Ledger, Outbox, Journal |
| Controllo | Steward, Presentation, claim, consent, policy, Rehearsal |

## 4. Stack: installazione senza globalità

Lo Stack rappresenta l’ambiente risolto dell’Agent:

```elixir
defmodule Acme.AI do
  use Spectre.Stack

  install Spectre.Prism do
    provider :openrouter, Acme.OpenRouter
    model :fast, id: "small-model"
    model :reasoning, id: "reasoning-model"
  end

  install Spectre.Kinetic do
    classifier Acme.IntentClassifier
  end

  install Spectre.Mnemonic do
    store Acme.MemoryStore
    isolate_by [:agent, :subject, :conversation, :flow, :task]
  end

  install Spectre.Directive do
    store Acme.ContinuityStore
    clock Acme.Clock
    resident_runs 16
  end

  install Spectre.Lens do
    backend Spectre.Lens.Playwright
    policy Acme.WebPolicy
  end

  install Spectre.Beam do
    channel :telegram, Acme.Telegram
    channel :whatsapp, Acme.WhatsApp
  end

  install Spectre.Pulse do
    transport :local, Spectre.Pulse.Local
    directory Acme.AgentDirectory
  end

  install Acme.JobActions
end
```

L’Agent usa:

```elixir
use Spectre.Agent, stack: Acme.AI
```

Non viene introdotto un generico `use Spectre`.

### 4.1 Contratto installabile

Il contratto comune è `Spectre.Stack.Installable`. Ogni package pubblica:

- ID, versione e compatibilità;
- contratti forniti e dipendenze;
- configurazione compilabile;
- Operation e Action registrate;
- eventuale DSL locale;
- runtime e risorse richieste;
- contract test versionati.

Non tutte le librerie diventano “Faculty”:

- Lens offre Operation ed è una facoltà;
- Prism è un servizio cognitivo;
- Kinetic è un interprete di decisioni vincolate;
- Mnemonic è memoria;
- Directive è continuità;
- Beam è il bordo esterno;
- Pulse è il protocollo tra Agent.

### 4.2 Le tre fasi

**Compilazione.** Lo Stack valida dipendenze, versioni, conflitti, Operation
duplicate, ownership dei servizi e serializzabilità. Produce installazioni
immutabili e ispezionabili.

**Avvio.** Lo Stack avvia o collega provider, store, browser, client, directory,
clock e pool. La definizione contiene riferimenti logici, non PID o secret.

**Binding.** Flow, Work e Skill vengono risolti contro uno Stack concreto. Il
risultato contiene solo capacità, policy e riferimenti disponibili per
quell’Agent. Più Stack possono convivere nella stessa VM.

### 4.3 DSL locale senza conflitti con Elixir

La DSL non deve importare nel modulo dell’Agent una macro per ogni verbo. Questo
entrerebbe prima o poi in conflitto con funzioni locali, import, `Kernel`,
`GenServer`, `Task` o altre librerie.

Soltanto le dichiarazioni strutturali sono macro pubbliche:

```text
flow, work, vigil, ledger, relation
```

Gli argomenti e gli eventuali blocchi vengono ricevuti come AST non espanso e
compilati dal parser Spectre competente. Parole come:

```text
on, gather, perform, recall, remember, utilize, action,
reply, notify, confirm, enroll, revoke, track, advance, sift,
resolve, review, explain, label, present, pulse
```

sono quindi **forme locali della DSL**, non macro importate nel namespace
dell’Agent e non funzioni pubbliche generate nel modulo.

Per esempio, `advance` dentro una Vigil viene riconosciuto dal compilatore
Ledger; non collide con `Runtime.advance/2`. Allo stesso modo `reply` non
nasconde `GenServer.reply/2` e `action` non impedisce di definire una normale
funzione Elixir con quel nome fuori dalla DSL.

`delegate` non fa parte del vocabolario pubblico: oltre a essere troppo vicino
a `defdelegate`, duplicava il significato di Pulse. Una delega viene espressa
con `pulse ..., relation: ...`. Anche `await` non è un verbo pubblico: l’attesa
è un risultato interno della Run o una condizione durevole gestita da
Directive.

Il compilatore:

1. riconosce soltanto le forme ammesse nel blocco corrente;
2. rifiuta forme valide nel contesto sbagliato, come `notify` in un Flow
   conversazionale quando è richiesta una `reply`;
3. lascia espandere normalmente il codice Elixir soltanto nei boundary
   esplicitamente previsti;
4. produce sempre la stessa IR core, indipendentemente dalla forma locale.

Una libreria estende la sintassi soltanto nel proprio namespace:

```elixir
utilize :lens do
  search ...
  visit ...
  extract ...
end
```

La Skill conserva l’uso non risolto; lo Stack dell’Agent sceglie
l’implementazione. Nessun package importa macro globali o registra
implicitamente un `Turn.Handler`.

## 5. Agent Instance e runtime concorrente

### 5.1 Granularità

Una Agent Definition può generare molte Instance:

```text
Astra Definition
├── Instance per Anna
├── Instance per Marco
└── Instance per Azienda ACME
```

L’Instance di Anna può essere raggiunta da Telegram e WhatsApp, ma conserva un
solo stato ordinato. Non esiste un unico PID globale per tutti gli utenti.

Lo State dell’Actor contiene indicativamente:

```elixir
%{
  identity: ...,
  subject: ...,
  external_identities: %{...},
  conversations: %{...},
  runs: %{run_id => run},
  tasks: %{task_id => task},
  ready: :queue.new(),
  invocations: %{invocation_id => run_id},
  commitments: %{...},
  enrollments: %{...},
  presentations: %{...},
  ledger_cursor: ...,
  journal_cursor: ...
}
```

#### Linking sicuro fra canali

Beam autentica un endpoint Telegram, WhatsApp o di altro canale e produce una
`ExternalIdentity`. Il **Subject Registry del core** decide a quale Subject essa
appartiene prima di aprire o raggiungere l’Instance. Beam non può fondere
identità e il core non usa nome, numero simile, rubrica, testo dei messaggi o
decisione del modello come prova di identità.

Il collegamento fra due canali segue un protocollo esplicito:

1. una sessione già autenticata apre un `LinkIntent`, legato ad `AgentRef`,
   Subject, identità sorgente e canale destinazione;
2. il core genera una challenge monouso, con scadenza e tentativi limitati;
3. Beam consegna la challenge all’identità destinazione;
4. la persona conferma dal canale destinazione; per policy ad alto rischio può
   essere richiesta una seconda conferma sul canale sorgente;
5. il core committa il `SubjectLink` e registra Receipt e Journal;
6. soltanto da quel commit entrambi i canali risolvono la stessa Instance.

Collegare un’identità nuova non trasferisce automaticamente Enrollment, origin
di notifica o autorizzazioni. Unire due Subject che possiedono già stato è
un’operazione di migrazione distinta e privilegiata: richiede conferma
esplicita, piano di conflitto per Ledger, Task e Commitment e non avviene mai
durante il normale routing. Un `SubjectLink` può essere revocato senza
cancellare lo stato durevole del Subject.

### 5.2 Un GenServer, molte Run

L’implementazione iniziale usa un `GenServer`. Ogni Run è una macchina a stati
serializzabile; il processo schedula Run diverse:

```text
Agent Instance
├── Run A: attende Prism
├── Run B: pronta
├── Run C: attende Lens
├── Run D: attende conferma
├── Run E: passivata fino a domani
└── Run F: gestisce il nuovo messaggio
```

Ogni callback avanza una Run per una sola Move, o per un numero strettamente
limitato di mosse deterministiche, poi restituisce il controllo alla mailbox:

```elixir
send(self(), {:spectre, :advance, run_id})
```

Non si usano catene di eventi interni che scavalcano la mailbox. Se in futuro
si adotta `:gen_statem`, gli advance continuano a passare dalla coda normale,
mai da `{:next_event, :internal, ...}`.

### 5.3 Invocation non bloccanti

Quando una Run invoca Lens, Prism, un provider o un’Action, l’Actor registra:

```elixir
invocations[invocation_id] = run_id
```

Il risultato rientra nella mailbox:

```elixir
{:spectre, :invocation_result, invocation_id, receipt}
```

Worker e servizi tecnici non modificano lo State. Producono soltanto messaggi e
Receipt correlati.

### 5.4 Runtime resumable

Il runtime espone internamente:

```elixir
Runtime.start(...)
Runtime.advance(...)
Runtime.resume(...)
```

Ogni passo restituisce una forma chiusa:

```elixir
{:continue, run}
{:await, invocation, run}
{:boundary, observable, run}
{:complete, result, run}
{:error, reason, run}
```

`Turn` è la proiezione pubblica; `Run` è la continuazione interna.

### 5.5 Confine pubblico

`Spectre.turn/3` resta il contratto pubblico stabile, ma ritorna al primo
confine osservabile:

```elixir
{:reply, output, ref}
{:awaiting, commitment_or_task_ref}
{:needs, request}
```

Una Task durevole può continuare dopo il ritorno. Beam non lascia una
`GenServer.call` sospesa per ore.

### 5.6 Passivazione e recovery

Directive checkpointa le Run inattive, le rimuove dalla RAM quando viene
superato il limite configurato e le ricarica all’arrivo di uno Stimulus, timer o
risultato correlato.

Task, Effect staged, lease e idempotency key sopravvivono a crash e rolling
upgrade. Il recovery non duplica un Effect già committato.

## 6. Flow, Work, Task e Run

### 6.1 Flow

Il Flow gestisce uno Stimulus e coordina passaggi principalmente deterministici:

```elixir
flow :job_search,
  beam: [:telegram, :whatsapp] do

  on "LOOK_FOR_JOB",
    when: "La persona vuole cercare offerte di lavoro." do

    gather :request do
      need :role
      need :location
      optional :remote
      reply :more_info
    end

    perform :find_jobs,
      with: :request,
      as: :jobs

    track :seen_offers, from: :jobs
    present :jobs, ledger: :seen_offers
    reply :job_results, from: :jobs
  end
end
```

`beam:` limita quali canali possono aprire il Flow; non installa né configura i
canali. Una ricerca read-only entro il budget dichiarato non richiede un
`confirm` rituale: è la policy a introdurre un confine di consenso quando
rischio, costo, prima esecuzione o contesto lo richiedono.

### 6.2 Work

Il Work descrive un obiettivo, non una sequenza rigida:

```elixir
work :find_jobs do
  label "Ricerca offerte {{request.role}} a {{request.location}}"

  goal """
  Trova offerte attuali e verificabili compatibili con la richiesta.
  Escludi duplicati, offerte scadute e risultati senza fonte valida.
  """

  given :request, Acme.JobQuery
  return :jobs, {:list, Acme.JobOffer}

  may do
    recall :job_preferences
    review :previous_attempts

    utilize :lens,
      only: [:search, :visit, :extract]
  end

  done when: Acme.JobSearch.sufficient?/1

  limits steps: 20,
         time: {:minutes, 5},
         cost: {:eur, 0.30}
end
```

Dopo ogni Receipt l’Agent aggiorna il Frame, valuta progresso e condizioni di
successo, quindi sceglie una nuova Move, chiede dati, attende o termina.

### 6.3 Task e Run

`perform :find_jobs` crea una Task. La Task contiene identità durevole:

- `task_id`, Work, subject e revisione;
- label umana renderizzata e versionata;
- stato, budget e scadenze;
- Commitment collegati;
- risultati committati.

La Run contiene la continuazione caricata:

- cursor e Frame;
- ultima Move e Invocation in attesa;
- tentativi e budget residuo;
- Source, causation e correlation;
- revisione della Task osservata.

Un risultato prodotto sulla revisione 3 non modifica automaticamente la
revisione 4. L’Agent decide se integrarlo, riutilizzarlo o scartarlo.

## 7. Ledger: verità operativa

Mnemonic ricorda, Journal prova, Ledger rappresenta **ciò che è operativamente
vero adesso**.

Esempi:

```text
offerta job_42: discovered → reviewed → proposed → applied → closed
candidatura app_7: drafted → confirmed → submitted → rejected
prenotazione booking_9: held → confirmed → cancelled
```

Il modulo Agent dichiara ogni Ledger prima che Flow, Work o Vigil possano
riferirlo:

```elixir
ledger :seen_offers,
  of: Acme.JobOffer,
  key: [:source, :external_id]

ledger :applications,
  of: Acme.JobApplication,
  key: [:provider, :external_id],
  states: [:submitted, :accepted, :rejected, :withdrawn],
  initial: :submitted,
  transitions: [
    submitted: [:accepted, :rejected, :withdrawn]
  ]
```

`of:` deve indicare uno schema serializzabile. `key:` contiene campi esistenti
e stabilisce l’identità durevole, mai un indice di presentazione o testo
generato dal modello. Quando `states:` è presente, il compilatore valida stato
iniziale e transition table; una transizione non dichiarata è irraggiungibile.
Qualunque riferimento a un Ledger non dichiarato è un errore di compilazione.

Il core definisce semantica, schema, chiavi e transition table. Directive
possiede la persistenza durevole. Ogni modifica passa dal lifecycle:

```text
Move → Invocation → Policy → Effect staged → Commit → Ledger transition → Receipt
```

I verbi sono:

- `track` — crea o aggiorna un’entità mediante chiave stabile;
- `advance` — applica una transizione valida;
- `sift` — confronta risultati contro entità già note;
- `resolve` — traduce riferimenti umani soltanto verso chiavi esistenti.

```elixir
sift :found,
  against: :seen_offers,
  as: :novel,
  if_empty: :quiet

track :seen_offers,
  from: :novel

resolve :offer,
  from: :latest_presentation,
  using: :message
```

`resolve` ha una sola firma:

```text
resolve <nome>, from: <ledger | presentation>, using: <sorgente dell’enunciato>
```

`from:` identifica lo spazio chiuso nel quale cercare: un Ledger dichiarato o
una Presentation valida. `using:` identifica il dato che contiene
l’enunciato, per esempio `:message` o un campo già raccolto. Il compilatore
risolve `from:` in un `LedgerRef` o `PresentationRef` tipizzato; non scambia mai
la sorgente dell’enunciato con lo spazio delle chiavi.

Il modello non può inventare una chiave Ledger. `resolve` restituisce una scelta
chiusa oppure un confine `:needs` con richiesta di disambiguazione.

## 8. Vigil, Enrollment e consenso

Una Vigil è una definizione. Un Enrollment è la sua attivazione autorizzata per
uno specifico subject:

```elixir
vigil :job_watch do
  label "Avvisi per nuove offerte {{request.role}} a {{request.location}}"
  subject :request, Acme.JobQuery

  wake every: "0 9 * * 1-5"
  wake on_change: {:lens, :job_sources}
  wake on_event: Acme.Events.ProfileChanged
  until {:days, 60}

  perform :find_jobs, with: :request, as: :found
  sift :found, against: :seen_offers, as: :novel, if_empty: :quiet
  track :seen_offers, from: :novel
  notify :fresh_offers, from: :novel
end
```

L’attivazione avviene esplicitamente:

```elixir
confirm :watch_consent,
  request: :watch_terms,
  accept: ["attiva", "sì"],
  attempts: 2

enroll :job_watch,
  subject: :request,
  origin: :current
```

`confirm` è zucchero sintattico sul lifecycle già esistente
`request/accept/attempts`; non crea un secondo sistema di consenso.

Il `confirm` esplicito è appropriato per Enrollment, Action rischiose,
condivisione di dati, spese materiali o altri confini di autorità. Per una
Operation read-only il core consulta invece la policy: rischio, costo
aggregato, prima esecuzione, privacy e preferenze del Subject determinano se
aprire un confine `:needs`. Il consenso non viene chiesto automaticamente prima
di ogni `perform`.

L’Enrollment conserva:

- subject e parametri;
- label umana renderizzata dalla Vigil;
- origin autorizzato;
- consenso e Receipt;
- policy, quiet hours e limiti;
- stato, scadenza e prossimi wake.

`revoke` termina l’Enrollment. `STOP` è un comando protetto e deterministico,
riconosciuto prima del routing cognitivo. Produce revoca, Journal e Receipt.

Quando una Vigil si sveglia, non esegue autonomamente il Work: invia uno
Stimulus alla stessa Agent Instance, che può eseguire, unire, rinviare o
rifiutare il lavoro.

## 9. Outbox e governo delle notifiche

`reply` risponde a uno Stimulus conversazionale aperto. `notify` produce una
comunicazione proattiva. Una Vigil può usare `notify`, mai `reply`.

Ogni `notify` passa attraverso una Outbox durevole che applica:

- idempotenza;
- destinazione autorizzata;
- rate limit;
- quiet hours;
- digest e aggregazione;
- priorità e scadenza;
- retry e Delivery Receipt.

Per default una Vigil può notificare soltanto l’origin autorizzato
dall’Enrollment. Cambiare canale richiede migrazione esplicita o nuovo consenso.
Beam effettua la consegna, ma non decide se essa sia lecita.

## 10. Steward e control plane conversazionale

Lo Steward è una responsabilità del core, non un secondo Agent. Gestisce il
dialogo relativo a:

- consenso e conferme;
- stato, modifica e arresto di Task e Vigil;
- Commitment aperti;
- riferimenti a elementi presentati;
- spiegazioni e costi;
- disambiguazione.

`present` registra una Presentation:

```elixir
present :jobs, ledger: :seen_offers
reply :job_results, from: :jobs
```

Così “candidami alla seconda” può essere risolto contro la lista realmente
presentata, quindi contro una chiave Ledger esistente.

`present` non descrive l’Agent a se stesso e non assegna un nome umano a Work o
Vigil. Quella responsabilità appartiene a `label`:

```elixir
label "Ricerca offerte {{request.role}} a {{request.location}}"
```

Il compilatore valida i riferimenti del template contro `given` o `subject`.
Quando nasce una Task, un Commitment o un Enrollment, il valore renderizzato
viene conservato con la sua revisione. Lo Steward usa questa label nelle liste,
nelle conferme e nelle disambiguazioni; non mostra l’atomo interno del Work.

La **semantica** dello Steward rimane kernel: claim, target, policy, STOP e
transizioni non sono sostituibili. La **voce** è invece configurabile tramite un
presenter o una Skill di controllo. Riceve un prompt tipizzato già deciso dal
core e può cambiarne tono, lingua e formulazione, ma non destinatario, opzioni,
autorità o conseguenze. Se il presenter fallisce, il core dispone di una resa
deterministica di fallback.

### 10.1 Ordine di claim del prossimo messaggio

Prima del router cognitivo, il core prova in ordine:

1. comando protetto, come `STOP`;
2. `reply_to` esplicito del canale;
3. conferma aperta più recente e compatibile;
4. riferimento risolvibile a Task, Commitment, Enrollment o Presentation
   aperti;
5. router normale dei Flow.

Un “sì” non viene quindi assegnato arbitrariamente a uno dei lavori attivi.
Quando più claim sono compatibili, lo Steward chiede disambiguazione.

### 10.2 Amend, pause e resume

`amend`, `pause` e `resume` sono comandi tipizzati del control plane, non verbi
pubblici nei blocchi Flow o Work. Possono arrivare da linguaggio naturale,
controlli UI o API amministrative, ma seguono lo stesso percorso:

```elixir
%Spectre.Steward.Command{
  kind: :amend | :pause | :resume,
  target: {:task | :enrollment, id},
  expected_revision: revision,
  payload: ...
}
```

Lo Steward reclama il messaggio, risolve il target e costruisce il comando. Il
lifecycle del core valida schema, autorità, policy e revisione; Directive
committa la transizione e il relativo checkpoint.

Per «aggiungi anche Milano», `:amend` produce una patch tipizzata sui dati
`given` del Work, incrementa atomicamente la revisione della Task e conserva la
revisione precedente. Ogni risultato in-flight resta marcato con la vecchia
revisione e non può modificare quella nuova senza una decisione esplicita
dell’Agent.

`:pause` impedisce nuove Invocation, checkpointa la continuazione e sospende
wake o notifiche dell’Enrollment interessato. Gli effetti già committati non
vengono finti come annullati; le Invocation cancellabili ricevono cancellation,
le altre restano fenced. `:resume` ricarica l’ultima revisione, riesegue
admission, policy e budget e crea una nuova continuazione senza riattaccare
risultati stantii. Se il target non è univoco, lo Steward chiede quale lavoro
modificare prima di applicare qualsiasi transizione.

## 11. Commitment

Un Commitment è una promessa durevole:

```text
“Ti avviso quando trovo una nuova offerta.”
“Preparo il report entro domani.”
“Tao restituirà una ricerca verificata.”
```

Contiene:

- destinatario e origin;
- label umana congelata alla revisione corrente;
- risultato promesso;
- Task e Relation collegate;
- scadenza, stato e revisione;
- autorità e condizioni di chiusura;
- budget assegnato e costi attribuiti.

I costi di Invocation e Task si aggregano al Commitment. `review :work_cost` ed
`explain :commitment` possono quindi rispondere a “quanto mi è costato questo
impegno?”.

## 12. Decisione cognitiva: Frame, Kinetic e Prism

Il modello non riceve l’intero stato. Il core costruisce un Frame circoscritto:

```elixir
%Spectre.Work.Frame{
  agent: ...,
  work: :find_jobs,
  objective: ...,
  subject: ...,
  facts: ...,
  recalled_memory: ...,
  operational_state: ...,
  recent_attempts: ...,
  last_receipt: ...,
  available_moves: ...,
  success_conditions: ...,
  authority: ...,
  remaining_budget: ...,
  source: ...,
  revision: 4
}
```

Non contiene Stack completo, credenziali, intero Journal, memoria di altri Agent
o chain-of-thought.

Le richieste cognitive sono separate:

- `:route_stimulus`;
- `:admit_work`;
- `:choose_work_move`;
- `:judge_work_result`;
- `:resolve_reference`;
- `:present_result`.

Kinetic:

- prepara un’Action Language chiusa;
- presenta solo Move consentite;
- interpreta una scelta strutturata riferita a un `move_id`;
- non esegue, autorizza o modifica lo State.

Prism:

- sceglie provider, modello e livello di intelligenza per purpose;
- considera privacy, budget, latenza e feature;
- gestisce fallback ed escalation;
- restituisce un Receipt di inferenza.

### 12.1 Provenienza degli argomenti

| Tipo | Esempio | Chi lo produce |
|---|---|---|
| Deterministico | location da `request` | Core |
| Riferimento chiuso | URL già osservato | Kinetic sceglie, core risolve |
| Semantico | nuova query | Modello entro schema |
| Runtime | browser, task ID, secret | Stack/Core |
| Policy | budget, trust, limiti | Core |

Il modello produce solo argomenti semantici o selezioni chiuse.

## 13. Operation, Action, Effect e trust firewall

Ogni Operation registra:

```text
id, versione, purpose, use_when, do_not_use_when,
input, output, rischio, trust, idempotenza, costo
```

Un Flow può decidere deterministicamente:

```elixir
utilize :lens do
  visit from: :url, as: :page
end
```

Un Work può concedere uno spazio di scelta:

```elixir
may do
  utilize :lens, only: [:search, :visit, :extract]
end
```

Se una capacità come `lens.research` decide query, fonti, iterazioni e
terminazione, non è una Operation: deve diventare un Work o una Skill.

Le Observation esterne sono untrusted per default e conservano:

- provenienza e timestamp;
- trust e integrità;
- riferimento alla sorgente;
- separazione tra dati osservati e istruzioni;
- contesto isolato.

Testo web, documenti e messaggi Pulse non diventano istruzioni eseguibili. Il
gateway applica controlli di ingresso; il core applica nuovamente il firewall
quando costruisce il Frame.

## 14. Ruoli delle librerie

| Componente | Ruolo |
|---|---|
| `spectre` | Stack, Agent, Subject Registry, Actor, Flow, Work, Task/Run model, policy, lifecycle, Ledger semantics, Group, Steward, Journal e IR |
| `spectre_kinetic` | Routing e scelta vincolata di una Move |
| `spectre_prism` | Selezione della cognizione per purpose |
| `spectre_lens` | Percezione del web/computer tramite Operation limitate |
| `spectre_mnemonic` | Recupero e conservazione di memoria committata |
| `spectre_directive` | Persistenza, Ledger store, checkpoint, timer, lease, Outbox, passivazione e recovery |
| `spectre_beam` | Normalizzazione degli input esterni e consegna degli output |
| `spectre_pulse` | Envelope, identità, reachability e trasporto tra Agent |
| `Spectre.Skill` | Flow e Work riusabili |
| Action package | Effetti applicativi tipizzati e protetti |

### 14.1 Mnemonic, Journal e Ledger

- **Run State:** verità corrente della continuazione.
- **Ledger:** verità operativa durevole.
- **Journal:** ciò che è accaduto e con quali evidenze.
- **Mnemonic:** conoscenza recuperabile in futuro.

`remember` avviene solo dopo un commit valido. La memoria è privata per default
e isolata almeno per Agent e subject.

### 14.2 Directive

Directive non ha una DSL `mission` né un secondo executor. Persiste la IR del
core e fornisce timer, wait, retry, cancellation, lease, Ledger, Outbox,
SubjectLink, checkpoint, passivazione e recovery. Alla scadenza produce un
evento per la mailbox dell’Agent.

### 14.3 Beam

Beam:

- autentica Source, endpoint e mittente come `ExternalIdentity`;
- consulta il Subject Registry del core senza creare fusioni implicite;
- normalizza contenuto e allegati in Stimulus;
- conserva originali e provenance nelle trasformazioni;
- indirizza verso l’AgentRef corretto;
- consegna reply e notifiche autorizzate;
- restituisce Delivery Receipt.

Non interpreta il comportamento, non possiede conversazioni e non sostituisce
`Spectre.turn/3`. MCP rimane un adapter opzionale al bordo.

### 14.4 Pulse e delega tipizzata

Beam collega persone e applicazioni all’Agent. Pulse collega Agent distinti.

Una delega richiede una Relation:

```elixir
relation :job_research,
  with: Acme.Researcher,
  skill: Acme.Skills.JobResearch,
  input: Acme.JobQuery,
  output: {:list, Acme.JobOffer},
  trust: :verified
```

```elixir
pulse :researcher,
  relation: :job_research,
  with: :request,
  budget: [time: {:minutes, 3}, cost: {:eur, 0.15}],
  until: {:minutes, 5}
```

`pulse/2` è la forma unica per inviare un Envelope a un altro Agent. La
presenza di `relation:` indica una delega e obbliga il core a costruire e
autorizzare un `DelegationGrant`; senza `relation:` Pulse resta una normale
comunicazione tipizzata. Non esiste una seconda macro `delegate`.

Il core produce un `DelegationGrant` con:

- Relation e Skill;
- input/output schema;
- autorità concessa;
- budget e scadenza;
- trust richiesto;
- correlation, cancellation e idempotenza.

Pulse autentica e trasporta Envelope e Grant. La policy Spectre autorizza
Operation e Action. La Task e il Commitment restano dell’Agent delegante; il
delegato possiede la propria Task locale.

Spostare un Agent su un altro nodo o cambiare transport non modifica la
semantica di Agent, Skill, Relation o Group.

Il **Group** resta il pattern di collaborazione definito nella parte I: raccoglie
AgentRef, Relation e regole comuni quando servono identità, autorità,
specializzazioni o domini di failure indipendenti. Non è un Actor collettivo,
non possiede lo State dei membri e non è necessario per eseguire più Task
concorrenti. Ogni Agent del Group conserva la propria Instance, mailbox, Task,
Commitment e policy; Pulse trasporta soltanto le interazioni tipizzate fra loro.

## 15. Journal, review ed explain

Il Journal registra:

- Stimulus, causation e correlation;
- Run, Task, Commitment ed Enrollment;
- Frame hash e Move disponibili;
- scelta strutturata e modello scelto;
- Invocation, policy, Effect e Receipt;
- transizioni Ledger;
- budget e costi;
- notifiche e Delivery Receipt;
- errori, retry, checkpoint e recovery.

Non registra chain-of-thought.

`review` produce viste operative per l’Agent:

```elixir
review :previous_attempts
review :recent_failures
review :open_commitments
review :stalled_tasks
review :work_cost
```

`explain` produce una ricostruzione rivolta alla persona o all’operatore:

```text
stimolo → regola/Flow → dati considerati → policy → azione → Receipt
```

Mostra motivi verificabili, fonti, limiti e costi, non ragionamento privato.

## 16. Prova: Rehearsal, replay e determinismo

La stessa IR deve supportare tre modalità:

### Rehearsal

Esegue Flow e Work con provider, clock, Operation e Action controllati. Gli
Effect vengono staged ma non applicati. Permette di verificare:

- routing e claim;
- consenso e policy;
- transition table;
- budget;
- output e notifiche;
- comportamento su timeout, retry e crash.

### Replay

```bash
mix spectre.replay JOURNAL_REF
```

Ricostruisce una Run dagli eventi del Journal. Può:

- verificare che la stessa IR produca le stesse transizioni deterministiche;
- sostituire solo decisioni cognitive esplicitamente selezionate;
- confrontare Receipt attesi e ottenuti;
- fermarsi prima di qualunque Effect.

### Explain

È una proiezione di Journal, Ledger e Receipt, non una richiesta al modello di
inventare una giustificazione.

Versione di IR, package, policy e schema devono essere conservate per rendere
replay e migrazioni verificabili.

## 17. Esempio completo

```elixir
defmodule Acme.JobAgent do
  use Spectre.Agent, stack: Acme.AI

  ledger :seen_offers,
    of: Acme.JobOffer,
    key: [:source, :external_id]

  ledger :applications,
    of: Acme.JobApplication,
    key: [:provider, :external_id],
    states: [:submitted, :accepted, :rejected, :withdrawn],
    initial: :submitted,
    transitions: [
      submitted: [:accepted, :rejected, :withdrawn]
    ]

  flow :jobs, beam: [:telegram, :whatsapp] do
    on "JOB_SEARCH", when: Acme.Intent.job_search? do
      gather :request do
        need :role
        need :location
        reply :missing_job_details
      end

      perform :find_jobs, with: :request, as: :jobs
      track :seen_offers, from: :jobs
      present :jobs, ledger: :seen_offers
      reply :job_results, from: :jobs

      confirm :watch_consent,
        request: :offer_watch,
        accept: ["attiva"],
        attempts: 1

      enroll :job_watch,
        subject: :request,
        origin: :current
    end

    on "APPLY_TO_PRESENTED_JOB" do
      resolve :offer,
        from: :latest_presentation,
        using: :message

      confirm :application_consent,
        request: :application_summary,
        accept: ["invia"],
        attempts: 2

      action :submit_application,
        with: :offer,
        as: :application

      track :applications, from: :application, state: :submitted
      reply :application_receipt, from: :application
    end
  end

  work :find_jobs do
    label "Ricerca offerte {{request.role}} a {{request.location}}"
    goal "Trova offerte attuali, compatibili, non duplicate e verificabili."
    given :request, Acme.JobQuery
    return :jobs, {:list, Acme.JobOffer}

    may do
      recall :job_preferences
      review :previous_attempts
      utilize :lens, only: [:search, :visit, :extract]
    end

    done when: Acme.JobSearch.sufficient?/1
    limits steps: 20, time: {:minutes, 5}, cost: {:eur, 0.30}
  end

  vigil :job_watch do
    label "Avvisi per nuove offerte {{request.role}} a {{request.location}}"
    subject :request, Acme.JobQuery
    wake every: "0 9 * * 1-5"
    wake on_change: {:lens, :job_sources}
    until {:days, 60}

    perform :find_jobs, with: :request, as: :found
    sift :found, against: :seen_offers, as: :novel, if_empty: :quiet
    track :seen_offers, from: :novel
    notify :fresh_offers, from: :novel
  end
end
```

## 18. Migrazione dal codice Spectre attuale

La migrazione deve riusare lifecycle, Effect, Action Provider, policy,
`Turn.Handler`, Journal e `Spectre.turn/3`, non sostituirli in blocco.

Le Fasi 1 e 2 costituiscono il primo PoC pure-core: validano installazione
immutabile, continuazioni riprendibili e ritorni chiusi senza dipendere dai
satelliti dell’ecosistema.

### Fase 1 — Stack

Introdurre:

```text
Stack.Installable
Stack.Package
Stack.Installation
Stack.Definition
Stack.Runtime
Stack.Ref
```

Extension e Provider Mount diventano adapter legacy. Aggiungere manifest e
contract test versionati.

### Fase 2 — Run resumable

Introdurre `Spectre.Run` e separare:

```text
start → advance → resume
```

Definire i ritorni chiusi e mantenere `Turn` come proiezione pubblica.

### Fase 3 — Agent Instance

Evolvere `Spectre.Session` in Instance per `AgentRef + subject`:

- Registry e lookup;
- Subject Registry, `ExternalIdentity`, `LinkIntent` e `SubjectLink`;
- più Run e ready queue;
- Invocation in-flight;
- fairness via mailbox;
- confini osservabili di `turn/3`.

### Fase 4 — Lifecycle per Run

Spostare il vincolo di un singolo Effect dallo State globale alla Run. Rendere
Effect, idempotency key e Receipt ripristinabili.

### Fase 5 — Flow, Work e Frame

Compilare Flow, Work, Vigil, Ledger e label in IR ispezionabile,
serializzabile e versionata. Integrare Move chiuse, firma canonica di
`resolve`, provenienza degli argomenti e trust firewall.

### Fase 6 — Continuity plane

Integrare in Directive:

- Task e Run persistence;
- checkpoint, passivazione e recovery;
- Ledger e transition table;
- timer, lease e wait;
- Enrollment;
- Outbox e Delivery Receipt.

### Fase 7 — Control plane

Implementare:

- `confirm`, `enroll`, `revoke`;
- STOP protetto;
- Steward e ordine di claim;
- comandi tipizzati `amend`, `pause` e `resume`;
- Presentation e `present`;
- label umane e presenter sostituibile dello Steward;
- Commitment e attribuzione dei budget;
- `review` ed `explain`.

### Fase 8 — Librerie

Collegare progressivamente:

- Kinetic ai Frame e alle Move chiuse;
- Prism a `Inference.Request`;
- Lens alle Operation e a `wake on_change`;
- Mnemonic a recall/remember committati;
- Beam a ExternalIdentity, protocollo di linking, Stimulus, origin, reply,
  notify e Receipt;
- Pulse a Relation, DelegationGrant ed Envelope.

### Fase 9 — Prova

Costruire Rehearsal sulla stessa IR, replay dal Journal e suite end-to-end con
crash, timeout, rolling upgrade, consenso, claim concorrenti e dedup degli
Effect. `Acme.JobAgent` del §17 diventa la prima suite di conformance
eseguibile: ogni esempio del documento deve compilare contro la DSL reale ed
essere provato in Rehearsal.

`Turn.Handler` resta un boundary esplicito e compatibile, non il plugin system
delle librerie.

## 19. Decisioni esplicitamente scartate

Spectre vNext non introduce:

- un PID globale per tutti gli utenti di un Agent;
- un processo per Flow, Work, Task, Run o Vigil;
- un secondo cervello dentro Lens, Directive o Pulse;
- un catalogo globale di tool visibile al modello;
- Operation installate automaticamente autorizzate;
- macro globali importate dai package;
- `Stance`, `mode` o un ambiguo `ask`;
- requirement duplicati in Stack, Skill, Flow e Work;
- una DSL pubblica `mission`;
- un secondo executor dentro Directive;
- un planner autonomo dentro Lens;
- `Turn.Handler` impliciti per ogni libreria;
- `:gen_statem` internal events per avanzare le Run;
- una chiamata sincrona sospesa fino alla fine di Task lunghe;
- fusioni implicite di Subject basate su numero, nome o decisione del modello;
- notifiche proattive senza Enrollment e Outbox;
- consenso rituale prima di ogni Operation read-only;
- `amend`, `pause` e `resume` implementati separatamente in ogni Flow;
- una voce Steward hardcoded come semantica di controllo;
- deleghe stringly senza Relation e Grant;
- MCP o A2A come modello interno;
- Observation esterne trattate come istruzioni;
- scritture Ledger prima del commit;
- memoria automatica di ogni Observation;
- chain-of-thought nel Journal;
- secret in prompt, planner, Journal o Mnemonic.

## 20. Sintesi

```text
Stack        installa e risolve l’ambiente
Definition   descrive l’Agent
Instance     isola stato, ordinamento e failure per subject
SubjectLink  collega identità esterne solo dopo verifica esplicita
Actor        possiede lo stato e schedula molte Run
Flow         reagisce a uno Stimulus
Work         persegue un obiettivo
Task         rende durevole un Work concreto
Run          conserva la continuazione attiva
Ledger       conserva la verità operativa
Vigil        definisce un’intenzione proattiva
Enrollment   la autorizza per subject e origin
Outbox       governa le notifiche
Steward      governa il dialogo di controllo
Presentation lega ciò che è mostrato a chiavi risolvibili
Commitment   rappresenta una promessa durevole
Kinetic      sceglie una Move consentita
Prism        sceglie la cognizione adatta
Lens         osserva il mondo
Mnemonic     ricorda conoscenza committata
Directive    persiste, passiva e riprende
Beam         collega persone e applicazioni
Pulse        collega Agent tramite contratti tipizzati
Group        coordina Agent che restano autonomi
Journal      conserva l’evidenza operativa
Rehearsal    prova la stessa IR senza effetti reali
```

Spectre vNext diventa così un sistema nel quale l’Agent è davvero vivo: una
identità persistente incarnata in un Actor OTP isolato per subject, capace di
intercalare molte attività, proseguire lavori durevoli, agire solo sotto policy
e consenso, mantenere verità operative e promesse, comunicare senza diventare
uno spam bot, delegare mediante contratti verificabili e spiegare ogni risultato
attraverso evidenze riproducibili.
