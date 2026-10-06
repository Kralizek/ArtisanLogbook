# Production UI

`/al` and `/artisanlogbook` open Artisan Logbook. The draggable minimap book
toggles the same window. Its angle, recipe pins, and trivial-reagent preferences
belong to `ArtisanLogbookUISettings`, never Core. Core owns the separate
`/al_trace` diagnostic tracer; its raw export is not a portable craft export.

`ArtisanLogbook` requires `ArtisanLogbook_Core` and reads facts through
`ArtisanLogbookAPI` v1. Retention uses `ArtisanLogbookManagement`. The production
UI neither accesses Core's private namespace nor reads/writes its SavedVariables.
Confirmed destructive maintenance stays in the debug tracer. Storage, retention,
and the durable outcomes introduced by #21 are unchanged. Additive API changes
are `GetRecipeSummaries({ sort = "profession" })` and the read-only
`GetReagentSummaries(options)` catalogue query.

## Pages and navigation

The persistent dark sidebar contains Overview, Logbook, Recipes, Reagents, pinned recipes,
characters, and professions. Settings stays at the bottom, outside the scrolling
navigation population. Selected entries have a restrained gold highlight; long
names are shortened with full labels on hover. The main surface uses Blizzard
parchment, dark text, light ledger separators, native controls, and item/profession
icons. Character names retain class coloring where available.

Recipe Detail belongs to the Recipes section: the primary Recipes entry stays
selected whether opened from the catalogue or a pin. A matching pin retains its
existing current-entry highlight without replacing the primary selection.

| Destination | Presentation and behavior |
| --- | --- |
| Overview | Period, character, and profession filters; craft activity bars; crafts, output, concentration, Multicraft, returned reagents, and most-crafted recipe. No factual craft list. |
| Logbook | Independent period/character/profession filters above a dense newest-first ledger. Recipe, Character, Profession, Qty, and Highlights columns. Factual history loads 40 crafts per page as the user scrolls. |
| Recipes | The complete recorded-recipe catalogue, with independent character/profession filters. Name (default), profession, and most-crafted sorting happen before 40-row pagination. Selecting a row navigates to Recipe Detail. |
| Reagents | Global reagent catalogue and canonical trivial-preference management. Profession, trivial-state and name-search filters; name/allocated/returned/recipe-count sort; one row per item ID with artwork, known quality, recorded professions/recipe count, quantities and a Trivial checkbox. |
| Character | Neutral helmet icon and class-colored identity; period and optional profession filter, graph, production totals, five most-crafted recipes, and exactly two primary-profession slots. Empty slots say Not recorded. |
| Profession | Profession icon and identity; period and optional character filter, graph, production totals, five most-crafted recipes, and a lazy-loaded recent-craft ledger. |
| Recipe Detail | Identity, profession/expansion metadata when known, pin control, shared period/character filters, and four local views: Overview, Craft History, Statistics, Reagents. This is a main-content page, not a modal. |
| Settings | Retained-craft/daily-row counts, addon version, and retention days. Saving retention applies pruning at the next startup. |

Recipe Detail's **Overview** has a bounded activity graph and production tiles:
crafts, total output, concentration, Multicraft, reagents returned, and Ingenuity
refund. **Craft History** uses the factual ledger. **Statistics** keeps the #21
proc counts, coverage-aware percentages, and non-trivial return interpretation.
**Reagents** shows ten returned item identities per page, with quantities, item
IDs, icons, available Blizzard reagent-quality visuals, item tooltips, and
per-item Trivial checkboxes. Same-named item IDs remain separate.

Characters' two slots use `GetProfessions(characterKey)` across all available
history, independent of the period and profession activity filters. Only primary
professions occupy these slots, in the API's stable skill-line ID order. If
history spans profession changes, the first two appear; this is not an assertion
about currently learned professions. Slots do not show period-based craft counts.
All recorded professions remain available through filters and the account
sidebar. No remote-character portrait, race, level, or faction is invented.

Page filters and scroll positions are independent for the session. Character,
profession, and recipe destinations remember their own state when switching
identities; recipe-local views, material pagination, and factual-history position
are included. Ordinary navigation does not discard loaded history. New data marks
cached pages stale and reloads lists in bounded batches while retaining position.
Profession metadata events refresh safely on the next frame. Page selections are
session state, not reload-persistent preferences.

## Global Reagents catalogue

