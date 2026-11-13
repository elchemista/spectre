# Revisione indipendente: proposta «AgentServer + kernel GAM dalla 0.3»

**Modello:** Claude Opus 5.5 (`claude-opus-5-5`). **Modalità:** sola lettura. Non ho eseguito test, compilazioni o processi e non ho modificato file.

**Limiti:** ho letto per intero la proposta, il manifesto e i documenti allegati. Nel codice ho controllato i punti che potevano cambiare il verdetto: `freelance` (Turn, Policy, Delivery, SideEffects, Agent), il runtime 0.3 (policy, matcher, runner, semantic cache), il core 0.4 (input del Domain, Candidate, Surface), Kinetic e Vettore. Non ho controllato Prism, Beam, Mnemonic, Directive né le suite di test. Dove qualcosa non è verificato lo indico.

---

## 1. Verdetto

**La direzione ha senso, ma la proposta oggi è più ampia di quanto serva e sottovaluta due punti d'integrazione. Su questi due punti il codice smentisce in parte le sue premesse.**

**Cosa regge:**
- Conservare la DSL e il routing della 0.3.
- Unificare i ritorni degli handler e far avanzare automaticamente l'interazione.
- Un solo proprietario dello stato locale.
- GAM come unica autorità solo per le conseguenze dichiarate.

La lettura del perimetro GAM (§2) è nella sostanza corretta. I dettagli e una correzione sono nel problema 6.

**Cosa non regge così com'è:**

1. **Il caso di riferimento non è quello descritto.** In `freelance` l'azione `delete_my_account` non fa nulla. La cancellazione reale avviene in un hook eseguito dopo il solo accodamento del messaggio. I percorsi che anonimizzano i dati sono quattro e nessuno passa da un confine unico (problema 1).
2. **Il kernel 0.4 non è un valutatore di Candidate isolabile.** Il suo percorso d'ingresso trasforma l'input in Evidence durevole e in Mind Turn sigillati. Il consenso si lega a `evidence_refs`. La proposta non dice come l'input della 0.3 diventi Evidence (problema 2).

**È più semplice della 0.4?** Per chi scrive l'agente probabilmente sì. Per il runtime no, almeno durante la migrazione: convivranno il lifecycle Effect/Awaitable/Policy della 0.3, AgentServer e il Domain GAM. Restano da dimostrare tre cose:
- che resti un solo confine per ogni conseguenza;
- che il codice dell'host diminuisca davvero, contando anche il setup GAM (genesis, mandati, Surface, executor, broker), che la proposta omette dagli esempi;
- che l'estrazione del kernel costi meno che riportare nella 0.4 le funzioni mancanti.

**È più semplice del solo aggiustamento al return della 0.3?** No. La sola Fase 1 elimina gran parte del ciclo manuale di `Freelance.Spectre.Turn` (dettagli al problema 4). Il resto della proposta serve a GAM, non all'ergonomia, ed è giusto presentarlo come tale.

**La mia raccomandazione:**
1. Fare subito la Fase 1 sulla 0.3: è utile in ogni scenario.
2. Prima di impegnarsi su AgentServer, fare uno **spike a tempo limitato** che confronti due strade sullo stesso caso (la cancellazione): estrarre il kernel sotto la 0.3, oppure riportare nella 0.4 coesistenza locale+LLM, arbitratore e raccolta online.
3. Separare la revisione dei nomi (Appendice A) dall'architettura.

---

## 2. Problemi in ordine di gravità

### Critici

**1. Nel caso pilota l'Act governerebbe un no-op; l'effetto reale passa da più porte laterali.** *(Verificato nel codice.)*

