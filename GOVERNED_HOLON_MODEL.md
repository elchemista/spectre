# GOVERNED HOLON MODEL

Un Actor sa ricevere un messaggio. Un Holon deve poter rispondere di ciò che quel messaggio diventa.

Il Governed Holon Model non è un modello parallelo al Governed Act Model. Non introduce una seconda costituzione, una quinta forma normativa o un altro modo di decidere. Il vocabolario condiviso resta quello del Governed Act Model: Mandate, Evidence, Act e Duty; le sue quattro leggi restano normative anche quando il sistema è composto.

Il Governed Holon Model rende esplicita una cosa che lì rimane implicita: il soggetto.

Ogni Mandate ha qualcuno che concede e qualcuno che riceve. Ogni Act viene imputato a qualcuno. Ogni Duty deve continuare ad appartenere a qualcuno anche quando il processo che lo stava eseguendo è morto. In un agente semplice quel “chi” può coincidere con l’intero runtime e restare quasi invisibile. Quando più Actor, agenti e organizzazioni collaborano, lasciarlo implicito permette alla topologia di decidere in silenzio chi rappresenta chi, quale autorità passa fra le parti e dove finisce una responsabilità.

Un **Holon** è quel soggetto operativo reso esplicito e ricorsivo.

Verso l’esterno presenta una sola identità governata. Verso l’interno può essere realizzato da un Actor, da molti Actor o da altri Holon. A sua volta può partecipare a un Holon più grande senza perdere la propria identità nel proprio ambito. È intero rispetto alle parti che coordina e parte rispetto alla composizione a cui aderisce.

Questa è l’estensione naturale fra i due modelli. L’Actor Model descrive come unità di computazione isolate ricevano messaggi, cambino comportamento, creino altri Actor e comunichino senza condividere una mutazione globale. Il Governed Act Model descrive come una proposta diventi una conseguenza autorizzata. Il Governed Holon Model applica quel governo a una identità logica che può essere realizzata da molti Actor e può incontrare altre identità governate.

Non sostituisce l’Actor Model. Gli assegna un confine di responsabilità.

## Actor, Holon e Principal

Un **Actor** è un’unità di computazione. Possiede stato e comportamento locali, riceve messaggi e decide come reagire. Può inviare altri messaggi, creare nuovi Actor, delegare lavoro e fallire. Un Actor organizza concorrenza e isolamento. Non stabilisce da solo se un messaggio sia autorevole, se una promessa debba sopravvivere al suo riavvio o chi debba rispondere di un effetto prodotto nel mondo.

Un **Holon** è un’unità di imputazione e continuità. È l’identità attraverso cui un sistema può ricevere un Mandate, riconoscere Evidence, registrare un Act e portare un Duty. Non è definito dal numero dei processi, dalla complessità del ragionamento o dalla capacità tecnica di chiamare un servizio. È definito dal fatto che esista un record canonico capace di conservare chi ha deciso, sotto quale autorità e che cosa resta ancora dovuto.

Computazionalmente, un Holon appare agli altri come un Actor logico: possiede un’identità a cui inviare proposte e produce messaggi attribuibili a quella identità. Non deve però coincidere con un processo fisico. Il processo è un’attivazione; il Holon è il soggetto che quell’attivazione serve. Un runtime può spegnere, spostare o ricreare i processi senza cambiare il soggetto, purché la continuità del record sia verificabile.

Un solo Actor può realizzare un Holon. Mille Actor possono restare organi dello stesso Holon. Un processo può anche ospitare più Holon, purché le loro identità, decisioni e registri restino logicamente separati. Il modo in cui il software viene distribuito non decide il confine della responsabilità.

Una persona o un’istituzione non viene ridotta a un Actor e non deve essere trasformata artificialmente in un Holon. Nel documento viene chiamata **Principal** soltanto per indicare una sorgente, una beneficiaria o una destinazione finale di autorità e responsabilità che il sistema riconosce senza pretendere di contenerla computazionalmente. Principal non è una quinta forma normativa. Un Holon può rappresentare una persona o un’organizzazione sotto Mandate, ma non diventa quella persona o quell’organizzazione e non assorbe la responsabilità umana o istituzionale che sta fuori dal runtime.

