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
include recipe profession sorting/name search and reagent character/day filters
with selection-wide totals. Recipe summaries also accept day-aligned time bounds.
These remain read-only API v1 catalogue queries; capture and storage are unchanged.

## Pages and navigation

The shared **Craft type** selection defaults to All crafts, with Personal crafting,
Crafting orders and Patron orders. It persists across pages/reloads and applies to
craft activity, outcomes, rankings, ingredients and tooltip populations. Craft
tooltips and Craft Detail distinguish ordinary personal crafting from personal
orders; recrafting is independent. Craft Detail's Ingredients/Configuration tabs
inspect quote scope, stats, equipment, supported buffs and finishing selections
with explicit missing information. This does not add a configuration comparison UI.
Known configurations are never hidden or downgraded to satisfy a storage quota.
Missing configuration labels describe capture gaps or historically unavailable
data; aggregate-backed configurations remain available after detail pruning.
See [the in-game checklist](crafting-observations.md#in-game-verification).

The persistent dark sidebar contains Overview, Logbook, Recipes, Reagents, pinned recipes,
characters, and professions. Settings stays at the bottom, outside the scrolling
navigation population. Selected entries have a restrained gold highlight; long
names are shortened with full labels on hover. The main surface uses Blizzard
parchment, dark text, light ledger separators, native controls, and item/profession
icons. Character names retain class coloring where available.

The parchment has an opaque base beneath Blizzard achievement parchment artwork,
so transparent texture padding cannot expose the dark window under long tables.
The grain is blended at 16% opacity rather than stretched at full opacity.
Parchment text has no drop shadow; character text uses darker shades of its class
hue for contrast, while sidebar/dropdown/chat colors stay native. Section headings
on dark panels have an explicit light gold color. Dropdown widths include their
native end caps, text is left-aligned, and captions hide with their controls.
Compact navigation uses the native quest-title
highlight, and local views use `TabSystemButtonArtTemplate` with its selected-state
mixin and top-tab orientation. Activity charts include numeric gridlines and
date labels; most-crafted summaries use the recipe's artwork.

Recipe Detail belongs to the Recipes section: the primary Recipes entry stays
selected whether opened from the catalogue or a pin. A matching pin retains its
existing current-entry highlight without replacing the primary selection.

| Destination | Presentation and behavior |
| --- | --- |
| Overview | Period, character, and profession filters; craft activity bars; crafts, output, concentration, Multicraft, recorded Resourcefulness proc rate over all selected crafts, known returned material units, and most-crafted recipe. No factual craft list. |
| Logbook | Period/character/profession filters plus a multi-checkbox craft-visibility menu above a newest-first ledger. Show crafts from unknown recipes is disabled by default and applies to craft-history lists; enabling it includes unattributed crafts. Show hidden recipes includes hidden recipes in Logbook only. Recipe, Result, Character, Profession, Qty, Highlights. Exact timestamps remain in row tooltips. |
| Recipes | Period/character/profession filters, search/clear controls and most-crafted default sorting. Rich recipe rows include a Hide checkbox and always include hidden recipes within the selected filters. |
| Reagents | Parchment catalogue with item/quality cells, professions, recipe counts, Required units/Returned units/Materials saved columns and editable Ignore checkboxes. Materials saved shows a matched share or a dash; its tooltip gives the comparable-craft count. Item IDs live in native item tooltips, not row subtitles. |
| Character | Neutral helmet and class-colored identity, up to two icon-only profession links, summary, Overview and Craft History tabs. No profession labels or empty-slot placeholders; names are in tooltips. |
| Profession | Profession identity, summary, Overview and Craft History tabs. Full-width most-crafted table rather than a long page containing history underneath. |
| Recipe Detail | Identity, pin control, filters, summary, then attached Overview, Statistics, Craft History and Reagents tabs. |
| Reagent | First-class identity page with filters, summary, Overview, Used in Recipes and Craft History tabs. Ignore classification is synchronized with catalogue and Recipe reagent checkboxes. |
| Settings | Craft-history count, addon version, and Keep craft history (days). Saving applies pruning at the next startup. |

All entity pages follow Header, Filters, Summary, Tabs. Headers and filters stay
fixed; lists scroll inside bounded regions. Recipe Statistics has a bounded local
overflow region at short heights, not a whole-page scrollbar. Tabs share a native
border/backdrop with the content they control.

Summary metrics share one compact row, normally 80 UI units high, with light
separators and extra width for the most-crafted recipe. Reagents uses a shorter
60-unit row with bounded metric widths. Recovered space goes to charts and lists.
Most crafted remains clickable without a stretched glowing highlight. When its
latest crafted item is available, hover shows that item's native game tooltip.

Recipe Statistics includes total crafts/output/concentration, output per craft,
concentration per craft, net concentration, Multicraft proc rate/bonus/output share,
overall and Useful Resourcefulness rates over the same selected craft population,
returned material units, per-item matched savings and its sample count, and
Ingenuity rate/refund. Useful counts distinct durable return-set crafts containing
at least one non-ignored material. Both rates use the total craft count; the useful
numerator cannot exceed the overall proc numerator.
The three mechanics have peer headings. Summary tiles remain visible above every
tab; Ingenuity includes its proc percentage. Missing denominators leave a dash,
with a specific missing-result explanation when a rate cannot be calculated.

Recipe Overview defaults to the same 30-day period as Overview/Character/Profession.
Preset and custom graph bounds match the selected interval even when empty; All
time remains an explicit option. The Multicraft summary shows both proc percentage
and additional output as a percentage of total output, when measured.

For recipes with multiple quality levels, Overview includes an output-by-quality
table grouped by captured quality and output item ID. A worker processes at most
100 crafts per frame and restarts on filter/recipe changes. Unknown quality stays
separate. The table never fabricates a historical distribution: detailed craft
pruning can leave the durable total output intact while losing quality evidence.
The UI states how many crafts have a usable quantity/quality and the exact split
is also accessible from the Total output tooltip. Capture/storage are unchanged.

The shared craft table omits columns made redundant by its context. Recipe history
omits Recipe and Profession; Character history omits Character; Profession history
omits Profession. Result combines item and native quality artwork. Concentration,
Multicraft, Resourcefulness and Ingenuity all belong in icon-only Highlights,
even with only one proc; amounts remain in icon tooltips. When is a narrow two-line
local date/time outside Logbook; exact timestamps are always in craft-row tooltips.
Result/reagent item cells show `GameTooltip:SetItemByID` with a safe name fallback
when native item tooltip support is unavailable. Item hover preserves row clicks.

Most-crafted and catalogue recipe tables use the same rich component: Recipe,
Latest result, Crafts, Items, Multicraft, Resourcefulness, Ingenuity. Resourcefulness
is the count of saved result records with a known positive Resourcefulness return,
divided by all recorded crafts in the selection. Missing/unclear outcomes mean no
recorded proc for this display only; Core facts remain unchanged. This recorded
rate is not a claim about the true probability. A true zero is shown when no
positive proc was recorded; an empty selection is a dash. Small table samples show
a compact craft count, and tooltips give the numerator and total-craft denominator.
Overview, Character, and Profession summaries show the rate and the
positive-result numerator in the subtitle when space permits. Narrow Character
cards use a compact `procs / crafts` form and a shortened `Proc rate` heading
(`Proc` at very narrow widths); the tooltip names Resourcefulness and gives the
full counts. Useful Resourcefulness counts distinct durable return-set crafts
containing at least one non-ignored item and divides by the same total craft
population. Changing Ignore preferences affects only that useful numerator, not
overall Resourcefulness or Core facts. A return set contributes only when its
item identities can be classified against Ignore preferences; unclear membership
is not guessed. The result is
the latest available craft result for that selection, not an inferred quality
distribution. Rows and the Overview most-crafted tile open Recipe Detail.
Measured-zero Multicraft and Ingenuity cells are empty rather than `0.0%`.
Their exact zero/sample evidence is still in row tooltips; missing results are
not turned into measured zero.

Characters' two slots use `GetProfessions(characterKey)` across all available
history, independent of the period and profession activity filters. Only primary
professions occupy these slots, in the API's stable skill-line ID order. If
history spans profession changes, the first two appear; this is not an assertion
about currently learned professions. Slots do not show period-based craft counts.
All recorded professions remain available through filters and the account
sidebar. No remote-character portrait, race, level, or faction is invented.
When multiple professions have activity in the selected character population,
Crafts and Output replace their single numbers with per-profession lines, for
example `Alchemy: 55` and `Tailoring: 47`. Output uses the same selected population
and keeps absent quantities as dashes, with incomplete quantities explained in
tooltips. Single-profession selections return to one number. There is no separate
Crafts by profession line. Historical selections with more than three active
professions expand the summary just enough to fit the lines, keeping tabs bounded.
This is independent of the two primary-profession header icons. The Recipe output
quality table remains available without the redundant By quality below label.

Page filters and scroll positions are independent for the session. Character,
profession, and recipe destinations remember their own state when switching
identities; recipe-local views, reagent tables, and factual-history position
are included. Ordinary navigation does not discard loaded history. New data marks
cached pages stale and reloads lists in bounded batches while retaining position.
Profession metadata events refresh safely on the next frame. Page selections are
session state, not reload-persistent preferences.
When a committed craft has no established recipe identity, its chat notification
shows the recipe as Unknown. The recovery retry reminder appears once per addon
session and explains that unresolved attribution will be retried after `/reload`.

## Global Reagents catalogue

Reagents is a top-level sibling directly after Recipes, separate from Recipe
Detail's contextual Reagents view. Both use the standard parchment table. Clicking
a reagent opens the standalone Reagent page; Recipes and craft inspection can
navigate there too, and its recipe/craft lists link back into those workflows.
The first cell contains only item name and quality artwork. Item IDs are available
in native item tooltips; identical names and distinct quality IDs never merge.
Numeric columns are bounded, with useful profession/recipe associations beside
them. Missing artwork uses the question-mark fallback; quality is not invented.

Reagent icons and quality atlases use a UI-session-only cache keyed by item ID.
Resolved fields are reused across rerenders, filters, sorting, paging and
navigation. Missing fields stay unresolved without polling or retrying on every
render. A successful `GET_ITEM_INFO_RECEIVED` retries only the matching cached
item's missing fields; `TRADE_SKILL_LIST_UPDATE` retries unresolved quality
atlases when profession data updates. API errors retain safe fallbacks. Events
repaint only matching reagent cells, including mounted cells on a hidden page,
without re-querying aggregates or resetting filters/scroll. The cache is never
persisted or stored in Core, and contains no craft totals or trivial preferences.

Filters are Period (All time by default), Character, Profession, Savings statistics
(All, Ignored, Included), and literal case-insensitive name search. Search has
explicit search/clear buttons and Enter support, plus a short debounce. The typed
term does not change a paging query until applied. Name is the default reagent
sort; Most required, Most returned and Recipe count sort the full selection before
40-row lazy paging. Recipe catalogue defaults to Most crafted. Filters, rows and
scroll offsets survive navigation. No user-facing Prev/Next controls remain.

Header totals cover the complete filtered selection, not just loaded rows. The
Reagent page shows identity/professions, gross required and known returned
quantities, durable craft and recipe counts, matched saved share with its matched
craft count, recent crafters, recipe uses and craft history. Required quantities
are gross inputs before returns, not net consumed. Headline totals and saved share
come from `GetReagentSummaries`; the usage worker reads retained craft details only
for chart/history drill-down, at most 100 crafts per frame. Changing the selection
replaces pending calculations. Histories and recipe uses render 40 rows at a time.
Metadata events repaint item artwork without restarting aggregate queries.

The two-color chart compares **required quantities and returns on retained craft
details**, shown as Required and Returned, with at most 60 buckets and quantity/date
tooltips. These chart points and craft-by-craft recipe uses are retained-detail
views, not lifetime totals. The Saved column uses only Core's per-item matched
returned and required quantities from the same crafts; unavailable matched samples
stay unavailable. Gross returned and required totals are never divided together.
Duplicate input slots of one item are consolidated by Core before matched savings
are measured. Missing quantities never become zero. Pruned detail leaves durable
catalogue totals and matched savings intact without reconstructing craft histories.
Reagent Detail states how many available craft rows supply chart quantities and
return results; that retained-detail coverage is separate from its saved-share
sample, which uses the selected durable item-level comparisons.

Required sums gross known inputs before returns; it does not claim net consumption.
Returned sums known positive returns from any supported cohort. Exact quantities,
missing-data caveats, and matched sample details are in row/tile tooltips. There is
no cross-material savings percentage. Recipe/profession associations describe
recorded uses, not all game recipes capable of using the item.

Ignore in savings statistics is editable on the standalone Reagent page, Reagents
catalogue and Recipe Reagents tab. All three share `ArtisanLogbookUISettings.trivialReagents`
and synchronized checkboxes. Craft inspection remains configuration-free.
The checkbox tooltip explains that quantities and the overall
Resourcefulness rate do not change; it excludes this reagent from useful-savings
craft counts. Notifications update affected statistics immediately while preserving
list positions. Filtering by Included/Ignored happens
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

## Hidden recipes

Hide from lists is a UI-only preference stored as positive recipe IDs in
`ArtisanLogbookUISettings.hiddenRecipes`. Unlike pins, hidden recipes have no
five-entry limit. The Recipes catalogue always lists hidden recipes under the
current period/search/character/profession filters, so its Hide checkbox can
restore them. Recipe Detail uses matching Hide recipe / Show recipe and Pin recipe /
Unpin recipe buttons, with equal widths and an 8-unit gap. Its visibility button
stays synchronized with the catalogue checkbox.

Hidden recipes are omitted from most-crafted tables and the most-crafted tile,
and from Logbook, Character, Profession, Recipe and Reagent craft histories.
Reagent recipe-use lists also omit them. The active page refreshes immediately;
cached entity pages are invalidated, including per-identity history state.
Pins still work, hidden recipes remain inspectable via their catalogue/detail
pages, and hiding does not delete or rewrite crafts or change aggregate totals,
charts, reagent quantities, capture, migrations or Core API results. If every
recipe is hidden, the summary says No visible recipes rather than claiming no
crafts occurred.
Empty most-crafted tables say `No recipes in this period (N hidden)` when recipes
in the current population are hidden. N counts recipes, not crafts or all saved
hidden preferences. Periods with no matching activity omit the hidden suffix.

Filtering occurs in UI after bounded Core pages are fetched. An entirely hidden
page schedules continuation on the next frame, one page per worker update, so
later visible crafts remain reachable and no unbounded synchronous scan is
introduced. List scroll restoration and the existing in-place enrichment remain
intact. Core never reads the hidden preference and has no new hide API/filter.

## Craft Detail modal

Only individual crafts open modally. A full-screen dimmed shade blocks underlying
interaction; the originating page stays mounted with its selected filters, local
view, loaded rows, and scroll offsets. Close or the native X returns to that
exact page without rebuilding its list. A single Escape registration closes the
modal first; a second Escape closes the journal. Closing the main window also
cleans up the shade and modal.

The modal is inspection only. A prominent result row combines item, quality,
quantity and Multicraft contribution. Paired facts show character, timestamp,
concentration and outcomes. An Ingredients table shows `Reagent | Required |
Returned`, one row per ingredient. Required combines the recipe's requirement
and recorded selections for the same ingredient without adding them twice;
quantities from different recipe slots for the same item are added. When the
recipe allows several qualities and the one used wasn't recorded, the row uses
the plain reagent name (for example "Eversinging Dust") with the recipe total,
no quality badge, and the tooltip "The quality used wasn't recorded."; returns of
any of its qualities appear on that row. Quality badges appear only for a
specific recorded item. A dash means unknown; 0 means Resourcefulness was
recorded and returned none. Positive returns are lightly highlighted. Tooltips
are short sentences ("This recipe requires 2 Munsell Ink. The quality used
wasn't recorded.", "1 Sienna Ink was returned by Resourcefulness."); crafting
orders add that their materials don't count toward personal savings. A single
caveat, "Some ingredient details weren't recorded for this craft.", appears only
when an ingredient or required quantity is genuinely missing (for example older
crafts captured before the slot-index correction). Item rows open Reagent pages
after closing the modal; rows with an unrecorded quality do not.
Logbook Highlights list returns the same way ("1 Sienna Ink (2 required)").
Recipe and Reagent views use Required for the recorded quantity of that specific
item; Recipe Reagents notes ingredients that aren't listed by quality and shows
their recipe totals on hover.
There is no classification dropdown or duplicate metadata footer. No full-modal
scrollbar is required. Multiple output identities are not synthesized.

## Recipe and craft hover previews

The two images on issue #35 inform the grouped native `GameTooltip` layout:
gold titles and section headings, TSM-like light-blue labels, aligned label/value
rows, white ordinary values and contextual text, green observed positive outcomes,
and amber partial coverage. Gray is reserved for muted negatives and unavailable
data. Character names use their recorded class colors when class data is known.
Observed negatives say `No proc`; missing craft measurements say `Not recorded`.
Unavailable aggregate measurements say `Not available`, never a guessed zero.

Recipe rows, pinned recipe navigation, most-crafted tiles, recipe titles and
the non-item area of output-quality rows share the recipe preview. Period,
character and profession scope is applied to public API queries. A compact
period/character line describes the selection; profession is omitted from scope
when the recipe subtitle already identifies it, unless the selection differs.
Single-day ranges collapse to one date; cross-year ranges keep both years.
Character counts use durable daily history; missing identities are marked as
known-only counts. Last-crafted timestamps are explicitly retained-detail
timestamps, with a UTC last-craft-day fallback after details are pruned.
Multicraft and Ingenuity frequencies use their observed populations.
Resourcefulness uses only the authoritative cohort, with numerator/denominator
beside its rate (for example `31.8% (7/22)`). At most one short amber note gives
coverage and additional unverified positives (for example
`22/98 authoritative; +21 unverified procs`). Without an authoritative population,
known positives are evidence only, never a rate.
Extra output is an absolute measured bonus, not an unsupported base-output
percentage. Existing informational/statistics controls remain unchanged.

Craft rows, non-item Highlights and craft titles share a compact factual preview.
It shows the local timestamp, character/profession, output, quality, concentration
and procs. The output-name row is omitted only when its known name equals the
recipe title; produced quantity is always shown, and different or unknown output
identities remain explicit. Multicraft bonuses and applied Ingenuity refund
amounts remain visible. At most two returned materials are listed, with a remaining-item count
and an incomplete-return note where appropriate. No full ingredient table is
duplicated. Each public craft is one recorded result: different output records
from prospecting/crushing remain separate, never a fabricated combined output.

Concrete output/reagent/returned-item cells and output icons retain Blizzard's
native item tooltip, with a name fallback if item display fails. Item children
take precedence over parent summaries and continue propagating row clicks.
Owner-aware deferred leave handling restores a still-hovered parent; row reuse,
scrolling, hiding and refreshing clear owned stale content. Names are bounded
using the shared UTF-8-aware elision helper, and titles/subtitles allow native
wrapping. The presenter keeps normal WoW `ANCHOR_RIGHT` placement and explicitly
enables screen clamping, without custom positioning or scale overrides. Tooltip
content contains no nested interactive item targets.

In-game validation remains required: move repeatedly between row text, output
cells and Highlights, then between sibling items and outside the window. Verify
no flicker/stale tooltip on filtering, scrolling, modal close and window hide;
verify item quality/effects and click navigation. Inspect long names at the
smallest journal/UI scale, missing dimensions, legacy partial data, and multiple
output result rows. The four 2026-10-13 in-game screenshots guided the compact
scope, Resourcefulness note and duplicate-output refinements; validate the new
layout at each screen edge and at small UI scales. Mocks verify native anchor
and clamping calls, not actual geometry. They cannot validate font metrics, hit-testing,
asynchronous item loading, screen clamping, strata or taint.

## Measurements and bounds

- Every period control shares Today, 7/30/60/90/365 days and Custom dates. Recipe,
  Recipes and reagent pages also offer All time where their query supports it.
  Custom bounds are UTC `YYYY-MM-DD`; through is inclusive. Invalid input keeps
  the last valid query. Craft timestamps use the game's local display.
- `UI.Number` formats quantities with k/M/B and at most one decimal; percentages
  use one decimal. Summary and table amounts use ordinary numbers with exact
  quantities and missing-data caveats in tooltips. A dash denotes unavailable,
  never measured zero. Internal IDs are not abbreviated.
- FilterBar caps dropdowns at 176 UI units and wraps controls into aligned rows.
  Search, dropdown and custom-date controls share baseline/spacing conventions.
  Recipes sizes its four selectors and search together to fit on one line even
  at the minimum journal width. Search/Clear use matching native button frames.
- Multicraft shows absolute bonus output and its percentage of **total produced
  output**, never craft count. The percentage is omitted unless both quantities
  are observed for every selected craft and the denominator is positive.
- Ingenuity uses applied proc/refund semantics from #21, not raw refund values
  on false-proc records. Partial outcomes do not become measured zero.
- Resourcefulness presentation uses Core's positive-result count over total
  recorded crafts. Missing or unclear outcomes do not enter the UI numerator; this
  display convention does not change Core's authoritative/complete/raw populations
  or stored facts. Core's authoritative cohort remains the correct choice for an
  unbiased probability analysis; the gameplay-facing rate is a recorded-proc
  frequency. Useful Resourcefulness is counted from distinct durable return sets
  and uses the same craft denominator. Current capture suspension is shown only
  when Management.Status reports it; it adds no recovery control.
- Per-item saved shares use Core's same-craft matched returned and required
  quantities. A missing matched denominator is Unavailable, not zero. Required is
  gross input, not net consumption; craft detail displays item facts and input
  evidence without an aggregate material percentage.
- Unknown/partial Resourcefulness results retain #21's semantics. Useful
  Resourcefulness counts durable positive return sets with classifiable
  non-ignored items over the selected craft population; incomplete membership is
  not guessed and can make this count conservative after detail pruning. Missing
  result facts never become negative observations. Trivial preferences only
  change UI interpretation and never rewrite facts or aggregates.
- Charts render at most 60 date groups with daily/multi-day buckets. Daily-only
  data for Today renders a concise dated total, never invented hourly activity or
  a full-width bar. Bar widths are capped; reagent pairs stay close within a day
  with wider gaps between days. Chart scales and labels use shared formatting.
  Population charts use bounded daily series; recipes use the bounded outcome API.
- Return-quantity workers process one outcome query or one 100-item page per
  render frame. Non-trivial classification processes 100 sets/crafts per frame;
  recipe outcome/result enrichment advances one recipe per frame. All large
  history/catalogue/returned-item/recipe-use lists render 40 rows per load. No
  heavyweight UI framework or external service is introduced.

## Visual references and deviations

The primary visual
reference is the [latest four-view Recipe Detail mockup](https://github.com/Kralizek/ArtisanLogbook/issues/22#issuecomment-6012538079).
The [earlier six-screen mockup](https://github.com/Kralizek/ArtisanLogbook/issues/22#issuecomment-6012436186)
supplies context for the other pages and Craft Detail.

The [Reagents mockup](https://github.com/Kralizek/ArtisanLogbook/issues/22#issuecomment-6017262856)
informed earlier versions. The [third-round review](https://github.com/Kralizek/ArtisanLogbook/pull/23#issuecomment-6024413086)
and consolidated design-system review supersede its master/detail split, page
scrolling and inconsistent table/filter conventions. The 2026-10-09 follow-up
restores convenient inline Ignore checkboxes while retaining the standalone page.

[JourneyTracker](https://github.com/skittlenicks/JourneyTracker/blob/main/JourneyTracker/JourneyTrackerUI.lua)
informs the native composition: opaque parchment base plus achievement artwork,
shadow-free ink and quest-title selection highlights. Its layout/code is not
vendored. Tab compatibility was checked against Blizzard's current shared
`TabSystemTemplates.xml` / `TabSystemTemplates.lua`; mocks alone cannot establish
that an assumed legacy template exists in the client.

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
  outcome indicators are always icons with full tooltips, even for a single proc.
- Headers, filters and summaries stay fixed. Tables and the statistics overflow
  region scroll locally; the whole content pane does not. The journal scales down
  to fit smaller UI parents. There is no free-form resizer.
- All large lists use lazy internal scrolling. One captured output identity is
  shown per craft fact; additional resulting items are not synthesized.

## In-game acceptance checklist

The third screenshot round is the baseline for this redesign, not visual proof of
the redesigned screens. Automated tests cover state, bounded rendering and frame
geometry at short/tall sizes. A fresh live capture is required for every destination.

The full matrix below is **not yet performed**. Lua mocks cover state and data semantics,
not Blizzard asset rendering, font metrics, hit-testing, strata, or taint. There
is no WoW client in the development container. Capture actual screenshots of all
pages and the modal while performing this checklist.

- [ ] Open with `/al`, `/artisanlogbook`, and minimap; drag the minimap icon,
  reload, and confirm its location. Disable the UI addon and check `/al_trace`.
- [ ] Check 1280x720, 1920x1080, and 2560x1440 at 0.64, 0.8, and 1.0 UI scales.
  Inspect parchment, text contrast, dropdown labels, graph bars, native borders,
  and access to all controls without overlaps/clipped labels.
- [ ] Confirm parchment covers the entire viewport and all scrolled rows; inspect
  attached-tab selected states, shared table contrast, numeric scales and dates.
- [ ] Drag/raise the journal beside Blizzard profession windows and other addons.
  Verify the modal is above its shade, the shade blocks the page, tooltips and
  dropdowns remain usable, and closing leaves no invisible input blocker.
- [ ] Test many characters/professions and very long names. Scroll the sidebar to
  its last entry; Settings must remain accessible. Inspect selected/hover states,
  full-name tooltips, class colors, and missing metadata fallbacks.
- [ ] Test an empty account, an empty filtered population, no pins, and five pins.
  Pin/unpin from Recipe Detail, reject a sixth, change catalogue filters, navigate
  directly from a pin, reload, and verify alphabetical order and persistence.
- [ ] Hide/unhide recipes from catalogue and Detail. Recipes must keep listing
  them; both checkboxes synchronize. Verify every ranked/history list, hide all,
  hidden-only pages before a visible craft, switching cached identities, pins,
  reload, and more than five hidden recipes. Totals and saved Core facts stay fixed.
- [ ] Overview must have no craft list. Verify all filters, graph and totals,
  including complete, zero, unknown, and partial Multicraft/Resourcefulness data.
- [ ] Logbook must have no graph. Inspect Result item/quality and Highlights for
  concentration, Multicraft, Ingenuity and returned reagents, including narrow
  layouts. Load more than 40 rows; verify full tooltips and the end/empty states.
  Verify the 60-day range, no When column, exact timestamp tooltip, and native
  item tooltip over the Result cell without blocking the craft-row click.
- [ ] Verify catalogue default most-crafted sort, profession sort and name sort
  across multiple pages. Search for a recipe beyond the first 40 rows; change
  search while paging and return from Recipe Detail to the preserved selection.
  Recipes must remain selected throughout Recipe Detail, including pin navigation,
  pin/unpin changes, local recipe views, and Craft Detail modal return.
- [ ] Open the top-level Reagents destination directly after Recipes. Test no
  reagents, one reagent, identical names with different item/quality IDs, missing
  metadata, long names, multiple professions and more than 40 rows. Check identity,
  quality artwork, tooltips and row navigation at every UI scale.
- [ ] With uncached item metadata, verify fallback artwork initially, then live
  icon/quality enrichment after item info or profession metadata arrives. Filters,
  scroll and row quantities must not reset; repeat while Reagents is hidden and
  then return. Reload starts a fresh display cache without changing saved settings.
- [ ] Exercise every Reagents filter/sort across multiple pages, including search
  while scrolling. Navigate away/back and verify filters, rows and offset persist.
  Confirm allocations/returns display unknown and partial evidence honestly.
- [ ] Open different Reagent pages while usage loads; verify the final chart,
  recipes and history belong to the current item. Exercise shared custom periods,
  all tabs, navigation back, list restoration, incomplete rates and pruning.
- [ ] Toggle Ignore in savings statistics on a Reagent page. Verify immediate
  useful-savings recalculation, unchanged quantities/overall Resourcefulness rate,
  and a row leaving Trivial/Non-trivial selections. Reload to verify persistence.
  Prune a copy of history and verify durable returns remain without inventing
  missing allocation totals. Compare with the attached Reagents mockup.
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
  Verify the shared 30-day default, empty/preset/custom graph bounds, both
  Multicraft percentages, captured output-quality splits, unknown quality and
  explicit missing-quality coverage after pruning.
- [ ] Open Craft Detail from Logbook, Profession and Recipe History after scrolling.
  Inspect every outcome, multiple individual returns and the resulting item.
  Close with Close, X and Escape; verify the exact originating view and offsets.
  A second Escape closes the journal. Closing the journal while modal must clean up.
- [ ] Toggle Ignore from catalogue and Recipe reagent rows as well as the entity
  page; controls synchronize, filters may remove ignored rows, and quantities stay
  unchanged. Recipe and Craft Detail reagent names open Reagent pages; returning
  preserves filters and list positions. Craft Detail remains inspection-only.
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