Reagents is a top-level sibling directly after Recipes, separate from Recipe
Detail's contextual Reagents view. It reuses the parchment ledger and thin
separators, with compact item/quality/profession artwork and no card grid.
Each row includes the item ID, so identical names and distinct quality IDs never
merge. Missing artwork uses the existing question-mark fallback; unavailable
quality is not invented.

Reagent icons and quality atlases use a UI-session-only cache keyed by item ID.
Resolved fields are reused across rerenders, filters, sorting, paging and
navigation. Missing fields stay unresolved without polling or retrying on every
render. A successful `GET_ITEM_INFO_RECEIVED` retries only the matching cached
item's missing fields; `TRADE_SKILL_LIST_UPDATE` retries unresolved quality
atlases when profession data updates. API errors retain safe fallbacks. Events
repaint only matching reagent cells, including mounted cells on a hidden page,
without re-querying aggregates or resetting filters/scroll. The cache is never
persisted or stored in Core, and contains no craft totals or trivial preferences.

Filters are Profession, Trivial state (All, Trivial, Non-trivial), and literal
case-insensitive name search. Search is briefly debounced without changing an
in-flight paging cursor. Name is the default sort; Most allocated, Most returned
and Recipe count sort descending across the entire selection before 40-row lazy
paging. Filters, loaded rows and scroll offset survive navigation away and back.

Allocated sums retained craft allocations only. Returned sums existing durable
positive return facts without double-counting retained rows. The footer states
the different scopes. Unknown quantities say Unknown rather than zero; known
amounts with incomplete coverage are marked partial. Full cell values and item
identity are available on hover. There is no return percentage. After detail
pruning, returns remain but allocation-only identities may disappear and
allocations/quality may become unknown; no new historical allocation store is
introduced. Recipe/profession associations describe recorded uses, not all game
recipes capable of using the item.

The checkbox writes only `ArtisanLogbookUISettings.trivialReagents`, the same
item-ID preference used by Craft Detail and Recipe Detail. Those contextual
controls remain. A UI-only change notification synchronizes controls and
invalidates/restarts relevant Resourcefulness classification immediately,
preserving recipe material pagination. Filtering by Trivial/Non-trivial happens
before pagination via generic included/excluded item IDs passed to Core; Core
has no knowledge of UI classification. A toggled row may leave the current
filtered population. Quantities are unaffected by classification.

This page contains no TSM, inventory, valuation, or Warband Bank integration.

## Pinned recipes

Up to five recipes can be pinned/unpinned from Recipe Detail. Pins are sorted
alphabetically by name, with recipe ID as a deterministic tie-breaker; there is
no manual ordering. A sixth pin is rejected without replacing an existing pin.
Pins use `ArtisanLogbookUISettings.pinnedRecipes`, keyed by recipe ID, with a small
copy of known display metadata. They survive reload, pruning, and Core history
clear. Sidebar navigation is independent of catalogue filters and still works
when factual detail has expired. Newly committed metadata can refresh a pin.

## Craft Detail modal

Only individual crafts open modally. A full-screen dimmed shade blocks underlying
interaction; the originating page stays mounted with its selected filters, local
view, loaded rows, and scroll offsets. Close or the native X returns to that
exact page without rebuilding its list. A single Escape registration closes the
modal first; a second Escape closes the journal. Closing the main window also
cleans up the shade and modal.

The modal shows recipe/output artwork, character, timestamp, quantity, quality,
concentration, Multicraft, Ingenuity, and Resourcefulness. Returned reagents are
individual rows with identity, quality when known, and quantity. Resulting item
identity/quantity are separate. Recipe, realm, expansion, craft ID, and available
request count/concentration quote remain accessible below. A reagent selector
and Trivial checkbox retain #21's reversible classification behavior. Changing
that preference refreshes recipe statistics on return without resetting history.

## Measurements and bounds

- Aggregate periods use UTC calendar days: Today, 7, 30 (default), 90, and 365
  days. Craft timestamps use the game's local display. Recipe Detail also offers
  All time (default) and Custom (UTC); enter `YYYY-MM-DD` from/through dates and
  press Enter. The through date is inclusive in the UI. Invalid input leaves the
  last valid filter in place.
- Multicraft shows absolute bonus output and its percentage of **total produced
  output**, never craft count. The percentage is omitted unless both quantities
  are observed for every selected craft and the denominator is positive.
- Ingenuity uses applied proc/refund semantics from #21, not raw refund values
  on false-proc records. Partial outcomes do not become measured zero.
