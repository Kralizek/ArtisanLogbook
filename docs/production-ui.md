# Production UI

`/al` and `/artisanlogbook` open the native Artisan Logbook window. Its five
tabs are Overview, Recent, Character, Profession and Recipes. The minimap book
button toggles the same window. Core owns the separate `/al_trace` capture tracer;
its raw export is diagnostic, not a portable craft export.

`ArtisanLogbook` is the user-facing UI addon and requires `ArtisanLogbook_Core`.
Core captures durable facts and exposes `ArtisanLogbookAPI`; the UI reads facts
only through that versioned API. Settings uses the separate
`ArtisanLogbookManagement` boundary for retention and confirmed deletion,
without accessing Core's private namespace or SavedVariables.

```text
ArtisanLogbook (user-facing product/UI)
   | RequiredDeps / public contracts
   v
ArtisanLogbook_Core (capture + durable facts + API)
```

Overview charts UTC daily craft counts from durable series for the selected 30,
90 or 365 days, character and profession. Its compact cards show crafts,
concentration spent/net, Multicraft bonus and most-crafted recipe **within the
selected chart range**. They no longer show lifetime totals; this keeps both
the chart and cards bounded as durable history grows. Week-over-week
craft and fully observed additive-measure comparisons use the latest seven
complete UTC days against the preceding seven. Month-over-month compares the
current UTC calendar month through today with the same number of calendar days
at the beginning of the previous month (capped at that month's length). These
comparisons remain independent of the selected chart range, and read only their
bounded comparison window.
Partial measurement coverage is shown, not treated as zero. Net concentration
is shown only when spent and applied refund are observed for every craft.

Recent uses newest-first, ten-craft cursor pages with time, character and
profession filters. Character initially selects the active character; Profession
initially selects that character and its first primary profession in game order
when available. Tracked-data alphabetical order is the fallback for historical
characters without game ordering. Both tabs reuse the chart, history and Craft
Detail, and selectors remain navigable. Recipes uses a bounded alphabetical
catalogue of durable craft counts. Recipe Detail has a filtered chart and craft
history; every craft row uses the same API-backed Craft Detail. Dates in Craft
Detail use the game's local date display. Unknown and measured zero/false are
displayed distinctly.

Settings is secondary to the five tabs. It shows retention, counts, current
capture capabilities and build diagnostics. Save changes the retention setting;
Prune applies it immediately to detailed facts, without erasing daily totals.
Clear requires confirmation and removes both detailed facts and durable totals.
There is no production portable-export contract yet; the tracer export is not
presented as one. No optional CraftSim/TSM integration is provided.

## In-game validation

On a Retail character with crafting activity, verify:

1. `/al`, `/artisanlogbook`, the minimap button and Escape open/close the
   production window. `/al_trace` opens the Core tracer and works with the
   UI addon disabled.
2. All five tabs and Settings fit the UI scale. Dropdowns and craft rows respond
   correctly; long recipe/item/character names do not overlap adjacent columns.
3. Overview chart changes with each time, character and profession choice.
   Verify card totals and most-crafted recipe follow the display range while
   WoW/MoM comparisons do not. Compare daily counts against recorded crafts, including
   unknown measurements and a true Ingenuity refund.
4. Recent stays newest-first, filters and pages forward/backward, and never
   shows a timestamp column. Craft Detail shows exact time, request quotes,
   observed zero/false, reagents/returns and unknowns accurately.
5. Character starts at the logged-in character and can switch to another;
   Profession selects the first game-ordered primary profession and allows
   switching between two professions and tracked characters. Histories and
   charts match the chosen scope.
6. Recipes is alphabetical with durable counts. Recipe Detail's chart remains
   after detailed pruning while its factual history empties; craft rows open
   the same Craft Detail.
7. Open a filtered view, craft again and verify live refresh. Test an empty
   ledger and aged-out detail with remaining daily totals.
8. Change retention, prune, and cancel then confirm Clear. Verify that Clear
   removes totals, does not erase debug tracing, and subsequent crafts record.
9. Verify window size, line rendering, scrollable long detail, tooltip,
   dropdown choices and frame behavior at common UI scales/resolutions.