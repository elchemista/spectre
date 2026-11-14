# Review finale: GAM gestito (verdetto dal sorgente allegato)

**Esito:** ho trovato 5 difetti P1 verificati nel codice, nessun P0 dimostrabile senza leggere `Spectre.Server.GAM` (Bridge). Seguono 5 ipotesi P1 che dipendono dal Bridge o da `Command` e alcune note minori.

---

## P1 verificati

### 1. Un override `presentation: nil` annulla la conferma forzata (route protetta, `confirmation:`, `handle_action → :confirm`)

**Dove:** `binding.ex:48-50`, con il controllo incompleto a `binding.ex:263-265`.

**Problema:** `bindings/3` calcola `confirm?` e aggiunge presentazione e interprete. Poi esegue `Map.merge(binding, Map.delete(override, :candidate))`, quindi un override statico `%{presentation: nil}` o `%{interpreter: nil}` vince sul default forzato. `validate_override!` vieta `nil` solo se `settings[:confirm]` è `true`. Per un'operazione con `confirm: false` la configurazione viene accettata.

**Impatto:** il kernel non richiede la presentazione, perché la classe non è in `presentation_required_classes` (`bootstrap.ex:252-257`). Una route `protected: true`, un `confirmation:` esplicito o un `handle_action` che restituisce `:confirm` produrrebbero quindi un Act ed eseguirebbero l'effetto senza consenso. Questo contraddice la garanzia "forces default presentation".

**Correzione minima:** in `bindings/3`, quando `confirm?` è vero, scartare i valori `nil` dell'override:
```elixir
override = if confirm?, do: Map.reject(override, fn {_, v} -> is_nil(v) end), else: override
```
Se la garanzia vuole proprio la presentazione *default*, fare `Map.drop(override, [:presentation, :interpreter])` quando la conferma deriva dalla policy. Aggiungere un test con route protetta, `confirm: false` e override `nil`.

### 2. La prova viene emessa prima dei controlli di stato: la presentazione diventa inutilizzabile

**Dove:** `runtime.ex:229-233` (decide), `runtime.ex:279-280` e `655-665` (testo), `runtime.ex:354-355` (transport), `runtime.ex:643-652` e `682-690`. Il blocco irreversibile sta in `gate.ex:109` e `gate.ex:123` (`authorized: false` → `true`).

**Problema:** `Gate.authorize` marca lo show come `authorized: true` *prima* che il runtime verifichi tre cose:
- che il pending sia ancora foreground con quel ref (`accept_decision`, `:stale_presentation`);
- che la coda non sia piena (`accept_input`, `{:error, :busy}`);
- che la Skill indicata esista (`Skills.lookup`).

Lo stesso accade se `decide(nil, ref)` riguarda un pending di una Skill, oppure se arriva un testo "sì" diretto con `pending:` a un altro pending.

**Impatto:** la prova non viene mai consumata, e ogni `decide` successivo restituisce `:consent_transport_not_authorized` fino alla scadenza. Con TTL `:infinity` il blocco è permanente. Non è un'escalation (la prova resta legata a ref e stance), ma rende impossibile un consenso legittimo dopo un errore di instradamento della UI o un picco di coda.

**Correzione minima:** in `Gate.authorize` accettare anche uno show già autorizzato non consumato. Prima di inserire la nuova prova, invalidare quelle esistenti per quel ref:
```elixir
proofs = state.proofs |> Map.reject(fn {_, p} -> p.ref == ref end) |> Map.put(proof, value)
```
Il singolo uso resta garantito, perché una prova sostituita fallisce in `consume` (fail-closed). Va aggiornato `managed_gate_test.exs:46-47`.

### 3. Il rendering della presentazione è ambiguo e permette di iniettare righe

**Dove:** `material.ex:6`, `13`, `17`.

**Problema:** le stringhe vengono emesse così come sono, mappe e liste annidate non sono indentate, e le etichette normalizzate possono collidere (`:a_b` e `"a b"`). Un payload generato dal modello (AL di Kinetic) come `%{body: "ciao\nTo: amico@x", to: "evil@x"}` produce due righe `To:`. Con `%{meta: %{to: "a"}, to: "b"}` il campo annidato appare come campo di primo livello. Il vecchio `inspect` faceva escape dei `\n`: la correzione a "fieldlines" ha reintrodotto il problema.

**Impatto:** l'umano approva un testo che non rappresenta in modo univoco `data`. È un problema di integrità del consenso.

