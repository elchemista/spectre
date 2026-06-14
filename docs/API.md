# Public API

- `Spectre.ask/3` sends a turn to an agent module or session.
- `Spectre.summon/1` starts one session directly.
- `Spectre.summon/3` starts one session under `Spectre.Supervisor`.
- `Spectre.dismiss/2` stops a supervised session.
- `Spectre.state/1` reads session state.
- `Spectre.reset/2` replaces session state.
- `Spectre.cancel/2` cancels the active policy or pending action.
- `Spectre.execute/3` executes the approved pending action.
- `Spectre.after_action/5` runs configured lifecycle hooks.

Compatibility aliases such as `handle/3`, `call/3`, `start_session/1`,
`start_session/3`, `cancel_current/2`, and `execute_pending/3` remain available.
