# Verifica dei fix (P1-1, P1-2, P1-3 e P2 correlati)

**Verdetto: READY nel perimetro richiesto.** Nessun blocker; restano due P2 nuovi su Ledger `ServerStore` e una nota minore (P3). Confidenza medio-alta.

Ho solo letto il codice: non ho eseguito test né compilazione. Le suite che citi (Mnemonic, Lens, Ledger, Pulse, i nuovi test di migrazione, l'integrazione e la copertura del core) non le certifico.

## P1-1: Ledger e Lab confinati al checkpoint corrente — risolto
- `Checkpoint.tool_reference/1` (`checkpoint.ex:187-196`) ricava `%{adapter, store, key}` dalla config del runtime. Arriva al worker come `checkpoint_ref` (`tool.ex:87`), non passa da prepare, assigns o outbox.
- Ledger (`ledger/server_tool.ex:41-46`) accetta solo `scope: :current` o la chiave uguale a quella del checkpoint; ogni altra chiave dà `:checkpoint_scope_mismatch`.
- `head` restituisce solo `revision`, `bytes` e `digest` (`:50-65`), con `max_bytes` a 64 KiB.
- Lab con `{:inspect, :checkpoint}` legge e decodifica nel worker e restituisce solo i conteggi. Il binario esplicito resta come ispezione offline, limitato a 1 MiB.
- L'integrazione segue la nuova catena (`workflow.ex:146-149`).

## P1-2: migrazione con lavoro in corso — risolto
- `migrated?` vale true solo se il migratore esplicito ha cambiato il fingerprint (`checkpoint.ex:78-81`). Il flag resta in memoria e viene rimosso in `validate_persisted!` (`tool.ex:131`).
- La marca `tool_contract_changed` viene salvata insieme all'entry e su un reload successivo è accettata anche senza migrazione (`tool.ex:184-189`).
- Esiti per tipo di entry (`runtime.ex:2380-2416`):
  - propose avviata (o legacy senza flag): `recover_governed`, con notifica;
  - propose non avviata: `{:error, :tool_contract_changed}`;
  - `:never`: `tool_unknown`;
  - `:safe`: errore, senza toccare il nuovo adapter.
- Il fence in `execute_entry` (`:1654`) copre anche le entry bloccate e poi rilasciate: `execute_entries`/`execute_current_entry` passano sempre da `execute_entry`. Non ho trovato percorsi che lo aggirino.

## P1-3: compattazione di `ServerStore` — risolto
- La compattazione include la mutazione pendente prima della risposta (`server_store.ex:138-159`). Se lo spazio non basta risponde con errore e lo stato precedente resta intatto.
- La scrittura è atomica: file temporaneo esclusivo con permessi 0600, fsync, rename, fsync della directory (`:213-244`). Anche la prima creazione usa questo percorso, quindi il file vuoto non si produce più.
- Il replay di SPLS2 verifica header, conteggio, ordine delle sequenze, `revision <= sequence` e unicità delle chiavi (`:294-378`). SPLS1 viene letto in modo retrocompatibile.

## P2 correlati — verificati
- Il limite unico `Checkpoint.max_bytes/0` è usato nello staging (`checkpoint.ex:201`) e nei descrittori (`tools.ex:16`).
- Una `confirmation` non portabile ora è errore di programmazione (`tool.ex:46-47`).
- Mnemonic richiede `stack_runtime` e proietta con allowlist per struct; la partizione è fissata nella Candidate e ricostruita dall'executor (`host.ex:49-54,192-200`).
- `bind:` di Beam e Pulse è validato.
- L'executor dell'esempio restituisce `:ambiguous` con evidenza vuota; solo `already_contacted` attesta `:definitive_no_effect`.

Non ho trovato regressioni di correttezza in questi percorsi.

## Residui non bloccanti

**P2-a. I tombstone non vengono mai eliminati, quindi la crescita non è limitata nemmeno con la compattazione**
- **Dove:** `server_store.ex:171-173,198-205`, insieme a `gam.ex:267-275`.
- **Trigger:** ogni `release_command` cancella la propria chiave di journal (una per comando). Il tombstone sopravvive a ogni compattazione, e lo stesso vale per le chiavi di conversazione cancellate.
- **Impatto:** l'insieme dei dati vivi cresce di circa 100–200 byte per comando, per sempre. Dopo un volume finito (circa milioni di comandi con 256 MiB) si torna a `:store_capacity_exceeded` in modo permanente.
- **Fix:** assegnare a `put_new` dopo una cancellazione la revisione `max(precedente, sequenza globale) + 1`. Così le revisioni restano monotone e i tombstone si possono scartare in compattazione senza rischio ABA.

**P2-b. Le chiamate `fetch` possono andare in timeout durante una compattazione lunga**
- **Dove:** `server_store.ex:33`, dove `fetch` usa il timeout di default di 5 s.
- **Trigger:** una compattazione vicino alla capacità (fino a 256 MiB più due fsync) si esegue dentro la chiamata dello store.
- **Impatto:** `Checkpoint.load` all'avvio di un Server, i fetch del journal GAM e i tool Ledger/Lab possono uscire per timeout, con restart o errore. Inoltre, se i dati vivi restano vicini al limite, ogni scrittura scatena una compattazione completa.
- **Fix:** timeout esplicito o `:infinity` su `fetch`, coerente con le operazioni di scrittura; oppure compattare con un margine di isteresi (per esempio compattare all'X% e richiedere dati vivi sotto una soglia più bassa).

**P3. L'allowlist Mnemonic si applica solo alle struct** (`projection.ex:56-57`). Le mappe semplici annidate, per esempio `SearchResult.record` quando il payload persistito è una mappa, passano per intero. Oggi non ho trovato mappe sensibili in questi percorsi; è una nota per evoluzioni future.

**Limiti dichiarati e accettati:**
- tail troncati gestiti in modo fail-closed;
- lo store di coordinamento non è un archivio immutabile;
- i dati vivi devono stare nella capacità;
- provider live e multi-nodo restano fuori dalla validazione.

L'evidenza xref sulla dipendenza di compilazione Server → Stack chiude il punto P2-9 della review originale.