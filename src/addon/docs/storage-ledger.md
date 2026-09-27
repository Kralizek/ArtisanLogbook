# Durable Ledger

This document describes the durable storage implemented by issue #4 and the
personal-craft request capture added by issue #12. The raw capture tracer remains
a separate diagnostic store and is not imported into the ledger.

The stable consumer-facing Lua API is documented separately in
[lua-api.md](lua-api.md).

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
context, and reagent ownership/source. The Lua API projects only facts already
supported by this ledger; see [lua-api.md](lua-api.md). This slice does not add
AL1 export, Recent/
Stats/Data product UI, CraftSim/TSM integration, Forever support, costing,
inventory/sales accounting, or release publishing; those remain later work.