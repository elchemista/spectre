# Review finale mirata — Spectre 0.4.0 core Agent/Server/GAM

Ho letto solo lo snapshot in `source/` e i log in `validation/`. Non ho usato shell, quindi non ho ricalcolato gli SHA256 di `inventory.json` e non ho eseguito test.

## Verdetto

**Nei quattro file modificati non trovo blocker.** Le correzioni di N1–N9 sono coerenti con il kernel originale. I fatti governati restano immutabili, la classificazione resta fuori dall'admission, e non ho trovato percorsi di doppio effetto o doppia callback. Le interazioni tra timeout, TTL, primo piano, late result e restart reggono.

Restano tre rilievi minori (sotto), nessuno bloccante.

Questo non certifica l'ecosistema. Instance, Work, Vigil, Morph e freelance restano fuori, insieme agli altri limiti già dichiarati.

**Stato dei log, senza inferenze:**
- **Suite completa precedente:** 4257 test verdi (1 doctest, 25 property, 4231 test) su OTP28 (`spectre-agent-server-otp28-tests.log:157`). Coverage 95,07% (`coverage-verified.log:158`). Entrambi i run sono **precedenti ai fix**.
- **Run mirati post-fix, con log presente:**
  - Checkpoint: 14 verdi.
  - Correzione tardiva con GAM reale: 2 verdi.
  - Plan: 8 verdi.
  - Planning boundaries: 12 verdi.
- **Run mirato senza log:** i «160 Runtime» citati in `STATUS.txt` non hanno un file in `validation/`.
- **Rerun completo sul codice congelato:** non ancora disponibile.

## Tabella N1–N9

| # | Stato | Evidenze |
|---|---|---|
| **N1** | **Chiuso** | **Comportamento:**<br>• `uncertain_governed` porta la pending a `:uncertain` e libera il primo piano (`runtime.ex:1829-1870`).<br>• `resolving_pending?` guarda solo `:resolving` (`:1822-1827`), quindi la coda non si blocca.<br>• Al timeout il worker resta vivo, `detached` e `uncertain` (`:269-273`), ed è escluso da `finish` (`:1210`).<br>• Il TTL salta `:uncertain` (`:1350`).<br>• Le risoluzioni vengono rifiutate (`:873-875`).<br>• Il late result arriva con `worker.event`, cioè l'input di conferma originale. Outbox e correlazione restano, e non parte nessun recovery automatico in esecuzione.<br>**Test:** `final_review_runtime_test.exs:159-206`, che copre crash di confirm/explain/resume, deadline più TTL scaduto più late result sull'input originale.<br>**Residuo accettato:** un crash di explain/resume senza checkpoint lascia quella sola consent in `:uncertain` fino al riavvio. Non blocca altro. |
| **N2** | **Chiuso** | `terminal?` vale solo per `:succeeded`/`:failed` (`operations.ex:73-78`).<br>**Test con GAM reale** (`no_effect_correction_test.exs:121-207`), per succeeded e failed:<br>• restart, poi `record_late_observation`, poi `deliver` per riferimento;<br>• la callback arriva sull'input originale e `operations` si svuota;<br>• un nuovo restart più una nuova delivery non producono una seconda callback;<br>• l'executor non viene rieseguito e Act e Attempt restano invariati. |
| **N3** | **Chiuso** (vedi R1) | • Sono accettate sia la tupla a 2 sia quella a 3 elementi (`checkpoint.ex:445-453`).<br>• `preserve_reconciliation` gira **prima** di `remap_projection` (`:433-435`).<br>• Ogni target deve corrispondere a una sola regola (`:455-463`).<br>• Il remap tocca solo `route_key`, `checkpoint_route.key`, `scope`, `protected` e `previous_route_keys`, cioè la provenienza (`:514-530`).<br>• Copre `current`, `queue`, `pending.origin`, eventi di outbox, inbox e `operations`, e i risultati route/interrupt (`:467-502`).<br>• Senza mappa il comportamento resta fail-closed.<br>• Il test copre tutte le posizioni, il round-trip save/load, target mancante, target ambiguo, mappa non valida, fatto modificato e input modificato (`checkpoint_route_migration_test.exs`). |
| **N4** | **Chiuso** | • `shown_pending_status` restituisce `:suspended` se la show è recuperata, incerta o se un altro id è in primo piano (`runtime.ex:596-601`).<br>• Il primo piano viene preservato (`:566-571`).<br>**Test:** resume da background, show tardiva dopo la deadline, show recuperata contro il primo piano creato da `init` (`final_review_runtime_test.exs:208-273`). |
| **N5** | **Chiuso** | • `pending_delivery_worker` trova il worker `:await_reply`, e `retire_delivered_worker` cancella timer e worker. Il `command_id` libera l'outbox (`runtime.ex:1783-1805`, `:1444`).<br>• `recovery_continuation` assegna `pending_id` solo ai kind stateful (`:1708-1723`).<br>**Test:** delivery doppia più restart; generate consegnato da fuori con il worker live ucciso e nessun duplicato (`:275-306`). |
| **N6** | **Chiuso** | • La release parte solo per i comandi governati (`runtime.ex:1536-1540`).<br>• Il risultato della release salta inbox, seen e save (`:1399-1400`).<br>**Test:** `seen_events`, `checkpoint_revision` e inbox restano invariati (`:308-332`). |
| **N7** | **Chiuso** | `stale_confirmation` restituisce `{:consent, :stale_input}` prima della validazione, quindi senza dead letter (`runtime.ex:630-631`, `:648-681`). La conferma resta legata a revisione, sequenza e origine (`:902-909`).<br>**Test:** `runtime_recovery_boundaries_test.exs:231-271` verifica nessun dead letter, nessun confirm e che un input nuovo successivo funziona. |
| **N8** | **Chiuso** (vedi R2) | `restore_failed_pending` porta a `:suspended` sia i casi `recovered`/`:uncertain` sia `previous == :foreground` quando il primo piano non è più quello (`runtime.ex:603-615`).<br>**Test:** `:335-356`. |
| **N9** | **Chiuso** | • `governed_unknown` e un Act con `outcome: nil` producono «still under verification» (`plan.ex:26-33`).<br>• La clausola Plan viene prima di quella generica `governed_unknown` (`server.ex:63-70`).<br>• Act nil con rifiuto produce «could not be confirmed».<br>• `succeeded` fa avanzare il piano.<br>**Test:** `planning_boundaries_test.exs:47-75`. |