Cosa ho trovato:
- `Client.Actions.delete_my_account/1` restituisce soltanto `{:ok, %{user: client}}` (`freelance/lib/freelance/spectre/client/actions.ex:208`).
- L'anonimizzazione avviene in `SideEffects.after_delivery/2` (`side_effects.ex:13-18`).
- Quell'hook è chiamato da `Turn.run_after_delivery_hooks` (`turn.ex:483`, `turn.ex:847-863`) subito dopo `Delivery.action_result` → `send_text` → `save_outbound`. Questa catena aggiorna lo stato e **accoda** il messaggio. Lo dice il moduledoc stesso (`delivery.ex:1-7`): la conferma di consegna appartiene a `Freelance.Messaging`. Quindi oggi `on: :delivered` scatta all'accodamento, non alla consegna confermata.
- Altri percorsi di anonimizzazione, tutti fuori da qualsiasi gate:
  - `decline_pending_consent` (`turn.ex:120`);
  - `deliver_policy_rejected` per `:rejected_terms` (`turn.ex:517`);
  - l'hook per `decline_terms` (`side_effects.ex:20-24`).
- La policy `:delete_account` ha `accept(:confirmed_delete_account, [])` e `reject(:cancel_delete_account, [])` (`client/agent.ex:82-83`). `Spectre.Policy.Matcher.match_branch/2` con una lista di regex vuota non trova mai corrispondenze (`policy/matcher.ex:35-41`). `Turn.Policy.satisfied_resolution/2` risolve solo `:terms` (`turn/policy.ex:49-57`). `otherwise ask:` chiama il modello senza planning (`runner.ex:182-192`). Ne segue che, da quanto ho letto, una risposta come «sì» non può accettare la cancellazione: dopo 3 tentativi la policy la annulla. Non ho trovato test di delete-account in `freelance/test`. Non ho eseguito nulla: può esistere un percorso che non ho visto.

Conseguenza: se si dichiara governato `delete_my_account` così com'è, il ledger registra un Act su un'operazione vuota. La conseguenza vera (cancellare dati personali) resta raggiungibile da almeno quattro percorsi non mediati. È il caso che il manifesto chiama «side door»: *«different paths must not be able to obtain the same consequence while avoiding the same official decision»*.

Correzione minima:
- Una sola classe governata per l'erasure (per esempio `account.anonymize`, collegata a `data.erase` dove applicabile) con un executor reale.
- I quattro percorsi diventano proposte di quella classe.
- Va presa una decisione esplicita sull'ordine: anonimizzare dopo la **consegna confermata** del messaggio di conferma (due conseguenze con dipendenza), oppure anonimizzare prima e poi inviare un messaggio che non contiene dati personali.
- Il pilota va **progettato**, non migrato: oggi non c'è una baseline funzionante da preservare.

**2. Il kernel 0.4 presuppone che l'input diventi Evidence nel ledger; la proposta non definisce il ponte.** *(Verificato in parte.)*

Cosa ho trovato:
- `Spectre.Domain.Command.Input` dichiara di convertire *«application input into durable Evidence and sealed Mind Turns»* (`lib/spectre/core/domain/command/input.ex:1-9`). `finish_turn` e `continue_turn` registrano Evidence e sigillano il Turn con il segreto del Domain (`:42-73`).
- `Sequencer` usa `Mind.Turn`. `Surface` dipende da `Spectre.Agent.Verification` (`core/surface.ex:14`).
- Il legame con la Presentation scorpora le `approval_evidence_refs` dal Candidate (`core/candidate.ex:153-172`). Il consenso è quindi Evidence registrata, non un'etichetta di una policy conversazionale.

Conseguenza: §5.6, §8 (passo 7) e §14 trattano il kernel come se ricevesse Candidates «a partire da operazioni registrate e contesto autenticato». Mancano tre cose:
- come la richiesta dell'utente e la sua risposta di consenso entrino nel ledger;
- se lo faccia ogni messaggio o solo quelli pertinenti;
- chi sigilla il Turn.

Se ogni messaggio diventa Evidence, la proiezione in memoria (limite dichiarato in `docs/capabilities.md`) cresce con tutte le chat. Se invece solo alcuni messaggi diventano Evidence, serve un Ingress-bridge che dichiari provenienza e freschezza dell'input preso dal checkpoint locale. Le dipendenze `Mind` / `Agent.Verification` vanno inoltre spezzate o portate con il kernel. La Fase 4 è sottostimata.