Quando una persona approva, firma, rifiuta o assume un impegno, il sistema registra Evidence e Act secondo la procedura riconosciuta. Non finge che la persona sia un processo interno. Quando un Duty non può più essere disposto da nessun Holon, ritorna al Principal o al forum umano o istituzionale nominato dalla catena di autorità.

Questa distinzione impedisce tre confusioni. Un modello non diventa responsabile perché ha generato una risposta. Un executor non diventa autore dell’Act perché ha prodotto l’effetto. Un essere umano non diventa un componente posseduto dal sistema perché partecipa alla decisione.

## Il Holon non è una nuova primitiva di esecuzione

Il Governed Holon Model non richiede un processo speciale chiamato Holon. Richiede che alcune identità del sistema siano trattate come confini governati.

Un Holon ha una **Definition** che descrive la sua forma riconoscibile: quali messaggi comprende, quali Act sa rappresentare, quali Membership può accettare, quali capability può usare, come cambia la propria Definition, come gestisce conflitti, uscita, successione e custodia del record. La Definition è analoga al comportamento dichiarato di un Actor, ma non è una sorgente di autorità. Dice che cosa il soggetto sa rappresentare; il Mandate dice che cosa può attualmente proporre.

La genesi del Holon è un Act proveniente da un’autorità che esiste già fuori da lui. L’Act di formazione lega una nuova identità a una Definition iniziale, alle radici che riconosce, al record che ne porterà la continuità e ai Principals verso cui torneranno i Duty residui. Nessun sistema autorizza dall’interno la propria nascita.

La **Membrane** è il confine del Governed Act Model applicato a quella identità. Non è necessariamente un proxy, un singolo modulo o un solo processo. È l’invariante secondo cui tutto ciò che il Holon vuole dichiarare governato passa per la stessa semantica di riconoscimento, decisione e registrazione.

Un messaggio può attraversare la Membrane come informazione senza diventare un comando. Una proposta interna può arrivare alla Membrane senza essere ancora la decisione del Holon. Una credenziale può esistere nell’infrastruttura senza diventare l’autorità di chi riesce a trovarla. La Membrane separa il flusso dell’informazione dall’esercizio del potere.

Il suo contenimento deve essere dichiarato capability per capability. Quando le credenziali e la capacità concreta di produrre un effetto sono irraggiungibili agli organi e vengono rilasciate soltanto dopo un Act, il Holon può rivendicare contenimento di quel percorso. Quando un organo può usare direttamente la capability ma ogni uso viene osservato e correlato, il Holon può rivendicare tracciabilità, non prevenzione. Quando non controlla né osserva in modo affidabile un percorso, quel percorso resta fuori dal perimetro governato. Una Membrane onesta non trasforma un log in isolamento.

Gli **organi** sono Actor, modelli, planner, verificatori, executor e strumenti che lavorano dentro lo stesso confine di responsabilità. Possono avere stato, indirizzi e autonomia computazionale. Non possiedono però un Duty indipendente verso l’esterno e non impegnano il Holon con la propria sola decisione. Producono osservazioni, Evidence, proposte o tentativi per un’identità che rimane quella del Holon.

Un supervisore è un organo di continuità operativa. Può avviare, fermare e ricreare processi. Non può ampliare un Mandate, ratificare un Act, chiudere un Duty o riscrivere il passato. Tenere vivo il software e governare le conseguenze sono responsabilità diverse.

Un planner o un esperto può proporre un piano migliore. Il suo risultato diventa Evidence o una proposta. Non diventa autorità soltanto perché il Holon si affida alla sua competenza. Se quell’esperto possiede invece una propria identità, può rifiutare il lavoro e assume un Duty indipendente quando lo accetta, allora non è più un organo: è un altro Holon.

## Membership e Holarchy

Una **Membership** è la relazione durevole con cui un Holon entra in una composizione oppure accetta il contributo di un altro Holon o di un Principal. Non è proprietà, fusione o accesso implicito. Non è una quinta forma accanto a Mandate, Evidence, Act e Duty. È il contesto che collega gli Act di proposta e accettazione, i Mandate concessi nelle due direzioni e i Duty che ciascuna parte ha assunto.

