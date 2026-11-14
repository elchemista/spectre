# Review finale implementazione GAM gestito

Read-only, non modificare file, non eseguire comandi, non fare commit/push.
Rispondi in italiano, massimo 1800 parole. Riporta solo bug concreti con file:riga,
impatto e correzione minima; se non ne trovi, dillo. Non ridisegnare l'architettura.
Tempo di analisi: concentrati sui file sotto; non rileggere tutta la storia o i
nove pacchetti. Distingui problemi verificati, ipotesi e limiti dichiarati.

Workspace `/home/dev/Sviluppo/spectre`. Core `spectre`, demo `demo_spectre`.
Implementazione nuova:
- `spectre/lib/spectre/server/gam/managed.ex` e `managed/*.ex` (circa 9 moduli);
- `spectre/lib/spectre/server/gam/effect.ex`, `effect_adapter.ex`;
- `spectre/lib/spectre/stack/effects.ex`.
- Solo i punti rilevanti di `server/runtime.ex`: start_link/init, setup_managed_gam,
  handle_call decide/transport_input, handle_info transport_ready/managed_decision,
  textual_consent_proof, action_policy, terminate e run_pending.
- `demo_spectre/lib/demo_spectre/session.ex` e `skills/knowledge_server.ex`.
- `spectre/test/server/managed_runtime_test.exs`, `managed_gate_test.exs`.
Usa Read e Grep mirati; puoi fare più letture indipendenti nello stesso turno.

Obiettivo utente: AgentServer registra e orchestra automaticamente il protocollo
GAM al ritorno dei callback con comandi, lasciando override ordinari e il bridge
manuale. Lo Stack registra executor espliciti con effects/1, senza cambiare i
descriptor helper v1. Kinetic prepara AL generato dal modello; non agisce in streaming.
Le Skill condividono il Domain con limiti per mount applicati dal runtime.
Il kernel non è stato modificato. Solo le transizioni dichiarate governate
producono Act; callback cognitivi/configurati non richiedono consenso a ogni passo.

Limiti INTENZIONALI già dichiarati (non segnalarli come bug nuovi):
- modalità automatica supporta esplicitamente authority: :development, storage
  ephemeral/disk. Produzione già provisionata usa gam:{Spectre.Server.GAM,config}.
- kernel lega una Scope a un principal; il profilo opera formalmente a nome
  dell'umano configurato, con Invocation provenance Agent/Skill separata. Non
  pretende proponente-principal agente + approvatore-principal umano nella stessa Scope.
- codice Elixir fidato non è sandboxato. Non devi proporre protezioni impossibili
  contro :sys.get_state da codice già fidato nella stessa BEAM. Scope/credenziali
  non devono però finire in ctx/options/planner/tool né nei log di crash.
- demo usa modello deterministico, reali Lightpanda/Vettore/GAM e casella locale.

Verifiche già avvenute: 5 pacchetti cambiati suite complete PASS (Kinetic1339,
Mnemonic538+11excluded,Beam199,Pulse189,Lens184+20excluded); tutti9 compilewarningsclean;
coremirati callback/manual/Skill/diskstartup pass; demo27pass;20browser avversariali
prima19pass+formatassertioncorretto, cleanrun finale ora in corso. Corefull finale in corso.

Difetti già corretti da non riportare senza verificare la sorgente corrente:
Store CAS tuple, schema Kinetic compile-vs-loaded, payloadshape, inputnil OTP,
inputSkill bloccante (ora async), avvio chepropagavaEXIT (allocazione+ownermonitor),
cleanupstoreprematuro (close/drain), configdriftdisk, policyTTLresume congelata,
candidateoverrideenvelope, renderingmaterialinspect (ora fieldlines), private crashstatus.

Domande: restano percorsi che eseguono prima dell'Act o senza consenso richiesto?
La prova può passare a pending/mount/revisione diversi? Recovery/override possono
ampliare l'autorità? Esistono crash/race concreti nel nuovo Runtime/Managed?
Sono coerenti record, risultato ed effetti reali? Nessuna conferma di cortesia.
