# Spectre semantic cache: Vettore backend

Optional backend for Spectre 0.4. The core has no Vettore dependency.
Exact matching, review/CAS, bounded pages and snapshots reuse the same engine
as `Spectre.Router.SemanticCache.Exact`; only the derived vector index differs.

Add `{:spectre_semantic_cache_vettore, "~> 0.4.0"}` to the host dependencies
when this package is published, or use this directory as a local path dependency.

```elixir
# Agent or reusable Stack: declaration only, no process startup.
adapter :semantic_cache, :routing, Spectre.SemanticCache.Vettore,
  max_entries: 2_000, dimensions: 384

semantic_cache :routing, learn: :review

flow :support do
  router via: [:semantic_cache, :regex], cache: :routing, accept: 0.9
  route :answer, cache: true, match: [regex: ~r/^question:/]
end
```

The host supervises a child bound to the exact partition:

```elixir
{Spectre.SemanticCache.Vettore,
 name: MyApp.RoutingCache,
 namespace: "tenant:acme",
 definition_ref: published_definition.ref,
 flow: "support",
 labels: ["support/answer"],
 profile_ref: encoder_profile.ref,
 max_entries: 2_000,
 dimensions: 384,
 index: :flat}
```

Wire `server: MyApp.RoutingCache` and the same namespace/profile into the
Instance's `semantic_cache` adapter binding. An address is not an authorization:
the host must select the partition for the authenticated tenant. Definition,
flow and encoder refs must match, even if two encoders have equal dimensions.
Declared limits must match the running backend's configuration.

There is no `embed:` callback. Exact lookup needs no vector; semantic lookup
requires an already computed vector with its encoder ref. Provider execution,
model download and training do not happen inside the Router.

New/edited examples are quarantined until explicit revision-checked approval.
Snapshots include text and vectors, so backup retention and deletion remain
host responsibilities. A snapshot restores only a fresh empty destination;
it is not a merge operation that can silently restore old approvals.

`:flat` is the default index; `:hnsw` is also available. Both use normalized
cosine vectors. Capacity counts approved and quarantined examples alike.
