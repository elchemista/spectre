# Review finale Spectre 0.4 (managed GAM)

Analisi solo sul sorgente incollato. Ogni punto indica se il bug è **verificato** nel codice mostrato o è un'**ipotesi** che dipende da codice non incluso (Bridge, Runtime completo, Domain, Effect). Nota di trasparenza: in questa sessione è stato eseguito un solo `ls doc/` in sola lettura, che non ha avuto alcun ruolo nella review.

## Verificato corretto (non lo ripeto oltre)
- Il Broker fa checkout con `put_new` e poi `consume` via CAS prima dell'adapter.
- La revoca passa da consumer → runtime → Managed.
- Il route del reviewer ha root separata con `classes == ["duty.dispose"]`, target esatto e singleton, causal ref validati da delegation e restriction.
- Facts esaustivo e indicizzato sono in parità, perché `disposition_entry` rifiltra `status: :open`.
- Nel Gate, la deadline di `presented` scade prima del timeout del worker, quindi non esiste un caso "ack accettato ma esito ambiguous".
- Lo scope riaperto al restart è deterministico.

---

## Bug verificati

### 1. La prova di consenso via input non è legata al testo interpretato
`managed/ingress.ex:33-46` e `managed/gate.ex:164`

`Gate.consume` confronta il digest salvato nella prova con `opts[:source_digest]`, cioè un valore dichiarato dal chiamante. Nessuno verifica che `sha256(envelope.input.text)` coincida con quel digest. La stance invece viene derivata dall'interprete su `envelope.input.text`. Una prova emessa per "annulla" può quindi chiudere una risposta "confermo", se Runtime o Bridge passano testo e digest disallineati: basta una normalizzazione o una pipeline che modifica il testo dopo l'emissione della prova. È la legge "prova umana separata dal render", e va fatta valere all'ingress.

Fix minimo: ricalcolare il digest dal testo e ignorare quello dichiarato.
```elixir
digest = opts[:source_digest] &&
  Base.encode16(:crypto.hash(:sha256, envelope.input.text), case: :lower)
:ok <- Gate.consume(gate, envelope.presentation.ref, envelope.stance, opts[:consent_proof], digest)
```
Se il Bridge già lo verifica, il punto scende a hardening. Il fix fallisce comunque in modo chiuso, e un test con testo normalizzato lo rende evidente.

### 2. Gli exit prima dell'adapter vengono registrati come `ambiguous`
`managed/executor.ex:69-78`

`Managed.execution/2` è una `GenServer.call` con timeout di 5 s. La chiamata avviene dopo `Broker.consume` ma prima di `Effect.execute`. Due casi la fanno fallire:
- Managed è occupato in `:view`, `:revoke` o `:dispose`, che chiamano il Domain in modo sincrono dentro `handle_call`;
- Managed è già fermo dopo `:drain_timeout`, e la chiamata fa exit `:noproc`.

L'exit risale al Runner, che lo trasforma in `ambiguous`. Ne nasce una Duty, anche se l'adapter non è mai stato invocato. Senza reviewer quella Duty resta aperta per sempre.
```elixir
defp execution(server, act) do
  Managed.execution(server, act)
catch
  :exit, _ -> {:error, :managed_execution_unavailable}
end
```
Il ramo `{:error, reason}` produce già `definitive_no_effect`, che qui è corretto. Conviene proteggere allo stesso modo `Effect.resolve` con un `rescue`. `Effect.execute` resta invece fuori dalla protezione.

### 3. Possibili segreti nel ledger durevole
`managed/executor.ex:44`

`inspect(reason, limit: 20)` limita il numero di elementi nelle collezioni, ma non la lunghezza dei binari. Un errore del provider che contiene header, URL firmati o token finisce per intero nell'Evidence dell'Outcome: su disco, per sempre. È anche leggibile tramite `gam_view` (punto 4).

Fix minimo: salvare il reason solo se è un atomo, altrimenti un digest.
```elixir
reason = if is_atom(reason), do: reason, else: %{term_digest: Value.digest!(inspect(reason))}
```

### 4. `gam_view` non ha alcun controllo sul chiamante
`runtime.ex:227`

Revoke, submit e resolve_duty sono tutti filtrati per chiamante. La view no: chiunque conosca il pid del Server legge testi utente, payload, risposte di consenso e receipt. Fix: passare `caller` a Managed e accettare solo `options[:consumer]` oppure `reviewer.consumer`. Il reviewer ne ha bisogno per scoprire `duty.ref` e i supporting ref.

