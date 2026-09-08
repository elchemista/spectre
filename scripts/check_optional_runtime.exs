# Run in a fresh MIX_ENV=prod build in CI, and an isolated VM from ExUnit.
# Testing module absence on the actual code path catches runtime and compile
# dependency leaks that inspecting only spectre.app would miss.
false = Code.ensure_loaded?(Vettore)
false = Code.ensure_loaded?(ExFastembed)
{:ok, _} = Application.ensure_all_started(:spectre)

options = [
  namespace: "tenant:acme",
  definition_ref: "definition:support",
  flow: "support",
  labels: ["support/lookup"],
  max_entries: 20
]

{:ok, cache} = Spectre.Router.SemanticCache.Exact.start_link(options)
:ok = GenServer.stop(cache)

{:error, {:adapter_module_not_loaded, Vettore}} =
  Spectre.SemanticCache.Vettore.start_link(options ++ [dimensions: 384])

false = Code.ensure_loaded?(Vettore)
false = Code.ensure_loaded?(ExFastembed)
IO.puts("optional backends absent; Spectre available")
