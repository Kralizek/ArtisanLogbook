# Artisan Logbook Companion

The **Companion** is a separate, cross-platform .NET command-line tool for preserving Artisan Logbook crafting history outside World of Warcraft. It imports explicit `ArtisanLogbook_Core.lua` SavedVariables snapshots, or snapshots discovered under a configured WoW installation, into a local DuckDB database.

The Companion reads source files without modifying them. Importing a snapshot again is intended to be idempotent. Historical information already pruned from the addon cannot be reconstructed.

## Available commands

| Command | What it does |
| --- | --- |
| `artisanlogbook init` | Configure a WoW installation root interactively |
| `artisanlogbook import [source-file]` | Import one explicit snapshot, or discover snapshots using configured roots |
| `artisanlogbook status` | Show database status and craft counts without modifying the database |
| `artisanlogbook --help` | Show available help |

Both `import` and `status` accept `--database <path>` to override the default database location.

## Get started

The CLI currently requires the **.NET 10 SDK** to build from source.

From `src/companion`:

```sh
dotnet restore ArtisanLogbook.Companion.slnx
dotnet build ArtisanLogbook.Companion.slnx -c Release
dotnet run --project src/Cli/Cli.csproj -c Release -- --help
```

On Windows, a local development deployment script is available from the repository root:

```powershell
.\scripts\deploy-companion.ps1
```

This installs a local `al` command alias; it is **not a published end-user installer**. Open a new terminal after installation and run:

```text
al init
al import
al status
```

Alternatively, import one SavedVariables file explicitly:

```text
artisanlogbook import "/path/to/ArtisanLogbook_Core.lua"
```

## Scope and limitations

The Companion currently provides initialization, importing, and read-only status. It does **not** provide a web interface, analytics dashboard, automatic synchronization, restoration into WoW, or a background service. Aggregate-only history cannot be recovered as individual crafts.

Imports may include locally sensitive character/account information. Avoid sharing raw SavedVariables or diagnostic logs.

## More information

- [Command and configuration reference](../../docs/companion/cli.md): database paths, settings, discovery behavior, import and status details, and exit codes.
- [Contributing](../../CONTRIBUTING.md): build, tests, and local deployment.
- [Runtime contracts](src/Runtime/README.md): implementation-facing application services.
- [Main project](../../README.md).