### 5. `:checkout` restituisce l'intero stato a qualsiasi chiamante
`managed.ex:211-213`

Lo stato contiene il `token` di Ingress, `reviewer.scope` (uno Scope reviewer autenticato), le `options` del runtime (inclusi i `services`) e `close_waiters`. Il modello di fiducia è la stessa BEAM, ma questo rende la legge "resolve_duty solo reviewer" aggirabile anche per errore: basta un log o un crash report del worker. Fix:
```elixir
{:reply, {:ok, %{Map.take(state, [:scope, :gate, :journal, :effects, :refs, :row, :mandate])
  | options: Keyword.take(state.options, [:store, :consent_ttl_ms, :bindings])}}, ...}
```
Va verificato che il Bridge non legga altri campi.

### 6. Override `presentation: nil` provoca un crash a runtime
`managed/binding.ex:35-53` e `:343`

All'avvio `validate_overrides` controlla solo `settings[:confirm]`. Se però `handle_action` restituisce `:confirm`, oppure la route è protetta, `bindings/3` imposta l'`effective` a confirm e `validate_override!` solleva `ArgumentError` dentro `invoke_bridge`. L'override non ha comunque alcun effetto, perché la riga 53 scarta `:presentation`. Fix: rifiutare `presentation: nil` sempre, già all'avvio.

### 7. `Gate.show` sovrascrive una show pendente
`managed/gate.ex:55-71`

Non c'è controllo né sul chiamante né sull'esistenza del ref. Una seconda show con lo stesso `presentation_ref`, per retry, recovery o un processo qualsiasi, sostituisce `worker` e cancella le prove già emesse. Il worker legittimo va in timeout e produce una show `ambiguous`. Fix:
```elixir
Map.has_key?(state.shows, ref) -> {:reply, {:error, :presentation_already_pending}, state}
```
Ogni re-show genera un nuovo ref, perché `prepared_at` cambia.

### 8. La chiave idempotente non è separata per submitter
`runtime.ex:398-403`

Il `fingerprint` esclude il chiamante. Se un submitter B usa la chiave di A con la stessa richiesta, riceve il `command_id` di A, e la provenance registra solo A. Con una richiesta diversa, B riceve un `conflict` che rivela l'uso della chiave. Fix senza cambiare il formato del checkpoint:
```elixir
digest!({submitter_ref, operation, arguments, Keyword.delete(opts, :key)})
```
Va calcolato prima del lookup.

### 9. Il budget di shutdown è hardcoded e c'è una race sul lock
`server.ex:232` e `storage_lock.ex:16`

`child_spec` fissa `shutdown: 35_000`, mentre il `shutdown_timeout` della GAM è configurabile (default 30 s). A questo si aggiungono gli stop sequenziali in `terminate`, fino a 5 s ciascuno per domain, gate, ledger, journal, lock e gate del reviewer.

Il problema concreto: Managed non è supervisionato e gestisce `trap_exit`. Se il Runtime crasha o viene ucciso, il supervisor lo riavvia subito mentre il vecchio Managed sta ancora drenando o terminando. `:global.register_name` restituisce `:no` e il nuovo avvio fallisce con `managed_storage_path_in_use`. Riavvii ripetuti possono esaurire l'intensity del supervisor.

È verificabile con un test: storage su disco, `Process.exit(runtime, :kill)` sotto supervisor. Fix minimo in due parti:
- in `StorageLock.init`, su `:no`, recuperare il pid con `:global.whereis_name`, monitorarlo, attendere `:DOWN` con un timeout limitato e ritentare;
- derivare `shutdown` da `gam[:shutdown_timeout] + margine`.

Il commento alla riga 7 suggerisce poi che nodi connessi siano protetti. Non lo sono, perché `node()` fa parte del nome. Va riformulato in "solo questo nodo".

---

## Ipotesi (dipendono da codice non incluso)

**10. Duty mai disponibili.** La costituzione nomina il reviewer per cinque classi, ma la copertura causale richiede che `duty.mandate_ref` ricada nella lineage del mandato operativo. Le Duty con `mandate_ref: nil` (forse `disputed_evidence`, `scope_promise_overdue`, `erasure_reduces_verifiability`) danno `causal_refs → :error`, quindi restano aperte anche con reviewer configurato. Va verificato in `Duty.Derive`. Se è così, conviene documentarlo e aggiungere un test. Non va allargato il target.

