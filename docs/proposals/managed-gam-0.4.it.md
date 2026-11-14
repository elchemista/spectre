# GAM integrato nel framework — piano per Spectre 0.4

> Documento storico: il successivo completamento elimina il selettore
> development/produzione e il collegamento GAM manuale in AgentServer.
> Per il contratto attuale e `Spectre.GAM.submit/4` vedere
> [GAM automatico](../MANAGED_GAM.md). I risultati di verifica qui sotto
> descrivono la revisione precedente.

Implementazione disponibile nel profilo gestito `authority: :development`; questa
proposta conserva anche le decisioni e le alternative discusse. Per le API attuali,
i limiti e il percorso manuale vedere [Managed GAM](../MANAGED_GAM.md).

Stato: proposta revisionata con Opus 5.5, non implementata. Data: 2026-11-14.
La direzione è approvata dal reviewer con correzioni; la fattibilità del percorso
di consenso con identità umana distinta deve superare la fase 0 prima di implementare.
Branch di riferimento: `feature/agent-server-gam`; si considera il working tree,
incluse le modifiche Skills e demo non ancora committate.

Review originale: [parere Opus](reviews/claude-opus-5.5-managed-gam-review.it.md).
La [bozza esaminata](reviews/managed-gam-0.4-reviewed-draft.it.md) è conservata
separatamente; i suggerimenti seguenti non sono un'approvazione incondizionata.

Aggiornamento successivo richiesto dall'utente: automatismi con controllo manuale
opzionale. Vedere [piano ed esempi dei livelli di controllo](managed-gam-control-examples.it.md).
Questa aggiunta non è stata sottoposta a un'ulteriore review Opus.

## Obiettivo

Un'applicazione normale scrive Stack, Agent, Server, Skill e servizi applicativi.
Non implementa `Host`, `Ingress`, `Mind`, `Executor` né costruisce oggetti GAM.
Spectre gestisce il protocollo; l'applicazione configura autorità e regole e
implementa gli effetti concreti. Il kernel in `lib/spectre/gam/` rimane invariato.

La demo deve diventare la prova di questa ergonomia, conservando tutte le capacità
e i controlli già presenti. Questa proposta riguarda l'integrazione, non una nuova
architettura del Governed Act Model.

### Decisione centrale: completare AgentServer, non aggiungere un Host pubblico

Chiarimento dell'utente durante la review: sfruttare AgentServer per tracciare e
registrare automaticamente azioni, autorità applicabile, return e risultati.
Si recepisce questa scelta come punto di partenza dell'implementazione.

`Spectre.Server.Runtime` esiste già, è un GenServer e controlla il ritorno dei
callback e l'outbox. Estendere quel punto, senza introdurre un secondo motore:

```text
callback applicativo → return ctx con comandi
→ Runtime normalizza e congela il comando nell'outbox
→ usa mandato/configurazione già riconosciuti
→ Server.GAM costruisce e sottopone la proposta
→ il kernel decide e registra prima di rilasciare l'esecuzione
→ l'esecutore restituisce osservazioni, GAM registra l'esito
→ Runtime consegna il risultato al callback handle_result
```

La registrazione dell'invocazione, dei passaggi di lifecycle e del risultato
avviene nel framework. Non si costruisce un nuovo mandato a ogni return, né si
trasforma ogni return in un Act: l'Act è solo l'esercizio ammesso dell'autorità.
Rifiuti, osservazioni, operazioni cognitive e risultati conservano i propri tipi.

Gli helper accumulano comandi senza I/O immediato: questo permette la mediazione
prima dell'effetto. Una chiamata diretta a un servizio dentro codice Elixir
arbitrario non può diventare governata tramite logging al ritorno del callback.
Il Domain rimane separato per record e decisioni condivisi; AgentServer orchestra
automaticamente quel protocollo anche per le Skill e i callback OTP.

## Evidenza nel codice attuale