La relazione può essere asimmetrica. Un membro può concedere soltanto il diritto di ricevere determinate richieste. Un altro può ricevere il diritto limitato di rappresentare il tutto. Una parte può fornire una risorsa senza ottenere alcun potere sulla composizione. Ciò che conta è che ogni direzione sia dichiarata e che nessuna autorità emerga dalla parola “membro”.

Il ruolo descrive la funzione che la parte svolge. Non concede autorità. Essere parent, child, Head, supervisor, staff, representative o coordinator non permette da solo di impegnare nessuno. Il potere di quel ruolo esiste soltanto nei Mandate che lo delimitano e negli Act con cui viene esercitato.

Le architetture holoniche chiamano spesso **Head** il membro o il componente che presenta il super-Holon verso l’esterno. Il termine è utile purché non venga confuso con il soggetto stesso. Un Head può coordinare messaggi, scegliere quali organi coinvolgere, preparare proposte e, se autorizzato, parlare per il tutto. Non è però la sorgente dell’identità collettiva. La Membrane deve ancora riconoscere i suoi Act e la sua sostituzione non cambia il Holon. Il rappresentante è una parte con un Mandate, non il proprietario del soggetto che rappresenta.

Un Holon può avere più Head. Più ingressi non dividono il soggetto finché convergono sullo stesso record canonico e sulla stessa semantica GAM. Se ogni Head può impegnare la medesima identità senza riconoscere gli Act degli altri, non esiste una rappresentanza plurale: esiste uno split brain normativo.

Una Membership nasce soltanto quando entrambe le posizioni sono state riconosciute. Il proponente registra ciò che offre o richiede. Il destinatario registra ciò che accetta realmente. La sola richiesta non crea un Duty nel destinatario. Potergli inviare un messaggio non significa poter occupare le sue risorse, impegnare il suo tempo o creare collaterale nel suo record.

L’accettazione può essere esplicita per ogni richiesta oppure anticipata per una classe rigorosamente delimitata. L’accettazione anticipata non è un permesso permanente. È una disponibilità consumabile che dichiara almeno quali mittenti e contratti copre, quanti Duty possono restare aperti contemporaneamente, quale frequenza ammette, quale envelope di risorse o collaterale può essere impegnato e quando scade o può essere revocata.

Ogni accettazione automatica riserva una parte di quell’envelope. Finché il Duty resta aperto, quella parte non può essere riutilizzata come se nulla fosse accaduto. Quando il limite è esaurito, le richieste successive tornano a richiedere un’accettazione esplicita. In questo modo la pre-accettazione riduce il coordinamento senza restituire al mittente il potere di creare un numero illimitato di obbligazioni nel destinatario.

Le condizioni di emendamento e uscita vengono accettate insieme alla Membership, non improvvisate durante il conflitto. La relazione dichiara quali cambiamenti limitati possono essere applicati sotto un Mandate già accettato, quale preavviso è richiesto, come si interrompono i nuovi incarichi e quale disposizione si attiva se una parte rifiuta di cooperare al passaggio di consegne.

Una parte può quindi terminare unilateralmente la relazione futura quando quel diritto era stato precommittato. L’uscita revoca i Mandate futuri e l’accettazione anticipata. Non trasferisce da sola i Duty aperti. Questi restano con chi li ha assunti finché vengono soddisfatti, disposti da un’autorità competente o accettati da un successore.

Una **Holarchy** è la composizione ricorsiva delle Membership. Non deve essere un albero. Un Holon può appartenere a più composizioni, e una composizione può assumere temporaneamente una forma gerarchica, federata o eterarchica. Cambiare modalità di coordinamento non cambia le leggi del governo.

La Holarchy non coincide con la supervision tree di OTP. Un processo figlio può essere un semplice organo dello stesso Holon. Un child Holon può essere ospitato sotto lo stesso supervisor del parent oppure in un altro sistema. La supervision tree descrive chi deve essere avviato, fermato o ricreato. La Holarchy descrive chi ha accettato quale responsabilità.

In una fase stabile un Holon superiore può coordinare e ottimizzare il lavoro dei membri. Durante un guasto gli stessi membri possono cooperare direttamente o rifiutare proposte che non riescono a sostenere. Il passaggio fra gerarchia ed eterarchia modifica i Mandate attivi e i percorsi di proposta, non crea una sovranità di emergenza.

