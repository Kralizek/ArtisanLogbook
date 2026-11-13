# Artisan Logbook Companion

The **Companion** is a separate, cross-platform .NET command-line tool for preserving Artisan Logbook crafting history outside World of Warcraft. It imports explicit `ArtisanLogbook_Core.lua` SavedVariables snapshots, or snapshots discovered under a configured WoW installation, into a local DuckDB database.

The Companion reads source files without modifying them. Importing a snapshot again is intended to be idempotent. Historical information already pruned from the addon cannot be reconstructed.

## Available commands

| Command | What it does |
| --- | --- |
| `artisanlogbook init` | Configure a WoW installation root interactively |
| `artisanlogbook import [source-file] [--verbose]` | Import one explicit snapshot, or discover snapshots using configured roots |
| `artisanlogbook status` | Show database status and craft counts without modifying the database |
| `artisanlogbook serve` | Run the local Companion host until Ctrl+C or termination |
| `artisanlogbook --help` | Show available help |

`import`, `status`, and `serve` accept `--database <path>` to override the default database location.

Normal imports show concise change summaries and relevant new diagnostics;
unchanged successful reimports suppress known historical warnings. Use
`--verbose` for full paths, detailed counts, and all current diagnostics.
Failures and discovery diagnostics remain visible in both modes.

## Get started

Building from source requires the **.NET 10 SDK** and **Node.js 26.13.1 LTS**
with npm 11. Node is build/development tooling only, not a runtime dependency.

From `src/companion`:

```sh
dotnet restore ArtisanLogbook.Companion.slnx
dotnet build ArtisanLogbook.Companion.slnx -c Release
dotnet run --project src/Cli/Cli.csproj -c Release -- --help
```

On Windows, a local development deployment script is available from the repository root:

```powershell
.\scripts\Deploy-Companion.ps1
```

This installs a local `al` command alias; it is **not a published end-user installer**. Open a new terminal after installation and run:

```text
al init
al import
al status
al serve
```

Alternatively, import one SavedVariables file explicitly:

```text
artisanlogbook import "/path/to/ArtisanLogbook_Core.lua"
```

Both forms support complete diagnostic reporting:

```text
artisanlogbook import --verbose
artisanlogbook import snapshot.lua --verbose
artisanlogbook import --help
```

## Scope and limitations

The Companion provides initialization, importing, read-only status, and a
long-running local host. `serve` owns the database until shutdown; other processes
cannot import or inspect it while that writer is active. Stop the host before
using manual database commands. Monitoring defaults to enabled. Disable it with
`serve --monitoring false` for one invocation, or persist preferences through the
[monitoring API](../../docs/companion/api.md#monitoring). Enabled monitoring
discovers configured accounts and client flavors, watches for changes, and
periodically reconciles stable SavedVariables snapshots through the same importer.
Older settings with omitted monitoring preferences use the new default without
being rewritten. An explicit saved `"enabled": false` remains disabled.

The host binds loopback only and serves the [local HTTP API](../../docs/companion/api.md)
(`/api/v1`, OpenAPI at `/openapi/v1.yaml`); the URL is printed at startup. It has
browser overview and recent-crafts pages at `/` and `/history`. It does **not**
provide the complete C12 analytics dashboard, automatic synchronization, restoration into WoW, or OS service
installation. Aggregate-only history cannot be recovered as individual crafts.

Imports may include locally sensitive character/account information. Avoid sharing raw SavedVariables or diagnostic logs.

## More information

- [Local HTTP API](../../docs/companion/api.md): endpoints, port selection, curl examples, and local security model.
- [Command and configuration reference](../../docs/companion/cli.md): database paths, settings, discovery behavior, import reporting and suppression, verbose output, status details, and exit codes.
- [Contributing](../../CONTRIBUTING.md): build, tests, and local deployment.
- [Runtime contracts](src/Runtime/README.md): implementation-facing application services.
- [Browser application](../../docs/companion/web.md): embedded production packaging,
  Aspire development, generated API clients, fixtures and smoke verification.
- [Main project](../../README.md).
