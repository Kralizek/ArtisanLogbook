# Artisan Logbook Companion MVP

One cross-platform .NET executable preserves crafting history from explicit
SavedVariables snapshots or configured installations into **one authoritative DuckDB file for all game
contexts**. Import regularly, before the addon's detailed retention window
expires. The Companion never changes the source file.

## One-command Windows local deployment

From the repository root on Windows, with the .NET 10 SDK installed:

```powershell
.\scripts\deploy-companion.ps1
```

This builds and smoke-tests a Release `win-x64` self-contained, untrimmed,
single-file Companion using `dotnet publish`, then installs it under
`%LOCALAPPDATA%\Programs\ArtisanLogbook\Companion`. It also installs an
`al.cmd` forwarding alias and adds that directory to the **user PATH**
(no administrator rights required). Open a **new terminal** after the first
install, then run `al init`, `al import`, or `al status`.
`artisanlogbook` remains the canonical executable name.

Run the script again to rebuild and replace a previous script-managed
installation. Publishing and the executable smoke test happen in a separate
staging directory before replacing the installed binaries; an unsuccessful
publish leaves the previous installation unchanged. If the Companion is running
and Windows locks the executable, close it and retry. The script refuses to
overwrite an existing directory that lacks its installation marker.

```powershell
.\scripts\deploy-companion.ps1 -Configuration Debug
.\scripts\deploy-companion.ps1 -InstallDirectory 'D:\Tools\ArtisanLogbook' -NoPathUpdate
```

The installation path is **not** the data path. The script never deletes,
migrates, or modifies `settings.json` or `history.duckdb` under the per-user
application-data directory documented below. `-NoPathUpdate` is useful for
CI/smoke tests and custom launchers; if used, invoke the executable from
the install directory. This is a Windows x64 local development deployment
script, **not** a public installer, auto-updater, or a macOS/Linux release.

## Build and install

Use the .NET SDK pinned in [global.json](global.json) (currently .NET 10).
From this directory:

```sh
dotnet restore ArtisanLogbook.Companion.slnx
dotnet build ArtisanLogbook.Companion.slnx -c Release -warnaserror
dotnet run --project src/Cli/Cli.csproj -c Release -- --help
```

To install the built executable as a local .NET tool, choose a tools/package
directory outside the source tree:

```sh
dotnet pack src/Cli/Cli.csproj -c Release --output ./packages
dotnet tool install ArtisanLogbook.Companion --version 0.1.0 \
  --add-source ./packages --tool-path ./tools
./tools/artisanlogbook --help
```

On Windows, use `.\tools\artisanlogbook.exe`. The pack/install commands can be
entered on one line in PowerShell instead of using shell line continuations.
The tool requires the .NET 10 runtime. Alternatively, run the built DLL with
`dotnet src/Cli/bin/Release/net10.0/artisanlogbook.dll <arguments>`.
No package has been published to NuGet and no standalone release is supplied
by this milestone.

## Commands and help

```text
artisanlogbook init
artisanlogbook import [source-file] [--database <path>] [--verbose]
artisanlogbook import --verbose
artisanlogbook import snapshot.lua --verbose
artisanlogbook status [--database <path>]
artisanlogbook --help
artisanlogbook import --help
artisanlogbook init --help
artisanlogbook status --help
artisanlogbook --version
```

No arguments displays help. Spectre generates argument/option descriptions and
examples, validates settings, and rejects unknown commands/options, extra
arguments, empty explicit paths, and missing option values. Quote paths containing
spaces. Relative paths resolve against the current working directory; `~` is
expanded by your shell, not by the Companion.

### Database location

