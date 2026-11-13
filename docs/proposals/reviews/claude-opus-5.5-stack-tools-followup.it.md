# Seconda review: Specifica normativa v1 (B1–B7)

## VERDETTO: **CHANGES_REQUIRED**

Resta **un solo blocker**, piccolo e locale: manca la definizione di cosa succede quando la normalizzazione fallisce. La fase 1 (Installable, validazione dei descrittori, compiler e generatore degli helper) non ne dipende e può partire subito. Il blocker va chiuso prima della fase runtime.

Non ho modificato file né eseguito test.

---

## Verifica dei punti richiesti

| Punto | Esito | Nota sul codice |
|---|---|---|
| Normalizzazione anche negli OTP sotto `Failure.capture` | **Parziale** | Vedi blocker R1. |
| Metadata tool separati da `proposal_metadata` | Risolto | Così `Catalog.validate` (`catalog.ex:39-70`) resta invariato per le proposal Kinetic. Precisazione P1 sotto. |
| `remember` solo governato, senza idempotenza promessa | Risolto | Coerente con l'API reale: `SpectreMnemonic.remember/2` non ha una chiave di idempotenza. La recovery passa dal percorso governato esistente. |
| `open` con `retry: :never` e tag `:tool_unknown` | Risolto | Per i risultati non GAM la chiave del risultato ricade sul `command_id` (`delivery.ex:55-60`), quindi l'id è stabile e la deduplica tramite `seen_events` già funziona. Dopo un timeout un risultato tardivo viene ignorato (`runtime.ex:203-205`). Va aggiunta la clausola `:never` in `recover_outbox_entry`, che oggi ricade su `execute_entry` (`:2219`), come previsto dalla specifica. |
| Codec aggregato prima di outbox e inbox | Risolto | Precisazione P2 sotto. |
| Proiezione dell'Outcome nell'executor del package | Risolto | Coerente con GAM: l'Outcome è canonico e content-addressed, quindi va proiettato prima di diventare fatto GAM, e non dopo. |
| `Planning.prepare` pubblica | Risolto | Riusa esattamente `legacy_context`, `consolidate(true)` e `proposal/1` (`services.ex:74-125`). Le proposal restano complete per `Catalog.validate`. |
| B1, B6, B7 | Risolti | Schema chiuso, verifiche all'avvio, migrazioni satellite, nomi, warning e collisioni: tutto adeguato. |

---

## Blocker residuo

### R1. Non è definito cosa succede quando la normalizzazione fallisce, percorso per percorso
La specifica chiede «stessa normalizzazione sotto `Failure.capture`» in conversazione, `init` e tutte le callback OTP, ma non dice cosa accade dopo un errore. Contro il codice:
- **Conversazione:** il fallimento va in quarantena (`runtime.ex:704-715`). L'app quindi non vede mai un errore tipizzato come `response_already_planned` o `model_output_required`, che la specifica B5 prevede come esiti di dominio.
- **`delegate_otp` (`runtime.ex:857-883`) e `init_application` (`:103-113`):** oggi non c'è nessun `Failure.capture`. Avvolgerli senza una regola lascia due vie sbagliate: inviare la `reply` di `handle_call` scartando in silenzio i comandi, oppure inventare una quarantena senza evento.

**Fix (un paragrafo da aggiungere alla specifica):**
1. **Rifiuti di dominio.** Comprendono `prepare` che restituisce `{:error, r}` o solleva un'eccezione, il codec o il `max_bytes` del tool che rifiuta, e un tag di operazione sconosciuto. Il comando tool non viene creato. Al suo posto si acquisisce, nello stesso ordine degli altri comandi, una completion durabile con il `command_id`: `{:error, {:tool_rejected, tool, op, bounded_reason}}`, consegnata a `on_result` attraverso il normale percorso dell'inbox. Il modello da seguire è `resolve_await`, che chiama direttamente `receive_result` (`runtime.ex:1152-1165`). Il comportamento è identico in conversazione, `init`, callback OTP ed error handler.
2. **Errori di programmazione.** Comprendono opzioni non ammesse, un helper assente dallo snapshot e un mismatch di contratto. Si mantiene la semantica attuale di `validate_context!` per ciascun percorso: quarantena in conversazione, `{:stop, reason}` in `init`, eccezione nelle callback OTP. Prima non viene salvato nulla, quindi non si crea un loop, e la `reply` non parte mai con i comandi scartati.
3. **Test:** per ciascun percorso, un caso di rifiuto di dominio e uno di errore di programmazione.

---

## Precisazioni non bloccanti, da includere nei test
- **P1. Campo riservato della provenienza tool.** Va rifiutato anche nelle opzioni di `propose/4` scritto direttamente dall'app, non solo in quelle dell'helper. Basta aggiungerlo alla lista dei campi riservati in `command.ex:31-33`, accanto a `lifecycle_*`. Conviene conservarlo nell'entry dell'outbox (come `lifecycle_authorized`) invece che nelle opzioni passate al bridge.
- **P2. Controllo aggregato prima dell'acquisizione.** Deve includere anche i `returned.assigns`. Lo scenario reale è questo: `handle_result` mette in assigns una vista Lens grande, poi `acquire` → `Checkpoint.save` solleva fuori dal capture, e alla ripartenza `recover_inbox_entry` riesegue la stessa callback, in loop. Il controllo deve girare negli stessi percorsi di R1.
- **P3. `kinetic` e il planner effettivo.** `Planning.prepare` usa il planner configurato per l'Agent. Se l'Agent sovrascrive `action_planner` nel DSL, `kinetic` userebbe un planner diverso da Kinetic. Suggerisco che l'adapter Kinetic verifichi che il planner sia `Spectre.Kinetic.Planner`, oppure che restituisca un errore tipizzato.
- **P4. Default per `:tool_unknown`.** Il default `handle_result` lo fa ricadere su `no_response`. Valutare una risposta di default analoga a quella per `:governed_unknown` (`server.ex:69-70`).

Una volta aggiunto il paragrafo R1, per me la specifica è **PASS** e l'implementazione a fasi può procedere come descritta.
