---
title: Resourcefulness Data Integrity
tags:
  - architecture
  - resourcefulness
  - data-integrity
  - migration
---

# Resourcefulness data integrity

This document records the durable invariants and design boundaries of the schema-v2 Core recorder. The public Lua API is documented in [lua-api.md](lua-api.md); storage layout and retention in [storage-ledger.md](storage-ledger.md).

## What a measurement means

A *craft* is a retained result observation; not every result is an independently identifiable, authoritative crafting attempt. A first-craft reward is a child of an attempt, not another denominator. Secondary/bonus results and unsupported operations must not consume a personal craft request merely by appearing after it.

A Resourcefulness *authoritative outcome* requires a validated primary result owned by a supported operation. For that result only, an omitted `resourcesReturned` field and a valid empty list mean **no returned materials**. Valid return entries establish positive quantities; malformed/partial lists can still preserve their provable positive entries but **cannot establish a complete negative or a complete return set**.

A historical positive-only observation must never become a negative by inference. Report known observations and authoritative denominators separately; never compute a positive/observed rate over selectively positive legacy data.

## Input provenance and completeness

A crafting quote is not evidence of actual submission. The Retail adapter snapshots the arguments of `CraftRecipe`, reconciles submitted allocations slot-by-slot against a readable recipe schematic, and independently records fixed basic reagent requirements where provable. Previous quotes, optional selections that were removed, stale recipe levels, missing automatic material selections and unsupported/variable slots must not manufacture input measurements.

`quoteObserved` means only that quoted/submitted allocation evidence exists; it does not prove all inputs. `inputComplete` requires a positively reconciled complete input set for **this owned operation**. For per-item savings, `inputTotalComplete` proves the entire input quantity of **that item for this operation**. Unknown slot identities or possible additional quantities for the same item prevent a complete item denominator, while a disjoint known item may remain eligible.

Consolidate repeated input slots at the craft × item grain. Example: two completely known slots of item A, 5 and 3 units, and 2 units returned yield a matched required amount of 8 and a matched return of 2. If an unresolved slot could also contain A, keep the observed gross and positive return but do not claim a matched 2/8 (or 2/5) denominator.

A valid primary result with an incomplete return list may still retain known inputs, but its return outcome remains partial. Invalid primary identity and incomplete return-list evidence are different conditions.

## Durable cohorts and aggregation

The durable reagent grain is UTC day × character × recipe × item, alongside daily craft series and return-set summaries. It tracks gross allocations, positive returns, quote/input coverage, complete authoritative outcomes, and same-population matched required/returned amounts. The material-saving proportion is **sum of matched returned quantity / sum of matched required quantity** for the same eligible crafts; never mix lifetime returns with retained-only input details, or confuse gross allocated with net consumed. A zero denominator means *unavailable*, not 0%.

Aggregate data survives detail retention pruning. Recipe repair must transfer all corresponding grains and must not learn a recipe-output relationship from a result whose identity is not established.

## Result ownership and lifecycle

The latest hook or `TRADE_SKILL_CRAFT_BEGIN` alone does not prove that a later asynchronous result belongs to that hook. Positive game operation IDs retain runtime observation provenance. Previously seen unsupported/stale IDs cannot acquire a newer personal request, consume its count, copy its input proof or teach its output mapping. Primary identity eligibility gates authoritative normalization, personal request association, batch consumption and output learning coherently.

A malformed/nonprimary/bonus callback does not consume a clean pending request, even when another callback for the same operation ID may later complete the same original request. Duplicate primary results must not consume multiple positions. An incomplete return list, unlike a malformed primary result, does not by itself invalidate legitimate input ownership.

Interrupting, closing, cancelling or replacing outstanding work may leave delayed callbacks, **including nonpersonal enchanting, salvage/prospecting/crushing and recrafting/order operations without personal pending requests**. Ownership then fails closed: preserve raw provable returns, but do not claim authoritative attempt/input evidence or guess a new recipe relationship. Unseen operation IDs after an uncertain transition remain unowned. The registry survives detailed-history pruning and clear; successful purge retires previous same-request completion exceptions before numeric request IDs can be reused while retaining known-stale ID rejection.

Uncertainty can last for the remainder of a runtime session. `ArtisanLogbookManagement.Status()` exposes `operationOwnershipUncertain` and `authoritativeCaptureSuspended`; these describe capture state, not a promise that every callback is eligible. Starting another craft, waiting an arbitrary delay, or merely closing a profession window does not establish a reliable server-side drain boundary. Runtime registry entries are not persisted into SavedVariables; game reload with events in flight has not been proven to provide a cross-session correlation guarantee.

## Schema-v1 to schema-v2 migration

Migration stages a validated replacement database rather than destructively modifying schema-v1 data first. Preserve craft/request identifiers, dimensions, sessions, daily series, return sets, returned item quantities, recipe/output knowledge and retained facts. Backfill only quantities justified by surviving input/return facts **before** retention pruning. Never synthesize historical authoritative negatives or complete input evidence. Historical v1 `quoteObserved` is not equivalent to `inputComplete`; old schema-v2 measurements made before strengthened evidence rules are preserved, not retrospectively certified.

Reload must be idempotent; a rejected upgrade must leave the original SavedVariables usable. There is no necessary schema change for runtime operation-ID provenance and quarantine.

A real in-game migration comparison of a backed-up schema-v1 SavedVariables file to a schema-v2 save preserved 746 crafts, 761 reagent facts, 174 requests, 519 daily series, 133 return-set rows, 489 returned units and 8,808 recipe-output relationships. It added one game session, marked 230 historical crafts as quote-observed and created 545 durable reagent grains; it manufactured **zero** authoritative or matched historical crafts. Persisted file size grew about 4%. Private SavedVariables are not checked into the repository.

## Failure scenarios protected by regression tests

- Partial, sparse or unsupported schematics and missing/underfilled slots cannot certify full inputs; optional absence requires positive readable evidence.
- A removed optional reagent must not return as a phantom input from an earlier quote.
- A known 5-unit item subtotal plus unknown same-item inputs cannot become a complete matched denominator; duplicate fully known slots may be combined.
- A delayed salvage callback after a newer personal submission cannot steal its input facts, request position or recipe-output knowledge.
- Malformed top-level and bonus callbacks before the valid primary leave its request available; partial return lists preserve known inputs without claiming authoritative return completeness.
- Interrupted nonpersonal enchants/recrafts/orders can also have in-flight results, even without a personal request.
- Purging resets numeric request IDs but cannot allow nonterminal old operation provenance to alias a new request.
- Reload, pruning, clear, purge and unknown-recipe repair must preserve the same statistical population rules.

## Resource limits and unresolved live evidence

The aggregate update path scales with affected operation inputs, return items and touched grains. Existing recipe-output learning may also copy its relationship map; do not generalize an O(current-operation) claim to that unrelated path. The in-memory observed-operation registry scales with unique positive IDs during a runtime session, and its retained entries intentionally provide negative evidence against stale reattribution. It does not add corresponding SavedVariables growth. The diagnostic tracer behavior is separate and intentionally unchanged.

Live investigation should prioritize: actual Blizzard result ordering after interruption; whether any reliable completion/drain signal can safely end quarantine; manual versus automatic/fixed input consumption; bonus/first-craft operation-ID sharing and child ordering; and reload/login with outstanding callbacks. Until evidence is available, prefer missing statistical coverage over fabricated authoritative outcomes.
