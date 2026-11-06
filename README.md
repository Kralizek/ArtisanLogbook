# Artisan Logbook

The native in-game browser opens with `/al` or `/artisanlogbook`. See
[production UI](docs/production-ui.md) for the views, data controls and in-game
validation checklist. Install the bundle, or install `ArtisanLogbook_Core` and
`ArtisanLogbook` (UI) separately. Core owns production capture, correlation,
the ledger, statistics and public API; the UI requires Core and works without the
optional `ArtisanLogbook_Tracer` diagnostic addon. Tracer also requires Core and
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
normal setup, since UI and Tracer each require Core:

```powershell
.\scripts\Deploy-WowAddon.ps1
.\scripts\Deploy-WowAddon.ps1 -Addon Tracer
```

See the tracer and [production UI docs](docs/production-ui.md) for installation
and live verification steps.

Release flavors are configured in [`.flavors.yml`](.flavors.yml). Each enabled
flavor has an `id` and WoW client `version`. The release matrix computes its
TOC interface number and creates a flavor-specific bundle. Retail keeps the
unqualified bundle filename for compatibility. Other flavors must be validated
in-game before enabling them.

CurseForge publication uses
[`curseforge-publish@v0.6.0`](https://github.com/Kralizek/github-actions/tree/v0.6.0/actions/curseforge-publish)
to resolve game versions by exact name and version type. Game-version IDs are
not committed to this repository. CurseForge **version-type IDs** may be set as
provider metadata when the flavor ID is not an actual CurseForge type name or
slug: Retail currently uses `metadata.curseforge.versionType: '517'`, since
the catalog does not recognize `retail` as a type name. Without an override
the flavor `id` is used as the version type. For example:
```yaml
flavors:
  - id: forever
    version: '1.60.1'
    metadata:
      curseforge:
        versionType: classic
```
This example is not an enabled flavor until it is included in `.flavors.yml`
and its bundle has been tested.

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
