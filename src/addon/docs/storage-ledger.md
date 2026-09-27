# Durable Ledger and Public Lua API

This document describes the storage slice from issue #4 and personal-craft
requests from issue #12. The raw
capture tracer remains a separate diagnostic store and is not imported into the
ledger.

## Stable Public Lua API (v1)

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
This is **not a persistent snapshot**: pruning may remove pending rows or the
anchor, and metadata enrichment may change matches/details. A pruned anchor
does not invalidate the boundary. Cursors have no server-side cache or expiry,
survive reload against the same ledger, and must not be shared across ledgers
or edited (they are not authorization tokens).

Malformed cursors, impossible ID bounds, or mismatched filters/directions return
`"invalid-cursor"`. Unknown options, invalid limits/directions, and non-table
options return `"invalid-options"`; offset paging and arbitrary sort fields are
not supported. Filters are applied before ordering/page selection. Only selected
crafts' relationships are projected. Queries scan retained facts and sort matching
references; they do not persist another ledger or require consumers to offset-scan
history. Facet queries likewise scan retained facts, not orphaned dimensions.

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
projection**, synchronously after craft and reagent facts are inserted and before
the automatic retention pass. The craft is queryable during delivery; retention
may remove it afterward (for example after a backward clock change). Failed
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

## SavedVariables and Versions

`ArtisanLogbookDB` is account-wide SavedVariables for durable facts.
`ArtisanLogbookTraceDB` remains the independent bounded debug trace database.
The TOC addon's version is recorded on each session; `schemaVersion` belongs to
the ledger and migrates independently. The debug export version in
`Capture/Trace.lua` is not an AL1 export contract. No final export contract or
`exportContractVersion` exists in this slice.

The current durable schema is version 2:

- `crafts` stores one row per observed Retail result callback, with a monotonic
  local `id`, timestamp, optional request ID, session/recipe/output dimension IDs, raw game
  `gameOperationId` (the raw `operationID`), observed output quality/item level/quantity,
  Multicraft bonus, concentration spent/currency, Ingenuity proc flag, and
  refund field. Unsupported values are absent.
- `requests` stores submitted personal `CraftRecipe` snapshots with separate
  monotonic IDs, timestamps, session/recipe references, `requestedCount`, and
  `useConcentration`. Optional quote fields are `concentrationCost`, `baseSkill`,
  `baseDifficulty`, and `craftingQuality`. Optional `allocations` contain
  positive-quantity quote selections: `dataSlotIndex`, item reference,
  `allocatedQuantity`, and observed `quality` when available. An absent
  allocations list means no supported quote selection was captured.
- `reagents` stores craft/item-linked allocations for correlated results and
  return-only rows for legacy or unmatched results. `allocatedQuantity` is
  absent on return-only rows. `returnedQuantity` is absent without a return
  list or when return attribution is ambiguous; it is zero only when a return
  list establishes that this allocated item was not returned. Ownership/source
  and commodity lot provenance are never inferred.
- `dimensions` contains append-only numeric collections for realm, character,
  profession, recipe, item, session, and expansion. Each collection has an
  independent monotonic ID counter. Repeated stable keys reuse their existing
  dimension. Identity and IDs never change; pruning never removes dimensions.
  Metadata supports monotonic enrichment as described below.
- `nextCraftId` and `nextRequestId` are independent of retained rows, so pruning
  never reuses either ID. Retention settings are `retentionDays` and `maxCrafts`.

Session dimensions capture session start, addon version, WoW version/build/date,
interface, project, locale, character and realm references, and the flavor
capability snapshot. Character and realm identities use the runtime context
described below. Profession/skill-line and recipe metadata
not present in the observed callbacks stays absent. Expansion rows use a stable
caller-supplied key, display name, and chronological order. Recipe/item/
profession dimensions may refer to an expansion only when that metadata is
known; a craft obtains expansion through its recipe, and a reagent through its
item. The consuming craft's expansion is never used to classify an item.
The canonical reference field for recipe, item, and profession is
`expansionDimensionId`; on an item it describes that item's own introduction or
ownership expansion, not consumption context. No alternate expansion-reference
spelling or guessed expansion mapping is accepted.

## Dimension Identity and Enrichment

Dimension IDs and keys are immutable. `AddDimension` is an internal storage
method, not a public Lua API. For the same key, a nil attribute may become known;
repeating a known value is a no-op. Conflicting known values return `nil, reason`
and reject the entire update, including other new attributes. Nested metadata
follows the same rule. Callers cannot change `id` or `key`, and valid expansion
references may be added after sparse item/recipe/profession creation. Input
tables are copied, so subsequent caller mutations cannot change stored metadata.

Runtime realm keys use `project:<WOW_PROJECT_ID>:region:<GetCurrentRegion()>:`
`realm:<GetRealmID()>` only when all three identifiers are available and positive.
The name is display metadata, never the identity. The two optional API calls are
guarded; failures, missing functions, or invalid identifiers do not invent a
region or realm. Without complete context, the key is `unresolved:session:<id>`
and `identityScope = "session"`. This deliberately sacrifices cross-load
deduplication rather than merge same-name realms. Character keys use this realm
scope plus GUID (or name when the GUID is absent). No GUID parsing, locale-to-
region mapping, connected-realm inference, or external catalog is used.