La comunicazione può formare cicli. La derivazione dell’autorità no. Se A delega a B, B a C e C torna ad A, il ciclo non ha creato una sorgente. Ogni Act deve poter risalire attraverso una catena finita a un Principal o a un’autorità di genesi riconosciuta.

La Holarchy permette quindi a un insieme di apparire come uno senza fingere che le parti abbiano perso il proprio confine. Il tutto può assumere un Duty complessivo. Le parti possono accettare Duty interni per contribuirvi. Il Duty esterno del tutto non scompare perché un membro ha accettato il lavoro, e il Duty del membro non diventa automaticamente dovuto alla controparte esterna del tutto.

### Ruoli strutturali e forme di composizione

Nella letteratura holonica, un membro che partecipa a un solo super-Holon viene spesso chiamato **Part**. Un membro condiviso fra più super-Holon viene chiamato **Multi-Part**. Nel Governed Holon Model questi nomi sono proprietà derivate dalle Membership, non nuovi tipi di soggetto. Il loro valore è pratico: il caso Multi-Part rende obbligatorio il controllo dei conflitti fra Mandate, Duty, dati e risorse provenienti da relazioni diverse.

Anche federazione, gruppo moderato e fusione descrivono gradi diversi di composizione, non governi differenti. In una federazione, più Holon cooperano ma non nasce necessariamente un nuovo soggetto. Se non esistono una nuova identità, un record canonico e Duty imputabili al tutto, esiste coordinazione, non un super-Holon.

Nel gruppo moderato, che è la forma più naturale per un sistema agentico governato, i membri conservano il proprio confine e formano anche una nuova identità comune. Uno o più Head ne costituiscono l’interfaccia, mentre i Mandate dichiarano esattamente quanta autonomia ciascun membro ha scelto di cedere.

Nella fusione, le identità precedenti cessano davvero di operare come soggetti indipendenti e i loro componenti diventano organi del nuovo Holon. Questa non è una Membership più forte. È una formazione accompagnata dalla chiusura, dal trasferimento o dalla disposizione dei Duty precedenti. Finché un vecchio soggetto porta un Duty proprio, non è stato assorbito soltanto perché il diagramma lo disegna dentro un contenitore più grande.

Immaginiamo un Holon di assistenza che operi per un’azienda. Al suo interno un modello interpreta la richiesta, un Actor legge l’ordine, un verificatore controlla la policy e un executor può contattare il sistema di pagamento. Sono organi di un solo Holon finché nessuno di loro assume una responsabilità indipendente.

Il modello propone un rimborso. Il lettore porta Evidence sull’ordine. Il verificatore porta Evidence sui limiti. Nessuno dei tre muove denaro. La Membrane riconosce il Mandate ricevuto dall’azienda, registra l’Act del rimborso e soltanto dopo rilascia all’executor una capability limitata a quel pagamento.

Se la verifica fiscale viene affidata a un servizio autonomo con identità, record e regole propri, quel servizio è un altro Holon. Il primo gli invia una proposta. Il secondo può rifiutare oppure accettare sotto la propria Membrane. Solo l’accettazione apre il suo Duty. Se esiste una Membership che pre-accetta fino a cinquanta verifiche concorrenti e cento richieste al giorno, l’accettazione può essere automatica entro quei limiti; la centounesima richiesta o la cinquantunesima obbligazione aperta richiede una nuova decisione.

Se il worker fiscale muore, il Duty non muore. Se il supervisore lo ricrea, non nasce un nuovo Mandate. Se il servizio esce dalla Holarchy, i nuovi incarichi si fermano ma i casi già accettati restano aperti. Questo esempio contiene il modello intero.

Le quattro leggi che seguono non sono leggi holoniche aggiuntive. Sono le stesse leggi del Governed Act Model viste quando il soggetto può contenere altri soggetti.

**Media tutto ciò che conta.**

Per un Holon, mediare significa impedire che un movimento interno venga scambiato per il movimento del tutto. Un pensiero non è una decisione collettiva. Un messaggio fra Actor non è una promessa esterna. Una modifica locale non è stato canonico. Una chiamata tecnicamente possibile non è un Act del Holon.

