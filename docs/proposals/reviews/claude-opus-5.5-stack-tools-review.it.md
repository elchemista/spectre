# Review architetturale: piano Stack tools 0.4

## VERDETTO: **CHANGES_REQUIRED**

La direzione del piano regge e non tocca GAM. Il callback opzionale `tools/1` sullo stesso `Installable` e i descrittori in `Installation.adapters[:tools]` funzionano: il digest li include già, perché `canonical/1` in `installation.ex:182-187` comprende `adapters`. Il controllo `verify_bound` intercetta già i binding obsoleti (`binding.ex:136-152`). Classificazione e generazione restano senza consenso.

Il piano però lascia indefiniti alcuni contratti, e contro il codice attuale quei vuoti producono re-esecuzioni alla cieca, crash del proprietario oppure proposal Kinetic che GAM rifiuta. **Con questi dettagli aperti l'implementazione non è sicura.**

Non ho modificato file né eseguito test. In questa sessione non ho il tool di scrittura, quindi non ho salvato la review nel file di piano: la risposta resta qui.

---

## Blocker, in ordine di priorità

### B1. Contratto del descrittore e callback dell'adapter non definiti
Il piano dice cosa deve contenere un descrittore (operazioni chiuse, percorso, proiezioni), ma non ne fissa la forma né la firma dell'adapter. Le firme reali divergono:
- `Spectre.Kinetic.Planner.plan_response(text, ctx, opts)`
- `Spectre.Mnemonic.Memory.recall(cue, opts)` e `remember(payload, opts)`, che richiedono `opts[:agent]`
- `Spectre.Lens.ActionProvider.execute(action, ctx, opts)`, che richiede `opts[:config]` e `ctx.opts[:stack_runtime]`

Senza questo contratto non si possono scrivere né il validatore né il generatore né il dispatch.

**Fix:** fissare nel piano uno schema chiuso e versionato. Ad esempio `%{nome => %{contract: 1, adapter: Mod, operations: %{op => %{path: :cognitive | :governed, retry: :safe | :never, input: ..., output: ...}}}}`, più tre callback dell'adapter, senza `@behaviour` obbligatorio:
- `prepare(op, input, trusted)`: pura, gira nel processo del callback e restituisce argomenti portabili.
- `invoke(op, args, tool_ctx)`: gira nel worker. `tool_ctx` contiene installation, service_context, resolver delle risorse e `command_id`.
- `project(op, raw)`: gira nel worker e restituisce un valore portabile.

L'operazione si sceglie dal tag della tupla con lookup chiuso (`{:recall, q}` → `:recall`), senza `String.to_atom`.

### B2. Il percorso governato deve diventare `:propose` all'acquisizione, non nel worker
Oggi recovery, timeout e crash si decidono **per kind di comando**:
- `governed?/1` (`runtime.ex:2444`)
- `mark_execution_started` (`:1915`)
- `recover_outbox_entry` (`:2196-2222`)
- `timeout_worker` (`:294`)
- `:DOWN` (`:226`)

Un nuovo kind `:tool` con modalità governata dichiarata nel descrittore verrebbe trattato come non governato: rieseguito al restart e con il worker ucciso al timeout.

**Fix:** dentro il confine `Failure.capture` (in `prepare_conversation` o in `validate_conversation_commands`), riscrivere il comando tool governato in `%Command{kind: :propose, args: [host_op, args]}`, con `proposal_metadata` che contiene tool, op e digest. Questo avviene prima dell'inserimento in outbox; da lì valgono tutte le regole esistenti di recovery e consenso.

Due punti collegati:
- Il nome dell'operazione host lo sceglie la configurazione Stack fidata, ad esempio `install Spectre.Mnemonic, bind: [remember: :save_report]`. Va verificato che esista in `bridge_config[:bindings]` all'avvio del Server: oggi l'errore `{:unbound_governed_operation, op}` arriva solo alla prima chiamata (`gam.ex:505-510`).
- `:propose` rifiuta `:timeout` (`command.ex:53`), quindi l'helper deve rifiutarlo per le operazioni governate.

Va anche detto esplicitamente che per le operazioni governate l'host deve configurare binding ed executor GAM. Il criterio «nessun adapter applicativo obbligatorio» vale solo per le operazioni cognitive. I package possono offrire moduli candidate/executor pronti da referenziare nella config host.

