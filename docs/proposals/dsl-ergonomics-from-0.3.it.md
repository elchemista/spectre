# Revisione della DSL e delle opzioni di Spectre

La revisione completa è stata integrata nella [proposta principale, Appendice A](agent-server-gam-from-0.3.it.md#appendice-a-dsl-e-opzioni), che costituisce il riferimento unico per architettura, DSL e piano di migrazione.

La [sezione 4.3](agent-server-gam-from-0.3.it.md#43-helper-dei-package-installati-kinetic-mnemonic-lens)
fissa la scelta successiva dei nomi `kinetic`, `mnemonic`, `lens` ecc. per
normali funzioni helper dei package, con `ctx` esplicito e continuazioni
`on_result`. L'AL prodotto dal modello passa a `kinetic` dal callback del
risultato; il framework non richiede una nuova DSL nel Server.

L’appendice include nomi canonici, default dei flow, classifier locale/LLM, IntentDataset, Stack, Skill, Work/Vigil e compatibilità con la 0.3. La proposta separa Agent dichiarativo e Server con callback OTP: fallback e dialogo delle conferme sono codice Elixir nel Server, mentre il runtime collega le conseguenze governate a GAM. Comprende esempi, streaming e piano di migrazione. Le nuove API sono proposte e non sono ancora implementate.
