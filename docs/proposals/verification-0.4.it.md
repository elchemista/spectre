# Verifica del branch Agent/Server 0.4.0

Branch `feature/agent-server-gam`, da `origin/main` (`1059bd8`).
Kernel sorgente `6906258`, importato sotto `Spectre.GAM`.
Verifiche locali del 13 novembre 2026; nessuna pubblicazione o merge.

**Stato:** i [tre problemi della review](remaining-fixes-0.4.it.md), comprese
le race aggiuntive della chiusura differita, sono risolti. La
[review indipendente conclusiva](reviews/cross-review-lifecycle-resolution.it.md)
non ha trovato blocker residui nel perimetro riesaminato. I risultati sotto
si riferiscono al freeze finale e sono confermati su entrambe le versioni OTP.

| Controllo | Risultato |
| --- | --- |
| Suite completa, Elixir 1.20.4 / OTP 29.1.1 | **4.323 passati**: 4.297 test, 25 proprietà, 1 doctest; 1 escluso |
| Copertura della stessa esecuzione | **95,10%**, soglia originaria **95%** invariata |
| Elixir 1.19.5 / OTP 28.5 | **4.323 passati**, zero failure, 1 escluso; compilazione senza warning passata |
| Budget prestazionali esistenti di Instance | **3 passati**, profilo CI esplicito; non è un benchmark del nuovo Server |
| Embedding reale ExFastembed | 1 test passato nel ciclo precedente con modello locale e Vettore 0.3.6; non rieseguito per gli ultimi fix del runtime |
| Compilazione corrente | `mix compile --warnings-as-errors`: passata |
| Formattazione | `mix format --check-formatted`: passata |
| Credo, regole CI | `mix credo`: nessun problema |
| Credo strict | Eseguito nel ciclo precedente; restano suggerimenti di stile/alias, anche nei sorgenti importati e legacy. Non dichiarato passato |
| Documentazione | `mix docs --warnings-as-errors`: passata |
| Pacchetto | `mix hex.build --unpack`: costruito localmente; **671 file** confrontati con il checkout, percorsi di sviluppo esclusi; nessuna pubblicazione |
| Audit dipendenze | Nessun package ritirato o con advisory rilevato |
| Dialyzer | **Passato**, 0 errori, 0 esclusioni; 44,45 secondi |
| Review finale | Review incrociata Runtime e GAM completata senza blocker residui nel perimetro; le review Opus precedenti sono conservate, ultimo tentativo interrotto dal limite di utilizzo |

La suite ordinaria esclude i profili embedding reale e prestazionale. I tre
budget Instance sono stati eseguiti separatamente sul freeze finale; il test
embedding reale appartiene al ciclo precedente. Questi risultati non dimostrano
un miglioramento prestazionale del nuovo Server.

La configurazione Dialyzer rimuove Spectre dalla **PLT delle dipendenze**, così
non viene analizzato due volte come dipendenza di sé stesso. L'analisi del
progetto continua a ricevere tutti i suoi BEAM; non sono introdotti filtri di
warning o esclusioni di sorgenti.

## Riproduzione

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
SPECTRE_PERF_TESTS=1 mix test test/instance_performance_test.exs --include perf
mix credo
mix docs --warnings-as-errors
mix hex.build --unpack --output /tmp/spectre-0.4-package
mix dialyzer
```

Per la matrice OTP 28 è usata una build distinta, con `MIX_ENV=test` e
`MIX_BUILD_PATH` assoluto. Le due suite vengono eseguite in sequenza: VM Mix
simultanee condividerebbero le directory temporanee per test.

Il profilo reale usa il checkout ExFastembed già vincolato nel lockfile del
profilo, modello locale `Xenova/bge-small-en-v1.5` e directory di build/deps
separate. Non è stato cambiato il contratto delle dipendenze per forzare la
compatibilità con il checkout esterno più recente.

## Interpretazione dei risultati

I primi giri hanno rilevato regressioni vere, poi corrette: callback avvelenate,
esiti governati incerti, consenso obsoleto, riferimenti di delivery, scadenza
prima dell'acquisizione e distinzione fra `cache: false` legacy e
`dataset_lookup: false`. Il giro finale include anche le regressioni su riprese
non avviate, deadline conservate dopo show fallite, report ritardati, singolo
worker lifecycle e chiusure indipendenti che sopravvivono a una callback
quarantinata. Non vengono sommati i conteggi dei gruppi mirati alla suite intera.

Il [metadata del freeze](reviews/cross-review-lifecycle-resolution.metadata.json)
registra il digest dei 1.003 sorgenti/test, gli hash dei sette file riesaminati
e gli esiti dei gate. L'ultima verifica conferma che sorgenti e test non sono
cambiati dopo il freeze; sono aggiornati soltanto i documenti di riepilogo.

I limiti di migrazione restano nello [stato di implementazione](implementation-status.it.md).
Le review originali restano separate dalla [risposta degli implementatori](reviews/claude-opus-5.5-implementation-resolution.it.md).
Una suite verde del core non attesta il porting completo di Instance, dei
package esterni o dell'applicazione freelance.
