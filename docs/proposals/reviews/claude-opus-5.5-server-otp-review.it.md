# Seconda revisione: `Spectre.Server` come GenServer estensibile

Ho lavorato in sola lettura: non ho eseguito test, compilazioni o processi e non ho modificato file. Le evidenze sono marcate **[V]** quando le ho verificate nel codice, **[I]** quando sono inferenze e **[P]** quando sono proposte. Le API indicate con `# PROPOSTA` non esistono.

**Cosa ho controllato in questo giro:**
- `Spectre.Instance` 0.4 (`lib/spectre/agents/instance.ex`, `instance/operation.ex`);
- i callback `Spectre.Agent` 0.4 (`agents/agent.ex`);
- la semantica del consenso 0.4 (`core/presentation/approval.ex`, `lib/spectre.ex:415-479`);
- la mappa dei `handle_info` di `Spectre.Instance` 0.3 (`/tmp/spectre-034-architecture-audit/lib/spectre/instance.ex`).

Ho ripreso senza rileggerli i rilievi su `freelance` già verificati nella prima review.

---

## 1. Verdetto

**La variante funziona bene come architettura OTP, a una condizione: il processo deve appartenere al framework, che delega a `SupportServer` sia i callback OTP standard sia quelli Spectre.** È lo stesso schema di `Phoenix.Channel`, `Phoenix.LiveView`, GenStage e Broadway. Il modulo applicativo non diventa il modulo del GenServer: è il modulo di callback di un processo che vede per primo i propri messaggi.

Se invece `use Spectre.Server` iniettasse `handle_info` e compagnia come funzioni `defoverridable` dentro un modulo che è il GenServer, basterebbe un `def handle_info(_, s), do: {:noreply, s}` scritto dal developer per bloccare il runtime senza alcun errore. Quella soluzione la sconsiglio.

**Cosa cambia rispetto alla prima review:**

| Prima review | Ora |
|---|---|
| Callback applicative nel modulo Agent (raccomandazione principale) | **Ritirata.** La separazione Agent/Server è legittima. L'analogia con LiveView che avevo usato in realtà la sostiene: dichiarazioni in un modulo (come il Router Phoenix), comportamento in un altro (la LiveView), processo del framework |
| «AgentServer non è un behaviour da implementare» | **Rivista.** È un behaviour, con callback che rispecchiano quelli OTP e un processo del framework che li delega |
| Problema 8: «tutte le callback applicative girino in task con timeout» | **Rovesciata.** I callback OTP *devono* girare nel processo, altrimenti non sono callback OTP. Anche i callback Spectre conviene eseguirli nel processo: devono restituire comandi in fretta, mentre il lavoro lento diventa un comando eseguito da worker. Mescolare worker con snapshot (modello 0.4) e `handle_info` nel processo produce stato obsoleto (problema 3) |
| Problema 6b: la Presentation è una conseguenza governata | **Confermato e rafforzato dal codice** (§5) |
| Rilievi su freelance (side door multiple, Evidence ingress, enqueue ≠ consegna, risveglio) | **Restano tutti validi.** Il risveglio diventa parte del contratto (§3.7) |

**Prima di dichiararla «più semplice» va dimostrato** che il processo resti piccolo. Sotto c'è un indizio, non una prova.

**Indizio [V]:** `Spectre.Instance` 0.4 contiene già quasi tutto lo scheletro necessario in circa 650 righe, API incluse:
- `trap_exit` (`instance.ex:246`);
- monitor del Domain (`:250`, `:376-381`);
- un solo job alla volta in `Task.async` con uno snapshot (`:439-469`);
- una coda limitata `max_pending_operations` (`:427-437`);
- ticket legati a `instance_ref` e `revision` (`:318`);
- reply differite (`:363-374`).

**Cosa gli manca:** la delega. Oggi `handle_cast(_)` e `handle_info(_)` scartano tutto (`:360`, `:414`).

`Spectre.Instance` 0.3, invece, multiplexa più di 25 tipi di messaggio interni con tag `{:spectre, ...}` più un catch-all (`instance.ex:1491-1759`) **[V]**. Non è una base da estendere.

---

## 2. Risposte puntuali

### 2.1 È buona architettura OTP? Qual è la strada più piccola?

Sì, con tre meccanismi e niente di più:

1. **Delega dopo intercettazione.** Il processo `Spectre.Server.Runtime` gestisce prima ciò che gli appartiene, poi chiama `SupportServer.handle_*`.
2. **Proprietà per riferimento.** Il runtime riconosce i propri messaggi dalle reference che ha creato (task, monitor, timer, sessioni di stream), non da prefissi di tupla.
3. **Ctx con coda di comandi.** I callback ricevono una vista (`%Ctx{}`) e restituiscono assigns e comandi. Il runtime non rilegge mai i propri campi da ciò che il developer restituisce.

