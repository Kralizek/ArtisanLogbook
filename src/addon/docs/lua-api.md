# Public Lua API

This document defines the stable, read-only Lua API introduced by issue #5.
It is the consumer contract for the production UI and other addons. It is
separate from the SavedVariables persistence schema documented in
[storage-ledger.md](storage-ledger.md) and from any future portable AL1 export.

## API v1

UI and addon consumers use the global `ArtisanLogbookAPI`, not SavedVariables,
dimension rows, or the private addon namespace. The API is loaded before
`ADDON_LOADED`; queries become available after Artisan Logbook initializes.
Consumers should declare an addon dependency or wait for its load event.
This contract is independent of the persistence schema and any future AL1
portable export. No export, statistics, costing, or UI is implemented here.

All calls use **dot syntax**, not colon syntax:

```lua
local craft, reason = ArtisanLogbookAPI.GetCraft(id)
local page, reason = ArtisanLogbookAPI.GetCrafts(filter, options)
local facets, reason = ArtisanLogbookAPI.GetFacets(filter, options)
local capabilities, reason = ArtisanLogbookAPI.GetCapabilities()
local unsubscribe, reason = ArtisanLogbookAPI.RegisterCallback("CRAFT_COMMITTED", function(craft)
  -- Refresh consumer state using the committed craft projection.
end)
```

Successful calls return the requested value; failures return `nil, reason`.
`GetCraft` returns `nil, "not-found"` for an absent/pruned positive local craft
ID, or `"invalid-id"` for a non-positive, fractional, non-finite, or non-numeric
ID. Data queries return `"not-ready"` before initialization or when the ledger
was refused. Capabilities require the adapter, independently of ledger loading.
Other errors are `"invalid-filter"`, `"invalid-options"`, `"invalid-cursor"`,
`"invalid-event"`, and `"invalid-callback"`. Correct a failed request rather than
retrying it as an unfiltered query.

### Projection shape and identities

Both craft queries and callback payloads use the same shape:

```lua
{
  id = 123, timestamp = 1800000000, -- local craft ID; observed server timestamp
  character = { key = "...", name = "...", guid = "...", realm = realm },
  realm = realm,
  profession = profession,
  recipe = recipe,
  expansion = expansion, -- ONLY the attributed recipe's expansion
  outputItem = item,
  gameOperationId = 0,
  outputQuantity = 5, outputQuality = 0, outputItemLevel = 0,
  multicraftBonus = 0, concentrationSpent = 0, concentrationCurrencyId = 0,
  hasIngenuityProc = false, ingenuityRefund = 9,
  request = {
    id = 42, timestamp = 1800000000, recipe = recipe,
    requestedCount = 1, useConcentration = false,
    concentrationCost = 0, baseSkill = 10, baseDifficulty = 20, craftingQuality = 0,
    allocations = {
      { item = item, dataSlotIndex = 1, allocatedQuantity = 3, quality = 0 },
    },
  },
  reagents = {
    { item = item, dataSlotIndex = 1, quality = 0,
      allocatedQuantity = 3, returnedQuantity = 0, source = nil },
  },
}
```

This is an illustrative shape, **not a set of defaults**. Fields without evidence
are absent (`nil`); observed zero/false survive unchanged. `id`, `timestamp`, and
the `reagents` array are always supplied. An empty reagent array means no
retained reagent facts, not proof of no reagent consumption. `request` is absent
without a correlated submission; `request.allocations` is absent without a
captured selection. No context, order/customer data, or source is fabricated.
Request quotes remain separate from observed result measurements.

Related objects have these allowlisted fields (each metadata field is optional):

| Object | Public fields |
| --- | --- |
| realm | `key`, `name`, `identityScope`, `projectId`, `regionId`, `gameRealmId` |
| character | `key`, `name`, `guid`, resolved `realm` |
| expansion | `key`, `name`, `chronologicalOrder` |
| profession | WoW `skillLineId`, `name`, resolved `expansion` |
| recipe | WoW recipe `id`, `name`, resolved `profession`, resolved `expansion` |
| item | WoW item `id`, `name`, resolved `expansion` |

