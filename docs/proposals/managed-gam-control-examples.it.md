# AgentServer: automatico per default, manuale quando serve

> Documento storico: il successivo completamento elimina il selettore
> development/produzione e il collegamento GAM manuale in AgentServer.
> Per il contratto attuale e `Spectre.GAM.submit/4` vedere
> [GAM automatico](../MANAGED_GAM.md). I risultati di verifica qui sotto
> descrivono la revisione precedente.

Implementazione disponibile nel profilo gestito `authority: :development`; questa
proposta conserva anche le decisioni e le alternative discusse. Per le API attuali,
i limiti e il percorso manuale vedere [Managed GAM](../MANAGED_GAM.md).

Proposta del 2026-11-14, non implementata. Integra il
[piano GAM gestito](managed-gam-0.4.it.md) dopo il chiarimento dell'utente.
Gli esempi descrivono l'API obiettivo; non sono un quickstart eseguibile oggi.
Le API nuove sono indicate. Nessuna nuova review Opus su questa aggiunta.

## Architettura

```text
Stack: strumenti e adapter
Agent: router, flow, modelli, Skill
Server/SkillServer: callback Elixir e comandi
       ↓ return ctx
Server.Runtime: acquisizione comandi, outbox, continuazioni
       ↓
Server.GAM: integrazione standard oppure binding personalizzati
       ↓
Domain condiviso: decisioni e record GAM
       ↓ solo dopo ammissione e registrazione
adapter dell'effetto → osservazione dell'esito → handle_result
```

Ogni parte ha un default; lo sviluppatore sostituisce soltanto ciò che gli serve.
Un controllo manuale della conversazione non richiede bootstrap GAM manuale.
Un executor personalizzato non richiede un router diverso. Non introdurre due
runtime o una modalità `gam: false` per avere più controllo.

## Piano di modifica

1. Risolvere la fase identità/consenso del piano principale: stessa Scope non
   consente principal distinti nel protocollo attuale. Dichiarare e verificare
   il profilo scelto senza inventare attribuzioni o modificare il kernel di nascosto.
2. Estendere l'acquisizione dei return in `Server.Runtime`, conservando outbox e
   comando originale. Nessuna duplicazione di registrazione tra override e default.
3. Aggiungere bootstrap/configurazione gestiti a `gam:`; mantenere la forma
   manuale attuale. Esplicitare ownership, storage e recovery nei due casi.
4. Definire gli override con default: callback applicativo di preparazione,
   binding per operazione, presentazione e trasporto, executor nel pacchetto.
   Conservare `handle_pending` e tutti i callback OTP esistenti.
5. Implementare tool descriptor v2 e adapter di esecuzione, compresi Kinetic,
   Mnemonic, Beam, Pulse e Lens `:act`; verificare tutti i pacchetti installabili.
6. Migrare demo e host di integrazione al percorso standard. Aggiungere un caso
   misto: email standard, validazione business personalizzata, pending/timer manuali.
7. Testare equivalenza delle invarianti tra standard e personalizzato, override
   non validi, autorità non ampliabile, concorrenza Skill, crash e recovery.
8. Aggiornare documentazione con guida semplice e guida avanzata separate.

## 1. Configurazione e flow

Ogni modulo qui rappresenta un file separato. Modello, prompt e trasporto sono
integrazioni dell'app; `MailActions` contiene l'effetto concreto. Lo Stack lo
registra, mentre il runtime lo chiama soltanto quando ammesso.

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Kinetic,
    mode: :closed_moves,
    actions: MyApp.MailActions,
    modes: [send_email: :write]