### B3. Operazioni cognitive non ripetibili: oggi vengono rieseguite alla cieca
Il problema riguarda Lens `open` (crea una tab), Lens `act` se lasciato cognitivo e un `remember` cognitivo.

Per i kind non governati il codice attuale si comporta così:
- `execution_started` resta `false`, quindi al restart l'entry viene rieseguita (`runtime.ex:2213`).
- Al timeout il worker viene ucciso e arriva `{:error, :timeout}` (`:299-303`), anche se l'effetto potrebbe essere già avvenuto.

**Fix:**
- Per `retry: :never`: segnare `execution_started` prima dello spawn. Su recovery, timeout o crash, consegnare un tag distinto (ad es. `{:tool_unknown, ...}`) senza reinvocare.
- Mnemonic: `SpectreMnemonic.remember/2` non accetta una chiave di idempotenza dal chiamante. `dedupe_key` esiste solo nei Record di persistenza. Quindi «usare `command_id` come identità» oggi non è implementabile. Bisogna scegliere: `remember` esplicito solo governato (come nell'esempio outreach), oppure un `idempotency_key` aggiunto in un branch di Mnemonic.

### B4. Due nozioni di «portabile»: rischio di crash a ripetizione del proprietario
- `Spectre.Stack.Value.portable?` accetta qualunque struct (`stack/value.ex:17-35`).
- Il Checkpoint usa `GAM.Canonical.Value` con `allowed_structs: @records` (`checkpoint.ex:28-49, 162`), ricrea gli atomi solo con `to_existing_atom` e ha un limite di 16 MB.
- `Checkpoint.save` solleva un'eccezione se la codifica fallisce (`checkpoint.ex:166`), e `acquire/3` sta fuori da `Failure.capture` (`runtime.ex:704-711`).

Conseguenze:
- Un input non codificabile fa crashare il GenServer.
- Un output non codificabile lo fa crashare in `acquire_worker_result` (`:2004-2010`). Al restart l'entry non governata viene rieseguita e si ha un loop di crash.

**Fix:**
- Input: `prepare` più una codifica di prova con lo stesso codec e gli stessi `@records` del Checkpoint, eseguite dentro il confine del callback (helper o `Command.validate`). Un errore diventa quarantena o errore tipizzato.
- Output: `project` più codifica di prova nel worker, con limite di byte per tool. Un errore diventa `{:error, {:tool_result_not_portable, _}}`.
- Esporre i `@records` del Checkpoint tramite una funzione, invece di duplicarli.
- Non salvare `%Spectre.Stack.Ref{}` in outbox (non è nei `@records`): usare dati semplici `{installation_id, tool, op, descriptor_digest}`.

### B5. Kinetic: il callee proposto produce proposal che GAM rifiuta
Chiamare direttamente `Spectre.Kinetic.Planner.plan_response/3`, come suggerisce la §4.3, salta sia lo staging di `Spectre.ActionPlanner` (owner/scope dell'effect) sia `Services.proposal/1`. Le azioni risultanti non hanno `metadata.owner/scope/schema_hash`, e il successivo `propose(..., proposal_metadata:)` fallisce in `Catalog.validate` (`catalog.ex:39-70`).

**Fix:**
- L'adapter deve riprodurre esattamente la catena di `Services.consolidate(text, true, ctx)` → `proposal/1` (`services.ex:78-100`), con il contesto dell'evento originario.
- Va estratta in un modulo pubblico condiviso (ad es. `ActionPlanner.plan_proposals/2`). `Catalog` è `@moduledoc false`, quindi l'adapter Kinetic non lo deve chiamare direttamente.

**Doppia pianificazione:**
- `{:generated, r}` deve portare un campo portabile `planning: boolean`, e `model_output` solo quando `planning: false`.
- `kinetic` restituisce `{:error, :response_already_planned}` se `planning: true` o se manca `model_output`.
- La proiezione dell'inbox (`checkpoint.ex:221-224`) toglie solo `:inference`, quindi `model_output` sopravvive al checkpoint, come serve.

### B6. I tre package non si installano su core 0.4.0
Kinetic, Lens e Mnemonic dichiarano `spectre: "~> 0.3.3"` (`kinetic.ex:44`, `lens.ex:45`, `mnemonic.ex:19`). Il core è 0.4.0 (`mix.exs:4`). `validate_compatibility!` (`definition.ex:252-261`) fallisce già quando si compila lo Stack, prima ancora dei tool: l'esempio di authoring non compila.

**Fix:** il piano deve elencare per ciascun branch satellite:
- aggiornamento del requisito di versione;
- `tools/1` e il modulo adapter;
- codec e proiezioni;
- idempotenza Mnemonic;
- eventuale risorsa Kinetic.

I test del core devono usare solo fixture.

### B7. Generazione degli helper nel Server
- **Warning:** `defp` generati e non usati producono warning e rompono `--warnings-as-errors`. Usare `@compile {:nowarn_unused_function, [{n, 2}, {n, 3}]}`.
- **Collisioni:** controllare contro `Module.defines?/2`, `env.functions` e `env.macros` (che includono Kernel e gli import di `Spectre.Server` in `server.ex:39-40`), i callback (`server.ex:22-33`) e **entrambe** le arità.
- **Nomi duplicati tra package:** due package diversi possono dichiarare lo stesso nome di helper. `Definition` vieta solo i package duplicati (`definition.ex:227-250`). Aggiungere un controllo di unicità in `Definition.new!`, senza nuovi kind in `Ref`.
- **`tools:`:** accettarlo solo come modulo letterale, espanso come fa `eval_opts`. Leggere la definizione con `Stack.Definition.fetch/1`, che ne valida il digest.

---

## Scelte da fissare prima di implementare
1. **Nome dell'helper rispetto a `as:`.** Raccomando: il nome è la chiave del descrittore (decisa dal package); `as:` cambia solo l'id dell'installazione.
2. **Chi decide il percorso di un'operazione.** Raccomando: il package dichiara i percorsi ammessi e un default; la config Stack può solo scegliere fra quelli.
3. **Sotto-operazione di Lens `act`.** Mappa chiusa dall'enum dei tipi (`navigate/click/fill/submit/scroll`, `action_provider.ex:37`) al percorso. Un tipo sconosciuto va governato oppure in errore. `act` è `:write` nel provider.
4. **Quando si verificano esistenza e arità degli adapter.** Alla compilazione dello Stack solo la forma; esistenza e arità all'avvio del Server. `ensure_compiled` su moduli dello stesso progetto può restituire `:unavailable`.
5. **Opzioni ammesse nell'helper.** Lista chiusa: `on_result`; `timeout` solo per le cognitive; `confirmation` solo per le governate (l'esempio passa un interpreter MFA, che arriva a `gam.ex:65`). Tutto il resto va rifiutato.
6. **Runtime Kinetic.** Oggi non c'è una risorsa Stack: `Planner.with_owned_runtime` lo carica a ogni chiamata (`planner.ex:221-246`). Decidere tra parità con `planning: true` in v1 oppure una risorsa `{:kinetic, :runtime}` nel satellite.

## Suggerimenti non bloccanti
- **Compatibilità a runtime:** in `initial_state` (`runtime.ex:38-47`) confrontare la tabella dei tool compilata con `Binding.installation(agent, id)`; in caso di mismatch, `{:stop, ...}`. Le risorse si risolvono con `context.options[:stack_runtime]` (già presente) e `Stack.Runtime.resolve/2`, seguendo il modello di `Spectre.Lens.runtime` (`lens.ex:145-162`).
- **Fingerprint:** copre già l'md5 di Stack e Server (`checkpoint.ex:386-421, 597`). Valutare di aggiungere anche i moduli adapter, perché oggi una modifica al loro codice con lo stesso descrittore non viene rilevata.
- **Revalidazione:** validare i descrittori anche in `build!` e `rebuild!`, non solo in `compile!`, così sono coperti anche i manifest serializzati.
- **Esempio outreach da correggere:**
  - `{:ok, %{tab_ref: _}}`: Lens `open` restituisce direttamente la mappa del TabRef.
  - `operation == :save_report` va allineato al binding scelto al punto B2.
- **Package late-bound (Lens):** `tools/1` deve restituire solo atomi e mappe, e l'adapter deve usare `Module.concat` come fa già `ActionProvider`.