Correzione minima: aggiungere alla §18 la decisione «politica di registrazione delle Evidence». Per il pilota propongo: registrare come Evidence scoped solo gli input che fondano una proposta governata e le risposte alla Presentation, attraverso un Ingress adapter dell'AgentServer. Classificazione e chat ordinaria restano fuori.

### Alti

**3. Rischio concreto di ricreare Instance, con callback divise su due moduli.**

`Spectre.Instance` nella 0.3 conta 1618 righe. AgentServer riceve: input, reducer, continuazioni, worker, stream, fallback, coordinamento del learning, dialogo di policy, checkpoint, fencing e recovery. A questo si aggiungono 7 callback.

Due problemi di forma:
- **Divisione del comportamento.** `on_result: :deleted` si dichiara nell'Agent, ma `handle_result(:deleted, …)` vive nel modulo server. Per capire un percorso bisogna leggere due file, contro l'obiettivo dichiarato al punto 1 della §3.
- **Duplicati.** `handle_classify` e `handle_generate` duplicano i behaviour degli adapter che la stessa Appendice dichiara (`classifier :local, Module`, `model …`). `handle_proposal` duplica `before_action`, già presente nella 0.3. `handle_turn` duplica `pre_route_handler`.

Correzione: vedi §3 di questo rapporto. Callback applicative nel modulo Agent. AgentServer è un processo del framework, non un behaviour da implementare.

**4. Il risparmio di codice host atteso è in buona parte ottenibile senza AgentServer; un'altra parte non verrà da AgentServer.** *(Stima mia sulla lettura di `turn.ex`, non una misura.)*

Le 885 righe di `turn.ex` si dividono grosso modo in:
- **Ciclo decisionale manuale:** `dispatch_decision` → `execute_pending` → `Spectre.execute` → `SpectreTurn.from_result` → `deliver_turn` ricorsivo (`turn.ex:200-322`), più `resolve_satisfied_policy`. La Fase 1 lo elimina.
- **Doppio routing:** quando il planning fallisce, l'host chiama di nuovo `Spectre.Router.evaluate` (`turn.ex:159-163`), con possibile seconda chiamata al classifier LLM, e fa match solo su `{:ok, receipt}`. Causa: l'errore restituito da `Spectre.turn` perde la route. Basta far portare all'errore la route già scelta (patch piccola).
- **Euristiche di sicurezza dell'output:** `internal_leak?`, `assistant_self_consent?`, `visible_refusal?` (`turn.ex:793-845`). Sono sintomi di planner/sanitizer che lasciano trapelare AL o testo di controllo. Appartengono a `reply_sanitizer` e alla validazione del planner, non ad AgentServer.
- **Regole di prodotto** (`premature_project_creation?`, `active_project_creation_conflict?`, mismatch dei ruoli): candidati naturali per un guard pre-proposta.
- **Consenso ai termini gestito interamente dall'host** prima di Spectre (`turn.ex:94-126`, `turn/policy.ex:14-33`, tramite `working_memory`).

Correzione: la §17 misura «righe di Turn». Va scomposta in queste categorie, e va dichiarato che la terza e la quinta richiedono interventi diversi da AgentServer.

**5. Il vocabolario degli esiti nell'esempio fonde distinzioni che il manifesto impone.**

`handle_result(:deleted, %{status: :done | :refused | :unclear})` con un catch-all «non confermata» (§7, A.11) mescola Decision ed Outcome:
- rifiuto;
- «non determinabile»;
- fuori vocabolario;
- pendente;
- fallimento;
- nessun effetto accertato;
- ambiguo.

Il manifesto lo vieta esplicitamente: *«"I cannot determine it" does not mean "it is forbidden"… "outside my vocabulary" does not mean "I evaluated and rejected it"»*. La §9 elenca 10 stati, ma l'esempio ne usa 3.

