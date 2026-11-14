# GAM integrato nel framework — piano per Spectre 0.4

Stato: proposta da revisionare, non implementata. Data: 2026-11-14.
Branch di riferimento: `feature/agent-server-gam`; si considera il working tree,
incluse le modifiche Skills e demo non ancora committate.

## Obiettivo

Un'applicazione normale scrive Stack, Agent, Server, Skill e servizi applicativi.
Non implementa `Host`, `Ingress`, `Mind`, `Executor` né costruisce oggetti GAM.
Spectre gestisce il protocollo; l'applicazione configura autorità e regole e
implementa gli effetti concreti. Il kernel in `lib/spectre/gam/` rimane invariato.

La demo deve diventare la prova di questa ergonomia, conservando tutte le capacità
e i controlli già presenti. Questa proposta riguarda l'integrazione, non una nuova
architettura del Governed Act Model.

## Evidenza nel codice attuale

| File | Responsabilità oggi lasciata all'applicazione |
| --- | --- |
| `../../demo_spectre/lib/demo_spectre/host.ex` | Bootstrap Domain, scope, superficie, mandato, Candidate, Presentation e interpretazione del consenso: 404 righe alla prima ispezione. |
| `../../demo_spectre/lib/demo_spectre/host/ingress.ex` | Autenticazione e adattamento di input, invocazioni, lifecycle e risposte a Evidence. |
| `../../demo_spectre/lib/demo_spectre/host/executor.ex` | Dispatch degli effetti ammessi, conferma di visualizzazione e ricevute GAM. |
| `../../demo_spectre/lib/demo_spectre/host/mind.ex` | Callback vuoto necessario al collegamento. |
| `../../demo_spectre/lib/demo_spectre/session.ex` | Avvio e chiusura manuali di Stack, Domain, ledger, store e Server; correlazione UI. |
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

Introdurre una modalità gestita nell'API pubblica di avvio Spectre, conservando il
bridge manuale come estensione avanzata. Il nome del modulo di supervisione è
interno; non costringere l'utente a imparare un secondo tipo di agente.

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

Distinguere Domain store, journal dei comandi e checkpoint Server anche quando
condividono un backend. Definire recupero con identità stabili, confini di restart,
revoca e conservazione delle Duty. Un disconnect UI non elimina il record autorevole.
Con Stack condiviso, terminare una sessione non deve fermare runtime altrui.

## 2. Contratto registrato per gli effetti

Estendere esplicitamente il contratto Stack/tool, versionandolo quando cambia la
forma chiusa dei descriptor. Non cercare funzioni `execute` per convenzione e non
passare moduli o MFA scelti dall'output del modello.

Il pacchetto deve fornire un contratto dichiarato per:

- catalogo di operazioni, schema e normalizzazione dei parametri;
- classe/conseguenza e informazioni necessarie a costruire una presentazione;
- adapter che esegue un tentativo già ammesso e ne restituisce osservazioni;
- regole di idempotenza e riconciliazione effettivamente supportate dal servizio.

L'applicazione abilita un sottoinsieme del catalogo e applica i propri limiti.
La registrazione descrive cosa sa fare il pacchetto; l'abilitazione descrive cosa
questo agente può proporre. Il consenso resta una condizione aggiuntiva.

Separare Kinetic dagli altri strumenti: il suo helper prepara azioni di un catalogo
applicativo (`MailActions`), non è esso stesso l'esecutore di ogni azione. Integrare
`ActionConfig`, `Planning` e `Catalog`, inclusi digest e origine del mount, senza
introdurre un secondo catalogo incoerente. Mnemonic/Beam/Pulse hanno operazioni
governate dirette; Lens e gli altri conservano i percorsi attuali secondo contratto.

Migrazione v1: mantenere il percorso host manuale; in modalità gestita rifiutare
operazioni governate senza descrizione eseguibile valida, con errore esplicito.
Testare i nove pacchetti e la loro compilazione indipendente quando supportata.

## 3. Regole applicative dentro Server, non builder GAM

Preferire un callback Elixir ordinario per validazione e scelta del consenso,
con default prevedibili e override facoltativi. Il callback può restringere
un'azione autorizzabile, rifiutarla o richiedere conferma, mai ampliare il mandato.
Il risultato è data-only: non esegue l'effetto e non costruisce Candidate.

Esempio di ergonomia PROPOSTA, non API già disponibile; nomi da fissare nella review:

```elixir
# Il Server mantiene i normali handle_flow / handle_result / handle_info.
# Invocato dopo la preparazione, prima della costruzione del Candidate.
def handle_action(%{name: :send_email, args: args}, ctx) do
  if args.to == ctx.assigns.email do
    {:confirm,
     %{message: "Inviare questa email?", expires_in: 60_000}}
  else
    {:reject, :recipient_not_observed}
  end
end
```

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

La demo conserva UI e hook di rendering, ma elimina messaggi interni a executor,
Evidence manuali e mappe di attese GAM. Il wrapper Session può restare per esigenze
UI, sottile e senza responsabilità normative.

## 5. Sequenza di implementazione

1. Bloccare i contratti osservabili con test mirati: esempio minimo senza Host,
   stesso Domain tra Agent/Skill, nessun effetto prima dell'ammissione.
2. Definire contratto registrazione/esecuzione e configurazione dell'autorità;
   validazione iniziale, compatibilità descriptor v1 e snapshot/digest.
3. Implementare bootstrap/supervisione gestiti con identity/storage/ownership
   espliciti; riutilizzare `Server.GAM`, `Invocation`, `Lifecycle` e kernel.
4. Implementare preparazione standard di Candidate/Presentation e callback
   applicativo. Congelare argomenti e contesto necessario prima del consenso.
5. Collegare esecutori registrati e osservazioni reali: solo dopo Act; gestire
   incertezza e recovery senza retry automatico degli effetti non riconciliati.
6. Implementare trasporto consenso e default pending, preservando override OTP.
7. Migrare i pacchetti che richiedono il nuovo contratto; testare tutti e nove.
8. Migrare demo: eliminare i quattro moduli Host, semplificare Session, mantenere
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
`../../demo_spectre/docs/VERIFICATION.md`; questi non sono test di questa proposta.

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
