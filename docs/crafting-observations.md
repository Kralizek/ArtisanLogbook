# Craft Context and Configuration

Issues #25 and #29 share one capture and persistence extension. Core records
observations, not prices, inventory, profitability or causal estimates. Schema 5
preserves exact configurations without admission quotas; public API v1 remains additive.

## Evidence Sources

Research used the Retail generated definitions and Blizzard profession UI at
[Gethe/wow-ui-source commit 18c6d67](https://github.com/Gethe/wow-ui-source/tree/18c6d677b605b312f3d813d498404631fb941977), particularly:

- `TradeSkillUIDocumentation.lua`: submitted call arguments, operation queries,
  `GetProfessionInfoByRecipeID` and `GetProfessionSlots`.
- `TradeSkillUITypesDocumentation.lua`: `CraftingOperationInfo`,
  `CraftingOperationBonusStatInfo`, reagent schematics and result payloads.
- `ProfessionConstantsDocumentation.lua`: `CraftingOrderType` and reagent roles.
- `CraftingOrderDocumentation.lua`: `GetClaimedOrder` and order metadata.
- `ItemDocumentation.lua`: equipment-location item ID, link and GUID.
- `UnitAuraDocumentation.lua`: `GetPlayerAuraBySpellID`.
- `Blizzard_ProfessionsRecipeSchematicForm.lua`: operation queries using the
  transaction's selected reagents and concentration.
- `Blizzard_ProfessionsRecipeCrafterDetails.lua`: displayed bonus-stat percentages.
- `Blizzard_ProfessionsCrafting.lua`: profession enum to equipped inventory slots.

[CraftSim commit 042d888](https://github.com/derfloh205/CraftSim/tree/042d8887f88b1830755d9f5702a20b8423ba0fc4)
independently corroborates localized stat globals and the three phial aura IDs
in `Util/Const.lua`, `Classes/Buff.lua`, and `Modules/CraftBuffs/CraftBuffs.lua`.
There is no runtime dependency on CraftSim. Repository build-69933 fixtures and
the existing sanitized consecutive-Patron replay establish the tested event shapes.
New API mocks follow these definitions; they are not claimed to be live traces.

## Capture Lifecycle

1. The secure `CraftRecipe` post-hook copies submitted selections. Context comes
   from the call, with order subtype only when `GetClaimedOrder().orderID` matches
   the submitted ID. Customer identity, notes, prices and order IDs are not saved
   in the observation dimension. Material ownership remains a separate fact.
2. A request configuration queries the operation using those selections and the
   submitted concentration choice. Equipment comes from the recipe profession's
   equipped slots, not bags or the currently displayed profession alone. Supported
   phials and finishing slots are observed independently.
3. A matching `TRADE_SKILL_CRAFT_BEGIN` obtains a fresh `attempt-start` snapshot.
   Core accepts it only for its clean pending request and current batch position.
   Repeated begins cannot replace an already accepted snapshot for that position.
   A begin preceding the hook cannot retroactively prove a start snapshot.
4. Only the existing primary-result ownership gate attaches an observation to a
   craft. The first attempt can carry `request` evidence. Subsequent attempts need
   their own begin snapshot; otherwise configuration is `batch-unobserved` while
   the request snapshot remains inspectable separately.
5. Equipment changes, crafting-detail changes or player aura updates invalidate
   configuration for the pending attempt, without erasing its context or outcomes.
   This is deliberately conservative, including unrelated aura/equipment changes.
   A new batch position can establish fresh start evidence. Expiration times are
   not canonical identities; buff state is refreshed at begin and aura updates
   invalidate it during an attempt.
6. A spell failure/interruption cancels the pending operation only when its GUID
   matches a player craft cast observed at `UNIT_SPELLCAST_START`. Unrelated or
   queued failures are not proof of interruption. Closing and replacing unfinished
   work retain the existing session-long ownership quarantine. A stopped(false)
   signal alone does not retire ownership; #32 demonstrates why that is unsafe.

**Neither quote scope proves final effective statistics.** The operation-info
response has no completed `operationID`; the result has outcomes but no effective
stat/equipment/buff snapshot. `attempt-start` means observed at a correlated begin,
not server-certified for the whole cast. Capture does not infer causal effects.
Missing event ordering or unavailable/secret APIs can reduce coverage.

`CraftEnchant`, `RecraftRecipe` and `RecraftRecipeForOrder` retain the existing
conservative nonpersonal ownership lifecycle. Their call-backed context and
independent recraft flag can be captured for an owned primary result, but target-
dependent configuration and allocations are unavailable in this implementation.
`CraftSalvage` and unsupported/multi-output callbacks remain unknown. No global
operation-ID merging or new attempt-count semantics are introduced. First-craft
rewards inherit a known parent's observation and never consume a batch position.
This leaves #32 free to separate attempts from outputs using the same dimension.

## Fields and Coverage

| Observation | Meaning and limits |
| --- | --- |
| `context.kind` | `personal`, generic `order`, `patron`, `public`, `guild`, `personal-order`, or `unknown`. Personal order is never ordinary personal crafting. |
| `context.source` | `submitted-call` or `claimed-order`; absent for unknown history. This is correlated client evidence, not an order ID on the result. |
| `context.isRecraft` | Independent boolean when the call or matched metadata establishes it; otherwise absent. |
| `configuration.scope` | `request` or `attempt-start`, never an authoritative completion snapshot. |
| `stats` | Exact reported base/bonus skill and difficulty, quality, thresholds, quoted concentration/refund, and identified bonus stats. No assumed sums from equipment. |
| bonus stats | `rating`, `ratingPct`, `bonusRatingPct` remain separate; percentages use Blizzard's reported percentage units. Missing fields stay absent. |
| stat identity | Exact comparison against localized Blizzard `CRAFTING_DETAILS_*` globals, with `ITEM_MOD_CRAFTING_SPEED_SHORT` for speed. The API has no numeric stat ID. Unidentified labels reduce coverage; no English parsing or positional guesses. |
| equipment | Sorted inventory slots, explicit empty when `DoesItemExist` reports false, item ID, item GUID, and item-string payload preserving enchant/bonus information. Missing GUID/link means partial identity. Two same-base-item GUIDs remain distinct. |
| buffs | Only supported aura IDs 393665 (Quick Hands), 432306 (Concentrated Ingenuity), 1239755 (Haranir Ingenuity), plus reported stacks. `supported-list` means those phials were checked, not that all crafting buffs are known. Quality/mechanical magnitude is not inferred. |
| finishing reagents | Sorted item/quantity totals from submitted selections matching supported finishing slots. Duplicate items add across slots. Hidden, variable, malformed and unmatched selections cannot prove a complete set. |
| choices | Explicit concentration and supplied recipe level. Omitted Retail concentration uses the documented call default; other unavailable choices remain absent. |

Independent `statsCoverage`, `equipmentCoverage`, `buffsCoverage`, and
`finishingCoverage` distinguish reported/observed/submitted/supported-list,
partial and unavailable. An absent array does not mean an empty set. An empty
supported buff list does not mean no other crafting buffs. No all-configuration
"complete" flag is provided.

## Durable Model and Retention

`observations` interns canonical context/configuration snapshots. Retained
requests/crafts and all five existing durable collections use an optional
`observationKey`. Their effective grain is the existing day/character/recipe
grain plus this single key, not separate equipment x buff x rating x reagent
dimensions. Return sets, item measurements, expected requirements and rewards
use the same partition as their parent craft. Existing #24/#31 coverage rules and
item-level matched savings are unchanged. Unknown-recipe repair transfers the
same observation partition, not a reconstructed configuration.

- Every valid observed configuration is retained at its reported precision. There
  is no account-wide quota, per-grain quota, overflow partition, rounding or lossy
  bucketing. The old per-snapshot byte/string/list quotas are also removed.
  Structural validation still rejects malformed types, non-finite measurements,
  duplicate/unsorted identities and unsupported provenance.
- Repeated equal snapshots reuse the same canonical key, independent of table
  iteration order. Distinct ratings, tool instances, buffs and selected inputs do
  not collapse into one configuration. Canonical numeric signatures use 17-digit
  round-trip precision; persisted measurement values are not converted or rounded.
- `observations` is a sparse numeric-keyed map. `nextObservationKey` is a validated
  monotonic allocator, independent of the number of live snapshots. Deleting a
  snapshot never renumbers another or makes its old key identify a different one.
- After the existing craft/request/reagent pruning pass, mark keys referenced by
  retained `crafts`, retained `requests`, `craftSeries`, `resourcefulnessSets`,
  `reagentSeries`, `reagentRequirementSeries`, and `firstCraftRewards`. Delete only
  unmarked snapshots. Runtime canonical indexes rebuild after collection. This
  also runs on load, after complete migration/validation, not on every capture.
- An abandoned request keeps its snapshot until that request expires. A separate
  request-time snapshot can be collected once its request expires if only the
  craft-start snapshot remains referenced. Durable aggregate references protect
  their snapshots indefinitely, even after all detailed crafts are gone.
- No per-craft membership archive or persisted reference counts are added. The
  mark pass uses the existing records, avoiding counter drift during migration,
  repair or pruning. Collection costs one pass over surviving rows and snapshots.
  ClearHistory clears snapshots but preserves the allocator; explicit full purge
  resets the entire database, including its key namespace.

Capture scales with snapshot fields, inputs, returns and touched aggregate grains,
not all history. Indexes rebuild on load. Queries visit selected daily grains;
configuration summary results are paged at 50 by default, maximum 200 per response,
with all remaining configurations accessible through cursors. This is not a
retention or admission limit. The public
daily-series API combines selected partitions back into its original grain.
The longstanding session operation-ID registry and retained details still grow
with session/craft count; these are not configuration dictionaries.

Representative Lua 5.1 container run: each workload has 10,000 crafts at one
day/character/recipe grain, returns on 20%, and an optional finishing input.
Configurations repeat in contiguous batches. Variants include two same-base-item
tool GUIDs, a stable accessory, a supported phial active/absent, finishing reagent
selected/absent, concentration on/off and exact fractional stat changes. These
are sanitized synthetic API-shaped observations, not assumed game stat formulas.
The 10,000-configuration case is an adversarial unique-state workload, not typical
crafting. Every configuration and its aggregate is asserted to survive pruning
and reload; reported cardinalities are observations, not limits.

| Configurations | Capture | Retained estimated Lua bytes | Runtime delta | Pruned bytes | Prune | Reload |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2.41 s | 10,453,309 | 29,718 KiB | 4,157 | 0.015 s | <0.001 s |
| 16 | 2.40 s | 11,923,258 | 33,050 KiB | 45,355 | 0.012 s | 0.003 s |
| 256 | 2.37 s | 12,597,900 | 34,491 KiB | 699,927 | 0.027 s | 0.055 s |
| 1,024 | 2.58 s | 14,698,862 | 39,116 KiB | 2,794,132 | 0.095 s | 0.207 s |
| 10,000 | 2.96 s | 37,117,426 | 90,188 KiB | 25,191,036 | 1.166 s | 2.803 s |

Storage grows with actual configuration cardinality and its observed aggregate
grains. Deduplication is effective for repeated states; durable configuration
data can dominate at high cardinality. GC cannot shrink this live history without
losing analysis data, so fidelity takes precedence. These are measurements, not
client performance guarantees. Existing 50k-craft API benchmarks still exercise
duplicate-input item totals, migration and queries.

## Migration

The original SavedVariables are cloned and validated. Schemas 1 and 2 pass through
their existing migrations; validated schema 3 gains an empty observation
dictionary at schema 4, then all validated schema-4 data migrates to schema 5
before final validation and pruning. The original
object is installed/replaced only through the existing successful-load path.
IDs, observations, historical aggregates and #24/#31 provenance are preserved.
Reload does not replay contributions. Relabeled or malformed schemas are refused.

Schema 4 to 5 keeps every existing observation key and initializes the allocator
above the highest old key. Old `capacity` markers become generic `unavailable`
observations, retaining context, reference identities and every aggregate total.
They do not gain a fabricated configuration or an authoritative negative. Exact
request snapshots already saved remain independently inspectable. Lost values
cannot be recovered from the old quota records. Only the schema-4 migration reads
the retired marker; new capture and the public API have no capacity semantics.

Legacy observation keys remain absent. Old request quotes and savings flags stay
available in their original API fields, but cannot classify whole already-pruned
populations or establish operation equipment/buffs. No speculative backfill is
performed; recipe repair cannot restore absent context/configuration. Back up
SavedVariables with WoW closed before upgrading. Older Core versions refuse v5.

## Public API

All existing craft, facet, daily-series, recipe outcome/return/requirement and
catalogue queries accept additive `craftType`, `isRecraft`, `configuration`
filters (on catalogue options where other filters already live).

`craftType`: `personal`, `orders` (all order subtypes including generic order),
`patron`, `public`, `guild`, `personal-order`, `order` (generic only), `unknown`.
Absent selects all. `isRecraft=false` excludes unknown, not just true recrafts.

`configuration` accepts `key`, `scope`, `stat` with `minimumRating`/`maximumRating`,
`equipmentItemID`, `equipmentGUID`, `buffSpellID`, `finishingItemID`, and
`useConcentration`. Conditions are ANDed; absent observations never match a
requested property. A stat range requires an identified stat. Unknown options
fail explicitly. Key values are opaque, store-local strings, not persistence
indexes for consumers to dereference.

`GetCraft` adds detached `context`, `configuration`, `configurationCoverage`;
its `request` has its own separately scoped projection. Unknown configurations
have no snapshot and coverage `unavailable`, `changed` or `batch-unobserved`.
Existing facts keep their original semantics. Known configurations are never
made unavailable to meet a storage budget.

`GetRecipeConfigurations(recipeId, filter, {limit, cursor})` returns
`configurations`, selection-wide `coverage`, and optional `nextCursor`. Each
group exposes domain context/configuration, coverage and `totals` using existing
outcome and input coverage names. The unknown group is retained. Use its
configuration key with existing outcome, return-set and reagent queries for
the same recipe/time/character selection. Pages/cursors are filter-scoped.

Outcome totals and configuration-query coverage add `contextObservedCount`,
`configurationObservedCount`, `requestConfigurationCount`,
`attemptStartConfigurationCount`. The former `configurationCapacityLimitedCount`
field is removed; it is not emitted as a zero.
These describe selected observations, not authoritative effective-stat coverage.

**Comparison rule:** filtering aligns the selected craft population, not every
measurement's completeness. Every metric retains its own observed count. Do not
divide separately observed output/bonus/refund sums unless both cover the same
population, or compare request snapshots to start snapshots as if identical.
Use `matchedAllocatedQuantity`/`matchedReturnedQuantity` and `matchedCraftCount`
for per-item savings; neither all returns nor gross expected requirements are a
substitute. Returned items are not additive proc counts. Missing observations and
historically lost configurations can bias comparisons. Core exposes facts/coverage, not a
bare effectiveness percentage, confidence interval, causal claim or optimizer.

## In-Game Verification

- Back up SavedVariables while logged out; load v1/v2/v3/v4 copies and confirm all
  totals/IDs survive, legacy context stays unknown, and second reload is stable.
- Craft one ordinary item with manual quality selections and concentration on/off;
  compare request/start quote fields against Blizzard. Repeat automatic selection.
- Switch tools, including two same-base-item instances; inspect GUID/item-string
  distinction and accessory/empty-slot coverage with professions open and closed.
- Apply/expire supported phials before, between and during batch attempts. Apply
  an unrelated aura; confirm conservative missing coverage, never a stale claim.
- Select/remove finishing reagents, including multiple slots and quantities;
  distinguish a recorded empty selection from unavailable slots.
- Run ordinary batches with begin-before-hook, repeated begin and missing-begin
  sequences. Interrupt a tracked cast; attempt replacements and delayed results.
- Complete consecutive Patron/public/guild/personal orders, then ordinary crafts.
  Inspect mismatched/unavailable claimed metadata and recrafts independently.
  Order-provided materials must never become assumed personal savings.
- Craft enchants and ordinary/order recrafts; configuration can remain unavailable.
  Replay prospecting/crushing/milling and child rewards: no new attribution or
  negative proc assertions from unsupported multiple-result callbacks (#32).
- Switch Craft type on Overview, Logbook, Recipes, Recipe Detail, Character,
  Profession and Reagents. Check charts, rankings, quality rows, quantities,
  useful Resourcefulness preferences, tooltips and lazy-page continuation.
- Inspect the two Craft Detail tabs at 1280x720 and 1920x1080 with UI scales
  0.64, 0.8 and 1.0. Check wrapping, scrolling, tooltips and modal navigation.
- Reload with Craft type selected; prune a backed-up copy and confirm aggregate
  filters still agree and every referenced configuration remains inspectable.
- Exceed 256 distinct configurations and eight states within one day's recipe;
  verify exact filtering still works. Abandon requests, expire their detail in a
  backed-up copy, and verify only truly unreferenced snapshots disappear without
  renumbering live keys. Check old quota records stay unavailable after upgrade.

The container cannot validate native rendering, taint, secret values, event timing
or actual item consumption. Do not commit personal SavedVariables or raw traces.