- Resourcefulness quantities sum durable returned-item facts. Partial positive
  amounts are labeled with missing details. No returned quantities with incomplete
  coverage display a dash; complete known zero displays zero. Lifetime pages do
  not show returned/allocated percentages because the durable APIs do not expose
  a complete allocation denominator. Proc percentages remain distinct and require
  the existing full-population coverage guarantees.
- Craft Detail may show returned quantity as a percentage of **allocated reagents**
  only with a complete result, all per-reagent allocations/returns known, a positive
  denominator, and no returned amount exceeding its allocation. It is not a
  consumption percentage or a percentage of output.
- Unknown/partial Resourcefulness results retain #21's semantics. Non-trivial
  savings combine complete durable return sets with known positive returns on
  retained partial-result crafts, without double counting. Missing result facts
  never become negative observations. Trivial preferences only change UI
  interpretation and never rewrite facts or aggregates.
- Charts render at most 60 bars, with multi-day buckets for longer periods and
  date/count tooltips. A one-day population still has a visible bar when nonempty.
  Population graphs read date-bounded daily series. Recipe charts use the bounded
  outcome API, not an unbounded daily-series request.
- Return-quantity workers process one outcome query or one 100-item page per
  render frame. Non-trivial classification processes 100 sets/crafts per frame;
  recipe reagent tables render ten rows per page. History and catalogue requests remain
  40-row pages. No heavyweight UI framework or external service is introduced.

## Visual references and deviations

