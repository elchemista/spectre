# Risposta ai rilievi di implementazione Opus 5.5

La [review originale](claude-opus-5.5-stack-tools-implementation.it.md) resta
immutata. Questo documento è la risposta degli implementatori, non una nuova
approvazione di Opus. Le evidenze finali sono nel
[rapporto di verifica](../stack-tools-0.4-verification.it.md).

## P1

1. **Ledger e confidenzialità:** `head` restituisce solo revisione, digest e
   dimensione. `head` e `entries` sono limitati alla chiave del checkpoint del
   Server, ricevuta dal runtime in un riferimento fidato solo per il worker tool.
   Lab accetta `{:inspect, :checkpoint}` e legge/decodifica nel worker; il blob
   non passa dall'inbox/outbox dell'agente. Gli accessi ad altre chiavi sono
   rifiutati. L'input binario esplicito di Lab resta un'ispezione offline.
2. **Migrazione con lavoro in corso:** resta obbligatorio un migratore esplicito
   per il cambio di fingerprint. Le identità e i fatti originali non vengono
   riscritti. Il runtime marca il contratto cambiato: termina i comandi cognitivi
   senza richiamare il nuovo adapter, rifiuta proposte governate non iniziate e
   riconcilia quelle già iniziate tramite il journal GAM originale. La marca
   sopravvive a un ulteriore crash. Non viene autorizzato un retry implicito.
3. **Capacità Ledger:** compattazione atomica automatica al limite e API
   `compact/1` esplicita. Mantiene tutti i valori vivi, i record del journal GAM,
   la sequenza globale e le revisioni dei tombstone. Anche la prima creazione
   usa file temporaneo esclusivo, fsync, rename e fsync della directory.
   La capacità deve comunque contenere i dati vivi; non è un archivio immutabile.

## P2 e test

- Il limite aggregato è unico (`Checkpoint.max_bytes/0`), con margine per gli
  envelope dello store; anche la validazione dei descrittori lo usa.
- L'executor dell'esempio conserva l'ambiguità degli errori di trasporto: non
  inventa un Outcome fallito. I package conservano le proprie convenzioni di
  errore, rese portabili e limitate; l'host traduce esplicitamente nel contratto
  del proprio executor GAM.
- Mnemonic richiede un runtime Stack per i tool espliciti. Il fallback legacy
  della vecchia API Memory resta per compatibilità. Il test usa isolamento per
  soggetto reale; il candidato host congela la partizione e l'executor la legge
  dal candidato ammesso. La proiezione usa allowlist esplicite per struct/campi.
- `bind:` di Beam e Pulse viene validato; un refuso non nasconde più l'operazione.
- Una `confirmation` non portabile è errore di programmazione, coerentemente con
  `on_result`; non diventa un rifiuto di dominio.
- Tail troncati restano **fail closed**: senza evidenza esterna non si può sapere
  se il record danneggiato fosse già stato acknowledged. La documentazione
  chiarisce questa scelta e la differenza fra tombstone, compattazione ed
  eliminazione fisica da backup/supporti.
- La dipendenza di compilazione Server → Stack è verificata con un progetto
  Mix separato: cambiando solo la configurazione Stack vengono ricompilati
  Stack e Server, e il descriptor catturato cambia. Nessun fix necessario:
  [evidenza](stack-tools-compile-dependency.md).
- La validazione completa dello stato ha un costo proporzionale alla sua
  dimensione. Non è stata sostituita con un'ottimizzazione priva di benchmark;
  il limite rimane esplicito. Le prestazioni a stati prossimi al limite non sono
  certificate dai test funzionali.
- Le asserzioni di integrazione contano le ammissioni all'executor, oltre alle
  ricevute del Sink, e cercano il contenuto effettivo salvato. Le due correzioni
  erano già in corso mentre Opus leggeva la prima versione del test.
- Il test di riavvio riapre davvero Ledger dal file dopo la terminazione del
  processo; un'altra prova uccide il Server fra generazione e callback Kinetic,
  verificando AL durevole, una sola chiamata al modello e nessun AL nei messaggi
  consumer. I test Stream del core verificano già AL spezzata fra chunk.
- Aggiunte prove per Pulse execute, Lens act/close, scadenza del consenso e
  proposta tool governata interrotta durante la presentazione, seguita da cambio
  del descrittore e riconciliazione.

Restano fuori da questa attestazione provider live e concorrenza multi-nodo.
Non è stata modificata alcuna legge del kernel GAM.

## Follow-up READY e ultime osservazioni non bloccanti

[Opus ha verificato i fix e restituito READY](claude-opus-5.5-stack-tools-implementation-followup.it.md)
nel perimetro richiesto, senza regressioni bloccanti. Le sue due ulteriori P2
Ledger sono state poi chiuse: `put_new` usa un contatore globale monotono per
impedire ABA; la compattazione può così rimuovere i tombstone da memoria,
cronologia e file. Il marker di checkpoint 2 impedisce ai vecchi reader di
riaprire silenziosamente il formato senza questa garanzia. I reader nuovi
mantengono compatibilità con SPLS1 e checkpoint 1. `fetch` ed `entries` usano
attesa esplicita coerente con le scritture, evitando il timeout predefinito
mentre lo store compatta. Una revisione incrociata separata ha controllato
watermark, CAS, replay, downgrade fail-closed e ordinamento delle conferme dopo
fsync; non ha rilevato difetti concreti. I test finali sono nel rapporto.

La nota P3 sulle mappe semplici Mnemonic resta una considerazione per evoluzioni
future: i dati applicativi già persistiti come mappe rimangono dati applicativi.
Le struct del package e i loro campi tecnici passano dall'allowlist; non è stata
introdotta una cancellazione arbitraria del contenuto utente delle mappe.