## Rilievi nuovi (bassi, non blocker)

### R1 — Il migratore può cambiare `sequence`, che lega la freschezza della consent
`:sequence` manca dalla lista immutabile (`checkpoint.ex:535-549`). `confirmation_event?` usa `event.sequence > shown_at_sequence` (`runtime.ex:905`).

**Sequenza:**
1. Il checkpoint salvato ha `sequence` = 10 e un input in coda «sì» con sequenza 10.
2. Il migratore riporta `sequence` a 0.
3. Dopo il restart l'app fa `resume` della consent, e la nuova show ha `shown_at_sequence` = 0.
4. Il «sì» in coda, digitato prima della show, la può approvare.

Richiede un migratore host scorretto, che è codice fidato. Rompe però il contratto «immutabilità dei fatti».

**Fix:** aggiungere `:sequence` agli immutabili, oppure richiedere `migrated.sequence >= saved.sequence`. Aggiungere un caso in `checkpoint_route_migration_test.exs:122`.

### R2 — Dopo un restart, una pending con un comando governato in recovery risulta `:suspended`, non bloccata
`restore_state` imposta `:suspended` per tutte le pending (`checkpoint.ex:72-75`). Durante `recover_command` l'app può quindi chiamare `resume_pending` (`runtime.ex:873-882` lo permette).

Se il recovery termina con `{:error, _}`, `restore_failed_pending` riporta la pending a `:suspended` mentre il resume concorrente è ancora in corso. Il lock si perde e lo stato diventa incoerente.

Non c'è doppio effetto né doppia callback, grazie all'idempotenza del kernel e alla chiave `gam-result` in `seen_events`.

**Fix:** in `restore_state`, marcare `:uncertain` le pending referenziate da un'entry di outbox governata con `args == [pending_id]`. `restore_failed_pending` già converte `:uncertain` in `:suspended`.

### R3 — La delivery `{:pending, id}` dopo un `:DOWN` lascia l'entry di outbox del confirm
Dopo il crash non c'è più un worker, quindi il fallback di `pending_delivery_worker` non ha `command_id` (`runtime.ex:1786-1787`). Ne seguono due effetti:
- l'outbox del confirm resta fino al restart, dove viene deduplicata senza callback;
- la callback usa `pending.origin` invece dell'input di conferma.

La via `{:command, id}` invece è pulita (`:1807-1816`).

**Fix:** nel fallback, cercare l'entry governata dell'outbox con `args == [pending.id]` e usarne `command_id` ed `event`.

## Interazioni verificate senza problemi
- **Timeout del confirm più TTL scaduto più late result:** la pending resta `:uncertain`, il timer viene consumato senza scadenza, e il late `{:error,_}` riarma il timer, che scade subito e una volta sola (`:603-614`).
- **Show tardiva su worker incerto:** resta `:suspended` con revisione incrementata.
- **Delivery su worker detached:** `retire` lo rimuove, e un risultato live successivo viene ignorato perché il ref non c'è più.
- **Correzione tardiva:** un no-effect seguito da successo fa proseguire il Plan, come richiesto.

Il prossimo passo è il rerun completo con coverage sullo snapshot congelato. Finché non c'è, non lo considero verde.