Issue #22 was read with both comments before implementation. The primary visual
reference is the [latest four-view Recipe Detail mockup](https://github.com/Kralizek/ArtisanLogbook/issues/22#issuecomment-6012538079).
The [earlier six-screen mockup](https://github.com/Kralizek/ArtisanLogbook/issues/22#issuecomment-6012436186)
supplies context for the other pages and Craft Detail.

When the top-level Reagents page was requested, the issue still exposed only
those two comments/images, not a separate Reagents mockup. With direction to
proceed autonomously, the page follows the existing Recipes catalogue reference
and the requested ledger columns. Comparison with the missing page-specific
image remains part of the next review; no exact visual match is claimed.

The implementation follows the sidebar/parchment proportions, ledger density,
local recipe views, and native item artwork, but deliberately differs where the
illustrations exceed recorded facts:

- No invented quality distributions, donut charts, quality filter, acquisition
  source, current character level/race/faction, or profession skill progress.
  Those distributions and fields are not exposed by the durable public APIs.
- No "different crafters" tile. Its space is used for production/refund and
  returned-material information. Mockup percentages based on output for reagent
  returns are not reproduced.
- Pins remain alphabetical despite the illustrated manual-looking order. Pinning
  is on Recipe Detail rather than a separate catalogue-row control.
- Native controls and textures replace the generated ornate border work. Dense
  outcome indicators collapse to icons with full tooltips when space is limited.
- Data-heavy pages and Craft Detail scroll at shorter window heights rather than
  shrinking text or discarding facts. The journal scales down to fit smaller UI
  parents. There is no free-form resizer.
- Factual history is lazily scrolled rather than numbered pages; returned materials
  retain bounded Previous/Next paging. One captured output identity is shown per
  craft fact; additional resulting items are not synthesized.

## In-game acceptance checklist

These checks are **not yet performed**. Lua mocks cover state and data semantics,
not Blizzard asset rendering, font metrics, hit-testing, strata, or taint. There
is no WoW client in the development container. Capture actual screenshots of all
pages and the modal while performing this checklist.

- [ ] Open with `/al`, `/artisanlogbook`, and minimap; drag the minimap icon,
  reload, and confirm its location. Disable the UI addon and check `/al_trace`.
- [ ] Check 1280x720, 1920x1080, and 2560x1440 at 0.64, 0.8, and 1.0 UI scales.
  Inspect parchment, text contrast, dropdown labels, graph bars, native borders,
  and access to all controls without overlaps/clipped labels.
- [ ] Drag/raise the journal beside Blizzard profession windows and other addons.
  Verify the modal is above its shade, the shade blocks the page, tooltips and
  dropdowns remain usable, and closing leaves no invisible input blocker.
- [ ] Test many characters/professions and very long names. Scroll the sidebar to
  its last entry; Settings must remain accessible. Inspect selected/hover states,
  full-name tooltips, class colors, and missing metadata fallbacks.
- [ ] Test an empty account, an empty filtered population, no pins, and five pins.
  Pin/unpin from Recipe Detail, reject a sixth, change catalogue filters, navigate
  directly from a pin, reload, and verify alphabetical order and persistence.
- [ ] Overview must have no craft list. Verify all filters, graph and totals,
  including complete, zero, unknown, and partial Multicraft/Resourcefulness data.
- [ ] Logbook must have no graph. Inspect Highlights for quality, output,
  concentration, Multicraft, Ingenuity and returned reagents, including narrow
  layouts. Load more than 40 rows; verify full tooltips and the end/empty states.
- [ ] Verify catalogue default name sort, profession sort and most-crafted sort
  across multiple pages. Open a recipe and return to the preserved catalogue.
  Recipes must remain selected throughout Recipe Detail, including pin navigation,
  pin/unpin changes, local recipe views, and Craft Detail modal return.
- [ ] Open the top-level Reagents destination directly after Recipes. Test no
  reagents, one reagent, identical names with different item/quality IDs, missing
  metadata, long names, multiple professions and more than 40 rows. Check identity,
  quality artwork, tooltips and row checkbox hit areas at every UI scale.
- [ ] With uncached item metadata, verify fallback artwork initially, then live
  icon/quality enrichment after item info or profession metadata arrives. Filters,
  scroll and row quantities must not reset; repeat while Reagents is hidden and
  then return. Reload starts a fresh display cache without changing saved settings.
- [ ] Exercise every Reagents filter/sort across multiple pages, including search
  while scrolling. Navigate away/back and verify filters, rows and offset persist.
  Confirm allocations/returns display unknown and partial evidence honestly.
- [ ] Toggle Trivial globally and in both detail views. Verify shared checkbox
  state, immediate non-trivial Resourcefulness recalculation, unchanged quantities,
  and a row leaving Trivial/Non-trivial selections. Reload to verify persistence.
  Prune a copy of history and verify durable returns remain without inventing
  missing allocation totals. Compare with the Reagents mockup when supplied.
- [ ] Visit characters with 0, 1 and 2 recorded primary professions, including
  secondary professions and historical profession changes. There must never be
  more than two primary slots or an invented portrait. Test per-character filters.
  Switch periods where one profession has no crafts, then an empty period: the
  slots stay unchanged while the chart, totals, and most-crafted recipes update.
- [ ] Visit professions across characters; verify graph, aggregate figures, top
  recipes and recent crafts. Navigate to recipes and back without losing state.
- [ ] Inspect every Recipe Detail view. Test All time, Today, 7/30/90/365 days,
  individual characters, valid custom dates, leap days and invalid dates. Switch
  recipes and return; selected view, filters and list/material positions persist.
- [ ] Open Craft Detail from Logbook, Profession and Recipe History after scrolling.
  Inspect every outcome, multiple individual returns and the resulting item.
  Close with Close, X and Escape; verify the exact originating view and offsets.
  A second Escape closes the journal. Closing the journal while modal must clean up.
- [ ] Mark/unmark trivial materials in Recipe Reagents and Craft Detail, including
  mixed/trivial-only returns and several reagent pages. Quantities stay unchanged,
  each craft counts once, and returning from Craft Detail keeps history position.
- [ ] Craft while the journal is open, including while a modal covers a scrolled
  list. Verify safe sidebar refresh, delayed metadata enrichment, and updates on
  subsequent navigation without lost filters or fabricated values.
- [ ] Change retention and reload/prune a copy of history. Durable totals, returned
  quantities and pins survive; expired factual crafts are not reconstructed. Clear
  Core history via confirmed debug maintenance and verify UI preferences survive.

The pre-#21 migration replay caveat remains unchanged: the previously supplied
untouched SavedVariables was content-audited, not fully replayed through
`Ledger.New`. Its denominator differs from the later screenshot. Full replay,
reload idempotence, pruning, and repair checks on a **copy** of that untouched
file remain outstanding; this UI redesign does not change migration rules.

## Automated validation

From the repository root, run `bash src/addon/scripts/package.sh`. It runs all
trace, adapter, ledger, API and UI integration tests, stages both addons, checks
TOC/dependency/SavedVariables boundaries, builds three archives, and checks their
contents and integrity. For the focused UI suite:

```sh
lua5.1 src/addon/tests/addon_test.lua src/addon/src/ArtisanLogbook_Core src/addon/src/ArtisanLogbook
```

Navigation tests cover independent filters, entity/recipe view state, lazy pages,
modal return and Escape, zero/one/two profession slots, pins/limits/persistence,
and outcome coverage. API tests exercise global profession ordering across page
boundaries and after retention. These are behavioral tests, not visual approval.