| File | Responsabilità oggi lasciata all'applicazione |
| --- | --- |
| `../../../demo_spectre/lib/demo_spectre/host.ex` | Bootstrap Domain, scope, superficie, mandato, Candidate, Presentation e interpretazione del consenso: 404 righe alla prima ispezione. |
| `../../../demo_spectre/lib/demo_spectre/host/ingress.ex` | Autenticazione e adattamento di input, invocazioni, lifecycle e risposte a Evidence. |
| `../../../demo_spectre/lib/demo_spectre/host/executor.ex` | Dispatch degli effetti ammessi, conferma di visualizzazione e ricevute GAM. |
| `../../../demo_spectre/lib/demo_spectre/host/mind.ex` | Callback vuoto necessario al collegamento. |
| `../../../demo_spectre/lib/demo_spectre/session.ex` | Avvio e chiusura manuali di Stack, Domain, ledger, store e Server; correlazione UI. |
| `lib/spectre/server/gam.ex` | Il bridge implementa già proposta, consenso e ripresa, ma richiede scope e binding host con builder Candidate/Presentation. |
| `lib/spectre/stack/tools.ex` | Descriptor v1: le operazioni governate nominano un binding host, senza un contratto per l'esecuzione automatica. |
| `lib/spectre/server/tool.ex` | Normalizzazione e controlli del catalogo già esistenti: vanno riutilizzati. |
| `lib/spectre/server/skills.ex` | Processi Skill con dominio condiviso, autorità limitata al mount e instradamento già implementati. |

La soluzione non consiste nello spostare intero `DemoSpectre.Host` dentro la
libreria: occorre separare la meccanica generale dalle decisioni della demo.

## Vincoli

- Stack installa; Agent descrive router, flow, modelli, classifier e Skill; Server
  gestisce comportamento e continuazioni con callback Elixir, inclusi i callback OTP.
- Le Skill concorrenti condividono il Domain dell'agente, con provenienza e limiti
  per mount. Un mount non acquisisce l'autorità delle altre Skill.
- Conservare router/fallback, classifier indipendenti, IntentDataset, training,
  raccolta `collect_intent` e cache vettoriale con embedding compatibili.
- Il modello genera AL; `kinetic(ctx, response, ...)` prepara proposte dal risultato
  consolidato. I token di anteprima non possono produrre effetti.
- Le operazioni cognitive configurate mantengono il loro percorso. L'installazione
  non concede automaticamente ogni conseguenza proposta da un tool.
- Stesso meccanismo per proposte da flow, result, pending, timer e callback OTP.
- Nessuna dipendenza da Phoenix nel core; integrazione trasporto adattabile.
- Nessuna promessa che il kernel controlli ogni chiamata Elixir arbitraria: le
  credenziali degli effetti governati devono restare al confine di esecuzione.

