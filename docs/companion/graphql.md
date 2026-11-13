# Canonical history GraphQL API

The Companion serves a read-only GraphQL API at `/graphql` on the same loopback
host as the [operational REST API](api.md). The version-controlled schema is
[`schema.graphql`](../../src/companion/src/Runtime/GraphQL/schema.graphql).
GraphQL exposes canonical history, not import, monitoring, recorder evidence,
configuration payloads, or provenance. There is no dashboard dependency.

## Executing a query

Start `artisanlogbook serve` and use the actual loopback port printed at startup.
Requests must use POST, JSON, `Content-Length` (provided by curl), and the
nonempty client header. The existing Host, same-origin and DNS-rebinding
protections apply. There is no CORS, GET execution, WebSocket, subscription,
mutation, or multipart upload endpoint. Introspection queries are allowed by
POST under the same security and resource limits; schema downloads and the
browser IDE are not exposed.

```bash
BASE=http://127.0.0.1:48721
curl -sS "$BASE/graphql" \
  -H 'Content-Type: application/json' \
  -H 'X-Artisan-Logbook-Client: curl' \
  --data-binary '{"query":"query CharacterHistory { characters(first: 10) { nodes { id name crafts(first: 20) { nodes { id recordedAt concentrationSpent ingenuityRefund recipe { id name profession { id name } expansion { id name } } reagents { item { id name } allocatedQuantity returnedQuantity } outputs { item { id name } quality quantity } } pageInfo { hasNextPage endCursor } } } } }"}'
```

Use the item ID returned by `items { nodes { id } }` for reverse navigation:

```bash
ITEM_ID='replace-with-an-item-id'
jq -n --arg id "$ITEM_ID" '{
  query: "query ReagentUsage($id: ID!) { item(id: $id) { id name consumingCrafts(first: 50) { nodes { id recordedAt character { name } recipe { name } reagents { item { id name } allocatedQuantity returnedQuantity } } pageInfo { hasNextPage endCursor } } } }",
  variables: {id: $id}
}' | curl -sS "$BASE/graphql" \
  -H 'Content-Type: application/json' \
  -H 'X-Artisan-Logbook-Client: curl' --data-binary @-
```

GraphQL errors appear in `errors`, and may accompany partial `data`. Invalid
IDs/cursors use `INVALID_ID_OR_CURSOR`; invalid page sizes use
`INVALID_PAGE_SIZE`; incompatible context filters use `INVALID_FILTER`.
Unexpected exceptions do not expose SQL, native errors, paths, or stack traces.
Unexpected execution exceptions are logged locally; client cancellation is not
logged as an execution failure.

## Entities and observations

Root collections and individual lookups cover crafts, characters, recipes,
professions, expansions, items and game contexts. Recipe and item collections
accept an optional `search` argument. It matches a case-insensitive literal
substring of the stored name; `%` and `_` have no wildcard meaning. A null or
empty search applies no name filter. Search combines with game-context,
profession and expansion relationship scopes. Character name search is not
provided. Each dimension ID includes its game context. A character is keyed by
its canonical character identity, not its
name; a craft is keyed by canonical origin and observation. Recipe, profession
and item IDs use Blizzard IDs within the game context; expansion keys are the
canonical stored keys. Project is an integer because the canonical model permits
future project IDs not represented by today's enum.

Craft reagent and output rows are actual observations. Reagent quantities are
independently nullable, and outputs have item/quality grain. Recipe reagent
slots are canonical schematic slots, not historical request evidence or
observed craft inputs. Their candidate items may be null when unobserved, or an
empty list when observed empty. An empty slot list means no canonical slots are
stored; the schema does not establish that the full schematic was observed.
Production observations are not a recipe-output catalog. Expansion and parent
profession identities are not inferred from names or dates.

Unknown measurements and booleans are null, distinct from zero and false.
Unobserved craft reagents and outputs are null, distinct from observed empty
lists. Completeness fields are independent nullable observations. A known
identity remains navigable if its display metadata is missing; names and
other optional metadata are nullable. `Long` preserves 64-bit quantities,
`Decimal` preserves canonical decimal quantities, and `DateTime` includes an
offset. Clients using JavaScript numbers should use a lossless JSON parser for
large integers and high-precision decimals.

## IDs, filters and pagination

IDs are opaque, versioned base64url-encoded JSON containing an entity kind and
its canonical identity; craft IDs contain origin and observation, while
dimensions contain project, optional progression track, and canonical key.
They are stable across restarts and metadata enrichment and do not use database
surrogate keys. IDs are **not secrets**. Hot Chocolate's Relay/Node support was
evaluated; the initial API uses explicit typed lookups and a versioned composite
identity encoding rather than introducing a second domain identity or exposing
a Node contract.

