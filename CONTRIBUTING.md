# Contributing to Artisan Logbook

Contributions and bug reports are welcome. Keep changes scoped and include relevant tests or reproduction evidence. In-game behavior should be validated in WoW when automated tests cannot exercise Blizzard APIs.

## Repository areas

- `src/addon/`: WoW addon Core, UI, Tracer, packaging, and tests.
- `src/companion/`: standalone .NET CLI, data preservation, and associated tests.
- `docs/`: focused technical references, capture notes, UI and deployment guidance.
- `scripts/`: developer deployment tools.

## Addon development

Local packaging prerequisites are Lua 5.1, Python 3 with PyYAML, `jq`, `zip`, and `unzip`.

```sh
bash src/addon/scripts/package.sh
python3 -m unittest discover -s src/addon/tests -p 'package_test.py'
```

On Windows, use `scripts/Deploy-WowAddon.ps1` for local game deployment. See [addon deployment](docs/addon/deployment.md) for flavors, paths, and packaging.

## Companion development

Use the .NET SDK pinned by `src/companion/global.json` (currently .NET 10). From `src/companion`:

```sh
dotnet restore ArtisanLogbook.Companion.slnx
dotnet format ArtisanLogbook.Companion.slnx --verify-no-changes
dotnet build ArtisanLogbook.Companion.slnx -c Release -warnaserror
dotnet test ArtisanLogbook.Companion.slnx -c Release --no-build
```

The Companion uses `src/companion/NuGet.Config`, which clears inherited NuGet package sources and configures only `nuget.org`. This prevents unrelated user-wide feeds from triggering NU1507 during centrally managed restores. The Windows deployment script explicitly selects this configuration during `dotnet publish`; it does not modify user-wide NuGet settings.

On Windows, the repository-root `scripts/deploy-companion.ps1` creates a local development installation. See the [Companion guide](src/companion/README.md) for user-facing commands.

## Documentation rules

**Write READMEs for their intended readers, not for the agent or developer that delivered the latest feature.**

- The root README introduces the addon to players; component READMEs explain purpose, quick start, and current scope.
- Put procedures, reference tables, and detailed behavior contracts in focused `docs/` pages or code-adjacent implementation documentation.
- Keep enduring architectural rationale in focused architecture docs or ADRs; avoid copying PR narratives.
- Keep test observations, one-off troubleshooting evidence, and milestone status in issues/PRs and regression tests, not product READMEs.
- Link to a canonical explanation rather than duplicating it. Check relative links whenever headings or files move.
- Do not add a README paragraph merely because a feature was implemented. Describe the observable behavior only when it matters to readers.

Documentation-only changes should not imply that unsupported features are released or validated.
