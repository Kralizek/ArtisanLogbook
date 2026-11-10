# Companion application runtime services (C06/C10)

This library composes C03/C07 and the ASP.NET Core shared framework for C10.
Settings, paths, and discovery remain independent of host execution and Spectre.
The existing CLI is the sole application entry point: only `serve` builds a host.

- `ApplicationPaths`: one shared per-user data directory, default history path,
  settings path, and working-directory-relative explicit path resolution.
- `CompanionSettings`: schema version 1, multiple absolute installation roots,
  optional monitoring preferences (enabled, 60 seconds), and HTTP preferences
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
- `DiscoverFlavors(roots)`: reports only client directories containing the
  ArtisanLogbook Core addon's own TOC file; ordinary client folders and
  unrelated addons do not count as an ArtisanLogbook installation.

All discovery results are read-only inspections. They do not parse sources,
establish game identity, import, or prove WoW has finished saving. Only C04
determines GameContext from ledger evidence, and only C07 imports files using
its existing stable-byte-read checks and per-file transaction.

Directory/ledger links are not followed, including installation-root ancestors.
Normalized aliases are deduplicated using the OS comparer; hard-link identity,
case-insensitive Unix volume detection, and adversarial concurrent filesystem
replacement are not supported. Discovery itself does not watch or import.
C06 uses root-level watchers as hints, then repeats the same bounded layout
inspection; it never replaces discovery with a recursive ledger scan.

## Host composition and ownership

`serve` resolves `CompanionRuntimeConfiguration`, constructs a
`WebApplication.CreateEmptyBuilder`, calls `ConfigureCompanionHost(configuration)`
and `AddArtisanLogbookCompanion(paths, configuration)`, builds the application,
and awaits `RunCompanionAsync()`. Empty-builder configuration deliberately avoids
an unrelated appsettings/environment configuration pipeline. Explicit precedence
is CLI overrides, persisted Companion settings, then defaults. Invalid persisted
settings fail before overrides are applied; missing settings use defaults without
being saved. All settings writers continue using the single settings store.

`CompanionRuntimeConfiguration` is an invocation snapshot, not a settings document:
`PersistedPreferences` retains the loaded user preference snapshot (null if no
settings file), `InvocationOverrides` retains each explicitly supplied CLI value
(null means not supplied), and `EffectiveSettings` is the validated resolved
result. Defaults for omitted JSON properties are applied by the existing settings
model. A saved false and a CLI false remain distinguishable, even when they
produce the same effective value. `WithPersistedPreferences` is pure resolution
of a new saved snapshot with the original invocation overrides; it neither saves
nor changes the running host. There is no hot reload in C10.

Monitoring controls save user preferences through
`CompanionSettingsStore`, then explicitly resolve the effective snapshot with
the retained overrides. Precedence remains **invocation overrides > persisted
user preferences > defaults**. Public controls must deliberately report both
saved preference and effective value, and whether an invocation override is
active. For example, with `--monitoring false`, saving enabled should report
"preference saved; monitoring remains disabled by invocation override", never
claim that effective monitoring was enabled. The opposite override is symmetric.
`SourceMonitor` owns the current resolved monitoring configuration; the original
invocation configuration remains the startup snapshot. No general-purpose
mutable configuration framework is introduced.

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
Both `CompanionStatus` and its provider are assembly-internal. They are operational
models for Runtime composition, **not approved HTTP response contracts**. Future
C06/C11 services implemented in this project can consume them; separate component
assemblies must not expose them by widening visibility without a deliberate
boundary decision. C11 must map selected fields to public, versioned DTOs.
Never automatically serialize the internal status or configuration: database
paths, installation roots, configuration internals, and sensitive operational
information are not public API data. Public DTOs are generated from the C11 OpenAPI contract in `Api/`
(see `docs/companion/api.md`) and mapped from these internal types.
Counts are queried via C03 `ReadStatus()` on every read; no duplicate history
state is maintained. C06 reports its own actual reconciliation/checkpoint state
through explicitly mapped monitoring DTOs. Startup/status failures are
explicit and structured `ILogger` records use failure codes and exception types,
not raw sources, account IDs, or installation paths. Detailed command failures
remain available to diagnose configuration/schema/ownership problems.
Startup emits the application-started event separately from concise effective
settings lines for SavedVariables monitoring, its configured
reconciliation interval, and the HTTP preferred port; once started it logs the
actual listening URL (`HTTP API listening on ...`). Disabled monitoring is
reported as `SavedVariables monitoring: off`; enabled is reported as `on`.
Startup also logs each configured WoW game directory
and the direct client flavors where
`Interface/AddOns/ArtisanLogbook_Core/ArtisanLogbook_Core.toc` exists, or
`(none detected)`. Other client directories and unrelated addons are not
listed. This bounded check does not require SavedVariables to exist. Game
directory paths are shown explicitly for startup diagnostics; history database
paths remain unlogged. Flavor directory names are presentation labels only and
never establish a saved craft's GameContext.

