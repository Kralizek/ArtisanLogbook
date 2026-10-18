---
title: Resourcefulness Data Integrity
tags:
  - architecture
  - resourcefulness
  - data-integrity
  - migration
---

# Resourcefulness data integrity

This document records the durable invariants and design boundaries of the schema-v3 Core recorder. The public Lua API is documented in [lua-api.md](lua-api.md); storage layout and retention in [storage-ledger.md](storage-ledger.md).

## What a measurement means

A *craft* is a retained result observation; not every result is an independently identifiable, authoritative crafting attempt. A first-craft reward is a child of an attempt, not another denominator. Secondary/bonus results and unsupported operations must not consume a personal craft request merely by appearing after it.

A Resourcefulness *authoritative outcome* requires a validated primary result owned by a supported operation. For that result only, an omitted `resourcesReturned` field and a valid empty list mean **no returned materials**. Valid return entries establish positive quantities; malformed/partial lists can still preserve their provable positive entries but **cannot establish a complete negative or a complete return set**.

A historical positive-only observation must never become a negative by inference. Report known observations and authoritative denominators separately; never compute a positive/observed rate over selectively positive legacy data.

## Input provenance and completeness

A crafting quote is not evidence of actual submission. The Retail adapter snapshots the arguments of `CraftRecipe`, reconciles submitted allocations slot-by-slot against a readable recipe schematic, and independently records fixed basic reagent requirements where provable. Previous quotes, optional selections that were removed, stale recipe levels, missing automatic material selections and unsupported/variable slots must not manufacture input measurements.

`quoteObserved` means only that quoted/submitted allocation evidence exists; it does not prove all inputs. `inputComplete` requires a positively reconciled complete input set for **this owned operation**. For per-item savings, `inputTotalComplete` proves the entire input quantity of **that item for this operation**. Unknown slot identities or possible additional quantities for the same item prevent a complete item denominator, while a disjoint known item may remain eligible.

Consolidate repeated input slots at the craft × item grain. Example: two completely known slots of item A, 5 and 3 units, and 2 units returned yield a matched required amount of 8 and a matched return of 2. If an unresolved slot could also contain A, keep the observed gross and positive return but do not claim a matched 2/8 (or 2/5) denominator.

A valid primary result with an incomplete return list may still retain known inputs, but its return outcome remains partial. Invalid primary identity and incomplete return-list evidence are different conditions.

For a required Basic slot with multiple schematic item alternatives, `quantityRequired`
establishes the recipe's expected gross slot-family total even when automatic
crafting omits that choice from the submitted `CraftingReagentInfo` list. This
does not prove that submitted or consumed inputs matched the schematic. A returned
quality identifies a possible candidate, not the allocation of all consumed units.
`grossRequirementsComplete` and the durable candidate-set aggregate preserve
the expectation independently from `inputComplete` and exact per-item savings.
Contradictory selections leave exact input completeness false and never enter
matched savings, while independently supported schematic expectations remain
available. Patron order requirements and returns are retained, but supplier
ownership is not inferred and order crafts do not enter the personal matched-savings
cohort. Resourcefulness rate denominators are unchanged.

## Durable cohorts and aggregation

The durable reagent grain is UTC day × character × recipe × item, alongside daily craft series and return-set summaries. It tracks gross allocations, positive returns, quote/input coverage, complete authoritative outcomes, and same-population matched required/returned amounts. The material-saving proportion is **sum of matched returned quantity / sum of matched required quantity** for the same eligible crafts; never mix lifetime returns with retained-only input details, or confuse gross allocated with net consumed. A zero denominator means *unavailable*, not 0%.

Aggregate data survives detail retention pruning. Recipe repair must transfer all corresponding grains and must not learn a recipe-output relationship from a result whose identity is not established.

## Result ownership and lifecycle

Ordinary-craft acceptance replays exposed two rejection paths: optional
`CraftRecipe` arguments were required by Core, and duplicate identical begins
made a clean personal request ambiguous. The adapter now normalizes API defaults;
duplicate begins for the same clean request are idempotent. Interrupted/replaced
ownership remains quarantined. The provided screenshots show attribution recovery
after reload, but no current event trace or current SavedVariables accompanies
them; they do not prove which path caused a particular live result.

