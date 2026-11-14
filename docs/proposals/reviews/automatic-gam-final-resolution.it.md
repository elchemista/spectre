# Risoluzione della review finale Opus 5.5

La [review originale](claude-opus-5.5-automatic-gam-final.it.md) è un'analisi del
bundle di sorgenti, non una certificazione. I rilievi sono stati verificati sul
codice completo e con regressioni. L'API applicativa resta unica e automatica.

| Rilievo | Risoluzione |
| --- | --- |
| Digest della risposta interpretata | Ingress calcola il digest dal testo effettivamente interpretato; copiare il digest di un altro input non consuma la prova. Test negativo dedicato. |
| Errore prima dell'adapter | Preparazione isolata: uscita del Managed o errore di risoluzione prima dell'adapter produce `definitive_no_effect`. Errori durante l'effetto restano incerti. |
| Dettagli sensibili degli errori | Gli atomi sono conservati; gli altri dettagli diventano digest. Test con credenziale nel messaggio del provider verifica il ledger. |
| Accesso audit | `gam_view` richiede il consumer configurato o il reviewer; la richiesta al Managed deve provenire dal runtime. |
| Checkout dello stato completo | Già corretto dopo il bundle: allowlist minima, senza Scope/capability del reviewer o opzioni applicative annidate. |
| Callback `presentation: nil` | Falso positivo: sempre rifiutato dal validatore. Aggiunta regressione anche con conferma inizialmente disabilitata. |
| Presentazione duplicata | Gate rifiuta il ref duplicato e preserva worker e prova originali. |
| Chiavi tra submitter | Contratto intenzionale: namespace condiviso per Agent/Domain tra processi applicativi autorizzati. Serve a deduplicare lo stesso job fra worker e dopo restart; non conferisce consenso né cambia l'identità. |
| Restart durante drain | Lock attende con monitor solo quando il vecchio runtime è morto; collisione con owner vivo rifiutata. Shutdown segue il timeout. Test reale sotto supervisor: effetto unico e recovery. |
| Duty senza mandato causale | I percorsi Managed configurati non generano quel caso. Nessun allargamento della copertura: test di rifiuto esplicito per Duty senza mandato. |
| Provenienza esterna falsificabile nei comandi | Opzione riservata rifiutata nella validazione pubblica; il runtime aggiunge l'attribuzione solo dopo acquisizione/validazione. |
| Tag `on_result` esterno | Scelta esplicita del chiamante applicativo autorizzato, come gli altri helper; tutti i comandi successivi restano soggetti a GAM. |
| Consumer assente | Gate restituisce errore senza crash. |
| Identità esplicita duplicata | Una stessa identità seleziona deliberatamente un Domain. Conversazioni distinte usano `conversation`; identità omessa effimera viene generata univoca. |
| Vecchio indice | Recovery rigioca il ledger canonico, non uno State arbitrario. Aggiunti comunque versione dell'indice e fallback per vecchi indici in memoria. |
| Re-show e identity key | Falso positivo: resume riceve un nuovo command ID; test su disco dimostra nuovo show e un solo effetto. |

Ulteriori correzioni: segreti grant/checkout distinti; caricamento esplicito del
modulo Store; opzioni executor limitate; timeout invalidi rifiutati prima
allocazione; predecessori calcolati una volta per vista esaustiva; riferimenti
actor esterni separati per generazione del runtime.

La disponibilità del filesystem tra VM scollegate resta un requisito
infrastrutturale esplicito. Una capability già consumata non produce un falso
`no_effect` al replay: l'esecuzione precedente potrebbe essere avvenuta.
L'identità rappresentata e l'indipendenza reale del reviewer provengono sempre
dall'autenticazione dell'applicazione, non dal modello né dal confronto fra PID.

Gli ultimi fix hanno superato 58 test mirati, 24 test del runtime con verifica
privacy, 38 regressioni kernel/review e l'integrazione delle nove librerie.
Il riepilogo principale riporta l'esito dell'ultima suite completa e della demo.
