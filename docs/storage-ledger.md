# Durable Ledger

This document describes the durable storage implemented by issue #4 and the
personal-craft request capture added by issue #12, durable outcomes from #17, and
the schema-2 authoritative outcome and reagent measurement model from #24. The raw
capture tracer remains a separate diagnostic store and is not imported into the ledger.

The stable consumer-facing Lua API is documented separately in
[lua-api.md](lua-api.md).

## SavedVariables and Versions

`ArtisanLogbookDB` is account-wide SavedVariables for durable facts.
`ArtisanLogbookTraceDB` remains the independent bounded debug trace database.
Both belong to `ArtisanLogbook_Core`; their Lua tables are private persistence,
not supported in-game consumer APIs. All addons, including the production UI,
must use `ArtisanLogbookAPI` for factual reads. Offline exporters may have
version-specific persistence readers without making these tables a public
in-game API. The Core TOC addon version is recorded on each session;
`schemaVersion` belongs to the ledger, and public API version 1 is independent
of both. The debug export version in
`Capture/Trace.lua` is not an AL1 export contract. No final export contract or
`exportContractVersion` exists in this slice.

**Schema 2 is the current persistence contract**, identified by both
`schemaVersion = 2` and `schemaIdentity = "ArtisanLogbookLedger"`. **Schema 1**
(`schemaVersion = 1` with the same identity, in every `outcomeVersion` variant
described below) is the only supported upgrade source and is migrated
automatically at startup; see [Schema 1 → 2 migration](#schema-1--2-migration).
No reset or purge is required. Schema 2 is never downgraded: an older Core build
refuses a schema-2 database with its usual unsupported-schema diagnostic.
Use authoritative WoW natural IDs directly for WoW entities where a stable
domain ID exists. Changes to earlier unreleased development layouts did not
increment `Ledger.schemaVersion` and do not provide a migration path. Such layouts
must be reset, not converted.
The identity marker distinguishes supported data from experimental builds that
also used small version numbers. Development/prerelease schemas 0–5 without the
marker were experimental and are **not supported upgrade sources**. There is no
migration or historical backfill path from them. Changing the version number or
adding the marker manually is not a supported conversion.

Users of development builds may need to reset SavedVariables. With WoW fully
closed, back up the account's `ArtisanLogbook_Core.lua` SavedVariables file before
resetting/removing `ArtisanLogbookDB` (and any backup WoW might restore).
The addon refuses unsupported data with a clear reset-required error rather
than deleting or rewriting it automatically. Resetting the ledger loses its
experimental history; the independent diagnostic trace is not imported.

The supported schema contains:

- `crafts` stores one row per observed Retail primary result callback, with a monotonic
  local `id`, timestamp, optional request ID, session ID and WoW recipe/output
  item IDs, raw game
  `gameOperationId` (the raw `operationID`), observed output quality/item level/quantity,
  Multicraft bonus, concentration spent/currency, Ingenuity proc flag, and
  refund field. Schema 2 adds the compact provenance enum `outcomeSource`
  (`native`, `partial`, `unverified`; absent for schema-1 captures),
  `quoteObserved = true` for crafts whose request carried quote allocations, and
  `inputComplete = true` for crafts whose complete recipe inputs are known (see
  [Recipe inputs](#recipe-inputs-quote-allocations-vs-complete-inputs)).
  Unsupported values are absent. First-craft rewards are not craft rows.
- `requests` stores submitted personal `CraftRecipe` snapshots with separate
  monotonic IDs, timestamps, session/recipe references, `requestedCount`, and
  `useConcentration`. Optional quote fields are `concentrationCost`, `baseSkill`,
  `baseDifficulty`, and `craftingQuality`. Optional `allocations` contain
  positive-quantity quote selections: `dataSlotIndex`, item reference,
  `allocatedQuantity`, and observed `quality` when available. An absent
  allocations list means no supported quote selection was captured. Schema 2
  adds optional `fixedReagents` (`dataSlotIndex`, item reference,
  `requiredQuantity`) read from the recipe schematic at submission, and
  `inputComplete = true` when that schematic accounted for every input slot.
- `reagents` stores craft/item-linked allocations for correlated results and
  return-only rows. `allocatedQuantity` is absent on return-only rows. Schema-2
  rows copied from `fixedReagents` carry `fixed = true` and the schematic's
  required quantity as `allocatedQuantity`. When the
  complete return set is known, a single-slot allocation carries its item's
  returned quantity (zero when nothing returned). Duplicate slots of one item
  carry zero when that item was not returned; otherwise they stay unknown and
  a return-only row holds the item's total. Without a complete set, slots stay
  unknown and provable positives are return-only rows. Ownership/source and
  commodity lot provenance are never inferred.
- `dimensions.recipes`, `dimensions.items`, and `dimensions.professions` are
  append-only numeric-keyed maps indexed by WoW recipe ID, item ID, and skill
  line ID respectively. Their row `id` equals the map key. They have no
  Artisan Logbook surrogate IDs, string identity keys, or local counters.
  `dimensions.realms`, `.characters`, `.sessions`, and `.expansions` remain
  append-only arrays with independent Core-owned monotonic ID counters and
  stable keys. Pruning never removes metadata; known fields can be enriched.
- `nextCraftId` and `nextRequestId` are independent of retained rows, so pruning
  never reuses either ID. The retention setting is `retentionDays`; there is no
  craft-count ceiling.
- `craftSeries` contains durable daily rows at UTC day × character × recipe
  grain. Unlike detailed crafts/requests/reagents, these rows do not age out.
- `resourcefulnessSets` contains UTC day × character × recipe × canonical
  returned-item-set rows with `craftCount` and optional `authoritativeCraftCount`.
  Only positive, completely identified return sets participate. Empty/no-return
  outcomes are covered in `craftSeries`.
- `reagentSeries` (replacing schema-1 `returnedReagents`) contains UTC day ×
  character × recipe × item measurement rows. Different materials are never
  added together.
- `firstCraftRewards` contains UTC day × character × parent recipe × item rows
  with `rewardCount`, `quantity` and `quantityObservedCount`.

## Durable Outcome and Reagent Statistics (#17, #24)

The four aggregate collections above are the complete durable outcome model. There
is no compressed dictionary, craft-membership index, per-craft durable outcome
archive, classification flag, or external data/runtime service. The tables
use the same character and recipe identities as daily craft totals, including
the unattributed grain. Trivial-item preferences belong exclusively to the UI
SavedVariables and never enter these facts.

Daily rows add `multicraftProcCount`, `resourcefulnessProcCount`,
`resourcefulnessCompleteProcCount`, `resourcefulnessAuthoritativeProcCount`, and their
respective `...ObservedCount` fields to the existing output, Multicraft bonus,
concentration spent, Ingenuity proc, and applied refund measures. Each sum is
absent at zero coverage, not a fabricated zero. A Multicraft proc is an observed
positive bonus; an observed nonpositive bonus is no proc. Ingenuity continues
to use its authoritative boolean: false implies an applied refund of zero,
true uses the observed refund, and unknown does not apply the reported field.
Schema 2 also adds always-present `quoteObservedCount`, `inputCompleteCount` and
`matchedCraftCount`.

### Result normalization (schema 2)

Each `TRADE_SKILL_ITEM_CRAFTED_RESULT` payload is normalized exactly once, before
anything is staged:

1. `firstCraftReward = true` marks a **child reward** (Blizzard's crafting output
   log nests these under the parent with the same `operationID`). It never
   creates a craft, consumes a request position or touches recipe correlation.
   It increments `firstCraftRewards` under the parent craft's recipe when a
   committed craft in this session has that positive operation ID (a 64-entry
   runtime memory); otherwise it is stored unattributed.
2. A **validated primary result** needs affirmative supported call context
  (`CraftRecipe`, `CraftEnchant`, `RecraftRecipe`, or `RecraftRecipeForOrder`),
  no ambiguous request/begin context, a nonnegative integer `operationID`, a
  positive item ID, and a positive integer output quantity. Operation ID zero
  cannot establish identity. Every observed positive operation ID is remembered
  for the active runtime session, independently of detail retention; another
  callback for that ID cannot acquire a newer request or authoritative outcome.
  A bonus or malformed observation may be completed by a valid primary only
  within the same still-pending request; it never reserves that request's position.
  `bonusCraft = true`
  is conservatively excluded until its attempt semantics are verified.
  Salvage, unavailable/failed hooks, failed submissions, cleared context, and
  malformed top-level payloads stay `outcomeSource = "unverified"`. A malformed
  or bonus callback preserves the pending request and begin and receives no
  input facts. Its useful positive returns remain independent evidence. A valid
  primary with malformed `resourcesReturned` still owns its known inputs and
  consumes exactly one position; only its return measurement is partial.
  Close/cancel of unfinished work, replacement of an unfinished request,
  invalidation of a live request, a contradictory begin, or transition away from
  any outstanding nonpersonal call leaves operation ownership uncertain. Enchant,
  recraft, order and salvage contexts are tracked independently of personal
  `pendingRequest`; its absence does not establish completion. A result alone
  does not retire a nonpersonal context because no drain/attempt-count contract
  has been established. Close, direct personal replacement and another
  nonpersonal hook therefore apply the same conservative rule. Known stale IDs do not consume
  a new batch. An unseen ID in that uncertain state stays unowned/unverified and
  conservatively invalidates the pending batch. Another hook cannot clear this
  uncertainty: it lasts until a new runtime session. This deliberately sacrifices
  fresh authoritative/input coverage after such a transition; shape alone cannot
  identify the actual new craft. Clearing history does not reset this guard.
  Salvage may
  emit several callbacks for one operation. These remain craft facts, not
  authoritative attempt counts. Ordering across replaced operations still
  requires in-game validation; a matching last call is not a server identity token.
  The runtime ID registry is not persisted or capped and is reset when a new
  runtime session is created. It does not alter schema-1 migration or previously
  committed aggregates. Live evidence is needed before implementing any less
  conservative recovery rule, or claiming continuity across a reload/login while
  callbacks are still in flight.
3. For a validated primary result, `resourcesReturned == nil` and `{}` are
   **complete negatives** (confirmed product assumption for #24). A dense list
   whose entries all have a positive integer item ID and a nonnegative integer
   quantity is complete; duplicate entries for one item are added together.
   Such outcomes are `outcomeSource = "native"`: `resourcefulnessComplete = true`
   and `hasResourcefulnessProc` is true exactly when some quantity is positive.
4. Any other primary payload (sparse/non-array tables, missing or fractional
   quantities, currency-only entries, non-table values) is `partial`: entries
   with a positive integer item ID and positive finite quantity remain positive
   evidence (`hasResourcefulnessProc = true`), and nothing else is claimed.
5. `unverified` callbacks record positive evidence only; even `nil` or `{}`
   cannot prove the attempt returned nothing.

Inputs never change the outcome classification above: a known positive or
negative outcome stays known whatever the input evidence says.

### Recipe inputs: quote allocations vs complete inputs

A quote allocation list and a complete recipe input snapshot are different
things. Capture now copies the actual `CraftRecipe` submission table, never an
earlier UI quote. There is no production quote-allocation cache to retain stale
optional selections or mix levels/concentration states. Operation quotes are
queried using those submitted selections and remain separate measurements.
Blizzard's `GetCraftingReagentInfos()` supplies all modified slots in manual mode,
but only optional/finishing choices in automatic mode. Omitted automatic basic
quality choices therefore remain unknown, including in later batch attempts.
Fixed basic reagents (slot data type `Reagent`, for example Luminant Flux) are
absent from either table. The private snapshot audit found 16 of 211 quoted
crafts returning such an item; historical quotes remain partial evidence.

Core records two separate coverage facts:

- `quoteObserved`: this compatibility field counts correlated requests carrying
  positive allocations (submitted selections for new captures, quote snapshots
  historically). It guarantees nothing about other slots or quote identity.
- `inputComplete`: every consumed item and its quantity is known. At submission
  the Retail adapter reads `C_TradeSkillUI.GetRecipeSchematic(recipeID, false,
  recipeLevel)` and lists a slot as fixed only when it is a required, visible
  `Reagent` slot of `CraftingReagentType.Basic` with exactly one item, a positive
  `quantityRequired` and no `variableQuantities`. Every supported modified slot
  must reconcile submitted item membership and total quantity against its
  requirement. A missing required slot or an underfilled/overfilled selection
  is partial. An optional slot may be absent only when a readable dense submitted
  table establishes zero selection; a selected optional slot must be fully filled.
  Sparse lists, duplicate slot identities, unknown selections, hidden/automatic
  types, variable quantities, or unreadable slots cannot certify completeness.
  `Currency` slots consume no item. A craft inherits the request's completeness
  only if every positively returned item is among the submitted or fixed rows;
  an outside return disproves completeness but never the outcome.

The schematic's fixed quantities follow the same rule Blizzard's UI uses
(`ProfessionsUtil.GetQuantityRequired`). They have not yet been verified in
game against actual bag consumption for every recipe type; when Blizzard does not
provide a readable schematic, inputs stay partial rather than being
reconstructed. No input is guessed for enchants, salvage, recrafts or orders.

### Cohorts and measurement grains

The daily metrics describe three Resourcefulness populations:

- **authoritative** (`resourcefulnessAuthoritativeProcCount`): only `native`
  outcomes. Every validated primary attempt enters it, positive or negative, so
  it is the unbiased denominator for proc rates.
- **complete** (`resourcefulnessCompleteProcCount`): authoritative outcomes plus
  schema-1 complete lists. Schema-1 capture recorded complete lists mainly for
  positives, so this population can overstate procs.
- **raw** (`resourcefulnessProcCount`): any known outcome including legacy
  positive-only evidence. It is evidence, not a rate.

Validation enforces authoritative ⊆ complete ⊆ raw for both observations and
negatives, `quoteObservedCount` and `inputCompleteCount <= craftCount`, and
`matchedCraftCount <= min(inputCompleteCount, authoritative observed)`.
`resourcefulnessSets` rows sum to the complete proc count, and their
`authoritativeCraftCount` values sum to the authoritative proc count.

`reagentSeries` rows (UTC day × character × recipe × item) hold optional measures.
Each craft's reagent facts are first consolidated **per item**; duplicate slots are
added together and the return is never assigned to a slot:

| Measure | Meaning |
| --- | --- |
| `returnedQuantity` | Positive returns of the item from any cohort (legacy sums may be fractional). |
| `allocatedQuantity`, `allocationCount` | Gross observed allocation subtotals (submitted selections plus schematic fixed rows; historical quotes) and the number of crafts with such evidence. |
| `matchedCraftCount`, `matchedAllocatedQuantity`, `matchedReturnedQuantity`, `matchedReturnCount` | The same item restricted to crafts with an authoritative (`native`) outcome **and** proof of its complete required total across all applicable slots, including zero returns. |

An unresolved slot blocks every item it could contribute, including submitted
out-of-slot items. Unknown slot identity blocks all item totals. Other, disjoint
fully reconciled items remain eligible: an unrelated Flux return does not remove
proven ore totals. A subtotal of 5 for an item also present in an unsupported
slot cannot be paired with that item's full return. New retained allocation facts
store explicit `inputTotalComplete` booleans; repair uses these same contributions.
Older schema-2 facts without the flag keep their original durable contributions
during repair, rather than rewriting previously stored history. Schema-1 migration
still creates no authoritative or matched measurements. The saved-material share is
`matchedReturnedQuantity / matchedAllocatedQuantity` for one population; gross
returns are never divided by gross allocations. The daily `matchedCraftCount` is
stricter: crafts with complete recipe inputs and an authoritative outcome.
Missing inputs are measured at craft level: `craftCount - inputCompleteCount` on
the daily grain counts crafts without a complete recipe input snapshot (quoted or
not), so a craft with no reagent rows, or one whose details were pruned, never
disappears from the denominator. Rows are absent when no measure exists; matched fields appear
together. Validation checks references, grain uniqueness, a parent daily grain,
integer measures, `allocationCount <= craftCount`, matched <= gross, and that
positive matched return counts agree with positive matched quantities.

Canonical set identity is the comma-separated, numerically sorted sequence of
distinct positive-return WoW item IDs (for example `3,20`, never `20,3` or
`3,20,20`). Quantities and allocation slots do not affect identity. A craft
returning several reagents increments exactly one set's craft count. Repeated
entries for an item are combined for quantity aggregation, including ambiguous
multi-slot allocations, without counting allocated quantities as returns.

Capture stages dimensions, daily measures, set counts, and item measurements before
committing any of them or consuming pending correlation. Checked count/quantity
overflow rejects the complete update. Runtime indexes point to aggregate rows;
the new aggregate-update path visits only current entries, allocations and touched
grains, not historical rows. This is not a bound on the entire capture path:
output learning still copies the full `recipeOutputs` map even for an already-known
relationship. The output-bearing 50,000-craft benchmark covers five recipe-output
relationships, not scaling with a large output map. No output-learning optimization
is included here. Unknown-recipe repair transfers every aggregate contribution
(daily metrics and counts, sets, reagent measurements) in the same staged
transaction, removes emptied source rows once, validates, and rebuilds indexes
before replacing live state. Pruning removes details only. Clear/purge removes all
aggregate collections but does not clear UI settings.

### Schema-1 outcome variants

Schema 1 itself had three internal variants, all accepted as migration sources.
The optional `outcomeVersion = 2` marker recorded completion of PR #21's additive
initialization, not a feature-start date. Before migrating, Core applies the
same once-only correction schema 1 performed:

- Existing durable output, bonus, concentration, and Ingenuity facts/coverage
  are preserved verbatim, including already-pruned history.
- Retained Multicraft measurements reconstruct proc counts and coverage. A daily
  grain with exactly one observation and no retained measurement also proves its
  outcome directly. No residual is inferred by subtracting retained values:
  floating-point sums can lose a positive contribution (for example `1 + 1e16`).
  Multiple observations cannot generally reveal proc frequency from
  their sum. In particular, the existing schema accepts signed measurements,
  so a zero sum alone does not prove every individual bonus was zero. Quantity
  sums and their original coverage remain available even when proc frequency
  cannot be reconstructed.
- Retained finite positive reagent facts, including fractional quantities,
  recover raw Resourcefulness positives and material quantities, not complete
  sets. Legacy capture could discard an unavailable return measurement while
  leaving allocation zeros, so neither mixed zero/nil facts nor even all-zero
  persisted rows prove craft-level false or set completeness. Those observations
  remain unknown. Raw positives remain useful without inventing exact historical
  non-trivial rates.
- Already-pruned Resourcefulness facts cannot be reconstructed from the old
  daily totals. There is no timestamp cutoff, synthetic false, or reimport from
  the diagnostic trace. Reopening the upgraded database never counts facts twice.

Databases written by the earlier PR #21 `outcomeVersion = 1` are corrected once:
unproven false/set coverage is discarded; durable positive counts and material
quantities survive, with omitted retained fractional quantities added only once.
Multicraft proc coverage is reconstructed from retained measurements and singleton
daily grains, since that revision did not distinguish captured counts from unsafe
residual inference. Pruned proc/set coverage whose provenance cannot be proved
becomes unknown; original daily output/bonus/Ingenuity measures remain unchanged.

### Schema 1 → 2 migration

Startup (`Ledger.New`) migrates a schema-1 database inside the same protected
load used for every database:

1. Deep-copy the supplied SavedVariables (cycles, non-finite numbers and unsupported
   values refuse the load). All later steps work on the private copy.
2. Refuse mixed data that already contains schema-2 collections or provenance.
3. Apply the schema-1 outcome correction above, then run the full schema-1
   validation (references, counters, coverage, set agreement).
4. Convert: `returnedReagents` rows become `reagentSeries` rows with the same
   grain and `returnedQuantity`; `firstCraftRewards` starts empty; daily rows gain
   `resourcefulnessAuthoritativeProcCountObservedCount = 0`,
   `quoteObservedCount = 0`, `inputCompleteCount = 0` and `matchedCraftCount = 0`;
   `outcomeVersion` is removed.
5. Backfill inputs from **retained** details, still before any retention pruning:
   each retained craft's allocations are consolidated per item and added to
   `allocatedQuantity`/`allocationCount` on its existing daily grain. A craft whose
   request carried allocations gets `quoteObserved = true` and increments
   `quoteObservedCount`, whether or not it returned an item outside the quote.
   Schema 1 never stored a schematic, so no migrated craft gets `inputComplete` and
   fixed reagents of migrated crafts stay unknown. Retained returns are not added
   again: they already live in the converted rows. Fresh capture applies the same
   rules, so a schema-1 craft and a quote-only schema-2 craft are measured alike.
6. Run the full schema-2 validation, apply startup pruning, build indexes, create
   the session, and only then let Bootstrap replace `ArtisanLogbookDB`.

Any failure returns `ledger data refused: schema 1 migration failed (saved data
unchanged): <reason>` (or the underlying validation reason). Core stays disabled,
`ArtisanLogbookDB` remains the original table and is saved back unchanged, and the
tracer is unaffected. A user can report the diagnostic and keep the backup; the
confirmed debug purge remains an explicit, separate choice. The migration is
idempotent: the result is schema 2, so later loads never replay retained details
into aggregates; reloading an unsaved schema-1 file repeats the same deterministic
migration. `ArtisanLogbookManagement.Status()` reports `migratedFromSchemaVersion`
and `migratedQuoteCrafts` for the session that performed the upgrade.

**What is recovered:** every craft/request/reagent fact and immutable ID,
dimensions and counters, sessions, `recipeOutputs`, all daily measures and
coverage (including history already pruned), complete return sets, returned
quantities, positive-only Resourcefulness evidence, and gross quote allocations
and quote coverage for crafts that were still retained.

**What cannot be recovered:** the authoritative cohort is empty for all schema-1
history. Schema-1 capture stored nothing that distinguishes a `nil`
`resourcesReturned` from a malformed or unavailable list, so old unknown outcomes
are never reinterpreted as negatives, and schema-1 complete lists (selectively
recorded) never join the authoritative denominator. Matched measurements are
therefore schema-2 only, as is complete recipe input coverage. Fixed basic
reagent quantities were never captured. Inputs for crafts pruned before the upgrade, and
first-craft rewards that schema 1 recorded as crafts, cannot be recovered or
separated; those crafts remain counted as crafts with unknown inputs.

Cost is O(retained crafts + reagent facts + aggregate rows) with one extra
private copy, the same order as a normal load. The 50,000-craft stress test below
reports actual timings.

### Size and Cost

Growth follows occupied day/character/recipe, return-set, reagent-item and
first-craft-reward grains, not the number of crafts. Retained craft provenance
(`outcomeSource`, `quoteObserved`, `inputComplete`) expires with details; durable rows never
retain craft IDs. Login builds three simple aggregate indexes after
validation/pruning. Migration scans retained details once; subsequent loads do
not replay crafts into aggregates.

Measured in the development container with Lua 5.1 (timings vary, they are not
guarantees):

- The 239-craft synthetic sample (two allocation slots, 62 return sets) grows
  from **279,797** estimated Lua-text bytes as schema 1 to **290,725** bytes after
  migration (+10,928, about 3.9%) and **309,398** bytes when captured freshly as
  schema 2 (+29,601, about 10.6%, mostly retained `outcomeSource`/`quoteObserved`
  flags and matched measures). It has 62 set rows and 75 reagent rows.
  Migration took about **0.016 s**.
- 50,000 crafts across 50 days, 2 characters, 5 recipes and 3 allocation slots
  with a duplicate item: schema-2 capture **5.0–5.3 s** total (about 100 µs per
  craft; the schema-1 writer took 3.7–3.9 s), **500** reagent rows, three durable
  UI-facing queries (`GetReagentSummaries`, `GetRecipeReagentStatistics`,
  `GetRecipeOutcomes`) about **0.001 s** together without touching craft,
  reagent, request or aggregate arrays, schema-2 reload **2.4–2.9 s**, and
  migration of the equivalent schema-1 database **3.3–4.5 s**.
- A real schema-1 SavedVariables snapshot (688 retained crafts, 473 daily rows,
  about 3.8 MB of estimated Lua text; not part of the repository) migrates in
  about **0.15 s** and grows by about 137 KB (+3.6%). Daily measures, return sets
  and returned quantities are identical before and after, and a reload is
  idempotent. 211 crafts become `quoteObserved` and none `inputComplete`.

Session dimensions capture session start, addon version, WoW version/build/date,
interface, project, locale, character and realm references, and the flavor
capability snapshot. Character and realm identities use the runtime context
described below. Profession/skill-line and recipe metadata
not present in the observed callbacks stays absent. Expansion rows use a stable
caller-supplied key, name, and optional chronological order. Recipe/item/
profession dimensions may refer to an expansion only when that metadata is
known; a craft obtains expansion through its recipe, and a reagent through its
item. The consuming craft's expansion is never used to classify an item.
The canonical expansion reference field on recipe, item, and profession metadata is
`expansionDimensionId`; on an item it describes that item's own introduction or
ownership expansion, not consumption context. No alternate expansion-reference
spelling or guessed expansion mapping is accepted. The guarded recipe APIs do
not expose a global WoW expansion ID. Expansion rows therefore keep a Core-owned
ID and a caller-supplied key; their display names are not identity keys.

## Dimension Identity and Enrichment

Core-owned dimension IDs and keys are immutable; recipe/item/profession identity
is the WoW ID, with no second local ID. `AddDimension` is an internal storage
method, not a public Lua API. For the same identity, a nil attribute may become known;
repeating a known value is a no-op. Conflicting known values return `nil, reason`
and reject the entire update, including other new attributes. Nested metadata
follows the same rule. Callers cannot change `id` or a Core-owned `key`, and valid expansion
references may be added after sparse item/recipe/profession creation. Input
tables are copied, so subsequent caller mutations cannot change stored metadata.

On Retail, Core queries `C_TradeSkillUI.GetRecipeInfo(recipeID)` for a recipe's
name and optional `maxQuality` when `supportsQualities` is true, and
`C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)` for its skill line.
When supplied, `parentProfessionID` identifies the base profession used
for filtering (for example, Alchemy); otherwise `professionID` is used.
When `professionID` differs from its parent, Core asks
`GetProfessionInfoBySkillLineID(professionID)` for that exact child. Only a
matching child with no contradictory parent and a non-`Unknown`
`expansionName` can classify the recipe. Its expansion key is
`skillLine:<child ID>`: this is a
stable, profession-scoped expansion skill-line identity, not a global expansion
ID shared between professions. The API's expansion name is display metadata,
never a key. Missing, mismatched, or `Unknown` child information leaves the
recipe expansion unknown; Core does not parse recipe/category names, infer from
item IDs, or map expansion order. Trade-skill refresh retries previously
observed recipes in the currently opened trade skill, including those with
known names but missing quality scales or unknown expansions. Core intersects
`GetAllRecipeIDs()` with already tracked recipe identities at
`TRADE_SKILL_SHOW`; it does not query every historical recipe at login or
create dimensions for unobserved recipes from that list.

Item names come from `GetItemInfo(itemID)` for output, selected, and returned
reagent IDs after their facts or requests commit. Uncached items remain
identity-only until a matching successful `GET_ITEM_INFO_RECEIVED` event or
trade-skill refresh retries them; unrelated events are ignored. Unavailable or
failed metadata queries never reject a valid craft. Enrichment preserves
identities and rebuilds affected detailed
craft filter indexes; durable series and character profession choices resolve
the updated recipe association on read without rewriting history.

The confirmed `/al_trace` **Purge Logbook DB** operation creates a fresh Core
ledger with a new active session and the same runtime character/realm context.
It removes crafts, requests, reagents, aggregates, and all prior dimensions;
only the new session, character, and realm dimensions remain. Core-owned counters and
retention settings reset to clean-database defaults (including craft and
request IDs starting at 1). Diagnostic `ArtisanLogbookTraceDB` is unaffected.
Runtime operation IDs remain remembered. Only after successful purge, every old
observation's same-request completion exception is retired, including malformed
and bonus observations. Reusing numeric request ID 1 cannot make it the old
request. Terminal stale-ID rejection is preserved; the registry is not cleared.
Normal clear and pruning keep monotonic request IDs and do not retire a live
same-request completion exception. No operation state is added to SavedVariables.
If normal ledger initialization refused an invalid or unsupported development
database, the same confirmed purge builds a clean current schema-2 ledger and
current session before installing it. A failed recovery reports a diagnostic,
leaves Core unready and does not replace SavedVariables. Valid natural-ID
history does not need a purge for this metadata enrichment, and a schema-1
migration failure should be reported rather than purged by default.

`UnitClass("player")` supplies the optional authoritative `classFile` token on
the current character dimension at session creation. Existing dimensions with
the same identity accept this missing fact in place; historical characters
not observed on the current login remain unknown. The optional class and
recipe-quality fields were added to the schema-1 layout without a destructive
reset and are carried into schema 2 unchanged.

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
reagent quality. This passive path does not depend on `/al_trace start`. Later UI
quotes cannot mutate an already submitted request. Missing/mismatched quote
arguments leave selections and quote values absent. Orders, recrafts, and
target-dependent operations do not create request rows.

The sole active submitted request can be referenced by up to `requestedCount`
successful result callbacks. A new explicit personal `CraftRecipe` submission
in the same session supersedes an unfinished personal request, even when the
recipe is unchanged; the prior request and its already recorded crafts remain
untouched. The new request is used for subsequent results unless a craft begin
names a different recipe. Such a conflicting result remains unlinked and does
not consume the new request. Unsupported operations (orders, recrafts, enchants,
salvage) invalidate personal correlation rather than being treated as safe
sequential replacements; trade skill close or a new session clears that guard.
Generic `UNIT_SPELLCAST_FAILED`, `FAILED_QUIET`, and `INTERRUPTED` are player-wide;
their current verified payload does not establish a safe request/recipe match,
so they do not clear correlation. `UPDATE_TRADESKILL_CAST_STOPPED(false)` was
observed before a later successful batch result and cannot safely clear it
either. Failure and stop callbacks never create CRAFT rows; a failure after
one success leaves a request with fewer crafts than requested. Correlation can
remain pending until close or the requested count is reached after a partial
failure; a new explicit personal submission supersedes that unfinished request.
Neither operation
ID nor a timing window is used to join results to requests. Repeated, zero, and
missing operation IDs still create separate result facts. Pending attribution
is not resumed across reloads. Late callbacks without a distinguishing begin,
especially for same-recipe restarts, cannot always be distinguished from current
results; unsupported concurrent operation types remain unlinked until reset.

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

Schema 2 refines this with evidence from Blizzard's crafting output log, which
treats `firstCraftReward = true` results as children of the parent result with
the same `operationID`. Such callbacks are not facts or attempts (see
[Result normalization](#result-normalization-schema-2)); they never consume a
request position or the pending begin. Operation IDs are still not used to
deduplicate primary results. Salvage callbacks remain one fact per callback but
are `unverified`, so they cannot inflate any outcome denominator.

## Facts and Unknowns

The result payload supplies the output item, quantity, quality, Multicraft,
concentration, `hasIngenuityProc`, and `ingenuityRefund` where present. Observed
zero and `false` are stored; absent or unsupported values remain nil. The ledger
does not persist net concentration or an inferred proc. A positive refund with
`hasIngenuityProc = false` is preserved as a reported refund field, not treated
as an applied refund. A future derivation may apply it only when the flag is
explicitly true. The Ogrim export now verifies a successful proc with
`hasIngenuityProc=true`, `concentrationSpent=323`, and `ingenuityRefund=162`.

`resourcesReturned` is authoritative for returned item IDs and quantities on a
validated primary result, and its absence there means nothing was returned (see
[Result normalization](#result-normalization-schema-2)). One result may create
several reagent rows. Per-slot attribution is only stored when it is
unambiguous; durable statistics consolidate each craft by item, so duplicate
allocation slots (for example 5 + 7 of item A with 2 returned) are measured as
12 allocated, 2 returned and 10 net consumed without choosing a slot. Reagent item
expansion comes only from its own item dimension, not from the recipe consuming it.

Quoted skill/difficulty/expected quality are only available on personal requests
when the operation query supplies them. No order/recraft allocation,
ownership/source, profession/skill-line, or target-GUID semantics have been
verified. The optional
`itemLevel` result field is copied only if observed; the real fixtures do not
verify its applicability. Other
flavors receive an empty capability map and do not acquire Retail-only values.

## Retention and Supported-Schema Loading

The default is `retentionDays = 60`, with **no fixed craft-count threshold**.
The issue #5 indexing/retention decision supersedes the original 50,000-craft cap.
Pruning runs once when the ledger loads, after format/reference validation and
**before runtime indexes are built**. It removes craft facts older than the age
cutoff together with their reagent facts. Requests age out with the same cutoff
unless a retained craft still references them; zero-result requests remain until
age expiry. Dimensions, ID counters, and daily craft series are retained;
there is no dimension garbage collection or reagent-level historical rollup.

The age boundary is exclusive: exactly 60 days old survives until it is older.
No automatic pruning occurs on submissions or results. Facts that age out during
gameplay remain queryable until next startup, and backdated results are not
immediately deleted. The private explicit `Prune` maintenance method rebuilds
runtime indexes if invoked after initialization; it is not a public API or normal
capture path. Dimensions and counters never reset, even when all facts expire.
The original ledger slice exposed no clear command or UI.

The production UI uses the deliberately separate `ArtisanLogbookManagement`
cross-addon boundary for mutable Settings operations. It is not part of the
stable read-only factual `ArtisanLogbookAPI` and never exposes raw persistence.
`Status` returns detached retention,
record-count, schema and build diagnostics, plus two additive read-only booleans:
`operationOwnershipUncertain` reports runtime ownership quarantine;
`authoritativeCaptureSuspended` reports quarantine or ambiguous request/begin
context. False means no global suspension is active, not that any particular
callback has verified identity. Neither field changes state, clears quarantine
or provides an automatic recovery rule. Quarantined callbacks remain raw
unowned facts; they do not appear in a recipe's authoritative denominator.
`CurrentCharacter` exposes the
active ledger identity without exposing SavedVariables. Retention changes take
effect on the next startup or explicit prune, not on capture. `Prune` applies
the configured age cutoff to detailed facts and rebuilds indexes, leaving daily
series intact. Confirmed `Clear` deletes detailed crafts, requests, reagents and
all daily totals while preserving dimensions, session identity, retention and
monotonic ID counters. Capture can resume immediately afterward. This is distinct
from the tracer's independent debug clear operation.

The tracer also exposes **Repair unknown recipes** as a confirmed maintenance
operation. Analysis derives `outputItemId -> recipeId set` from committed craft
facts and authoritative Retail output metadata stored in `recipeOutputs`. A
retained craft with no recipe is repairable only when its output has exactly
one known recipe; ambiguous, missing-output, and unsupported outputs remain
unchanged. Names can discover candidates but never authorize repair; only
explicit Blizzard output IDs or attributed crafts supply evidence. Analysis
is repeated when the confirmation is accepted, without repeating discovery.

The `recipeOutputs` map stores only natural-ID relationships:
`recipeOutputs[recipeId][outputItemId] = true`. Older schema-1 databases without
the field migrate with an empty map; schema 2 always persists it. Core bootstraps it idempotently from retained
attributed crafts before startup repair, then persists it normally. New
attributed crafts add relationships; duplicate observations do not add rows.
The runtime reverse index is rebuilt from this map and is never persisted.
Relationships are monotonic and survive craft retention, so storage grows with
distinct recipe/output pairs rather than craft count. Multiple outputs for one
recipe are supported; ambiguity occurs only when one output maps to multiple
recipes.

After successful ledger loading and index reconstruction, Core performs this
same conservative analysis once, after recipe-output bootstrap, when retained
Unknown crafts exist and applies any uniquely supported repairs without
confirmation. It does not scan after each craft commit. The runtime-only
`unknownRecipeCount` is derived from
retained detailed craft facts, not SavedVariables or durable series, and is
reconstructed on load/reindex and maintained by commits. Pruning, repair, clear,
and purge therefore leave it consistent with retained detail. Startup repair is
best-effort: a failed staged operation records a diagnostic and leaves the
loaded ledger available. Manual confirmed repair remains useful when new
metadata becomes available later in a session.

After this normal startup repair, remaining outputs with **no** durable mapping
get one candidate-discovery pass. Core reads `unknownCraftIdsByOutput` and item
dimensions, builds a temporary map only for their exact stored names, and walks
recipe dimensions once. Each matching recipe is queried once through the same
output reader used by profession enrichment. No match or no authoritative
confirmation means no knowledge write. If a candidate confirms a wanted output,
its explicit output set is learned through `addon.LearnRecipeOutputs`.
All candidates finish before learning, and the entire batch reaches the reverse
index before any repair, so shared outputs cannot be assigned to the first
matching recipe. Known unique outputs need no candidate queries; known ambiguous
outputs are not reconsidered using names.

Automatic batch learning invokes the existing targeted repair once for all
newly unique affected outputs. Manual discovery uses the same learning path but
defers repair until the existing preview is confirmed. It may persist verified
knowledge before confirmation, but never repairs historical facts on that path.
An entirely unverified manual attempt does not change the database. The Debug
analysis includes Unknowns, candidates, confirmed candidates, unavailable
metadata, unconfirmed candidates, uniquely repairable and ambiguous crafts.
Automatic recovery produces no normal chat/UI notifications.

### Recovery cost and lifetime

Let U be distinct retained Unknown outputs, R recipe dimensions, C exact-name
candidate recipes and E their returned output relationships. Extra startup/manual
discovery costs O(U + R + C + E), with O(U + E) temporary memory, no scan of craft
history, and at most C schematic queries plus C quality-output queries. The R
walk is skipped entirely when no unresolved named outputs need discovery.
Names are referenced from existing dimensions, not normalized or duplicated in
a permanent index. Candidate tables/API results die at the end of the pass.

Profession opportunities reuse the current loaded list, not global candidate
discovery. For P loaded recipe IDs, list signature preparation is O(P log P),
with O(P) temporary storage and one O(P)-sized signature retained to suppress
duplicates. Only this signature and an open/list-settled boolean are kept between
events. Actual enrichment is bounded by that loaded profession's recipes and
outputs. Duplicate settled events compute the signature but perform no recipe
queries, item-dimension scans or repair. Close/reopen, a changed list or observed
data readiness transition creates another natural opportunity. There is no
failed-candidate queue, attempt counter, retry generation, scheduler or timer.

Learning retains the existing O(K) staged knowledge copy/reverse-index build for
K durable relationships, once per nonempty batch. Actual repair intentionally
retains the existing history-sized staging, validation and index reconstruction
for atomicity; it is not O(U). Batching avoids one such rebuild per output. Normal
load validation, indexing, retention and craft-knowledge bootstrap costs are
unchanged. Core does not await caches or another event: optional candidate reads
run synchronously once after ordinary startup repair and failures are nonfatal.

The addon test fixture with 2,010 recipe dimensions, 2,000 attributed crafts and
14 Unknowns makes exactly nine candidate schematic queries, zero profession
enumerations and zero recipe-info queries at login; three confirm, leaving 11
Unknowns. Mocked full startup (including load/indexing/repair) measured roughly
0.06-0.08 seconds in the development container. This is a practical Lua check,
not a bound on native API latency or a measurement of the user's live database.

Persistent storage remains only `recipeOutputs` plus any item
dimensions for newly confirmed outputs. Runtime diagnostics keep one small
summary and a session learned-relationship count, never evidence histories or
per-craft recovery state. Recovery itself needs no migration prompt or purge.
See [Retail/Forever API findings](capture-tracer.md#recipe-metadata-and-recovery)
for availability and security limits.

Repair stages one copy of the database per batch, changes only proposed craft
`recipeId` values, and transfers each retained craft's additive series
contribution (metrics, coverage, `quoteObservedCount`, `inputCompleteCount`,
`matchedCraftCount`),
its return-set count (including `authoritativeCraftCount`) and its consolidated
per-item reagent measurements from the nil-recipe grain to the known recipe
grain. Contributions are recomputed from the craft's retained facts and flags,
not by scanning history. Existing target rows merge normally; emptied source
rows are removed in one pass after all transfers. It deliberately does not rebuild durable series from retained
crafts: those rows can include older crafts already removed by retention, so
only repaired retained contributions move and pruned historical totals remain
in their original grain. Schema version and request relationships are unchanged.
The staged database is validated and all runtime indexes are rebuilt before the
live ledger is swapped, so handled planning, validation, and index-build failures
leave the original ledger intact.

### Runtime indexes

Runtime state references normalized storage rows, not projected/cached domain
objects. Startup performs the history-sized rebuild once after retention:

- `craftById`, `requestById`, and `reagentsByCraftId` provide direct lookups.
- `craftIds` is a sorted ascending array of retained craft IDs.
- `craftIdsByCharacter[key]`, `craftIdsByRealm[key]`, `craftIdsByRecipe[id]`,
  `craftIdsByProfession[id]`, and `craftIdsByExpansion[key]` contain sorted
  ascending craft-ID arrays only. They use the public domain identities and
  recipe-based expansion/profession attribution, not surrogate dimension IDs.
- `craftIdsByTime` contains IDs ordered by `(timestamp, craft ID)` for cursor
  boundary searches, including timestamp ties and backward clock changes.
- `seriesDays` indexes occupied UTC days for bounded chart queries; runtime
  recipe counts and an invalidatable alphabetical recipe-ID order serve bounded
  catalogue pages without traversing every historical aggregate on each page.
- Distinct character and recipe IDs from durable series are indexed globally
  and per character for tracked selector choices. These sets are rebuilt from
  persisted series on load/prune/clear and updated on commit. Profession
  identity is resolved through current recipe metadata when queried, so
  enrichment needs no historical reindex or stored projection.
- `unknownRecipeCount` counts only retained detailed crafts with no `recipeId`;
  it is derived during this rebuild and never persisted or inferred from durable
  series rows.
- The existing operation-count index supports evidence-backed recipe attribution.

New requests update their map; new crafts/reagents update all relevant maps and
ID arrays before callbacks run. Monotonic IDs append naturally to secondary
indexes. The chronological index appends for the normal nondecreasing clock path;
a backdated craft uses binary-position insertion (array shifting is exceptional).
Neither capture correlation nor callback projection scans historical requests or
reagents. There is no history-sized pruning/index rebuild on normal capture.
Actual dimension enrichment must refresh affected filter membership, while
reusing an unchanged dimension does not rebuild indexes. This exceptional
metadata maintenance work is separate from ordinary submissions/results.

Indexes never enter SavedVariables and never cache denormalized projections.
Large histories above 50,000 crafts remain supported within the time window;
initialization and explicit analytics may do history-sized work. Detailed query
selection and paging behavior is described in [lua-api.md](lua-api.md).

### Durable daily aggregates

`craftSeries` is a dense collection of rows keyed by `bucketStart`,
optional `characterDimensionId`, and optional WoW `recipeId`. `bucketStart`
is `floor(craft.timestamp / 86400) * 86400` (Unix UTC midnight). Character derives
through the craft session; unknown character/recipe references form unknown
groups rather than guessed identities. Dimension references remain resolvable
after detail pruning. Realm derives through character and profession/expansion
through recipe at query time, so enrichment requires no duplicate aggregate store.

Each row stores `craftCount` plus optional sums `outputQuantity`, `multicraftBonus`,
and `concentrationSpent`. Each sum has an always-present
`<metric>ObservedCount`: absent evidence contributes neither a value nor coverage;
observed zero contributes coverage and a zero sum. Zero coverage requires an absent
sum, positive coverage requires a sum, and coverage cannot exceed `craftCount`.
The series also stores `ingenuityProcCount` and `ingenuityRefund` with
`ingenuityProcCountObservedCount` and `ingenuityRefundObservedCount`. Known true/
false flags contribute one/zero to proc count; unknown flags contribute no
coverage. Applied refund is the observed raw amount only for true, zero for
false (including positive potential raw refunds), and unknown for an absent flag
or true without an amount. Raw craft refunds are unchanged. These fields follow
the same absent-sum/zero-coverage rule. Proc count is an integer between zero and
its coverage; refund coverage cannot exceed known-flag coverage and cannot be
less than the number of observed false flags (`proc coverage - proc count`).
If no true proc was observed, a present applied-refund sum must be zero.
Resourcefulness and reagent measurements live in the separate grains described in
[Durable Outcome and Reagent Statistics](#durable-outcome-and-reagent-statistics-17-24);
no derived net/profit measures are persisted.

A runtime keyed aggregate lookup is rebuilt from these rows once at startup.
Every successful commit updates exactly its aggregate grain before callback
delivery, using constant-time lookup and fixed metric work. It never scans
history or waits for pruning. Detail pruning never removes aggregate rows.
Queries read this store for all days, including recent days; they never combine
recent facts with old aggregates. The factual APIs remain detail-only.

All measures are recorded at commit from the start of the supported contract.
Loading never replays detailed facts into series, recomputes historical grain,
or reconciles unknown-character rows against enriched session metadata.
Reload preserves persisted daily rows and their coverage even after all details
expire. Metadata still resolves through append-only dimensions, while stored
series grain references remain unchanged.

Schema 2 validates aggregate collection shape, unique grain, UTC-day alignment,
references, counts, metric coverage, cohort containment, finite sums, and
Ingenuity consistency.
A persisted or configured `maxCrafts` is rejected, not converted.
The default detailed retention is 60 days; explicit positive settings are
preserved on reload. Public APIs expose no retention setter.

### Exact integers and exhaustion

Core-owned IDs, monotonic counters, and counts must fit Lua's exact safe-integer range,
up to **9,007,199,254,740,991 (2^53 − 1)**. Zero is allowed for observation counts
but not local IDs/next-ID counters. Allocation requires room to advance the
next-ID counter, so the maximum next-ID value is an exhausted sentinel, not
another allocatable ID. Counts can reach the maximum but cannot increment again.
Natural-ID metadata keys are finite nonnegative integers (including observed
zero item IDs) and are not limited by local counter capacity. Finite numeric
measurements retain their existing signed/fractional semantics.

Exhausted counters/counts reject the operation before committing dimensions,
facts, aggregates, or correlation changes. Multi-dimension requests/results and
session creation check capacity for all needed new Core-owned dimensions, not just the
first. Natural metadata never consumes a local ID. Pruning never resets
counters; loading never reconstructs them from retained rows.

Loading runs on a deep copy inside a protected path. Missing/invalid format
identity or versions, unsupported versions, cyclic/non-serializable data, non-finite numbers,
sparse/non-array Core-owned collections, malformed natural-ID maps, duplicate
IDs/keys, invalid counters, or broken references refuse the database before
pruning or index construction. Craft
timestamps and session references, and reagent craft/item references, are
required. Other unknown references remain absent, but if present must resolve
to an existing row in the correct collection (WoW IDs for natural metadata,
Core-owned IDs for other dimensions and facts):

- Craft: `sessionId`, `recipeId`, `outputItemId`, `professionId`, `requestId`
  (same session).
- Request: `sessionId`, `recipeId`; allocation: `itemId`.
- Reagent: `craftId`, `itemId`.
- Character: `realmDimensionId`.
- Session: `characterDimensionId`, `realmDimensionId`.
- Recipe: `professionId`, `expansionDimensionId`.
- Item and profession: `expansionDimensionId`.
- Daily series and return sets: `characterDimensionId`, `recipeId`.
- Reagent series and first-craft rewards: `characterDimensionId`, `recipeId`, `itemId`.

The same reference checks run before live dimension creation/enrichment.
Unsupported reference fields are refused rather than silently treated as absent.
Bootstrap replaces `ArtisanLogbookDB` only after successful
validation and session initialization. A failed load leaves the original
SavedVariables intact and tracing independent. A missing database creates schema
2 with the required identity marker; the unrelated trace database is never imported. Malformed result snapshots
are rejected before craft/reagent facts are committed; timestamps are never
fabricated as zero when the clock is unavailable.

## Regression Coverage and Limits

`tests/ledger_test.lua` replays the sanitized Retail build-69933 fixture and
covers basic results, concentration without Ingenuity, Multicraft,
multi-reagent Resourcefulness, separate batch results/operation IDs, unknown
versus zero/false, reload IDs, startup age pruning, append-only dimensions,
ambiguous/repeated results, unsupported flavor capabilities, and supported-format
reload/refusal safety. Hardening tests cover every reference path,
sparse collections, missing/exhausted counters, atomic enrichment/conflicts,
expansion enrichment, runtime realm collisions/fallback, and deterministic
pruning/index reconstruction. The mocked TOC test covers passive capture while
tracing is paused, reload identity, missing identity APIs, initialization refusal,
and debug-trace clear isolation. Sanitized personal build-69933 replay covers
two quality mixes, off/on concentration and quote/spend differences, mapped
multi-item returns, three-result batches, partial failure, ambiguous attribution,
reload and pruning. Index coverage includes rebuild after
load/pruning, incremental updates, metadata enrichment, sorted ID/time arrays,
history above 50,000 crafts, direct lookup/no-scan callbacks, and indexed query
correctness. Issue #24 coverage adds 20/80 authoritative cohorts for `nil` and
`{}` lists, legacy positive-only cohort isolation, duplicate-slot consolidation,
missing-input coverage after pruning, malformed lists, first-craft rewards in a
batch, enchanting/prospecting/recraft classification, unknown-recipe repair of
all grains, rollback for eight corruptions, and a 50,000-craft stress run.
`tests/fixtures/legacy/` holds three schema-1 SavedVariables (pre-#21,
`outcomeVersion = 1` and `= 2`) **generated by the historical Ledger code** that
wrote them (`generate.lua` documents how), each with pruned history, duplicate
slots, enchanting, synthetic prospecting/crushing, an unknown recipe and a
legacy first-craft reward row. `Ledger-schema1.lua` is the verbatim schema-1
Ledger used by tests to write further authentic schema-1 inputs. Run `bash src/addon/scripts/package.sh` from
the repository root to test and validate the Core-only, UI-only, and bundle ZIPs
in `src/addon/dist/`.

Remaining evidence gaps include operation-ID reuse scope, true duplicate/late
callback behavior, crafting-order/recraft
context, reagent ownership/source, the exact callback shape of salvage outputs,
and the meaning of `bonusCraft`. The Lua API projects only facts already
supported by this ledger; see [lua-api.md](lua-api.md). This slice does not add
AL1 export, Recent/
Stats/Data product UI, CraftSim/TSM integration, Forever support, costing,
inventory/sales accounting, or release publishing; those remain later work.

Series tests cover atomic commit/exhaustion, repeated reload, coverage and observed
zero, unknown dimensions, commit visibility, UTC boundaries, and durable queries
on both sides of the detail cutoff. Facet tests cover requested subsets without
unused population traversal.