Tutto ciò che il soggetto vuole dichiarare governato deve tornare alla sua Membrane: cambiamenti del record canonico, consumi, esposizioni di dati, deleghe, rappresentanza, Membership, modifiche della Definition e capability capaci di produrre effetti. Possono esistere molti percorsi fisici, ma non due semantiche diverse per impegnare la stessa identità.

Lo stesso Holon richiede una decisione canonica atomica. Il cambiamento di stato, l’Act, i Duty prodotti e la riserva delle risorse necessarie devono essere committati insieme oppure non esserlo. Questa è una conseguenza del confine scelto, non un test per scoprirlo.

L’inferenza inversa è falsa. Due Holon possono condividere un database, un sequencer e perfino una transazione fisica per ragioni di hosting. Restano due soggetti se ciascuno deve produrre la propria decisione. Nessuna atomicità tecnica sostituisce l’accettazione del destinatario e nessuna scelta di storage può fondere retroattivamente due responsabilità.

Un parent non apre lo stato del child per correggerlo. Gli invia una proposta. Un Head non scrive direttamente il fatto canonico del tutto. Presenta una proposta alla Membrane. Un executor non riceve una chiave generica perché “fa parte del sistema”. Riceve, quando il contenimento lo permette, la capacità precisa legata a un Act già registrato.

Il modello governa soltanto i percorsi che può davvero mediare. Per ogni capability deve dichiarare se impedisce il bypass, se può soltanto rilevarlo oppure se non lo controlla. La superficie governata è un insieme di conseguenze e percorsi concreti, non una proprietà magica dell’intero software.

**L’autorità non cresce.**

Una Holarchy può combinare conoscenza, calcolo e capacità. Non somma automaticamente i Mandate dei membri.

Se un Holon sa leggere documenti e un altro sa effettuare pagamenti, il tutto non ottiene entrambe le autorità per il solo fatto di contenerli. La capacità descrive ciò che la struttura potrebbe fare. Il Mandate descrive ciò che una identità ha il diritto di proporre. Nessun parent eredita il potere del child e nessun child eredita il potere del parent.

Ogni delega conserva o restringe la fonte. Può ridurre operazioni, destinatari, scopo, durata, budget e condizioni. Non può creare una facoltà che il delegante non possedeva. Quando una quota esclusiva viene delegata, deve cessare di essere contemporaneamente spendibile altrove. Altrimenti la composizione moltiplica il potere copiando chi lo usa.

Neppure il ruolo crea autorità. Un supervisor controlla il ciclo di vita. Un Head coordina. Uno staff consiglia. Un representative comunica. Ognuno può esercitare soltanto il Mandate assegnato e soltanto attraverso gli Act riconosciuti. Il nome organizzativo rende leggibile una funzione; non è una scorciatoia intorno al governo.

La richiesta di A non crea da sola un Duty in B. Se potesse farlo, A acquisterebbe unilateralmente il potere di occupare risorse di B, consumarne la capacità e sospenderne altri Mandate attraverso conflitti collaterali. Per questo l’accettazione del destinatario non è un dettaglio di protocollo: è la conseguenza diretta del fatto che l’autorità non cresce.

L’accettazione anticipata conserva la stessa legge soltanto quando è delimitata e consumabile. Il mittente può usare lo spazio che il destinatario ha già scelto di rendere disponibile, non inventarne altro. Rate, concorrenza, risorse, scadenza e classe del contratto fanno parte del confine, non sono ottimizzazioni facoltative.

Prima di accettare una nuova Membership, il Holon deve confrontarla con i Mandate e i Duty già esistenti. Un servizio che promette riservatezza ad A e divulgazione a B non può fingere che le due relazioni siano indipendenti soltanto perché hanno identificatori diversi. Può accettare il rischio solo quando la propria Definition lo permette, le parti che ne subiscono il rischio sono state informate e l’isolamento o la disposizione prevista rendono il conflitto governabile.

La Definition non crea potere. La sua modifica richiede un Act proveniente dall’autorità di emendamento nominata. Una Membership può contenere il consenso anticipato a modifiche limitate, ma non una clausola con cui il Holon superiore si concede il diritto di riscrivere qualsiasi cosa. Se la parte viola ciò che aveva già accettato, si attiva il Duty e la disposizione precommittata: sospensione, sostituzione, uscita o successione. Il conflitto non viene risolto inventando sovranità durante l’incidente.

