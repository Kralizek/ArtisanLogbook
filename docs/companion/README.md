# Companion documentation

The [Artisan Logbook Companion](../../src/companion/README.md) is a .NET CLI that
imports addon SavedVariables into a local DuckDB history database and owns the
long-running local application through `serve`.

## Getting started

- [Companion overview and quick start](../../src/companion/README.md) — capabilities, building and primary commands.
- [CLI and configuration reference](cli.md) — initialization, database paths, importing, status, discovery and exit codes.

## Technical reference

Implementation-facing contracts remain close to the source:

- [Runtime services](../../src/companion/src/Runtime/README.md)
- [Core](../../src/companion/src/Core/README.md)
- [SavedVariables](../../src/companion/src/SavedVariables/README.md)
- [Import service](../../src/companion/src/ImportService/README.md)
- [History store](../../src/companion/src/HistoryStore/README.md)

For build and test commands, see [CONTRIBUTING](../../CONTRIBUTING.md).
