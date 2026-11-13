# Stack tools 0.4 — implementazione e verifica

Il core resta su `feature/agent-server-gam`, versione **0.4.0**. I nove package
installabili hanno il branch **`feature/stack-tools-0.4`**. Non sono stati fatti
push o merge. Studio ed Ecosystem non espongono il contratto installabile e non
richiedono un adapter tool.

| Repository | Base satellite | Commit finale | Modifica principale |
| --- | --- | --- | --- |
| spectre_kinetic | `3b69444` | `500b1b1` | Registrazione `kinetic`, planner reale, metadati delle proposte |
| spectre_mnemonic | `85bf12c` | `69620f2` | Engine 0.2 per Stack, recall portabile, remember governato e isolato |
| spectre_lens | `52f258f` | `932e4ae` | TabRef logici, view non attendibili, act governato e close |
| spectre_prism | `fcbac6b` | `251e411` | Selezione modello con contesto completo del Server |
| spectre_beam | `6a0b6f9` | `abadac8` | Endpoint/delivery, ingresso Server, esiti incerti conservati |
| spectre_directive | `561037f` | `f66ca38` | Reducer portabile nel loop del Server |
| spectre_pulse | `8b98233` | `30a2c1d` | Protocollo/contatti/send, ingresso autenticato nel Server |
| spectre_ledger | `d69c875` | `645ecf4` | Store CAS durevole e compattazione per checkpoint e journal GAM |
| spectre_lab | `857f33e` | `efc4707` | Ispezione read-only del checkpoint corrente nel worker |

Mnemonic conserva il proprio `main` e parte dalla base 0.2 con Engine isolato;
Prism e Pulse partono dalle rispettive basi compatibili 0.3, evitando di
trascinare l'authoring sperimentale della precedente linea 0.4.

## Contratto effettivo

La callback opzionale `Spectre.Stack.Installable.tools/1` dichiara descrittori
immutabili. `use Spectre.Server, tools: MyApp.AI` genera helper privati con due
o tre argomenti. Non esistono import inventati dalle librerie.

Il core valida binding effettivo, digest, adapter, collisioni e dimensioni.
Normalizza i comandi prima dell'acquisizione durevole. Una chiamata cognitiva
avviene in un worker; un'operazione governata diventa `propose` e attraversa il
bridge GAM standard. L'host fornisce mandati, candidati, ingressi, interpreti ed
executor. La sola installazione non concede autorità.

`kinetic(ctx, response)` interpreta AL consolidato e conserva owner, scope,
provider e hash dello schema. Il risultato non esegue azioni. Mnemonic, Lens,
Beam e Pulse espongono operazioni con effetti soltanto se collegate a un binding
host. Directive non avvia un secondo loop. Ledger e Lab operano sul codec reale.

Gli errori di dominio arrivano al callback correlato. Errori di programmazione
o stato aggregato non portabile non vengono acquisiti come successi. Un tool
non ripetibile con risultato incerto, anche dopo una proiezione fallita, mantiene
l'identità del comando e restituisce `tool_unknown`.

## Verifica

Ambiente locale: Elixir 1.20.4 / Erlang OTP 29.1.1. Le suite ExUnit sono
eseguite in sequenza, per evitare collisioni fra fixture legacy condivise.

| Area | Risultato |
| --- | --- |
| Core completo sullo snapshot finale | **4378 passati**: 4352 test, 25 proprietà, 1 doctest; 1 escluso |
| Copertura core | **95,09%**, soglia originale 95% invariata |
| Integrazione reale dei nove package | **3 passati**, modello/browser/email esterni simulati |
| Core mirato dopo la review | **50 passati**, compresi migrazione e riconciliazione |
| Kinetic | Suite completa **1336 passati**, poi **10 mirati** sulle ultime correzioni |
| Mnemonic | Suite completa **531 passati**, 11 embedding esclusi |
| Lens | Suite completa **181 passati**, 19 browser esclusi |
| Prism | Suite completa **80 passati**, poi **3 mirati** sul contesto del selector |
| Beam | Suite completa **198 passati** (1 doctest incluso) |
| Directive | Suite completa **160 passati** |
| Ledger | Suite completa **113 passati** |
| Lab | Suite completa **88 passati** |
| Pulse | Suite completa **188 passati** |
| Core format, compile warning come errori, Credo | Passati |
| Core Dialyzer | **0 errori, 0 skip** |