Correzione: un risultato tipizzato con due campi distinti, `decision` (`:admitted | :refused | :undeterminable | :unrecognized`) e `outcome` (`:pending | :succeeded | :failed | :no_effect | :ambiguous`). Il default di `super` non deve mai produrre testo di successo.

**6. Perimetro GAM: lettura corretta, ma mancano due obblighi del manifesto.**

Corretto:
- *«"Everything" does not mean every computation… It means every transition that the system wants to declare governed»*. Tenere classificazione, embedding e planning fuori dall'ammissione ordinaria è una **scelta di superficie** legittima, non una violazione della legge.
- La §2.3 (una divulgazione dichiarata governata resta tale anche se passa da un provider cognitivo) riprende fedelmente *«A derivative retains the constraints of the sources»*.

Cosa manca:
- **(a) Dichiarazione pubblica di ciò che resta fuori.** Il manifesto chiede che *«an honest promise must state which consequences it includes»*. Mandare a OpenRouter il testo dell'utente e la cronologia recente (il classifier riceve `recent_chat`, vedi ROUTING.md) è una divulgazione a terzi. Usare il modello è un consumo. Nel profilo proposto entrambe sono **non governate**. Va scritto nella HostProfile e nella documentazione del pilota, non solo omesso dagli esempi. È una scelta, non un errore, ma deve essere visibile.
- **(b) La richiesta di consenso è essa stessa una conseguenza governata.** Il manifesto elenca tra le transizioni governate *«a presentation used to obtain consent»*. In A.8 la policy usa `request(:confirm_delete_account)` e propone `otherwise do reason(:prompt) end`. Se l'operazione richiede consenso, ogni testo che sollecita la decisione (richiesta e ri-chieste) deve essere materiale di una Presentation legato al Candidate. Un `reason` generato dal modello non può fare da ri-chiesta di consenso. Per le policy che proteggono operazioni governate con consenso, la DSL deve accettare solo template deterministici legati alla Presentation.

**7. Le continuazioni durevoli non hanno un meccanismo di risveglio.**

Gli Outcome tardivi arrivano al Domain (§10.3). Ma AgentServer ha `idle_timeout` e può essere terminato. La proposta non dice chi riattiva il server giusto quando arriva una ricevuta tardiva: serve almeno un indice scope/correlation → identità dell'agente, più una sottoscrizione o un dispatcher. Senza questo, `on_result` funziona solo se il server è ancora vivo.

Correzione: un dispatcher degli esiti (servizio dello Stack) che avvia o recupera l'AgentServer per identità e consegna l'esito. È una decisione da aggiungere alla §18.

### Medi

**8. Non è specificato dove girano le callback utente.** «Il reducer separa transizioni da I/O» vale per il framework. Ma `run(:prepare_delete)` e i guard leggono il DB (`Projects.active_project_exists?`). Solo `handle_classify` viene dichiarato in un worker. Propongo che tutte le callback applicative girino in task con timeout, come già fa `Call.run` nella 0.3 (`runner.ex:356-364`), e che il reducer applichi lo Step restituito con fencing.

**9. La concorrenza dell'input è elencata, non definita.** La §6.5 elenca categorie, ma non dice cosa succede a un secondo messaggio mentre il primo è in classificazione LLM: va accodato, sostituisce il primo, o viene rifiutato? La «mailbox limitata» non è una semantica.

**10. Senza la verifica degli esempi, la raccolta online oggi non porta benefici a `freelance`.** Gli esempi online sono salvati con `verified?: false` (`arbitrate.ex:396`) ed esclusi dai lookup (`learned/online.ex:133-134`). In `freelance` non ho trovato né `verify` né `include_unverified`. Quindi i molti `learn: true` di `client/agent.ex` accumulano righe mai usate nel routing. Conservare il comportamento va bene, ma la promessa «ridurre chiamate LLM» (§11.2) richiede un percorso di verifica che la proposta rifiuta di imporre. Va detto chiaramente.