**La causalità non si riscrive.**

Quando due Holon cooperano, non esiste un unico evento distribuito che ognuno possa raccontare come preferisce. Esistono decisioni locali collegate.

Il mittente registra ciò che aveva il diritto di proporre, il contenuto esatto della proposta e le Evidence su cui si è basato. Il destinatario registra ciò che ha ricevuto, ciò che ha compreso e ciò che ha accettato. Il tentativo nel mondo e il suo risultato arrivano dopo. Richiesta, accettazione, esecuzione, outcome e chiusura sono momenti distinti.

Gli identificatori causali collegano i due lati, ma nessuno dei due riscrive il record dell’altro. Se la risposta si perde, il mittente può sapere di aver inviato e il destinatario può sapere di aver accettato senza che esista ancora Evidence condivisa. La verità onesta resta divisa. Il Duty rimane aperto dove manca la prova capace di chiuderlo.

Una transazione distribuita può rendere simultanee alcune scritture. Non può sostituire il significato delle due decisioni. Il destinatario non ha accettato perché il database del mittente è riuscito a committare. Ha accettato soltanto quando il proprio confine ha prodotto l’Act corrispondente.

La revoca cambia ciò che può accadere dopo. Non cancella ciò che è già stato proposto, accettato o tentato. Le Evidence tardive devono poter entrare anche quando il vecchio Mandate non è più spendibile, perché registrare il passato non significa riattivare il potere che lo aveva prodotto.

Il rappresentante che eccede il proprio Mandate non vincola automaticamente il Holon. Ma il confine non diventa uno scudo contro chi ha fatto affidamento su una rappresentanza esposta dal sistema. L’eccesso apre un Duty verso la catena che ha nominato, configurato o lasciato operare il rappresentante. La disposizione può ratificare con autorità nuova, ripudiare, compensare, correggere l’esposizione ambigua o assegnare la perdita. Nessuna di queste operazioni trasforma retroattivamente l’eccesso in un Act autorizzato.

Ogni Holon può verificare il proprio percorso di governo. Non può affermare di conoscere dall’interno il kernel di un altro. Dell’altro riconosce firme, attestazioni, ricevute, prove di continuità e altri tipi di Evidence sotto le proprie regole. Una federazione non richiede fiducia cieca né un kernel globale; richiede confini locali onesti e causalità collegabile.

**Il dovere non si autoestingue.**

Un Duty appartiene al soggetto che lo ha assunto, non al processo, al modello o al membro momentaneamente incaricato di soddisfarlo.

Il Holon può sostituire un executor, cambiare planner, riavviare un Actor, riassegnare un compito o passare da coordinamento gerarchico a cooperazione fra pari. Queste modifiche cambiano il mezzo. Non cambiano ciò che il soggetto deve.

Quando il tutto delega un incarico e un membro lo accetta, nasce un Duty interno del membro verso il tutto. Se il tutto aveva già promesso qualcosa a un Principal esterno, quel Duty esterno resta suo. La delega collega le responsabilità; non le trasferisce in silenzio.

L’uscita dalla Membership ferma i nuovi Mandate e le nuove accettazioni. I Duty già aperti continuano a ricevere Evidence e devono essere chiusi o disposti. Se la controparte rifiuta il passaggio di consegne, si applica la via precommittata all’ammissione. Nessuno può essere costretto ad assumere il lavoro residuo senza averlo accettato, e nessuno può usare quel rifiuto per dichiararsi libero da ciò che aveva già promesso.

Un conflitto fra Membership non è soltanto un motivo per respingere una nuova proposta. Quando due Duty già assunti diventano incompatibili, nasce un Duty di conflitto che nomina entrambe le pretese, le risorse o i dati contesi, le parti che ne subiscono il rischio e il forum autorizzato a disporlo. Il Holon non sceglie in silenzio il Principal più conveniente e non chiude una promessa cancellando l’altra dal contesto.

Un Holon può sciogliersi soltanto quando i Duty sono chiusi oppure quando un successore autorizzato li ha accettati. La successione è una nuova relazione, non un cambio di nome. Il predecessore propone la devoluzione; il successore accetta sotto il proprio confine; la continuità causale collega i record. Se nessun successore macchina può assumere il residuo, il Duty ritorna al Principal o all’istituzione nominata nell’Act di formazione.