Strada minima **[I/P]**:
- scrivere un nuovo modulo processo sul modello di `Spectre.Instance` 0.4, non sopra Instance 0.3;
- riusare Router, inference adapter e StreamSession 0.3 come librerie chiamate dai comandi worker;
- lasciare Instance 0.3 per gli agenti non migrati;
- non far girare due proprietari per la stessa identità.

### 2.2 Composizione: confronto

| | A. Il modulo applicativo è il GenServer (`use` + `defoverridable`) | B. Il GenServer del framework delega a `SupportServer` (un solo processo) |
|---|---|---|
| Chi vede per primo un messaggio | Il developer. Con `defoverridable`, una `handle_info/2` definita dall'utente *sostituisce* quella iniettata; il runtime riceve il messaggio solo se l'utente chiama `super` | Il runtime, sempre |
| Catch-all del developer | Blocca task, monitor, timer e terminali di stream. Errore silenzioso | Innocuo: il developer vede solo i messaggi che non appartengono al runtime |
| Stato | Il developer riceve e restituisce lo struct completo, compresi i campi del runtime | Il developer riceve un `%Ctx{}`; il runtime riprende solo `assigns` e i comandi |
| `GenServer.start_link(SupportServer, …)` | Funziona | No: si usa `SupportServer.start_link/1` generato |
| `:sys.get_state`, `$initial_call` | Mostrano il modulo applicativo | Mostrano lo struct del runtime (servono `format_status` con redazione e `Process.set_label`) |
| `code_change` | Diretto | `gen_server` chiama `code_change` del modulo di callback reale, cioè il runtime, che lo delega. Va testato con `:sys.change_code` **[I]** |
| Cosa limita | L'integrità del runtime, che dipende dalla disciplina del developer | Il developer non intercetta mai i messaggi del runtime (voluto). Il `timeout` intero viene rifiutato (§2.11) |

**Scelgo B.** Le due opzioni non sono equivalenti: A limita la sicurezza del runtime, B limita alcune introspezioni OTP. Scarto un'eventuale «terza via» con due processi (sidecar applicativo più runtime): duplicherebbe lo stato correlato e l'autore lo ha escluso.

### 2.3 Che stato ricevono i callback

Tutti i callback ricevono `%Spectre.Server.Ctx{}` **[P]**:

| Campo | Chi lo scrive | Il runtime lo rilegge? |
|---|---|---|
| `assigns` | Il developer (`assign/3` o aggiornamento diretto) | Sì: è lo stato applicativo |
| `identity` (principal e account autenticati dallo Scope) | Il runtime | No |
| `interaction` (`nil` oppure `%{ref, origin_input_ref, status}`) | Il runtime | No |
| `pending` (riepiloghi e id in primo piano) | Il runtime | No |
| `__dispatch__` (token del dispatch corrente) | Il runtime | Solo per verificare l'origine del ctx |
| `__commands__` | Gli helper | Sì, se il token corrisponde al dispatch corrente |

**Restano nel runtime e non entrano nel ctx:** continuazioni, task ref, monitor, Presentation, correlazioni, sessioni di stream, contatori, Scope e sigilli.

**Cosa garantisce davvero:**
- un ctx modificato per errore, o salvato e restituito in un dispatch successivo, non corrompe lo stato del runtime: il runtime ignora i campi che non rilegge e scarta i comandi se il token non corrisponde;
- **non è isolamento.** Lo stesso processo può chiamare moduli interni, leggere il process dictionary o usare `:sys.replace_state`. Qualunque codice sullo stesso nodo può inviare messaggi. La garanzia è *protezione dagli errori applicativi*, non sicurezza contro codice fidato malevolo.

Una nota sull'esempio del brief: `%{account_id: ctx.assigns.account_id}` prende il soggetto della cancellazione da uno stato modificabile dall'applicazione. Deve venire da `ctx.identity`. Il kernel ricontrolla comunque contro il contesto autenticato, ma il builder non deve partire da un valore mutabile.

### 2.4 Ritorni esatti

**Callback OTP:** stessi ritorni di GenServer, con `%Ctx{}` al posto dello stato:
- `{:reply, r, ctx}`, `{:reply, r, ctx, :hibernate | {:continue, c}}`;
- `{:noreply, ctx}`, `{:noreply, ctx, :hibernate | {:continue, c}}`;
- `{:stop, reason, ctx}`, `{:stop, reason, r, ctx}`.

