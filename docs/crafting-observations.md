# Craft Context and Configuration

Issues #25 and #29 share one capture and persistence extension. Core records
observations, not prices, inventory, profitability or causal estimates. Configuration
identity contains observed conditions only; context and capture evidence are separate.

## Versioning Baseline

The PR target, `master` at `7a1838770db176688f1f5b823116ae3ca0152278`, defines
ledger schema 3 and public API v1. This PR makes one logical schema change to
**schema 4**, with a direct 3-to-4 migration. Existing released schema-1/2 migration
support remains. Unreleased coupled layouts from earlier PR revisions are refused,
not migrated, even if they used version numbers 4 or 5. Restore a backup from
master or explicitly reset a backed-up review database before testing this layout.
Saved data is never silently reset. Additive domain API changes retain API v1.

Schema/API version decisions are relative to the PR target, not previous commits
within the PR. Intermediate review revisions do not create supported migrations.

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
  in configuration identities. Material ownership remains a separate fact.
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
5. Equipment, crafting-detail or player-aura events trigger a fresh configuration
  check during the accepted attempt. An unchanged observed condition set is a UI
  refresh, not an invalidation. A changed or unavailable recheck invalidates the
  attempt's configuration without erasing its context or outcome; invalidation
  remains sticky through that result. A new batch position can establish fresh
  start evidence. Expiration times are not canonical identities; supported buff
  state is refreshed at begin and checked again after aura events.
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
`CraftSalvage` uses the separate call-backed recipe lifecycle described below;
it still receives no configuration or authoritative input/outcome evidence. No global
operation-ID merging or new persisted attempt-count semantics are introduced. First-craft
rewards inherit a known parent's observation and never consume a batch position.
This leaves #32 free to separate attempts from outputs using the same dimension.

### Recycling: build-70448 investigation

The temporary diagnostic archive contains 160,258 retained events (sequences
41,923-202,180), recorded with `0.0.0-dev-9ec1926`. Its recipe dimension identifies
1229930 as Recycling. These are observed IDs, not name/output guesses:

| Sequence | Elapsed seconds | Observed evidence |
| --- | --- | --- |
| 41924 | 345770.6931341 | `TRADE_SKILL_CRAFT_BEGIN(1229930)` |
| 41933 | 345770.717189 | `CraftSalvage(1229930, 184, location, {}, false)` post-hook |
| 41934 | 345770.717227 | Request probe reports `operation = "unavailable"` |
| 41940-41941 | 345772.540002 | Player spell success/stop for 1229930 |
| 41942 | 345772.5753771 | **Next** begin for 1229930, before the previous result |
| 41943 | 345772.6564928 | Operation 3854211863, item 243581, quantity 4 |
| 42948-42949 | 345774.764398 | Next begin followed about 2 ms later by operation 533880495, quantity 3 |
| 43960 / 44001 | 345776.830418 / 345776.924349 | Next begin, then operation 2010458240, quantity 3; 3 of item 245807 returned |
| 201106-201107 | 346153.112978 | Final result (operation 722306087, quantity 2), then stopped(false) |

There is one submitted call, 184 begins, 184 player cast starts/successes/stops,
and 184 results with distinct positive operation IDs. Every result is item
243581 (Evercore in the captured link), quality 1, quantity 2-5; none carries a
recipe ID, `bonusCraft = true`, or `firstCraftReward = true`. Results span
380.4564852 seconds, with successive results 1.4708158-2.5886088 seconds apart.
This recording does **not** demonstrate multiple item-result callbacks for a
single Recycling operation. Multi-output regression cases are explicitly
synthetic extensions, not claimed observations.

All 184 operation IDs match saved crafts 1132-1315, each without a recipe and
with `requestCorrelationReason = "ownership-quarantine"`. Earlier saved rows in
the same runtime session already have that reason, before recording started.
The trace cannot establish which earlier transition first caused quarantine.
It does establish two independent defects in the old salvage path:

1. The adapter discards the submitted recipe/count when it invalidates personal
   correlation for `CraftSalvage`. The diagnostic quote being unavailable is
   unrelated: the submitted recipe ID is already readable and authoritative.
2. Without a supported pending batch, repeated same-recipe begins become ambiguous.
   The first next-begin-before-result pair already reproduces this in a clean
   session. Salvage never retires its outstanding context on completion, so a
   later hook or close also triggers session-long ownership quarantine.

The saved ledger provides comparison, not live event sequences for other crafts.
It contains ordinary recipe 1229853 crafts with request-backed identity and native
outcomes, 62 known Midnight Prospecting (1231127) output rows including 15 shared
operation IDs, and 7 known Crushing (1231132) rows. Those salvage rows have no
personal request. This does not prove their original attribution mechanism.
The captured relationship for Recycling does not include output 243581, so
existing output-based recovery has no confirming relationship for these results.
Recycling is not a unique API category here: the defective hook/lifecycle is
shared by `CraftSalvage` operations.

The corrected passive hook retains the submitted recipe and explicit positive
batch count in runtime-only salvage state, even when tracing is off or quotes
are unavailable. Matching begins are idempotent; they cannot consume or overwrite
an output's identity. The first complete output for each previously unseen
positive operation ID consumes one batch position. Further outputs of that ID
retain its recipe without consuming a position, including after another batch
starts. The positive identity cache is bounded to 64 operation IDs; the existing
seen-ID rejection registry prevents evicted IDs from stealing a newer batch.
This reuses the existing recent-operation bound, not a delay threshold measured
from this trace. It limits only how many recent operation identities can be
recovered for additional outputs: it does not limit batch size or the number of
recorded crafts. Active remaining-count state is independent of the cache, so
the observed 184-operation batch can evict early identities and still complete.
Evicted IDs remain in the existing session-long `observedOperationIds` registry,
including after history pruning; they cannot reacquire identity from a newer
submission. The new positive cache adds no unbounded recording.
Completing the submitted count retires outstanding salvage ownership without
waiting for a stop signal.

This changes recipe attribution only. There is still one craft fact per result
callback, no manufactured attempt/reagent/configuration facts, no new persisted
fields, no salvage output-to-recipe learning, and no historical repair. Positive
returned quantities remain measurable, but absent returns are not promoted to
authoritative negatives. Diagnostic retention is unchanged.

Conflicting begins, replacing/interruption/closing unfinished work, malformed
submissions, missing operation/output fields, and already quarantined sessions
cannot safely acquire fresh operation identity. Known recent IDs can retain
their already established recipe after cancellation; unknown or evicted IDs
stay unknown. Clear/purge discard positive salvage identity without resetting
the existing ownership guard. No timer or output-item guess clears uncertainty.
Results observed before the submitted-call hook and evicted operation IDs cannot
subsequently acquire a new batch's recipe.

#### Batch-transition assumptions and review findings

The count-based lifecycle assumes each counted salvage operation produces one
distinct positive operation ID, shared by its outputs. The Recycling trace
supports this for that batch; it is not an API-proven submission identifier or
a guarantee for every salvage variant.

- **Unfinished previous batch:** if an older operation has never returned any
  output, its position remains outstanding. Replacing that batch, cancelling it
  or closing the profession quarantines ownership before another submission.
  A synthetic regression delivers the old unseen ID after a different-recipe
  submission and verifies that both it and the new operation stay unknown and
  consume no positions. Known cached IDs still retain their original recipe.
- **Completed previous batch:** all requested distinct IDs have been seen under
  the count model. Additional outputs with those IDs are recoverable while
  cached, or remain unknown after eviction. They never consume another position.
  Sequential completed batches of the same or different recipe are supported.
- **Unexpected output between batches (confirmed defect):** previously, a
  complete, unseen operation ID after counted completion stayed unknown but left
  subsequent submissions eligible. This is an observable contradiction of the
  tracked lifecycle. Core now quarantines future unseen operations after
  committing that unknown result. Known cached or evicted IDs between batches
  are not such a contradiction and do not themselves trigger quarantine.
  Malformed payloads alone are not evidence of a new completed operation.