Character/realm keys are **opaque, case-sensitive API identities**, stable within
this ledger, not names or dimension IDs. Store/pass them back unchanged; do not
parse them. Known runtime identities are scoped by project, region, and realm.
Unresolved identities remain session-scoped rather than guessing cross-session
equivalence. Earlier stored identities retain their original scope; absent
`identityScope` is unknown, not proof of runtime scope. Transfers, identity repair,
and cross-ledger cursor/key portability are not promised.

Profession uses explicit craft attribution when present, otherwise the
attributed recipe's profession. Unknown native identity is not replaced with
a surrogate ID. Expansion always follows `craft -> recipe -> expansion`, never
output/reagent items, profession, or the current client. Item expansion describes
the item itself. No catalog is synthesized for missing metadata.

`request.id` identifies a shared submission across batch results. Its allocations
and quotes are the shared request snapshot, not totals to multiply or combine
implicitly. Craft reagents retain allocation/return-only distinctions and
ambiguous return matching described below. A positive `ingenuityRefund` is not
an applied refund when `hasIngenuityProc` is false; the API does not derive a proc
or net concentration.

All returned tables are detached, including nested related objects, request
allocations, facet details, and callback payloads. Consumers may mutate their
copies without affecting persistence, another query, or another subscriber.
The API has no write methods; detached copies are not immutable Lua proxies.
Internal dimension IDs, session rows, and unlisted persistence fields are not
public. Metadata may become known through ledger enrichment; reads project
current retained metadata without rewriting observed measurements.

### Shared filter

`nil`/`{}` selects all retained crafts. The only supported fields are:

```lua
{
  time = { from = 1800000000, to = 1800600000 },
  characters = { "opaque character key", "another character key" },
  realms = { "opaque realm key" },
  expansions = { "midnight" },
  professions = { 171, 333 }, -- WoW skill-line IDs
  recipes = { 12345, 67890 }, -- WoW recipe IDs
}
```

Selections are dense arrays: values within a field are ORed; different fields
are ANDed. Duplicates have no effect. An omitted selection imposes no restriction;
an empty array matches nothing for that field. Unknown identities never match a
selected known value. String keys must be nonempty and numeric identities must
be finite nonnegative integers (observed zero remains a value).

Time is a half-open absolute interval: `from <= timestamp < to`. Either bound
may be omitted, equal bounds select nothing, and reversed bounds are invalid.
Timestamps must be finite numbers. Relative calendar/UI presets are resolved
by consumers. The time constraint is never self-excluded by facets.

Unknown fields, non-table filters, metatables, sparse arrays, wrong value types,
and invalid times return `"invalid-filter"`. Context/property filters and
paging/sorting fields in a filter are intentionally rejected, not ignored.

### Craft ordering and paging

`GetCrafts(filter, { limit = 50, direction = "desc", cursor = nil })` returns
`{ crafts = { ... }, nextCursor = "..." }`. `nextCursor` is absent on the final
page (including an empty dataset). The default limit is 50; the **hard maximum
is 200**. Limits must be integers from 1 through 200; oversized limits are
rejected rather than clamped. Only `"asc"` and `"desc"` are supported, ordered
lexicographically by `(timestamp, local craft ID)` in that direction. Descending,
newest-first is the default. Ties always use craft ID.

Pass the opaque `nextCursor` unchanged, with the same filter and direction;
the limit may change. Equivalent reordered/deduplicated selections are accepted.
Cursors bind an exclusive timestamp/ID boundary, direction, normalized filter,
and the initial craft-ID high-water mark. Later commits are excluded from that
traversal, even if their clocks move backward. Start without a cursor to refresh.
This is **not a persistent snapshot**: startup pruning may remove pending rows or the
anchor, and metadata enrichment may change matches/details. A pruned anchor
does not invalidate the boundary. Cursors have no server-side cache or expiry,
survive reload against the same ledger, and must not be shared across ledgers
or edited (they are not authorization tokens).

