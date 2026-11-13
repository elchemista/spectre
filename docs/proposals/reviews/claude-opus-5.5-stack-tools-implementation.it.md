# Review dell'implementazione Stack tools 0.4

**Verdetto: CHANGES_REQUIRED.** Confidenza media.

- Nessun P0.
- Tre P1: due operativi/di recovery e uno di confidenzialità in un satellite.
- Il nucleo core (compiler, normalizzazione R1, `:safe`/`:never`, provenienza, governed → `:propose`) è sostanzialmente conforme a B1–B7, R1 e P1–P4.

**Limiti di questa review**
- È solo lettura: non ho eseguito test, compilazione o Dialyzer e non certifico nulla.
- Durante la lettura sono cambiati `lib/spectre/server/tool.ex` e `spectre_mnemonic/.../server_tool.ex`. Li ho riletti: i finding si riferiscono allo stato finale osservato.
- In particolare, il caso «`:never` con fallimento dopo `invoke`» era aperto alla prima lettura e ora è chiuso (`tool.ex:113-116`, `runtime.ex:2148-2156`).

## P0
Nessuno.

## P1

**P1-1. Ledger `head` espone il checkpoint grezzo di qualunque chiave**
- **Dove:** `spectre_ledger/lib/spectre/ledger/server_tool.ex:20,32,38`.
- **Trigger:** `ledger(ctx, {:head, key})` con una chiave qualsiasi. `prepare` non valida né limita la chiave, `project` restituisce `%{revision, value: binary}` intero. Con uno store condiviso e chiavi per conversazione (come suggerisce il moduledoc di `ServerStore`), un Server può leggere assigns, history, `model_output` e candidate pending di un'altra conversazione.
- **Impatto:**
  - Fuga di dati tra conversazioni.
  - Il blob finisce anche nell'inbox e nel checkpoint del chiamante.
  - `docs/STACK_TOOLS.md:96` dice «head/entry metadata»: la doc non corrisponde all'implementazione.
  - L'integrazione (`workflow.ex:127-130`) mostra proprio il pattern «head → blob → `lab(:inspect, blob)`», che raddoppia lo stato e invita alla copia.
- **Fix suggerito:**
  - `head` restituisce solo metadata (revision, digest, size), come `entries`.
  - In alternativa, limitare la chiave a quella del checkpoint del Server stesso tramite un campo fidato. Oggi `service_context` scarta `:checkpoint`, quindi va aggiunto un campo dedicato.
  - Lab `inspect` riceve un riferimento logico (store/chiave) e decodifica nel worker, senza far passare il binario dall'outbox.

**P1-2. Nessun percorso di migrazione per entry tool in volo: il riavvio si blocca, anche per propose governate incerte**
- **Dove:** `runtime.ex:34` e `:294`, `tool.ex:123-139`, `checkpoint.ex:592-613`.
- **Trigger:** cambia il descriptor o il digest dell'installazione (per esempio `bind:`, `max_bytes` o qualsiasi opzione di config, perché `installation_digest` entra in `origin`). Basta un'entry `:tool_call` o una `:propose` con `tool_origin` e `execution_started: true` rimasta nell'outbox (worker propose interrotto, GAM non disponibile).
- **Cosa succede:**
  - `validate_persisted!` solleva un'eccezione, oppure `Map.fetch!` va in KeyError se l'helper è stato rimosso.
  - Il `checkpoint_migrator` non può aiutare: `preserve_reconciliation` vieta di modificare l'outbox.
- **Impatto:** il Server non riparte più. Una propose governata con effetto reale incerto non può essere riconciliata con GAM per un motivo, la provenienza tool, che non incide sull'effetto. Il piano dice «mismatch richiede migrazione esplicita», ma la migrazione non è possibile.
- **Fix suggerito:**
  - Per le entry governate, un mismatch di provenienza non deve impedire `recover_governed`: notificare e marcare l'entry (per esempio `tool_contract_changed`).
  - Per `:tool_call`, convertire l'entry in una completion durabile: `{:tool_unknown, ...}` se `:never`, `{:error, :tool_contract_changed}` se `:safe`.
  - Aggiungere test di restart dopo cambio descriptor per entrambi i percorsi.

