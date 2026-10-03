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
Selecting a recipe opens a 365-day chart and lazily loaded factual history;
craft rows open the same Craft Detail used by Logbook. Long labels are shortened
in rows with full values on hover. Craft Detail shows observed output, quotes,
and positive concentration, Multicraft, Ingenuity, and reagent-return activity
without implying unknown consumption. Class colors use the stored, optional
character class file token. For quality-bearing recipes, output-quality icons
come from the recipe-specific Blizzard quality metadata when available; missing
quality/scale data does not invent an icon. Dates use the game's local display.

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