# Durable Ledger

This document describes the storage slice implemented for issue #4. The raw
capture tracer remains a separate diagnostic store and is not imported into the
ledger.

## SavedVariables and Versions

`ArtisanLogbookDB` is account-wide SavedVariables for durable facts.
`ArtisanLogbookTraceDB` remains the independent bounded debug trace database.
The TOC addon's version is recorded on each session; `schemaVersion` belongs to
the ledger and migrates independently. The debug export version in
`Capture/Trace.lua` is not an AL1 export contract. No final export contract or
`exportContractVersion` exists in this slice.

The current durable schema is version 1:

- `crafts` stores one row per observed Retail result callback, with a monotonic
  local `id`, timestamp, session/recipe/output dimension IDs, raw game
  `operationID`, observed output quality/item level/quantity,
  Multicraft bonus, concentration spent/currency, Ingenuity proc flag, and
  refund field. Unsupported values are absent.
- `reagents` stores one row per returned item entry observed in
  `resourcesReturned`, linked to its craft and item dimension. Returned quantity
  is retained as observed; allocated quantity, reagent quality, and source are
  absent unless later capture evidence supports them.
- `dimensions` contains append-only numeric collections for realm, character,
  profession, recipe, item, session, and expansion. Each collection has an
  independent monotonic ID counter. Repeated stable keys reuse their existing
  dimension; rows are never updated or removed by pruning.
- `nextCraftId` is independent of retained rows, so pruning never makes a craft
  ID available again. Retention settings are stored as `retentionDays` and
  `maxCrafts`.

Session dimensions capture session start, addon version, WoW version/build/date,
interface, project, locale, character and realm references, and the flavor
capability snapshot. Character identity uses the character GUID when available,
otherwise character name plus realm. Profession/skill-line and recipe metadata
not present in the observed callbacks stays absent. Expansion rows use a stable
caller-supplied key, display name, and chronological order. Recipe/item/
profession dimensions may refer to an expansion only when that metadata is
known; a craft obtains expansion through its recipe, and a reagent through its
item. The consuming craft's expansion is never used to classify an item.

## Capture and Correlation

The Retail result event `TRADE_SKILL_ITEM_CRAFTED_RESULT` is the completion
boundary: every observed callback creates its own immutable craft fact. This
matches the sanitized build-69933 traces, where one count-2 request yielded two
result callbacks and two distinct, non-zero operation IDs.

`operationID` is stored exactly when present, including an observed zero, but is
not used to deduplicate or merge rows. Its uniqueness scope is not proven. A
repeated ID therefore remains a separate fact with a separate local ID and is
not attached to a pending recipe. This avoids losing a real craft if the game
reuses an ID; until duplicate/late
callbacks are traced, an actual repeated callback can likewise remain as an
extra fact. The callback is not rewritten based on `itemGUID`, spellcast events,
or `CRAFTING_DETAILS_UPDATE`.

`TRADE_SKILL_CRAFT_BEGIN` supplies a recipe candidate. Recipe attribution is
made only when exactly one begin is pending and the result has a positive
`operationID` not already present in the retained facts for that session.
Missing/zero/repeated operation IDs still produce craft facts, but no recipe
reference. Character and realm are reached through the session dimension, not
duplicated on each craft. If another begin arrives before a result, attribution
is ambiguous and omitted for the next result rather than overwriting or
guessing. There is no time-window grouping, request-count expansion, or
spellcast-based completion inference.

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
result may create several reagent rows. The replay traces do not establish
allocated inputs, quality, or ownership/source, so those fields are not
fabricated. Reagent item expansion comes only from its own item dimension, not
from the recipe consuming it. No separate Resourcefulness fact or derived
aggregate is persisted.

The current Retail hooks do not establish pre-craft skill/difficulty/expected
quality, profession/skill-line, output item level, crafting context, order,
recraft, reagent allocation, or source. Those fields remain absent. Other
flavors receive an empty capability map and do not acquire Retail-only values.

## Retention and Migration

Defaults are `retentionDays = 180` and `maxCrafts = 50000`. Pruning runs when the
ledger loads and after each result. It first removes facts older than the age
cutoff, then removes the oldest timestamp/ID rows if the count limit is still
exceeded. Reagent facts for removed crafts are removed together. Dimensions and
ID counters are retained; there are no rollups or dimension garbage collection.

Schema version 0 migrates to version 1 on a cloned table, preserving recognized
facts and counters while filling the version-1 collections/counters. A missing
database initializes a new version-1 store. A missing/invalid schema version,
failed migration, malformed collections, or newer schema is refused. Bootstrap
only replaces `ArtisanLogbookDB` after successful validation/migration, so
unsupported or failed data is left untouched for recovery. There is no
conversion from the unrelated debug trace database.

## Regression Coverage and Limits

`tests/ledger_test.lua` replays the sanitized Retail build-69933 fixture and
covers basic results, concentration without Ingenuity, Multicraft,
multi-reagent Resourcefulness, separate batch results/operation IDs, unknown
versus zero/false, reload IDs, age/count pruning, append-only dimensions,
ambiguous/repeated results, unsupported flavor capabilities, and migration
success/refusal safety. The mocked TOC test also verifies SavedVariables
initialization and that clearing debug traces does not clear ledger facts.

Remaining evidence gaps include operation-ID reuse scope, true duplicate/late
callback behavior, successful Ingenuity/refund semantics, cancellation,
crafting-order/recraft context, pre-craft measurements, and unambiguous reagent
allocation/source. This PR does not add the public Lua API, AL1 export, Recent/
Stats/Data product UI, CraftSim/TSM integration, Forever support, costing,
inventory/sales accounting, or release publishing; those remain later work.