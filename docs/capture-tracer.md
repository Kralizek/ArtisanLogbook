# Retail Capture Evidence (PR #3)

This document preserves the capture evidence verified in merged PR #3 against
user-supplied live Retail traces from build 69933 (12.1.0). It is the historical
tracer review record, not the durable storage contract. The issue #4 ledger
implementation and its conservative correlation behavior are documented in
[storage-ledger.md](storage-ledger.md). Other cases and universal correlation
guarantees remain unverified.

## Build and Install

From the repository root, with Lua 5.1, ZIP, and unzip available:

```sh
bash src/addon/scripts/package.sh
```

This runs the addon tests and produces Core-only `ArtisanLogbook_Core.zip`,
UI-only `ArtisanLogbook.zip`, and `ArtisanLogbook-Bundle.zip` in `src/addon/dist/`.
Extract the bundle's sibling `ArtisanLogbook_Core` and `ArtisanLogbook` folders
into the live client's `_retail_/Interface/AddOns/`, or install both individual
archives. Core's TOC must be at `Interface/AddOns/ArtisanLogbook_Core/ArtisanLogbook_Core.toc`;
the UI requires Core. Restart the client after the first installation.
Enable **Artisan Logbook** in the addon list.

The TOC targets interface `120100`, based on the live UI source mirror reporting
12.1.0 (69933) on 2026-09-26. Confirm the actual client using
`/dump GetBuildInfo()`; the client, not the mirror, is authoritative. Report any
mismatch before changing the compatibility target. Every recording start also
stores the actual build, interface, locale, character, realm, and capabilities.

Open the tracer with `/al_trace`. Recording starts **paused**
on every load/reload. The native window provides Start, Stop, an editable scenario
label with Mark, Export, Diagnostics, page arrows, and confirmed Clear. Closing
the window does not stop capture. It does not alter the crafting UI or trigger
crafts. No third-party libraries or addons are required.

The debug window also provides **Repair unknown recipes** beside the database
purge control. It first tries to verify remaining output-name candidates through
Blizzard metadata, learns confirmed relationships, then previews repair counts.
Historical craft/aggregate mutation still requires confirmation; canceling keeps
any authoritative knowledge learned, not a pending repair. Ambiguous and
unsupported crafts stay Unknown. This is a recovery tool, not a replacement for
correct live capture. Startup and profession-event recovery are silent and
best effort. Diagnostics show the last discovery's candidate, confirmed,
unavailable and unconfirmed counts, and relationships learned this session.

### Recipe metadata and recovery

API-contract/source review (2026-10-03; not an in-client experiment):

- `C_TradeSkillUI.GetRecipeSchematic(recipeId, false)` is a direct recipe-ID
   query. Its returned `recipeID` must match; `outputItemID` is nullable. The
   contract does not promise availability for every recipe before opening its
   profession, nor give a complete cache-readiness guarantee. Startup/manual
   recovery makes one query per plausible recipe and accepts only readable,
   explicit output identities. Missing APIs, errors and unavailable metadata
   leave the output unsupported, without opening a profession or waiting.
- A schematic exposes one optional output ID, not all possible outputs.
   `GetRecipeQualityItemIDs(recipeId)` supplies an optional array of quality
   output IDs. With a matching schematic, these IDs and its output ID form a
   deduplicated set. There is no assumption that this enumerates every random,
   salvage, enchanting, gathering, reagent-dependent or recraft outcome. Currency
   or other recipes without explicit item outputs cannot be recovered this way.
   Absence of X in a returned set is not a permanent claim that R cannot make X.
- No general item-ID-to-recipe lookup was found in the reviewed contract.
   `GetOriginalCraftRecipeID` requires an item GUID, not a retained output item ID.
   Exact stored item/recipe names are therefore a discovery hint only. No fuzzy
   matching, translation, spell-name inference or external recipe data is used.
- `GetAllRecipeIDs()` returns the current profession's learned and unlearned
   recipes, ignoring UI filters; before a profession opens it can return an
   empty list. Event enrichment uses these IDs directly, without name matching
   or scanning stored recipes from other professions. Missing enumeration does
   not fall back to querying every stored recipe.
