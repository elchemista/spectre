# Server → Stack compilation dependency probe

Disposable Mix project with core path dependency `/home/dev/Sviluppo/spectre/spectre`.
Own `deps/` and `_build/`; compiled dependency artifacts copied into this build
from verified satellite builds. No shared build directories, no ExUnit VM, no
production source changes. `--no-deps-check` avoids recompiling the core dependency.

Three distinct source files: `probe_package.ex`, `probe_stack.ex`, `probe_server.ex`.
Server declares `use Spectre.Server, tools: XrefProbe.Stack`.

`mix xref graph --label compile --no-deps-check`:

```
lib/probe_server.ex
└── lib/probe_stack.ex (compile)
lib/probe_stack.ex
└── lib/probe_package.ex (compile)
```

Initial Server descriptor reports `max_bytes: 128`.
Changed ONLY Stack installation option from `limit: 128` to `limit: 256`.
`mix compile --no-deps-check --verbose`:

```
Compiling 2 files (.ex)
Compiled lib/probe_stack.ex
Compiled lib/probe_server.ex
```

Subsequent `mix run --no-start --no-deps-check` reports Server descriptor
`max_bytes: 256`. Server BEAM SHA-256 changed (before.json / after.json).

Conclusion: compile dependency is present, and changes to Stack configuration
recompile the Server and replace its captured descriptor. No compiler fix needed.