Il [manifesto GAM](https://spectre.guide/en/governed-act-model) richiede una
superficie esplicita, autorità proveniente dall'esterno e registrazione prima
dell'esecuzione. Il consenso non sostituisce un mandato. Un esito incerto resta
incerto: riavvio, timeout o chiusura della conversazione non risolvono una Duty.
Questi vincoli guidano gli automatismi; non richiedono builder ripetuti in ogni app.

## Architettura proposta

```text
Stack: catalogo strumenti e adapter registrati
Agent: router / flow / Skill / configurazione applicativa
                        │
       supervisione di una sessione Spectre
       ├── Domain GAM + record autorevole
       ├── runtime Stack posseduto, oppure riferimento condiviso esplicito
       ├── AgentServer
       ├── SkillServer outreach
       └── SkillServer knowledge

callback → comando persistito → preparazione/validazione
         → bridge Spectre → kernel GAM → Act → esecutore registrato
         → esito osservato → record GAM → handle_result

conferma: presentazione ammessa → visualizzazione attestata dal trasporto
         → risposta autenticata e correlata → valutazione GAM → eventuale Act
```

Il Domain ordina le decisioni; non diventa il processo che attende browser,
rete, modello o risposta umana. Le attese rimangono in worker supervisionati.
La relazione è di condivisione del confine di autorità, non una catena di
GenServer bloccanti `Domain → Agent → Skill`.

## 1. Runtime gestito e bootstrap

### Controllo progressivo, stesso percorso GAM

Il runtime gestito è il default ergonomico, non una limitazione delle API.
Sono previsti tre livelli componibili:

1. **Standard:** configurazione delle operazioni e callback applicativi; Spectre
   fornisce bootstrap, builder, esecuzione mediata, consenso e registrazione.
2. **Personalizzato:** stessa gestione, con override per singola operazione o
   callback (`handle_action`, `handle_pending`, `handle_result`, callback OTP),
   presentazione/trasporto e adapter. Le parti non sostituite mantengono i default.
3. **Integrazione manuale:** conservare la forma esistente
   `gam: {Spectre.Server.GAM, config}` con scope/binding forniti dall'host e
   accesso alle API kernel per chi gestisce direttamente il proprio Domain.

Controllo manuale non significa disabilitare ammissione, consenso richiesto o
registrazione. Il bootstrap può appartenere all'app, ma un comando emesso da un
Server passa comunque per outbox, bridge e kernel. Non duplicare Act o Evidence
registrando manualmente lo stesso comando prima del return.

Precedenza: gli obblighi del mandato/superficie sono sempre vincolanti; la
configurazione applicativa può restringerli; un override può aggiungere
restrizioni o personalizzare il flusso, non rimuovere obblighi. Nessun
`confirm: false` per aggirare una conferma richiesta dalla superficie.

L'override del builder non modifica l'autorità: il framework verifica schema,
identità, origine/mount e materiale prima dell'ammissione, e il kernel applica
le proprie invarianti. Callback di sola preparazione senza I/O. L'effetto si
personalizza nell'adapter registrato, eseguito soltanto dopo l'Act.

Con Domain esterno, il Server non lo arresta e non ne duplica il bootstrap.
Le Skill continuano a usare quel Domain e i propri limiti. Una variante manuale
deve superare gli stessi test di consenso, replay, scadenza e recovery dei default.

Introdurre una modalità gestita nell'API pubblica di avvio Spectre, conservando il
bridge manuale come estensione avanzata. Il nome del modulo di supervisione è
interno; non costringere l'utente a imparare un secondo tipo di agente.

Forma pubblica preferita: estendere l'opzione esistente `gam:` di
`Spectre.Server.start_link/1` con una configurazione gestita. Non aggiungere un
nuovo Host obbligatorio. I nomi di supervisor e adapter rimangono interni.

Il runtime gestito possiede bootstrap, ingress standard, esecutore standard,
correlazione, lifecycle, journal e cleanup. Autentica la sessione a partire dal
confine applicativo affidabile, senza prendere identità o concessioni dal testo
del modello o da parametri del browser non verificati.

Configurazione esplicita e compatta: identità autenticata, operazioni abilitate,
scopo/limiti, consenso richiesto e persistenza. Un profilo locale di sviluppo può
usare identità e storage effimeri dichiarati; produzione deve richiedere origine
dell'autorità e garanzie di storage adeguate. Nessun mandato universale implicito.
La configurazione compatta produce gli oggetti kernel tramite API esistenti;
non afferma che il framework possa inventare l'autorità esterna.

Il profilo deve essere esplicito (`authority: :development` per la demo); la
produzione riceve una fonte affidabile dell'autorità e identità già verificata,
non un parametro arbitrario del client. Il contratto della configurazione deve
coprire anche l'autorità che può disporre le Duty, senza obbligare l'app a
costruire record kernel.

Prima dell'avvio operativo confrontare la configurazione canonica dell'autorità
con lo stato autorevole recuperato. Un nuovo valore in `operations:` non modifica
un mandato esistente. Divergenza non gestita → errore esplicito e percorso di
modifica governata tramite le API già esistenti; niente nuovo genesis al restart.
Distinguere configurazione iniziale, modifiche autorizzate registrate e revoche.

Distinguere Domain store, journal dei comandi e checkpoint Server anche quando
condividono un backend. Definire recupero con identità stabili, confini di restart,
revoca e conservazione delle Duty. Un disconnect UI non elimina il record autorevole.
Con Stack condiviso, terminare una sessione non deve fermare runtime altrui.

Ordine di arresto: fermare nuovi input, riconciliare o attendere con limite i
worker governati, conservare l'incertezza residua, poi arrestare i componenti
posseduti. In modalità durevole il Domain ha identità stabile indipendente dalla
connessione LiveView. Storage effimero esplicito solo nel profilo di sviluppo;
non presentare checkpoint durevole + ledger effimero come recovery completo.

Scope, credenziali e configurazione interna del Domain non devono attraversare
`ctx`, `service_context.options`, planner o adapter cognitivi. Conservare solo
identificativi pubblici e proiezioni autorizzate. Questo evita esposizioni del
framework; non costituisce un sandbox contro codice Elixir fidato arbitrario.

### Fase 0: identità e consenso umano

Il codice attuale della demo autentica `proposer.ref` anche per l'input umano
(`Host.open`, `principal: proposer.ref`) e presenta la conferma al proposer.
Non migrare questo comportamento nel default del framework.

Il registro deve attribuire la risposta umana all'identità umana autenticata;
proposta, osservazione e approvazione devono mantenere la loro provenienza reale.
Non imporre una legge universale che vieti ogni coincidenza tra ruoli: qui il
problema è attestare una conferma umana come se fosse una risposta dell'agente.

Nel [follow-up](reviews/claude-opus-5.5-managed-gam-followup.it.md) Opus ritira la
proposta iniziale dei due principal nella stessa Scope. `Scope.Opening` vincola
principal, submission context e autenticazione; `GovernedAct.View.scope_context/2`
verifica quei legami. Il protocollo corrente lega proposta e approvazione alla
stessa Scope/principal: autenticare un secondo principal non risolve il problema.

Percorso candidato a kernel invariato: una Scope dell'umano autenticato, con
mandato intestato a quell'identità, proposte formalmente a suo nome e provenienza
dell'elaborazione dell'agente registrata come tale. Questo ha una semantica diversa
da un agente principal autonomo che riceve approvazione da un altro principal.
Non adottarlo implicitamente solo per far passare i test. Documentare la scelta
del profilo e dimostrare proposta, approvazione e provenienza con test del bridge.

La separazione agente-principal / approvatore-principal richiederebbe un'estensione
del protocollo attuale: è fuori da questa semplificazione e non va introdotta
silenziosamente. Nessuna falsa promessa che basti automatizzare AgentServer per
ottenere una semantica assente nel kernel.

In entrambi i casi l'ingress deve verificare un evento del trasporto autenticato,
fresco e legato alla presentazione. Il semplice envelope `:presentation_response`
non è prova di consenso. Un riferimento o token monouso da solo non dimostra un
gesto umano: va verificata anche la sessione/capacità del trasporto, impedendone
esposizione ai tool e riutilizzo. Il framework fornisce questa meccanica.

Test della fase 0: proposta sotto il mandato corretto; approvazione attribuita
all'identità verificata; rifiuto senza evento affidabile o con correlazione vecchia;
nessuna Scope nei contesti tool; provenienza Agent/Skill presente nel record.
Nessuno di questi nuovi test è stato ancora eseguito.

## 2. Contratto registrato per gli effetti

Estendere esplicitamente il contratto Stack/tool, versionandolo quando cambia la
forma chiusa dei descriptor. Non cercare funzioni `execute` per convenzione e non
passare moduli o MFA scelti dall'output del modello.

Nome preciso della revisione: **tool descriptor v2**, distinto dal già esistente
`Spectre.Stack.Contract.V2`. Il contratto adapter attuale è verificato tramite
funzioni esportate in `Server.Tool.validate_adapter!`; introdurre un behaviour
esplicito e documentato per le nuove callback invece di presumere che esista già.

Il pacchetto deve fornire un contratto dichiarato per:

- catalogo di operazioni, schema e normalizzazione dei parametri;
- classe/conseguenza e informazioni necessarie a costruire una presentazione;
- adapter che esegue un tentativo già ammesso e ne restituisce osservazioni;
- regole di idempotenza e riconciliazione effettivamente supportate dal servizio.

Riutilizzare il vocabolario di `Spectre.Operation.Spec`: `:none`, `:idempotent`,
`:reconcilable`, `:non_idempotent`, senza reintrodurre il vecchio runtime.
Gli esiti del nuovo adapter devono distinguere successo, fallimento osservato,
nessun effetto definitivo e ambiguità. Non trasformare ogni errore in ambiguità,
né ogni `{:ok, receipt}` in consegna esterna avvenuta: il livello attestato dalla
ricevuta fa parte del contratto. Usare riferimenti stabili dell'Act per correlazione
e idempotenza quando il provider la supporta; il solo ID non garantisce deduplica.

Congelare anche partizione/identità necessarie all'esecuzione (per Mnemonic),
senza consentire override dal payload. Derivare l'executor contract ref dai
descriptor e dagli schemi/adapter versionati; controllarlo anche alla conferma
e al recupero di proposte pendenti. Metadati vuoti non devono saltare i controlli
del catalogo nel percorso gestito.

L'applicazione abilita un sottoinsieme del catalogo e applica i propri limiti.
La registrazione descrive cosa sa fare il pacchetto; l'abilitazione descrive cosa
questo agente può proporre. Il consenso resta una condizione aggiuntiva.

Separare Kinetic dagli altri strumenti: il suo helper prepara azioni di un catalogo
applicativo (`MailActions`), non è esso stesso l'esecutore di ogni azione. Integrare
`ActionConfig`, `Planning` e `Catalog`, inclusi digest e origine del mount, senza
introdurre un secondo catalogo incoerente. Non occorre fondere fisicamente tutti
i cataloghi: basta un collegamento verificabile con identità dell'operazione
preservata. Mnemonic/Beam/Pulse hanno operazioni governate dirette; includere
esplicitamente anche `Lens :act`, mantenendo i suoi percorsi cognitivi distinti.

Migrazione v1: mantenere il percorso host manuale; in modalità gestita rifiutare
operazioni governate senza descrizione eseguibile valida, con errore esplicito.
Testare i nove pacchetti e la loro compilazione indipendente quando supportata.

## 3. Regole applicative dentro Server, non builder GAM

Preferire un callback Elixir ordinario per validazione e scelta del consenso,
con default prevedibili e override facoltativi. Il callback può restringere
un'azione autorizzabile, rifiutarla o richiedere conferma, mai ampliare il mandato.
Il risultato è data-only: non esegue l'effetto e non costruisce Candidate.
Il runtime acquisisce il risultato e il contesto congelato nell'outbox una sola
volta; non rivaluta il callback contro nuovi assigns al replay. Questo non evita
le verifiche correnti del kernel su validità, revoca, scadenza e contratto.

Esempio di ergonomia PROPOSTA, non API già disponibile; nomi da fissare nella review:

```elixir
# Il Server mantiene i normali handle_flow / handle_result / handle_info.
# Invocato dopo la preparazione, prima della costruzione del Candidate.
def handle_action(
      %{operation: {{:skill, :outreach}, :kinetic, :send_email},
        args: %{"to" => to}},
      ctx
    ) do
  if to == ctx.assigns.email do
    {:confirm,
     %{message: "Inviare questa email?", expires_in: 60_000}}
  else
    {:reject, :recipient_not_observed}
  end
end
```

L'esempio mantiene la forma reale dell'operazione e le chiavi stringa di Kinetic.
Un'API futura con un nome locale normalizzato dovrà specificare separatamente
il mount e il provider, senza perderne l'identità. Nella Skill riusabile non si
deve obbligare a codificare il nome del mount dell'applicazione: definire una
vista locale per il callback, mantenendo l'identità completa nel runtime.

I dettagli materiali (destinatario, contenuto, operazione, eventuali costi) sono
costruiti dalla proposta congelata dal framework e sempre inclusi nella
presentazione. `message` personalizza il testo, non può nascondere o sostituire
quei dettagli. Per conferme senza personalizzazione deve bastare configurare
la richiesta di consenso sull'operazione abilitata.

Il flow resta leggibile e il risultato del modello continua a entrare in Kinetic:

```elixir
# API esistenti: la preparazione resta separata dall'effetto.
def handle_result(:model, {:generated, response}, ctx),
  do: kinetic(ctx, response, on_result: :prepared)

def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
  propose(ctx, proposal.operation, proposal.args,
    proposal_metadata: proposal.metadata,
    on_result: :sent
  )
end
```

Questo frammento tratta deliberatamente una sola azione; la gestione completa
deve includere zero/più proposte e errori, riusando `Spectre.Server.Plan` dove adatto.
L'eliminazione dei builder host è indipendente dall'aggiunta di ulteriore DSL.

## 4. Consenso e trasporto

- API neutra per pubblicare presentazioni e ricevere ack/decisioni correlate.
- Default per conferma/rifiuto espliciti; override conversazionale con
  `handle_pending`. Un classifier può aiutare la conversazione, non emettere consenso.
- Un click conferma deve essere legato a identità, sessione, pending, mount,
  presentazione e contenuto congelato. L'ack di rendering non è una conferma.
- Topic change: sospensione, eventuale timer e nuova presentazione alla ripresa.
- Più consensi aperti: nessuna conferma generica applicata a tutti o al primo.
- Scadenze, replay e riconnessioni devono mantenere le verifiche attuali.
- Niente consenso valido se il trasporto non ha attestato la visualizzazione;
  offrire adapter diversi per LiveView, terminale e altri canali.

Preferire due funzioni nuove, nomi proposti: `Server.presented/2` e
`Server.decide/4`, con riferimento della presentazione e mount. Non tradurre il
click in un semplice testo sintetico "confermo". Il processo chiamante deve essere
un trasporto autenticato e autorizzato per quella sessione: il solo possesso di
un pid o del riferimento non autentica la decisione. Le credenziali del trasporto
non devono essere pubblicate agli adapter. Le API testuali restano disponibili.

Il consumer riceve una presentazione pubblica con materiale, revisione e
correlazione; i pulsanti devono essere mostrati insieme al materiale approvato.
Non pubblicare il contenuto come presentazione riuscita prima dello show Act.

La demo conserva UI e hook di rendering, ma elimina messaggi interni a executor,
Evidence manuali e mappe di attese GAM. Il wrapper Session può restare per esigenze
UI, sottile e senza responsabilità normative.

## 5. Sequenza di implementazione

0. Dimostrare il percorso corretto dell'identità umana e agente con il kernel
   esistente. Se l'API attuale non lo consente, risolvere esplicitamente il punto
   architetturale prima di promettere un'implementazione a kernel invariato.
1. Bloccare i contratti osservabili con test mirati: esempio minimo senza Host,
   stesso Domain tra Agent/Skill, nessun effetto prima dell'ammissione.
2. Definire prima principal, fonte dell'autorità e controllo di divergenza al
   recovery; poi registrazione/esecuzione, compatibilità descriptor v1 e digest.
3. Implementare bootstrap/supervisione gestiti con identity/storage/ownership
   espliciti; riutilizzare `Server.GAM`, `Invocation`, `Lifecycle` e kernel.
4. Implementare preparazione standard di Candidate/Presentation e callback
   applicativo. Congelare argomenti e contesto necessario prima del consenso.
5. Collegare esecutori registrati e osservazioni reali: solo dopo Act; gestire
   incertezza e recovery senza retry automatico degli effetti non riconciliati.
6. Implementare trasporto consenso e default pending, preservando override OTP.
7. Migrare i pacchetti che richiedono il nuovo contratto; testare tutti e nove.
8. Migrare demo e host dell'integrazione `integration/stack_tools`: eliminare
   i quattro moduli Host della demo, semplificare Session, mantenere
   i controlli applicativi nel Server/Skill e gli effetti in MailActions/adapter.
9. Aggiornare README, GAM, AgentServer, Skills, Stack Tools, migration e demo;
   l'esempio principale deve funzionare senza alcun oggetto kernel scritto dall'utente.
10. Suite, browser avversariale e review finale; nessun push o merge in questa fase.

## Criteri di accettazione e test

- Demo: link → Lens → output modello → Kinetic → conferma visibile → email locale
  → consenso separato per memoria → ricerca dalla seconda Skill.
- `hello` via Kinetic non appare nel log prima del consenso; replay non lo duplica.
- Mnemonic: mantenere tutte le letture e scritture già integrate, isolamento per
  soggetto, scelta del ricordo da dimenticare e assenza di mutazioni nelle letture.
- Agent/Skill/timer: origine corretta; nessuna escalation da mount o tool diversi.
- Dichiarare che i limiti per mount oggi sono applicati dal runtime, non da
  mandati kernel distinti. Rafforzare quei controlli nel percorso gestito; eventuali
  mandati per mount sono un approfondimento separato, non un requisito nascosto.
- Consenso umano: record attribuito all'umano verificato, nessuna auto-conferma
  dell'agente per operazioni che richiedono specificamente approvazione umana.
- Prova che contesti tool/modello non ricevano Scope, credenziali di submission
  o configurazioni normative riservate del runtime.
- Drift di configurazione, revoca e modifica governata: errore chiaro sulle
  divergenze non gestite, nessuna sostituzione silenziosa del record recuperato.
- Disposizione Duty autorizzata e non autorizzata; errori definitivamente senza
  effetto distinti dall'incertezza, senza attestazioni di successo inventate.
- Manomissione destinatario/contenuto, catalogo cambiato e credenziali mancanti:
  rifiuto esplicito prima dell'effetto, senza falso successo.
- Due consensi concorrenti, risposta tardiva, cambio argomenti, expiry, reconnect,
  doppio click, render ack assente e stop durante esecuzione: nessun falso consenso.
- Crash prima/dopo Act e dopo invio senza ricevuta: riconciliazione e Duty preservate;
  no promesse exactly-once quando il servizio esterno non le supporta.
- Upgrade/restart: snapshot/digest e ID stabili impediscono esecuzione sotto un
  catalogo o una policy diversi senza nuova valutazione; nessuna perdita di record.
- Cache semantica, fallback, IntentDataset e training invariati; test embedding
  deterministico non presentato come prova della qualità di un modello neurale.
- Compilazione/format/test core, pacchetti modificati e demo; test browser reali.

Baseline riportata nell'ultima verifica, da rieseguire dopo implementazione:
core 4398 test; Mnemonic 537 con 11 esclusioni; demo 25; 20 scenari browser
verificati con 19 pass in una run e un rerun corretto. Vedere
`../../../demo_spectre/docs/VERIFICATION.md`; questi non sono test di questa proposta.

## Miglioramenti della demo inclusi nella migrazione

- Le condizioni specifiche (destinatario osservato, scelta da ricerca prima di
  dimenticare) rimangono callback di business, non finiscono nel kernel.
- La presentazione standard di Beam e degli altri strumenti deve includere i
  parametri reali; nessun testo fisso in contraddizione con la conseguenza.
- Catalogo abilitato minimo: niente classi/mandati per binding inutilizzati.
- Proiezione UI limitata e su eventi, evitando il polling dell'intero `GAM.view`
  ogni 700 ms. Un timeout del pannello non equivale a sessione morta.
- Retention esplicita per file di checkpoint e record autorevoli; mai cancellare
  una Duty come semplice cleanup della UI.
- Documentazione Lens: distinguere `:act` governato da `open/look/close` nei
  rispettivi percorsi, evitando descrizioni ambigue.

## Limiti della review

Opus 5.5 ha letto piano, manifesto, demo e numerosi moduli core/pacchetti; la
review originale elenca i file letti interamente, parzialmente e non verificati.
Non ha eseguito test. Le segnalazioni sono verifiche statiche e proposte, non
prova end-to-end. Le correzioni recepite e le riserve sono documentate in
`reviews/claude-opus-5.5-managed-gam-resolution.it.md`.

## Domande per Opus 5.5

1. L'integrazione proposta preserva il manifesto e le invarianti del kernel reale?
2. Qual è il minimo contratto pubblico per autorità/configurazione senza nuovo
   boilerplate Host e senza concedere poteri implicitamente?
3. Il callback proposto deve vivere nel Server o esiste già un punto migliore?
4. Come unificare catalogo Kinetic e descriptor delle operazioni dirette senza
   rompere origine, mount, checkpoint e replay?
5. Quali parti di Session/Host sono veramente generiche e quali restano nella demo?
6. Quale supervisione e protocollo UI minimizzano deadlock e perdita di record?
7. Quali bug nel working tree attuale o ostacoli rendono questo piano incompleto?
8. Proporre un esempio minimo completo delle API nuove, chiaramente separato da
   quelle esistenti, e ordinare le correzioni per priorità.
