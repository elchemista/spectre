# Test an agent and prepare a release

Start with the behavior you want to trust.

Can the Router select the right handler? Can a refused request accidentally
reach the backend? What happens when a receipt arrives after a timeout?

Those questions need different tests. A coverage percentage helps find missing
paths, but it does not answer them on its own.

This guide starts with tests for your application. The
[release checklist](#build-locally-before-publishing) is for Spectre maintainers.

## Scaffold a local agent

From your host Mix application:

```sh
mix spectre.gen.agent MyApp.Hello --dry-run
mix spectre.gen.agent MyApp.Hello
mix test test/my_app/hello_test.exs
mix spectre.routes MyApp.Hello
mix spectre.eval MyApp.Hello test/my_app/hello_routes.jsonl --flow greetings
```

For an umbrella, run from the chosen child application.

The generator creates five files:

| File | Purpose |
| --- | --- |
| `lib/my_app/hello.ex` | Agent handlers that prepare a local greeting |
| `lib/my_app/hello/router.ex` | Greeting/help routes |
| `lib/my_app/hello/prompts/hello.txt.eex` | Compiled greeting template |
| `test/my_app/hello_test.exs` | Local routing and handler tests |
| `test/my_app/hello_routes.jsonl` | Input/expected-route examples |

`--dry-run` lists paths without writing. Existing targets stop generation
before any write; there is no force-overwrite option.

The local greeting uses `Spectre.Agent.render_prompt/3`. It needs no model,
Domain or credential. Returning local state does not send a message.

These tests establish local authoring behavior, not permission to act.
For the first governed backend operation, use
[the host scaffold](host-setup.md#from-a-draft-to-your-first-governed-save).

### Test the connection from input to handler

A hand-built handler message can hide a broken route. Route actual input,
then call the handler with the resulting message:

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

Changing the regex or route name now affects the test.

`nil` is appropriate here only because this callback ignores the Turn.
If your handler needs authenticated context, test it through a real Instance.

`route_message/4` does not create a Turn, record Evidence or submit a request.
For custom methods and pipelines, pass explicit `adapters` and `pipelines`.
Those callbacks are still ordinary host code, not sandboxed pure functions.

Preparation failures return `{:error, reason}`.
Routing misses, ambiguity and errors become `{:ok, handler_message}`, allowing
you to test the application's chosen response.

Nested Skill paths use the Skill's local handler names. Call the owning Skill
with its own state, not the parent handler.

## Check routing behavior before changing a classifier

Use `spectre.routes` to inspect structure.
Use `spectre.eval` to check behavior against examples.

A JSONL file contains one case per line:

```jsonl
{"input":"hello Ada","expected":{"status":"matched","rule":"greetings/hello","via":"regex"}}
{"input":"what can you do","expected":{"status":"matched","rule":"greetings/help"}}
{"input":"refund order 42","expected":{"status":"no_match"}}
```

`rule` uses the qualified name printed by `spectre.routes`, not a kernel
action class. Include `via` only if changing the method should count as a
regression too.

Supported expected statuses are matched, ambiguous, no_match, halted, unrouted
and error. An ambiguous expectation has a `rules` list whose order does not
matter.

### What the CLI checks

- `--flow` is required.
- `--max-cases` defaults to 10,000; oversized input is rejected, not silently
  truncated.
- `--max-failures` defaults to 20 retained details. Every case is still checked.
- Empty or malformed datasets fail.
- Any mismatch fails the command.

Reports identify failed lines without printing inputs, captures or private
callback error messages.

### Use the same evaluator from ExUnit

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

For a cache, pipeline or captured classifier result, use a prepared Router or
Flow with `Spectre.Eval.run/3` or `run_file/3`.
`Eval.prepare/3` can prepare an Agent, extracted Router or nested Skill with
explicit wiring.

`run/3` also accepts a function returning the ordinary routing result.
That lets you replay recorded classifier nominations or query a preloaded
cache without asking a live model.

Eval does not run handlers, dispatch effects, train models or prove authority.
A supplied callback can still perform I/O; the evaluator does not sandbox it.

## Agent integration tests

Once routing works, test the path into your actual governed operation.

For the order Agent, useful cases include:

1. A covered order produces one admitted lookup.
2. An uncovered order never reaches the executor.
3. Missing required Evidence produces `:undecidable`, not a provider call.
4. An executor timeout does not produce a retry.
5. A later receipt is recorded without repeating the lookup or overwriting
   newer conversation state.

Test Agents both with and without Skills. Include adapter failures, ambiguous
routes, checkpoint restoration and governed Definition changes.

### Test concurrency deliberately

Hold a callback behind a test-controlled barrier. While it is waiting, read
Instance state, change authority or stop the Domain. Then release the callback
and inspect what is accepted.

This tests the actual ordering. Sleeping for an estimated interval and hoping
two processes overlap is a weaker test.

For streaming, include preview/delivery paths and ensure no governed content is
sent before authorization. Stopping the UI must not become a successful
Outcome or Duty resolution.

### Find existing whole-agent tests

Shared fixtures are in `test/support/`; each test gets isolated state.

| Scenario | Test source under `test/core/` |
| --- | --- |
| Basic agents, Skills and Instance lifecycle | `full_agents_test.exs` |
| Information lineage, governance, Duties, consent and external payloads | `agents_information_test.exs`, `agents_governance_test.exs`, `agents_duty_test.exs`, `agents_consent_test.exs`, `agents_payload_test.exs` |
| Regex, string-bag, custom matching and input pipelines | `routed_agents_test.exs` |
| Routed checkpoints/Morph, provenance/isolation and durable recovery | `routed_agents_lifecycle_test.exs`, `routed_agents_provenance_test.exs`, `routed_agents_recovery_test.exs` |


Use `full_agent_case.ex` and `routed_agent_case.ex` for common host wiring,
but keep the scenario's assertions beside the test.

### Real semantic-cache integration

The root test dependencies include Vettore and ExFastembed.
They are not production dependencies.

The first native build needs Rust. The first embedding-model load downloads
`BAAI/bge-small-en-v1.5` (384 dimensions); cache it in `.fastembed_cache/`.

Run the focused integration tests with:

```sh
MIX_ENV=test mix deps.get
mix test test/agents/semantic_cache_vettore_test.exs \
  test/agents/semantic_cache_real_embeddings_test.exs \
  test/agents/semantic_cache_real_agent_test.exs \
  test/agents/optional_cache_dependencies_test.exs --seed 42
```

They also run in the ordinary suite. They use native Flat/HNSW search and real
model-generated vectors. Whole-agent cases continue through admission,
execution, Outcome and offline audit.

A missing model or failed download is a failure, not a skipped test.
Separate VM tests check that Spectre and Exact work without either native
dependency.

## Trace the law through the whole lifecycle

Do not stop at “the callback returned ok.”

| Property | What to assert |
| --- | --- |
| Authority cannot grow | Child permissions and budgets do not exceed their source |
| Record before capability | No executor/broker call on refusal or unconfirmed commit |
| Preserve causality | Late receipts survive revocation/restart; uncertain effects are not retried |
| Duties need resolution | Timer expiry or the responsible actor alone cannot silently close one |
| Preserve information constraints | Consent, source labels and erased support remain meaningful through replay |
| Exact canonical records | Reject malformed fields, non-integer revisions and wrong identities |

Prefer the public ingress/governance path for lifecycle tests.
Directly constructing a projection can test a helper, but does not establish
that the running application can obtain that authority.

Inspect ledger records, callback counts and both sides of Meter accounting.

## Faults and differential checks

Test failures at the boundaries where uncertainty changes meaning:

- before the write;
- after commit but before acknowledgement;
- after Attempt/grant consumption;
- during broker checkout;
- after the external effect but before its receipt.

Also test altered storage: missing batches, wrong keys, malformed timestamps,
bad digests and impossible transitions.

A fully rewritten but internally consistent history needs an independent
witness to detect. A hash-chain test cannot establish that guarantee alone.

A **differential test** compares two ways of deriving the same answer.
For example, compare an incremental index with exhaustive derivation over the
same history, or live replay with offline audit.
Use real transition sequences as well as isolated helper fixtures.

## Development checks

From the source repository:

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --seed 0
mix test --seed 42
mix test --cover
mix credo --strict
mix dialyzer
git diff --check
```

The checks complement each other. Static analysis does not detect every
ordering error, duplicated test name, misleading operator instruction or
history-dependent performance problem.

Tests using scripted backends do not qualify a real PostgreSQL deployment,
Mnesia cluster or remote payload store. Add fault tests for the backend and
deployment you intend to rely on.

## Performance and memory

The source checkout includes development benchmarks:

```sh
mix run bench/suite.exs --quick
mix run bench/suite.exs --phase growth --stores ets,disk_compressed \
  --checkpoints 10,50,100,200,500,1000,2000 --payload-bytes 16384
mix run bench/authority_reads.exs --quick
```

These scripts are not shipped as Hex package commands. See `bench/README.md`
in the source checkout for options and units.

A quick run checks that the workload works. It does not establish reliable
tail latency—the slowest requests—or months of sustained service.

Measure elapsed time, CPU work, ledger growth, external payload calls and
process/store memory separately. Include consent, erasure, concurrent requests,
overload and recovery. State the revision, environment and sample count, and
whether you forced garbage collection.

Compression or flat CPU cost alone does not prove bounded total memory.

## Documentation is an executable artifact

The guides' Elixir examples are checked by tests, including setup fragments
that need explicit host fixtures.

Every fenced Elixir example needs a unique `spectre:example` marker and a
test context in the documentation tests. Removing the marker fails verification;
it does not quietly remove that example from the suite.

The full recipe listing is checked against `examples/authoring.exs`.
Its prompt file must stay in the matching location.

After generating HTML, check the actual links:

```sh
mix docs --warnings-as-errors
mix run scripts/check_documentation_links.exs doc
```

This catches missing pages and section anchors. It does not verify external
websites or guarantee that a source commit has been pushed.

### Build locally before publishing

These checks create local artifacts only:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
ERL_FLAGS='+S 4:4' mix test --cover --seed 1701 --max-cases 16 --warnings-as-errors
mix docs --warnings-as-errors
mix run scripts/check_documentation_links.exs doc
mix hex.audit
package_dir=$(mktemp -d)
mix hex.build --unpack --output "$package_dir"
mix run scripts/check_package.exs "$package_dir"
```

`hex.build` does not publish. `hex.audit` checks dependency advisories,
not the security of your application.

Before publishing, finalize the release status/date, review the
[documented limits](capabilities.md), and ensure the intended source tag exists
remotely. Generate published documentation with that tag:

```sh
SPECTRE_DOCS_REF=v0.4.0 mix docs --warnings-as-errors
```

That variable changes source links only. It does not create or push a tag.

### What CI checks

The ordinary test matrix includes native embeddings and the one-minute
Worker/Vigil/Skill lifecycle. Coverage has a separate 95.5% gate.
The benchmark job is a smoke run with measurements, not a production SLO.

The package job compares files byte-for-byte with the manifest and performs
a fresh production build. It starts Spectre/Exact with Vettore and ExFastembed
absent, so an old local build cannot hide a dependency leak.

Keep library checks and deployment qualification separate.
The release should state the guarantees and limitations it actually has,
without promising that every external integration has been qualified.