- **Unobservable origin (unresolved limitation):** suppose batch A has counted
  completion, batch B starts cleanly, and a previously unseen ID first appears
  during B. The payload can describe either B's next operation or an additional
  operation from A/outside captured context. There is no submission token in
  the payload to distinguish them. Under the supported count model an unseen
  A operation would have kept A unfinished; outside that model (extra IDs per
  operation, missed hooks, or cross-session in-flight work), the two origins
  are indistinguishable. Core can associate that ID with B. Quarantine protects
  observable uncertain transitions, **not** this undetectable case. No claim is
  made that every possible late unseen operation is rejected; doing so would
  also reject legitimate new-batch results. No timer, output-item guess or
  retroactive rewriting is used to conceal this limitation.

The review regressions are synthetic lifecycle extensions, explicitly separated
from the curated live trace: same/different-recipe completion, unfinished
replacement, known and unseen outputs between submissions, delayed additional
outputs, cache eviction during a 184-operation batch, and stale callbacks after
history pruning. Controlled live-game validation should check the one-ID-per-
counted-operation assumption for each salvage family and capture transitions
between different recipes; those live sequences are not present in this trace.

The curated first-three-result fixture preserves actual ordering, IDs and timing,
removing locations, item/cast GUIDs and UI chatter. Tests separately label batch
shortening, alternate output items, reordered extra callbacks and interruption
as synthetic variations. The full temporary trace was also replayed directly
against the old and corrected ledger in a clean session, without committing it.
The baseline produced 0 known / 184 unknown results; the corrected ledger
produced 184 known / 0 unknown, exactly 184 craft facts, no outstanding batch or
quarantine after close, and a 64-entry positive cache. This replay does not
retroactively clear the recorded session's pre-existing quarantine.

Separately, 158,664 of the captured records are UI quote-call/probe events (more
than 99% of the trace). They are not submitted craft requests and are not used
as identity evidence. Their volume is an unrelated diagnostic/performance
observation; neither quote probing nor trace retention is changed by this fix.

## Fields and Coverage

| Observation | Meaning and limits |
| --- | --- |
| `context.kind` | `personal`, generic `order`, `patron`, `public`, `guild`, `personal-order`, or `unknown`. Personal order is never ordinary personal crafting. |
| `context.source` | `submitted-call` or `claimed-order`; absent for unknown history. This is correlated client evidence, not an order ID on the result. |
| `context.isRecraft` | Independent boolean when the call or matched metadata establishes it; otherwise absent. |
| `configurationObservation.scope` | `request` or `attempt-start`, never an authoritative completion snapshot; independent of configuration identity. |
| `stats` | Exact reported base/bonus skill and difficulty, quality, thresholds, quoted concentration/refund, and identified bonus stats. No assumed sums from equipment. |
| bonus stats | `rating`, `ratingPct`, `bonusRatingPct` remain separate; percentages use Blizzard's reported percentage units. Missing fields stay absent. |
| stat identity | Exact comparison against localized Blizzard `ITEM_MOD_MULTICRAFT_SHORT`, `ITEM_MOD_RESOURCEFULNESS_SHORT`, `ITEM_MOD_INGENUITY_SHORT`, and `ITEM_MOD_CRAFTING_SPEED_SHORT` globals. `CraftingOperationBonusStatInfo` exposes the localized `bonusStatName` plus exact rating and percentage values, but no stable numeric stat ID. Unidentified labels reduce coverage; no English parsing or positional guesses. |
| equipment | Sorted inventory slots, explicit empty when `DoesItemExist` reports false, item ID, item GUID, and item-string payload preserving enchant/bonus information. Missing GUID/link means partial identity. Two same-base-item GUIDs remain distinct. |
| buffs | Only supported aura IDs 393665 (Quick Hands), 432306 (Concentrated Ingenuity), 1239755 (Haranir Ingenuity), plus reported stacks. `supported-list` means those phials were checked, not that all crafting buffs are known. Quality/mechanical magnitude is not inferred. |
| finishing reagents | Sorted item/quantity totals from submitted selections matching supported finishing slots. Duplicate items add across slots. Hidden, variable, malformed and unmatched selections cannot prove a complete set. |
| choices | Explicit concentration and supplied recipe level. Omitted Retail concentration uses the documented call default; other unavailable choices remain absent. |