- `TRADE_SKILL_SHOW` and `TRADE_SKILL_LIST_UPDATE` are existing opportunities.
   `IsDataSourceChanging()` and `IsTradeSkillReady()` guard unstable/unloaded
   lists. Blizzard's profession UI itself defers list handling while the data
   source is changing. Neither flag guarantees every individual output query.
   One open pass and the first stable list-update pass are allowed; duplicate
   events for that settled list do no further recipe queries. A changed list,
   an observed readiness transition, or close/reopen permits a new opportunity.
- Queries are synchronous metadata reads. The published contract has no
   mutation, UI-opening or user-gesture requirement for these getters. Their
   native cache behavior and worst-case latency are not specified; Lua mocks
   cannot measure those. We do not force loading via `OpenRecipe`, profession
   switching, or request loops. A live client is needed to characterize which
   unavailable recipes become readable at each opportunity.

### Forever compatibility

The published Forever TradeSkillUI declarations include `GetRecipeSchematic`,
`GetRecipeQualityItemIDs`, the existing recipe/profession information getters,
and `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`, `TRADE_SKILL_CLOSE`.
The output getters are in `Environment = "All"`, with
`SecretArguments = "AllowedWhenUntainted"`, without a protected/limited-input
precondition in the reviewed declarations. This annotation restricts **secret
arguments**, not ordinary addon calls with plain recipe IDs. Recovery passes
only validated IDs and a literal `false`; it does not request secure execution.

The API references list `GetAllRecipeIDs`, `IsTradeSkillReady`, `issecretvalue`
and `canaccesstable` for Forever 1.60.1 (69913). Forever's profession UI uses
`IsDataSourceChanging()` with `TRADE_SKILL_LIST_UPDATE`; that getter, like some
other established TradeSkill getters, is absent from the generated catalog.
All getters remain feature-detected and best effort. `issecretvalue` and
`canaccesstable` reject secret/inaccessible metadata before identity operations;
unavailable/invalid metadata never authorizes repair. No secret values are
decoded, persisted as evidence, or inspected through another execution context.

Recovery adds no hooks into Blizzard frames, protected actions, hidden data,
network access, timers, or polling. Existing normal item-cache events continue
name enrichment; profession events refresh only their observed output items.
This verifies the recovery API contract/usage pattern, not execution on an
actual Forever client or certification of the entire addon's other features.
Future restrictions or unavailable metadata must preserve Unknowns.

Sources reviewed:

- [Retail API declarations](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua)
   and [output structures](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua).
- [Forever API declarations](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua)
   and [profession event handling](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_Professions/Blizzard_ProfessionsFrame.lua).