**11. Provenance esterna falsificabile.** `commit_submission` passa `external_submission` dentro le opts di `propose` e poi `validate_context!` lo valida con `Command.validate`, quello pubblico. Se il validator pubblico accetta `:external_submission`, anche `handle_flow` può dichiararsi "external_actor" con un `submitter_ref` arbitrario. Fix: iniettare la provenance dopo la validazione e far rifiutare la chiave a `Command.validate`.

**12. `on_result` scelto dal chiamante esterno.** Un submitter esterno può indirizzare il proprio risultato a qualunque clausola `handle_result(tag, …)` dell'app (nel test, `:done`). Hardening: forzare `{:submission, tag}`.

**13. Consumer `nil`.** Con consumer `nil`, `send(nil, …)` in `Gate.show` solleva un errore. Il Gate crasha, Managed si ferma con `managed_component_stopped` e il Runtime cade, perché la conferma dinamica può nascere sempre. Fix: rifiutare all'avvio un consumer che non sia un pid, oppure restituire un errore da `show`.

**14. Collisione di domain ref in ephemeral.** Il default `"managed:" <> digest(agent, identity)` fa collidere due sessioni concorrenti con la stessa identity esplicita (per esempio due tab). Se `Domain.start_link` registra il ref, il secondo avvio fallisce; se non lo registra, due Domain condividono lo stesso ref.

**15. Indice da snapshot persistiti.** `open_duty_causes` non entra nei `counts` di `AuthorityIndex.complete?`. Se lo `State` viene ripristinato da snapshot precedenti, l'indice risulta "completo" con un set vuoto, e `Facts.current` perde Duty aperte. `for_candidate` non è colpito. Fix: includere una versione o il numero di Duty aperte in `counts`.

**16. Re-show con la stessa `identity_key`.** La show usa `"spectre:managed:show:" <> command_id`. Un re-show con `prepared_at` diverso, che `retire_previous_show` prevede, può collidere sull'identità nel kernel, salvo che il Bridge sovrascriva la chiave. Serve un test esplicito su expiry o "unclear" seguito da re-show.

---

## Minori (una riga ciascuno)
- `checkpoint_store/1` (`managed.ex:557`): `function_exported?` su un modulo non ancora caricato restituisce `false`, e il checkpoint finisce silenziosamente sul journal mentre il Bridge usa lo store esterno. Aggiungere `Code.ensure_loaded?`.
- `bootstrap.ex:473-474`: lo stesso segreto vale per `checkout_receipt_secret` e `grant_secret`. Conviene separarli, con due chiamate a `strong_rand_bytes` o con una derivazione HMAC distinta per etichetta.
- `managed.ex:229-232`: all'adapter arrivano tutte le opts del runtime (`services`, `init_arg`, `submitters`, `consumer`). Riusare la drop-list di `service_context`.
- `Identity.normalize`: non limita i valori ad atomo o stringa, come invece dichiarato. Mappe, liste e numeri passano.
- `consent_ttl_ms`, `show_timeout` e `shutdown_timeout` non sono validati. Uno `show_timeout` non intero rompe `receive … after` e trasforma la show in `ambiguous`.
- `DutyTargets.causal_refs` ricalcola `group_by(mandate_successors)` per ogni Duty aperta in `from_state` e `current`, con costo O(D·S). Calcolare i predecessori una volta sola.
- Il digest del profilo include `settings[:message]` e le MFA dei binding. Un cambio di testo o di nome modulo blocca per sempre il restart durable con `managed_authority_configuration_changed`. Valutare l'esclusione di `:message`, che non è authority.
- `start_owner`: un `Process.link/1` verso un pid già morto fa crashare il Runtime con `:noproc`, invece di restituire un errore.
- Residuo di design: la conferma dinamica (da `handle_action` o da route protetta) è legge del solo runtime. La Surface conosce solo `presentation_required_classes` statiche, quindi il kernel non rifiuta un Act con `managed_policy.confirm: true` privo di presentation. Va documentato come limite dichiarato.
- Operativo: ogni show non confermata entro 20 s apre una Duty `ambiguous` che, senza reviewer, non si chiude mai. Con consumer offline si accumulano senza limite.

## Priorità consigliata
Da chiudere prima del tag: 1, 2, 3, 4, 6, 7, 9 (race del lock). Da verificare con un test mirato: 8, 10, 11, 13.