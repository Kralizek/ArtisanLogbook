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
replacement are not supported. No recursive scan, watcher, periodic work, file
archive, or state mutation is performed by discovery itself. The hosted C06
monitor uses these bounded discovery results during reconciliation.

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

Future browser controls must save user preferences through
`CompanionSettingsStore`, then explicitly resolve the effective snapshot with
the retained overrides. Precedence remains **invocation overrides > persisted
user preferences > defaults**. Public controls must deliberately report both
saved preference and effective value, and whether an invocation override is
active. For example, with `--monitoring false`, saving enabled should report
"preference saved; monitoring remains disabled by invocation override", never
claim that effective monitoring was enabled. The opposite override is symmetric.

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
state or monitoring statistics are maintained. Startup/status failures are
explicit and structured `ILogger` records use failure codes and exception types,
not raw sources, account IDs, or installation paths. Detailed command failures
remain available to diagnose configuration/schema/ownership problems.
Startup emits the application-started event separately from concise effective
settings lines for SavedVariables monitoring, its reconciliation interval, and
the HTTP preferred port; once started it logs the actual listening URL
(`HTTP API listening on ...`). Disabled monitoring is reported as
`SavedVariables monitoring: off`; enabled is reported as `on`. Startup also logs each configured WoW game directory
and the direct client flavors where
`Interface/AddOns/ArtisanLogbook_Core/ArtisanLogbook_Core.toc` exists, or
`(none detected)`. Other client directories and unrelated addons are not
listed. This bounded check does not require SavedVariables to exist. Game
directory paths are shown explicitly for startup diagnostics; history database
paths remain unlogged. Flavor directory names are presentation labels only and
never establish a saved craft's GameContext.

## Hosted monitoring and API

C06 is an opt-in `SourceMonitor` hosted in the existing `serve` application. It
does not create another host, database writer, or import queue. The versioned
`/api/v1/monitoring` endpoints are authored in `Api/Contracts/openapi.yaml` and
implemented with the same MinimalOpenAPI generator, local request security, and
Problem Details behavior as C11.

`SourceMonitor` uses a shared invalidation stream rather than long-lived groups
per source. Each installation root has a recursive `FileSystemWatcher`; typed
events identify the source location, and `GroupByUntil`/`Throttle` coalesce
events independently by stable source ID while expiring quiet groups. Root
watcher failures retry with bounded exponential delay. An injected Rx scheduler
drives periodic reconciliation, debounce, retry, and stabilization timers.
Filesystem events only request work: periodic discovery and SHA-256 snapshots
recover missed events and determine whether content changed.

One `Concat`-serialized Rx pass consumes invalidations. A one-bit pending flag
retains at most one follow-up pass while a scan is active, so event bursts do not
become an unbounded queue and a change during a scan is not lost. `Switch`
disposes watcher/timer subscriptions on runtime disable, enable, or shutdown.
Pass failures are contained and retried; watcher and worker failures remain
visible in status diagnostics.

Successful file imports return the SHA-256 fingerprint calculated from the
exact stable byte snapshot consumed by C07. `MonitoringCheckpointStore` persists
observed and ingested fingerprints, availability, pending state, and retry time
atomically outside canonical craft history. Import-completion notifications
remain in a bounded source-keyed pending map until their effects are durable.
If that map overflows, the monitor reconciles current files and may safely
re-import; it never invents a successful checkpoint. A changed file remains
pending when a source is busy, capacity is exhausted, or a retry is deferred.
Manual and automatic work share C11 `ImportOperations`, source admission,
capacity limits, C10 shutdown handling, and the single C07 execution path.

Settings updates persist through `CompanionSettingsStore` before changing the
effective runtime state. CLI invocation overrides remain authoritative.
Disabling prevents new automatic submissions; accepted imports retain C11's
shutdown behavior. At shutdown the monitor disposes subscriptions and awaits
checkpoint work before C10 releases the shared writer.

## C06 architecture comparison

This experiment was implemented from `master`; [PR #72](https://github.com/Kralizek/ArtisanLogbook/pull/72)
was used only as a behavioral reference. Counts below compare the core monitor
and checkpoint code at PR #72's latest revision (`b9b9426`) with this experiment.
Code lines exclude blank and comment-only lines; the Rx total includes the
48-line stable-snapshot reader extracted for C07's exact-byte fingerprint.

| Criterion | PR #72 | Rx experiment |
|---|---|---|
| Core production code | 970 code lines (monitor and checkpoint store) | 964 (monitor, checkpoint store, snapshot reader): only 6 fewer |
| Monitor synchronization | 4 lock objects, a bounded signal channel, and a pass semaphore | 2 lock objects; Rx `Concat` serializes passes and a one-bit pending flag bounds invalidations |
| Scheduling and recovery | Explicit worker, signal draining, and timer coordination | `Merge`, `GroupByUntil`/`Throttle`, `Concat`, `Switch`, and `RetryWhen`; retry policy and application state remain explicit |
| Source management | Explicit watcher coordination | Shared invalidation stream with expiring per-source groups; root watcher recovery remains explicit |
| Checkpoint correctness | Explicit durable state | Still explicit and nearly the same size (91 vs. 92 code lines); Rx does not simplify completion ordering or durable persistence |
| Testability | Real-time coordination tests | Injected scheduler supports virtual-time periodic/debounce/retry tests |
| Dependencies | No Rx dependency | Adds `System.Reactive` at runtime and `Microsoft.Reactive.Testing` in tests |

The experiment removes some bespoke stream coordination and reduces the number
of synchronization objects, but the measured production-code reduction is
negligible. Durable checkpoint ordering, import admission, overflow recovery,
and lifecycle state still require explicit application code; Rx also adds
operator semantics and a production dependency that maintainers must understand.
The recommendation is to **retain PR #72 as the implementation baseline** and
consider a narrowly scoped scheduler/coalescing improvement only if it can be
shown to simplify those specific paths without adopting a second coordination
model. The Rx rewrite is useful as a virtual-time testing reference, but it does
not demonstrate a material maintainability improvement overall.

## Host lifecycle

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
shutdown.

See the [Companion guide](../../README.md) for command flow, configuration
locations, diagnostics, and operational limitations.