Il runtime avvolge `{:continue, c}` in `{:continue, {:app, c}}` e lo restituisce a `SupportServer.handle_continue(c, ctx)`. Le continue non passano dalla mailbox, quindi questo namespace non è falsificabile dall'esterno.

**Callback Spectre** (`handle_flow`, `handle_pending`, `handle_result`): restituiscono `%Ctx{}`. Regola: le funzioni Spectre restituiscono il ctx, i callback OTP restituiscono la tupla OTP.

**Come una callback OTP chiede un passo Spectre:** sì, basta una funzione che accoda un comando nel ctx, come `push_event/3` in LiveView. Niente `GenServer.call(self())`, che peraltro termina con `:calling_self`. Dopo il ritorno, il runtime:

1. verifica il token del dispatch;
2. prende gli `assigns`;
3. valida i comandi in ordine;
4. li applica (eventualmente avviando worker);
5. solo a quel punto restituisce la reply OTP.

Lo stato aggiornato e i comandi viaggiano nello stesso valore, quindi nessuno dei due può essere scartato separatamente.

**Correlazione con l'interazione:**
- un comando accodato dentro un callback Spectre eredita `interaction.ref` e `origin_input_ref`;
- un comando accodato in `handle_call/cast/info` è *staccato*: non può far avanzare l'interazione in primo piano né risolvere un'attesa, a meno di nominare esplicitamente una correlazione registrata prima (`resolve_await/3`, §3.1).

Ogni passo di un'interazione deve chiudersi con un comando che progredisce o termina: risposta, `generate`, `propose`, attesa, `no_response` o `route_current_input`. Altrimenti il runtime segnala `interaction_without_step` e passa al fallback.

**Rilievo ergonomico (non bloccante):** in un modulo che è anche GenServer, l'helper `reply(ctx, text)` («rispondi all'utente») e la tupla `{:reply, value, ctx}` («rispondi al chiamante OTP») si confondono facilmente. Suggerisco `respond/2` o `say/2`.

### 2.5 Messaggi da altri actor

Un messaggio Erlang non porta il mittente. Per il runtime, ciò che arriva a `handle_info` è un dato locale non autenticato, prodotto da codice fidato. Il runtime non lo interpreta mai come:

- **input utente:** entra solo dall'API pubblica `Spectre.Server.input/3`, con il contesto autenticato e l'Ingress. Solo gli input usati come base o come risposta di consenso diventano Evidence (decisione già aperta nella prima review);
- **consenso:** solo il percorso Presentation → show Act → Outcome riuscito → Evidence di risposta dal principal autenticato (§2.8);
- **ricevuta dell'executor:** solo il percorso del Domain (risultato dell'Attempt, `record_late_observation` con l'observer fisso, `lib/spectre.ex:486-496` **[V]**).

**Cosa possono fare le reference:** per le richieste correlate si registra un `ref` (meglio un alias di processo con `Process.monitor(pid, alias: :reply_demonitor)`) come attesa dell'interazione, con una scadenza. Questo protegge da risposte obsolete, duplicate o fuori interazione. Non autentica nulla: qualsiasi processo che conosca la ref può mandarla.

### 2.6 Chi intercetta `:DOWN`, risultati dei task, timeout e terminali stream

Il runtime, prima del developer, in base a una mappa di reference possedute:

| Messaggio | Al runtime se… | Altrimenti |
|---|---|---|
| `{ref, result}` | `ref` è un task del runtime | `handle_info` dell'app (i suoi `Task.async`) |
| `{:DOWN, ref, …}` | `ref` è un monitor del runtime | App |
| `{:EXIT, pid, r}` | `pid` è collegato dal runtime | App. Il default (vedi sotto) ferma il processo se `r` è anomalo |
| `{:"$spectre", ref, …}` (timer, stream, heartbeat) | `ref` posseduta e generazione corrente | **Scartato** con telemetria: né al runtime né all'app |
| Chiamate pubbliche Spectre (`{:"$spectre_call", …}`) | Sempre al runtime, poi validate (contesto sigillato) | — |

Distinguere per reference invece che per tag rende inefficaci le tuple costruite a mano, salvo che chi le costruisce conosca la ref. Codice sullo stesso nodo che ispeziona lo stato la conosce (§2.3).

**Conseguenza da documentare:** il runtime intercetta le uscite dei processi collegati (`trap_exit`), come già fa la 0.4 (`instance.ex:246`). I `spawn_link` dell'app non fanno più crashare il server per propagazione. Per preservare la semantica dei link, il `handle_info` di default converte un `:EXIT` anomalo non del runtime in `{:stop, reason, ctx}`.

### 2.7 Callback lente, chiamate ad actor e regole

