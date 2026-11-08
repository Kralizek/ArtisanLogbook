# Addon installation, local deployment, and releases

This guide is for testers, maintainers, and anyone installing outside the normal packaged addon distribution. For a player-oriented introduction, start at the [project README](../README.md).

## Addon layout

The combined bundle contains `ArtisanLogbook_Core`, `ArtisanLogbook` (the UI), and the optional `ArtisanLogbook_Tracer`. Core and UI are required for the normal browsing experience; Tracer is disabled by default. The three components share a version and release tag.

The addon stores its crafting history in `ArtisanLogbookDB`; UI preferences and diagnostic recorder data are separate. Back up SavedVariables before experimenting with development builds.

## Local build

From the repository root:

```sh
bash src/addon/scripts/package.sh
```

Packaging runs addon checks and writes individual archives plus a combined bundle under `src/addon/dist/`. Local prerequisites: Lua 5.1, Python 3 with PyYAML, `jq`, `zip`, and `unzip`.

Use `ADDON_FLAVOR=retail` (the default) or `ADDON_FLAVOR=forever` to select an enabled client:

```sh
ADDON_FLAVOR=forever bash src/addon/scripts/package.sh
```

## Local Windows deployment

`scripts/Deploy-WowAddon.ps1` deploys the combined bundle by default. To deploy a single addon or target another client:

```powershell
.\scripts\Deploy-WowAddon.ps1
.\scripts\Deploy-WowAddon.ps1 -Addon Tracer
.\scripts\Deploy-WowAddon.ps1 -Flavor Forever -Addon Core
.\scripts\Deploy-WowAddon.ps1 -Flavor Forever -Addon UI
```

The `-WowPath` option refers to the **WoW installation root**, not `Interface/AddOns`. Retail installs under `_retail_/Interface/AddOns`; Forever installs under `_forever_/Interface/AddOns`. The selected client directory must exist.

The script saves its local configuration at `%LOCALAPPDATA%\ArtisanLogbook\deploy.json`, with per-flavor roots. It validates downloaded archives and client interface metadata before extracting them. Invalid configuration is not silently overwritten.

For manual installs, place the extracted Core and UI addon directories directly inside the relevant client's `Interface/AddOns` folder while WoW is closed.

## Supported flavors

Retail is the primary release target. Forever support is limited: ordinary personal crafts with deterministic output and fixed required reagents are supported, but Retail-only crafting mechanics and many advanced operations are not. Fixed reagent quantities inferred from schematics are **not** independently measured consumption or evidence of material savings.

Forever is presently a validation/testing flavor, not a certified published release. See [production UI](production-ui.md#forever-live-acceptance) and [Forever capture notes](capture-tracer.md#first-forever-crafting-adapter) for test coverage and limitations.

Flavor definitions live in [`.flavors.yml`](../.flavors.yml). Flavors with `release: false` may be packaged for testing but are not published to GitHub releases or CurseForge.

## Release maintenance

The **Release addon** GitHub Actions workflow runs from `master` and accepts the version bump and release channel. It stamps a shared tag/version into addon TOCs, publishes the combined bundle and individual archives to GitHub, and publishes eligible bundles to CurseForge.

Publication records a per-flavor marker with the resolved CurseForge file and artifact hash so matching reruns can be skipped. If an upload may have succeeded but no marker was recorded, verify CurseForge before retrying to avoid duplicates.

CurseForge game version mappings are resolved by the configured publication action; see its workflow and `.flavors.yml` for the authoritative values. Do not guess version-type IDs for unpublished flavors.

## Tests

```sh
python3 -m unittest discover -s src/addon/tests -p 'package_test.py'
```

```powershell
pwsh -NoProfile -File scripts/tests/Deploy-WowAddon.Tests.ps1
```

These tests do not require a running game client. In-game acceptance remains necessary for UI behavior and capture events.
