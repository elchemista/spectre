# Testing and release validation

The useful question is not "how many tests?" but "which invalid history,
authority change or host failure would this test detect?" Coverage locates
unexercised code; it does not establish the four GAM laws.

## Scaffold a local agent

From the host Mix application (inside the selected child for umbrellas):

```sh
mix spectre.gen.agent MyApp.Hello --dry-run
mix spectre.gen.agent MyApp.Hello
mix test test/my_app/hello_test.exs
mix spectre.routes MyApp.Hello
mix spectre.eval MyApp.Hello test/my_app/hello_routes.jsonl --flow greetings
```

The generator writes five ordinary files:

| File | Purpose |
| --- | --- |
| `lib/my_app/hello.ex` | Agent callbacks that prepare a local greeting in `state.draft` |
| `lib/my_app/hello/router.ex` | `:greetings` flow with regex greeting and string-bag help routes |
| `lib/my_app/hello/prompts/hello.txt.eex` | EEx text compiled through the normal `prompt_root` / `prompt` declarations |
| `test/my_app/hello_test.exs` | Executable local routing/handler contract tests |
| `test/my_app/hello_routes.jsonl` | Example inputs and expected routes for regression checks |

`MyApp.Hello` determines the paths and authoring identity. `--dry-run` reports
targets without writing; a collision refuses the whole scaffold before any
write. There is no force-overwrite option. No application config, dependency,
Surface, Mandate, credential, Domain or supervisor is generated.

The greeting uses `Spectre.Agent.render_prompt/3`: a module, declared prompt
name and assigns map produce `{:ok, text}` or an error. It renders one template,
not ask/flow injections; it does not call a model. The ordinary `{:ask, ...}`
path still composes injections/context and prepares a governed inference request.
Returning `{:ok, state}` only updates local state. Delivery remains a separate
governed request if it crosses the application's protected boundary.

The generated tests deliberately need no Scope: they exercise pure authoring
callbacks, not authenticated admission. To run an Instance, follow
[host setup](host-setup.md) to activate the exact Definition and provide a Scope.
There is no parallel Hello World runtime that bypasses those checks.

