# Companion application runtime services (C06/C10)

This library has no Spectre, DuckDB, host, or addon dependencies. The CLI is its
first consumer; future monitoring and web hosts should use these same services.

- `ApplicationPaths`: one shared per-user data directory, default history path,
  settings path, and working-directory-relative explicit path resolution.
- `CompanionSettings`: schema version 1 and multiple absolute installation roots.
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
archive, or background service is introduced.

See the [Companion guide](../../README.md) for command flow, configuration
locations, diagnostics, and operational limitations.