**Regole proposte:**
1. Tutti i callback (OTP e Spectre) girano nel processo e devono restituire presto. Brevi letture dal DB sono accettabili, come nei `handle_event` di LiveView. Il lavoro lento diventa un comando: `async(ctx, tag, fun)`, `generate`, `classify`, `call_actor`. Il risultato torna come `handle_result(tag, …)` fenced per interazione e generazione.
2. `handle_call` resta sincrono. Il developer può differire la reply (`{:noreply, ctx}` più `GenServer.reply(from, x)` in un `handle_result` successivo). Il runtime non lo sposta mai in un worker.
3. Una chiamata sincrona verso un altro actor da un callback blocca il server. È ammessa, ma la documentazione deve segnalare il deadlock delle chiamate circolari (A chiama B, B chiama A, entrambi muoiono al timeout). L'helper `call_actor(ctx, server, msg, timeout:, on_result:)` **[P]** esegue la `GenServer.call` in un task: niente rientranza e nessun blocco.
4. Input concorrenti:
   - una sola interazione in primo piano;
   - un nuovo input mentre l'interazione è occupata (classificazione o generazione in corso) entra in una coda limitata (`max_pending_inputs`) e viene elaborato al prossimo punto stabile;
   - oltre il limite si risponde `{:error, :busy}`;
   - le interruzioni esplicite (cancellazione) scavalcano la coda.

   I messaggi non di input (`call/cast/info`) vengono elaborati subito anche durante un'interazione in attesa.
5. Limiti per interazione: passi, comandi per callback, re-routing per input (al massimo uno) e durata.

**Compromesso inevitabile:** con callback nel processo, un callback che blocca rallenta anche la ricezione dei risultati dei worker. I messaggi non si perdono: si accodano. La 0.4 manteneva reattive le letture durante handler lenti eseguendo gli handler in un worker. Questa variante rinuncia a quel vantaggio in cambio di un unico proprietario dello stato senza snapshot obsoleti.

### 2.8 `handle_pending` + classificazione + `handle_result`

**Cosa dice il codice 0.4 [V]:** l'approvazione è un grafo di Evidence `Presentation -> show Act -> successful Outcome -> response Evidence` (`approval.ex:10`). L'Evidence di risposta porta come `issuer_ref` il principal autenticato del `SubmissionContext` e i binding `presentation_ref`, `show_act_ref` e `recipient_ref` (`approval.ex:55-83`). Mostrare la Presentation è un Act mediato dall'executor (`lib/spectre.ex:451-476`). Una label prodotta dal classificatore non entra in questo grafo.

**Contratto minimo [P].** Bastano i tre callback più uno stato esplicito dell'attesa. Non servono altri callback: scadenza e sostituzione arrivano come `handle_result({:pending, id}, :expired | :superseded, ctx)`.

Stato dell'attesa, gestito dal runtime:

```text
%Pending{id, kind: :consent, candidate_digest, presentation_ref, show_act_ref,
         shown_at, expires_at, accept_rule,
         status: :foreground | :suspended | :expired | :resolved}
```

`confirm_pending(ctx, id)` lavora sull'**input d'origine della continuazione**. Il runtime salva `origin_input_ref` quando accoda `classify`, e lo restituisce in `handle_result`: non è mai «l'ultimo messaggio della chat». Il runtime verifica che:
1. l'attesa sia in primo piano, non scaduta e non già risolta;
2. l'input provenga dal principal destinatario e sia arrivato *dopo* l'Outcome riuscito dello show Act **corrente**;
3. l'input non sia già stato consumato da un'altra risoluzione;
4. il digest del Candidate non sia cambiato;
5. l'input soddisfi la `accept_rule` deterministica (regex o payload di un pulsante dell'UI).

Solo dopo registra l'Evidence di risposta tramite l'Ingress e sottomette. Il kernel rivaluta tutto (`validate_approval`).

**Una label LLM `:confirm` non è consenso.** Nella prima versione deve portare a una richiesta di conferma esplicita e deterministica. Le label `:reject`, `:clarify` e `:new_topic` possono invece venire dal classificatore: sbagliarle non rilascia potere. Al peggio annullano o sospendono.

**Dopo un cambio argomento:** l'attesa diventa `:suspended`. Un «sì» generico non può confermarla, perché non è in primo piano. `resume_pending(ctx, id)` produce una **nuova visualizzazione** (nuovo show Act, quindi nuovo `show_act_ref`): le risposte precedenti non valgono più. Un cambiamento materiale richiede un nuovo Candidate e una nuova Presentation.

**`:refused` non significa «chiedi conferma».** Se serve il consenso lo dice il contratto della classe nella Surface, *prima* della sottomissione, non il motivo di un rifiuto. Non ho verificato come la 0.4 segnali al proponente l'assenza di approvazione: va controllato prima di congelare i tipi di risultato.