I test mirati sono sovrapposti alle suite, non si sommano come casi distinti.
I package hanno formato, compilazione e controlli statici sulle modifiche puliti.
La suite completa finale del core è passata con sorgenti congelati.
Il log conclusivo locale è `/tmp/spectre-stack-tools-core-final-coverage.log`;
la copertura HTML è in `cover/`.

Una prima esecuzione completa durante le correzioni aveva 4369/4370 passati e
95,09% di copertura: il solo fallimento era il sottoprocesso del generatore, che
aveva letto il nuovo riferimento a `Checkpoint.max_bytes/0` prima che la funzione
fosse stata scritta. Non è usata come risultato finale. La verifica conclusiva
usa sorgenti congelati.

Comandi principali:

```sh
# core
mix format --check-formatted
mix compile --warnings-as-errors
mix credo
mix dialyzer
ERL_FLAGS='+S 4:4' mix test --cover

# integration/stack_tools
mix deps.get
mix test

# nei package con dipendenza opzionale locale di test
SPECTRE_PATH=../spectre mix test
```

Hex segnala `erlexec 2.3.4` come deprecato nella dipendenza Lens preesistente;
questa migrazione non ne sostituisce il backend. Mint e ReqLLM sono aggiornati
nei lock dove necessari entro i vincoli compatibili.

## Agente completo e limiti

L'[esempio eseguibile](../../integration/stack_tools/README.md) contiene Stack,
Agent, Server, host e test. Usa tutte e nove le librerie: sito Lens, contesto
Mnemonic, modello Prism, AL Kinetic, effetto GAM, notifica Beam, protocollo Pulse,
metadata Ledger, analisi locale Lab e consenso prima della scrittura Mnemonic.
Verifica anche isolamento fra soggetti, processo Ledger terminato e riaperto dal
file, owner ucciso fra generazione e Kinetic, assenza di seconda chiamata al
modello, assenza di AL nei messaggi consumer e conteggio reale degli executor.

Browser, modello ed email esterni sono simulati in modo deterministico. Le API
dei package, il kernel GAM, lo store e il motore di memoria sono reali. Il test
non invia email e non certifica credenziali o protocolli di produzione. I test
browser/embedding esclusi nelle suite satellite restano esclusi esplicitamente.
`freelance` non è stato modificato né migrato automaticamente.

## Review

Il piano ha ricevuto due review reali di Opus 5.5; le condizioni sono nella
[risoluzione del piano](reviews/claude-opus-5.5-stack-tools-resolution.it.md).
La review incrociata dell'implementazione ha rilevato e fatto correggere la
perdita del contesto Prism e il trattamento errato delle proiezioni fallite dei
tool non ripetibili. La [review di implementazione](reviews/claude-opus-5.5-stack-tools-implementation.it.md)
ha richiesto tre correzioni bloccanti. Dopo le correzioni e i test aggiunti,
[Opus ha espresso READY nel perimetro verificato](reviews/claude-opus-5.5-stack-tools-implementation-followup.it.md),
senza blocchi residui. È una review del codice, non una certificazione delle
suite: i risultati dei test sono quelli eseguiti e registrati dagli implementatori.
La [risposta ai rilievi](reviews/claude-opus-5.5-stack-tools-implementation-resolution.it.md)
documenta anche le scelte tecniche e i limiti. Risposte originali e metadata del
modello `claude-opus-5-5` sono conservati senza modificarne il verdetto.
