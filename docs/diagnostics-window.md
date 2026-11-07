# Core diagnostics inspector

`/al_debug` toggles **Artisan Logbook - Diagnostics**. Enable Core; neither
production UI nor Tracer is required. This is a read-only developer tool, not
another crafting UI. It works alongside `/al_trace` and does not replace `/dump`.
It does not repair recipes, clear history, modify retention, change
classifications, submit crafts, or register diagnostic observers.

## Placement and lifecycle

The inspector lives in Core's `Diagnostics/` directory. Two small Lua modules
register the slash command at load time, but create **no UI frames** until the
first toggle. Subsequent toggles reuse the same window. This avoids another
addon/package/deployment selector and avoids a Core dependency on Tracer. The
font, multiline EditBox, scroll-child and cursor-following patterns follow
Tracer's compatible window, but there is no shared dependency or production UI
import. All controls use plain frame primitives, not Blizzard UI templates.

The explicit read allowlist is `GetCapabilities`, `GetDiagnostics`, `GetCrafts`,
`GetCraft`, `GetSessions`, and `GetSession`. API responses are detached projections,
not ledger globals. Sessions is a small additive public read API because no
session query existed; craft projections now expose their local `sessionId`.
The persistence schema remains 5. Capability responses additionally expose copied
Core event, hook and declared-measurement flags; these are not Tracer flags.

Opening, section selection and **Refresh** query only the relevant read API.
No APIs are polled on a timer or every frame. While a raw page is being prepared,
a temporary `OnUpdate` handler advances a bounded formatter coroutine; it stops
when the page is available or the window closes. It never reads capture state.

## Controls

- Drag the title bar to move; drag the visible lower-right grip to resize.
  Initial/minimum sizes are 840 x 640 / 620 x 500 UI units, bounded by the screen.
  The frame is clamped to the screen. Native resize bounds are preferred;
  older min/max resize methods are a fallback.
- **X**, Escape, or `/al_debug` closes the window.
- **Capabilities** shows detected flavor, available readiness/correlation flags,
  capture paths and declared mechanics. `false` means unavailable for that flag;
  `nil` means the API did not declare it. Unsupported Forever mechanics are
  expected, not capture errors. **Raw View** includes registered events and hooks.
- **Diagnostics** shows capture/observer errors, unsupported request reasons,
  ambiguity, and recipe/output knowledge status. Raw View includes every returned
  field, including cached repair analysis and recovery details. Inspection does
  **not** run analysis, discovery or repair.
- **Crafts** queries twelve records per page, newest first. Click the first row
  to inspect the latest craft. Details show recipe/output, timestamp, request,
  session, input completeness and outcome source when available. Raw View includes
  the complete returned craft, including reagent facts, reagent requirements,
  output observations and the correlated request's fixed/selected reagents.
  No missing persisted fields are reconstructed. **Craft session** opens that
  record's session through `GetSession`.
- **Sessions** shows twelve sessions per page, newest local session ID first,
  and identifies the current session. Select a row for client/build/interface,
  addon version and saved identity/capture capabilities. Historical capabilities
  are the creation-time snapshot, not current capture health.
- **Back** returns from a detail record or to the previous data page.
  **Next records** follows the API cursor; it does not render the entire history
  as widgets. Select Crafts or Sessions again to return to the newest page.
- **Raw View / Summary** switches display without requerying the API.
  **Refresh** requeries the selected response or record, including the current
  data page. Empty results and API failures have visible messages. A stale cursor
  after history changes is not silently retried against different data; reselect
  the section to start a fresh page sequence.
- Mouse wheel or the vertical scrollbar scrolls the text independently of chat.
  Resizing reflows the text and bounded record buttons.

Position and size are saved **only after moving/resizing**, in the separate
`ArtisanLogbookDebugSettings` SavedVariable in Core's settings file. They are not
ledger facts, not production UI settings, and contain no diagnostic snapshots.
Invalid dimensions are bounded/defaulted. Opening the inspector does not write
preferences. Existing Core/Tracer data is never cleared or overwritten by export.

## Raw formatting and copy/export

Raw text is deterministic: numeric, string, then boolean keys, ordered within
each kind; nested tables are indented. Nil, booleans, numbers and quoted strings
remain distinct. Cycles have explicit markers. Functions/userdata/threads are
represented by type markers, never executed or coerced via metamethods.
Secret/inaccessible values and non-scalar keys are marked, not traversed.
No Lua evaluator or arbitrary callable API is exposed.