## Extension points

The same WebApplication owns embedded Kestrel on IPv4 loopback, with free-port
fallback and versioned `/api/v1/` endpoints generated by **MinimalOpenAPI**.
C12 may add bundled static assets at `/`. No feature requires another host or executable.

C06 is registered after the runtime lifecycle and before C11's import worker.
It waits for ApplicationStarted before source work, and uses the same
settings/discovery services. Automatic and HTTP manual imports both use
`ImportOperations`; its single worker calls `CompanionRuntimeImports`, which holds a
`CompanionWorkAdmission.Admit()` lease around the existing C07 operation. Before
startup and once stopping begins, admission rejects explicitly with a logged
error and an exception. A future worker coordinating longer-lived work may hold
a lease itself and call shared C07 directly for **already admitted** work. Hold
the lease through commit/rollback and release it in `using`/`finally`; do not
re-admit existing work during shutdown. Manual CLI imports still use C07 directly
and are unaffected.

The [.NET 10 Generic Host lifecycle implementation](https://github.com/dotnet/runtime/blob/v10.0.0/src/libraries/Microsoft.Extensions.Hosting/src/Internal/Host.cs)
stops in reverse registration order within each phase: all `StoppingAsync` hooks,
`ApplicationStopping`, all `StopAsync` calls, then all `StoppedAsync` hooks.
Shutdown errors are aggregated rather than skipping later phases. Runtime closes
admission in its StoppingAsync hook and in ApplicationStopping (which may be
signaled first by external termination), and waits for outstanding leases in
StoppedAsync before disposing C03. Workers must stop admitting new work when
shutdown begins and drain in StopAsync; they must not defer database work to
StoppedAsync. The guarantee does not depend on sequential StopAsync execution.

Pass request/worker cancellation tokens into C07. The host's shutdown token can
cancel worker work, but stopping does not immediately cancel every admitted
request or dispose its connection. Drain waits even if the shutdown token is
canceled, allowing admitted transactional work to commit or roll back before
ownership is released. RunCompanionAsync also closes admission and drains in
finally before host disposal after startup/shutdown failure. Workers must observe
cancellation and release leases; an uncooperative worker can delay graceful
shutdown, and forced termination still relies on DuckDB transactional safety.
Always run/stop the host before disposal; DI disposal alone is not worker
shutdown. C06 adds no ingestion queue or per-flavor worker.

## Monitoring ownership

- `SourceChangeFeed` owns cold watcher subscriptions, per-source debounce groups,
  periodic ticks and recoverable watcher errors. Disposal tears down the whole
  activation; inactive source groups expire.
- `SourceReconciler` is an independently callable discovery, inspection and C11
  admission operation. It neither owns Rx nor writes canonical history.
- `MonitoringCheckpoints` owns immutable per-source transitions and explicit
  durable acknowledgement. C11 delivers terminal receipts directly, before
  operation-history eviction; notifications are merely wake-up hints.
- `SourceMonitor` applies preferences and composes producer sessions with
  `Switch`, then serializes work through bounded latest-pending concat. It never
  replaces an active reconciliation until that operation has unwound.

Checkpoint maintenance also runs when monitoring is disabled. Shutdown first
disposes source producers (including on ApplicationStopping), then drains
reconciliation and C11 imports. C06's StoppedAsync flushes only monitoring
metadata after **all** workers' StopAsync calls; it performs no canonical write.
Save failure remains unacknowledged and fails graceful shutdown explicitly.

See [the architecture assessment](../../../../docs/companion/rx-monitoring-architecture.md)
for state ownership, synchronization invariants, exact-byte snapshot identity
and acknowledgement semantics. The [HTTP guide](../../../../docs/companion/api.md#monitoring)
documents control behavior and sidecar recovery.

See the [Companion guide](../../README.md) for command flow, configuration
locations, diagnostics, and operational limitations.
