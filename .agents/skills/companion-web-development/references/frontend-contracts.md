# Frontend contracts

Read the [web guide](../../../../docs/companion/web.md),
[GraphQL contract](../../../../docs/companion/graphql.md) and
[REST contract](../../../../docs/companion/api.md) for the changed surface.
Reuse [clients.ts](../../../../src/companion/web/src/api/clients.ts): relative
URLs, POST GraphQL, omitted credentials, the client header and REST AbortSignals.
Use generated operation documents/types; committed SDL, OpenAPI and authored
operations are the offline sources. Contract changes require backend contract
tests and explicit client regeneration.

For context navigation, REST metadata uses `canonicalId` and `routeAlias`.
Use the alias in browser URLs and the canonical string for analytical and cache
identity. Current friendly aliases cover only base Retail and Forever contexts;
all other contexts use the canonical ID as their alias. Context-scoped REST
resources live under `/api/v1/games/{context}`, and the backend is authoritative
for resolving the complete context.

Apollo's existing `__typename:id` identity uses opaque canonical IDs for
entities. Analysis contribution, recipe and configuration rows embed scoped
measures and must not be normalized by their entity ID: the same ID can have
different values across populations and item roles. Do not decode IDs or cursors
or introduce a parallel identity. Connections are
forward-only `nodes`/`pageInfo`, not full Relay; replace pages on Next and reset
on Newest. Cursors are not frozen snapshots across imports. Respect bounded
queries, existing DataLoaders and the documented remaining per-parent queries.

Long and Decimal exceed JavaScript number precision; generated mappings are not
lossless. Use exact string-valued analytical aggregates for precision-sensitive
quantities and preserve safe-integer warnings for REST counts. Keep unknown
metadata and measurements distinct from zero.

Analytical destinations are context-qualified and keep investigation scope in
the URL. A related link inherits compatible scope; context-wide search starts an
independent investigation. Status updates independently. Detailed analysis
retains results until explicit refresh, indicating relevant changes without
claiming a durable snapshot. Preserve cancellation, context isolation, retry and
redacted errors. `no-store` does not invalidate Apollo's cache.