Earlier PR #10 name-only realm rows and their references remain unchanged when
loaded; new scoped identities are not merged with them. Region/environment
history cannot be reconstructed from a name. Cross-client
SavedVariables import, PTR/live identity unification, and character transfers
are not supported. Conflicting display-name changes require explicit future
handling; currently session initialization is refused with a diagnostic rather
than silently overwriting known metadata. These are reviewable conservative
identity choices, not claims of universal API uniqueness.

## Capture and Correlation

The Retail result event `TRADE_SKILL_ITEM_CRAFTED_RESULT` is the completion
boundary: every observed callback creates its own immutable craft fact. This
matches the sanitized build-69933 traces, where one count-2 request yielded two
result callbacks and two distinct, non-zero operation IDs.

`operationID` is stored exactly when present, including an observed zero, but is
not used to deduplicate or merge rows. Its uniqueness scope is not proven. A
repeated ID therefore remains a separate fact with a separate local ID and is
not attached to a pending begin-only recipe. This avoids losing a real craft if the game
reuses an ID; until duplicate/late callbacks are traced, an actual repeated callback can remain as an
extra fact. The callback is not rewritten based on `itemGUID`, spellcast events,
or `CRAFTING_DETAILS_UPDATE`.

For personal `CraftRecipe`, positive-allocation `GetCraftingOperationInfo` calls
provide selected reagent arguments. Quote candidates are keyed by recipe and
concentration choice: a newer positive selection replaces its matching entry,
but empty, all-zero, malformed, or unrelated quotes cannot erase it. Only the
matching entry is consumed at the craft post-hook, and unsubmitted entries are
discarded when the trade skill closes. Without a positive matching quote,
allocations remain absent; the hook's own reagent table can be empty and is not
used as a fallback. A guarded operation query supplies optional
quote measurements, and an optional item-quality lookup supplies observed
reagent quality. This passive path does not depend on `/al start`. Later UI
quotes cannot mutate an already submitted request. Missing/mismatched quote
arguments leave selections and quote values absent. Orders, recrafts, and
target-dependent operations do not create request rows.

The sole active submitted request can be referenced by up to `requestedCount`
successful result callbacks. A second submission before that count is reached
makes attribution ambiguous until trade skill close (or a new session) clears it.
Generic `UNIT_SPELLCAST_FAILED`, `FAILED_QUIET`, and `INTERRUPTED` are player-wide;
their current verified payload does not establish a safe request/recipe match,
so they do not clear correlation. `UPDATE_TRADESKILL_CAST_STOPPED(false)` was
observed before a later successful batch result and cannot safely clear it
either. Failure and stop callbacks never create CRAFT rows; a failure after
one success leaves a request with fewer crafts than requested. Correlation can
remain pending until close or the requested count is reached after a partial
failure; distinguishing a subsequent unrelated result requires stronger evidence.
Neither operation
ID nor a timing window is used to join results to requests. Repeated, zero, and
missing operation IDs still create separate result facts. Pending attribution
is not resumed across reloads. Late callbacks cannot always be distinguished
from current results; overlapping submissions are deliberately left unlinked.

Without a request link, `TRADE_SKILL_CRAFT_BEGIN` supplies a recipe candidate. Recipe attribution is
made only when exactly one begin is pending and the result has a positive
`operationID` not already present in the retained facts for that session.
Missing/zero/repeated operation IDs still produce craft facts, but no recipe
reference. Character and realm are reached through the session dimension, not
duplicated on each craft. If another begin arrives before a result, attribution
is ambiguous and omitted for the next result rather than overwriting or
guessing. There is no time-window grouping or
spellcast-based completion inference.

This is an intentional loss-of-attribution policy, not a WoW API requirement.
In the older count-2 concentration fixture without request evidence, both begins
precede the first result: both result facts survive, but neither receives a
recipe reference. A novel late
ID cannot universally be recognized as late. Repeat detection only covers
retained facts within a session; reload starts a new session and pruning forgets
evicted IDs. No universal duplicate/late protection is claimed. The runtime
operation-count index is rebuilt from validated facts and updated by pruning;
it is not a persisted aggregate.

This deliberately differs from the broader assumptions in issue #2: one result
callback is one fact based on PR #3 evidence; the implementation does not infer
one result to be a duplicate merely because an operation ID repeats, and it
does not assume a batch request's count equals its result count.

## Facts and Unknowns

The result payload supplies the output item, quantity, quality, Multicraft,
concentration, `hasIngenuityProc`, and `ingenuityRefund` where present. Observed
zero and `false` are stored; absent or unsupported values remain nil. The ledger
does not persist net concentration or an inferred proc. A positive refund with
`hasIngenuityProc = false` is preserved as a reported refund field, not treated
as an applied refund. A future derivation may apply it only when the flag is
explicitly true. Successful Ingenuity behavior remains unverified.

