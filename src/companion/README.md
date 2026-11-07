# Artisan Logbook Companion MVP

One cross-platform .NET executable preserves crafting history from explicit
SavedVariables snapshots into **one authoritative DuckDB file for all game
contexts**. Import regularly, before the addon's detailed retention window
expires. The Companion never changes the source file.

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
artisanlogbook import <source-file> [--database <path>]
artisanlogbook status [--database <path>]
artisanlogbook --help
artisanlogbook import --help
artisanlogbook status --help
artisanlogbook --version
```

No arguments displays help. Spectre generates argument/option descriptions and
examples, validates settings, and rejects unknown commands/options, extra
arguments, missing arguments, and missing option values. Quote paths containing
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

Reports include resolved paths, observed source craft count, committed
inserted/already-present/enriched counts, rejected/conflicting count, dimension
changes, diagnostics (including source locations), and coverage warnings.
Warnings do not imply failure, but aggregate-only history is **not recovered**
and is never counted as canonical crafts. Diagnostic text may contain private
source information; do not upload raw terminal logs or SavedVariables.

Example using the **sanitized repository fixture**, not live user data
(tables condensed):

```text
Import successful.
Observed source crafts       15
Inserted crafts              15
Already-present crafts        0
Enriched crafts               0
Rejected/conflicting crafts    0
Inserted dimensions          20
Enriched dimensions           0
Aggregate-only history: 3 attempts lack retained detail.
These are not canonical crafts and were not recovered.
```

On repeat import: inserted 0, already-present 15, enriched 0, dimension changes 0.

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
| 0 | Successful import/status/help/version; also missing-database status |
| 1 | CLI parsing or settings-validation error |
| 2 | Import rejected: malformed/unsupported source, validation, or conflict |
| 3 | Failed operation: source read, permissions, database/lock/schema failure |

## Architecture and Hyde conventions

[Hyde's CLI](https://github.com/Kralizek/Hyde/blob/master/src/Hyde/Program.cs)
is the reference: `CommandApp`, Microsoft `ServiceCollection`,
`DependencyInjectionRegistrar`, described commands with validated examples,
shared base settings and command-local nested settings, asynchronous import
commands, and Spectre tables. Unlike Hyde's static `AnsiConsole` usage, this
Companion injects `IAnsiConsole` for testable output and configures Spectre's
help/error renderer to use that same console. No site configuration interceptor
is needed: explicit paths and one-shot commands do not require a configuration
file or generic host.

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

A locally supplied November 2026 schema-5 Retail snapshot was tested without
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

## Current limitations

- Only explicit `import` and `status`; no `serve`, `validate`, monitoring,
  installation discovery, restoration, analytics, cloud sync, or checkpoints.
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