Independent `configurationObservation.statsCoverage`, `equipmentCoverage`,
`buffsCoverage`, and `finishingCoverage` distinguish reported/observed/submitted/supported-list,
partial and unavailable. An absent array does not mean an empty set. An empty
supported buff list does not mean no other crafting buffs. No all-configuration
"complete" flag is provided.

## Durable Model and Retention

`configurations` interns only `stats`, `equipment`, `buffs`, `finishingReagents`,
`useConcentration` and `recipeLevel`, preserving field absence and exact values.
Craft type, recraft, context source, observation scope, coverage and buff-list
version do not enter this identity. They are scalar fields on request/craft facts:
`craftType`, `isRecraft`, `contextSource`, `configurationScope`, the four coverage
fields, `buffListVersion` and `configurationUnavailableReason`. An optional
`configurationKey` references the observed conditions.

Existing durable rows carry the same context/evidence fields and configuration
key. The grain is the existing day/character/recipe plus the observed combination
of configuration and context/evidence. Return sets, item measurements, expected
requirements and rewards use the parent's same combination. No second snapshot,
context dictionary, provenance dimension or independent cross-product aggregate
is introduced. Only combinations actually observed create rows. Existing #24/#31
coverage and matched-savings semantics are unchanged; recipe repair transfers
the same facts and aggregate contributions without reconstructing conditions.

**A key means equality of observed fields, not proof of equal full configurations.**
The same known partial payload can reuse storage with different evidence, but
those populations remain separate. An absent field differs from an explicitly
observed zero, false or empty list. A wholly unavailable payload has no key.
The API labels identity as `observed-fields` and exposes evidence independently;
it never offers a complete-configuration or causal-equivalence assertion.

- Every valid observed configuration is retained at its reported precision. There
  is no account-wide quota, per-grain quota, overflow partition, rounding or lossy
  bucketing. The old per-snapshot byte/string/list quotas are also removed.
  Structural validation still rejects malformed types, non-finite measurements,
  duplicate/unsorted identities and unsupported provenance.
- Repeated equal snapshots reuse the same canonical key, independent of table
  iteration order. Distinct ratings, tool instances, buffs and selected inputs do
  not collapse into one configuration. Canonical numeric signatures use 17-digit
  round-trip precision; persisted measurement values are not converted or rounded.
- `configurations` is a sparse numeric-keyed map. `nextConfigurationKey` is a validated
  monotonic allocator, independent of the number of live snapshots. Deleting a
  snapshot never renumbers another or makes its old key identify a different one.
- After the existing craft/request/reagent pruning pass, mark keys referenced by
  retained `crafts`, retained `requests`, `craftSeries`, `resourcefulnessSets`,
  `reagentSeries`, `reagentRequirementSeries`, and `firstCraftRewards`. Delete only
  unmarked snapshots. Runtime canonical indexes rebuild after collection. This
  also runs on load, after complete migration/validation, not on every capture.
- An abandoned request keeps its snapshot until that request expires. A separate
  request-time conditions payload can be collected once its request expires if
  different craft-start conditions remain referenced. Equal request/start conditions
  share one key. A key shared by several contexts is collectible only after its
  last reference disappears. Durable aggregate references protect
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
| 1 | 2.89 s | 16,893,886 | 39,095 KiB | 4,734 | 0.018 s | <0.001 s |
| 16 | 3.33 s | 18,374,942 | 42,454 KiB | 57,039 | 0.021 s | 0.005 s |
| 256 | 3.49 s | 19,224,784 | 44,336 KiB | 886,811 | 0.039 s | 0.073 s |
| 1,024 | 3.29 s | 21,886,386 | 50,374 KiB | 3,541,656 | 0.094 s | 0.299 s |
| 10,000 | 3.39 s | 48,281,430 | 110,451 KiB | 29,915,040 | 1.049 s | 3.519 s |