For an opt-in host scaffold and a test of the first actual save, see
[your first governed save](host-setup.md#from-a-draft-to-your-first-governed-save).
That scaffold intentionally requires host completion; the local generator's
immediately runnable tests do not claim to test governance.

### Test the connection from input to handler

`Spectre.Agent.route_message/4` uses the same flow preparation and message
conversion as live routing. Feed real input instead of hand-building a tuple
that might outlive a renamed route:

<!-- spectre:example routed_handler -->
```elixir
defmodule Guide.RoutingContract do
  use Spectre.Agent, namespace: "guide", name: "routing-contract"

  flow :orders do
    router via: [:regex]
    route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/]
  end

  @impl true
  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}
end

{:ok, message} = Spectre.Agent.route_message(Guide.RoutingContract, "orders", "order 42")
{:request, "orders.lookup", %{"order_id" => "42"}, %{}} =
  Guide.RoutingContract.handle_turn(message, nil, %{})
```

`nil` works here only because this handler does not inspect the Turn. This
tests a proposed request, not a Candidate or permission. Handlers using real
authentication/Evidence need Instance tests. Nested Skill paths preserve local
names: test the owning Skill's callback with its own state, not its parent.

Optional `pipelines` and `adapters` are explicit registries, as in `Eval.prepare`.
Preparation errors return `{:error, reason}`. A routing miss/error/ambiguity is
instead returned as `{:ok, handler_message}`, so the application's callback
chooses how to handle it. No-match retains original input; halted/unrouted
messages retain the corresponding pipeline output, just like a live turn.
The helper neither calls the handler nor creates a Turn or records Evidence.
Host pipelines/adapters still run ordinary code: absence of a Domain is not
proof that a supplied callback performs no I/O.

## Check routing behavior before changing a classifier

`spectre.routes` displays structure; `spectre.eval` measures agreement with
explicit examples. An example dataset looks like this:

```jsonl
{"input":"hello Ada","expected":{"status":"matched","rule":"greetings/hello","via":"regex"}}
{"input":"what can you do","expected":{"status":"matched","rule":"greetings/help"}}
{"input":"refund order 42","expected":{"status":"no_match"}}
```

Use qualified **rule** names printed by `spectre.routes`, not kernel classes.
`via` is optional: include it only when changing the matching method should
itself count as a regression. Other expected statuses are `ambiguous` with a
`rules` list, `halted`, `unrouted`, and `error`. Ambiguity compares the rule set,
not its order. A callback failure is not a miss. Malformed and empty datasets
fail the command; they cannot produce a green zero-case report.

`--flow greetings` is mandatory. `--max-cases 10000` rejects oversized datasets
rather than silently testing a prefix. `--max-failures 20` limits retained
details, not the number of evaluated mismatches. The command prints totals and
failed physical line numbers, then fails CI if any expectation differs. It
does not print input, captures, vectors or private callback error messages.

For custom adapters, semantic caches, pipelines or captured classifier outputs,
use `Spectre.Eval.run/3` / `run_file/3` from an application test with its prepared
Router or `Spectre.Agent.Flow`. `Eval.prepare/3` can also prepare current compiled
Agent, Router or nested Skill code with explicit `:adapters` and `:pipelines`.
The CLI supplies neither wiring nor implicit application startup.

<!-- spectre:example routing_evaluation -->
```elixir
{:ok, router} = Spectre.Router.new(%{
  "orders/lookup" => %{to: "lookup", match: %{regex: ~r/^order [0-9]+$/}},
  "orders/help" => %{to: "help", match: %{string_bag: ["help with my order"]}}
}, via: [:regex, :string_bag])

cases = [
  %{"input" => "order 2041", "expected" => %{"status" => "matched", "rule" => "orders/lookup"}},
  %{"input" => "weather tomorrow", "expected" => %{"status" => "no_match"}}
]
{:ok, report} = Spectre.Eval.run(router, cases)
0 = report.failed
```

`run/3` also accepts a function of one input returning the normal routing result.
That lets a test replay recorded classifier nominations through the existing
`Spectre.Agent.Classification` bridge or query a preloaded cache. Captured
vectors must use the same embedding profile as that cache. The harness never
trains/promotes cache entries, obtains embeddings, calls models, runs handlers,
or proves GAM authorization. Explicit host callbacks remain ordinary code:
the harness does not sandbox them or establish that they are pure.

## Development checks

From the repository, with Elixir `~> 1.19` and the supported OTP version:

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --seed 0
mix test --seed 42
mix test --cover
mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
mix hex.build
git diff --check
```

Benchee is development-only; provider/database libraries are not implicit
runtime dependencies. Tests use host doubles and deterministic fixtures, but
those doubles are not proof of a real PostgreSQL, Mnesia cluster, S3 or network
deployment. Run integration tests against the deployment you intend to claim.

## Trace the law through the whole lifecycle

| Property | Assertions beyond happy-path output |
| --- | --- |
| Authority never grows | Child coverage/Meters do not exceed ancestors; restriction/revocation survive replay; evidence cannot choose a new principal |
| Record before capability | No broker/executor call on refusal, incomplete/ambiguous commit or invalid receipt; Attempt is durable before checkout |
| Causality is not rewritten | Late observation after revocation/restart is recorded; no-effect and ambiguous results are not conflated; no blind executor retry |
| Duty does not self-extinguish | Deadline derives debt; timer alone never disposes it; responsible/conflicted actors cannot self-clear it |
| Information flow remains bound | Consent occurrence, assumption DAG, counterproofs, erased parents and labels survive complete-agent paths |
| Canonical facts are exact | Integer/float confusion, duplicate fields, wrong keys, malformed frames, wrong Domain and hash/identity mismatch are rejected |

Use a real admitted setup and normal ingress/governance paths where possible.
Manually inserting a root Mandate into a projection can test a pure helper; it
does not prove an application can obtain that authority through the runtime.
Assert callback order/cardinality, forbidden calls, ledger records and both
sides of the accounting transition, not just `{:ok, _}`.

## Agent integration tests

Exercise agents without Skills, with namespaced Skills, with Extension ports,
and after a governed Morph. Include regex/string-bag/custom binary routing,
ties, misses and adapter failures. The selected Candidate must still be denied
when the current authority or evidence does not cover it.

Stateful Instance tests need barriers, not timing guesses: hold a callback until
the test explicitly releases it, read state during the hold, change authority,
stop the Domain and deliver a late result. Verify that only an allowed successful
completion changes local state and that no stale worker resurrects a fenced Scope.

For [streaming integrations](integration-and-streaming.md), assert that governed
content is not delivered before admission, new input does not rewrite an old
Act's evidence basis, interrupted provider work stays uncertain when appropriate,
and local cancel is not a successful Outcome or Duty disposal.

The complete-agent suites are organized by scenario rather than one growing
file. Shared `ExUnit.CaseTemplate` fixtures live in `test/support/`; they start
isolated state for each test, not a shared Domain for the whole suite.

| Scenario | Test source under `test/core/` |
| --- | --- |
| Basic agents, Skills and Instance lifecycle | `full_agents_test.exs` |
| Information lineage, governance, Duties, consent and external payloads | `agents_information_test.exs`, `agents_governance_test.exs`, `agents_duty_test.exs`, `agents_consent_test.exs`, `agents_payload_test.exs` |
| Regex, string-bag, custom matching and input pipelines | `routed_agents_test.exs` |
| Routed checkpoints/Morph, provenance/isolation and durable recovery | `routed_agents_lifecycle_test.exs`, `routed_agents_provenance_test.exs`, `routed_agents_recovery_test.exs` |

Use `test/support/full_agent_case.ex` and `test/support/routed_agent_case.ex`
for common host wiring and ledger/accounting assertions. Keep scenario-specific
assertions alongside their tests, so the property under examination stays visible.

### Real semantic-cache integration

`vettore` and `ex_fastembed` are test-only dependencies in the root project.
There is no separate adapter package or alternate Mix configuration. The first
test build compiles native code and requires a Rust toolchain; the first model
load downloads `BAAI/bge-small-en-v1.5` (384 dimensions). Reuse `.fastembed_cache/`
between runs. Models and compiled native libraries are not Spectre runtime
dependencies or release artifacts.

```sh
MIX_ENV=test mix deps.get
mix test test/agents/semantic_cache_vettore_test.exs \
  test/agents/semantic_cache_real_embeddings_test.exs \
  test/agents/semantic_cache_real_agent_test.exs \
  test/agents/optional_cache_dependencies_test.exs --seed 42
```

These tests also run in the ordinary full suite. Flat/HNSW searches use real
native indexes; held-out customer paraphrases use actual model output, not
hand-written vectors. The complete-agent tests continue through governed
admission, execution, recorded Outcome and offline audit. A missing model or
failed download is a test failure, never a silent skip. Separate VM tests check
that Spectre and the Exact cache still work without either native dependency.

## Faults and differential checks

Inject failure before commit, after durable commit but before acknowledgement,
after Grant consumption, during broker checkout and after the external action
but before its receipt. Independently tamper with storage keys, batches, counts,
timestamps, digests and entire internally consistent histories. The last case
requires an external witness to detect: a hash chain alone cannot do it.

Compare indexed/incremental facts to the exhaustive pure derivation over the
same verified prefix. Compare live fold and offline export audit. Keep raw
state fixtures for helper tests, but include real transition sequences: otherwise
an index test can agree with an equally incomplete fixture.

## Performance and memory

The development benchmark suite can be run with:

```sh
mix run bench/suite.exs --quick
mix run bench/suite.exs --phase growth --stores ets,disk_compressed \
  --checkpoints 10,50,100,200,500,1000,2000 --payload-bytes 16384
mix run bench/authority_reads.exs --quick
```

These scripts are repository development assets, not Hex package commands.
See `bench/README.md` in the source checkout for all options and units.
Quick runs check the workloads, not p99 stability. The focused authority
microbenchmark is not a complete agent benchmark.

Measure completed cycles, CPU reductions, append counts/bytes, payload verify
calls, sequencer heap, backend ETS/process memory and physical ledger bytes
separately. Include external payloads, consent, completed erasure, concurrent
proponents, overload and recovery. A compressed store or flat CPU curve does
not imply bounded total memory. Record environment, revision, dirty status,
sample counts and whether explicit GC changed the measurement.

## Documentation is an executable artifact

The release-artifact tests check that published guides exist, are included in
the package and do not link to missing local files or Markdown sections.
**Every fenced Elixir block**
in the published guides must have a unique `spectre:example` marker and an
explicit test context in `test/core/documentation_examples_test.exs` or
`test/core/documentation_recipes_test.exs`. Removing
a marker fails verification rather than silently dropping the example.
Wiring fragments execute with explicit test-host foundations and resources;
Agent/Stack body fragments compile inside the declared module context.
The tests render the distributed prompt file, exercise custom/semantic routing,
start the real Domain and verify admitted, undecidable and pending paths.
They do not create a permissive production foundation or simulate a provider.

The complete authoring listing in the recipes is checked byte-for-byte against
`examples/authoring.exs` and compiled in that file's declared location, beside
its prompt directory. Links to the listing target the guide, not a raw `.exs`
path that would work on GitHub but be missing from generated HexDocs.

After generation, `mix run scripts/check_documentation_links.exs doc` checks
local files and fragments in the actual HTML site. CI runs it too. This catches
relative source links and callback anchors that a successful ExDoc build alone
can miss. It does not certify external websites or unpublished source commits.

While 0.4 is unreleased, source links target its development branch. After the
release commit/tag is published, generate release docs with the explicit ref:

```sh
SPECTRE_DOCS_REF=v0.4.0 mix docs --warnings-as-errors
```

`SPECTRE_DOCS_REF` only changes documentation source links. It does not select
an Agent Definition, change runtime behavior or create/push a Git tag. New
source files are accessible remotely only after the host repository is pushed.

CI uses the root `mix.lock` for all test dependencies. The ordinary matrix runs
real embeddings and the >=60-second Worker/Vigil/Skill lifecycle, with a cached
model download and no separate checkout or opt-in lane. The benchmark smoke job
runs the development Benchee suite and uploads latency/ledger/memory results;
it is not a throughput guarantee on a shared runner. Coverage remains a separate
gate at the configured threshold, not evidence that every contract is correct.

The package job compares the unpacked release byte-for-byte with `mix.exs`'s
file manifest. It also compiles in a fresh production directory and starts
Spectre/Exact with Vettore and ExFastembed absent from the code path. Residual
native files in a developer's `_build` cannot make this isolation check pass.

ExDoc and Hex packaging must both succeed. The landing page, capability
inventory and trust assumptions must describe the same version. A clean
compiler, Credo and Dialyzer result cannot detect duplicated ExUnit names,
incorrect operator advice, network-effect ordering or quadratic runtime work.