- [GetAllRecipeIDs](https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.GetAllRecipeIDs),
   [IsTradeSkillReady](https://warcraft.wiki.gg/wiki/API_C_TradeSkillUI.IsTradeSkillReady),
   [secret restrictions](https://warcraft.wiki.gg/wiki/Secret_values),
   [issecretvalue](https://warcraft.wiki.gg/wiki/API_issecretvalue), and
   [canaccesstable](https://warcraft.wiki.gg/wiki/API_canaccesstable).

Live acceptance: load the existing schema-v1 DB without opening a profession,
check Diagnostics, open a relevant profession and check again, then try manual
Repair. Verify silence, readiness, ambiguous outputs remaining Unknown, cancel
leaving craft facts untouched, and learned knowledge surviving reload. The
actual 14-Unknown DB and a Retail/Forever client are not part of the Lua tests.

Optional commands:

```text
/al_trace start
/al_trace mark basic-before
/al_trace mark basic-after
/al_trace stop
/al_trace status
/al_trace export
```

`/al` and `/artisanlogbook` open the separate production UI. The tracer window refreshes status twice per second while
visible, but does not overwrite export text as events arrive. Export refreshes
the displayed data with the complete trace in one copyable block. Click in the
export text, select all, and copy. The page arrows switch to ten-record pages
as a fallback for large traces; Export returns to the complete trace. Capture
is bounded independently of rendering.

## Controlled Trace Collection

1. Start with a clean, out-of-combat session on live Retail. Disable unrelated
   addons for the first pass, including CraftSim and TSM. Open the profession.
2. Start recording, enter a unique label such as `basic-01-before`, and Mark.
   Also note recipe/profession, allocated reagent IDs/qualities/quantities, the
   selected batch size, and whether concentration is enabled. Screenshots of
   the recipe and quoted concentration are useful; the tracer does not query
   or infer a pre-craft quote.
3. Perform the intended craft through the normal game UI. Mark the observed
   outcome, including visible output quantity, quality, and proc messages.
   Keep recording for several seconds after completion to retain late callbacks.
4. Stop, check `/al_trace status`, and inspect the export for `warnings`. Capacity
   stops and omitted payloads mean the affected evidence is incomplete, not
   evidence that the game omitted a field. Report these before proceeding.
5. Copy the complete Export block, or preferably preserve the entire
   account-wide SavedVariables file after `/reload` or a normal logout. If using
   the paged fallback, export every page, including the first with `TRACE_START`.
   Keep separate evidence copies for each controlled run before clearing.
6. Build 69933 traces now cover a basic result flow, concentration spend with
   `hasIngenuityProc = false`, Multicraft, and Resourcefulness (including
   multiple returned item IDs in one result). The newly verified Ogrim export
   supplies a successful Ingenuity result: proc true, concentration spent 323,
   refund 162. Preserve full attempt sequences for further testing; do not
   fabricate or manually inject a proc.
7. The supplied traces also cover consecutive same-recipe crafts and a
   two-operation concentration batch. Cancellation/interruption remains to be
   traced. Orders and actual recraft operations remain unverified and can be
   handled separately.

Normal logout or `/reload` writes WoW SavedVariables. A crash or forced kill can
lose the current session; this addon cannot force a disk flush. Reload pauses
capture and a new Start creates another metadata boundary. Do not use reload
mid-scenario unless testing that boundary intentionally.

The file is under
`_retail_/WTF/Account/<account>/SavedVariables/ArtisanLogbook_Core.lua` and contains
`ArtisanLogbookTraceDB`. This is account-wide, not a per-character file. Raw traces
can include character names, GUIDs, targets, hyperlinks, and order identifiers.
The claimed-order probe stores only an allowlisted diagnostic snapshot, not
full order names, GUIDs, notes, or hyperlinks. Review traces before sharing.
Preserve originals privately; label any sanitized copy and keep ID substitutions
consistent. Local `src/addon/traces/` is gitignored to reduce accidental
publication. Do not execute trace files received from others.

## What Is Captured

- `TRADE_SKILL_CRAFT_BEGIN`, item/currency result callbacks, and
  `UPDATE_TRADESKILL_CAST_STOPPED`.
- Player-only spellcast sent/start/success/stop/failure/interruption/delay and
  channel start/stop events. All supplied arguments are preserved by position.
- Profession open/close, crafting-details updates, currency-display updates,
  UI errors, and logout. Some are unrelated noise; no causal claim is made.
- Read-only `hooksecurefunc` post-hooks for `C_TradeSkillUI.CraftRecipe`,
  `CraftEnchant`, `CraftSalvage`, `RecraftRecipe`, and `RecraftRecipeForOrder`,
  if available. `CALL_POST:` records contain arguments only, not return values.
  Hooks may run after synchronous events and are **not** pre-craft snapshots,
  success signals, or necessarily one invocation per individual batch operation.
- While recording, `QUOTE_CALL_POST:` records the arguments to
  `GetCraftingOperationInfo` and `GetCraftingOperationInfoForOrder` when the
  client invokes them. `QUOTE_PROBE:` re-queries the same read-only API with
  those arguments immediately afterward, recording `status` (`ok`, `nil`, or
  `error`) and a nullable `info`. The secure post-hook cannot read the
  original return value. Re-querying may fail or differ from the UI's return;
  neither record proves which quote was displayed or accepted.
- While recording, each craft post-hook also emits a `REQUEST_PROBE:` record.
  For `CraftRecipe` calls with a supplied reagent table and explicit
  concentration boolean, this attempts `GetCraftingOperationInfo` (or
  `GetCraftingOperationInfoForOrder` for a supplied order ID) with the
  submitted arguments. `CraftEnchant` and `CraftSalvage` remain `unavailable`
  here until target-item GUID conversion is verified, to avoid capturing a
  misleading quote for the wrong target. The observation includes query status
  (`ok`, `nil`, `error`, `unavailable`, or `not-queried`) and the nullable
  `info`. Per-entry `reagentQuality` is queried by selected item ID when the
  API is present; nil quality is not zero quality. For an order ID,
  `GetClaimedOrder` is recorded only when its returned ID matches the submitted
  ID, and then only as an allowlisted snapshot of order ID, quality/commission,
  and reagent allocation/source data. Recraft calls have no recipe ID in their
  submitted arguments, so their operation quote is labeled
  `no-recipe-id-in-call`. These observations occur **after** the craft
  function; a synchronous result can precede them. They are diagnostic only and
  never update the ledger.
- Explicit `TRACE_START`, `TRACE_MARK`, and `TRACE_STOP` markers.

No operation IDs, cast GUIDs, recipe IDs, or callback payloads are rewritten.
Nothing is merged or deduplicated. Trace sequence numbers identify observations,
not crafts. Unrelated player spells remain visible during recording to avoid
filtering out evidence based on an unverified correlation rule. Recording does
not stop when the profession window closes or a cast ends.

## Runtime Findings: Retail Build 69933

The findings below come from the user's live Retail traces, with build `69933`
and version `12.1.0` in trace metadata. The raw SavedVariables attachment is not
committed because it includes personal and instance identifiers. The selected,
sanitized callback sequences are replayed by
[`tests/fixtures/retail-build-69933.lua`](../src/addon/tests/fixtures/retail-build-69933.lua).
Cast tokens are replaced with fixture-local placeholders; character/account
metadata, item-instance GUIDs, and hyperlinks are omitted. Recipe/item IDs and
operation IDs are retained as representative game data.

- **Result and request cardinality:** In the observed operations, one
   `TRADE_SKILL_ITEM_CRAFTED_RESULT` callback describes one actual result. A
   single `CraftEnchant` post-hook call with `count = 2` was followed by two
   `TRADE_SKILL_CRAFT_BEGIN` events and two result callbacks with distinct,
   non-zero `operationID` values. A durable craft fact represents one actual
   operation/result, not one button click or API request. In this build's
   traces, `operationID` is the leading identity/correlation candidate, not a
   universal guarantee: its scope, uniqueness duration, and behavior in other
   batch, late-callback, cancellation, and client-version cases remain unverified.
- **`itemGUID`:** The same output `itemGUID` appeared on two separate result
   callbacks for the same output item while their `operationID` values differed.
   Do not use `itemGUID` as craft identity or a uniqueness key. Keep it only as
   optional observed result metadata if a later use is established.
- **Spellcasts:** Spellcast events provide supporting timing/correlation
   evidence, but observed `UNIT_SPELLCAST_START` payloads differ: some contain a
   cast GUID in argument 2 and another observed shape omits it. The batch trace
   also shows why a spellcast token must not be the sole durable craft key.
   Preserve these callbacks as raw supporting signals; do not assume a stable
   one-to-one mapping to logical crafts.
- **`CRAFTING_DETAILS_UPDATE`:** One burst contained 127 consecutive events with
   no arguments (records 9-135) and no craft result in that interval. This event
   is too noisy for completion or craft correlation. It may later be used only
   to trigger a refresh of pre-craft state.
- **Concentration and Ingenuity:** In the observed two-operation batch, each
   result reported `concentrationSpent = 185`, `hasIngenuityProc = false`, and
   `ingenuityRefund = 93`. Currency updates showed a full 185 decrease for each
   operation. A positive `ingenuityRefund` is therefore not evidence that a
   refund was applied; it appears to be the amount available if Ingenuity
   procs. Never infer a proc from `ingenuityRefund > 0`. For applied-refund aggregation,
   use `ingenuityRefund` as the applied refund only when `hasIngenuityProc` is
   explicitly true; use zero only when the flag is explicitly false. If the flag
   is absent/unknown, applied refund is unknown. Net concentration is
   `concentrationSpent - actualRefund` only when both inputs are known. The
   newly verified Ogrim export supplies `hasIngenuityProc=true`,
   `concentrationSpent=323`, and `ingenuityRefund=162`, establishing a successful
   proc with an applied refund. A true flag without an observed refund amount
   counts as a proc but leaves applied-refund coverage unknown.
- **Multicraft:** A real result showed a normal output of 5 in one separate
   result and a Multicraft result with `multicraft = 10` and `quantity = 15`.
   The result payload directly exposes the Multicraft bonus and total output;
   bag-delta inference is unnecessary.
- **Resourcefulness:** Several result payloads contained `resourcesReturned`,
   including one result with three different item IDs and quantities. Treat
   those returned IDs and quantities as the authoritative observed return data.
   Attach each return to its reagent fact only when the input allocation makes
   attribution unambiguous. A craft may return multiple reagent types; no
   separate Resourcefulness fact is needed if reagent-level attribution remains
   sufficient. The fixture does not invent missing input-allocation facts.
- **Unknown versus zero:** Preserve observed zeroes as zero and unsupported or
   unavailable values as absent. Do not assign semantics to defaulted API values
   without runtime evidence. In particular, an absent proc flag is not the same
   as an observed false flag.

## Debug Format and Limits

`ArtisanLogbookTraceDB` holds `traceSchemaVersion`, `traceExportVersion`,
`nextSequence`, `records`, `bytes`, and optional `stoppedReason`.

Each record contains a monotonic observation `sequence`, server `timestamp`,
high-resolution client-uptime `elapsed`, event name, serialized argument
`payload`, and optional `warnings`. A `TRACE_START` contains the load's
`loginStartedAt`/`loginUptime`; elapsed times across loads must not be treated as
one continuous timeline. Clear preserves `nextSequence`.

Arguments use numeric keys plus `n = select('#', ...)`, preserving interior and
trailing nils. Values absent in the source stay absent; observed false and zero
are retained unchanged. Table snapshots are taken synchronously, so later
mutations cannot alter earlier observations. Ordinary table keys are serialized
in sorted order. Argument positions, rather than serialized key order, convey
the original argument order.

The debug export is a Lua table literal preceded by `return`, with argument
tables exposed as `arguments` rather than strings. It has independent trace
schema and debug export versions. The current trace schema is 2 and the current debug export version is 2; `totalRecords` is included for
checking page completeness. This is **not** the final `AL1` ledger contract.
There is no importer and no `loadstring` in the addon.

Expansion/era dimensions and their references belong to the separate durable
ledger schema, not this debug format. The tracer does not capture or infer item
or recipe expansion metadata; in particular, an item's metadata must not be
derived from a craft that consumes it. See
[implementation-plan.md](implementation-plan.md) for the planned dimension
direction. Unknown metadata remains absent until supported by game data and the
schema review.

Once 10,000 records are stored, a new trace cannot start until the evidence is
exported and cleared. A trace already in progress continues until stopped, even
if it exceeds that count; earlier evidence is never evicted. The displayed
byte total is a payload-plus-overhead estimate, not a limit or an exact
measurement of Lua heap or SavedVariables file size; long recordings increase
SavedVariables size and load/save cost. Existing trace schema-2 databases below
the count threshold can continue after reload and Start without clearing evidence.
Individual payloads have a 16 KiB serialized ceiling, 512 traversal-node budget,
eight-level depth limit, and 2,048-byte per-string limit. Cycles, restricted
values, unsupported types/keys, and limit violations are explicitly diagnosed
through `warnings` and `traceOmitted`/`traceRemainder` markers. These are debug
annotations, not measured values or substitutes for unknown craft facts. A
warning-bearing trace must not be used as complete evidence of absence.

Trace schema 1 used the older `exportContractVersion` name. Schema 2 renames it to
`traceExportVersion`; the loader migrates that exact schema-1 shape on a copy so
existing diagnostic records survive while the original SavedVariables table is
left untouched until initialization succeeds. Unsupported schema/export versions
or invalid top-level shapes are refused without overwriting the existing data.
Export/back up the SavedVariables file outside the game before resetting an
incompatible debug database. The durable ledger has its own versioned schema
and load contract; debug records still do not silently become ledger entries.

## Source Findings, Not Runtime Verification

Research baseline: [live UI mirror commit 09b9db7](https://github.com/Gethe/wow-ui-source/commit/09b9db7948abc9b9648dedaab51eb0cf3ee67b31).

- [TradeSkillUI event/API declarations](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua)
  declare craft begin with `recipeSpellID` and crafted results with a data table.
- [Crafting result structures](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua)
  include `operationID`, `quantity`, `craftingQuality`, `multicraft`,
  `concentrationSpent`, `ingenuityRefund`, and `resourcesReturned`. Returned
  resources contain a `reagent` (item or currency identifier) and `quantity`.
  These declarations do not prove reagent allocation/ownership attribution.
- The result declaration supplies default zeroes for several fields, including
  `operationID`. Raw API zeroes are retained as evidence, but cannot yet be
  interpreted as valid identities, measured zeroes, or supported capabilities.
- [Unit event declarations](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua)
  include optional `castBarID` and conditional secret payloads. The tracer uses
  `issecretvalue` where available and never attempts to bypass restrictions.

The shared flavor registry identifies known client families and dispatches a
registered adapter by project ID. It provides an empty capability fallback for
other clients, so core loading, manual markers, and saved evidence do not require
Retail. The Retail event/call adapter is the only implementation in this slice;
the capability `measurements` map remains empty because evidence findings have
not been turned into product capability declarations. Forever remains deferred
until its exact client/API is known. CraftSim and TSM are neither read nor
required.

## Evidence Register and Gate

`retail-build-69933.lua` is a sanitized replay fixture derived from the
user-supplied live trace. `retail-synthetic.lua` remains explicitly synthetic;
its example ordering and values do not establish game behavior.

| Scenario | Trace/build reference | Verified behavior |
| --- | --- | --- |
| Basic craft result flow | Build 69933, records 149-157 | Craft begin, call post-hook, spellcast callbacks, and result callback observed |
| Concentration without Ingenuity | Build 69933, records 168-184 | Two result callbacks with distinct non-zero operation IDs; spent 185 each, proc false, refund field 93, full currency decrease |
| Successful Ingenuity proc/refund | User-supplied Ogrim export findings | Proc true, spent 323, applied refund 162; non-proc positive refund remains potential only |
| Multicraft | Build 69933, records 158-164 | `multicraft = 10`, total `quantity = 15`; result field is directly available |
| Resourcefulness returns | Build 69933, records 195-236 | Returned reagent IDs and quantities observed, including three reagent types in one result |
| Consecutive crafts / batch | Build 69933, records 149-164 and 168-183 | Separate results have distinct operation IDs; one count-2 request produced two actual results |
| `CRAFTING_DETAILS_UPDATE` burst | Build 69933, records 9-135 | 127 empty-argument updates; not a completion/correlation signal |
| Cancellation / interruption | Not captured | Unverified |
| Crafting orders / actual recraft | Not captured | Unverified |

For each additional trace, record build, scenario/recipe, marker and sequence
ranges, observed outcome, identifier changes, callback ordering, and any loss
warnings. Continue checking repeated/late results, ID scope or reuse, and
batch/cancel interactions. Do not equate spellcast stop with success or assume
a fixed timing window.

For future capture-contract changes, reviewers should continue to verify:

1. The evidence-backed operation identity and completion rule, including
   `operationID` scope/uniqueness, repeated/late callbacks, and why distinct
   crafts cannot be merged.
2. Field sources, units, applicability, and unknown-versus-zero handling, with
   explicit limitations for any unavailable data.
3. How allocated reagents and returned reagents can be attributed, or what
   additional instrumentation/traces are required before making that decision.
4. Trace-backed replay fixtures, a supported-field matrix, and documented
   divergences from issue #2. No inferred facts should fill evidence gaps.

If the raw tracer is insufficient, extend this debug slice and collect another
controlled trace. Do not implement the durable ledger to paper over uncertainty.
The approved later work is recorded in [implementation-plan.md](implementation-plan.md).

## Issue #12: Request-side investigation and personal-craft evidence

The current [Retail API declarations](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua)
and [data types](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua)
(mirror build 69933) identify `CraftingReagentInfo` as
`{ reagent = { itemID? / currencyID? }, dataSlotIndex, quantity }`. For personal
crafts, selected items and amounts are observed in quote-call arguments, while
the craft post-hook reagent table may be empty. Coverage of mandatory/default
and customer-provided order reagents is not established. Quality can be queried with
`GetItemReagentQualityByItemInfo(itemID)`; a schematic's slot list and
`orderSource` are recipe definitions, **not** proof of selected input or
ownership. `CraftingOperationInfo` declares base/bonus skill and difficulty,
`craftingQuality`, `guaranteedCraftingQualityID`, `concentrationCost`, and
`concentrationCurrencyID`. For verified personal crafts, only observed
`baseSkill`, `baseDifficulty`, `craftingQuality`, and `concentrationCost` are
stored as optional request-side quotes; other fields and order/recraft meaning
remain unverified. None is substituted for actual result-side spend.

[Blizzard's transaction code](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_ProfessionsTemplates/Blizzard_ProfessionsTransaction.lua)
builds quote inputs from positive allocations with `dataSlotIndex` (not
`slotIndex`); the
[order UI](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_Professions/Blizzard_ProfessionsCrafterOrderView.lua)
can quote with customer-provided reagents but submit only non-customer
reagents. `GetClaimedOrder()` is a candidate source of order ID,
`customerName`, `tipAmount` (candidate commission), `minQuality`, and
per-reagent `source` (see
[order types](https://github.com/Gethe/wow-ui-source/blob/09b9db7948abc9b9648dedaab51eb0cf3ee67b31/Interface/AddOns/Blizzard_APIDocumentationGenerated/CraftingOrderUISharedDocumentation.lua)).
Order source enum values, claimed-order availability, and whether the
selected crafter inputs combine correctly with customer inputs remain
unverified. Personal recraft arguments include an item GUID, modifications,
and reagent list but no recipe ID; order recraft adds order ID. The
`GetItemSlotModifications` / `GetItemSlotModificationsForOrder` APIs may
explain prior item state; these are untested. No guessed provenance or
correlation is persisted.

**Personal-craft evidence gate completed (build 69933 / 12.1.0):** Quote-call
arguments expose positive selected allocations with slot, quantity, and item ID;
the `CraftRecipe` post-hook reagent table may be empty. A submitted count can
produce multiple result operations, or fewer results after a queued failure.
Quote concentration cost and actual spend may differ by one; `useConcentration`
is request intent, not spend. `resourcesReturned` item IDs matched selected
personal-craft inputs, but only unambiguous item mappings can be attributed.
The ledger (schema 2, migrated from schema 1 with its format identity marker) captures a
personal submission snapshot and links only reliably correlated successful
result callbacks. Return-only rows remain partial. `operationID` is not assumed to identify a
request, and no nearest-event/time-window correlation is used. Order/recraft
semantics and target-item GUID conversion still require live evidence; see
`storage-ledger.md` for the precise storage contract and experimental-format reset
requirements. The trace schema's own migration is independent and unchanged.

### Controlled live traces for remaining gaps

Install the instrumented ZIP as above. Back up the raw SavedVariables
privately, disable unrelated addons, work out of combat, and use a fresh
recording **per scenario**. Open the recipe first, then `/al_trace start`, mark
`scenario-before`, choose reagents and concentration, wait for the quote,
mark `scenario-click`, craft normally, mark `scenario-after`, and `/al_trace stop`.
If quote activity fills the 10,000-record limit, clear and restart
immediately before selection; report any capacity or payload warnings.
Preserve every export page or the raw SavedVariables after a normal logout,
including `TRACE_START` and build information. Note the UI-displayed
allocation/quality, concentration quote, batch count, result/procs, and
the sequence ranges of `QUOTE_CALL_POST`, `QUOTE_PROBE`, `CALL_POST`,
`REQUEST_PROBE`, craft begins, and individual results. Never share raw
order names, item GUIDs, cast tokens, or hyperlinks publicly.
The optional claimed-order probe stores only an allowlisted order snapshot
(for example ID, minimum quality, commission, and reagent source/allocation),
not customer/crafter names, GUIDs, notes, or item hyperlinks. Do not publish
the raw SavedVariables file anyway; other trace records can still contain
identifiers that require review before sharing.

1. Personal craft with explicit selected item IDs/quantities; repeat the
   **same recipe** using a different reagent-quality mix, with a new marker.
   Include at least one case with concentration off and one with it on;
   record the displayed quote and actual per-result spend independently.
2. Resourcefulness on a known allocation (including, if possible, multiple
   returned reagent types); keep the entire sequence until a natural proc.
   Compare returned item IDs against selected slots without bag-delta
   inference. Include a normal no-return result to distinguish absent
   returns from zero.
3. A count-2 or larger batch of the same recipe with a single click; mark
   before/after and retain **every** begin and result. If practical repeat
   with a changed allocation between separate requests. This is needed to
   test shared versus per-operation inputs and overlapping callbacks.
4. If available, a claimed crafting order with both customer and crafter
   supplies: privately retain the order UI's ID, requester, minimum quality,
   commission, and allocation/source display; capture quote and craft call
   separately, then sanitize stable placeholders before sharing. A personal
   recraft and an order recraft are separate optional runs; record item and
   modification context privately and sanitize GUIDs.

Do not turn a probe's `nil`/`error`, a secret/limit warning, or a missing
post-hook into an observed zero. Only after reviewing the complete live
sequences can request/result attribution, return matching, and a schema
migration be specified.
