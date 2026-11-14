**Verdetto:** la proposta mette in pratica una regola che esiste già, senza ampliare l'autorità, a patto di rispettare 5 vincoli. Senza quei vincoli la amplia. Non ho trovato un percorso già implementato che funzioni.

## 1. La diagnosi è corretta, e il problema è un difetto, non una lacuna da dichiarare

- `Governance.dispose_duty` (`lib/spectre/gam/governance.ex:269`) imposta il target a `[duty_ref]`. `Coverage.covered_values(:targets)` (`kernel/authority/coverage.ex:76`) esige che quel ref compaia tra i `mandate.target_refs`. Non c'è una wildcard: con `target_refs` vuoto non passa nulla.
- Il ref di un Duty dipende dal suo contenuto, quindi non si conosce in Genesis. La delega e la restrizione possono solo togliere, quindi il ref non si può aggiungere neanche dopo.
- `Duty.Authority.independent_route` (`duty/authority.ex:52`) esclude l'accountable, tutti i ruoli dell'Act causale (proposer, executor, authorizer, accountable) e anche i suoi subject e target (`derive/cause.ex:98`). Controlla poi grantor, holder e accountable di tutta la catena di Mandate.
- Il bootstrap gestito nomina `actor.ref` come autorità di disposizione (`server/gam/managed/bootstrap.ex:344`). Quell'actor però è holder del Mandate causale e compare anche nei suoi target, quindi è una via che non può mai essere usata.
- **L'argomento decisivo:** `Constitution.validate_duty_routes` (`constitution.ex:125`) *obbliga* a nominare una via di disposizione per ogni classe discrezionale. La legge dichiara quindi che chiudere un Duty dev'essere possibile, ma Coverage lo rende impossibile per tutti i Duty futuri. Limitarsi a dichiarare la mancanza vorrebbe dire tenere una regola costituzionale che non si può applicare.

## 2. Percorsi già implementati: nessuno funziona

- **`retained_controller`:** è legato a `mandate.revoke` e a `target_refs == [mandate.ref]` (`retained_revocation.ex:69`). Allargarlo a `duty.dispose` sarebbe un abuso peggiore della proposta.
- **Target implicito di `mandate.delegate`:** copre solo il Mandate genitore.
- **`:condition_met`:** salta `Authority.validate` (`disposal.ex:44`), ma passa comunque dall'ammissione, quindi è bloccato dalla stessa Coverage.
- **Mandate di emergenza in Genesis:** non è pensato per la disposizione dei Duty, non lo userei.

Esistono però dei precedenti per eccezioni di Coverage legate a una sola classe: `declassification_owners` decodifica la conseguenza e consulta la catena dei Mandate, e `mandate.delegate` ha il suo target implicito. La forma della proposta è quindi coerente con l'architettura.

## 3. Quando la proposta amplierebbe l'autorità illecitamente (vincoli obbligatori)

1. **Il significato di target deve restare chiuso.** L'eccezione vale solo se `candidate.class == "duty.dispose"` **e** `mandate.classes == ["duty.dispose"]` esattamente. Altrimenti un Mandate di governance con classi miste farebbe trapelare l'uso di "target = Mandate causale" verso altre classi.
2. **Il legame dev'essere esatto, non dedotto dal target.** Bisogna decodificare la `Disposition` dalla conseguenza e richiedere `candidate.target_refs == [disposition.duty_ref]`. Il Duty deve esistere ed essere `:open`, e il suo `disposition_authority_refs` deve contenere `mandate.ref` (o il proposer, se la via nomina un Principal). Così, se la Constitution non nomina quel Mandate, l'eccezione non scatta mai.
3. **Facts devono restare minimi.** `Facts.for_candidate` dovrebbe estrarre solo il Duty indicato dalla conseguenza (ref, mandate causale, autorità, stato), non tutte le aperture. Non è una Evidence ma una proiezione del ledger, come `blocked_effect_digests`, quindi il principio scritto nel moduledoc di Facts resta rispettato.
4. **Va gestita la catena dei Mandate causali.** Con il match esatto, un Mandate causale ristretto (che diventa un successore con un ref nuovo) o delegato produce Duty che nessuno può chiudere. Consiglio di accettare se il target appartiene alla catena degli antenati (`Ancestry.lineage`) o dei predecessori del Mandate causale. Questi discendenti si ottengono solo togliendo autorità al Mandate dichiarato in Genesis, quindi restano dentro il dominio fissato lì. Va reso esplicito e testato.
5. **L'indipendenza vale per tutta la catena, grantor compreso.** Il Mandate del reviewer non può essere concesso dall'accountable di business: il controllo a `authority.ex:145` lo rifiuterebbe al commit con `duty_disposition_mandate_route_not_independent`. Grantor, holder e accountable devono tutti stare fuori dai conflitti, e questo include i target e subject del Mandate causale. In più `Coverage.matching_accountable` obbliga l'accountable del Candidate a coincidere con quello del reviewer: la responsabilità della disposizione passa quindi al reviewer, ed è corretto così.

