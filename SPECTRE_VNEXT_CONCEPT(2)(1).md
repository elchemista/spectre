# Spectre vNext — concept verificato

> Stato: proposta architetturale.
>
> Questo documento distingue rigorosamente:
>
> - ciò che esiste oggi nelle repository;
> - le decisioni già confermate per vNext;
> - ciò che deve ancora essere progettato.
>
> I blocchi Elixir presenti nel documento mostrano soltanto API già
> documentate nelle repository. Non vengono presentate pseudo-API vNext.

## Regola di provenienza

Ogni affermazione del concept deve appartenere a una di queste categorie:

| Categoria | Significato |
|---|---|
| **Esiste oggi** | è verificabile nel codice o nella documentazione delle repository |
| **Decisione vNext** | è una scelta architetturale già confermata |
| **Da progettare** | il comportamento è richiesto, ma nomi, moduli e sintassi pubblica non sono ancora decisi |

Una cosa **da progettare** non deve comparire in un esempio come se fosse già
una funzione, una macro o una struct reale.

In particolare, questo concept non introduce matcher, helper, struct o
callback Work con nomi non ancora approvati.

### Correzioni assorbite dalla revisione

Della proposta Wayfinder vengono adottate le idee di:

- Mission nata normalmente dal dialogo;
- Waypoint al posto di “ticket”;
- Question atomica, durevole e correlata;
- frontier non bloccata dalle domande indipendenti;
- blocker Work trasformabile da Directive in decisione umana;
- rami Work dichiarati e chiusi;
- valutazione esplicita dei prototipi.

Della revisione architetturale vengono inoltre adottate queste decisioni:

- l’Agent Instance resta il GenServer proprietario dello stato canonico;
- Flow, Work e Vigil sono strutture distinte dentro lo stesso Agent;
- Work, Vigil e Directive riusano lo stesso runtime operativo Spectre;
- il runtime comune si chiama runtime operativo Spectre e non “runtime Work”;
- le operazioni lente avvengono fuori dal GenServer, ma non possiedono lo
  stato;
- ogni tentativo operativo attivo usa un Runner isolato, temporaneo e
  supervisionato;
- ogni Runner esegue una sola operazione e termina dopo il Result o il crash;
- l’Agent monitora il Runner e decide retry o ripresa dopo un crash;
- snapshot e modifiche ritornano all’Agent per un merge serializzato;
- l’Agent può mettere in pausa, aggiornare e riprendere Work, Vigil e
  Directive senza perdere il checkpoint;
- gli aggiornamenti sono revisionati, validati e collegati alla loro
  provenienza; non riscrivono silenziosamente l’input originale;
- pausa e stop sono diversi: la pausa è reversibile, lo stop è terminale;
- la pausa avviene normalmente al prossimo confine sicuro; un’interruzione
  immediata richiede fencing e policy esplicita;
- Vigil appartiene al core Spectre;
- un confronto cognitivo Vigil usa un nuovo Runner e non blocca l’Agent;
- Directive appartiene semanticamente a `spectre_directive`, ma il suo loop
  può essere eseguito dal runtime operativo Spectre;
- Directive riconcilia le viste Work committed e non dipende dalla consegna
  effimera degli eventi;
- Frontier e Fog sono derivate deterministicamente, mentre Destination e
  Resolution restano verificabili e collegate alle fonti primarie;
- budget e scadenza producono esiti terminali tipizzati;
- la cognizione a esiti chiusi viene validata prima del commit;
- visibilità e consegna proattiva dipendono da policy esplicite;
- il dataflow senza variabili usa-e-getta resta un requisito, mentre il
  meccanismo del compiler resta da progettare;
- Group viene rimosso e handoff resta una decisione aperta.

Non vengono adottati come API:

- la pseudo-DSL Work con `given`, `return`, `step`, `utilize`, `repeat`,
  `sift`, `track`, `done when`, `decide`, `infer` o `notify`;
- variabili DSL come `work_ref`, `view` o `answer`;
- nomi non verificati quali `Steward`, `Spectre.Continuity.*`,
  `Presentation` o `Commitment`;
- `{:needs, question}` come confine generico;
- `command` o `:command` come nuovo verbo DSL inventato;
- l’equazione “`decide` = Kinetic” o “`infer` = Prism”.

Kinetic oggi seleziona candidati operativi, Prism seleziona un profilo
cognitivo e Directive `invoke` esegue target autorizzati. Nessuno di questi
contratti viene rinominato per far sembrare già implementato il target vNext.

---

## 1. Decisione principale

Spectre vNext deve separare quattro semantiche, senza trasformarle in quattro
runtime indipendenti:

| Concetto | Dominio | Responsabilità |
|---|---|---|
| **Flow** | `spectre` | ricevere input ed eventi, instradare la conversazione, rispondere e interagire con gli altri loop |
| **Work** | `spectre` | eseguire nel tempo un’operazione precisa e osservabile |
| **Vigil** | `spectre` | osservare qualcosa nel tempo e reagire a timer o eventi dichiarati |
| **Directive** | `spectre_directive` | chiarire una Destination verificabile e pianificare una Mission quando il percorso è ancora nella nebbia |

Flow usa il runtime conversazionale già fondato su Run e Turn.

Work, Vigil e Directive riusano invece lo stesso runtime operativo Spectre
per lifecycle, attese, Effect, Invocation, Result, checkpoint, budget,
controllo e osservabilità.

Nel resto del documento questo motore viene chiamato **runtime operativo
Spectre**. Non viene chiamato “runtime Work”: Work è uno dei controller che lo
usa, non il proprietario del runtime e non la semantica comune imposta a Vigil
o Directive.

Il runtime operativo non è un singolo processo proprietario dello stato. È
composto da:

- scheduler e reducer dentro l’Agent;
- supervisione dinamica dei Runner;
- un Runner isolato e temporaneo per ogni tentativo operativo che sta
  avanzando;
- protocollo di Result, progress, crash, controllo e ripresa.

Condividere il runtime non rende uguali le loro regole.

### Flow

Un Flow è la linea conversazionale:

- riceve un input;
- riceve eventualmente un evento;
- sceglie la route;
- può ragionare;
- può eseguire un’operazione breve;
- può chiedere l’avvio o lo stato di un Work;
- può chiedere lo stato di una Vigil o di una Mission Directive;
- può chiedere pausa, aggiornamento, ripresa o stop di un loop autorizzato;
- può rispondere o inviare una notifica.

Il Flow non deve possedere il ciclo persistente di un Work.

### Work

Un Work è una linea operativa:

- svolge una cosa precisa;
- conserva il proprio stato operativo dentro lo stato canonico dell’Agent;
- usa un Runner separato per eseguire le operazioni;
- continua attraverso più operazioni;
- può usare Lens;
- può usare un candidato operativo prodotto da Kinetic;
- può eseguire funzioni registrate dall’applicazione;
- salva checkpoint e risultati;
- può ricevere nuove informazioni o modifiche dichiarate mentre è in corso;
- possiede una funzione deterministica che stabilisce il completamento
  operativo.

Un Work non contiene una Mission, un obiettivo aperto o una destinazione da
interpretare.

Un Work non crea Work figli. Se la sua operazione richiede dieci passaggi,
sono dieci passaggi dello stesso Work.

### Vigil

Una Vigil è una linea di sorveglianza:

- resta registrata tra un’osservazione e la successiva;
- viene risvegliata da timer o eventi dichiarati;
- può usare Lens, funzioni applicative, Kinetic e inferenze;
- conserva l’ultima osservazione e lo stato necessario al confronto;
- decide in modo dichiarato se un cambiamento è rilevante;
- può restare silenziosa;
- può produrre un evento destinato a un Flow;
- può aggiornare risorse, trigger o soglie quando la sua definizione lo
  permette;
- termina per stop, scadenza, condizione dichiarata, errore terminale o
  budget.

Vigil appartiene al core Spectre e riusa il runtime operativo Spectre. Non è
un package satellite e non è un Work infinito mascherato: ha una semantica
esplicita di osservazione continuativa.

### Directive

Directive è il mission planner:

- possiede la Mission;
- chiarisce la destinazione;
- costruisce e aggiorna una MissionMap;
- tiene traccia della fog;
- calcola la frontier;
- crea Waypoint;
- registra Question, risoluzioni e dipendenze;
- può distribuire Waypoint tra sessioni, persone, Agent o Work;
- può avviare più Work precisi e coordinarne i risultati;
- può ricevere nuove informazioni, vincoli o evidenze e ricalcolare la mappa;
- può cambiare la MissionMap quando nuove informazioni riducono o spostano la
  fog.

Directive appartiene soltanto a `spectre_directive`.

La libreria fornisce il controller orientato alla Destination e lo schema
dello stato Mission. Il runtime operativo Spectre può eseguire quel controller,
conservare il suo stato tipizzato e riprenderlo, senza interpretare MissionMap,
Waypoint, Fog o Question.

Il core Spectre non introduce un secondo tipo Mission. Una Mission Directive
non è un normale Work, anche quando ne riusa il runtime.

---

## 2. La metafora della stazione

L’Agent Instance è la stazione ed è concretamente il GenServer che possiede lo
stato canonico dell’Agent.

```text
                       INSTANCE SUPERVISOR

       Agent GenServer                    Runner Supervisor
   stato canonico e mailbox              supervisione dinamica
             |                                  |
       Flow / Run / Turn                 Runner Work A
       Work / Vigil / Mission            Runner Work B
             |                           Runner Vigil
             |                           Runner Directive
             +------ progress/Result/DOWN ------+
```

La stazione ordina i messaggi, applica le transizioni e committa le revisioni.
Le operazioni lente possono avanzare contemporaneamente nei Runner. Ogni
Runner riceve soltanto uno snapshot revisionato e non possiede lo stato
canonico.

Il nome esatto dei moduli e la topologia OTP definitiva sono **da
progettare**. L’invariante è che il crash di un Runner non deve far crashare
l’Agent e che l’Agent deve poter ricreare il Runner dall’ultimo checkpoint.

La metafora non cambia il significato dei tipi:

- **Flow** è la definizione della linea conversazionale e del routing;
- **Run** è la continuazione core creata per avanzare un input o un Turn;
- **Work** è una procedura operativa precisa eseguita dal runtime operativo
  Spectre;
- **Vigil** è un loop di osservazione risvegliato da timer o eventi;
- **Directive** è un controller di missione fornito da
  `spectre_directive` ed eseguito sullo stesso runtime operativo.

Una conversazione avanza attraverso Run successivi governati dai Flow. Work,
Vigil e Directive avanzano attraverso transizioni e checkpoint mantenuti
dentro lo stesso Agent.

Un interscambio può servire per:

- avviare un Work da un Flow;
- leggere lo stato di un Work durante una nuova conversazione;
- informare un Work con nuovi dati;
- mettere in pausa, aggiornare, riprendere o fermare un loop;
- segnalare che un Work ha trovato qualcosa;
- segnalare che un Work è terminato;
- risvegliare una Vigil;
- consegnare a Directive il risultato di un Work;
- attivare un Flow che prepara una risposta;
- attivare una notifica solo quando un risultato è importante;
- lasciare il risultato silenzioso e disponibile soltanto quando viene chiesto.

La stazione è un unico proprietario dello stato, non un unico esecutore delle
operazioni lente.

La chat deve restare utilizzabile mentre un Work, una Vigil o una Mission:

- aspetta Lens;
- aspetta una funzione lenta;
- esegue una richiesta al modello;
- salva un documento;
- attraversa molte pagine;
- applica nuove informazioni ricevute dalla chat;
- attende un timer o un risultato esterno.

---

## 3. Stato reale delle repository

Questa sezione descrive ciò che esiste oggi, non il target vNext.

### 3.1 `spectre`