**11. La ricerca quantizzata di Vettore non è sublineare.** `do_quantized_search` carica tutti gli embedding con `store_mod.all/1` prima della selezione Hamming (`vettore/lib/vettore/collection.ex:279`). Con dataset di intenti di migliaia di righe, Flat è già sufficiente. Fase 7: rimandare.

**12. Il preview in streaming con il planner dipende da un prerequisito esterno.** `Spectre.Kinetic.Planner.incremental_cleaner?/0` restituisce `false` (`spectre_kinetic/lib/spectre/kinetic/planner.ex:113`). La proposta lo riconosce. Ma la Fase 8 lo tratta come un adattamento, mentre richiede un parser AL incrementale con la stessa invariante a senso unico del sanitizer 0.3. È un progetto a sé: fuori dal primo ciclo.

### Bassi

**13. L'Appendice A propone circa 80 rinomine e ~17 rimappature di opzioni della cache.** Tutte rinomine senza guadagno funzionale, che aumentano il costo di migrazione e confondono la revisione architetturale. Vanno in una RFC separata, successiva al pilota.

**14. Contraddizione interna sul Router.** La §5.3 sospende il routing quando serve classificazione, ma il Router 0.3 chiama il classifier LLM dentro l'arbitratore (`{:llm, arbitration}`). Trasformarlo in una sospensione con ripresa cambia il contratto degli arbitratori custom. Va dichiarato come cambio semantico, non come refactoring.

---

## 3. Confini e callback

| Componente | Cosa deve possedere | Cosa togliere |
|---|---|---|
| **Stack** | Package, manifest, risorse, binding degli adapter (classifier, model, embedding, dataset) | — |
| **Agent** (modulo applicativo) | DSL **e** callback applicative: funzioni `run`, `handle_result/3`, `handle_fallback/2`, guard pre-proposta | Il modulo `server:` separato come posto predefinito delle callback |
| **AgentServer** | Processo del framework: mailbox, serializzazione, fencing, worker, checkpoint, dispatcher degli esiti | Il ruolo di behaviour applicativo da implementare |
| **Reducer** | Transizioni pure `(stato, evento) → (stato, comandi)` | — |
| **Router** | Evidenze, arbitraggio, esito tipizzato | Le chiamate remote coordinate (passano ai comandi del reducer) |
| **Adapter behaviour** | `classify`, `generate`/`complete`, `embed`, `lookup` | `handle_classify` / `handle_generate` sul server |
| **GAM Domain** | Ledger, Evidence, ammissione, Outcome, Duty | Qualsiasi copia nell'AgentServer |

Callback applicative davvero necessarie: **3**.
- `handle_result/3`, ripresa tipizzata;
- `handle_fallback/2`;
- un solo guard pre-proposta (`before_action` della 0.3 compilato in `handle_proposal`; scegliere un solo nome).

`handle_turn` resta un escape hatch, già coperto da `pre_route_handler`. `handle_stream`: rimandare.

Analogia: Phoenix LiveView mette `mount` e `handle_event` nello stesso modulo che dichiara la vista. Il processo è del framework.

Il rischio Instance si riduce se:
- il modulo GenServer resta sotto una soglia fissata (per esempio «nessuna logica di dominio, solo dispatch reducer/worker»);
- il reducer ha test di proprietà indipendenti;
- il coordinamento di learning, stream e policy vive in moduli-servizio con proprio stato. Il caso più delicato sono le sessioni di stream: oggi appartengono a Instance e hanno budget, epoch e ricevute (STREAMING_INFERENCE.md).

---

## 4. DSL e opzioni

**Rinomine utili:**
- `learn` → `collect_intent`: corregge un'aspettativa sbagliata.
- `embedding: [...]` → `semantic_examples`.
- `:classifier` → `:local_classifier`.
- `via` della route → `match_with` (visibilità e ordine erano confusi).
- `turn_handler` → `pre_route_handler`.
- `then:` → `on_result`.

