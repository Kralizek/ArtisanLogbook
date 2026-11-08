# Companion application runtime services (C06/C10)

This library composes C03/C07 and the ASP.NET Core shared framework for C10.
Settings, paths, and discovery remain independent of host execution and Spectre.
The existing CLI is the sole application entry point: only `serve` builds a host.

- `ApplicationPaths`: one shared per-user data directory, default history path,
  settings path, and working-directory-relative explicit path resolution.
- `CompanionSettings`: schema version 1, multiple absolute installation roots,
  optional monitoring preferences (disabled, 60 seconds), and HTTP preferences
  (port 48721). Older version-1 files load without migration or writes.
- `CompanionSettingsStore.Load()`: structured `Loaded`, `Missing`, `Invalid`,
  `Unsupported`, or `Unreadable` result, diagnostic, and opaque revision.
  Loading never creates files. Root availability is checked by discovery, not
  by deserialization.
- `Save(settings, cancellationToken, expected)`: strict validation, refusal to
  overwrite invalid/unreadable/unsupported files, revision comparison, flushed
  same-directory temporary file and atomic replacement. Pass the wizard's load
  result as `expected` to reject concurrent changes. No migration or repair is
  implicit. Application-level writers must be serialized; external changes
  between the final check and rename cannot be compare-and-swapped portably.
- `InstallationDiscovery.DefaultHints`/`CurrentHints` and `Detect(hints)`:
  bounded OS hints with layout validation, not recursive launcher/drive scans.
- `ValidateRoot(root)`: a root with a direct client containing `WTF/Account` or
  `Interface/AddOns`. A new installation can have no saved ledgers.
- `DiscoverSavedVariables(roots)`: normalized sorted Core ledger paths and
  structured path/code/severity/message diagnostics. Missing optional layout
  branches are normal. Configured-root enumeration and known source-branch
  failures are errors; incidental client-candidate/addon-layout inspection
  failures and skipped links are warnings. All remain explicit. Consumers
  should use `HasErrors`, not diagnostic count, to determine incomplete discovery.

All discovery results are read-only inspections. They do not parse sources,
establish game identity, import, or prove WoW has finished saving. Only C04
determines GameContext from ledger evidence, and only C07 imports files using
its existing stable-byte-read checks and per-file transaction.

Directory/ledger links are not followed, including installation-root ancestors.
Normalized aliases are deduplicated using the OS comparer; hard-link identity,
case-insensitive Unix volume detection, and adversarial concurrent filesystem
replacement are not supported. No recursive scan, watcher, periodic work, file
archive, or monitoring worker is introduced.

## Host composition and ownership

`serve` resolves `CompanionRuntimeConfiguration`, constructs a
`WebApplication.CreateEmptyBuilder`, calls `ConfigureCompanionHost(configuration)`
and `AddArtisanLogbookCompanion(paths, configuration)`, builds the application,
and awaits `RunCompanionAsync()`. Empty-builder configuration deliberately avoids
an unrelated appsettings/environment configuration pipeline. Explicit precedence
is CLI overrides, persisted Companion settings, then defaults. Invalid persisted
settings fail before overrides are applied; missing settings use defaults without
being saved. All settings writers continue using the single settings store.

Registration provides paths, invocation configuration, settings access,
installation discovery, one singleton C03 writer, singleton C07 importer, and
`CompanionApplicationStatus`. Duplicate history ownership registration is rejected.
`CompanionRuntimeLifecycle` uses standard `IHostedLifecycleService` and
`IHostApplicationLifetime`: startup opens and verifies C03 before successful host
startup; ApplicationStarted reports Running, ApplicationStopping reports Stopping,
and StoppedAsync closes the database after all workers' StopAsync calls. Disposal
also closes the writer after partial startup failures. C03's transaction gate
ensures disposal cannot race an in-progress transactional write. No database,
source, or craft semantics have changed.

DuckDB locking, not a second lock/ownership persistence system, rejects other
processes. Short-lived CLI commands retain their own existing open/dispose
behavior and actionable contention errors; they do not forward requests.

`CompanionApplicationStatus.Read()` returns the entry application's informational
version, startup UTC time, lifecycle state, effective configuration, database
availability/schema version, canonical count, and current critical failure.
Counts are queried via C03 `ReadStatus()` on every read; no duplicate history
state or monitoring statistics are maintained. Startup/status failures are
explicit and structured `ILogger` records use failure codes and exception types,
not raw sources, account IDs, or installation paths. Detailed command failures
remain available to diagnose configuration/schema/ownership problems.

## Extension points

The same WebApplication already owns embedded Kestrel on IPv4 loopback.
There are no routes/assets or advertised browser URL. Occupied ports currently
fail startup; C11 will add free-port fallback in host configuration and register
versioned `/api/v1/` Minimal API endpoints after Build and before Run, with the
selected **MinimalOpenAPI** implementation (not Swashbuckle/NSwag). C12 will serve
bundled static assets at `/`. Neither requires another host or executable.

C06 will register hosted monitoring workers after runtime registration and use
the same settings/discovery services and shared C07 importer. Workers must honor
ApplicationStopping and stop/drain transactional work in StopAsync before the
runtime closes C03. Monitoring remains explicitly opt-in; no monitoring or
automatic imports run in this foundation, even with the enabled preference.
Future operational status can extend `CompanionStatus` with real source,
reconciliation, import, and sync information. No scheduler, channel, persistent
checkpoint, or dynamic configuration framework is pre-created.

See the [Companion guide](../../README.md) for command flow, configuration
locations, diagnostics, and operational limitations.
