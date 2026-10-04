# Production UI

`/al` and `/artisanlogbook` open the native Artisan Logbook window. Its three
tabs are Logbook, Recipes, and Settings. The draggable minimap book button
toggles the same window; its angle is stored in the UI addon's
`ArtisanLogbookUISettings`, not in Core. Core owns the separate `/al_trace`
capture tracer. Its raw export is diagnostic, not a portable craft export.

`ArtisanLogbook` is the user-facing UI addon and requires `ArtisanLogbook_Core`.
Core captures durable facts and exposes `ArtisanLogbookAPI`; the UI reads facts
only through that versioned API. Settings uses the separate
`ArtisanLogbookManagement` boundary for retention without accessing Core's
private namespace or SavedVariables. Destructive maintenance remains outside
the production window; confirmed database purge is on the debug tracer.

```text
ArtisanLogbook (user-facing product/UI)
   | RequiredDeps / public contracts
   v
ArtisanLogbook_Core (capture + durable facts + API)
```

Logbook has 30-, 90-, and 365-day ranges with character and profession filters.
Its UTC daily chart, four summary cards (crafts, concentration spent, Multicraft
bonus, most-crafted recipe), and newest-first craft history share the same
selection. Missing measurements are marked unknown or partially measured, not
counted as observed zero. The history fetches 40 factual crafts at a time as
the user scrolls. The chart and cards read durable daily series and survive
detailed craft pruning; the factual list does not reconstruct expired crafts.

Recipes has independent character and profession filters and name/count sort.
The catalogue loads 40 durable-count summaries at a time as the user scrolls.
Selecting a recipe opens observed outcome statistics (All time, Character: All
by default), a bounded chart and lazily loaded factual history;
craft rows open the same Craft Detail used by Logbook. Long labels are shortened
in rows with full values on hover. Craft Detail shows observed output, quotes,
and positive concentration, Multicraft, Ingenuity, and reagent-return activity
without implying unknown consumption. Class colors use the stored, optional
character class file token. For quality-bearing recipes, output-quality icons
come from the recipe-specific Blizzard quality metadata when available; missing
quality/scale data does not invent an icon. Craft timestamps use the game's local
display; historical aggregate filters and chart boundaries use UTC calendar days.

## Recipe Outcomes

Recipe Detail has All time, existing period presets, and Custom (UTC) dates.
For a custom period, enter `YYYY-MM-DD` from/through dates and press Enter;
the through date is inclusive in the UI and becomes an exclusive next-day API
bound. Invalid dates leave the last valid selection in place. Character defaults
to All and uses durable character choices, including characters whose details
have aged out. Chart, statistics, returned materials, and retained craft history
share the selection. The detail body scrolls independently of the native window.

- Multicraft: observed proc rate and numerator/denominator, coverage, bonus,
   output, and extra-output share when fully observed.
- Resourcefulness: any-return and currently non-trivial-return rates, each using
   its explicit coverage denominator. Non-trivial rates require complete-return
   coverage; legacy positive evidence alone does not prove an exact returned set.
   Multiple returned materials count
   once per craft. Partial calculations display Calculating, never a partial rate.
- Ingenuity: authoritative observed proc rate, coverage, applied refund, spent
   concentration, and refund/spend percentage when fully observed.
- Returned materials: per-item quantities, three at a time with Previous/Next;
   no total across different materials is presented as an interchangeable quantity.

Every reagent item can be marked/unmarked **Trivial** in the returned-material
list. Shared Craft Detail also provides a reagent selector and Trivial checkbox
for observed reagents. The preference is an item-ID-to-true set in
`ArtisanLogbookUISettings.trivialReagents`, with no built-in catalogue or value
service. Unmarking removes the preference. Changes immediately recompute the
recipe's historical interpretation, including pruned crafts; returning from Craft
Detail refreshes its recipe view. Preferences survive UI reload and Core history
clear/purge. Core facts and aggregates are never rewritten for classification.

The UI requests at most 60 chart buckets, processes 100 return sets per render
frame without retaining prior pages, and renders three material rows. The
native craft-history list remains 40-row lazy paging. Recipe Detail does not use
unbounded daily series or detailed-craft scans to calculate statistics.

Settings displays retained craft and daily-row counts, addon version, and the
retention setting. Saving retention applies pruning at the next startup. There
is no optional CraftSim/TSM integration.

## In-game validation

On a Retail character with crafting activity, verify:

1. `/al`, `/artisanlogbook`, the minimap button and Escape open/close the
   production window. Drag the minimap button and reload to check its position.
   `/al_trace` opens the Core tracer and works with the UI addon disabled.
2. Logbook's time, character, and profession filters update the chart, cards,
   and history together. Check an empty selection, missing measurements, and
   retained daily totals after factual detail pruning.
3. Recipes filters and sort affect the catalogue. Scroll well past 40 results,
   open a recipe, scroll its history, open a craft, and navigate back. Confirm
   long labels, tooltips, quality icons for different recipe quality scales,
   and class colors render correctly.
4. Open a profession with older tracked recipes missing `maxQuality`; confirm
   authoritative quality metadata fills in without resetting the logbook.
   Reload to verify that enrichment and the current character's class persist.
5. Craft with the window open and confirm live refresh; test both empty and
   aged-out factual history. Change retention and reload, then verify daily
   totals survive. Confirm purge remains in the debug tracer only.
6. Check window layering, minimap placement, scrolling, tooltips, dropdowns,
   and layout at common UI scales and resolutions, including beside other addon
   windows. Automated Lua mocks cannot establish these in-game behaviors.
7. In Recipe Detail, compare All time, Today, a custom UTC period (including a
   leap day and invalid date), and individual characters. Verify proc counts and
   coverage against known captured true/false/unknown outcomes. Check applied
   Ingenuity refunds rather than raw false-proc refund fields.
8. Mark a returned reagent trivial in Craft Detail and navigate back. Mark/unmark
   materials in Recipe Detail, including trivial-only, mixed, and multiple
   non-trivial returns. Verify each craft counts once and quantities do not change.
   Reload, prune detailed history, and repeat; clear Core history and verify UI
   preferences remain. Test long item names and return lists spanning several pages.

The #17 implementation is validated with Lua 5.1 integration mocks and package
checks in the container. Live Retail/Forever UI interaction, real font sizing,
taint behavior, and common in-game UI scales still require the checks above;
there is no WoW client in the development container. This change adds no game
API hooks or external calls: it consumes the existing guarded Retail capture
boundary and uses ordinary native UI controls outside protected gameplay actions.