**Copy** focuses/selects the complete displayed text page. Press **Ctrl+A**, then
**Ctrl+C**, and paste into an external editor. Addons cannot write directly to
the OS clipboard. The text box rejects edits to the inspected display; it does
not write changes back to the response. This does not prevent selecting/copying.

**Export** switches to the raw representation of the currently selected response
or detail record. Use Copy, then **Text >**, and repeat for every text page.
Paste the pages in order **without adding separators**. **< Text** revisits
previous chunks. The status shows the text page number and whether more remains
(`+` while the formatter has not reached the end). Data-page navigation and
text-page navigation are separate. To inspect/export older crafts or sessions,
return to their list and follow Next records; a paged API response is not the
entire ledger. There is no automatic full-history export or persistent duplicate.

Each EditBox chunk is at most **12,000 ASCII bytes**, independently of window
height and chat limits. String control bytes, backslashes, quotes, WoW pipe markup,
and non-ASCII bytes use reversible escapes (`\n`, `\\`, `\"`, `\ddd`). This preserves
the original byte values without executing links/colors/textures. Unicode names
therefore appear as escaped UTF-8 bytes in this diagnostic representation.
Pages may split an escape sequence; concatenate them before analysis.
This is human-readable diagnostic evidence, **not** the portable ledger export
format, Tracer's trace schema, or guaranteed executable Lua.

For exceptional responses, limits are explicit: depth 12, 5,000 examined keys
per table, 50,000 visited values, and approximately 1.5 MB formatted output.
Limits produce visible text notices and a LIMIT status; such an export is not
complete. Select a single craft/session rather than a large page to narrow it.
Normal large strings/tables span pages rather than being cut off by the visible
height. A table exceeding the safe key budget is represented by a notice, not
silently represented as empty. Core history remains accessible through API
record pages regardless of these per-response display limits.

## Compatibility and manual acceptance

Targets: Retail and Forever **1.60.1.70862 / interface 16001**. Selected source
pins are Gethe/wow-ui-source Retail
`297d7aaaa736f346b3e036f38ee088eaf7f8c07f` and Forever
`9dc84f0d3bbae1768ac3405b3716000bd93eda06`.
Generated widget declarations confirm resize bounds, multiline text and selection
methods; unprotected, addon-created primitive frames avoid Blizzard-template
dependencies. Optional secret/access predicates are guarded before inspection.
Declared method presence and mocked tests do not certify actual addon access,
clipboard behavior, visual layout, combat interaction or client performance.

Automated checks cover both Core flavors, lazy/reused frames, template-free UI,
API failures, deterministic/typed output, cycles/depth/size/access limits,
record/text paging, copy/export, scroll/resize, session snapshots, immutable ledger
inspection and coexistence with the actual Tracer. Full addon regressions and
both flavor package checks must pass.

Live-client and UIForever visual validation have **not been run**. The simulator
requires importing addon code into a third-party site; that transfer was not
performed. A live acceptance session is still required on both clients:

1. Deploy Core (`-Flavor Forever -Addon Core` for Forever), leave production UI
   and Tracer disabled, reload, and confirm `/al_debug` opens once without errors.
2. Drag, resize to the minimum, scroll, and close/reopen using the command,
   Escape and X. Confirm no chat spam. Move/resize and reload to check geometry.
3. Read Capabilities and Diagnostics. On Forever, unsupported mechanics should
   be false/unavailable, not errors. Check raw events/hooks and cached repair state.
4. Craft one supported item. Select Crafts again, open the newest row, and inspect
   Raw View's reagents/request, input completeness and provenance. Open Craft
   session and confirm client/build/flavor. Reload and find the saved craft again.
5. Copy a record and diagnostics; test all chunks of a large response and older
   data pages. Paste into a local editor and verify no missing/doubled chunk.
6. Enable Tracer, record a session, and open both windows; confirm capture and
   observer integration continue unchanged. On Retail, repeat with production UI.
7. Check smaller viewports/UI scales, long names, focus/scroll behavior, and safe
   operation during combat. Compare API facts before/after inspection; only an
   intentional move/resize may alter inspector preferences.
