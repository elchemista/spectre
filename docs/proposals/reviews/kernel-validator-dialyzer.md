# Validatori GAM: ottimizzazione dell'inferenza, senza modifiche al modello

Il solo `validate_refs/1` di [Act](../../../lib/spectre/gam/act.ex) e
[Decision](../../../lib/spectre/gam/decision.ex) è stato diviso in quattro
gruppi privati sequenziali, rispettivamente da sei e cinque controlli.
Ogni gruppo viene chiamato soltanto dopo `:ok` dal precedente. Espressioni,
ordine, primo errore e valutazione lazy restano quelli del kernel importato da
`6906258`. Non sono cambiate typespec, rappresentazioni canoniche, permessi o
leggi GAM. Candidate e il resto del kernel non ricevono questo refactor.

## Misura isolata

Diagnostica con Erlang/OTP 29.1.1, Elixir 1.20.4, due scheduler e PLT delle sole
dipendenze già verificata. `:dialyzer.run` analizza tutti i **207 BEAM GAM**;
nessun Runtime/Server è tra i file analizzati. Il secondo run sostituisce
soltanto i BEAM di Act/Decision, compilati inizialmente in una directory
temporanea. Tracing delle SCC e timing di fase restano diagnostici: nessun
warning è filtrato o soppresso.

| Caso | Misura |
| --- | --- |
| Catene originali | Compilazione interna: 0,74 s. Primo typesig: 1,37 s. Nel secondo typesig, `Decision.validate_refs/1`: **43,8 s**; `Act.validate_refs/1`: **oltre 290 s** ancora nella stessa SCC. Run non concluso al momento del confronto; nessun esito sui warning è deducibile da questo run incompleto. |
| Gruppi sequenziali | Analisi completa degli stessi 207 moduli: **16,598 s**, **0 warning**. Fase finale warning: 1,73 s. |

I log diagnostici locali sono `/tmp/spectre-gam-dialyzer-diag.log` e
`/tmp/spectre-gam-refactor-dialyzer-diag.log`; gli elenchi esatti dei file sono
nei corrispondenti `*-files.txt`. La misura comprende l'analisi fresca di GAM
su una PLT delle dipendenze già disponibile: non misura la costruzione da zero
della PLT né costituisce il risultato del controllo finale dell'intero progetto.
I due run avvenivano mentre un altro checker era attivo, quindi il confronto
non è un benchmark di throughput isolato. Localizza però il costo nelle due
SCC originali e mostra che il refactor lo elimina senza ampliare le specifiche.

## Verifica dell'equivalenza

Da un checkout che contiene il commit sorgente dell'import:

```sh
elixir scripts/check_gam_validator_equivalence.exs
```

Il [comparatore AST](../../../scripts/check_gam_validator_equivalence.exs)
legge i due file originali con `git show 6906258`, applica la sola rinomina
`Spectre` → `Spectre.GAM` e rimuove i metadata del parser. Espande soltanto gli
helper chiamati con lo stesso argomento; appiattisce le catene `with` composte
da match `:ok` e verifica l'identica sequenza di espressioni: **20 controlli
Decision e 24 Act**. Verifica anche che l'AST esterno ai validatori sia identico.
Un cambio di espressione, ordine, argomento o codice estraneo fallisce il check.

[validator_order_test](../../../test/gam/core/validator_order_test.exs) parte
da Decision/Act realmente ammessi e verifica coppie di campi invalidi attraverso
tutti i confini dei gruppi, oltre a un record con molti errori contemporanei.
Le asserzioni richiedono il medesimo primo errore originale; i record validi
devono restare identici. Il run successivo al refactor su `test/gam/core` e
sulle quattro suite del bridge/Server GAM è passato: **1436 casi, zero failure**
(13 proprietà e 1423 test), in 27,7 s. Log locale:
`/tmp/spectre-gam-validator-refactor-tests.log`. Copre ammissione, prove, replay,
recovery e le nuove combinazioni di errori. Il risultato del Dialyzer completo
del progetto rimane separato da questa misura isolata.

La differenza intenzionale è registrata come `pure_optimization` in
[IMPORT.json](../../../test/gam/IMPORT.json).