**Correzione minima:** indentare le continuazioni, cioè `label <> ": " <> indent(render(item))` con `indent = &String.replace(&1, "\n", "\n  ")`, e lo stesso per gli elementi di lista. Rimuovere o sostituire i caratteri di controllo e bidi (U+202A–202E, U+2066–2069).

### 4. Scope e token di autenticazione passano nel `context` dei callback override

**Dove:** `managed.ex:289-294` (`managed: state`) e `binding.ex:72` (`apply(module, function, [args, turn, context])`).

**Problema:** `state` è lo stato completo di Managed: `scope`, `token` (credenziale di `Gate.authenticate`), pid di `domain`/`gate`, store. Il fatto è verificato: `Binding.candidate` legge `context.managed`, quindi il Bridge inoltra quel context, e `custom_candidate` lo passa intero all'MFA applicativo.

Inoltre ogni `KeyError` su questo context (es. `context.proposal_metadata` a `binding.ex:114`, `context.command_id` a `managed.ex:318`) stampa la mappa, token incluso, nel report di crash del worker. Ciò viola il vincolo dichiarato: "non in ctx/options/tool né nei log di crash".

**Correzione minima:** a `managed.ex:291` passare
```elixir
managed: Map.drop(state, [:scope, :token, :domain, :gate, :store, :journal, :ledger, :owned, :workers])
```
`Binding` usa solo `effects`, `options`, `refs`, `row`, `mandate`. Scope e gate restano nella keyword `bridge` costruita localmente.

### 5. Decide e input verso una Skill possono restare senza risposta

**Dove:** `runtime.ex:240-249` e `682-686` (il root risponde `:noreply`), `runtime.ex:331-340` e `367-388` (unico punto di risposta, nel figlio).

**Problema:** il root inoltra `from` alla Skill con un semplice `send`. Se il figlio muore o si riavvia tra `lookup` e la consegna, se il token non coincide (ramo `_ -> {:noreply, state}` senza reply), o se `accept_input` solleva un'eccezione (es. `Checkpoint.save`), nessuno risponde. Il chiamante monitora solo il root, che è vivo.

**Impatto:** dipende dal timeout del chiamante. Il risultato è un blocco indefinito (`Session.decide`/`input` usano `:infinity`) oppure un exit per timeout dentro `Session.handle_call`, che fa crashare la Session e con essa agent e store.

**Correzione minima:** affidare il relay a un Task sotto `Spectre.Server.TaskSupervisor`. Il Task fa `GenServer.call(child, msg, :infinity)` intercettando l'exit e risponde a `from` con `{:error, {:skill_unavailable, reason}}`. In alternativa il root monitora il figlio e risponde al DOWN. Nel ramo con token errato rispondere con un errore invece di scartare.

---

## Ipotesi P1 (da confermare sul Bridge o su `Command`)

**H1. `bind_pending_deadline` trasforma in errore pending legittimi** (`managed.ex:333`, `346-351`; `gate.ex:94`).
- **Meccanismo:** il bind riesce solo se il chiamante è il processo che ha eseguito lo show e se `deadline_bound` è `false`. Ogni `{:pending, p}` restituito da `confirm` (testo `:unclear`), `explain`/`resume` senza nuovo show, o `recover_*` riceve quindi `{:error, :presentation_deadline_not_authorized}`. Lo stesso vale se lo show è già stato consumato.
- **Rischio aggiuntivo:** se esistono pending non `:consent` senza `presentation`, `pending.presentation.ref` va in crash.
- **Correzione:** rendere il bind idempotente quando `deadline_bound: true` e `expires_at == deadline`, a prescindere dal worker (non estende nulla). Fare il bind solo se `pending` ha `presentation`.

**H2. Le opts possono sovrascrivere la policy congelata** (`managed.ex:394`).
- **Meccanismo:** `Map.merge(frozen, opts[:action_policy])` fa vincere le opts anche su `confirm`/`resume`. Se un `confirm_pending`/`resume_pending` applicativo può portare `action_policy: %{confirm: false}` (dipende dalla validazione di `Command`), i binding perdono presentazione e interprete per operazioni con `confirm: false`.
- **Correzione:** invertire il merge (`Map.merge(opts_policy, frozen)`) o ignorare le opts quando esiste `frozen`.

**H3. Il recovery perde la conferma da policy** (`managed.ex:98`, `101`, `110` con `operation = nil`; `binding.ex:33-35`).
- **Meccanismo:** con `current == nil` la presentazione dipende solo da `settings[:confirm]`. Se `Bridge.recover_command` o `resolve_command_result` risottomettono un candidate congelato con `managed_policy.confirm = true`, l'Act potrebbe essere ammesso senza presentazione.
- **Correzione:** nei percorsi di recovery derivare `operation` e la policy dal candidate o dal comando nel journal, oppure rifiutare il recovery di candidate con `confirm` congelato senza un pending consumato.

