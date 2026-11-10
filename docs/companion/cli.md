# Companion CLI reference

This document covers the current Companion CLI in more detail. Start at the [Companion README](../../src/companion/README.md) for installation and quick usage.

## Database location

| Platform | Default |
|---|---|
| Windows | `%LOCALAPPDATA%\ArtisanLogbook\Companion\history.duckdb` |
| macOS | `~/Library/Application Support/ArtisanLogbook/Companion/history.duckdb` |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/ArtisanLogbook/Companion/history.duckdb` |

Linux ignores empty or relative `XDG_DATA_HOME`, as required by XDG conventions.
`--database` completely overrides the default. Import and serve create parent directories
and initializes the complete schema v2 directly. Old C03 development databases
are unsupported: use a new database path and reimport SavedVariables. No old
database is migrated, deleted, or overwritten. Status uses DuckDB's read-only access mode, does not
migrate schemas, and does not create a missing file or directory. Unrecognized
or unsupported schemas fail explicitly. Defaults never use the executable
directory; an unavailable user data directory requires an explicit override.

## Initialization and shared settings

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
requires an integer `version` and an `installationRoots` array of normalized
absolute paths, with optional `monitoring` and `http` objects. It has no credentials, account IDs, character IDs, flavor
settings, or database overrides. For example on Linux:

```json
{
  "version": 1,
  "installationRoots": [
    "/games/World of Warcraft"
  ],
  "monitoring": {
    "enabled": false,
    "reconciliationIntervalSeconds": 60
  },
  "http": {
    "preferredPort": 48721
  }
}
```

The model and discovery support multiple roots now. This wizard manages the
first root and preserves additional roots and monitoring/HTTP preferences. There is no `config set/get`
command. Settings use strict, human-readable JSON; missing required, duplicate, unknown,
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

The settings version remains **1**; there is no migration. Existing files with
only `version` and `installationRoots` load unchanged. Omitted monitoring settings
mean **enabled**, with a 60-second reconciliation interval; omitted HTTP
settings mean preferred port **48721**. An omitted property inside either object
also uses its built-in default. Explicit `null` objects are invalid. Intervals
must be integers from **1 through 86400 seconds**; ports must be integers from
**1 through 65535**. Unknown and duplicate properties are rejected at every level.
Saving includes the additive preferences; merely loading or serving never saves.
Existing files with an explicit `"enabled": false` remain disabled, including
after unrelated preference updates. Use `serve --monitoring false` to disable
monitoring for one invocation without saving a preference.

## Serve

```text
al serve
al serve --database history.duckdb --port 48722
al serve --monitoring false --reconciliation-interval 120
al serve --monitoring true
```

`serve` alone constructs and owns the .NET Generic Host (`WebApplication`).
`init`, `import`, `status`, help, and version remain short-lived and do not build
or start a host. The existing `al` deployment alias invokes the same executable.
Framework-dependent installations now require the ASP.NET Core 10 runtime as
well as .NET 10; the SDK and self-contained Windows deployment supply it.

Configuration precedence is **invocation CLI overrides > persisted settings >
built-in defaults**. `--database` continues selecting the database independently
of settings. `--monitoring <BOOL>`, `--reconciliation-interval <SECONDS>`, and
`--port <PORT>` override only the current invocation and never persist. Invalid
CLI options return 1. Invalid, unreadable, or unsupported persisted settings
return 3 even if overrides would otherwise mask their invalid values. With no
settings file, serve uses defaults and no installation roots without creating
settings; `init` is not a prerequisite.

Internally, saved preferences and invocation overrides are retained separately
from the effective configuration. Runtime preference changes cannot
discard an explicit invocation override: controls must distinguish "preference
saved" from "effective monitoring changed". The
[monitoring API](api.md#monitoring) persists preferences and applies effective
changes immediately. Settings-file hot reload is not supported.

Startup validates configuration and opens one writable C03 History Store, shared
with C07. Offline installations, absent SavedVariables, and empty craft history
are supported. With effective monitoring disabled, startup does not import.
Enabled monitoring immediately discovers sources, watches for changes, and
periodically reconciles stable snapshots. Manual and automatic imports share
the same bounded import coordinator and writer. Monitoring reads but never
modifies SavedVariables; removed sources do not remove canonical history.

### Operational logging

`serve` uses a synchronous Spectre.Console logging provider in the CLI project;
Runtime and monitoring services retain standard structured `ILogger<T>` templates.
Interactive ANSI terminals get muted timestamps, compact colored severities,
restrained icons, and contextual properties below each message. Logs scroll
normally; there is no dashboard or screen clearing. Redirected output, CI, and
terminals without ANSI support use readable timestamped plain text. Messages,
properties, scopes and exceptions are rendered as literal text with terminal
control characters sanitized. Concurrent entries are rendered atomically.

Information events describe enabled/disabled monitoring, effective interval and
root count, watcher readiness/recovery, meaningful reconciliation summaries,
automatic import admission and import outcomes/counts, and shutdown. Summaries
include combined trigger reasons, discovered sources, submitted imports, duration,
diagnostic codes and pending sources. A healthy periodic pass still logs when
nothing changed. Repeated watcher/checkpoint outages warn once until recovery;
unexpected failures retain error details. The one-second checkpoint maintenance
evaluation does not emit Information heartbeats.

Debug events include settled file-change hints, reconciliation starts, unchanged
sources, superseded fingerprints, source inspection failure codes and exception
details. `source-changed-during-read` is an expected unstable write, distinct from
`source-read-failed` (inaccessible source) and `invalid-source-encoding`. Short-term
byte stability is not semantic completeness: parser/import validation and retries
remain authoritative for temporarily incomplete writes. The two reads, existing
250 ms quiet interval, metadata/byte comparisons, strict UTF-8, and C07's exact
imported-byte checkpoint identity are unchanged. No historical file copies are kept.

Standard .NET logging configuration controls filtering, including environment
variables such as `Logging__LogLevel__Default=Debug` or
`Logging__LogLevel__ArtisanLogbook.Runtime=Debug`. Microsoft and ASP.NET Core
warnings/errors remain visible. Console logging has one owner: the Spectre
registration replaces the framework console provider without clearing other
logging providers.

Set `Logging__SpectreConsole__IncludeScopes=true` to include logging scopes
(off by default), or `Logging__SpectreConsole__ForcePlainText=true` to request
plain text even in an ANSI terminal. Provider-specific filters use the standard
`Logging__SpectreConsole__LogLevel__<category>` keys.

### HTTP and shutdown

Kestrel binds **IPv4 loopback only** (`127.0.0.1`) on the effective preferred port,
falling back to an OS-assigned loopback port only when that port is already in use.
The actual URL is printed at startup. The local `/api/v1/` HTTP API and its
OpenAPI document are described in [Local HTTP API](api.md). Bundled browser assets
at `/` belong to C12.

The process stays active without a browser. Ctrl+C, SIGTERM, or normal host
shutdown stops hosted work and disposes the writer, releasing database ownership.
New runtime import requests are rejected once stopping begins; already admitted
work may complete or roll back before the writer is disposed. Shutdown cancellation
is passed to workers, not used to prematurely close the database beneath them.
Transactional writes retain C03's serialization, commit, and cancellation rollback
behavior. Failed startup also disposes acquired resources. Forced termination
cannot guarantee graceful disposal; DuckDB's WAL/transaction guarantees still apply.

DuckDB's native process-level file lock is authoritative: no ownership file,
database/WAL deletion, IPC, or HTTP forwarding is used. A second `serve`, or a
manual `import`/`status` in another process, fails clearly while the writer owns
the selected database. Stop serve and retry. Different databases are independent,
although each host must use an available port.

## Installation and SavedVariables discovery

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

## Import

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

### Normal output

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

### Attribution and suppression

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

Enrichment comparisons match the underlying history contracts: output/reagent
rows use order-independent value equality with occurrence multiplicity preserved
(C01 also rejects duplicate canonical grains). Evidence uses C03's sequence
equality, preserving multiplicity and C01's ordered output callbacks. C02 sorts
and deduplicates evidence when merging two non-null collections, but can retain
duplicates when one side is null; reporting does not assume uniqueness.

Unknown recipes are valid incomplete evidence, **not rejected crafts**.
Aggregate-only history is **not recovered** and is never counted as canonical
crafts. Files that fail/reject are identified by full path with actionable
details and an explicit no-commit statement. Other valid files remain committed;
partial success and existing nonzero exit codes are preserved.

### Verbose output

`--verbose` works with installation and explicit-file imports:

```text
artisanlogbook import --verbose
artisanlogbook import snapshot.lua --verbose
```

It adds full source/database paths, the existing detailed C07 craft/dimension
counters, observed counts, all source/coverage diagnostics (including normally
suppressed ones), original locations and messages, validation and reconciliation
details, input/persistence failures, discovery diagnostics, per-file outcomes,
aggregate coverage detail, and installation totals. It is presentation-only:
parsing, identity, reconciliation, transaction boundaries, persistence, and exit
codes are identical to normal mode.

Diagnostic text, paths, and account labels may contain private source
information; do not upload raw terminal logs or SavedVariables.

## Status

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
processes. `status` never starts a host, watcher, server, or background service.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Successful init/import/status/help/version, clean serve shutdown; also canceled init and missing-database status |
| 1 | CLI parsing/settings-validation error, missing installation configuration, or noninteractive init |
| 2 | Import rejected: malformed/unsupported source, validation, or conflict |
| 3 | Failed operation: source read, permissions, database/lock/schema/configuration failure, no ledgers, or incomplete discovery |

## Operational boundaries

Only `serve` starts the local application host and can monitor source files.
No command synchronizes automatically or recovers aggregate-only history that
has already lost per-craft detail. Only one process should write to a DuckDB file at a time.
Do not delete a database's write-ahead log to resolve a lock.

Source snapshots can contain private game account or character data. Back them up, and share only sanitized fixtures or redacted diagnostics.

## Implementation reference

For service ownership and runtime contracts, see [Companion Runtime](../../src/companion/src/Runtime/README.md). Development tests and CI instructions live in [CONTRIBUTING](../../CONTRIBUTING.md).