A separate benchmark holds conditions identical for 12,000 crafts and varies only
context/evidence. Six populations cover all captured craft types; 48 additionally
vary recraft, request/start scope and reported/partial stat coverage. Every case
stores **one** configuration. The coupled reference estimates only the old-style
snapshot dictionary for the same observed combinations, not an entire old database.

| Populations | Conditions dictionary | Coupled dictionary reference | Retained bytes | Durable bytes | Capture | Prune / reload |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 571 | 948 | 20,289,360 | 4,608 | 3.11 s | 0.018 / 0.002 s |
| 6 | 571 | 5,665 | 20,689,368 | 16,616 | 3.15 s | 0.016 / 0.008 s |
| 48 | 571 | 45,434 | 20,801,913 | 117,161 | 3.34 s | 0.020 / 0.010 s |

Fact-local evidence increases retained detail cost compared with a single combined
snapshot reference. It avoids duplicating the larger conditions payload and keeps
domain identities independent without another dictionary. Aggregate population
rows still grow where their context/coverage differs; coalescing them would erase
filtering evidence. These results do not claim an overall byte reduction for every
workload. Conditions are validated once per dictionary entry on load; each fact's
evidence is then validated separately without recopying the shared payload.

Storage grows with actual configuration cardinality and its observed aggregate
grains. Deduplication is effective for repeated states; durable configuration
data can dominate at high cardinality. GC cannot shrink this live history without
losing analysis data, so fidelity takes precedence. These are measurements, not
client performance guarantees. Existing 50k-craft API benchmarks still exercise
duplicate-input item totals, migration and queries.

## Migration

The original SavedVariables are cloned and validated. Schemas 1 and 2 use the
migrations already present on master. Validated schema 3 directly gains an empty
`configurations` dictionary and `nextConfigurationKey = 1` at final schema 4,
before final validation and normal pruning. Only a successful load installs the
new object. IDs, facts, all five aggregate collections and #24/#31 coverage remain
unchanged. Reload does not replay contributions. Malformed source data and the
unreleased coupled review layouts are refused without rewriting SavedVariables.

`tests/fixtures/legacy/ledger-schema3.lua` was generated using master's ledger at
`7a1838770db176688f1f5b823116ae3ca0152278` and independently accepted by it. Deep
equality tests cover retained craft/request/reagent facts, already-pruned history,
all aggregate collections, direct migration, reload and subsequent pruning.

Legacy configuration keys and context/evidence fields remain absent. Old request quotes and savings flags stay
available in their original API fields, but cannot classify whole already-pruned
populations or establish operation equipment/buffs. No speculative backfill is
performed; recipe repair cannot restore absent context/configuration. Back up
SavedVariables with WoW closed before upgrading. Older Core versions refuse the final schema 4.

## Public API

All existing craft, facet, daily-series, recipe outcome/return/requirement and
catalogue queries accept additive `craftType`, `isRecraft`, `contextSource`,
`configuration` and `configurationObservation`
filters (on catalogue options where other filters already live).

`craftType`: `personal`, `orders` (all order subtypes including generic order),
`patron`, `public`, `guild`, `personal-order`, `order` (generic only), `unknown`.
Absent selects all. `isRecraft=false` excludes unknown, not just true recrafts.
`contextSource` selects `submitted-call` or `claimed-order`; missing provenance
does not match either.

`configuration` accepts `key`, `stat` with `minimumRating`/`maximumRating`,
`equipmentItemID`, `equipmentGUID`, `buffSpellID`, `finishingItemID`, and
`useConcentration`. Conditions are ANDed; absent observations never match a
requested property. A stat range requires an identified stat. Unknown options
fail explicitly. Key values are opaque, store-local strings, not persistence
indexes for consumers to dereference.