Tutti gli altri controlli (Status, revoca, scadenza, Row, executor del kernel, purpose) restano invariati.

## 4. Soluzione minima sicura

- **Kernel:**
  - Aggiungere una clausola a `Coverage.covered_values(:targets, %Candidate{class: "duty.dispose"}, mandate, facts)`, con i vincoli 1, 2 e 4.
  - Estendere `Facts` con un campo `disposition_duty` (uno solo, oppure nil).
  - Lasciare `Disposal` e `Duty.Authority` **invariati**: rivalidano già opening_digest, evidence congelate e indipendenza al commit.
- **AgentServer:**
  - Accettare una config opzionale con l'identità del reviewer e il processo autorizzato.
  - Il bootstrap costruisce un Mandate radice in Genesis con: grantor e holder uguali al reviewer (o a un Principal di governance separato), classes `["duty.dispose"]`, target uguale al Mandate causale, executor e contract del kernel.
  - Le `duty_rules` nominano quel Mandate al posto di `actor.ref`.
  - Al boot si fa un controllo preventivo dell'indipendenza, con un errore esplicito se fallisce.
  - Senza reviewer i Duty restano aperti e la via attuale (inerte) va documentata come tale.
  - Il Mandate del reviewer non si può mai richiedere da un percorso tool o LLM, perché il principal autenticato è diverso.
- **Da decidere a parte:** se l'holder del Mandate causale debba poter chiudere i Duty solo con `:condition_met`. È legge già scritta, perché le condizioni di chiusura sono congelate nel Duty, ma estende l'autorità dell'actor e va scelto esplicitamente.

## 5. Test richiesti

1. Caso positivo: un'esecuzione ambigua apre un Duty, il reviewer lo ratifica, il Duty risulta chiuso nella proiezione.
2. L'actor che prova a chiudere da solo viene rifiutato in Coverage. Anche forzando l'Act, viene rifiutato da `Duty.Authority`.
3. Il Mandate del reviewer punta a un altro Mandate causale: `{:targets, :outside_mandate}`.
4. La Constitution non nomina il Mandate del reviewer: rifiutato.
5. Candidate con `target_refs` del tipo `[duty, extra]`, oppure con `duty_ref` nella conseguenza diverso dal target: rifiutato.
6. Duty inesistente o già chiuso: rifiutato.
7. Mandate del reviewer con classi miste: l'eccezione non si applica.
8. Classe diversa da `duty.dispose` con un target che è un Mandate: nessuna eccezione.
9. Grantor del reviewer uguale all'accountable di business: errore al boot e rifiuto al commit.
10. Reviewer che è target o subject del Mandate causale: non indipendente.
11. Mandate del reviewer revocato, scaduto o bloccato da debito: rifiutato.
12. Mandate causale ristretto o delegato: coperto. Mandate del reviewer delegato: i target restano un sottoinsieme.
13. Stesso risultato tra `Facts.from_state` e il percorso indicizzato, e dopo un replay dal ledger.
14. Senza reviewer: il Duty resta aperto e non viene generato alcun Candidate automatico.
15. Regressione su evidence non congelate e su opening_digest non corrispondente.

Nota: in questa sessione non sono disponibili né la scrittura del file di piano né ExitPlanMode, quindi la review è tutta qui sopra. Non ho modificato nessun file.