**H4. Autorità effimera con journal e checkpoint durevoli** (`managed.ex:300`; `bootstrap.ex:18-29` non rifiuta `:store`; la demo lo fa a `session.ex:62-70`).
- **Meccanismo:** dopo un riavvio con lo stesso checkpoint, i comandi `execution_started` puntano a un ledger che non esiste più. Il nuovo dominio ha gli stessi ref deterministici e un nuovo genesis. `identity_key` non deduplica più, quindi il recovery potrebbe rieseguire un effetto `:non_idempotent`.
- **Nella demo** il problema è latente, perché l'id di sessione è casuale.
- **Correzione:** con `storage: :ephemeral` rifiutare `:store` e richiedere un checkpoint assente o effimero.

**H5. Envelope del candidate override incompleto** (`binding.ex:82-97`).
- **Meccanismo:** non vengono confrontati `consent` (`data_digest`, `risk`, `recipient_refs`), `disclosure`, `evidence_refs`, `meter_requests`, `observation_window_ms`.
- **Condizione:** è un problema solo se il kernel non ricalcola `data_digest` dalla consequence e non vincola `disclosure` al mandate.
- **Correzione:** aggiungere almeno `:consent` e `:disclosure` a `fields`.

---

## Minori (P2)

- **Leak del Gate con TTL `:infinity`.** Gli show di pending chiusi per lifecycle o cancellazione non vengono mai consumati né rimossi (`gate.ex:165`). Dopo 256 restano bloccati tutti i nuovi show (`gate.ex:57`). Correzione: rimuovere l'entry alla chiusura del pending.
- **Policy di `handle_action` non validata** (`binding.ex:135`, `139`, `199`).
  - Un `:message` non binario fa crashare `<>`.
  - Valori non canonici in `bind` o chiavi extra causano un `MatchError` su `data_digest`.
  - Correzione: validare con `Value.validate` e `is_binary` in `action_policy`.
- **Pending in attesa di consenso dopo riavvio disk.** Il Gate è nuovo e senza show, quindi `decide` fallisce finché non avviene un `resume` con nuovo show. Va verificato che `recover` lo faccia.
- **Prova salvata nel checkpoint.** `consent_proof` finisce in `event` e viene salvato da `Checkpoint.save` (`runtime.ex:620`, `632`). È innocuo dopo il riavvio, ma è una credenziale persistita.
- **Mandate fisso a 30 giorni** (`bootstrap.ex:299`). Il dominio disk scade senza un percorso di rinnovo diverso dal cancellare la directory. Da documentare.
- **Test.** `refute Keyword.has_key?(context.options, :gam)` (`managed_runtime_test.exs:116`) è sempre vero, perché `Effect.invoke` prende solo due chiavi. Mancano test per i punti 1, 2 e 5 e per H1.

---

## Risposte alle domande

- **Esecuzione prima dell'Act o senza consenso richiesto:** sì, tramite il punto 1 (override `nil` su conferme da policy). È possibile anche tramite H2 e H3 se il Bridge lo consente. Nessun percorso del kernel per le classi in `presentation_required_classes`.
- **La prova passa a pending, mount o revisione diversi:** no. È legata a ref della presentazione e stance, il consumo è atomico e la mappa non viene modificata in caso di mismatch. Il difetto reale è che la prova si brucia (punto 2).
- **Recovery o override ampliano l'autorità:** l'override sì (punto 1). Il recovery è ipotizzabile (H3, H4). La verifica di disk e digest su profilo, genesis e mandate è corretta e fail-closed.
- **Crash o race concreti:** il punto 5 (risposte perse). H1 per i pending non nati da uno show nello stesso worker. Il resto della chiusura (checkout, drain, owner monitor, EXIT) mi sembra coerente.
- **Coerenza tra record, risultato ed effetti:** l'Executor mappa correttamente `succeeded`, `failed`, `definitive_no_effect` e `ambiguous`. Il contratto e l'identità vengono riverificati prima dell'adapter, e le eccezioni dell'adapter diventano `ambiguous`. Ciò che l'umano approva, invece, può non corrispondere a `data` (punto 3).

**Limite di questa review:** non ho visto `Spectre.Server.GAM` (Bridge), `Tool.normalize`, `Skills.authorize` né `Command.validate`. Non posso quindi escludere helper di scrittura classificati come non governati né confermare H1–H5.