La custodia del record non è una nuova forma normativa. È un ruolo che porta Duty precisi. Il **custode** deve preservare, entro il perimetro dichiarato, integrità, disponibilità, recuperabilità e prova della continuità del record canonico. Se è un organo interno, il Duty resta del Holon. Se è un altro Holon o un Principal esterno, deve accettare quel Duty verso il Holon e verso i beneficiari nominati.

La sostituzione del custode richiede un Act autorizzato, l’accettazione del nuovo custode e Evidence del passaggio di consegne. Il Duty del vecchio custode non si chiude perché è stato cambiato un campo di configurazione; si chiude quando la nuova custodia è stata realmente stabilita secondo le condizioni previste.

Il processo può morire e il Holon può restare. Il record non può sparire e lasciare intatta la stessa affermazione. Un Holon conserva la propria identità finché il record canonico è recuperabile o la sua continuità può essere dimostrata da prove previste. Se questa base viene perduta, la perdita è Evidence di una rottura, rende attuali i Duty del custode e avvia la disposizione o la successione. Un nuovo processo può continuare il servizio, ma non appropriarsi del passato chiamandosi lo stesso soggetto senza una continuità verificabile.

Anche la cancellazione legittima deve rispettare questa differenza. I contenuti possono dover essere rimossi o minimizzati. Se la cancellazione riduce la possibilità di verificare il passato, il sistema conserva almeno il fatto che quella verificabilità è stata ridotta, sotto quale autorità e in quale misura. La privacy può limitare la memoria; non deve fabbricare una causalità diversa.

## La macchina che ne emerge

L’implementazione resta un Actor system.

Un messaggio arriva all’identità logica del Holon. La Membrane ne riconosce il contratto, l’origine e il contesto e lo ammette come informazione. Gli Actor interni possono lavorare in parallelo, interrogare modelli, consultare memoria, negoziare, simulare e preparare proposte. Nessuno di questi passaggi è ancora un Act del Holon.

Quando una proposta vuole cambiare il record canonico, consumare una risorsa, esporre dati, delegare, assumere un Duty, rappresentare il soggetto o produrre un effetto, ritorna alla Membrane. Qui viene confrontata con la Definition, il Mandate, le Evidence, lo stato corrente, le riserve, i Duty aperti e i conflitti riconosciuti.

Il Governed Holon Model non introduce un secondo vocabolario di decisione. Usa gli esiti del Governed Act Model.

`permit` significa che il candidato può diventare Act. `deny` comprende il rifiuto autonomo o la mancanza di autorità. `indeterminate` conserva i casi in cui le Evidence non bastano o il sistema è temporaneamente incapace di decidere. `not_applicable` significa che il contratto o la proposta non appartengono al vocabolario riconosciuto. Mancanza di Evidence, impossibilità temporanea, rifiuto e contratto sconosciuto possono essere ragioni più precise, ma non nuovi esiti normativi.

Il conflitto non è un quinto esito. Un conflitto soltanto potenziale, scoperto prima di accettare una nuova Membership o un nuovo incarico, può produrre `deny` quando la policy lo vieta oppure `indeterminate` quando manca ancora una disposizione. Non apre il Duty che il controllo stava cercando di evitare. Quando invece Duty già accettati risultano incompatibili, l’esito resta `indeterminate` con una ragione come `membership_conflict` e si apre o si mantiene il Duty di conflitto. Questa asimmetria deve essere esplicita perché il semplice rifiuto di un candidato non crea normalmente una nuova obbligazione.

Se la decisione è `permit`, il runtime registra atomicamente lo stato locale, l’Act, i Duty prodotti e le riserve necessarie. Solo dopo rilascia la capability concreta. Commit prima della capacità non significa che il mondo sia atomico con il record; significa che il sistema non produce prima l’effetto e inventa dopo l’autorizzazione.

Il mondo risponde separatamente. Ricevute, errori, risultati e silenzio diventano Evidence. Possono consentire un nuovo Act di chiusura, aprire una compensazione, richiedere riconciliazione o lasciare il Duty aperto. L’outcome non riattiva il vecchio Mandate e non esegue una continuazione congelata contro uno stato ormai diverso.