**Superflue per ora:** `semantic_cache` → `intent_dataset` con tutta la tabella A.6, `state` → `state_store`, `history summary:` → `summarizer:`, le rinomine Work/Vigil/Operation, le proposte ai package (A.10). Meglio alias e deprecazioni dopo il pilota.

**Semantiche ancora ambigue:**
- `on_result:` atomo nell'Agent, implementazione nel server (vedi sopra).
- `fallback :no_match` contro `on :UNKNOWN` contro `on_no_decision: :clarify`: tre meccanismi per «non ho capito». La proposta li distingue a parole, ma senza una tabella di precedenza compilata, con esempio, il developer li confonderà.
- `defaults:` del flow ereditato nei flow annidati, mentre «le liste sostituiscono la lista ereditata»: `match_with` in `defaults` sostituisce o interseca il `match_with` della route?
- `policy` che protegge un'operazione con consenso GAM: quali forme di `otherwise` sono ammesse (problema 6b)?
- `protect` senza classe GAM dichiarata: errore di compilazione? La §2.2 dice «superficie chiusa», ma l'esempio omette tutto.

**Esempio più compatto.** *(API inventate, marcate con `# PROPOSTA`.)*

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, prompt_root: "priv/support/prompts"

  router strategies: [:regex, :semantic_cache, :local_classifier, :llm_classifier]

  actions MyApp.AccountActions
  # PROPOSTA: la classe GAM è dichiarata accanto all'azione, verificata contro la Surface dell'host
  governed :delete_my_account, class: "account.anonymize", consent: :confirm_delete

  flow :support do
    on :DELETE_ACCOUNT, match_with: [:local_classifier, :llm_classifier] do
      run :prepare_delete
    end
  end

  # PROPOSTA: solo template deterministici ammessi, perché protegge un consenso governato
  policy :confirm_delete do
    request :confirm_delete_account
    accept :confirmed, regex: ~r/^\s*confermo\b/i
    reject :cancelled, regex: ~r/^\s*annulla\b/i
    otherwise reply: :please_confirm_or_cancel
    attempts 3, on_exhausted: :cancel_pending
  end

  def prepare_delete(_input, ctx),
    do: {:action, :delete_my_account, %{account_id: ctx.auth.account_id}, on_result: :deleted}

  # PROPOSTA: callback nello stesso modulo; risultato tipizzato con decision e outcome distinti
  def handle_result(:deleted, %{decision: :admitted, outcome: :succeeded}, _ctx), do: {:reply, :account_deleted}
  def handle_result(:deleted, %{decision: :refused}, _ctx), do: {:reply, :deletion_not_permitted}
  def handle_result(:deleted, %{outcome: o}, _ctx) when o in [:pending, :ambiguous], do: {:reply, :deletion_under_verification}
  def handle_result(op, res, ctx), do: super(op, res, ctx)