| Platform | Default |
|---|---|
| Windows | `%LOCALAPPDATA%\ArtisanLogbook\Companion\history.duckdb` |
| macOS | `~/Library/Application Support/ArtisanLogbook/Companion/history.duckdb` |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/ArtisanLogbook/Companion/history.duckdb` |

Linux ignores empty or relative `XDG_DATA_HOME`, as required by XDG conventions.
`--database` completely overrides the default. Import creates parent directories
and initializes the complete schema v2 directly. Old C03 development databases
are unsupported: use a new database path and reimport SavedVariables. No old
database is migrated, deleted, or overwritten. Status uses DuckDB's read-only access mode, does not
migrate schemas, and does not create a missing file or directory. Unrecognized
or unsupported schemas fail explicitly. Defaults never use the executable
directory; an unavailable user data directory requires an explicit override.

### Initialization and shared settings

Run `artisanlogbook init` in an interactive terminal. The Spectre wizard explains
the Companion, detects plausible installations, and offers discovered roots,
the current root (preselected on repeat runs), manual entry, and cancellation.
Manual entry is available even when candidates are found, accepts relative paths,
and explains invalid selections before retrying. Select the **installation root**,
not a flavor or account. A root must contain a direct client directory with
`WTF/Account` or `Interface/AddOns`; a directory named "World of Warcraft" alone
is insufficient. No flavor selection is needed.

The wizard shows the proposed configuration and asks for confirmation (default
**No**) before saving. Canceling leaves settings unchanged. It neither opens nor
creates DuckDB, changes SavedVariables, nor imports anything. After saving,
run `artisanlogbook import`. Redirected/noninteractive `init` returns a clear
usage error rather than waiting for input.

`settings.json` lives beside the **default** `history.duckdb` in the per-user
directory listed above. `--database` does not relocate settings. Schema version 1
contains only an integer `version` and an `installationRoots` array of normalized
absolute paths. It has no credentials, account IDs, character IDs, flavor
settings, or database overrides. For example on Linux:

```json
{
  "version": 1,
  "installationRoots": [
    "/games/World of Warcraft"
  ]
}
```

The model and discovery support multiple roots now. This wizard manages the
first root and preserves any additional roots. There is no `config set/get`
command. Settings use strict, human-readable JSON; missing, duplicate, unknown,
malformed, relative, or unsupported-version fields are not silently defaulted.
Missing settings instruct the user to initialize; unreadable, malformed, or
unsupported settings require explicit backup/repair or a compatible Companion.
Neither `init` nor the reusable save service overwrites such a file. A settings
path that is itself a link or directory is rejected.

Saving writes and flushes a unique same-directory temporary file, then atomically
renames it over the old file. Cancellation or write/rename failure leaves the
previous complete configuration intact. A revision check rejects changes made
while the wizard was open; configuration is intended for a single writer, not
concurrent editing by multiple processes. Atomic visibility assumes filesystem
rename support; this is not a power-loss guarantee on every filesystem. Settings
paths are structurally validated on load; filesystem availability is checked
during initialization/discovery so an offline installation is reported rather
than erased.

### Installation and SavedVariables discovery

Automatic detection is a bounded set of hints, not a drive scan or a dependency
on Battle.net:

- Windows: Program Files, Program Files (x86), the system drive's `Games`, and
  the user's `Games`, each with a `World of Warcraft` child.
- macOS: `/Applications/World of Warcraft` and the user's `Applications`.
- Linux: the user's `Games/World of Warcraft`, the default Wine prefix, and a
  common Lutris `Games/world-of-warcraft/drive_c/Program Files (x86)` location.

Other launchers, custom prefixes, drives, and mount points may require manual
entry. The service validates layout, not directory names or launcher metadata.

For every configured root, discovery inspects only direct client directories
and the fixed account-level SavedVariables layout:

```text
<root>/<client>/WTF/Account/<account>/SavedVariables/ArtisanLogbook_Core.lua
```

All accounts and client directories are considered, including Retail, Classic
variants, Forever, and future names. Missing account/ledger directories are
normal; no files is an explicit unsuccessful import, not a successful empty
operation. Backups, temporary files, UI and Tracer SavedVariables, and
character-level or unrelated directory trees are not scanned. Paths are
normalized, sorted with the OS path comparer, and deduplicated. Directory links
(including root ancestors) and ledger links are skipped with diagnostics;
select a physical installation path. Hard-link aliases and case aliases on
case-insensitive Unix filesystems are not physically deduplicated; C07/C02
identity reconciliation still makes repeated observations idempotent.
Inaccessible/broken configured roots, account entries, and known client source
branches produce errors and do not hide other discoverable ledgers. Incidental
failures inspecting unrecognized installation children or `Interface/AddOns`
layout hints are warnings, as are skipped filesystem links. Discovery never
reads ledger contents or writes files.

### Import

The thin command opens/disposes C03 and invokes C07's
`CompanionImportService.ImportSavedVariablesFileAsync`. C04 gets the game project
and optional progression track from SavedVariables; there is no flavor argument.
C01/C02 validation/reconciliation and C03 transactional persistence remain the
only promotion path. Reimporting unchanged input is idempotent; compatible
unknown-to-known enrichment is retained. A rejected/conflicting batch commits
**no** craft or dimension changes. Failed source reads and database errors are
distinct from rejected source data. A first failed/rejected import may leave an
initialized but empty database.

With an explicit source file, behavior is unchanged: no configuration is needed,
loaded, searched, or modified. With no source argument, the command loads shared
settings, discovers all Core ledgers, and imports each through that
same C07 API into one database. Directory names **never** infer or override
C04's source-derived GameContext. Each file has its own transaction; rejected
or failed files do not roll back separately committed valid files. Processing
continues across independent files, with a compact per-source summary and final
committed-craft totals. Totals count observations handled across files,
not unique database cardinality (use `status` for that).

Partial success is explicit and returns nonzero. Any failed file or discovery
error returns 3; otherwise a rejected file returns 2. Discovery warnings
(including skipped links) and source coverage/evidence warnings do not fail
an otherwise successful import or mark it partial. Discovery diagnostics remain
visible in both output modes. No configured
root returns 1 and advises `artisanlogbook init`; malformed/unreadable/unsupported
settings or no discovered ledgers return 3 without opening DuckDB.

#### Normal output

Installation imports show one table of new, existing, enriched, and outcome
counts per source, without repeated full paths or low-level report tables.
Labels use client-directory names only for presentation (`_retail_` becomes
`Retail`, `_forever_` becomes `Forever`). Shared labels include the account
directory and, when necessary, a deterministic installation number based on
sorted configured roots. These labels never classify the canonical GameContext.
Explicit-file imports show the filename and change summary without an
installation table. First imports emphasize newly preserved observations.

An unchanged successful installation reimport looks like this (illustrative,
not live source data; table borders omitted):

```text
Artisan Logbook - Import
Source     New   Existing   Enriched   Result
Forever      0         30          0   successful
Retail       0      2,702          0   successful

