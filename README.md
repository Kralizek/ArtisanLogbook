# Artisan Logbook

The native in-game browser opens with `/al` or `/artisanlogbook`. See
[production UI](docs/production-ui.md) for the views, data controls and in-game
validation checklist. Install the bundle, or install both `ArtisanLogbook` (UI)
and its required `ArtisanLogbook_Core` (capture and durable facts). The UI reads
Core via `ArtisanLogbookAPI`; engineering tracing is available through `/al_trace`.

Release flavors are listed in `.curseforge.yml`; each configured version gets its
interface injected into staged TOCs and a separate flavor-named bundle. Add a
flavor only after validating addon compatibility. To look up a CurseForge game
version ID for a future entry, run
`bash src/addon/scripts/fetch-curseforge-version.sh <version> [flavor]`. The
script reads `CF_API_TOKEN` or `CURSE_FORGE_TOKEN` from the environment or root
`.env` and requires `curl` and `jq`. Packaging defaults to the configured Retail
flavor; set `ADDON_FLAVOR` to build another configured flavor. Package builds
require Lua 5.1, Python 3 with PyYAML, `jq`, `zip`, and `unzip`.
