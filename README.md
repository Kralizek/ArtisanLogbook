# Artisan Logbook

The native in-game browser opens with `/al` or `/artisanlogbook`. See
[production UI](docs/production-ui.md) for the views, data controls and in-game
validation checklist. Install the bundle, or install `ArtisanLogbook_Core` and
`ArtisanLogbook` (UI) separately. Core owns production capture, correlation,
the ledger, statistics and public API; the UI requires Core and works without the
optional `ArtisanLogbook_Tracer` diagnostic addon. Tracer can run without Core and
is **disabled by default**. Enable it in the game's AddOns list to collect
diagnostic evidence and use `/al_trace`. See
[capture tracer](docs/capture-tracer.md) for recording modes, limits and
SavedVariables compatibility.

The package contains all three addons in one ZIP. They share a version, release
tag and CurseForge project; the individual addon ZIPs are also produced for
testing and deployment. Tracer owns `ArtisanLogbookTraceDB`; Core declares only
`ArtisanLogbookDB`.

## Local packaging and deployment

Run `bash src/addon/scripts/package.sh` to execute addon tests and build three
individual ZIPs plus the combined bundle under `src/addon/dist/`. Packaging
defaults to the configured Retail flavor; set `ADDON_FLAVOR` to another enabled
flavor, for example `ADDON_FLAVOR=retail bash src/addon/scripts/package.sh`.

On Windows, `scripts/Deploy-WowAddon.ps1` deploys the complete bundle by default;
it can also deploy one explicitly selected addon. Install the full bundle for a
normal Retail setup, since UI requires Core:

```powershell
.\scripts\Deploy-WowAddon.ps1
.\scripts\Deploy-WowAddon.ps1 -Addon Tracer
.\scripts\Deploy-WowAddon.ps1 -Flavor Retail -Addon Tracer
.\scripts\Deploy-WowAddon.ps1 -Flavor Forever -Addon Tracer
```

`-Flavor` defaults to Retail. `-WowPath` remains the WoW **installation root**:
Retail uses `_retail_\Interface\AddOns`, Forever uses
`_forever_\Interface\AddOns`; neither falls back to the other client.
The selected client directory must exist. Invalid paths fail with instructions
to supply `-WowPath`, before downloading/copying addons. A missing configuration
prompts once for the root.

The deployment configuration remains at
`%LOCALAPPDATA%\ArtisanLogbook\deploy.json`. Legacy `wowPath` roots are reused
and preserved; successful deployment adds a `paths` object keyed by `retail`
and `forever`, retaining other saved paths and fields. A shared root works for
both flavors without repeated prompts; separate per-flavor roots are also
supported. Invalid JSON is not overwritten: back it up or repair it first.

The script selects exact flavor/addon archives from same-commit releases or
workflow artifacts. Retail names remain unqualified; Forever names have
`-forever`, such as `ArtisanLogbook_Tracer-forever.zip` (CI) and
`ArtisanLogbook_Tracer-forever-<version>.zip` (release convention).
Cached runs are reused only after downloading and validating the requested
archive, not merely because the commit succeeded. Otherwise the script
dispatches Addon CI, which builds every configured flavor, and verifies the
run's commit. Archive paths, addon directories and **all** selected TOC
interfaces are validated against `.flavors.yml` before any extraction/copy.
The PowerShell reader consumes the block-style `id` and `version` scalar fields
used in that file; CI's existing YAML resolver validates the complete format.

Forever Core supports ordinary personal crafts with deterministic output and
fixed required reagents. The shared production UI is ready for **live acceptance**,
not released or fully visually validated. Install **Core + UI**:

```powershell
.\scripts\Deploy-WowAddon.ps1 -Flavor Forever -Addon Core
.\scripts\Deploy-WowAddon.ps1 -Flavor Forever -Addon UI
```

Enable both addons in-game and open `/al` or `/artisanlogbook`. Tracer may remain
disabled or absent. Overview, Logbook, Recipes, Reagents, Character and Profession
use the same screens as Retail. Confirmed crafts, output quantities, recorded
identities and expected fixed reagent requirements are available. Fixed quantities
come from recipe schematics and are attributed to confirmed crafts; they are
**not independently measured bag consumption or evidence of savings/returns**.
Resourcefulness, Multicraft, Ingenuity, concentration, qualities and crafting
operation measurements are unavailable, not zero, and their cards/charts are hidden.
Build local Forever archives with
`ADDON_FLAVOR=forever bash src/addon/scripts/package.sh`; extract the Core and UI
directories into `_forever_/Interface/AddOns` with WoW closed. Back up
`ArtisanLogbookDB` and `ArtisanLogbookUISettings` SavedVariables before deployment.
See the [Forever UI acceptance checklist](docs/production-ui.md#forever-live-acceptance)
for the four-craft history and a focused Retail smoke test.
The [Forever adapter guide](docs/capture-tracer.md#first-forever-crafting-adapter)
documents the replayed evidence, support boundary and in-game acceptance plan.
Orders, enchants, salvage, recrafts, optional/substituted inputs, crafting stats,
qualities and Retail-specific mechanics are not supported on Forever.

See the tracer and [production UI docs](docs/production-ui.md) for installation
and live verification steps.

Release flavors are configured in [`.flavors.yml`](.flavors.yml). Each enabled
flavor has an `id` and WoW client `version`. The matrix computes its
TOC interface number and creates a flavor-specific bundle. Retail keeps the
unqualified bundle filename for compatibility. Set `release: false` for
diagnostic flavors: they produce CI/local archives but are excluded from
GitHub releases and CurseForge. Forever retains this safety gate pending production
UI live acceptance; initial Core capture acceptance does not certify UI layout.
Retail release semantics are unchanged.

CurseForge publication uses
[`curseforge-publish@v0.6.0`](https://github.com/Kralizek/github-actions/tree/v0.6.0/actions/curseforge-publish)
to resolve game versions by exact name and version type. Game-version IDs are
not committed to this repository. CurseForge **version-type IDs** may be set as
provider metadata when the flavor ID is not an actual CurseForge type name or
slug: Retail currently uses `metadata.curseforge.versionType: '517'`, since
the catalog does not recognize `retail` as a type name. Without an override
the flavor `id` is used as the version type. Do not assign Forever the Classic version type speculatively; its publication
target remains unverified and it is not currently eligible for publication.

Run the **Release addon** GitHub Actions workflow from `master`, selecting the
version bump and release channel. One calculated version and tag are stamped
into all three TOCs. The workflow creates an authoritative GitHub release with
individual addon archives and the combined bundle, then publishes that bundle
to the configured single `CURSEFORGE_PROJECT_ID` for each enabled flavor. It
records a marker alongside the GitHub release artifacts containing the flavor
selector, resolved CurseForge version ID, uploaded file ID, asset name, and
SHA-256. Reruns skip publications whose marker matches the intended release; on
an ambiguous upload failure without a marker, verify CurseForge manually before
retrying to avoid duplicate uploads.

Local builds require Lua 5.1, Python 3 with PyYAML, `jq`, `zip`, and `unzip`.

Run mocked deployment tests with
`pwsh -NoProfile -File scripts/tests/Deploy-WowAddon.Tests.ps1`, and flavor archive
tests with `python3 -m unittest discover -s src/addon/tests -p 'package_test.py'`.
Neither needs a WoW installation or GitHub access.