Import complete - no changes.
2,732 existing crafts / 0 new / 0 enriched
```

Relevant source warnings/information are grouped by stable code and severity.
Counts are **diagnostic occurrences**, not rejected crafts, unique affected
crafts, or recovered attempts. The same occurrence exposed through C07's source
and coverage views is counted once; separate equal occurrences remain separate.
Group lines identify affected source labels. Unknown codes retain their original
locations/messages in normal output, and errors/conflicts are never collapsed
into warning counts.

#### Attribution and suppression

C04 associates diagnostics emitted while mapping a complete grouped observation
with its canonical `(Origin, Observation)` identity. It does not parse IDs from
messages or locations, and it does not treat a local craft ID as globally unique.
Schematic variation is directional: each occurrence belongs to the current
craft's differing schematic snapshot, not to every craft sharing that recipe.
C03 exposes per-observation committed reconciliation outcomes through C07;
no diagnostic history, database schema change, or source mutation is needed.

- Inserted crafts' diagnostics remain visible.
- Already-present crafts' warnings/information are suppressed.
- Enriched crafts' known diagnostics appear only when their relevant recipe,
  output, reagent/completeness, or schematic evidence changed. Unrelated
  enrichment does not repeat an unknown-recipe warning. New diagnostic codes
  conservatively remain visible on enrichment.
- Ledger-level lineage, legacy outcome, missing-rollup, and aggregate-only
  notices appear when observations or dimensions commit changes, not on an
  unchanged successful reimport with retained crafts.
- Unattributed diagnostics, missing associations, and ledgers with no retained
  observations remain visible conservatively: existing craft reconciliation
  cannot establish prior ingestion of those conditions. Legacy clone lineage
  uncertainty is unchanged; presentation cannot make independently diverged
  ledgers safe to combine.
- Rejected/failed imports and all errors, validation failures, conflicts,
  source-read failures, and persistence failures are never suppressed.

Unknown recipes are valid incomplete evidence, **not rejected crafts**.
Aggregate-only history is **not recovered** and is never counted as canonical
crafts. Files that fail/reject are identified by full path with actionable
details and an explicit no-commit statement. Other valid files remain committed;
partial success and existing nonzero exit codes are preserved.

#### Verbose output

`--verbose` works with installation and explicit-file imports. It adds full
source/database paths, the existing detailed C07 craft/dimension counters,
observed counts, all source/coverage diagnostics (including normally suppressed
ones), original locations and messages, validation and reconciliation details,
input/persistence failures, discovery diagnostics, per-file outcomes, aggregate
coverage detail, and installation totals. It is presentation-only: parsing,
identity, reconciliation, transaction boundaries, persistence, and exit codes
are identical to normal mode.

Diagnostic text, paths, and account labels may contain private source
information; do not upload raw terminal logs or SavedVariables.

### Status

Status reports existence, schema version, total canonical craft count, oldest
and newest timestamps (UTC, microsecond display precision), and counts grouped
by game context, including numeric Blizzard project ID and progression track.
It uses C03 aggregate SQL, not `ReadAll`, and excludes dimension-only contexts
without crafts. This is an operational inventory across contexts, not an
analytics dashboard; future analytical queries still select exactly one context.

```text
History status (read-only).
Schema version      2
Canonical crafts   15
GameContext    Project ID    Progression track    Crafts
Retail         1            (unspecified)        15
```

For a missing database, status returns success and advises importing a snapshot.
For locks, close other Companion/DuckDB processes using this database and retry.
Do not delete the database or its WAL. Commands do not coordinate with other
processes or start a host, watcher, server, or background service.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Successful init/import/status/help/version; also canceled init and missing-database status |
| 1 | CLI parsing/settings-validation error, missing installation configuration, or noninteractive init |
| 2 | Import rejected: malformed/unsupported source, validation, or conflict |
| 3 | Failed operation: source read, permissions, database/lock/schema/configuration failure, no ledgers, or incomplete discovery |

## Architecture and Hyde conventions

[Hyde's CLI](https://github.com/Kralizek/Hyde/blob/master/src/Hyde/Program.cs)
is the reference: `CommandApp`, Microsoft `ServiceCollection`,
`DependencyInjectionRegistrar`, described commands with validated examples,
shared base settings and command-local nested settings, asynchronous import
commands, and Spectre tables. Unlike Hyde's static `AnsiConsole` usage, this
Companion injects `IAnsiConsole` for testable output and configures Spectre's
help/error renderer to use that same console. No site configuration interceptor
or generic host is needed: the shared Runtime settings/discovery services are
injected directly. The initialization prompt boundary is replaceable in tests.

Reference patterns were checked against Hyde commit
`42a0fd1635a1928d2d4e6b2eb6b2cb8089a53b5e`.
Spectre Console/CLI/Testing are pinned to **0.49.1**, with the matching DI adapter
**0.6.0**. Acceptance tests found a strict-parser regression in 0.57.2:
`status --database` incorrectly succeeds with `__default_command` as the path.
The [newer parser's retry](https://github.com/spectreconsole/spectre.console.cli/blob/0.57.2/src/Spectre.Console.Cli/Internal/CommandExecutor.cs)
inserts that sentinel after a parse failure. The pinned parser reports the
missing value correctly without custom parsing or sentinel-specific hacks.
Keep the invalid-usage tests when evaluating an upgrade.

Future `serve` is another command in this same registration method, reusing
the centralized path resolver and application services. It will start
ASP.NET Core/Kestrel, own DuckDB, and serve a browser UI and versioned REST API.
There is no separate desktop executable. HTTP forwarding and multi-process
coordination are deferred.

`ArtisanLogbook.Companion.Runtime` owns `ApplicationPaths`,
`CompanionSettingsStore`, and `InstallationDiscovery`. It references neither
Spectre nor DuckDB. Future monitoring/host/web components reuse these application
services, not CLI classes; the CLI owns only prompts, presentation, and command
orchestration. C04 and C07 remain unchanged. See [Runtime contracts](src/Runtime/README.md).

## Validation and live-data acceptance

```sh
dotnet format ArtisanLogbook.Companion.slnx --verify-no-changes
dotnet build ArtisanLogbook.Companion.slnx -c Release -warnaserror
dotnet test ArtisanLogbook.Companion.slnx -c Release --no-build
```

Companion CI builds/tests the executable and all five test projects on Ubuntu
and Windows. Tests use isolated paths, Spectre `TestConsole`, real DuckDB,
sanitized fixtures, and process-level lock checks; no WoW installation or user
configuration is required.
The milestone additionally tests strict settings/version validation, concurrent
atomic readers, cancellation and stale-wizard protection, permission/path
failures, manual/detected/repeat initialization, multi-root/flavor/account
discovery, links, partial imports, mixed Retail/Forever history, replay, and
byte-for-byte source preservation.

A locally supplied November 2026 schema-5 Retail snapshot was tested for PR #62 without
modifying it. **Live preservation acceptance passed** after correcting the
historical schematic evidence boundary:

| Measurement | Result |
|---|---|
| Observed detailed crafts | 2,560 |
| First import | Successful, exit 0; accepted/inserted 2,560, exclusions 0 |
| C07 source diagnostics | 1 `legacy-identity-lineage` warning, 44 `unknown-recipe` warnings, 3 informational `historical-recipe-schematic-variation` notices; errors 0 |
| Dimension insertions/enrichments | 748 / 0 |
| Status, then reimport | Canonical count 2,560; reimport exit 0, inserted 0, already-present 2,560, enriched 0, dimension changes 0 |
| Reopened status | Schema 2, canonical count 2,560; Retail project 1, progression unspecified |
| Exact persistence verification | All canonical observations equal their parsed source; all 1,065 craft-attached schematic snapshots preserved exactly |
| Source integrity | SHA-256 unchanged |

The original import was rejected because C04 promoted historical schematic
observations into one immutable recipe-slot dimension. Request and result
observations from different crafts contained different required quantities
**and** candidate item sets. The crafting facts themselves passed C01 validation.
The Companion is an observational history store, not an authoritative recipe
catalog: those supplementary snapshots now remain attached to their crafts,
with original record references, timestamps and fields. Variance is reported;
no winner, union of candidate sets, or inferred schematic is manufactured.
Canonical craft conflicts and explicit catalog-dimension conflict checks remain
strict. Regression tests cover cross-history and within-craft metadata variance,
exact persistence, idempotent evidence enrichment, round trips, and
continued canonical conflict rejection. The original file, identities, GUIDs,
account identifiers, and raw diagnostic traces are not committed.

This initialization/discovery milestone has deterministic sanitized-installation
acceptance only; no real WoW installation has been supplied or tested for the
new wizard. The prior live-snapshot results above are not live installation
discovery or interactive acceptance results.

## Current limitations

- Only `init`, explicit/configured `import`, and `status`; no `serve`, `validate`,
  monitoring, restoration, analytics, cloud sync, or checkpoints.
- C04 supports ledger schemas 1-5 and its data-only Lua subset; C07 caps file
  snapshots at 64 MiB and rejects files that change during the read. Import a
  settled copy saved after logout/reload; a stable read does not prove WoW has
  finished saving.
- Pruned aggregate-only history cannot be reconstructed. Legacy source lineage
  can collide across independently diverged clones. Contradictory canonical
  facts reject the whole snapshot rather than silently choosing a winner;
  differing well-formed supplementary schematics are retained as evidence.
- One writer per database; direct commands do not forward to a future server.
- No native macOS CI lane or packaged ARM acceptance in this milestone.