**`protected: true`** nell'Agent vincola il routing:
- niente `collect_intent`;
- niente match dalla sola LLM, se si vuole;
- il runtime fallisce se il handler conclude con una risposta senza proposta né rinuncia esplicita.

La protezione vera sta nella classe di `delete_my_account`: si applica anche quando la stessa azione arriva da `generate(:understand, planning: true)`.

**Tipi di risultato:** l'esempio del brief usa `:done` e `{:outcome, %{status: :unclear}}`. Servono campi distinti (rilievo 5 della prima review):

```text
%OperationResult{consent: nil | :rejected | :expired | :superseded,
                 decision: nil | :admitted | :refused | :undeterminable | :unrecognized,
                 outcome: nil | :pending | :succeeded | :failed | :no_effect | :ambiguous}
```

Il `super` di default non deve mai produrre testo di successo. Analogamente `handle_flow(:unmatched, …)` va reso come `{:unrouted, :no_match | :ambiguous | {:classifier_error, e}}`: una sola clausola `{:unrouted, _}` cattura tutto, ma le distinzioni restano disponibili.

### 2.9 Actor esterni: conseguenza governata o coordinamento

- **Conseguenza dichiarata nella Surface** (addebito, cancellazione, invio governato): il Server chiama `propose/4`. L'executor registrato presso il broker è l'unico codice che parla con l'actor che produce l'effetto. Se il Server chiama direttamente `BillingActor.charge/1`, quella è una side door.
- **Coordinamento interno** (preventivo da un PricingActor, aggiornamento di presenza, invalidazione di cache): `call`, `cast` o `async` ordinari. Niente GAM e niente Act. Il lifecycle locale può essere tracciato con la telemetria.
- **Criterio unico:** la conseguenza sta nella superficie dichiarata? Se passi dati protetti a un actor che li divulga all'esterno, è una divulgazione governata anche se il messaggio è un `cast`.

**Tre livelli di protezione da non confondere:**

| Livello | Esempio | Cosa garantisce |
|---|---|---|
| Errori applicativi | Nessun helper diretto verso servizi privilegiati; check di Doctor/xref sui moduli executor; test di grep (prima review) | Che il percorso ovvio passi dal confine |
| Isolamento reale | L'actor privilegiato accetta solo capability rilasciate dal broker; credenziali solo nel processo o nodo dell'executor | Che il codice del Server *non possa* produrre l'effetto da solo |
| Responsabilità dell'host | Codice fidato sullo stesso BEAM con accesso alle credenziali | Nessuna garanzia della libreria; va dichiarato nella HostProfile |

### 2.10 Streaming

- La sessione di stream appartiene al runtime. I delta provvisori vanno direttamente al consumer, come nella 0.3. Heartbeat e terminali arrivano al runtime con una ref posseduta.
- Il developer vede solo `handle_result(tag, {:generated, %{text:, proposals:}})` *dopo* il consolidamento. Nessun `handle_stream` nella prima versione.
- Un terminale falso inviato da un altro processo: con il tag Spectre e una ref sconosciuta viene scartato; senza tag finisce all'app come messaggio qualsiasi.
- Le proposte del modello non vengono sottomesse automaticamente. Il `handle_result` di default le passa a `propose` con il consenso richiesto dalla classe, e il developer può sovrascriverlo. Una proposta costruita dall'app in `handle_info` non è «consolidata dal modello», ma attraversa lo stesso kernel. Bypassare il consolidamento cambia la provenienza, non l'ammissione.
- Il codice dell'host che spinge chunk su un proprio PubSub resta fuori dalla garanzia ed è responsabilità dell'host.

### 2.11 `init`, `terminate`, `code_change` e il resto

| Callback/feature | Prima versione | Note |
|---|---|---|
| `init(arg, ctx)` | Sì | Il runtime ripristina il checkpoint *prima*; l'app riceve gli assigns ripristinati. Ritorni: `{:ok, ctx}`, `{:ok, ctx, {:continue, c} \| :hibernate}`, `:ignore`, `{:stop, r}`. Nessun comando governato in `init` |
| `handle_continue` | Sì | Con namespace interno (§2.4) |
| `:hibernate` | Sì | Passa direttamente |
| `timeout` intero nei ritorni | **No**: errore esplicito | Il traffico interno del runtime lo riarmerebbe, quindi non sarebbe più la semantica GenServer. Alternativa: `Process.send_after` dell'app |
| `terminate(reason, ctx)` | Sì | L'app per prima, poi la pulizia del runtime (worker uccisi, reply in sospeso con errore). I comandi accodati in `terminate` vengono ignorati. Non è chiamata con `:kill` |
| `code_change` | Delega dei soli assigns | Lo struct del runtime non è aggiornabile a caldo fra versioni Spectre: serve un riavvio. Test con `:sys.change_code` se lo si dichiara |
| `format_status` | Sì, con redazione | Lo stato del runtime contiene contesto sigillato e reference: non deve finire nei crash report |
| Checkpoint | Assigns portabili | Pid e ref negli assigns non sopravvivono a un riavvio. Le attese su ref vengono ripristinate come scadute |