Malformed cursors, impossible ID bounds, or mismatched filters/directions return
`"invalid-cursor"`. Unknown options, invalid limits/directions, and non-table
options return `"invalid-options"`; offset paging and arbitrary sort fields are
not supported. Filters are applied before ordering/page selection. Only selected
crafts' relationships are projected. `GetCraft` and callback projection use direct
runtime craft/request/reagent maps, with no retained-history scans. Unfiltered and
broadly filtered pages seek the timestamp/ID index with binary search, then walk
until the page and one lookahead match are found. Selective filters use the
smallest selected secondary-index population (OR-union of sorted craft-ID arrays)
and check the remaining AND constraints; sparse populations sort only their
candidate IDs for time ordering. No denormalized projections are cached.

History-sized work remains possible for explicit analytical queries, particularly
broad filters with few matches, but ordinary pages do not sort full history.
Facets reuse secondary-index candidate populations with the appropriate
self-exclusion; their counts may require traversing the full retained population.
Indexes are runtime-only and rebuilt after startup retention, never persisted
as another ledger. See [storage-ledger.md](storage-ledger.md) for details.

### Facets

`GetFacets(filter, { mode = "self-excluding" })` returns five arrays:
`characters`, `realms`, `expansions`, `professions`, and `recipes`. Entries are
`{ value = <filter identity>, count = <matching craft count>, details = <related object> }`,
sorted ascending by identity (numeric for recipes/professions, lexical for keys).
Each craft counts once per known identity; requests and reagent quantities do not
inflate counts. Unknown identities and unreferenced dimensions are omitted.

Default `"self-excluding"` computes each facet with every active constraint
**except that facet's selection**. Midnight + Alchemy therefore lists all
professions available in Midnight, while recipe choices still require Alchemy.
`"strict"` applies the complete filter to every facet. Values always come from
the retained population, never current-flavor support or an expansion catalog.
Only `mode` is accepted: paging, cursors, craft sort directions, and invalid modes
return `"invalid-options"`.

### Runtime capabilities

`GetCapabilities()` returns a fresh
`{ flavor = "...", craftResults = boolean, personalRequests = boolean, reagentAllocations = boolean }`.
`craftResults` reports successful registration of the authoritative result event;
`personalRequests` additionally requires the personal `CraftRecipe` hook;
`reagentAllocations` additionally requires the personal operation quote hook.
Unsupported adapters report false for these capture paths. True means the path
is available, **not** that every craft will contain every related measurement or
that every event's semantics have been verified. Optional fields still depend on
payload evidence and unambiguous correlation. Orders/recraft requests and reagent
ownership remain unsupported in this slice.

Capabilities describe the current adapter, not the session stored with a craft.
Historical facets/measurements are never hidden or reclassified when runtime
capabilities differ. Internal tracer events/hook maps and diagnostic errors are
not public capability fields or public callback events.

### Callbacks

Only `"CRAFT_COMMITTED"` is supported. Its callback receives **one craft
projection**, synchronously after craft/reagent facts and their runtime indexes
are updated. The craft is queryable during delivery. Automatic retention runs
only at ledger startup, not during submission, capture, or callbacks; facts that
age out during gameplay remain available until the next startup. Failed
capture, request submissions, reload, and pruning do not emit public events.
Callbacks also run while diagnostic tracing is off.

Subscriptions run in registration order, once per successful result commit.
Each gets its own projection. Errors are protected and swallowed independently:
they neither stop subsequent consumers nor break capture/retention. Consumers
should keep synchronous handlers short and must not yield.
`RegisterCallback` returns an idempotent `unsubscribe()` closure; subscriptions
are runtime-only and may be registered before ledger initialization. Duplicate
registrations are separate subscriptions. A delivery snapshots its subscribers:
registering/unsubscribing during a handler affects the next event, not the current
one. Unrecognized events/non-functions fail without subscribing.
