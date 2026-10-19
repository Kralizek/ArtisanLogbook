# Artisan Logbook

The native in-game browser opens with `/al` or `/artisanlogbook`. See
[production UI](docs/production-ui.md) for the views, data controls and in-game
validation checklist. Install the bundle, or install both `ArtisanLogbook` (UI)
and its required `ArtisanLogbook_Core` (capture and durable facts). The UI reads
Core via `ArtisanLogbookAPI`; engineering tracing is available through `/al_trace`.

Release flavors are configured in [`.flavors.yml`](.flavors.yml). Each enabled
flavor has an `id` and WoW client `version`. The release matrix computes its
TOC interface number and creates a flavor-specific bundle. Retail keeps the
unqualified bundle filename for compatibility. Other flavors must be validated
in-game before enabling them.

CurseForge publication uses
[`curseforge-publish@v0.6.0`](https://github.com/Kralizek/github-actions/tree/v0.6.0/actions/curseforge-publish)
to resolve game versions by exact name and version type; numeric CurseForge
IDs are not committed to this repository. By default the CurseForge version type
is the flavor `id`. Override it when necessary using:
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

The release workflow creates an authoritative GitHub release and bundles, then
publishes each enabled flavor to CurseForge. It records a marker alongside the
GitHub release artifacts containing the flavor selector, resolved CurseForge
version ID, uploaded file ID, asset name, and SHA-256. Reruns skip publications
whose marker matches the intended release; on an ambiguous upload failure without
a marker, verify CurseForge manually before retrying to avoid duplicate uploads.

Packaging defaults to the configured Retail flavor. Set `ADDON_FLAVOR` to
package another enabled flavor. Local builds require Lua 5.1, Python 3 with
PyYAML, `jq`, `zip`, and `unzip`.
