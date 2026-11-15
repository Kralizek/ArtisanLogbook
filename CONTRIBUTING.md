# Contributing to Artisan Logbook

Contributions and bug reports are welcome. Keep changes scoped and include relevant tests or reproduction evidence. In-game behavior should be validated in WoW when automated tests cannot exercise Blizzard APIs.

The repository's VS Code devcontainer is the primary supported development
environment. Windows PowerShell on the host supports local deployment. Use
isolated test data; never point tests at real user SavedVariables, Companion
history, settings, or an existing installation. Do not run host and container
builds or npm restores concurrently against the same checkout.

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
Packaging runs the existing Lua replay, migration and compatibility tests;
normal addon CI also checks configured flavor archives and mocked deployment.
These checks do not replace actual Retail/Forever runtime acceptance.

## Companion development

VS Code Dev Containers is the primary supported environment. Reopen/rebuild the
repository container, then run `aspire run` from `src/companion`. See the
[daily web development workflow](docs/companion/web.md#daily-development-vs-code-dev-containers)
for forwarded browser endpoints, isolated fixtures and edit/rebuild loops.

Use the .NET SDK pinned by `src/companion/global.json` (currently .NET 10),
the Node/npm versions in `.devcontainer/devcontainer.json` and `web/package.json`,
and Aspire CLI 13.6.5 for orchestrated development.
From `src/companion`:

```sh
dotnet restore ArtisanLogbook.Companion.slnx
dotnet build ArtisanLogbook.Companion.slnx -c Release -warnaserror
dotnet format ArtisanLogbook.Companion.slnx --verify-no-changes
dotnet test ArtisanLogbook.Companion.slnx -c Release -p:CompanionWebDevelopment=false
```

For frontend work, after dependencies are restored by MSBuild or Aspire, from
`src/companion/web` run the applicable checks:

```sh
npm run codegen
npm run typecheck
npm run lint
npm run format:check
npm run test
npm run build
```

`npm run build` generates contracts, typechecks and bundles; it is not itself
an embedded distribution test. Generated clients are not committed. Stop
Aspire before a separate restore or production build. See the web guide for
HMR, contract regeneration and local troubleshooting.

The Companion uses `src/companion/NuGet.Config`, which clears inherited NuGet package sources and configures only `nuget.org`. This prevents unrelated user-wide feeds from triggering NU1507 during centrally managed restores. The Windows deployment script explicitly selects this configuration during `dotnet publish`; it does not modify user-wide NuGet settings.

MSBuild restores npm dependencies, generates API types and embeds the Vite build.
The devcontainer intentionally defaults to development-only assets; the test
command above explicitly builds production resources required by hosting tests.
Use `-p:CompanionWebDevelopment=false` for production builds/publishes too.
Stop Aspire before deploying from the Windows host using the same checkout.
The devcontainer isolates npm dependencies in a volume, and .NET outputs are
partitioned by platform and asset mode. Do not run host/container builds or
a separate npm restore concurrently against the same checkout.
See the [browser development guide](docs/companion/web.md) for Aspire startup,
isolated fixtures, frontend checks and executable-only production verification.
Normal CI runs the complete .NET suite and an executable smoke on Linux and
Windows; frontend lint, formatting, unit tests and npm audit run on Linux. Aspire and
incremental-build smokes are extended checks, not part of every PR.

On the Windows host, after stopping Aspire, run `.\scripts\Deploy-Companion.ps1`
from the repository root to create a local development installation. See the
[Companion guide](src/companion/README.md) for user-facing commands and
[executable-only verification](docs/companion/web.md#publish-and-verify-one-executable)
for production publish commands. Do not publish with development assets or
`--no-build`.

## Extended regression validation

Select these suites when the affected development, build, deployment or
compatibility surface justifies them. They complement normal CI rather than
re-running every application test. Run from the repository root, sequentially
with any other build against the checkout:

```sh
bash .github/workflows/scripts/regression-addon.sh
bash .github/workflows/scripts/regression-companion.sh
```

The addon suite requires Git, Lua 5.1 and `diff`, plus the historical Git
objects used by the fixture generator (a full clone, or a fetch of those
revisions). It regenerates the pre-#21 and outcome-2 sanitized schema-1 fixtures
in a temporary directory and compares them with the committed files. The
outcome-1 generator revision is not reachable from the default branch and is
not required by this suite. Normal CI already runs
the large replay, migration, packaging and cross-component adapter tests; there
is no separate extended live-client or larger-replay suite. Do not manufacture
one or treat fixture generation as live WoW validation.

The Companion suite runs on Linux/devcontainer with the pinned .NET SDK, Node,
npm, Aspire CLI and Lua 5.1 available. It restores the solution, runs the
existing incremental asset smoke, starts real Aspire with a temporary imported
fixture and tests health, Vite, REST and canonical GraphQL, then verifies
production restoration after the development install. It modifies generated
assets, dependency state and timestamps while running; stop other builds first.
The smoke restores its source timestamp and temporary data, and Aspire is stopped
on exit. Publication guards and executable-only distribution remain normal CI
checks; targeted publish commands are linked above. HMR is a manual check, not
part of this suite.

On Windows with PowerShell 7, the pinned .NET SDK and Node/npm on PATH:

```powershell
pwsh -File .\.github\workflows\scripts\regression-companion-windows.ps1
```

This tests missing tools, failed codegen/publication and failed npm restore
against a temporary installation, preserving it across failures. It temporarily
modifies `web/codegen.ts` and dependency state; do not run it concurrently with
another build. It restores the source and reinstalls development dependencies
afterwards. It does not touch an existing installation or the user's PATH.

The **Regression Tests** GitHub Actions workflow is manual only. In Actions,
select **Run workflow**, choose a branch and `all`, `addon` or `companion`
(default `all`). Once the workflow exists on the default branch, the CLI
equivalent is:

```sh
gh workflow run regression-tests.yml --ref BRANCH -f component=all
```

The hosted Linux and Windows jobs run the same scripts, but do not simulate
alternating Windows-host/Linux-devcontainer builds on one checkout. For that
acceptance, run Aspire in the devcontainer and stop it. On Windows, deploy to
a new temporary `-InstallDirectory` with `-NoPathUpdate`; set
`ARTISAN_LOGBOOK_DATA_DIRECTORY` to a separate temporary directory and disable
monitoring when verifying the embedded application. Then stop it, restart
Aspire and continue development without manual dependency repair. A fresh container rebuild,
host-browser forwarding and certificates, HMR, and actual WoW runtime/visual
behavior require the real environments; report each as tested or not tested.

## Agent skills and evaluations

Repository skills live only under `.agents/skills/`; see [AGENTS.md](AGENTS.md)
for routing. Each skill's `evals/evals.json` contains manual cases with stable IDs,
prompts, expected outcomes, assertions and paths relative to that skill directory.
Choose a case, give its prompt to a fresh agent session with the relevant skill
discoverable or explicitly loaded, and compare the result with every assertion
and referenced source. Existing evaluation tooling may consume the JSON, but
the format does not promise automatic compatibility with any particular harness.

Checking frontmatter and links is format validation; seeing a skill in a fresh
session is discovery, not proof of activation. Running a case evaluates agent
behavior; product regression scripts test the application instead. None of
these implies the others, and no model evaluation is required in CI.

## Documentation rules

**Write READMEs for their intended readers, not for the agent or developer that delivered the latest feature.**

- The root README introduces the addon to players; component READMEs explain purpose, quick start, and current scope.
- Put procedures, reference tables, and detailed behavior contracts in focused `docs/` pages or code-adjacent implementation documentation.
- Keep enduring architectural rationale in focused architecture docs or ADRs; avoid copying PR narratives.
- Keep test observations, one-off troubleshooting evidence, and milestone status in issues/PRs and regression tests, not product READMEs.
- Link to a canonical explanation rather than duplicating it. Check relative links whenever headings or files move.
- Do not add a README paragraph merely because a feature was implemented. Describe the observable behavior only when it matters to readers.

Documentation-only changes should not imply that unsupported features are released or validated.