The decoder accepts long API-generated IDs and cursors without a separate
character-count cap. Each request must still fit within the 16 KiB GraphQL POST
body limit, including JSON and query overhead; clients should pass long values
as variables rather than interpolating them into the query text.

`crafts(filter: ...)` accepts `gameId`, `characterId`, `recipeId`, `professionId`,
`expansionId`, `inputItemId`, `outputItemId`, and inclusive `from`/`to`
timestamps. Dimension IDs imply their context; conflicting contexts or an
inverted time range are rejected. Item filters match actual reagent/output
rows. Other collections can be scoped through a game context, profession or
expansion relationship.

Collections default to 20 items, with `first` from 1 to 100. Pass `endCursor`
as `after` to continue. Cursors are opaque versioned base64url positions with
a collection kind; invalid or wrong-kind cursors are rejected. Craft ordering
is newest recorded instant first, preserving 100 ns precision across offsets,
then origin and observation ascending. Dimensions order by canonical game-context
key and entity identity. Cursor positions are not frozen snapshots: an import
between requests can add rows after the position that appear on later pages,
while rows inserted before the position will not appear in that continuation.
These are custom forward-only `nodes` connections, not a complete Relay
connection contract; there are no edges, backward pagination, total counts or
Node interface.

## Resource and consistency boundaries

POST bodies are limited to 16 KiB for `/graphql`; REST retains its 4 KiB
limit. Hot Chocolate enforces a 100-field parser limit, maximum execution
depth 12, 30-second execution timeout, a 35,000 field cost limit and a 50,000
type cost limit, and
at most eight concurrent executions. List-size annotations account for the
requested page size; other lists use an assumed size of 20 for static cost
analysis. DataLoader-backed lookups have low explicit field weights; reverse
collections that issue a bounded repository operation per parent have higher
weights. Request/variable batching is disabled and the maximum batch size is
one. A single-element request array may be treated as a single request by the
transport. These limits also apply to introspection.

The limits were calibrated using Hot Chocolate's cost analysis with the pinned
implementation. Representative field/type costs were 911/1,682 for recent
crafts with metadata, 9,041/16,832 for the documented character-history query,
2,162/2,154 for item usage, 22,031/41,522 for a larger dashboard page, and
28,851/24,642 for schematic candidates plus observed reagents/outputs. Both a
100-recipe-by-100-crafts query and 50 items with two 20-craft reverse
collections scored 100,111 field cost and are rejected before repository
resolvers run. A 100-character-by-100-craft page with reagent/output lists
scored 20,211 field cost but 410,202 type cost, demonstrating independent
rejection by the type limit before repository work. The accepted larger
dashboard sample stays below both caps. These estimates bound permitted query
shape and materialization; they are not a count of SQL statements or a
database-connection limit.
Concurrent GraphQL executions are capped at eight requests, but resolvers
within a request can execute concurrently and HistoryStore opens independent
read connections per repository operation. There is intentionally no global
database concurrency manager or connection pool.

Resolvers and request-local DataLoaders use focused craft/dimension repositories.
Repositories invoke typed `HistoryStore` operations; neither layer owns a
connection or emits SQL. HistoryStore uses handcrafted parameterized DuckDB SQL
and Dapper on independent read connections. A craft page uses one header query
and two batched child queries, inside one snapshot. Shared dimension lookups
use exact context/key pairs in batched queries, and recipe schematic slots are
batched. Character craft pages are grouped with partitioned SQL and materialized
together in groups of up to 50; each parent still has its own page and cursor.
Other nested reverse collections currently execute one bounded repository
operation per parent; grouping arbitrary nested pagination is deliberately
deferred.

Each repository operation has a snapshot across its SQL statements, not across
the entire GraphQL request. Separate resolvers can observe different commits.
Request cancellation flows through resolvers, loaders and repositories to
HistoryStore's connection-local native interruption. The existing bounded
shutdown and independent-reader/writer guarantees remain in effect.

## Exporting and verifying the schema

From the repository root, regenerate the snapshot after intentionally changing
the GraphQL contract:

```bash
UPDATE_GRAPHQL_SCHEMA=1 dotnet test src/companion/tests/Cli/Tests.Cli.csproj \
  --filter 'FullyQualifiedName~GraphQLSchemaMatchesTheVersionControlledContract'
```

Run the same test without `UPDATE_GRAPHQL_SCHEMA` to verify the committed SDL.
The existing REST OpenAPI contract and verification are independent.