La repository [`elchemista/spectre`](https://github.com/elchemista/spectre)
possiede già:

- `Spectre.Agent`;
- `Spectre.Stack`;
- `Spectre.Skill`;
- `Spectre.State`;
- `Spectre.Result`;
- `Spectre.Run`;
- `Spectre.Turn`;
- `Spectre.Effect`;
- `Spectre.Invocation`;
- `Spectre.Awaitable`;
- `Spectre.Instance`;
- policy;
- action provider;
- lifecycle esplicito degli Effect;
- checkpoint dei Run;
- Agent Instance con più Run.

La DSL attuale verificata usa `flow` e `on`.

Gli handler attuali sono:

- `ask`;
- `reply`;
- `run`;
- `action`.

Esempio tratto dalla forma reale documentata:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent

  flow :support do
    on :PRICING, regex: ~r/\b(price|pricing|cost)\b/i do
      reply(:pricing)
    end

    on :DELETE_ACCOUNT, regex: ~r/\bdelete my account\b/i do
      action(:delete_account)
    end
  end
end
```

Nella DSL attuale:

- `run` chiama una funzione locale dell’Agent;
- `action` prepara un Effect applicativo;
- l’esecuzione reale dell’Effect attraversa il lifecycle esplicito di Spectre;
- `Spectre.turn/3` restituisce il primo boundary osservabile;
- `Spectre.Runtime` possiede il protocollo chiuso
  `start/advance/resume`.

Oggi non esiste ancora un dominio pubblico `Spectre.Work`.

Il Run attuale è una continuazione di runtime. Non deve essere rinominato Work:
il nuovo Work ha una semantica operativa diversa e può contenere molti cicli,
molte Invocation e molti boundary.

Fonti:

- [DSL attuale](https://github.com/elchemista/spectre/blob/main/docs/DSL.md)
- [Run riprendibili](https://github.com/elchemista/spectre/blob/main/docs/RUNS.md)
- [Agent Instance](https://github.com/elchemista/spectre/blob/main/docs/INSTANCES.md)
- [Confini di integrazione](https://github.com/elchemista/spectre/blob/main/docs/INTEGRATIONS.md)

### 3.2 `spectre_prism`

La repository
[`elchemista/spectre_prism`](https://github.com/elchemista/spectre_prism)
seleziona un profilo cognitivo per una richiesta di inferenza.

Oggi Prism considera:

- livello minimo;
- preferenza;
- modalità;
- dimensione del contesto;
- privacy;
- costo;
- latenza;
- numero di tentativi.

I livelli documentati sono:

- `fast`;
- `balanced`;
- `deep`.

Prism non schedula lavoro e non possiede la continuità di un Work.

La scelta dell’intelligenza per un Work dovrà quindi essere tradotta in
vincoli Prism applicati alle future inferenze di quel Work.

### 3.3 `spectre_kinetic`

La repository
[`elchemista/spectre_kinetic`](https://github.com/elchemista/spectre_kinetic)
trasforma Action Language in un candidato di funzione validato.

Kinetic:

- mantiene un registry compilato di funzioni;
- seleziona un tool;
- mappa gli argomenti;
- segnala campi mancanti;
- restituisce una proposta;
- non esegue la funzione.

Quindi Kinetic può aiutare un Work a decidere **quale operazione registrata
usare nel passaggio corrente**, ma:

- non possiede il Work;
- non decide quando il Work è terminato;
- non deve creare implicitamente un workflow;
- non deve eseguire il side effect.

### 3.4 `spectre_lens`

La repository
[`elchemista/spectre_lens`](https://github.com/elchemista/spectre_lens)
possiede già un runtime browser indipendente e le operazioni:

- open;
- look;
- discover;
- act;
- export.

Lens produce riferimenti portabili e viste agent-safe. I processi browser
restano fuori dal Run e dallo State Spectre.

Un Work può usare Lens per:

- aprire una pagina;
- leggerne la vista;
- seguire la paginazione;
- estrarre informazioni;
- esportare un documento;
- osservare cambiamenti.

Lens non possiede il Work e non deve schedulare autonomamente una Mission.

### 3.5 `spectre_mnemonic`

La repository
[`elchemista/spectre_mnemonic`](https://github.com/elchemista/spectre_mnemonic)
è il memory engine.

Mnemonic possiede:

- remember;
- recall;
- search;
- consolidamento;
- memoria attiva;
- memoria persistente;
- provenance;
- governance;
- isolamento per scope.

Mnemonic non è lo store operativo del Work.

Nel target vNext il Work conserva il proprio stato nella sezione operativa
dello stato canonico dell’Agent. Soltanto osservazioni, risultati o artifact
committed possono essere ricordati in Mnemonic secondo policy.

### 3.6 `spectre_directive`

La repository
[`elchemista/spectre_directive`](https://github.com/elchemista/spectre_directive)
possiede già un mission loop:

- Mission;
- piano;
- step;
- richieste correlate;
- reasoner;
- invocation;
- richieste di informazioni;
- patch versionate del piano;
- outcome;
- Store opzionale;
- runtime OTP opzionale.

Directive già dichiara esplicitamente che il package non possiede:

- memoria;
- provider LLM;
- tool discovery;
- Kinetic;
- policy applicativa;
- persistence backend concreto.

Questo è il punto di partenza reale per evolvere Directive verso il modello
Wayfinder. Non serve creare una seconda Mission nel core.

### 3.7 `spectre_pulse`

La repository
[`elchemista/spectre_pulse`](https://github.com/elchemista/spectre_pulse)
possiede un protocollo di comunicazione tra Agent:

- envelope versionato;
- indirizzo logico;
- contact e directory;
- transport sostituibili;
- correlazione tramite `relates_to`;
- atti `inform`, `query` e `request`;
- Effect Pulse eseguito attraverso Spectre.

Pulse non coordina i Work e non possiede task, workflow o Mission.

Può trasportare un evento o una richiesta tra Agent, ma il lifecycle semantico
resta del loop Flow, Work, Vigil o Directive e il commit resta dell’Agent
proprietario.

### 3.8 `spectre_beam`

La repository
[`elchemista/spectre_beam`](https://github.com/elchemista/spectre_beam)
è il confine dei canali esterni:

- normalizzazione inbound;
- binding endpoint/conversazione;
- consegna reattiva;
- azioni di consegna proattiva;
- adapter ExGram ed ExWapp;
- pipeline prima e dopo decode/delivery.

Beam non decide se un risultato Work è importante.

Il Flow o una policy applicativa decide se notificare; Beam consegna il
messaggio attraverso il canale scelto.

---

## 4. Flow vNext

### Decisione confermata

Flow resta il luogo nel quale passano:

- input umani;
- input di canale;
- eventi applicativi;
- eventi provenienti da Work, Vigil e Directive;
- risposte;
- richieste di avvio o controllo dei loop operativi.

Flow non diventa un workflow engine durevole.

### Compatibilità con la DSL reale

La forma reale `flow/on` deve restare riconoscibile.

La route attuale usa:

- una label;
- evidenze come regex, embedding, classifier o metadata check;
- un handler.

Gli eventi dei loop dovranno entrare nello stesso routing normale dopo essere
stati convertiti in un input/evento tipizzato dal runtime.

La forma esatta di questa conversione è **da progettare**. Non viene inventato
un matcher speciale in questo documento.

### Evoluzione dei verbi

È già stato deciso che il futuro Flow deve evitare il verbo ambiguo `ask`.

Le responsabilità richieste sono:

| Responsabilità | Semantica |
|---|---|
| ragionare | usare il modello senza eseguire funzioni |
| agire | lasciare che il planner scelga tra operazioni esplicitamente ammesse |
| eseguire | chiamare un’operazione già determinata |
| avviare lavoro | creare un Work operativo separato |
| rispondere | consegnare il risultato corrente alla Source |

I nomi già discussi per queste responsabilità sono `reason`, `act`, `run`,
`work` e `reply`.

La firma esatta delle macro, il modo in cui ricevono input e il modo in cui
ritornano errori devono essere progettati sul compilatore reale di Spectre.

Questo concept fissa la semantica, non inventa le firme.

### Nessun plumbing manuale obbligatorio

La DSL non deve obbligare l’autore a creare variabili usa-e-getta per:

- risultato del ragionamento;
- riferimento del Work;
- risultato di una funzione;
- Observation;
- Artifact;
- risposta finale.

Resta però **da progettare** il modo esatto con cui il compiler rappresenterà
e distinguerà i risultati. Due verbi uguali nello stesso Flow o due risultati
dello stesso tipo non possono essere risolti per posizione implicita o per
supposizione.

Il compiler dovrà:

- verificare il dataflow;
- distinguere risultati omonimi in modo esplicito e compilabile;
- rifiutare le ambiguità;
- evitare riferimenti manuali quando il contesto è già univoco.

Questo concept non decide ancora se la rappresentazione interna sarà un frame,
slot tipizzati o un’altra struttura.

Il riferimento stabile del Work appartiene:

- al runtime;
- alla relazione con il Turn di origine;
- agli eventi;
- all’API host.

Non deve essere una variabile obbligatoria dentro il Flow.

### Flow e stato dei loop operativi

Quando l’utente chiede:

- «Come procede?»;
- «Cosa hai trovato?»;
- «Cosa stai facendo adesso?»;
- «Sei bloccato?»;
- «Quante pagine hai letto?»;
- «Quale intelligenza stai usando?»;

un nuovo Turn deve:

1. identificare il Work, la Vigil o la Mission corretta;
2. leggere la vista committed dentro lo stato canonico dell’Agent;
3. costruire una risposta;
4. lasciare il loop in esecuzione.

Se più loop sono compatibili con la richiesta, il Flow deve chiedere quale.
Non deve sceglierne uno attraverso una supposizione del modello.

### Flow e controllo naturale dei loop

Lo stesso vale quando la persona scrive:

- «ferma un attimo la ricerca»;
- «usa anche questi link»;
- «aggiungi questo vincolo e continua»;
- «controlla ogni due ore invece che ogni dieci minuti»;
- «metti in pausa la Mission»;
- «riprendi da dove eri arrivato»;
- «chiudi definitivamente questo lavoro».

Il Flow:

1. risolve il loop visibile e autorizzato;
2. distingue pausa reversibile da stop terminale;
3. normalizza le nuove informazioni contro lo schema del controller;
4. invia il comando correlato all’Agent;
5. risponde usando lo stato di controllo committed.

Non serve una variabile DSL che contenga il riferimento del Work. L’Agent usa
i riferimenti stabili associati a Subject, origine, Turn e loop attivi. Se il
destinatario è ambiguo, il Flow chiede chiarimento prima di mutare qualsiasi
stato.

La risposta deve distinguere «pausa richiesta» da «pausa raggiunta». Non deve
dire che l’aggiornamento è applicato o che il loop è ripartito prima del
relativo commit.

### Visibilità

“Visibile nella conversazione” non è una regola sufficiente.

Ogni Work, Vigil e Mission deve conservare:

- Subject canonico;
- Source e Turn di origine;
- origini autorizzate;
- scope di visibilità;
- destinazioni autorizzate per un’eventuale consegna.

Due canali possono vedere lo stesso loop quando appartengono allo stesso
Subject verificato e la policy lo permette. Un’origine condivisa, di gruppo o
sensibile resta limitata alla propria origine salvo autorizzazione esplicita.

La visibilità e la consegna proattiva sono decisioni di policy. Non vengono
inferite dal modello.

### Il risultato non riscrive un Turn concluso

Quando un Runner restituisce progress o Result, l’Agent:

1. correla il messaggio al loop e al tentativo che lo attendono;
2. verifica epoch, fencing e revisione dello snapshot;
3. scarta messaggi tardivi, duplicati o non più autorizzati;
4. applica o rifiuta le modifiche proposte;
5. aggiorna e committa lo stato canonico dell’Agent;
6. aggiorna il checkpoint del loop;
7. registra gli artifact e, se consentito, le osservazioni destinate a
   Mnemonic;
8. pubblica gli eventi committed previsti;
9. rende il nuovo stato visibile ai Turn successivi.

Non modifica retroattivamente il Turn conversazionale che aveva avviato il
Work. Se serve una risposta o una notifica, l’evento apre o alimenta un nuovo
avanzamento attraverso un Flow.

Stato conversazionale e stato Work restano sezioni semanticamente distinte,
ma vengono ordinati e committati dallo stesso Agent.

---

## 5. Work vNext

### Definizione

Un Work è:

> un’esecuzione operativa asincrona, definita in anticipo, che aggiorna il
> proprio stato dentro l’Agent finché la procedura termina oppure il runtime
> produce un esito terminale tipizzato.

Il Work non riceve un obiettivo aperto.

Riceve:

- input tipizzato;
- una definizione operativa;
- stato iniziale;
- policy e limiti;
- eventuali vincoli cognitivi.

Il runtime operativo Spectre che esegue il Work è riusabile. Fornisce il
meccanismo comune anche a Vigil e ai loop Directive, ma non concede loro
automaticamente la semantica rigida di una Work Definition.

### Contenuto minimo di una Work Definition

La futura Work Definition deve dichiarare:

1. identità e versione;
2. schema dell’input;
3. schema dello stato operativo;
4. operazioni del ciclo;
5. funzione che applica il risultato allo stato;
6. funzione che decide se l’operazione del Work è completata;
7. eventuali rami chiusi e le condizioni tipizzate che li selezionano;
8. eventuali confini di attesa o blocker dichiarati;
9. errori recuperabili e terminali;
10. retry e timeout;
11. budget di passi, tempo, costo e risorse rilevanti;
12. comportamento quando un budget viene esaurito;
13. artifact e informazioni pubblicabili;
14. vincoli di sicurezza;
15. eventuali decisioni cognitive a dominio chiuso;
16. quali informazioni o configurazioni possono essere aggiornate durante
    l’esecuzione e il loro schema;
17. funzione deterministica di applicazione dell’aggiornamento;
18. regole di invalidazione di cursori, risultati, cache o passaggi già
    committed;
19. punto dal quale riprendere dopo ogni categoria di aggiornamento;
20. compatibilità del checkpoint tra versioni.

I nomi Elixir dei callback sono **da progettare**.

### Ciclo operativo

Il lifecycle richiesto è:

```text
avvio
  |
  v
carica stato/checkpoint
  |
  v
determina la prossima operazione definita
  |
  v
Agent crea snapshot e tentativo
  |
  v
avvia Runner supervisionato
  |
  v
Runner crea/esegue Effect o Invocation
  |
  v
Runner restituisce Result
  |
  v
Runner termina; Result contiene modifica proposta e artifact
  |
  v
Agent valida revisione e applica il merge
  |
  v
commit dello stato e del checkpoint
  |
  v
funzione di termine
  |
  +-- non finito --> prossimo ciclo
  |
  +-- finito -----> evento terminale
```

La funzione di termine:

- legge soltanto stato committed;
- restituisce una decisione deterministica;
- non interroga il modello;
- non usa Kinetic;
- non interpreta un goal;
- può essere rieseguita dopo un restart;
- produce lo stesso risultato sullo stesso stato.

La valutazione avviene dopo il commit della transizione Work. Non si assume che
ogni chiamata interna o ogni callback sia automaticamente un checkpoint.

### Esiti terminali e budget

La funzione deterministica decide il completamento **operativo** della
procedura. Il runtime può inoltre terminare il Work per una causa di controllo.

Le categorie terminali minime sono:

- completamento;
- fallimento;
- cancellazione;
- scadenza;
- esaurimento del budget.

Queste sono categorie semantiche, non nomi di atom già approvati.

L’esaurimento del budget non è un’eccezione invisibile. Il risultato terminale
deve indicare:

- limite raggiunto;
- consumo osservato;
- ultima revisione committed;
- stato e artifact parziali disponibili.

Uno stato di attesa o un blocker non è terminale.

### Rami chiusi

Un Work può avere rami soltanto quando tutti i rami sono dichiarati nella sua
definizione.

La selezione di un ramo deve dipendere da:

- un valore tipizzato già committed;
- una condizione deterministica;
- oppure una decisione cognitiva già committata dentro un insieme finito di
  esiti ammessi dalla definizione.

Il modello non può inventare un nuovo ramo, una nuova operazione o una nuova
procedura durante l’esecuzione.

Un ramo dichiarato resta parte dello stesso Work. Non è un Work figlio.

### Nessun Work figlio

Un Work non lancia un altro Work.

Un Work può invece:

- eseguire una sequenza di operazioni Lens;
- richiedere una scelta a Kinetic;
- eseguire una funzione applicativa;
- leggere dal database;
- leggere log;
- interrogare un servizio meteo;
- salvare dati;
- creare un report;
- aggiornare un repository attraverso una capability autorizzata;
- attendere un risultato;
- continuare con il prossimo passaggio.

Queste sono operazioni dello stesso Work.

Se serve pianificare più Work indipendenti perché il percorso non è noto,
quella responsabilità appartiene a Directive.

### Funzioni applicative

Il Work deve poter usare funzioni dell’applicazione.

Deve riutilizzare il confine già esistente di Spectre:

```text
operazione logica
  -> Effect
  -> policy
  -> Invocation
  -> executor
  -> Result
  -> transizione Work
```

Una funzione eseguibile deve essere registrata dall’applicazione con:

- identità stabile;
- input validabile;
- output validabile;
- timeout;
- rischio;
- regola di idempotenza;
- strategia di receipt o riconciliazione, quando necessaria;
- executor risolvibile dopo restart.

Il modello e Kinetic non possono inventare:

- moduli;
- funzioni;
- MFA;
- codice Elixir;
- argomenti fuori schema.

Kinetic può proporre soltanto un’operazione presente nel registry ammesso per
quel passaggio.

### Uso di Lens

Un Work di paginazione può:

1. aprire la pagina iniziale;
2. leggere la vista tramite Lens;
3. estrarre i dati utili;
4. salvare i dati;
5. aggiornare il cursore;
6. verificare se esiste la pagina successiva;
7. ripetere;
8. terminare quando non esiste più paginazione.

La condizione “non esiste pagina successiva” è parte dello stato operativo.
Non è un obiettivo interpretato dal modello.

### Uso di Kinetic

Kinetic può essere usato quando il Work conosce il passaggio ma deve scegliere
tra più operazioni ammesse.

Esempio concettuale:

- il Work deve estrarre informazioni da una pagina;
- il registry ammette soltanto alcune operazioni;
- Kinetic sceglie il candidato;
- Spectre valida e autorizza;
- Spectre esegue;
- il Work riceve il risultato.

Kinetic non:

- crea il ciclo Work;
- persiste lo stato Work;
- decide la fine;
- esegue la funzione.

### Decisione cognitiva a dominio chiuso

Un Work può avere un passaggio nel quale serve classificare, estrarre o
scegliere un valore tramite un modello senza selezionare un’operazione
Kinetic.

La Work Definition deve allora dichiarare:

- schema dell’output;
- insieme o dominio degli esiti ammessi;
- validazione;
- numero massimo di tentativi;
- eventuale fallback deterministico;
- comportamento terminale se nessun risultato valido viene ottenuto.

Prism seleziona il profilo cognitivo, ma non valida l’esito.

Il runtime valida il risultato prima del commit. Un output malformato o fuori
dominio:

1. non viene committato;
2. può essere ritentato entro policy e budget;
3. produce un fallimento tipizzato quando i tentativi finiscono;
4. diventa un blocker umano soltanto se la Work Definition dichiara
   esplicitamente quel percorso.

Il nome e la rappresentazione pubblica di questo passaggio sono **da
progettare**.

### Attesa di una decisione umana

Un Work preciso può dichiarare in anticipo un punto nel quale potrebbe servire
un dato umano. In quel caso:

1. committa lo stato operativo raggiunto;
2. entra in uno stato di attesa o blocco;
3. pubblica un evento blocker tipizzato e correlato;
4. non si dichiara completato;
5. riprende dallo stesso checkpoint quando arriva una risposta autorizzata e
   correlata.

Se il blocker apre invece una procedura che la Work Definition non conosce, il
Work non può improvvisarla. Termina con un esito non riuscito o non applicabile
e lascia a Flow, all’host o a Directive la scelta del passo successivo.

Directive può trasformare un blocker in una propria Question, ma il Work non
possiede la Question, la Mission o il dialogo con la persona.

### Vista pubblica

Mentre il Work gira deve esistere una proiezione read-only.

Deve poter mostrare:

- identificatore presentabile;
- tipo di Work;
- stato: in coda, attivo, in attesa, in pausa oppure terminale;
- eventuale pausa richiesta ma non ancora raggiunta;
- categoria dell’esito terminale;
- fase corrente;
- operazione corrente;
- numero di cicli completati;
- numero di tentativi e retry;
- progresso reale, se misurabile;
- cursore o checkpoint redatto;
- risultati parziali committed;
- artifact prodotti;
- blocker;
- ultima modifica;
- revisione del contesto effettivo;
- ultimo aggiornamento applicato o rifiutato, in forma redatta;
- eventuale comando di controllo pendente;
- dati o risultati marcati come superati;
- prossima operazione già committed;
- vincoli cognitivi richiesti;
- profilo Prism effettivamente selezionato;
- fallback cognitivo avvenuto;
- ultimo crash o stato di riconciliazione, se rilevante.

Non deve mostrare:

- chain-of-thought;
- prompt interni;
- credenziali;
- client;
- PID;
- callback;
- payload sensibili;
- output non committed;
- percentuali inventate.

Il nome del modulo e la forma della struct pubblica sono **da progettare**.

### Controllo e aggiornamento in corso

Il runtime operativo Spectre deve permettere:

- lettura dello stato;
- pausa reversibile;
- ripresa;
- aggiunta di informazioni;
- modifica dei campi che la Work Definition dichiara aggiornabili;
- cambio dei vincoli cognitivi per le inferenze future;
- stop o cancellazione terminale.

I nomi delle API e dei verbi DSL sono **da progettare**. La semantica invece è
obbligatoria.

**Pausa e stop non sono sinonimi.**

- la pausa conserva checkpoint, stato, risultati e possibilità di ripresa;
- lo stop produce un esito terminale e lo stesso Work non può essere ripreso;
- continuare da un Work terminale richiede una nuova istanza esplicitamente
  collegata alla precedente, se l’applicazione lo permette.

Le mutazioni devono essere:

- autorizzate;
- correlate al Work corretto;
- validate contro la Work Definition;
- protette da revisione;
- serializzate dall’Agent GenServer;
- collegate al Turn, Subject e origine che le hanno richieste;
- osservabili nel journal.

L’input iniziale non viene sovrascritto silenziosamente. Il checkpoint conserva:

- input di base;
- successione committed degli aggiornamenti;
- revisione del contesto effettivo risultante;
- invalidazioni o dati superati prodotti dagli aggiornamenti.

Dal punto di vista dell’applicazione, quindi, gli argomenti effettivi del Work
possono cambiare durante l’esecuzione quando la Definition lo permette. Ai
fini di audit e replay, però, il runtime conserva sempre input originale e
successione delle modifiche che hanno prodotto il nuovo valore effettivo.

La Work Definition decide deterministicamente come un aggiornamento valido
modifica il contesto effettivo. Può, per esempio:

- aggiungere elementi a una coda;
- sostituire un filtro futuro;
- aggiungere una fonte o un vincolo;
- marcare un risultato precedente come superato;
- invalidare un cursore e ripartire da una fase dichiarata.

Non può trasformare il Work in una procedura diversa. Se le nuove informazioni
richiedono passaggi non previsti dalla Definition, l’aggiornamento viene
rifiutato oppure viene lasciato a Flow o Directive il compito di avviare un
altro Work.

Quando arriva una richiesta di pausa o aggiornamento mentre esiste un Runner
attivo, il runtime supporta due comportamenti semantici:

1. **pausa al confine sicuro**, comportamento predefinito: non viene avviato
   un altro Runner, il tentativo corrente può terminare e il suo Result viene
   valutato prima di entrare in pausa;
2. **interruzione immediata**, quando richiesta e autorizzata: l’Agent invalida
   il fencing del tentativo e chiede la terminazione del Runner.

La scelta esatta dei nomi pubblici è **da progettare**. Un side effect già
partito non viene annullato per supposizione: valgono le regole di receipt,
idempotenza e riconciliazione del runtime.

Quando il Work è quiescente e in pausa:

1. nessun nuovo Runner può partire;
2. l’Agent applica gli aggiornamenti validi in ordine di revisione;
3. committa il nuovo contesto effettivo e il checkpoint;
4. ricalcola la prossima operazione attraverso la Work Definition;
5. resta in pausa oppure accetta la ripresa.

La ripresa crea sempre un nuovo snapshot, un nuovo tentativo e un nuovo Runner.
Un Result proveniente dal tentativo precedente non può applicare stato basato
sul vecchio contesto.

Una singola intenzione espressa in chat, come «usa anche questi link», può
richiedere l’intera sequenza pausa, aggiornamento e ripresa. Non è una mutazione
reentrante: l’Agent la espande in transizioni serializzate e committa ciascun
passaggio necessario.

Per un Work di ricerca web, un aggiornamento può aggiungere URL conosciuti alla
coda delle fonti ancora da visitare. Il reducer del Work deduplica gli URL
contro fonti pendenti e già visitate, conserva i risultati committed e fa sì
che la funzione di termine consideri anche le nuove fonti.

Se il Work termina prima che la pausa venga applicata, non viene riaperto
silenziosamente. Il Flow informa la persona e può proporre un nuovo Work basato
sui risultati precedenti.

La cancellazione terminale deve distinguere:

- operazione non ancora iniziata;
- cancellazione confermata;
- risultato ambiguo;
- side effect già avvenuto.

---

## 6. Vigil vNext

### Definizione

Una Vigil è:

> un loop operativo durevole che resta in attesa di timer o eventi dichiarati,
> osserva una risorsa e aggiorna il proprio stato senza trasformare ogni
> osservazione in una notifica.

Vigil appartiene a `spectre` e riusa il runtime operativo Spectre.

Non è:

- una libreria separata;
- una Mission;
- un Work con una funzione di termine sempre falsa;
- un semplice evento che crea ogni volta una sorveglianza nuova.

La Vigil resta registrata dentro l’Agent tra un trigger e il successivo.

### Contenuto minimo di una Vigil Definition

La futura definizione deve dichiarare:

1. identità e versione;
2. risorsa o fenomeno osservato;
3. schema dello stato;
4. timer ed eventi che possono risvegliarla;
5. operazioni di osservazione;
6. funzione che applica l’osservazione allo stato;
7. regola di cambiamento o significatività;
8. eventi che può produrre;
9. policy di consegna richiesta;
10. budget, timeout, retry e backoff;
11. condizioni terminali;
12. risorse, trigger, intervalli, soglie e policy future aggiornabili;
13. reducer degli aggiornamenti e regole di invalidazione dei timer;
14. calcolo del prossimo trigger dopo la ripresa;
15. compatibilità del checkpoint tra versioni.

I nomi Elixir e la forma pubblica sono **da progettare**.

### Ciclo di sorveglianza

```text
registrazione
  |
  v
attesa di timer o evento dichiarato
  |
  v
snapshot dello stato Vigil
  |
  v
Agent avvia un Runner di osservazione
  |
  v
Runner esegue Effect / Invocation
  |
  v
Result correlato
  |
  v
Agent valida e committa la nuova osservazione
  |
  v
valutazione di significatività
  |
  +-- non rilevante --> nuova attesa
  |
  +-- rilevante ----> evento tipizzato --> nuova attesa
```

Una regola di significatività può essere deterministica oppure usare la
decisione cognitiva a dominio chiuso definita per Work.

Nel caso deterministico, l’Agent applica un reducer breve allo stato già
committed. Nel caso cognitivo, l’Agent non interroga il modello dentro il
GenServer: crea un nuovo snapshot, un nuovo tentativo e un nuovo Runner per la
sola valutazione di significatività. Il Runner restituisce un esito nel dominio
chiuso; l’Agent lo valida e lo committa prima che possa produrre un evento.

Il Runner di osservazione è già terminato prima di questo eventuale secondo
tentativo. Nessun Runner resta vivo mentre la Vigil attende il trigger
successivo.

### Lifecycle e controllo

Una Vigil deve poter essere:

- interrogata;
- messa in pausa;
- ripresa;
- fermata in modo terminale;
- rinnovata quando possiede una scadenza;
- aggiornata per risorse, trigger, intervalli, soglie e policy future dichiarate.

Durante la pausa:

- nessun trigger può avviare un nuovo Runner;
- un timer già consegnato viene ignorato se appartiene alla generazione
  invalidata;
- un Runner attivo raggiunge il confine sicuro oppure viene fenced secondo la
  modalità di pausa scelta;
- stato e ultima osservazione restano committed e interrogabili.

Un aggiornamento può, per esempio, aggiungere una città, cambiare la frequenza
di controllo o modificare una soglia di significatività. Non può cambiare
silenziosamente consenso o autorizzazioni di consegna: questi attraversano la
policy applicativa.

Alla ripresa l’Agent committa la configurazione effettiva, crea una nuova
generazione dei trigger e ricalcola il prossimo timer. Eventi o timer della
configurazione precedente non possono produrre una nuova osservazione.

La vista deve mostrare almeno:

- cosa sta osservando;
- ultimo trigger;
- ultima osservazione committed;
- prossimo timer, quando noto;
- generazione e revisione della configurazione corrente;
- stato corrente;
- eventuale pausa o aggiornamento pendente;
- numero di osservazioni;
- ultimo cambiamento rilevante;
- budget consumato;
- policy di consegna applicabile;
- eventuale errore o backoff.

Una Vigil termina per stop, scadenza, condizione dichiarata, errore terminale
o budget esaurito. Può essere dichiarata senza scadenza soltanto quando policy
e consenso lo permettono; deve comunque restare controllabile.

Una Vigil terminale non viene ripresa. Per tornare a sorvegliare si registra
una nuova Vigil correlata, quando autorizzato.

## 7. Runner e isolamento delle esecuzioni

### Ruolo del Runner

Il Runner è l’unità esecutiva isolata del runtime operativo Spectre.

Un Runner:

- appartiene a un solo loop, a una sola operazione e a un solo tentativo;
- riceve uno snapshot dello stato necessario;
- esegue Effect, Invocation o calcolo ammessi;
- può produrre progress;
- restituisce Result, artifact e una modifica proposta;
- non committa direttamente lo stato canonico;
- non decide autonomamente retry o restart;
- può terminare senza terminare semanticamente il loop.

Il Runner può conservare localmente una copia dello stato Work o del payload
del loop, ma quella copia non è autoritativa.

Lo stato canonico resta nell’Agent.

### Avvio e correlazione

Quando un loop deve avanzare, l’Agent prepara almeno:

- identità del loop;
- revisione di partenza;
- revisione del contesto effettivo;
- generazione del controllo del loop;
- identificatore del tentativo;
- epoch o fencing token dell’Agent;
- snapshot autorizzato;
- operazione da eseguire;
- policy, timeout e budget residuo;
- idempotency key quando esiste un side effect.

La rappresentazione esatta è **da progettare**.

Progress e Result devono riportare abbastanza informazioni da permettere
all’Agent di verificare:

- loop corretto;
- tentativo ancora attivo;
- revisione compatibile;
- contesto e generazione di controllo ancora validi;
- epoch valido;
- operazione attesa;
- eventuale receipt.

### Lifecycle del Runner

```text
Agent sceglie la prossima transizione
        |
        v
crea snapshot, attempt ed epoch
        |
        v
avvia Runner supervisionato
        |
        v
Runner esegue l’operazione
        |
        +-- progress --> Agent valida e, se utile, committa
        |
        +-- Result ----> Runner termina; Agent valida, applica merge e committa
        |
        +-- crash -----> monitor DOWN verso Agent
```

Il Runner non deve essere riavviato automaticamente con uno snapshot vecchio.
È l’Agent che, dopo aver letto lo stato canonico, decide se creare un nuovo
tentativo.

La configurazione raccomandata è un Runner temporaneo sotto supervisione
dinamica, monitorato dall’Agent. Il monitor è osservazione unidirezionale: il
crash del Runner non deve propagarsi come crash dell’Agent. Il nome dei moduli,
la strategia esatta del supervisor e il tipo di child spec sono **da
progettare**.

### Crash e ripresa

Quando un Runner termina inaspettatamente:

1. l’Agent riceve il segnale di monitor;
2. stato Work, stato Vigil o stato Mission restano intatti;
3. l’Agent registra il tentativo fallito;
4. invalida l’epoch o il token del tentativo precedente;
5. scarta eventuali Result tardivi;
6. verifica retry, budget e natura dell’operazione;
7. avvia un nuovo Runner dall’ultimo checkpoint oppure produce un esito
   terminale tipizzato.

Se è l’Agent a ripartire, i Runner precedenti devono essere terminati dalla
supervisione oppure resi incapaci di committare tramite un nuovo epoch.

### Side effect ambiguo

Il crash di un Runner non dimostra che un side effect non sia avvenuto.

Ogni operazione esterna deve dichiarare se è:

- idempotente e ritentabile;
- riconciliabile tramite receipt o lettura dello stato esterno;
- non idempotente e potenzialmente ambigua.

Prima di ritentare, l’Agent usa:

- idempotency key;
- receipt già committed;
- funzione di riconciliazione, quando disponibile;
- policy esplicita per il caso sconosciuto.

Un’operazione non idempotente con esito sconosciuto non viene ripetuta
automaticamente e non viene registrata come successo. Il Work entra in attesa
di riconciliazione oppure termina con un esito tipizzato coerente con la
policy.

### Durata del Runner

Per `0.2.0` vale una regola unica: **un Runner esegue una sola operazione e un
solo tentativo operativo**.

Il Runner:

1. nasce da uno snapshot revisionato;
2. esegue l’Effect, l’Invocation o il calcolo ammesso per quell’operazione;
3. può emettere progress correlato;
4. restituisce un solo Result conclusivo del tentativo oppure termina con un
   crash;
5. termina dopo il Result.

La transizione viene committata dall’Agent. Se il loop deve continuare,
l’Agent crea un nuovo snapshot, un nuovo tentativo e un nuovo Runner.

Il Runner può mantenere processi o risorse interne soltanto per la durata
dell’operazione corrente. Non viene riusato per l’operazione successiva e non
mantiene authority dopo che il tentativo è stato invalidato.

Quando un loop aspetta:

- una decisione umana;
- un timer lungo;
- un evento futuro;
- una finestra di retry;

il Runner termina. Lo stato di attesa resta nell’Agent e un nuovo Runner
viene creato quando arriva il trigger.

Questo modello si applica in modo diverso alle tre semantiche:

- **Work**: il Runner esegue il passaggio operativo corrente;
- **Vigil**: un trigger crea il Runner per una singola osservazione; un
  eventuale confronto cognitivo usa un secondo tentativo Runner, poi la Vigil
  torna in attesa senza processo dedicato;
- **Directive**: il Runner esegue un passaggio di charting, pianificazione,
  riconciliazione o revisione della MissionMap; i Work avviati dalla Mission
  hanno Runner indipendenti.

### Progress e backpressure

Il Runner può inviare progress osservabile, ma l’Agent deve poterlo
campionare, aggregare o limitare.

Il progress:

- non aggira le revisioni;
- non contiene chain-of-thought;
- non può saturare senza limite la mailbox;
- non sostituisce il Result terminale dell’operazione;
- diventa committed soltanto se l’Agent decide di registrarlo.

### Controllo condiviso dei loop

Pausa, aggiornamento, ripresa e stop appartengono al runtime operativo Spectre,
non a un Runner e non a una singola integrazione di chat.

Nel testo “comando di controllo” indica un messaggio interno correlato. Non
introduce una macro, un handler o un verbo DSL chiamato `command`; la forma
pubblica resta **da progettare**.

Questa capacità è una conseguenza diretta dell’architettura scelta: lo stato
canonico è nell’Agent, mentre il Runner possiede soltanto uno snapshot. Per
aggiornare un loop non serve trasferire lo stato da un processo esecutore a un
altro; l’Agent ferma l’avanzamento, committa il nuovo contesto e crea il Runner
successivo dallo snapshot aggiornato.

Ogni controller Work, Vigil o Directive deve dichiarare al runtime:

- quali parti del proprio contesto sono aggiornabili;
- schema e validazione degli aggiornamenti;
- reducer deterministico che li applica;
- quali dati committed diventano superati o devono essere ricalcolati;
- punto sicuro dal quale riprendere;
- comportamento dei Runner e dei trigger durante la pausa;
- condizioni nelle quali l’aggiornamento deve essere rifiutato.

Il lifecycle condiviso è:

```text
attivo
  |
  v
richiesta di pausa committed
  |
  v
confine sicuro oppure fencing del tentativo
  |
  v
in pausa, senza nuovi Runner
  |
  v
aggiornamenti validati e committed
  |
  +-- resta in pausa
  |
  +-- ripresa --> nuovo snapshot --> nuovo tentativo --> nuovo Runner
```

Dal momento in cui la richiesta di pausa è committed, lo scheduler non può
avviare un nuovo Runner per quel loop. Nel comportamento al confine sicuro il
Result del tentativo già attivo può essere validato e committato prima della
pausa; nell’interruzione immediata la generazione di controllo e il fencing
vengono invalidati e il Result tardivo non può mutare il loop.

Una richiesta può contenere soltanto la pausa, soltanto un aggiornamento o
l’intenzione completa di aggiornare e continuare. Il runtime può tradurre
quest’ultima in più transizioni, ma conserva una correlazione durevole che
permette di completare la sequenza in modo idempotente dopo un restart.

L’Agent risolve sempre:

- loop destinatario;
- Subject e origine autorizzati;
- revisione sulla quale si basa la richiesta;
- provenienza delle nuove informazioni;
- stato finale desiderato: ancora in pausa oppure nuovamente attivo.

Se più loop sono compatibili con una frase come «usa anche questi link», il
Flow deve chiedere quale aggiornare. Il modello non sceglie per supposizione.

Un loop terminale non può tornare attivo tramite ripresa. La continuazione da
uno stato terminale, quando ammessa, crea una nuova istanza correlata e conserva
la provenienza della precedente.

## 8. Intelligenza dei loop con Prism

L’utente deve poter scegliere il livello di intelligenza del singolo Work.
La stessa infrastruttura può applicare vincoli distinti a una Vigil o a una
Mission Directive.

Questa scelta non deve:

- cambiare il modello globale dell’Agent;
- cambiare gli altri loop;
- cambiare il modello usato dal Turn che legge lo stato;
- fissare direttamente un provider o model ID;
- superare privacy, costo o policy.

Ogni loop conserva i propri vincoli cognitivi.

Prism seleziona il profilo effettivo per ogni inferenza.

Esempio di comportamento:

```text
Work richiesto con livello deep
        |
        v
vincoli Prism del Work
        |
        v
inferenza del ciclo corrente
        |
        v
profilo compatibile scelto da Prism
```

La chat può usare un profilo veloce per rispondere «come procede?» mentre il
Work continua con un profilo deep.

Un cambio richiesto durante l’esecuzione vale soltanto per le inferenze non
ancora iniziate.

La sintassi con cui il Flow o l’host assegna questi vincoli è **da progettare**.

---

## 9. Eventi e interscambi

### Ruolo degli eventi

Flow, Work, Vigil e Directive non devono chiamarsi direttamente in modo
reentrante.

Vivono nello stesso Agent, ma avanzano attraverso la mailbox e transizioni
serializzate. Possono ricevere snapshot autorizzati dello stato; nessun Runner
esterno può mutare direttamente lo stato canonico.

Gli interscambi interni usano:

- comandi correlati;
- timer;
- Result di Effect e Invocation;
- progress e segnali di terminazione dei Runner;
- eventi committed;
- viste read-only;
- riferimenti stabili ai loop.

Non è richiesto un event bus distribuito per far comunicare strutture dello
stesso Agent. Pulse entra in gioco soltanto quando l’interscambio attraversa
Agent diversi.

Le categorie semantiche minime sono:

- avvio;
- progresso;
- informazione trovata;
- artifact prodotto;
- attesa;
- richiesta di pausa;
- pausa raggiunta;
- aggiornamento applicato o rifiutato;
- ripresa;
- stop o cancellazione terminale;
- completamento;
- fallimento;
- crash del tentativo;
- evento applicativo.

Queste sono categorie, non nomi di atom o struct già approvati.

### Significato di committed

Dentro un Agent, un cambiamento è committed quando:

1. l’Agent GenServer ha validato la revisione di partenza;
2. ha accettato la transizione o il merge;
3. ha aggiornato lo stato canonico;
4. ha assegnato la nuova revisione;
5. ha registrato journal e checkpoint secondo la policy di persistenza.

`Committed` non significa automaticamente consegnato a una persona o a un
altro Agent. Consegna e applicazione remota sono stati successivi.

### Contenuto minimo di un evento

Ogni evento deve contenere:

- identificatore dell’evento;
- identificatore stabile dell’Agent;
- tipo e identificatore del loop sorgente;
- revisione;
- correlazione;
- causazione;
- tipo;
- timestamp;
- provenance;
- payload tipizzato o riferimento a un artifact.

La forma esatta dell’envelope è **da progettare**.

Progress, Result e segnale di crash del Runner non sono automaticamente eventi
pubblici. Sono messaggi del runtime che devono essere correlati almeno a loop,
tentativo, epoch e revisione. Soltanto l’Agent può trasformarli in stato o
eventi committed.

### Dal Flow ai loop operativi

Un Flow deve poter chiedere al runtime:

- avvia questo Work con questo input;
- registra questa Vigil;
- avvia o continua questa Mission Directive;
- mostrami lo stato dei loop visibili al Subject e all’origine autorizzata;
- metti in pausa al confine sicuro oppure interrompi il tentativo, quando
  autorizzato;
- aggiungi questa informazione con la sua provenienza;
- aggiorna questi campi dichiarati dal controller;
- riprendi e usa il nuovo contesto committed;
- applica in sequenza aggiornamento e ripresa;
- ferma in modo terminale;
- modifica i vincoli cognitivi futuri.

Il Flow non riceve necessariamente il riferimento in una variabile DSL.

Il runtime registra:

- loop creato;
- Agent Instance proprietaria dello stato canonico;
- Turn/Source di origine;
- Subject;
- scope di visibilità;
- correlazione;
- comando di controllo pendente e stato finale desiderato, quando presenti;
- policy;
- destinatari autorizzati.

### Dai loop al Flow

Work, Vigil e Directive possono pubblicare:

- un aggiornamento;
- un finding;
- un artifact;
- un blocker o una necessità di informazione tipizzata;
- un risultato terminale;
- un evento applicativo importante.

L’Agent può:

- attivare un normale Flow;
- aggiornare soltanto la vista pubblica;
- consegnare il risultato al loop Directive che lo attende;
- consegnare l’evento a un host subscriber;
- non produrre alcun messaggio umano.

### Notifica solo se importante

Work, Vigil e Directive non devono inviare direttamente testo su Telegram,
WhatsApp o altri canali.

Il loop:

1. aggiorna il proprio stato;
2. applica la regola dichiarata per classificare l’importanza;
3. se la regola usa cognizione, limita gli esiti e committa il risultato
   tipizzato prima di proseguire;
4. committa stato ed eventuale evento;
5. continua o termina.

L’importanza non concede da sola il permesso di contattare una persona.

Prima della consegna, una policy deterministica deve verificare:

- consenso preventivo e revocabile;
- Subject e origine autorizzati;
- destinazione e canale consentiti;
- scadenza del consenso;
- deduplicazione;
- rate limit;
- quiet hours;
- eventuale aggregazione o digest;
- receipt e audit della consegna.

Soltanto dopo, un Flow autorizzato:

1. riceve l’evento;
2. prepara il testo;
3. usa il destinatario autorizzato dalla policy;
4. usa Beam per la consegna.

Se il cambiamento non è importante:

- nessun Flow di notifica viene attivato;
- il loop può continuare;
- i risultati committed restano leggibili quando l’utente li chiede.

---

## 10. Persistenza e concorrenza

### Un solo proprietario runtime

L’Agent GenServer è l’unico proprietario dello stato canonico locale.

Lo stato resta diviso per significato:

| Sezione | Semantica |
|---|---|
| conversazione, Run e Turn | Flow e runtime conversazionale |
| istanze Work | operazioni precise e loro checkpoint |
| istanze Vigil | sorveglianze, trigger e osservazioni |
| loop Directive | payload Mission definito da `spectre_directive` |
| controllo dei loop | pausa, aggiornamenti, ripresa, stop e stato desiderato |
| journal, correlazioni e revisioni | ordinamento e ripresa dell’Agent |
| Mnemonic | memoria recuperabile esterna allo stato operativo |

La separazione è logica e tipizzata, non una moltiplicazione obbligatoria di
processi o proprietari.

Il core conserva il payload Directive senza dover comprendere MissionMap,
Waypoint, Fog o Question. La libreria possiede la loro semantica; l’Agent
possiede commit, ordinamento e checkpoint.

Un backend può fisicamente suddividere tabelle o record, ma non può introdurre
due writer concorrenti per lo stesso stato dell’Agent.

### Snapshot e copie

Quando Flow, Work, Vigil, Directive o un Runner devono operare su uno stato,
l’Agent può fornire uno snapshot immutabile contenente:

- revisione di partenza;
- revisione del contesto effettivo e generazione di controllo;
- porzione di stato autorizzata;
- riferimenti logici necessari;
- limiti delle modifiche eventualmente ammesse.

La copia può essere:

- **senza merge**: serve soltanto come contesto e produce un risultato,
  artifact o evento;
- **con merge**: può restituire una modifica proposta allo stato canonico.

Non è necessario copiare materialmente tutto lo stato dell’Agent. La semantica
è quella di uno snapshot; l’implementazione può proiettare soltanto i dati
necessari.

### Merge semplificato

Il merge segue un modello simile a un branch Git, ma limitato allo stato
tipizzato dell’Agent:

```text
stato revisione 12
      |
      | snapshot
      v
operazione asincrona
      |
      | Result + modifica proposta
      v
Agent valida la revisione e applica
      |
      v
stato revisione 13
```

Le regole minime sono:

- una modifica senza merge non cambia lo stato originale;
- lo stato locale di ciascun loop viene aggiornato soltanto dalle sue
  transizioni correlate;
- modifiche su porzioni indipendenti possono essere applicate;
- una modifica basata su dati diventati incompatibili viene rifiutata o
  ricalcolata;
- un risultato vecchio non sostituisce mai l’intero stato più recente;
- il modello non risolve conflitti strutturali per supposizione;
- ogni merge accettato produce una nuova revisione.

La rappresentazione esatta delle modifiche e l’algoritmo di conflitto sono **da
progettare**.

### Checkpoint dei loop operativi

Il checkpoint comune deve contenere soltanto dati portabili:

- tipo di loop e controller;
- versione della relativa definizione;
- input di base normalizzato;
- aggiornamenti committed con correlazione e provenienza;
- revisione del contesto effettivo;
- stato operativo tipizzato;
- posizione nel ciclo, stato di pausa o stato di attesa;
- comando di controllo pendente e stato finale desiderato;
- invalidazioni prodotte dagli aggiornamenti;
- trigger, timer e loro generazione rilevante;
- riferimenti logici;
- risultati committed necessari;
- artifact reference;
- revisioni;
- receipt e idempotency key necessarie alla ripresa;
- contatore dei tentativi e fencing necessario;
- budget consumato;
- vincoli cognitivi.

Non deve contenere:

- PID;
- Port;
- reference;
- funzioni anonime;
- client;
- connessioni;
- token;
- processi Lens;
- modello o provider client;
- PID o stato interno del Runner attivo.

Il payload Mission può essere presente nel checkpoint del loop Directive, ma
resta opaco al core e versionato da `spectre_directive`.

### Responsività

L’Agent Instance attuale mantiene più Run, ma in Spectre 0.1.5 le normali
inferenze restano sincrone dentro il Move worker.

Per supportare Work, Vigil e Directive serve:

- mantenere il loro stato dentro l’Agent;
- eseguire operazioni lente in Runner supervisionati;
- fare nel GenServer soltanto transizioni e commit brevi;
- applicare fairness tra Turn e loop operativi;
- correlare ogni Result allo snapshot e al loop corretti;
- scartare Result vecchi o duplicati;
- ricevere e gestire i segnali di crash dei Runner;
- applicare backpressure ai progress;
- accettare e committare rapidamente richieste di pausa o aggiornamento;
- permettere letture rapide delle viste committed.

Un’operazione lenta non deve bloccare:

- un nuovo Turn;
- la lettura dello stato;
- la richiesta di pausa, aggiornamento o ripresa di un loop;
- un altro loop;
- la ricezione di eventi.

---

## 11. Directive come Wayfinder

### Punto di partenza reale

Directive oggi possiede già Mission, piano, step, reasoner, request,
invocation, patch e outcome.

Esistono già, oggi:

- request correlate tramite Mission id e Request id;
- la decisione `{:ask, question}` nel protocollo del reasoner;
- la decisione `{:blocked, reason}`, convertita dal runtime Directive in un
  confine di domanda;
- plan patch atomiche e versionate;
- Store snapshot con Mission, piano, request pendente, informazioni, trace e
  outcome;
- una sessione durevole collegabile a una conversazione Spectre.

Questi elementi sono la base reale da evolvere. Non significano che esistano
già Waypoint, MissionMap, integrazione con il runtime operativo Spectre o Question
parallele.

Nel target vNext Directive non deve creare un secondo scheduler dentro
Spectre. Il suo reducer e il suo mission loop diventano un controller
eseguibile dal runtime operativo Spectre.

La distinzione resta semantica:

| Loop | Chi sceglie il prossimo avanzamento |
|---|---|
| Work | la procedura dichiarata dalla Work Definition |
| Vigil | timer o eventi ammessi dalla Vigil Definition |
| Directive | il mission planner orientato alla Destination |

Il runtime operativo Spectre impone lifecycle, policy, Effect, Invocation,
budget, checkpoint e controllo. `spectre_directive` mantiene la libertà di
creare o rivedere Waypoint e MissionMap.

Quando la Mission deve ragionare o aggiornare la mappa, l’Agent avvia un Runner
Directive con uno snapshot del payload Mission. Il Runner restituisce una
modifica proposta; soltanto l’Agent può committarla. Se il Runner crasha,
MissionMap, Waypoint e Question restano nello stato canonico e il passaggio può
essere ritentato secondo policy.

Quando Directive aspetta una risposta umana o il completamento di un Work, non
serve mantenere un Runner vivo.

Il runtime OTP e lo Store standalone esistenti possono restare disponibili per
chi usa `spectre_directive` senza un Agent Spectre. Nell’integrazione vNext non
diventano un secondo proprietario dello stato dell’Agent.

### Quando usare Directive

Directive serve quando:

- esiste una destinazione;
- il percorso non è noto;
- ci sono decisioni dipendenti;
- serve ricerca;
- servono prototipi;
- serve dialogo;
- il lavoro supera una singola sessione;
- nuovi fatti possono cambiare la mappa.

Esempio:

> Arrivare a una specifica costruibile per una nuova funzione, anche se non
> sappiamo ancora quali ricerche, decisioni e prototipi saranno necessari.

Questo è diverso da:

> Leggere tutte le pagine finché non esiste più una pagina successiva.

Il primo è una Mission Directive.

Il secondo è un Work.

### La Mission nasce normalmente in chat

Una Mission non deve richiedere che la sua mappa sia già scritta nel codice.
La forma normale è:

1. la persona esprime in un Flow una richiesta ancora nebbiosa;
2. il Flow avvia il loop Mission controllato da Directive sul runtime
   operativo dell’Agent;
3. Directive avvia il charting con domande atomiche;
4. persona e Directive concordano una destination verificabile;
5. l’Agent committa la prima MissionMap prodotta da Directive e propone i
   Waypoint già visibili;
6. dopo la conferma richiesta dalla modalità della Mission, i Waypoint
   affrontabili entrano nella frontier;
7. la chat torna libera mentre ricerca e prototipi procedono altrove.

Una definizione autorata nel codice resta utile come template per Mission
ricorrenti, non è la forma obbligatoria di ogni Mission.

### Vocabolario Wayfinder

La Mission Directive deve evolvere per possedere:

| Concetto | Significato |
|---|---|
| **Destination** | condizione verificabile che descrive l’arrivo |
| **MissionMap** | stato durevole e versionato di Waypoint, dipendenze e risoluzioni |
| **Waypoint** | una decisione, ricerca, prova o azione delimitata che riduce la nebbia |
| **Frontier** | Waypoint affrontabili adesso, calcolati dalle dipendenze |
| **Fog** | Waypoint o decisioni ancora bloccati |
| **Question** | richiesta atomica e correlata di una decisione umana |
| **Resolution** | esito committed di un Waypoint, con evidenze e fonti |
| **Outcome** | esito terminale della Mission |
| **History** | successione versionata dei cambiamenti della MissionMap |

Il termine `Route` non viene usato per la MissionMap, perché nel core
`Spectre.Route` appartiene già al routing dei Flow.

Il materiale Wayfinder originale chiama queste unità “ticket”. Nel vocabolario
Spectre diventano Waypoint: evita la semantica da issue tracker e non collide
con i tipi operativi del core.

### Destination, Frontier e fonti verificabili

La Destination deve dichiarare un contratto versionato di soddisfazione. La
verifica può dipendere da:

- una condizione deterministica sulle Resolution e sugli Artifact committed;
- un’accettazione umana esplicita, correlata tramite Question;
- una combinazione dichiarata delle due.

Una valutazione cognitiva può proporre evidenze o produrre un esito tipizzato,
ma non può dichiarare unilateralmente conclusa la Mission fuori dal contratto
di soddisfazione.

La Frontier è una proiezione derivata deterministicamente da:

- MissionMap committed;
- stato e dipendenze dei Waypoint;
- Resolution disponibili;
- policy e vincoli dichiarati.

Il planner può proporre nuovi Waypoint, dipendenze o modifiche della mappa.
Dopo il commit, però, non “indovina” quali Waypoint siano affrontabili: lo
calcola un reducer deterministico. Una cache della Frontier è valida soltanto
insieme alla revisione della MissionMap da cui è stata derivata.

Ogni presa in carico di un Waypoint deve inoltre conservare un riferimento
stabile alla sua esecuzione: sessione, Work, persona, Agent o sistema esterno.
Il nome e la rappresentazione pubblica di questo riferimento sono **da
progettare**; non costituisce un nuovo tipo Session nel core.

Ogni Resolution deve collegare:

- il Waypoint;
- il riferimento di esecuzione che l’ha prodotta;
- evidenze e Artifact pertinenti;
- la fonte primaria, quando esiste;
- la revisione della MissionMap sulla quale è stata applicata.

La sintesi nella MissionMap non sostituisce la fonte primaria.

### Tipi di Waypoint

I quattro tipi iniziali sono:

| Tipo | Responsabilità | Esecutore tipico |
|---|---|---|
| Research | trovare informazioni o evidenze | un Work preciso |
| Prototype | produrre un Artifact concreto per ottenere feedback | un Work preciso |
| Dialogue | prendere una decisione che appartiene alla persona | Question e Flow |
| Errand | compiere un’azione tecnica, organizzativa o nel mondo reale | persona, host o Work schedulato |

Questi Waypoint non sono Work figli.

Un Waypoint può essere affidato a:

- una sessione;
- una persona;
- un Agent;
- un Work preciso;
- un sistema esterno.

Se la procedura di una ricerca non è abbastanza precisa per scegliere una Work
Definition, Directive non crea un “Work che prova”. Il Waypoint resta da
chiarire, viene scomposto oppure apre un Dialogue.

### Question

Question è stato di dominio di `spectre_directive`, non un nuovo significato
inventato per un tipo del core.

Una Question deve contenere almeno, a livello concettuale:

- identità stabile;
- Mission e Waypoint di appartenenza;
- testo o payload strutturato;
- tipo di risposta attesa;
- stato;
- correlazione con la consegna e con la risposta;
- policy di notifica;
- data di creazione e, quando risolta, Resolution collegata.

Una Question può nascere:

1. nel charting iniziale;
2. quando un Waypoint Dialogue entra nella frontier;
3. quando un Work emette un blocker tipizzato;
4. quando nuove risoluzioni si contraddicono o richiedono di rinegoziare la
   destination.

La consegna attraversa un Flow o un adapter di canale autorizzato. La Question
non possiede la chat e il Work non risponde direttamente alla persona.

La risposta deve sempre tornare alla Question esatta tramite una correlazione
committed. Se esiste una sola Question presentata e non ambigua, una risposta
breve può risolverla. Se più Question sono aperte, il Flow le presenta con
identità distinguibili e chiede una scelta esplicita; un “sì” isolato non viene
assegnato per supposizione.

Le Question non bloccano l’intera Mission. Bloccano soltanto i Waypoint che
dipendono dalla loro Resolution; il resto della frontier continua.

Oggi Directive possiede già request correlate e `{:ask, question}`, ma emette
una request pendente per volta nel proprio loop. Il modello esatto per più
Question simultanee — coda nella Mission, sessioni per Waypoint o entrambe —
è **da progettare**.

Il confine core `{:needs, ...}` oggi rappresenta una necessità di policy. Non
viene riutilizzato in questo concept come pseudo-API generica per Question.

### Pausa e aggiornamento della Mission

Il loop Directive può essere messo in pausa, aggiornato e ripreso attraverso
lo stesso contratto del runtime operativo Spectre.

Mettere in pausa Directive significa:

- non avviare nuovi Runner Directive;
- non prendere nuovi Waypoint dalla Frontier;
- non avviare nuovi Work;
- conservare MissionMap, Question, Resolution e riferimenti ai Work;
- lasciare la Mission interrogabile dalla chat.

La vista della Mission deve mostrare stato di controllo, revisione del
contesto, ultimo aggiornamento, eventuale ricalcolo pendente e quali Work
collegati stanno continuando oppure sono stati messi in pausa separatamente.

I Work già avviati dalla Mission sono indipendenti. La pausa di Directive non
li mette automaticamente in pausa. La persona o una policy esplicita può
chiedere all’Agent di inviare comandi separati ai Work collegati; ogni Work
mantiene il proprio checkpoint, fencing e lifecycle.

Anche lo stop terminale della Mission non dichiara automaticamente cancellati
i Work già avviati. L’Agent deve applicare una policy esplicita oppure chiedere
alla persona se fermarli separatamente.

Le nuove informazioni possono essere:

- evidenze o fonti;
- vincoli;
- risposte a Question;
- correzioni di fatti precedenti;
- cambiamenti delle preferenze della persona;
- modifiche proposte alla Destination.

Directive conserva l’input originale e committa ogni aggiornamento con
provenienza. Alla ripresa:

1. riconcilia Question e Work collegati;
2. avvia un nuovo Runner Directive con lo snapshot aggiornato;
3. valuta l’impatto sulle Resolution esistenti;
4. può riaprire, sostituire o creare Waypoint;
5. committa la nuova MissionMap;
6. ricalcola deterministicamente Fog e Frontier.

Cambiare la Destination non è una semplice aggiunta di contesto. Richiede una
nuova versione del contratto di soddisfazione e, quando la Mission è guidata,
una conferma umana esplicita. Le Resolution precedenti restano nella History e
vengono marcate come ancora applicabili, superate oppure da rivalutare.

Se l’informazione aggiunta riguarda direttamente un Work preciso — per esempio
nuovi URL per una ricerca già in corso — il Flow può aggiornare quel Work
senza far interpretare l’operazione a Directive. Se il destinatario non è
univoco, chiede chiarimento.

Una Mission che ha già prodotto un Outcome terminale non viene ripresa
silenziosamente. Un seguito richiede una nuova Mission correlata oppure una
riapertura esplicitamente definita dalla policy futura; la scelta pubblica è
**da progettare**.

La modalità standalone di `spectre_directive` deve conservare la stessa
semantica di stato per pausa, aggiornamento e ripresa, anche se l’API host e il
proprietario del commit non sono l’Agent Spectre.

### Blocker Work verso Question Directive

La catena corretta è:

```text
Work preciso
  -> checkpoint committed
  -> evento blocker tipizzato
  -> stato ed evento interni dell’Agent
  -> Question Directive
  -> risposta umana correlata
  -> Resolution
  -> risposta al Work oppure ricalcolo della MissionMap
```

Se il loop Directive non sta avanzando in quel momento, l’evento e lo stato
del Work restano committed nello stesso Agent. Alla transizione successiva
Directive li può leggere senza riconciliare due proprietari o dipendere da una
consegna effimera.

Se la risposta seleziona un ramo già dichiarato nella Work Definition, lo
stesso Work può riprendere. Se richiede una procedura nuova, Directive aggiorna
la MissionMap e sceglie un nuovo Waypoint o un altro Work.

Un blocker non è un completamento riuscito del Work.

### Lifecycle della Mission

```text
charting e destination concordata
        |
        v
committa la prima MissionMap
        |
        v
riconcilia Question e Work collegati
        |
        v
calcola fog e frontier
        |
        v
prende uno o più Waypoint
        |
        v
research / prototype / dialogue / errand
        |
        v
salva Resolution con evidenze e fonti
        |
        v
aggiorna MissionMap, dipendenze, fog e frontier
        |
        +-- destination non soddisfatta --> continua
        |
        +-- destination soddisfatta -----> Outcome
```

La lista iniziale dei Waypoint non è un piano immutabile.

Una Resolution può:

- sbloccare Waypoint;
- crearne di nuovi;
- rendere inutili Waypoint esistenti;
- riaprire una decisione;
- cambiare la frontier.

L’Outcome può essere derivato dalle Resolution per la presentazione, ma il
receipt terminale deve restare nello stato del loop Directive per audit,
idempotenza, replay e recupero. Il runtime operativo Spectre lo include nel
checkpoint dell’Agent; lo Store Directive standalone continua a farlo quando
la libreria viene usata senza Spectre.

### Valutazione dei Prototype

Un Waypoint Prototype produce un Artifact. L’esistenza dell’Artifact non
costituisce automaticamente una Resolution.

Per impostazione predefinita, un prototipo che richiede gusto, ergonomia o una
scelta di prodotto apre un Waypoint Dialogue di valutazione. Può chiudersi
senza dialogo soltanto quando la MissionMap dichiara un criterio di accettazione
deterministico e l’Artifact lo soddisfa.

### Tracker

Directive deve restare issue-tracker agnostic.

Adapter possibili:

- GitHub Issues;
- Linear;
- Jira;
- PostgreSQL;
- filesystem;
- adapter applicativo.

L’item padre rappresenta la MissionMap.

I sotto-item rappresentano i Waypoint.

La Resolution completa resta collegata al Waypoint. Una sintesi con link alla
fonte primaria viene proiettata nella MissionMap.

Il tracker è una proiezione o uno Store adapter: non diventa il runtime della
Mission.

### Integrazione con Work

Quando un Waypoint richiede un’operazione precisa:

```text
Agent / runtime operativo Spectre
      |
      +-- loop Directive -> Runner Directive -> Waypoint
      |
      +-- Work indipendente -> Runner Work
              |
              +-- Result e artifact committed
                          |
                          v
                 loop Directive -> Resolution
```

Directive conserva nel Waypoint il riferimento stabile al Work avviato.

Il collegamento conserva anche almeno:

- ultima revisione Work osservata;
- ultimo risultato o evento terminale applicato;
- stato della riconciliazione;
- riferimento di esecuzione da riportare nella Resolution.

La rappresentazione concreta resta **da progettare**.

Il Work non conserva il riferimento alla Mission e non deve sapere di essere
stato avviato da Directive.

Il completamento del Work:

- alimenta o risolve il Waypoint secondo una regola Directive;
- non completa automaticamente la Mission;
- non sostituisce il calcolo di MissionMap, fog e frontier.

L’evento di completamento del Work è un segnale di risveglio, non l’unica
fonte di verità. Prima di pianificare una nuova transizione, e sempre dopo
restart, resume o crash del Runner Directive, il controller:

1. legge dallo stato canonico dell’Agent le viste committed dei Work collegati;
2. confronta revisione e risultato con ciò che il Waypoint ha già osservato;
3. applica soltanto risultati non ancora acquisiti;
4. crea o aggiorna la Resolution in modo idempotente;
5. committa la nuova MissionMap prima di avanzare.

Se un Work termina mentre Directive è in attesa, in pausa o priva di un Runner
attivo, il risultato non viene perso: resta nello stesso Agent e viene
riconciliato alla prossima transizione Directive.

Quando `spectre_directive` viene usata in modalità standalone e deve coordinare
un Work posseduto da un Agent Spectre esterno, l’adapter deve offrire lettura
durevole e riconciliazione per riferimento stabile. Una consegna effimera non
è sufficiente. La forma di questo adapter è **da progettare**.

L’attuale decisione Directive `{:invoke, target}` esegue una funzione, un
modulo o un MFA autorizzato. Non è già un lancio Work. L’adapter con cui il
controller Directive richiede al runtime operativo Spectre di creare un Work
è **da progettare**.

Questa facoltà non viola la regola “un Work non crea Work”: una Mission
Directive non è semanticamente una Work Definition, anche se usa lo stesso
runtime.

### Confini di Directive

Directive possiede:

- Mission;
- Destination;
- MissionMap;
- Fog;
- Frontier;
- Waypoint;
- Question;
- dependency;
- Resolution;
- Outcome;
- History;
- input Mission e aggiornamenti con provenienza;
- regole con cui nuove informazioni rivalutano Map, Waypoint e Resolution;
- schema e transizioni dello stato Mission;
- Store standalone opzionale.

Directive non possiede:

- Flow runtime;
- Work Definition;
- stato operativo dei Work avviati;
- ordinamento e commit dell’Agent;
- Lens;
- Kinetic;
- memoria Mnemonic;
- Pulse transport;
- Beam delivery;
- policy e lifecycle Effect Spectre.

Nell’integrazione vNext, Directive riusa:

- runtime operativo Spectre;
- checkpoint dei loop;
- Effect e Invocation;
- pausa, aggiornamento, ripresa, stop, budget e osservabilità;
- eventi interni dell’Agent.

La semantica di un eventuale handoff tra sessioni, persone o Agent è **da
progettare** e non viene presentata come concetto già posseduto.

L’esatta nuova DSL Wayfinder dentro `spectre_directive` è **da progettare**.

Il concept non introduce macro nuove per Destination, MissionMap, Waypoint o
Question.

---

## 12. Ruolo finale delle librerie

| Libreria | Ruolo |
|---|---|
| `spectre` | Agent, Stack, Skill, Flow, State, Run, Turn, Effect, Invocation, Instance, runtime operativo, supervisione Runner, controllo dei loop, Work e Vigil |
| `spectre_prism` | selezione del profilo cognitivo |
| `spectre_kinetic` | pianificazione di operazioni registrate, senza esecuzione |
| `spectre_lens` | browser, percezione e operazioni web |
| `spectre_mnemonic` | memoria recuperabile, non stato live del Work |
| `spectre_directive` | controller goal-driven per Mission, MissionMap, fog, frontier, Waypoint e Question, eseguibile sul runtime operativo Spectre |
| `spectre_pulse` | envelope e trasporto tra Agent |
| `spectre_beam` | ingresso e uscita dai canali esterni |
| MCP eventuale | adapter opzionale di tool/resource, non fondazione del runtime |

### Regola di indipendenza

Ogni libreria mantiene il proprio dominio semantico e si integra attraverso i
confini pubblici di Spectre.

Esempi:

- Lens espone operazioni browser;
- Kinetic propone un’operazione;
- Prism seleziona una capacità cognitiva;
- Mnemonic ricorda dati committed;
- Directive controlla un loop goal-driven e pianifica Mission;
- Pulse trasporta envelope;
- Beam consegna messaggi;
- Spectre possiede Agent State, commit, lifecycle, policy, Effect, controllo
  dei loop e runtime operativo;
- i Runner eseguono senza possedere lo stato canonico.

Una libreria può fornire un controller al runtime operativo Spectre senza
diventare un secondo proprietario dello stato. Spectre esegue e persiste; la
libreria definisce la propria semantica.

---

## 13. Scenari obbligatori

### Scenario A — leggere tutte le pagine

1. Un messaggio entra tramite Beam.
2. Il normale Flow identifica la richiesta.
3. Il Flow chiede al runtime di avviare il Work “leggi tutte le pagine”.
4. Il Flow conferma l’avvio e termina il Turn.
5. L’Agent avvia un Runner con snapshot, revisione e tentativo.
6. Il Runner apre la prima pagina tramite Lens.
7. Legge ed estrae le informazioni.
8. Usa una funzione registrata per salvarle.
9. Restituisce Result e modifica proposta.
10. L’Agent aggiorna pagina, cursore e contatori e committa il checkpoint.
11. La funzione di termine verifica se esiste ancora paginazione.
12. Se esiste, l’Agent crea un nuovo snapshot, un nuovo tentativo e un nuovo
    Runner per la pagina successiva.
13. Se non esiste, il Work termina e pubblica l’evento terminale.
14. Un Flow può produrre il report e notificarlo.
15. Se nessun Flow è configurato per notificare, il risultato resta
    disponibile nella vista del Work.

### Scenario B — chiedere informazioni durante il Work

1. Il Work sta leggendo la pagina 7.
2. L’utente scrive «come procede?».
3. Il messaggio crea un nuovo Turn.
4. L’Agent risolve il Work visibile al Subject e all’origine autorizzata.
5. Il Turn legge la vista committed dallo stato canonico dell’Agent.
6. Il Flow risponde con pagina corrente, informazioni trovate e operazione
   attuale.
7. Il Work continua senza essere fermato.

### Scenario C — leggere log o database

1. Il Work richiede un’operazione registrata dall’applicazione.
2. L’Agent avvia il Runner del tentativo corrente.
3. Il Runner crea Effect e Invocation.
4. L’executor applicativo legge log o database.
5. Il Result torna al Runner e quindi all’Agent.
6. L’Agent aggiorna lo stato Work.
7. La funzione di termine decide se servono altre letture.

La funzione applicativa attraversa policy e idempotenza come qualsiasi altro
side effect.

### Scenario D — monitor meteo

1. L’Agent registra una Vigil sul servizio meteo.
2. Un timer dichiarato risveglia la Vigil.
3. L’Agent avvia un Runner con lo snapshot Vigil.
4. Il Runner crea l’Effect di osservazione.
5. Il Result torna all’Agent.
6. L’Agent committa previsione e stato della Vigil.
7. Il Runner di osservazione termina.
8. Se la significatività è deterministica, l’Agent applica il reducer breve.
9. Se richiede cognizione, l’Agent avvia un nuovo Runner con un dominio di
   esiti chiuso e committa il risultato validato.
10. Se il cambiamento non è importante, la Vigil torna in attesa.
11. Se è importante, pubblica un evento applicativo.
12. Nessun processo Runner resta vivo durante l’attesa.
13. La policy verifica consenso, origine, quiet hours, rate limit e
   deduplicazione.
14. Un Flow prepara il messaggio.
15. Beam lo consegna al canale autorizzato.

### Scenario E — scegliere l’intelligenza

1. L’utente avvia un Work chiedendo un livello profondo.
2. Il runtime salva il vincolo cognitivo del Work.
3. Ogni inferenza futura passa a Prism.
4. Prism seleziona un profilo compatibile con privacy, budget e capacità.
5. La vista del Work mostra richiesta, scelta effettiva e fallback.
6. Una domanda di stato può usare un profilo più veloce e indipendente.

### Scenario F — Mission Directive

1. La destination è una specifica costruibile.
2. Il Flow avvia un loop controllato da `spectre_directive` sul runtime
   operativo Spectre.
3. L’Agent avvia un Runner Directive per il charting.
4. Il Runner propone la MissionMap iniziale e l’Agent la committa.
5. Un Waypoint Research richiede la lettura paginata di alcune fonti.
6. Il controller Directive chiede allo stesso runtime di avviare un Work
   preciso e indipendente.
7. Quel Work riceve un proprio Runner.
8. Il Waypoint conserva il riferimento stabile al Work e alla sua esecuzione.
9. Il Work termina e l’Agent committa artifact, stato terminale ed evento di
   risveglio.
10. Un nuovo Runner Directive rilegge la vista committed del Work e riconcilia
    soltanto il risultato non ancora applicato.
11. Il Waypoint viene risolto con riferimento di esecuzione, evidenze e fonte
    primaria.
12. L’Agent committa la nuova MissionMap e ricalcola deterministicamente fog e
    frontier.
13. La Mission continua anche se quel Work è terminato.

### Scenario G — blocker e decisione umana

1. Un Work raggiunge un bivio previsto dalla propria definizione.
2. Committa il checkpoint ed emette un blocker tipizzato.
3. L’Agent collega l’evento al loop Directive e al Waypoint che lo attende.
4. Directive apre una Question correlata.
5. Il Flow la presenta alla persona senza fermare gli altri Work o Waypoint.
6. La risposta risolve la Question esatta.
7. Se seleziona un ramo già dichiarato, lo stesso Work riprende.
8. Se richiede una procedura nuova, Directive aggiorna la MissionMap e sceglie
   un altro Waypoint.

### Scenario H — snapshot e merge

1. Due Runner ricevono snapshot della revisione 40 su sezioni Work
   indipendenti.
2. Entrambi eseguono operazioni lente fuori dal GenServer.
3. Il primo Result modifica soltanto il proprio stato Work.
4. L’Agent applica il merge e crea la revisione 41.
5. Il secondo Result torna con base 40.
6. L’Agent verifica che la sua modifica non dipende dalla sezione cambiata.
7. Applica il merge e crea la revisione 42.
8. Se entrambi avessero modificato in modo incompatibile lo stesso dato,
   l’Agent avrebbe rifiutato o ricalcolato la seconda transizione.

### Scenario I — budget esaurito

1. Un Work raggiunge il limite dichiarato prima del completamento operativo.
2. Il runtime non avvia una nuova operazione.
3. L’Agent committa un esito terminale di budget esaurito.
4. L’esito registra limite, consumo e ultimo checkpoint.
5. Stato parziale e artifact restano interrogabili.
6. Un Flow può spiegare l’interruzione senza presentarla come completamento.

### Scenario J — crash e ripresa del Runner

1. Un Runner sta eseguendo un’operazione del Work alla revisione 18.
2. Il processo termina inaspettatamente.
3. L’Agent riceve il segnale di monitor.
4. Lo stato Work alla revisione 18 resta disponibile.
5. L’Agent invalida il tentativo e registra il crash.
6. Se l’operazione è ritentabile e il budget lo permette, avvia un nuovo
   Runner dall’ultimo checkpoint.
7. Un Result tardivo del vecchio tentativo viene scartato.
8. Se retry o budget non lo permettono, il Work termina con un esito
   tipizzato.

### Scenario K — side effect con risultato sconosciuto

1. Un Runner invia una scrittura non idempotente a un sistema esterno.
2. Il Runner crasha prima di committare il receipt.
3. L’Agent non assume che la scrittura sia fallita.
4. Se esiste una funzione di riconciliazione, avvia un Runner per verificare lo
   stato esterno.
5. Se il risultato resta sconosciuto, non ripete automaticamente
   l’operazione.
6. Il Work entra in attesa di riconciliazione oppure termina secondo la policy
   dichiarata.

### Scenario L — aggiungere link a una ricerca in corso

1. Un Work sta facendo una ricerca web e un Runner sta leggendo una fonte.
2. La persona scrive nella chat: «usa anche questi due link e continua».
3. Il Flow identifica il Work visibile al Subject e all’origine; se più Work di
   ricerca sono compatibili, chiede quale aggiornare.
4. La Work Definition conferma che la coda delle fonti è aggiornabile e valida
   gli URL.
5. L’Agent committa una richiesta correlata con pausa, aggiornamento e stato
   finale nuovamente attivo.
6. Lo scheduler impedisce l’avvio di un altro Runner.
7. Il tentativo di lettura corrente raggiunge il confine sicuro; il Result
   valido viene committato e il Work entra in pausa. Se viene richiesta
   interruzione immediata, l’Agent applica fencing e terminazione del Runner.
8. L’Agent registra i link con provenienza dal Turn, li deduplica contro fonti
   visitate e pendenti e committa una nuova revisione del contesto effettivo.
9. I risultati già raccolti restano committed; eventuali dati invalidati sono
   marcati esplicitamente.
10. La ripresa crea un nuovo snapshot, un nuovo tentativo e un nuovo Runner.
11. La funzione di termine considera anche le nuove fonti prima di dichiarare
    completata la ricerca.
12. La chat può leggere se l’aggiornamento è pendente, applicato oppure
    rifiutato senza fermare nuovamente il Work.

### Scenario M — aggiornare una Vigil

1. Una Vigil controlla il meteo ogni dieci minuti.
2. La persona chiede di controllare ogni due ore e di aggiungere una seconda
   città.
3. L’Agent committa la richiesta di pausa e impedisce nuovi Runner Vigil.
4. L’Agent lascia terminare il Runner al confine sicuro oppure lo interrompe
   con fencing, secondo la modalità richiesta.
5. Il reducer Vigil valida città e intervallo, aggiorna la configurazione e
   invalida la vecchia generazione dei timer.
6. Alla ripresa l’Agent calcola il nuovo timer e registra una nuova generazione
   dei trigger.
7. Un timer tardivo della configurazione precedente non avvia osservazioni.
8. Uno stop terminale, diversamente dalla pausa, richiederebbe la registrazione
   di una nuova Vigil per ricominciare.

### Scenario N — aggiornare una Mission Directive

1. Una Mission sta pianificando una specifica e ha collegati due Work Research
   indipendenti e attivi.
2. La persona aggiunge un nuovo vincolo di budget e chiede di rivedere la
   MissionMap.
3. L’Agent mette in pausa il loop Directive: non partono nuovi Runner
   Directive, Waypoint o Work.
4. I due Work già avviati continuano perché sono indipendenti. Se la persona
   chiede di fermare anche loro, l’Agent invia due comandi di pausa separati.
5. Il nuovo vincolo viene committed con provenienza e revisione.
6. Alla ripresa Directive riconcilia Question e Work collegati e avvia un nuovo
   Runner Directive.
7. Il controller rivaluta Resolution e Waypoint, committa una nuova MissionMap
   e ricalcola Fog e Frontier.
8. Se l’aggiornamento cambia la Destination, richiede una nuova versione del
   contratto e la conferma umana prevista dalla modalità della Mission.

---

## 14. Modifiche richieste per repository

### `spectre`

Da aggiungere:

- dominio Work separato da Run;
- Vigil come dominio core;
- runtime operativo condiviso da Work, Vigil e controller forniti da librerie
  autorizzate;
- sezioni Work, Vigil e Directive nello stato canonico dell’Agent;
- snapshot revisionati;
- modifiche proposte e merge serializzato;
- Work Definition versionata;
- Vigil Definition versionata;
- checkpoint comune dei loop;
- scheduler Agent-side;
- supervisione dinamica dei Runner;
- un Runner isolato e temporaneo per ogni tentativo operativo attivo;
- terminazione del Runner dopo il Result, senza riuso tra operazioni;
- monitor dei Runner senza propagazione del crash all’Agent;
- attempt id, epoch e fencing dei Result;
- ripresa del loop dall’ultimo checkpoint;
- backpressure e aggregazione dei progress;
- riconciliazione dei side effect ambigui;
- proiezione pubblica read-only;
- comandi durevoli e correlati di pausa, aggiornamento, ripresa e stop;
- distinzione tra pausa reversibile e stop terminale;
- pausa al confine sicuro e interruzione immediata con fencing;
- contratto dei controller per campi aggiornabili, reducer, invalidazioni e
  punto di ripresa;
- input di base, aggiornamenti con provenienza e revisione del contesto
  effettivo;
- ripresa idempotente delle sequenze di controllo dopo restart;
- generazione dei trigger Vigil per invalidare timer precedenti;
- proiezione dello stato dei comandi di controllo;
- correlazione con Agent Instance, Source e Turn di origine;
- eventi committed;
- interscambio tra eventi e routing Flow;
- uso del lifecycle Effect/Invocation esistente;
- journal dei passaggi pubblici;
- compatibilità di restart e upgrade;
- budget ed esiti terminali tipizzati;
- contratto per decisioni cognitive a dominio chiuso;
- policy di visibilità e consegna proattiva.

Da non aggiungere:

- Mission;
- destination;
- MissionMap;
- fog;
- frontier;
- Waypoint e Question Directive;
- Work figli;
- un secondo proprietario dello stato Work;
- stato canonico posseduto dal Runner;
- restart automatico del Runner con snapshot stale;
- un runtime separato per Vigil;
- pseudo matcher per gli eventi.

### `spectre_prism`

Da aggiungere:

- vincoli cognitivi associabili a Work, Vigil e loop Directive;
- selezione per ogni inferenza del loop;
- osservabilità di profilo e fallback;
- cambio valido soltanto per richieste future.

Prism non deve possedere:

- runtime operativo;
- checkpoint dei loop;
- stato conversazionale.

### `spectre_kinetic`

Da aggiungere:

- adapter per ricevere il catalogo limitato del passaggio operativo;
- risultato correlabile alla transizione del loop;
- chiara separazione tra proposta ed esecuzione.

Kinetic non deve:

- creare Work;
- creare Work figli;
- terminare Work;
- trasformare una chain in workflow implicito;
- modificare MissionMap o stato Vigil.

### `spectre_lens`

Da aggiungere:

- integrazione delle Action esistenti con il runtime operativo Spectre;
- Result correlati a Runner, tentativo e loop Work, Vigil o Directive;
- artifact portabili;
- recovery quando il runtime browser non è più disponibile.

Lens non deve possedere lo scheduler del runtime operativo.

### `spectre_mnemonic`

Da aggiungere:

- scope di loop quando esplicitamente richiesto;
- commit soltanto di risultati ammessi e già committed.

Mnemonic non deve diventare lo store canonico dell’Agent o dei loop.

### `spectre_directive`

Da aggiungere:

- modello Wayfinder;
- destination;
- MissionMap;
- fog;
- frontier;
- Waypoint;
- Question tipizzate e correlate;
- dipendenze;
- contratto versionato di soddisfazione della Destination;
- frontier derivata deterministicamente;
- riferimento stabile di esecuzione per ogni Waypoint preso in carico;
- resolution con evidenze e fonti primarie;
- charting della Mission attraverso Flow;
- controller compatibile con il runtime operativo Spectre;
- stato Mission portabile e checkpointabile dal core;
- avvio di Work indipendenti attraverso il runtime operativo Spectre;
- riconciliazione idempotente delle viste Work dopo resume o restart;
- pausa e ripresa del controller Mission;
- aggiornamenti Mission con provenienza e rivalutazione delle Resolution;
- nuova versione e conferma del contratto quando cambia la Destination;
- policy esplicita per l’eventuale pausa dei Work collegati, senza cascade
  implicita;
- gestione dei blocker Work senza falso completamento;
- tracker adapter;
- integrazione con Flow, Work e Pulse attraverso l’Agent.

Da preservare:

- reducer Mission;
- correlazione delle request;
- patch versionate;
- runtime e Store standalone come modalità opzionale;
- semantica equivalente di pausa, aggiornamento e ripresa in standalone;
- indipendenza da provider e memoria.

Da rimuovere dall’integrazione Spectre futura:

- qualsiasi pretesa di possedere checkpoint o lifecycle Work;
- qualsiasi tipo Mission nel core;
- qualsiasi modalità “Work come Mission”;
- un secondo scheduler quando è integrato in Spectre.

### `spectre_pulse`

Da aggiungere soltanto ciò che serve a trasportare eventi o richieste Work tra
Agent, mantenendo envelope e correlazione.

Pulse non deve diventare:

- Work scheduler;
- board operativo globale;
- Mission planner.

### `spectre_beam`

Da aggiungere:

- mapping sicuro tra eventi/risposte Flow e consegna proattiva autorizzata;
- idempotenza della notifica;
- rendering dello stato Work quando richiesto dal Flow;
- supporto a quiet hours, rate limit e digest definiti dalla policy
  applicativa.

Beam non decide importanza, completamento, consenso o policy dei loop.

---

## 15. Piano di implementazione verso `0.2.0`

### Obiettivo della versione

`0.2.0` deve essere la prima versione nella quale l’architettura vNext può
essere considerata stabile e congelata.

Deve includere:

- Agent GenServer come proprietario unico dello stato canonico;
- snapshot, revisione e merge;
- runtime operativo condiviso;
- Runner isolati e supervisionati;
- crash recovery e fencing per tentativo;
- Work preciso;
- Vigil nel core;
- osservabilità, pausa, aggiornamento, ripresa e stop dalla chat;
- funzioni applicative, Lens, Kinetic e Prism;
- integrazione di `spectre_directive` come controller goal-driven;
- budget ed esiti terminali tipizzati;
- visibilità e consegna proattiva governate;
- restart e compatibilità dei checkpoint.

Non è necessario includere in `0.2.0`:

- MCP;
- un tracker specifico;
- handoff remoto tra Agent;
- una DSL Wayfinder completa;
- Group;
- ottimizzazioni distribuite;
- nuove pseudo-API non validate dal compilatore.

### Regola di compatibilità con `0.1.x`

Durante la migrazione:

- `Run` non viene rinominato Work;
- `flow/on` resta riconoscibile;
- il protocollo attuale di Effect e Invocation viene riutilizzato;
- le API attuali possono essere deprecate soltanto con percorso documentato;
- il reducer e lo Store standalone di Directive restano utilizzabili;
- il nuovo runtime viene introdotto prima tramite API Elixir, poi attraverso
  una DSL minima.

### `0.2.0-alpha.1` — stato canonico dell’Agent

Implementare prima la fondazione, senza Work DSL:

1. dividere lo State dell’Agent in sezioni tipizzate;
2. introdurre una revisione monotona;
3. definire snapshot autorizzati;
4. definire modifiche senza merge e con merge;
5. impedire la sostituzione dello stato tramite Result vecchi;
6. aggiungere journal delle transizioni;
7. definire il formato portabile del checkpoint Agent.

Criteri di uscita:

- due operazioni su sezioni indipendenti possono terminare in ordine diverso;
- una modifica stale incompatibile viene rifiutata;
- una copia senza merge non modifica lo stato originale;
- restart e restore mantengono revisione e correlazioni.

### `0.2.0-alpha.2` — runtime operativo, Runner e Work

Costruire il runtime operativo Spectre:

1. lifecycle di un loop operativo;
2. scheduler interno all’Agent;
3. supervisione dinamica dei Runner;
4. Runner temporaneo per ogni tentativo operativo attivo;
5. una sola operazione e un solo Result conclusivo per Runner;
6. terminazione del Runner dopo Result o crash;
7. monitor dei Runner da parte dell’Agent;
8. attempt id, epoch e fencing;
9. correlazione di progress, Result, timer ed eventi;
10. backpressure dei progress;
11. crash recovery dall’ultimo checkpoint;
12. classificazione di side effect idempotenti, riconciliabili o ambigui;
13. richieste durevoli e correlate di controllo;
14. pausa al confine sicuro e interruzione immediata;
15. distinzione tra pausa reversibile e stop terminale;
16. registro degli aggiornamenti con provenienza e revisione del contesto
    effettivo;
17. contratto controller per validazione, reducer, invalidazione e punto di
    ripresa;
18. sequenza idempotente pausa, aggiornamento e ripresa;
19. checkpoint e ripresa anche con un comando di controllo pendente;
20. budget e categorie terminali;
21. Work Definition versionata;
22. rami chiusi;
23. blocker e ripresa;
24. API Elixir per avvio, ispezione e controllo.

Criteri di uscita:

- un Work paginato completa tutte le pagine;
- un Effect lento non blocca un nuovo Turn;
- un Result duplicato o stale non viene applicato;
- il crash di un Runner non fa crashare l’Agent;
- dopo un Result il Runner termina e l’operazione successiva riceve un nuovo
  snapshot, tentativo e Runner;
- il Work viene ripreso con un nuovo tentativo;
- un Result del tentativo precedente viene scartato;
- un side effect ambiguo non viene ritentato automaticamente;
- un Work riparte dallo stesso checkpoint;
- una pausa impedisce nuovi Runner ma conserva la possibilità di ripresa;
- uno stop terminale non viene ripreso;
- nuove informazioni valide modificano soltanto i campi dichiarati dalla
  Work Definition;
- dopo un aggiornamento il nuovo Runner vede il contesto revisionato e un
  Result basato sul vecchio contesto viene rifiutato;
- un restart a metà di pausa, aggiornamento e ripresa completa la sequenza una
  sola volta;
- il budget esaurito produce un esito terminale interrogabile;
- un normale Work non può creare altri Work.

### `0.2.0-alpha.3` — Flow, vista e dataflow

Integrare il runtime con la conversazione:

1. eventi interni come input normali del routing;
2. vista pubblica di Work;
3. query di progresso durante l’esecuzione;
4. disambiguazione tra più Work;
5. Subject, origine e scope di visibilità;
6. comprensione delle intenzioni naturali di pausa, aggiornamento, ripresa e
   stop;
7. correlazione del comando al loop corretto senza variabili DSL obbligatorie;
8. cambio dei vincoli cognitivi futuri;
9. dataflow compilabile senza variabili usa-e-getta obbligatorie;
10. sintassi DSL minima soltanto dopo la stabilità delle API Elixir.

Criteri di uscita:

- «come procede?» non ferma il Work;
- due Work ambigui producono una richiesta di chiarimento;
- «usa anche questi link e continua» aggiorna il Work corretto attraverso
  transizioni committed;
- la risposta distingue richiesta di pausa, pausa raggiunta e aggiornamento
  applicato;
- un canale vede soltanto i Work autorizzati;
- due risultati omonimi non vengono collegati per supposizione;
- un Turn già concluso non viene riscritto.

### `0.2.0-alpha.4` — Vigil

Riutilizzare il runtime operativo Spectre per la sorveglianza:

1. Vigil Definition versionata;
2. trigger tramite timer ed eventi;
3. stato dell’ultima osservazione;
4. confronto e significatività;
5. valutazione cognitiva tramite un nuovo tentativo Runner quando il confronto
   non è deterministico;
6. attesa tra i trigger;
7. vista, pausa, ripresa, stop e rinnovo;
8. aggiornamento di risorse, trigger, intervalli e soglie dichiarati;
9. generazioni dei trigger e invalidazione dei timer precedenti;
10. budget, scadenza, retry e backoff;
11. evento silenzioso o rilevante.

Criteri di uscita:

- la Vigil resta registrata tra due trigger;
- nessun Runner resta obbligatoriamente vivo durante l’attesa;
- un trigger duplicato non duplica l’osservazione committed;
- una valutazione cognitiva non viene eseguita dentro l’Agent GenServer;
- una Vigil in pausa non avvia Runner su timer o eventi;
- dopo un aggiornamento, un timer della generazione precedente viene ignorato;
- una modifica non rilevante non produce una consegna;
- restart conserva ultimo stato e prossimo timer;
- stop o budget impediscono nuove osservazioni.

### `0.2.0-beta.1` — funzioni e cognizione

Integrare le librerie operative:

1. registry delle funzioni applicative;
2. Action Lens come operazioni del runtime;
3. candidati Kinetic dentro cataloghi chiusi;
4. vincoli Prism per ogni loop;
5. decisioni cognitive a dominio chiuso;
6. validazione, retry e fallback;
7. commit selettivo verso Mnemonic.

Criteri di uscita:

- nessun modello può inventare moduli, funzioni o argomenti fuori schema;
- Kinetic propone ma non esegue;
- Prism seleziona il profilo senza possedere il loop;
- un output cognitivo fuori dominio non viene committato;
- il cambio di intelligenza vale soltanto per richieste future.

### `0.2.0-beta.2` — Directive sul runtime operativo Spectre

Evolvere `spectre_directive`:

1. rendere il mission loop un controller del runtime operativo Spectre;
2. rendere portabile e versionato il payload Mission;
3. aggiungere Destination, MissionMap, Fog e Frontier;
4. aggiungere Waypoint, Resolution e Outcome;
5. aggiungere Question correlate e charting tramite Flow;
6. permettere a Directive di avviare Work indipendenti;
7. eseguire charting e pianificazione tramite Runner Directive;
8. registrare un riferimento stabile per ogni esecuzione Waypoint;
9. collegare Result, artifact, evidenze e fonti primarie ai Waypoint;
10. derivare deterministicamente Fog e Frontier dalla MissionMap committed;
11. verificare la Destination tramite contratto versionato o accettazione
    umana correlata;
12. riconciliare idempotentemente i Work collegati dopo resume e restart;
13. mettere in pausa e riprendere il controller Mission;
14. committare nuove informazioni e rivalutare Resolution e Waypoint;
15. versionare nuovamente la Destination quando cambia;
16. rendere esplicita l’eventuale pausa dei Work collegati;
17. riprendere la Mission dopo il crash di un Runner;
18. mantenere la modalità standalone con semantica equivalente di controllo;
19. lasciare i tracker come adapter opzionali.

Criteri di uscita:

- Directive può cambiare liberamente la MissionMap entro policy;
- un Work normale resta procedurale e non acquisisce un goal;
- Directive può coordinare più Work concorrenti;
- ogni Work e ogni avanzamento Directive hanno Runner indipendenti;
- il Work non conosce la Mission che lo ha avviato;
- un Work completato non completa automaticamente la Mission;
- un evento Work perso o duplicato non perde né duplica la Resolution;
- Frontier e Fog possono essere ricalcolate dalla MissionMap committed;
- ogni Resolution conserva il riferimento alla propria esecuzione e fonte;
- una Mission in pausa non pianifica né avvia nuovi Work;
- la pausa della Mission non si propaga implicitamente ai Work già avviati;
- alla ripresa le nuove informazioni possono riaprire o sostituire Waypoint
  senza cancellare la History;
- il modello non può dichiarare conclusa la Mission fuori dal contratto della
  Destination;
- Question e risposte restano correlate dopo restart.

### `0.2.0-beta.3` — consegna e interscambi remoti

Completare i confini:

1. autorizzazione della consegna proattiva;
2. consenso, revoca e scadenza;
3. deduplicazione;
4. rate limit;
5. quiet hours;
6. digest e aggregazione;
7. Flow per il rendering;
8. Beam per la consegna;
9. Pulse per eventi tra Agent.

Criteri di uscita:

- un evento importante senza consenso non viene consegnato;
- la stessa notifica non viene inviata due volte;
- quiet hours e rate limit sono rispettati;
- Pulse non diventa scheduler, Store o mission planner.

### Ordine di lavoro tra repository

L’ordine consigliato evita che una libreria satellite anticipi contratti non
ancora stabili:

| Ordine | Repository | Blocco da completare |
|---|---|---|
| 1 | `spectre` | stato Agent, snapshot/merge, runtime, Runner, controllo dei loop, Work, Flow integration e Vigil |
| 2 | `spectre_lens` | Result portabili e correlati |
| 3 | `spectre_kinetic` | candidato chiuso e separato dall’esecuzione |
| 4 | `spectre_prism` | vincoli cognitivi per loop |
| 5 | `spectre_mnemonic` | commit selettivo senza ownership operativa |
| 6 | `spectre_directive` | controller sul runtime, Wayfinder e orchestrazione Work |
| 7 | `spectre_beam` | consegna governata |
| 8 | `spectre_pulse` | interscambi remoti senza ownership |

Ogni repository deve dichiarare la versione minima compatibile di `spectre`.
Non è necessario forzare lo stesso numero di versione a tutte le librerie, ma
la matrice finale deve identificare una combinazione precisa e riproducibile
per il milestone `0.2.0`.

### `0.2.0-rc.1` — hardening

Prima del freeze:

1. test di restart in ogni stato di attesa;
2. test di crash Runner prima e dopo il side effect;
3. test di Agent restart con Runner ancora attivi;
4. test di Result duplicati, fuori ordine, stale e provenienti da epoch vecchi;
5. test che ogni Runner termini dopo il Result e che l’operazione successiva
   riceva un nuovo tentativo;
6. test di merge concorrenti;
7. test di progress ad alta frequenza e backpressure;
8. test di upgrade delle Definition versionate;
9. test di budget e cancellazione con side effect ambiguo;
10. test della race tra richiesta di pausa e Result del Runner;
11. test distinti per pausa al confine sicuro e interruzione immediata;
12. test di restart in ogni fase di pausa, aggiornamento e ripresa;
13. test di deduplicazione dello stesso comando di controllo;
14. test che uno stop terminale non possa essere ripreso;
15. test di aggiunta di fonti a un Work web con deduplicazione degli URL;
16. test di valutazione cognitiva Vigil fuori dal GenServer;
17. test di timer Vigil proveniente da una generazione invalidata;
18. test di Work completato mentre Directive è ferma e riconciliazione al
    resume;
19. test di evento Work perso o duplicato senza perdita o duplicazione della
    Resolution;
20. test che pausa o stop Directive non fermino i Work collegati senza
    richiesta esplicita;
21. property test su Frontier, Fog e verifica della Destination;
22. test di più Work, Vigil e Mission contemporanei;
23. property test sui reducer, tentativi, revisioni e aggiornamenti;
24. telemetry e journal redatti;
25. documentazione delle API reali;
26. migration guide da `0.1.x`;
27. matrice di compatibilità tra le librerie;
28. esempi eseguibili senza pseudo-API.

### Freeze `0.2.0`

La release finale viene pubblicata soltanto quando:

- tutti i criteri della sezione 17 sono coperti da test;
- nessuna decisione aperta compare come API pubblica;
- i checkpoint possiedono versione e strategia di migrazione;
- le integrazioni dichiarano versioni compatibili;
- il comportamento di Work, Vigil, Directive e Runner è documentato
  separatamente;
- pausa, aggiornamento, ripresa, stop e relative race possiedono un contratto
  pubblico testato;
- le API pubbliche sono state provate almeno durante una beta e una RC.

Dopo il freeze:

- `0.2.x` accetta bugfix e aggiunte compatibili;
- nessuna semantica già pubblicata viene reinterpretata;
- una rottura architetturale viene rimandata a `0.3.0`;
- esperimenti non maturi restano interni o esplicitamente sperimentali.

---

## 16. Decisioni volutamente aperte

Queste cose non vengono decise da questo concept:

1. nome esatto del behaviour Work;
2. nomi esatti dei callback Work;
3. contratto pubblico con cui Work, Vigil e Directive forniscono un controller
   al runtime operativo Spectre;
4. sintassi esatta dei verbi Work e Vigil nel Flow;
5. rappresentazione del dataflow senza plumbing manuale;
6. rappresentazione delle modifiche e algoritmo di merge;
7. granularità delle revisioni dello stato Agent;
8. forma delle proiezioni pubbliche;
9. nome e schema degli eventi dei loop;
10. mapping preciso da evento a route Flow;
11. API host per avvio, ispezione e controllo;
12. backend e layout fisico del checkpoint Agent;
13. sintassi per selezionare Prism nei loop;
14. forma pubblica della decisione cognitiva a dominio chiuso;
15. sintassi della Vigil Definition;
16. nuova DSL Wayfinder di Directive;
17. adapter concreto per GitHub, Linear o Jira;
18. rappresentazione interna di più Question aperte;
19. configurazione concreta di consenso, quiet hours, rate limit e digest;
20. forma della correlazione che riprende un Work bloccato;
21. forma dichiarativa dei rami chiusi del Work;
22. semantica di un eventuale handoff;
23. nome esatto del modulo Runner e forma del child spec;
24. topologia e strategia esatta del supervisor dei Runner;
25. rappresentazione portabile di attempt, epoch e fencing token;
26. algoritmo di campionamento e backpressure del progress;
27. rappresentazione pubblica di un side effect con risultato sconosciuto;
28. rappresentazione pubblica del riferimento di esecuzione Waypoint e delle
    fonti primarie;
29. forma concreta del contratto versionato di soddisfazione della
    Destination;
30. adapter durevole per riconciliare Work esterni in modalità Directive
    standalone;
31. rappresentazione pubblica del comando durevole di controllo e degli
    aggiornamenti con provenienza;
32. nomi pubblici e policy che autorizza l’interruzione immediata rispetto alla
    pausa predefinita al confine sicuro;
33. forma del contratto controller per campi aggiornabili, invalidazioni e
    punto di ripresa;
34. policy con cui una pausa o uno stop Directive possono essere propagati
    esplicitamente ai Work collegati;
35. API per creare una nuova istanza correlata a partire da un loop terminale;
36. eventuale integrazione MCP.

Queste decisioni richiedono design sul codice reale e test di compilazione.

Finché non sono decise non devono comparire nella documentazione come API
esistenti.

---

## 17. Criteri di accettazione

Il design è corretto quando:

1. l’Agent GenServer è l’unico proprietario dello stato canonico locale;
2. Flow, Work, Vigil e Directive mantengono stati semanticamente distinti;
3. Work, Vigil e Directive riusano lo stesso runtime operativo Spectre, che
   non appartiene semanticamente a Work;
4. le operazioni lente non possiedono lo stato e non bloccano l’Agent;
5. ogni snapshot conserva la revisione di partenza;
6. una copia senza merge non modifica lo stato originale;
7. un Result stale non sostituisce lo stato recente;
8. un conflitto viene rifiutato o ricalcolato, non risolto dal modello;
9. ogni merge accettato produce una revisione committed;
10. un Work non contiene goal o Destination;
11. un Work non crea Work figli;
12. ogni Work descrive un’operazione precisa;
13. una funzione deterministica decide il completamento operativo dal solo
    stato committed;
14. cancellazione, scadenza, errore e budget producono esiti terminali
    tipizzati;
15. stato parziale e artifact restano disponibili dopo budget esaurito;
16. Vigil appartiene al core Spectre;
17. una Vigil resta registrata tra timer o eventi successivi;
18. Vigil riusa il runtime operativo Spectre senza diventare un Work infinito;
19. una Vigil può essere interrogata, messa in pausa, ripresa oppure fermata
    in modo terminale;
20. `spectre_directive` possiede la semantica di Mission, Destination,
    MissionMap, Fog, Frontier, Waypoint e Question;
21. il core checkpointa il payload Directive senza interpretarne il dominio;
22. Directive usa il runtime operativo Spectre come controller goal-driven;
23. Directive può avviare Work indipendenti;
24. il Work non sa di appartenere a un Waypoint Directive;
25. la fine di un Work non completa automaticamente una Mission;
26. il core Spectre non espone un secondo tipo Mission;
27. lo stesso Work o Vigil può usare Lens, Kinetic e funzioni registrate;
28. Kinetic propone ma non esegue;
29. Prism seleziona intelligenza senza possedere il loop;
30. un output cognitivo fuori dominio non viene committato;
31. Mnemonic non ricostruisce lo stato operativo;
32. la chat può interrogare Work, Vigil e Mission mentre avanzano;
33. la lettura della vista non ferma il loop;
34. più loop ambigui richiedono chiarimento;
35. la visibilità dipende da Subject, origine e policy, non dal modello;
36. il cambio di intelligenza vale soltanto per inferenze future;
37. progress, trigger e Result sono correlati e revision-fenced;
38. un loop può produrre un evento senza produrre una notifica;
39. importanza e autorizzazione alla consegna restano decisioni separate;
40. consenso, dedup, rate limit e quiet hours vengono verificati prima della
    consegna;
41. un Flow prepara il messaggio e Beam lo trasporta soltanto verso una
    destinazione autorizzata;
42. il risultato può restare disponibile fino a quando viene chiesto;
43. una Mission può nascere dal charting in chat senza una mappa autorata;
44. ogni risposta umana è correlata alla Question esatta;
45. più Question aperte non rendono valido un “sì” ambiguo;
46. un blocker Work non viene registrato come completamento riuscito;
47. un Work riprende dopo una risposta soltanto lungo un ramo già dichiarato;
48. un Prototype richiede valutazione, salvo criterio deterministico;
49. l’Outcome terminale Directive resta checkpointabile anche quando è
    derivabile;
50. gli esempi Elixir del concept corrispondono ad API verificate;
51. ogni futura sintassi non approvata è indicata come da progettare;
52. nessun pseudo helper viene presentato come parte di Spectre;
53. ogni tentativo di un loop possiede al massimo un Runner valido;
54. il Runner usa uno snapshot e non possiede lo stato canonico;
55. il crash di un Runner non fa crashare l’Agent;
56. l’Agent, non il supervisor, decide il retry semantico;
57. attempt ed epoch impediscono il commit di Result tardivi;
58. un Runner non viene riavviato automaticamente con uno snapshot stale;
59. Work, Vigil e Directive riprendono dall’ultimo checkpoint dopo il crash
    del proprio Runner;
60. un loop in attesa non richiede necessariamente un processo Runner vivo;
61. un side effect non idempotente con esito sconosciuto non viene ripetuto
    automaticamente;
62. i progress dei Runner sono soggetti a backpressure e diventano committed
    soltanto attraverso l’Agent;
63. ogni Runner esegue una sola operazione e un solo tentativo e termina dopo
    il Result conclusivo o il crash;
64. l’operazione successiva dello stesso loop riceve un nuovo snapshot, un
    nuovo tentativo e un nuovo Runner;
65. una valutazione cognitiva della significatività Vigil avviene in un Runner
    separato e non dentro l’Agent GenServer;
66. Directive riconcilia idempotentemente le viste committed dei Work
    collegati dopo resume, restart o crash del proprio Runner;
67. un evento terminale Work può risvegliare Directive ma non è l’unica fonte
    di verità del relativo Waypoint;
68. Fog e Frontier sono ricalcolabili deterministicamente dalla MissionMap
    committed e dalle dipendenze;
69. la Mission termina soltanto attraverso il contratto versionato della
    Destination o un’accettazione umana correlata;
70. ogni Resolution conserva il riferimento dell’esecuzione, le evidenze e la
    fonte primaria applicabile;
71. l’integrazione standalone con Work esterni richiede lettura durevole e
    riconciliazione, non soltanto consegna effimera di eventi;
72. l’Agent può mettere in pausa, aggiornare, riprendere e fermare Work, Vigil
    e Directive attraverso il runtime operativo Spectre;
73. pausa reversibile e stop terminale sono stati semanticamente distinti;
74. dopo una richiesta di pausa committed lo scheduler non avvia nuovi Runner
    per quel loop;
75. pausa al confine sicuro e interruzione immediata hanno regole esplicite per
    il Result del tentativo attivo;
76. una sequenza pausa, aggiornamento e ripresa sopravvive a restart e retry
    senza applicare due volte lo stesso aggiornamento;
77. ogni aggiornamento viene validato dal controller, revisionato e collegato
    alla propria provenienza;
78. l’input di base resta disponibile e il contesto effettivo deriva dagli
    aggiornamenti committed;
79. dopo la ripresa il nuovo Runner usa il contesto aggiornato e un Result
    basato sulla generazione precedente non può mutare il loop;
80. un Work web può ricevere nuove fonti, deduplicarle e includerle nella
    propria funzione di completamento senza perdere i risultati committed;
81. un comando naturale ambiguo non modifica alcun loop prima del
    chiarimento;
82. il Flow distingue nella risposta pausa richiesta, pausa raggiunta,
    aggiornamento applicato e ripresa committed;
83. un loop terminale non viene riaperto tramite una semplice ripresa;
84. una Vigil in pausa non reagisce a trigger e ignora timer appartenenti a
    generazioni invalidate;
85. la ripresa Vigil ricalcola il prossimo trigger dalla configurazione
    aggiornata;
86. una Directive in pausa non pianifica, non prende Waypoint e non avvia nuovi
    Work;
87. la pausa Directive non si propaga ai Work collegati senza richiesta o
    policy esplicita;
88. nuove informazioni Mission rivalutano Waypoint e Resolution preservando
    la History, mentre un cambio di Destination richiede nuova versione e
    conferma prevista dalla modalità della Mission;
89. pausa o interruzione non assumono che un side effect già partito sia stato
    annullato;
90. pausa o stop Directive non fermano implicitamente i Work collegati.

---

## Sintesi

```text
Flow
  conversazione, routing, risposta, controllo e interscambio

Work
  operazione precisa, stato, ciclo, funzioni e termine deterministico

Vigil
  osservazione continuativa, timer/eventi, confronto e attesa

Directive
  obiettivo, MissionMap dinamica, Fog, Frontier, Waypoint e Question
```

La struttura è:

```text
Instance Supervisor
  |
  +-- Agent GenServer
  |     |
  |     +-- Flow / Run / Turn
  |     +-- stato Work, Vigil e Directive
  |     +-- comandi di pausa, aggiornamento, ripresa e stop
  |     +-- revisioni, journal e checkpoint
  |
  +-- Runner Supervisor
        |
        +-- Runner Work
        +-- Runner Vigil quando osserva
        +-- Runner Directive quando pianifica
```

Flow, Work e Vigil sono linee semanticamente differenti dentro lo stesso
Agent.

Directive vive semanticamente nella propria libreria, ma il suo loop viene
eseguito dal runtime operativo Spectre. Può pianificare e avviare Work
indipendenti senza trasformarli in Mission o Work figli.

L’Agent può mettere in pausa, aggiornare e riprendere ciascun loop. Le nuove
informazioni vengono validate dal relativo controller, committate con
provenienza e viste soltanto dai Runner creati dopo la ripresa. Uno stop
terminale resta distinto dalla pausa reversibile.

Una richiesta dalla chat come «usa anche questi link e continua» diventa una
sequenza durevole: pausa del Work, aggiornamento della coda delle fonti e
ripresa con un nuovo snapshot. La stessa infrastruttura aggiorna trigger e
soglie Vigil oppure informazioni e vincoli della Mission Directive.

Ogni Runner esegue un solo tentativo operativo e poi termina. Una Vigil crea
Runner soltanto per osservare o valutare; Directive crea Runner soltanto per
charting, pianificazione, riconciliazione o revisione della MissionMap. Nessuno
dei due mantiene un processo Runner durante una lunga attesa.

Directive conserva riferimenti stabili alle esecuzioni dei Waypoint e
riconcilia i Work dallo stato committed dell’Agent. Fog e Frontier vengono
ricalcolate deterministicamente; ogni Resolution resta collegata a evidenze e
fonti, e la Destination possiede un contratto verificabile di soddisfazione.

Spectre core resta il proprietario di State, Run, Turn, Effect, Invocation,
Instance, runtime operativo, Work e Vigil. L’Agent GenServer serializza tutti
i commit; i Runner lavorano su snapshot e restituiscono progress, Result o
modifiche proposte. Il loro crash è isolato e l’Agent può ricrearli
dall’ultimo checkpoint.

La sintassi viene progettata dopo il contratto, non prima.