`resourcesReturned` is authoritative for returned item IDs and quantities. One
result may create several reagent rows. A return attaches to a selected input
only if exactly one allocation uses that item ID. With duplicate allocations
of the same item, the return stays in a separate return-only row and the input
rows have unknown return quantities. Net consumption can be derived only for
unambiguous rows with both quantities. Old schema 1 return-only rows stay
partial. Reagent item expansion comes only from its own item dimension, not
from the recipe consuming it. No separate Resourcefulness fact or derived
aggregate is persisted.

Quoted skill/difficulty/expected quality are only available on personal requests
when the operation query supplies them. No order/recraft allocation,
ownership/source, profession/skill-line, or target-GUID semantics have been
verified. The optional
`itemLevel` result field is copied only if observed; the real fixtures do not
verify its applicability. Other
flavors receive an empty capability map and do not acquire Retail-only values.

## Retention and Migration

Defaults are `retentionDays = 180` and `maxCrafts = 50000`. Pruning runs when the
ledger loads, after submissions, and after each result. It first removes facts older than the age
cutoff, then removes the oldest timestamp/ID rows if the count limit is still
exceeded. Reagent facts for removed crafts are removed together. Requests age
out with the same cutoff unless a retained craft still references them; when
count pruning removes their final linked craft, they are removed as well.
Zero-result requests remain until age expiry. Dimensions and
ID counters are retained; there are no rollups or dimension garbage collection.

The age boundary is exclusive: exactly 180 days old survives until it is older.
Count ties break on craft ID, independent of input array order. A single
compaction removes excess rows; dimensions and counters never reset, including
when all facts expire. No clear command or UI is added in this slice.

Schema 0 is explicitly migration-test scaffolding, not a released legacy addon
format. It has the same fact/dimension/reference/counter shape as schema 1 but
may omit retention settings. Its only migration fills nil retention settings
and advances the version. It never infers missing counters from retained facts,
creates missing collections, supplies measured zeroes, or repairs references.
Even an empty retained collection cannot prove the historical next ID.

The explicit schema 1 to 2 migration adds an empty `requests` collection and
`nextRequestId = 1` without changing old crafts, reagents, or dimensions.
Schema 1 data unexpectedly containing request fields is refused. Migration and
reference validation operate together on a copy; failed validation never
publishes or partially mutates SavedVariables.

All migrations run on a deep copy inside a protected load path. Missing/invalid
versions, newer versions, cyclic/non-serializable data, non-finite numbers,
sparse/non-array collections, duplicate IDs/keys, invalid counters, or broken
references refuse the database before pruning or index construction. Craft
timestamps and session references, and reagent craft/item references, are
required. Other unknown dimension references remain absent, but if present
must resolve to positive local IDs in the correct collection:

- Craft: `sessionDimensionId`, `recipeDimensionId`, `outputItemDimensionId`,
  `professionDimensionId`, `requestId` (same session).
- Request: `sessionDimensionId`, `recipeDimensionId`; allocation: `itemDimensionId`.
- Reagent: `craftId`, `itemDimensionId`.
- Character: `realmDimensionId`.
- Session: `characterDimensionId`, `realmDimensionId`.
- Recipe: `professionDimensionId`, `expansionDimensionId`.
- Item and profession: `expansionDimensionId`.

The same reference checks run before live dimension creation/enrichment.
Unsupported reference fields are refused rather than silently treated as absent.
Bootstrap replaces `ArtisanLogbookDB` only after successful migration,
validation, and session initialization. A failed load leaves the original
SavedVariables intact and tracing independent. A missing database creates schema
2; the unrelated trace database is never imported. Malformed result snapshots
are rejected before craft/reagent facts are committed; timestamps are never
fabricated as zero when the clock is unavailable.

## Regression Coverage and Limits

`tests/ledger_test.lua` replays the sanitized Retail build-69933 fixture and
covers basic results, concentration without Ingenuity, Multicraft,
multi-reagent Resourcefulness, separate batch results/operation IDs, unknown
versus zero/false, reload IDs, age/count pruning, append-only dimensions,
ambiguous/repeated results, unsupported flavor capabilities, and migration
success/refusal safety. Hardening tests cover every reference path for both
versions, sparse collections, missing counters, atomic enrichment/conflicts,
expansion enrichment, runtime realm collisions/fallback, and deterministic
pruning/index reconstruction. The mocked TOC test covers passive capture while
tracing is paused, reload identity, missing identity APIs, initialization refusal,
and debug-trace clear isolation. Sanitized personal build-69933 replay covers
two quality mixes, off/on concentration and quote/spend differences, mapped
multi-item returns, three-result batches, partial failure, ambiguous attribution,
migration, and pruning. Run `bash src/addon/scripts/package.sh` from
the repository root to test and validate `src/addon/dist/ArtisanLogbook.zip`.

Remaining evidence gaps include operation-ID reuse scope, true duplicate/late
callback behavior, successful Ingenuity/refund semantics, crafting-order/recraft
context, and reagent ownership/source. The public API exposes only the facts
already supported by the ledger. This slice does not add AL1 export, Recent/
Stats/Data product UI, CraftSim/TSM integration, Forever support, costing,
inventory/sales accounting, or release publishing; those remain later work.