Con questa tabella si può dire onestamente «GenServer estensibile, con il timeout intero escluso e l'hot upgrade limitato agli assigns».

---

## 3. Contratto raccomandato

### 3.1 Esempio: messaggio da un altro actor

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server,                       # PROPOSTA
    agent: MyApp.SupportAgent,              # PROPOSTA: il binding sta qui (§6, decisione 2)
    prompt_root: "priv/support/prompts"

  def handle_flow({:support, :pricing}, _input, ctx) do
    ref = make_ref()
    MyApp.PricingActor.request_quote(self(), ref, ctx.identity.account_id)  # cast ordinario

    await_reply(ctx, ref, timeout: 3_000, on_result: :quote)  # PROPOSTA: registra la ref per questa interazione
  end

  # Risposta correlata: il runtime verifica che la ref sia registrata, l'interazione viva e non scaduta.
  def handle_info({:quote, ref, quote}, ctx),
    do: {:noreply, resolve_await(ctx, ref, {:ok, quote})}  # PROPOSTA

  # Coordinamento puro: niente GAM, niente interazione.
  def handle_info({:price_list_changed, version}, ctx),
    do: {:noreply, assign(ctx, :price_version, version)}

  # Il catch-all è innocuo: task, monitor e stream del runtime non arrivano mai qui.
  def handle_info(msg, ctx), do: super(msg, ctx)

  def handle_result(:quote, {:ok, quote}, ctx),
    do: generate(ctx, :pricing, assigns: %{quote: quote}, on_result: :pricing)  # PROPOSTA

  def handle_result(:quote, :timeout, ctx), do: respond(ctx, :pricing_unavailable)  # PROPOSTA

  def handle_result(:pricing, {:generated, response}, ctx), do: respond(ctx, response.text)
end
```

### 3.2 Esempio: flow → consenso → esito

```elixir
  def handle_flow({:support, :delete_account}, input, ctx) do
    propose(ctx, :delete_my_account, %{account_id: ctx.identity.account_id},   # PROPOSTA
      basis: [input],                         # l'input autenticato diventa Evidence via Ingress
      consent: [template: :confirm_delete_account,           # Presentation deterministica
                accept: ~r/^\s*confermo\b/iu],               # regola deterministica di accettazione
      on_result: :deleted)
  end

  # Raggiunto solo se esiste un'attesa in primo piano e l'input non è un'interruzione.
  def handle_pending(%{kind: :consent, id: id}, input, ctx) do
    classify(ctx, input,                                       # PROPOSTA: il runtime salva origin_input_ref
      choices: [:confirm, :reject, :clarify, :new_topic],
      on_result: {:consent, id})
  end

  # Il runtime applica accept_rule all'input d'origine; altrimenti chiede la conferma esplicita.
  def handle_result({:consent, id}, {:classified, :confirm}, ctx), do: confirm_pending(ctx, id)
  def handle_result({:consent, id}, {:classified, :reject}, ctx), do: reject_pending(ctx, id)
  def handle_result({:consent, id}, {:classified, :clarify}, ctx), do: explain_pending(ctx, id)
  def handle_result({:consent, id}, {:classified, :new_topic}, ctx),
    do: route_current_input(ctx, suspend: id)  # stesso input, nessuna nuova Evidence, un solo re-route

  def handle_result(:deleted, %{decision: :admitted, outcome: :succeeded}, ctx),
    do: respond(ctx, :account_deleted)
  def handle_result(:deleted, %{decision: :admitted, outcome: o}, ctx) when o in [:pending, :ambiguous],
    do: respond(ctx, :deletion_under_verification)
  def handle_result(:deleted, %{decision: d}, ctx) when d in [:refused, :undeterminable, :unrecognized],
    do: respond(ctx, :deletion_not_permitted)
  def handle_result(:deleted, %{consent: c}, ctx) when c in [:rejected, :expired],
    do: respond(ctx, :deletion_cancelled)
  def handle_result(op, result, ctx), do: super(op, result, ctx)  # default: mai testo di successo