Recipe identity and expected requirements do not require an allocation ownership
claim. For ordinary unowned results only, unique existing output metadata supports
identity and a result-time schematic observation supports expected Basic quantities.
The new provenance remains separate from submitted selections, complete exact
inputs and player savings; outcomes are never upgraded by this enrichment. No
prospecting/salvage input or authoritative outcome changes are included here.
Call-backed salvage recipe identity is now handled independently; see the
[Recycling investigation](crafting-observations.md#recycling-build-70448-investigation).

The latest hook or `TRADE_SKILL_CRAFT_BEGIN` alone does not prove that a later asynchronous result belongs to that hook. Positive game operation IDs retain runtime observation provenance. Previously seen unsupported/stale IDs cannot acquire a newer personal request, consume its count, copy its input proof or teach its output mapping. Primary identity eligibility gates authoritative normalization, personal request association, batch consumption and output learning coherently.

A malformed/nonprimary/bonus callback does not consume a clean pending request, even when another callback for the same operation ID may later complete the same original request. Duplicate primary results must not consume multiple positions. An incomplete return list, unlike a malformed primary result, does not by itself invalidate legitimate input ownership.

Interrupting, closing, cancelling or replacing outstanding work may leave delayed callbacks, **including nonpersonal enchanting, salvage/prospecting/crushing and recrafting/order operations without personal pending requests**. Ownership then fails closed: preserve raw provable returns, but do not claim authoritative attempt/input evidence or guess a new recipe relationship. Unseen operation IDs after an uncertain transition remain unowned. The registry survives detailed-history pruning and clear; successful purge retires previous same-request completion exceptions before numeric request IDs can be reused while retaining known-stale ID rejection.

Uncertainty can last for the remainder of a runtime session. `ArtisanLogbookManagement.Status()` exposes `operationOwnershipUncertain` and `authoritativeCaptureSuspended`; these describe capture state, not a promise that every callback is eligible. Starting another craft, waiting an arbitrary delay, or merely closing a profession window does not establish a reliable server-side drain boundary. Runtime registry entries are not persisted into SavedVariables; game reload with events in flight has not been proven to provide a cross-session correlation guarantee.

### Consecutive Patron orders in PR #31

The private schema-3 dump supplied on 2026-10-12 establishes the failure for
crafts 889/890 and requests 238/239. Replaying its recorded payloads reproduces
these transitions in the pre-fix ledger:

- Sequence 40111 begins recipe 1230854; 40122 submits order 1298473129.
- Sequence 40128 owns request 238 and commits craft 889, but clears only
  `pendingOrderRequest`, leaving `nonpersonalOperationOutstanding` true.
- Sequence 40809 begins recipe 1230869. Sequence 40820 submits order
  1298473105/request 239 while the stale outstanding flag is still true;
  **this submission sets ownership quarantine**.
- Sequence 40826 stores craft 890 without recipe/request ownership, with
  `requestCorrelationReason = "ownership-quarantine"`, 17 seconds after 889.

Both claimed-order probes match their submitted order IDs. The two primary
operation IDs are distinct. Between the operations, the trace shows a skill-list
update and a currency update, not an interruption, close, contradictory begin,
or replacement craft. Begin-before-submission ordering is reproduced through
the production adapter/Core/API path; quote and spellcast events do not consume
pending order positions.

An owned, successfully committed **final** order result now retires that order's
outstanding flag together with its pending handle. This is not a reset of
ownership uncertainty. Partial batches, malformed/bonus callbacks, rejected
commits, conflicting begins and interrupted/replaced operations keep their
safeguards. Known old operation IDs still cannot consume a newer request.

Request 239 retains selections at modified slots 1/2/4/5. Its claimed-order
probe explicitly supplies three units of item 236777 at slot 3, which is absent
from the crafter's submitted selections. Its retained schematic expectations
also include item 236949 at slot 1. A fixed `Reagent` slot and a
`ModifiedReagent` slot can share a numeric data index: treating them as one
namespace reproduces a global reconciliation failure and falsely matches the
modified selection against the fixed requirement. The adapter now separates
these identities, preserves a supported fixed singleton independently, and
still rejects duplicate indices **within** a slot type. The full live schematic
was not saved; this metadata shape is a regression probe, not a claimed verbatim
schematic export. Missing customer selections remain expectations, not fabricated
allocations. Patron crafts remain excluded from personal material savings even
when their crafter selections reconcile.

The dump already contains the validated 1230869-to-241309 output mapping.
Existing recipe repair can therefore restore craft 890's **recipe identity**.
An in-memory comparison preserves all 890 crafts, 239 requests, 842 reagent
facts and global measured totals. Repair does not attach request 239, copy its
allocations/requirements, or turn the unverified missing return list into an
authoritative negative. The supplied file is kept outside the repository and
is not rewritten or imported into committed fixtures.

## Schema-v1 to schema-v3 migration

Migration stages a validated replacement database rather than destructively modifying schema-v1 data first. Preserve craft/request identifiers, dimensions, sessions, daily series, return sets, returned item quantities, recipe/output knowledge and retained facts. Backfill only quantities justified by surviving input/return facts **before** retention pruning. Never synthesize historical authoritative negatives or complete input evidence. Historical v1 `quoteObserved` is not equivalent to `inputComplete`; old schema-v2 measurements made before strengthened evidence rules are preserved, not retrospectively certified.

Reload must be idempotent; a rejected upgrade must leave the original SavedVariables usable. Schema-1 data passes through the validated schema-1-to-2 conversion and then schema-2-to-3 initialization. Schema 2 family alternatives cannot be reconstructed from a current schematic or return-only item ID, so migration leaves family coverage unknown and preserves prior exact facts and aggregates unchanged.

A real in-game migration comparison of a backed-up schema-v1 SavedVariables file to a schema-v2 save preserved 746 crafts, 761 reagent facts, 174 requests, 519 daily series, 133 return-set rows, 489 returned units and 8,808 recipe-output relationships. It added one game session, marked 230 historical crafts as quote-observed and created 545 durable reagent grains; it manufactured **zero** authoritative or matched historical crafts. Schema-2-to-3 adds no inferred historical family requirements. Private SavedVariables are not checked into the repository.

## Failure scenarios protected by regression tests

- Partial, sparse or unsupported schematics and missing/underfilled slots cannot certify full inputs; optional absence requires positive readable evidence.
- A removed optional reagent must not return as a phantom input from an earlier quote.
- A known 5-unit item subtotal plus unknown same-item inputs cannot become a complete matched denominator; duplicate fully known slots may be combined.
- A delayed salvage callback after a newer personal submission cannot steal its input facts, request position or recipe-output knowledge.
- Malformed top-level and bonus callbacks before the valid primary leave its request available; partial return lists preserve known inputs without claiming authoritative return completeness.
- Interrupted nonpersonal enchants/recrafts/orders can also have in-flight results, even without a personal request.
- Consecutive completed Patron orders retire outstanding state only on the final owned commit; unfinished or rejected results cannot end quarantine.
- Fixed/modified index collisions do not poison disjoint submitted inputs; customer-supplied choices and ambiguous slot identities cannot manufacture player savings.
- Purging resets numeric request IDs but cannot allow nonterminal old operation provenance to alias a new request.
- Reload, pruning, clear, purge and unknown-recipe repair must preserve the same statistical population rules.

## Resource limits and unresolved live evidence

The aggregate update path scales with affected operation inputs, return items and touched grains. Existing recipe-output learning may also copy its relationship map; do not generalize an O(current-operation) claim to that unrelated path. The in-memory observed-operation registry scales with unique positive IDs during a runtime session, and its retained entries intentionally provide negative evidence against stale reattribution. It does not add corresponding SavedVariables growth. The diagnostic tracer behavior is separate and intentionally unchanged.

Live investigation should prioritize: actual Blizzard result ordering after interruption; whether any reliable completion/drain signal can safely end quarantine; manual versus automatic/fixed input consumption; bonus/first-craft operation-ID sharing and child ordering; and reload/login with outstanding callbacks. Until evidence is available, prefer missing statistical coverage over fabricated authoritative outcomes.