end
```

---

## 5. Confronto delle alternative

| | Patch minima 0.3 | Estrazione progressiva AgentServer (proposta) | Percorso 0.4 + ripristino funzioni |
|---|---|---|---|
| Contenuto | Step + avanzamento automatico in `Spectre.turn`; errori con la route; `after_action :delivered` su conferma reale; guard pre-proposta | Fasi 1-9 | Kernel 0.4 così com'è; si riportano coesistenza locale+LLM, arbitratore 0.3, raccolta online, training, Stack installabile |
| GAM | No | Sì, con ponte Evidence da progettare (problema 2) | Sì, nativo; Ingress e Mind già integrati |
| Rischio maggiore | Nessuna governance | Due lifecycle autorevoli durante la transizione; nuovo Instance | Lavoro di porting delle funzioni sottostimato; authoring 0.4 meno leggibile |
| Indizi verificati | Il ciclo manuale di `turn.ex:200-322` scompare | Kernel = 204 moduli in `core/`, accoppiati a Mind e `Agent.Verification` | La restrizione locale/LLM è un singolo ramo `cond` (`agents/agent/wiring.ex:93-95`); semantic cache e adapter Vettore esistono già nella 0.4 |

Non posso dire, senza misurare, quale fra la seconda e la terza costi meno. La terza colonna è sottovalutata dalla proposta: alcune «perdite» della 0.4 sono restrizioni locali, non lacune strutturali. Per questo raccomando lo spike comparativo sulla cancellazione, con un unico criterio: test end-to-end verdi e righe di codice host scritte, separate in coordinamento e regole di prodotto.

---

## 6. Prima vertical slice per `freelance`

**Slice 0, senza GAM: Fase 1 sulla 0.3.**
- Step uniformi e avanzamento automatico.
- L'errore di `Spectre.turn` porta la route (elimina `turn.ex:159-163`).
- Gate:
  - prezzi durante la raccolta del brief senza perdere i dati;
  - il dettaglio richiesto riprende il percorso giusto;
  - nessun doppio routing o recall (contatore delle chiamate al classifier);
  - `client/project_intake_test` e `agent_routing_test` invariati.

**Slice 1, con GAM: «erasure dell'account».** Ordine d'implementazione:
1. Decidere l'ordine fra erasure e conferma, e la classe unica (domanda bloccante 1).
2. Host GAM minimo: genesis, mandato radice per l'utente sul proprio account, Surface con una classe, executor che chiama `Accounts.anonymize_user_data`, broker passthrough.
3. Ingress-bridge: la richiesta dell'utente e la risposta alla Presentation diventano Evidence scoped. Nient'altro.
4. `run(:prepare_delete)` → proposta. Presentation deterministica. Correggere i matcher vuoti.
5. **Tutti e quattro** i percorsi di anonimizzazione convertiti in proposte della stessa classe (`turn.ex:120`, `turn.ex:517`, i due hook).
6. Dispatcher degli esiti → `handle_result`.

Gate di test:
- un testo che contiene «accetto» generato dal modello non vale come consenso;
- una domanda durante il consenso non lo chiude;
- una domanda sui prezzi durante il consenso riceve risposta e il consenso resta pendente;
- crash dopo l'Attempt e prima dell'Outcome → esito ambiguo e Duty aperto, nessuna riesecuzione al riavvio;
- crash della continuazione dopo il successo → nessuna seconda anonimizzazione;
- un enqueue non fa scattare l'erasure (se si sceglie la variante «dopo conferma»);
- un test statico o di grep che nessun altro modulo chiami `anonymize_user_data` fuori dall'executor.

**Da rimandare:**
- streaming delle proposte e preview (Fase 8);
- rinomina IntentDataset e Appendice A;
- Vettore quantizzato;
- Work, Vigil, Directive, Pulse, Morph;
- migrazione dei checkpoint 0.3;
- `handle_stream`, `handle_generate` e `handle_classify` personalizzati;
- `create_project` con il consenso ai termini (dopo la domanda bloccante 4).

---

## 7. Domande bloccanti per l'autore

1. **Ordine dell'erasure:** anonimizzare dopo la consegna *confermata* del messaggio, o prima con un messaggio privo di dati personali? Il rifiuto dei termini e la cancellazione dell'account sono la stessa classe?
2. **Registrazione delle Evidence:** ogni messaggio entra nel ledger, o solo gli input che fondano proposte governate e le risposte di consenso?
3. **Dove vivono le callback applicative:** nel modulo Agent (raccomandato) o in un modulo server separato?
4. **Accettazione dei termini:** è un consenso per singola occorrenza (Presentation) o una Condition sostenuta dall'Evidence «termini accettati» sull'utente?
5. **Dichiarazione del perimetro:** si accetta di dichiarare pubblicamente, nel pilota, che la divulgazione della chat ai provider LLM e il consumo d'inferenza sono fuori superficie?
6. **Cosa si elimina della 0.3** per le classi governate (lifecycle Effect/Awaitable, retry/reconcile delle Operation, ricevute), e in quale fase? Senza questa lista, il rischio di «due autorità» resta aperto.
7. **Spike comparativo:** si accetta di farlo prima della Fase 2?