**P1-3. Ledger `ServerStore` senza compattazione: a capacità esaurita tutti i Server dello store vanno in crash-loop**
- **Dove:** `spectre_ledger/lib/spectre/ledger/server_store.ex:19,125-128`, insieme a `checkpoint.ex:147-149`.
- **Trigger:** ogni save scrive il checkpoint intero (non un delta) e ogni turno fa più save. Con il default di 256 MiB, checkpoint da circa 100 KB esauriscono lo spazio in poche migliaia di save, sommando tutte le conversazioni.
- **Impatto:** `:store_capacity_exceeded`, poi `Checkpoint.save` solleva un'eccezione, poi crash-loop di tutte le conversazioni sullo stesso store. Il moduledoc delega la rotazione all'operatore, ma non esiste uno strumento per farla.
- **Fix suggerito:**
  - Compattazione (riscrittura atomica che tiene l'ultimo record per chiave, tmp + fsync + rename + fsync della directory).
  - Oppure dichiarare lo store solo per demo/sviluppo nella matrice di compatibilità.
- **Nota:** se il parent lo considera già solo per sviluppo, va declassato a P2.

## P2

1. **Limiti aggregati non allineati.** `runtime.ex:2127` valida lo stato in staging col limite di default di 16 MiB; `runtime.ex:1035` usa 16 MiB − 16 KiB.
   - **Trigger:** uno stato in staging nella finestra tra i due limiti con `ServerStore`. Il record wrapper supera 16 MiB, `invalid_store_value`, crash prima del save.
   - **Conseguenza:** al riavvio un `:safe` viene rieseguito e il ciclo si ripete. È plausibile con Ledger `head` o Lab (`max_bytes` 16 MiB).
   - **Fix:** un'unica costante del Checkpoint usata in entrambi i punti, e `max_bytes` massimo dei tool sotto quella soglia.

2. **Ambiguità degli esiti trattata in modo incoerente.**
   - L'executor dell'esempio (`integration/.../host.ex:149`) mappa ogni errore su `:failed`. GAM supporta `:ambiguous` e `:definitive_no_effect` (`gam/attempt/runner.ex:265`). È un esempio che gli utenti copieranno.
   - Beam segnala `{:error, {:ambiguous, _}}` (`beam/server_tool.ex:96-108`); Pulse usa `%{outcome: ...}` (`pulse/server_tool.ex:96-100`) e nel ramo generico restituisce una reason non limitata né resa portabile.
   - **Fix:** una convenzione unica (per esempio `{:unknown, reason}`) e un executor d'esempio che la mappi su `:ambiguous`.

3. **Mnemonic `remember` governato: partizione ed engine non garantiti.**
   - Il prepare non riceve l'identity e l'executor non può derivarla. L'integrazione maschera il problema con `isolate_by([:agent])` (`workflow.ex:7`), `identity: %{}` e `memory_options` cablate a parte sia nel Server sia nell'executor (`outreach_test.exs:29,40`, `host.ex:172-178`).
   - Con isolamento per `:subject` o `:conversation` la scrittura fallisce (fail-closed, nessuna fuga).
   - Se manca `stack_runtime`, `memory.ex:109-111` ripiega silenziosamente su un engine diverso da quello per-Stack.
   - **Fix:** la candidate host porta la partizione nel payload; errore esplicito se lo Stack dichiara un engine ma manca `stack_runtime`; test con `isolate_by([:subject])`.

4. **Proiezione Mnemonic a denylist** (`mnemonic/server_tool.ex:12-24,100`). Un nuovo campo sensibile aggiunto alle struct `SpectreMnemonic.*` finirebbe nel checkpoint. Meglio un'allowlist per struct.

5. **`bind:` non validato** in Beam (`beam/server_tool.ex:17`) e Pulse (`pulse/server_tool.ex:16`), a differenza di Mnemonic e Lens. Un refuso fa sparire l'operazione governata senza errore.

6. **Classificazione incoerente secondo R1.** Un `on_result` non portabile è un errore di programmazione (`tool.ex:44`), una `confirmation` non portabile diventa rifiuto di dominio (`tool.ex:204-210`). Va uniformato, preferibilmente come errore di programmazione.

7. **`ServerStore`, robustezza del file.**
   - Un crash tra `:file.open` e la scrittura del magic lascia un file vuoto, poi `:invalid_store_header` permanente (`server_store.ex:49-50,176-183`).
   - Un tail troncato non acknowledged blocca l'avvio, anche se è troncabile in sicurezza.
   - `delete` è solo un tombstone: il payload resta su disco (cancellazione/privacy). Va documentato o risolto con la compattazione.

8. **Costo nel processo owner.** Lo stato canonico intero viene percorso due o tre volte per step (`runtime.ex:1035`, `:2127`, più il save). Non blocca, ma con stati da 15 MiB si sente.

9. **Da verificare (confidenza bassa):** che `Macro.expand` dentro `__using__` registri la dipendenza di compilazione Server → Stack (`mix xref graph --label compile`). Il controllo a runtime intercetta comunque il caso, con un errore poco chiaro in sviluppo.

## Test: falsa copertura e test essenziali mancanti

- **Il Sink deduplica per destinatario** (`adapters.ex:65-67`): `length(email) == 1` (`outreach_test.exs:154-155`) non può rilevare un tentativo di reinvio. Bisogna contare i tentativi.
- **`refute before_memory == after_memory`** (`outreach_test.exs:135`) è debole: va asserito che il contenuto salvato sia presente.
- **Il restart è uno stop pulito, senza kill**, e lo store Ledger non viene riavviato da file. Manca la replay reale del `ServerStore`.
- **Manca il restart tra `generate` e `kinetic`**, richiesto da B5. Mancano anche test che `model_output` non compaia in eventi consumer, preview o stream.
- **Pulse `execute/2` non ha nessun test**, inclusi il merge con chiavi stringa e il vincolo sul formato dell'id. L'integrazione non fa il bind di `send`.
- **Lens:** `execute(:act)` e `close` non testati.
- **Percorso governato:** mancano test di crash con propose tool-originated incerta, consenso scaduto e riavvio dopo cambio descriptor (vedi P1-2).

## Preesistenti o fuori scope
- `TabRef` di Lens non è legato a un owner (rischio di forgiare riferimenti tra conversazioni sullo stesso runtime).
- I worker catturano l'intero `state` della closure.
- `cancel` dei `:safe` non consegna una completion (stessa semantica di `generate`).
- Euristica `{module, ref}` in `store/port.ex:22-26`.
- Gli adapter Beam che restituiscono errori non ambigui dopo un invio reale restano un contratto dell'adapter.

## Cose verificate e corrette
- Fence all'avvio sullo Stack effettivo dell'Agent, prima di load e init.
- Collisioni controllate su entrambe le arità (definizioni, import, callback, special forms).
- Forging di `:tool_call` e `tool_origin` respinto.
- Rifiuti di dominio come completion durabili in conversazione, init, callback OTP ed error handler.
- `:never` con `execution_started` salvato prima dello spawn; timeout, DOWN, cancel e restart producono `tool_unknown`.
- `prepare` puro nei pacchetti; gli `execute` sono invocati solo dall'executor host.
- P3 (planner Kinetic effettivo) e P4 (default per `tool_unknown`) presenti.
- `Planning.prepare` condiviso con `planning: true`.

**Limiti live:** tutti i provider (modello, browser, email, Pulse) sono deterministici o fake. Non ho validato comportamento con provider reali, streaming reale né concorrenza multi-nodo.