end
```

Se `confirm_pending` riceve una label `:confirm` ma l'input d'origine non soddisfa `accept`, il runtime non conferma. Mantiene l'attesa e fa visualizzare il testo deterministico di ri-chiesta associato alla Presentation.

### 3.3 Risveglio per esiti tardivi (ripreso dalla prima review)

Un `OutcomeDispatcher`, servizio dello Stack **[P]**, indicizza `act_ref → (identità del server, continuazione)`. Quando arriva un esito tardivo, avvia o ritrova il server per identità e consegna `handle_result` una sola volta, in modo idempotente. Se la continuazione è andata persa (checkpoint perso), il runtime chiama `handle_result({:orphan, act_ref}, result, ctx)`, il cui default registra l'evento senza dichiarare successi.

---

## 4. Libertà applicativa e invarianti

| Libertà applicativa | Invarianti del runtime | Invarianti GAM (Domain/kernel) |
|---|---|---|
| `handle_call/cast/info/continue`, `init`, `terminate`, `code_change`, `format_status` con i ritorni OTP | Vede per primo i propri messaggi, riconosciuti per reference | Ammissione solo su un Candidate completo e sullo stato corrente |
| Assigns arbitrari | Rilegge solo `assigns` e i comandi con un token valido | Nessuno stato governato copiato nel processo |
| Monitor, task, link e actor propri | Gestisce i propri monitor e task; `:EXIT` anomali estranei → stop di default | — |
| Chiamate e cast verso altri actor; `async` | Una sola interazione in primo piano; coda di input limitata; limiti di passi | — |
| Classificazione, embedding, generazione e IntentDataset ovunque | Fencing dei risultati per interazione e generazione; nessuna promozione dei frammenti di stream | Cognizione fuori dall'ammissione ordinaria (va dichiarato nella HostProfile) |
| Testi, template, ri-chieste e chiarimenti | `confirm_pending` legato all'input d'origine, all'attesa in primo piano e alla regola deterministica | Consenso = Presentation → show Act → Outcome → Evidence di risposta del recipient |
| Scegliere quando proporre e con quale base | `basis` → Evidence via Ingress; nessun altro input diventa Evidence | Act registrato prima del rilascio della capacità; Attempt prima del broker |
| Gestire ogni esito in `handle_result` | Il default non dichiara mai un successo; consegna una sola volta | Outcome ambigui → Duty; nessun retry automatico |
| — | Nessuna API per inserire ricevute dell'executor | Ricevute solo dal percorso executor/observer del Domain |

---

## 5. Problemi prioritari

1. **Proprietà dei messaggi.** Con l'opzione A il primo catch-all rompe il runtime. *Correzione:* B più reference possedute. *Test:* catch-all nell'app.
2. **Riscrittura dello stato del runtime.** Se il runtime rilegge il ctx, il developer può alterare attese e continuazioni. *Correzione:* ctx come vista, token di dispatch, rilettura dei soli `assigns` e comandi.
3. **Snapshot obsoleti se si mescolano modelli.** Il modello 0.4 (handler in un worker con snapshot, `operation.ex:28-35`, `instance.ex:439-463`) non convive con `handle_info` nel processo: il worker restituisce assigns basati su uno snapshot superato. *Correzione:* tutti i callback nel processo, lavoro lento come comandi. È un cambiamento rispetto alla 0.4 e va presentato come tale.
4. **Consenso.** Una label non basta: va legata all'input d'origine, alla Presentation corrente e al nuovo show dopo una sospensione (§2.8). L'API del brief (`confirm_pending(ctx, id)` dopo la label) è sicura solo se il runtime applica quei controlli. Altrimenti è un consenso inventato.
5. **Side door tramite actor e la cancellazione in freelance** (prima review, problema 1). Ancora irrisolto e indipendente da questa variante: quattro percorsi di anonimizzazione fuori da qualsiasi confine.
6. **Ingresso delle Evidence ed enqueue ≠ consegna** (prima review): restano decisioni bloccanti per il pilota.

**Compromessi inevitabili:**
- un callback che blocca rallenta il runtime;
- nessun isolamento nello stesso BEAM;
- niente `timeout` intero;
- `:sys.get_state` mostra lo struct del runtime;
- `trap_exit` cambia la semantica dei link;
- hot upgrade limitato agli assigns;
- separare Agent e Server costa due file per percorso. Si attenua con un helper di test che esercita `handle_flow` per ogni route dichiarata (dry-run) e con `mix spectre.routes` che mostra le route non gestite **[P]**.

---

## 6. Prima vertical slice e test

**Slice:** `SupportAgent` più `SupportServer` con tre percorsi:
- pricing con un PricingActor;
- delete-account con consenso e un executor reale (il setup GAM minimo indicato nella prima review);
- `{:unrouted, _}` → `generate(:understand)`.

Più l'`OutcomeDispatcher`. Fuori dalla slice: streaming delle proposte, hot upgrade in produzione, migrazione dei checkpoint 0.3.

**Test specifici:**

**Messaggi e monitor**
1. Con un catch-all `handle_info(_, ctx)` nell'app, `generate` si completa, il `:DOWN` del Domain ferma il server e il terminale di stream viene elaborato.
2. L'app monitora un proprio processo e riceve solo il proprio `:DOWN`. Un `:DOWN` del runtime non arriva all'app. Un `{:"$spectre", ref_ignota, …}` viene scartato con telemetria.
3. Un `Task.async` dell'app consegna `{ref, result}` all'app e non al runtime.
4. Un `spawn_link` dell'app che crasha ferma il server (default); con un override dell'app si può ignorare.

**Stato e ritorni**
5. L'app modifica `ctx.pending`, oppure restituisce un ctx salvato da un dispatch precedente: lo stato del runtime non cambia e i comandi vengono scartati.
6. `{:continue, x}` dall'app arriva a `handle_continue` dell'app; le continue del runtime restano invisibili. `:hibernate` passa; un timeout intero produce un errore esplicito.
7. Un comando accodato in `handle_call` viene applicato insieme agli assigns aggiornati, e la reply arriva dopo la validazione.

**Concorrenza e actor**
8. Due input durante la classificazione: il secondo viene accodato ed elaborato dopo, quello oltre il limite riceve `:busy`. Una cancellazione esplicita interrompe.
9. L'actor non risponde: `handle_result(:quote, :timeout)`. Una risposta arrivata dopo la scadenza viene ignorata da `resolve_await` senza toccare l'interazione.
10. Una chiamata circolare A→B→A tramite `call_actor` non va in deadlock. Con una `GenServer.call` diretta si documenta il timeout.

**Consenso**
11. Un «sì» dopo un cambio argomento non conferma.
12. Una label `:confirm` su un input che non soddisfa `accept` non conferma.
13. Un «accetto» scritto dal modello non vale come consenso.
14. Una risposta di un altro principal viene rifiutata.
15. Un input arrivato prima dell'Outcome dello show viene rifiutato.
16. Un'attesa ripresa richiede un nuovo show; la risposta al vecchio show non vale.
17. Un cambiamento materiale invalida il consenso.
18. Due conferme concorrenti producono una sola sottomissione.

**Ricevute e crash**
19. Una «ricevuta» inviata come messaggio al server non registra alcun Outcome.
20. Un esito tardivo con server morto: il dispatcher lo riavvia e consegna una volta; una consegna duplicata non ha effetto.
21. Crash dopo l'Attempt e prima dell'Outcome: ambiguo, Duty aperto, nessuna riesecuzione.
22. Crash di `handle_result` dopo il successo: nessuna seconda cancellazione.
23. `terminate` dell'app chiamata allo shutdown del supervisor; i comandi accodati lì vengono ignorati.

**Hot upgrade (solo se dichiarato)**
24. `:sys.suspend` → `:sys.change_code(pid, Spectre.Server.Runtime, old, extra)` → `code_change` dell'app riceve gli assigns e lo struct del runtime resta invariato.

**Ripresi dalla prima review**
25. Test statico: nessun modulo fuori dall'executor chiama `anonymize_user_data`.
26. L'enqueue non attiva l'erasure (se si sceglie la variante «dopo la consegna confermata»).

---

## 7. Decisioni ancora aperte

1. **Consenso interpretato dal modello:** è mai ammesso, magari per classe o per HostProfile? Raccomando di no nella prima versione.
2. **Direzione del binding:** `Server → agent:` oppure `Agent → server:`? Raccomando la prima. L'Agent resta una dichiarazione pura e riusabile (per esempio da un server di test), la dipendenza di compilazione segue la logica «il comportamento dipende dalla dichiarazione» e il Server può validare i flow. Non è una questione cosmetica: incide sulle dipendenze e sulla validazione.
3. **Persistenza delle attese dopo un riavvio:** sopravvivono con scadenza o richiedono sempre un nuovo show?
4. **Input durante un'interazione occupata:** coda (raccomandata) o sostituzione?
5. **Comandi staccati da `handle_info`:** possono produrre messaggi in uscita verso l'utente? E quei messaggi sono consegne governate?
6. Dalla prima review, ancora bloccanti: politica di registrazione delle Evidence, ordine fra erasure e conferma, dichiarazione pubblica del perimetro cognitivo.

**Non bloccanti:** `Spectre.Server` contro `Spectre.AgentServer`; `reply` contro `respond`; dove dichiarare il catalogo delle azioni (nomi nell'Agent per Doctor e Surface, implementazione nel Server o nello Stack).