`configurationObservation` selects `scope`, `statsCoverage`, `equipmentCoverage`,
`buffsCoverage`, `finishingCoverage` and/or `buffListVersion` independently from
condition identity. Scope is selected here, not inside `configuration`.
Conditions and evidence filters are ANDed.

`GetCraft` adds detached `context`, `configuration`, `configurationObservation`
and `configurationCoverage`;
its `request` has its own separately scoped projection. Unknown configurations
have no snapshot and coverage `unavailable`, `changed` or `batch-unobserved`.
Existing facts keep their original semantics. Known configurations are never
made unavailable to meet a storage budget.
`configuration` contains conditions, its opaque `key`, and
`identityBasis = "observed-fields"`. Scope and coverage are exclusively in
`configurationObservation`, not this identity. The legacy-style short
`configurationCoverage` summary still indicates request/start scope or why no
conditions were attributable.

`GetRecipeConfigurations(recipeId, filter, {limit, cursor})` returns
`configurations`, selection-wide `coverage`, and optional `nextCursor`. Each
group exposes domain context/configuration, independent observation evidence and
`totals` using existing outcome/input coverage names. Groups are **populations**:
the same configuration key can appear in several groups (and pages) with different
context, scope or coverage. Unknown groups remain explicit. Use its
configuration key with existing outcome, return-set and reagent queries for
the same recipe/time/character/context/evidence selection. Key-only queries
intentionally pool all matching observed populations; the key is not a claim that
their completeness is equal. Pages/cursors are filter-scoped and preserve every
population even when several share one conditions identity.

Outcome totals and configuration-query coverage add `contextObservedCount`,
`configurationObservedCount`, `requestConfigurationCount`,
`attemptStartConfigurationCount`. There is no capacity-loss counter or partition.
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

- Back up SavedVariables while logged out; load supported v1/v2/v3 copies and confirm all
  totals/IDs survive, legacy context stays unknown, and second reload is stable.
- Craft one ordinary item with manual quality selections and concentration on/off;
  compare request/start quote fields against Blizzard. Repeat automatic selection.
- Switch tools, including two same-base-item instances; inspect GUID/item-string
  distinction and accessory/empty-slot coverage with professions open and closed.
- Apply/expire supported phials before, between and during batch attempts. Verify
  an unchanged `CRAFTING_DETAILS_UPDATE`, unrelated aura update, or equipment event
  does not invalidate identical observed conditions. A supported phial, tool or
  quote-stat change during an attempt must invalidate that attempt's configuration.
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
- Set different Craft type and Period filters on Overview and Reagents, then
  navigate away and back. Verify each page retains its own totals, lists, charts,
  rankings and tooltips. Repeat for Recipe Detail and Reagent Detail filters.
- Close/reopen the window and confirm each page keeps its in-session selections;
  `/reload` should initialize Craft type to All crafts and Period to each page's
  existing default, not its previous active selection. Changing active filters
  must not alter SavedVariables or another page's defaults/selections.
- Inspect the three Craft Detail tabs at 1280x720, 1920x1080 and a smaller
  viewport with UI scales 0.64, 0.8 and 1.0. Check switching, wrapping, scroll
  boundaries, tooltips, craft replacement and modal navigation.
- Prune a backed-up copy and confirm aggregate filters still agree and every
  referenced configuration remains inspectable.
- Exceed 256 distinct configurations and eight states within one day's recipe;
  verify exact filtering still works. Abandon requests, expire their detail in a
  backed-up copy, and verify only truly unreferenced snapshots disappear without
  renumbering live keys.
- Observe the same conditions in personal/order/recraft contexts and request/start
  scopes. Check shared configuration keys but independent evidence and filtered
  totals. Different buff-list coverage must never imply equal unobserved buffs.

The container cannot validate native rendering, taint, secret values, event timing
or actual item consumption. Do not commit personal SavedVariables or raw traces.