Se il destinatario è un altro Holon, il messaggio in uscita dal primo entra nel secondo come proposta. Il primo non invoca una funzione privata del secondo e non ne muta lo stato. Ogni confine decide localmente. I due record sono correlati, non condivisi.

Ogni Holon possiede un solo writer logico dei propri fatti canonici. Quel writer può essere un Actor, una macchina a stati, un log distribuito o una sequenza virtualizzata. Molti Holon possono essere ospitati dallo stesso sequencer e uno stesso Holon può essere riattivato altrove. L’invariante riguarda la proprietà logica della decisione, non il PID, il nodo o il database.

La supervisione mantiene disponibile l’implementazione. La persistenza mantiene recuperabile la continuità. La Membrane governa la conseguenza. Confondere i tre livelli produce errori tipici: trattare il supervisor come autorità, il database come soggetto o la presenza di un processo come prova che i Duty siano ancora sotto controllo.

“Un solo runtime” significa che tutte le identità ospitate localmente applicano lo stesso algoritmo di governo alle proprie conseguenze. Non significa un solo thread, un solo writer globale o un kernel mondiale. Di un Holon esterno il sistema può verificare soltanto le Evidence che esso espone e che la propria Membrane ha deciso di riconoscere.

## Il confine giusto

Per decidere se qualcosa debba essere un Holon non bisogna chiedere quanto sia intelligente, quanti processi contenga o se possa essere aggiornato nella stessa transazione di qualcos’altro.

La domanda è: esiste qui una responsabilità operativa indipendente che deve sopravvivere all’Actor, al modello, all’executor o al parent che la sta usando?

Se no, è probabilmente un organo del Holon esistente. Se sì, servono un’identità, una Membrane e un record propri, perché nasconderlo come worker renderebbe invisibile chi può accettare, rifiutare e portare il Duty. Se la risposta riguarda una persona o un’istituzione, il termine corretto è Principal: il sistema deve indirizzarle responsabilità e autorità, non fingere di contenerle.

Per decidere se due componenti appartengano allo stesso Holon bisogna chiedere chi riceve il Mandate, a chi viene imputato l’Act, chi porta il Duty e quale identità deve restare la stessa dopo la sostituzione dei componenti. Una volta scelto quel soggetto, il runtime deve offrirgli una transizione canonica atomica. La possibilità tecnica di committare insieme due cose non sceglie il soggetto al posto nostro.

Per decidere se una collaborazione sia una Membership governata bisogna poter ricostruire proposta, accettazione, Mandate, Duty, limiti della pre-accettazione, conflitti, emendamento, uscita e successione. Se la relazione funziona soltanto perché un parent può mutare il child, un membro possiede una credenziale laterale o un ruolo viene trattato come autorità, non è una estensione della Holarchy. È un bypass organizzativo.

Il modello non prescrive quanti agenti usare, quali ruoli creare, quale planner scegliere o se coordinare in modo gerarchico o eterarchico. Non promette che i membri cooperino, che il risultato collettivo sia intelligente o che un sistema esterno dica il vero.

Promette qualcosa di più preciso. La topologia non crea un soggetto da sola. La composizione non conia autorità. Un messaggio non crea un Duty nel destinatario. Un rappresentante non impegna il tutto oltre il proprio Mandate. Un supervisor non assolve ciò che riavvia. Un cambio di membri non riscrive la causalità. La perdita di un processo non cancella il dovere, e la perdita del record non viene chiamata continuità.

Il Governed Act Model separa l’intelligenza dal potere. Il Governed Holon Model conserva la stessa separazione quando l’intelligenza è distribuita fra molti Actor e la responsabilità deve attraversare molti confini.

Molti Actor possono calcolare. Molti modelli possono proporre. Molti Holon possono cooperare. Ma ogni conseguenza appartiene al soggetto la cui Membrane l’ha riconosciuta, ogni autorità deve risalire a un Mandate, ogni cooperazione che crea un Duty richiede accettazione e nessuna riorganizzazione libera un Holon da ciò che ha già assunto.

Un Actor riceve un messaggio. Un Holon governato può rispondere di ciò che quel messaggio è diventato.