end
```

L'Agent viene prima del Server nell'esempio, così si vede prima la mappa dei flow:

```elixir
defmodule MyApp.MailAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.MailServer

  model(MyApp.TextModel)
  # Può essere un modello diverso da quello che genera la risposta.
  classifier(:llm, MyApp.IntentModel)
  router(strategies: [:regex, :llm_classifier])

  flow :mail do
    # Comando esplicito oppure classificazione verso questo intento dichiarato.
    on(:compose, regex: ~r/^email\b/i,
      semantic_examples: ["Vorrei scrivere un messaggio al contatto"],
      collect_intent: false)

    # Chiedere lo stato non equivale a confermare l'invio.
    on(:status, regex: ~r/^stato$/i,
      semantic_examples: ["A che punto siamo?"])
  end
end
```

Avvio gestito: **la forma keyword di `gam:` sotto è nuova e proposta**.
`authenticated_identity` è ottenuta dall'app; i dettagli del trasporto autenticato
e del profilo identità vanno definiti nella fase 0, non derivati dal messaggio.

```elixir
{:ok, agent} = Spectre.Server.start_link(
  agent: MyApp.MailAgent,
  consumer: self(),
  identity: authenticated_identity,
  gam: [
    authority: :development, # Solo esempio locale: profilo esplicito.
    storage: :ephemeral,
    operations: %{
      {:kinetic, :send_email} => [confirm: true]
    }
  ]
)
```

In produzione cambia la configurazione di autorità/storage, non il Server.
La sola mappa identity non costituisce una prova di autenticazione. Il runtime
gestito deve riceverla dal confine fidato e proteggere i propri handle interni.

## 2. Server con gestione GAM automatica

Qui gli helper e i risultati mostrati esistono già. La novità è che l'avvio
gestito fornisce tutti i binding GAM oggi scritti in `DemoSpectre.Host`.

```elixir
defmodule MyApp.MailServer do
  use Spectre.Server, tools: MyApp.AI, prompt_root: "priv/mail/prompts"

  @impl true
  def handle_flow({:mail, :compose}, input, ctx) do
    # Il prompt chiede al modello una proposta AL, non una dichiarazione
    # che l'email sia già stata inviata. Nessun invio durante lo streaming.
    generate(ctx, :email,
      assigns: %{request: input.text},
      planning: false,
      on_result: :draft
    )
  end

  def handle_flow({:mail, :status}, _input, ctx),
    do: respond(ctx, "Richieste aperte: #{map_size(ctx.pending_by_id)}")

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Descrivi l’email che vuoi preparare oppure chiedi lo stato.")

  @impl true
  def handle_result(:draft, {:generated, response}, ctx),
    do: kinetic(ctx, response, on_result: :prepared)

  def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
    # Accoda la proposta. Al return Spectre gestisce consenso e GAM.
    propose(ctx, proposal.operation, proposal.args,
      proposal_metadata: proposal.metadata,
      on_result: :sent
    )
  end

  def handle_result(:prepared, {:prepared, _}, ctx),
    do: respond(ctx, "Mi serve una sola proposta di email completa.")

  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Invio completato secondo la ricevuta del servizio.")

  def handle_result(:sent, {:governed, %{outcome: %{status: :ambiguous}}}, ctx),
    do: respond(ctx, "L’esito è ancora da verificare; non ripeto automaticamente l’invio.")

  def handle_result(:sent, {:governed, %{decision: %{outcome: :refused}}}, ctx),
    do: respond(ctx, "L’invio non è stato autorizzato.")

  def handle_result(:sent, {:consent, status}, ctx),
    do: respond(ctx, "Richiesta chiusa: #{status}.")

  def handle_result(:sent, _result, ctx),
    do: respond(ctx, "Non ho una conferma di invio riuscito.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

La riconciliazione reale richiede l'adapter previsto dal piano: il testo di una
risposta non la avvia da solo. Per una demo con casella locale, la risposta di
successo deve parlare di accettazione nella casella locale, non di consegna remota.
Zero/più proposte hanno qui un'uscita esplicita; una sequenza multi-azione può
usare la gestione piani esistente anziché eliminarne la metadata.

## 3. Più controllo: un override, stesso Server

**Callback nuovo proposto `handle_action/2`**: si esegue una volta nella fase di
preparazione. Non invia, non genera token di consenso, non concede autorità.
Il suo risultato viene congelato nel comando. Il default `super` conserva le
regole dell'operazione; non è un'autorizzazione generica.

```elixir
@impl true
def handle_action(
      %{operation: {:kinetic, :send_email}, args: %{"to" => to}},
      ctx
    ) do
  # :observed_email è stato assegnato da un precedente risultato Lens.
  # Se manca o non coincide, il controllo fallisce senza inventare il contatto.
  if to == ctx.assigns[:observed_email] do
    {:confirm, %{message: "Vuoi inviare l’email a questo contatto?",
                 expires_in: 60_000}}
  else
    {:reject, :recipient_not_observed}
  end
end

def handle_action(action, ctx), do: super(action, ctx)
```

L'override è un esempio per il workflow con Lens; non va aggiunto al semplice
MailServer precedente senza anche il passo che osserva e assegna il destinatario.
Il messaggio personalizza la presentazione, ma destinatario e contenuto approvati
vengono sempre dal materiale congelato. L'expiry effettiva non può superare limiti
più stretti già imposti dal mandato/superficie/configurazione.

Si può anche gestire manualmente il cambio argomento con gli helper esistenti:

```elixir
@impl true
def handle_pending(%{kind: :consent} = pending, %{text: "stato"}, ctx) do
  ctx
  |> close_pending_after(pending.id, 30_000, reason: :topic_changed)
  |> route_current_input(suspend: pending.id)
end

def handle_pending(pending, input, ctx), do: super(pending, input, ctx)
```

Il timer gestito viene registrato automaticamente. Per possedere il timer OTP
si può usare l'opzione esistente `timer: :application`; il messaggio a
`handle_info` deve mantenere schedule ID/revisione, verificare che la scadenza sia
ancora quella attuale e richiedere `close_pending(..., if_schedule: schedule_id)`.
Non usare un timer privo di correlazione che chiuda una nuova richiesta dopo resume.
Il callback OTP ritorna la forma prevista `{:noreply, ctx}`; il runtime acquisisce
i comandi come negli altri callback. La chiusura dell'intento non chiude una Duty.

## 4. Controllo del collegamento GAM: modalità manuale esistente

Per chi possiede già Domain, autenticazione e adapter, conservare questa forma:

```elixir
Spectre.Server.start_link(
  agent: MyApp.MailAgent,
  consumer: self(),
  identity: authenticated_identity,
  checkpoint: checkpoint_config,
  gam: {Spectre.Server.GAM,
    scope: authenticated_scope,
    store: journal_store,
    lifecycle: true,
    bindings: %{
      {:kinetic, :send_email} => %{
        candidate: {MyApp.MailBoundary, :candidate},
        presentation: {MyApp.MailBoundary, :presentation},
        interpreter: {MyApp.MailBoundary, :interpret}
      }
    }}
)
```

Questo è un frammento di wiring dell'API attuale: scope, store e checkpoint sono
risorse già configurate. La forma richiede il Domain/executor/ingress dell'host;
non è un modo breve per creare automaticamente quelle risorse.

La modalità gestita deve inoltre permettere override mirati di `bindings`, senza
obbligare chi personalizza una sola operazione a passare alla modalità manuale.
Questa composizione è una nuova API da definire e testare: verifica di authority,
schema, provenienza e materiale resta obbligatoria anche con builder personalizzati.

Le API pubbliche del kernel restano disponibili agli integratori. Il codice
dell'agente continua a emettere comandi al proprio Server: chiamare il kernel in
parallelo per la stessa operazione rischierebbe due flussi di persistenza/recovery.

## Criterio di successo

Il caso standard non contiene oggetti kernel o un Host applicativo. Il caso
personalizzato aggiunge solo il controllo richiesto. Il caso manuale conserva
le API avanzate. Tutti passano dalle stesse decisioni GAM e dallo stesso record
autorevole, senza differenze di sicurezza create dal livello di ergonomia.
