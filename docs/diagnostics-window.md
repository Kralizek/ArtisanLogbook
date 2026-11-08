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

## Layout and controls

The window opens at **720 x 520** UI units (minimum 560 x 420), bounded by the
screen, and is clamped to the screen. Native resize bounds are preferred; older
min/max resize methods are a fallback. From top to bottom:

- **Title bar** - drag to move. The drag region stops before **X**, and X sits
  explicitly above it, so the click is never claimed by the drag area.
- **Tabs** - Capabilities, Diagnostics, Crafts, Sessions. The active tab is
  highlighted, gold-labelled and underlined.
- **Breadcrumb** - where you are, e.g. `Crafts > Page 2 > Craft #150 > Raw View`
  or `Sessions > Session 3 (from craft #150)`. Navigation buttons on the same
  row appear only when they apply:
  - **< Newer / Older >** - record pages in Crafts/Sessions lists (disabled at
    either end). They follow API cursors; history is never rendered all at once.
  - **Back to list** - from a craft/session detail to the same list page, where
    the previously opened row stays highlighted.
  - **Open session** - craft detail only; opens that craft's session.
    **Back to craft #N** then returns to the craft.
- **Status** - one line of guidance; failures are shown in red.
- **Content** - a Crafts/Sessions list shows up to twelve rows (one column, or
  two/three when the window is short); otherwise a scrollable, selectable text
  area. Resizing reflows rows and text.
- **Bottom bar** - **Refresh**, **Raw View/Summary**, **Copy**, **Export** on
  the left; raw text paging (`<`, `Page n / m`, `>`) on the right in Raw View
  or Export only. Drag the lower-right grip to resize.

**X**, Escape and `/al_debug` all hide the same window and share cleanup: pending
raw formatting stops, text focus clears, and a move/resize in progress stops and
saves geometry. Reopening keeps the tab, page, selection and view mode and
re-queries the API once.

Sections:

- **Capabilities** - flavor, capture readiness, supported crafts, correlation,
  then grouped available and not-available features, mechanics, events and API
  hooks (counts plus unavailable names). Not-available Forever mechanics are
  expected, not errors. Raw View lists every value.
- **Diagnostics** - capture health, the last unsupported reason, correlation
  ambiguity, pending request state and recipe/output knowledge counts. Raw View
  includes every returned field, including cached repair analysis and recovery.
  Inspection does **not** run analysis, discovery or repair.
- **Crafts** - newest first. Click the first row to inspect the latest craft:
  recipe, crafted time, output, request, session, input completeness, recorded
  reagent count and provenance. Raw View includes reagent facts, requirements,
  output observations and the correlated request. Missing persisted fields are
  not reconstructed.
- **Sessions** - newest local session first; the current session is marked.
  Details show start time, client/build, interface/project, flavor and addon
  version. Historical capabilities are the creation-time snapshot.

Summary is intentionally concise and uses readable wording: `yes`/`no`, and
`unknown` when a field is absent. Timestamps appear as **local date/time**
(`%Y-%m-%d %H:%M:%S`); Raw View always shows the original Unix values and types.

**Provenance** (`outcomeSource`) describes how completely *returned reagents*
(Resourcefulness) were observed, not whether the craft happened. Every listed
craft was recorded from a craft result:

- `native` - returned reagents completely observed; none listed means none returned.
- `partial` - only some returned reagents could be proven.
- `unverified` - the request context could not be verified, so returned
  reagents are not claimed complete. It does **not** mean the craft failed.
- absent - captured before provenance tracking.

**Raw View / Summary** switches display without requerying the API. **Refresh**
requeries the current response or record, including the current data page. A
stale cursor after history changes is not silently retried; reselect the tab to
start a fresh page sequence. Mouse wheel or the scrollbar scrolls text
independently of chat.

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

**Copy** focuses/selects the complete displayed text page (it is disabled while a
record list is shown; open a record or use Raw View). Press **Ctrl+C** (or
**Ctrl+A** then **Ctrl+C**), and paste into an external editor. Addons cannot write directly to
the OS clipboard. The text box rejects edits to the inspected display; it does
not write changes back to the response. This does not prevent selecting/copying.

**Export** switches to the raw representation of the currently selected response
or detail record. Use Copy, then **>**, and repeat for every text page.
Paste the pages in order **without adding separators**. **<** revisits
previous chunks. `Page n / m` shows the text page number and whether more remains
(`+` while the formatter has not reached the end). Data-page navigation and
text-page navigation are separate. To inspect/export older crafts or sessions,
return to their list and follow **Older >**; a paged API response is not the
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
mouse hit-testing of X above the title bar (strata/frame level/anchor geometry),
shared X/Escape/command cleanup, contextual controls, tab/row highlighting,
local-time and provenance summaries, layout at minimum/default/large sizes,
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
   Escape and X (click X directly, including right after dragging the title). Confirm no chat spam. Move/resize and reload to check geometry.
3. Read Capabilities and Diagnostics. On Forever, unsupported mechanics should
   be false/unavailable, not errors. Check raw events/hooks and cached repair state.
4. Craft one supported item. Select Crafts again, open the newest row, and inspect
   Raw View's reagents/request, input completeness and provenance. Open
   session and confirm client/build/flavor. Reload and find the saved craft again.
5. Copy a record and diagnostics; test all chunks of a large response and older
   data pages. Paste into a local editor and verify no missing/doubled chunk.
6. Enable Tracer, record a session, and open both windows; confirm capture and
   observer integration continue unchanged. On Retail, repeat with production UI.
7. Check smaller viewports/UI scales, long names, focus/scroll behavior, and safe
   operation during combat. Compare API facts before/after inspection; only an
   intentional move/resize may alter inspector preferences.
