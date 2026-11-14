# GAM automatico in AgentServer 0.4

Questa modifica sostituisce il limite della precedente proposta: non esistono
un percorso automatico di sviluppo e un percorso manuale di produzione.
`Spectre.Server.start_link/1` costruisce sempre l'integrazione GAM. L'applicazione
non implementa Host, ingress, Scope o protocollo di consenso.

La guida corrente è [MANAGED_GAM.md](../MANAGED_GAM.md); la demo Phoenix è nel
repository fratello `demo_spectre`.

## Confini delle responsabilità

- **Applicazione:** autentica identità e trasporti; registra gli adapter; dichiara
  operazioni autorizzate, persistenza e regole di business. Può richiedere
  conferma, restringere o rifiutare. L'installazione di un tool non concede
  automaticamente il permesso di usarne gli effetti.
- **AgentServer:** acquisisce i comandi restituiti dai callback, congela policy e
  materiale, costruisce proposte e presentazioni, correla consenso e pending,
  gestisce timer, ripresa, streaming e processi Skill. Lo Scope resta privato.
- **GAM:** verifica autorità e consenso, ammette prima dell'esecuzione, conserva
  Act/Attempt/Outcome/Evidence e responsabilità. Nessun callback trasforma un
  risultato incerto in successo né cancella un Duty chiudendo una conversazione.
- **Reviewer indipendente:** quando configurato, può proporre la disposizione
  di un Duty con supporti verificabili. Spectre costruisce automaticamente il
  suo percorso separato. L'agente causale non si attribuisce quel ruolo.

Le operazioni esterne usano `Spectre.GAM.submit/4`, con la stessa preparazione,
policy e ammissione del Server. La chiave opzionale permette di ripetere una
richiesta acquisita senza creare un'altra azione, anche dopo recovery.
`Spectre.GAM.revoke/1` registra una revoca persistente; `resolve_duty/4` usa
l'autorità indipendente configurata. Il kernel autonomo resta utilizzabile
anche senza il DSL Agent: non è un'alternativa per disattivare GAM nel Server.

## Correzioni sostanziali

Il broker di sviluppo è stato sostituito da un broker mediato: verifica la
ricevuta per Act/Attempt, acquisisce il claim nello storage e consuma una
capability monouso prima di chiamare l'adapter. Il grantor iniziale è
l'applicazione, non un consenso umano inventato. Identità e configurazione sono
validate, congelate e confrontate al recovery; alias di storage locali non
possono creare due owner. Un'autorità scaduta può essere riaperta per leggere
lo storico, senza riottenere permessi sugli effetti.

La review ha identificato un difetto precedente nel kernel: i target esatti
rendevano irraggiungibile la disposizione di Duty creati dopo Genesis. La
correzione è limitata a Mandate con sola classe `duty.dispose`, Duty esistente
aperto, autorità nominata e mandato causale coperto da una catena verificata
che non amplia i permessi. Restano invariati i controlli di indipendenza,
materiale, supporti, revoca, scadenza e condizioni di chiusura. L'indice contiene
solo riferimenti ai Duty aperti; i percorsi indicizzati ed esaustivi sono
verificati contro lo stesso risultato.

## Review e verifiche

Opus 5.5 ha esaminato sia l'architettura sia la correzione della disposizione:
[review architetturale](reviews/claude-opus-5.5-automatic-gam-architecture.it.md),
[review Duty](reviews/claude-opus-5.5-automatic-gam-duty.it.md).
La [risoluzione finale](reviews/automatic-gam-final-resolution.it.md) distingue
i difetti corretti dalle ipotesi non confermate e collega la review del codice.

I test che iniettano bridge finti o PID nelle identità sono test isolati del
protocollo e ora avviano il Runtime interno. Non è stato introdotto un bypass
nell'API pubblica. I test pubblici usano il Domain reale e verificano consenso,
revoca, actor esterni, deduplicazione, identità, recovery e reviewer indipendente.
La demo e `integration/stack_tools` usano il bootstrap automatico con le nove
librerie.

Verifica finale sul codice consegnato, 14 novembre 2026:

- Core: **4.500 verifiche passate** (1 doctest, 25 proprietà, 4.474 test),
  1 esclusa; suite completa in 211,2 secondi.
- Dialyzer: **0 errori**; documentazione ExDoc con `--warnings-as-errors`,
  formattazione e `git diff --check` completati senza errori.
- Integrazione Stack con le nove librerie: **4/4**.
- Demo Phoenix: `mix precommit` **27/27**; ultimo smoke test Chromium del
  workflow con nove librerie **1/1**, su server riavviato dal codice finale.
- Review finale del codice con Opus 5.5 completata; correzioni e valutazione
  dei rilievi sono registrate nella risoluzione collegata sopra.

Le modifiche rimangono locali sui branch di lavoro, senza commit, push o merge
in questa consegna. Le verifiche dettagliate della demo sono registrate nel suo
`docs/VERIFICATION.md`.

La documentazione di follow-up esplicita ora anche la condivisione tra Skill:
un solo collegamento GAM e Domain/ledger, stato e checkpoint locali, allowlist
del mount, provenienza, conferme isolate e timer registrati. README e guide
attive del core e delle nove librerie sono allineati. Nella demo,
`docs/SHARED_GAM.md` segue il percorso nel codice. Dopo questi aggiornamenti,
ExDoc senza warning passa nel core e nelle nove librerie, `mix precommit` passa
27/27 e Chromium passa 2/2 (workflow completo e consenso parallelo tra Skill).

## Limiti dichiarati correttamente

Il codice Elixir dell'applicazione è fidato: GAM media i percorsi dichiarati,
non intercetta una chiamata HTTP arbitraria eseguita direttamente in un callback.
L'applicazione autentica gli esseri umani e l'indipendenza reale del reviewer.
Lo storage effimero termina con il Domain; quello su disco consente recovery.
L'esclusività del filesystem tra VM scollegate richiede infrastruttura coerente,
non un nuovo Host applicativo. La demo usa modello deterministico e mailbox
locale; non verifica consegna SMTP reale o un provider LLM remoto.
