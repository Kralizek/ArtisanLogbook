# Companion documentation

The [Artisan Logbook Companion](../../src/companion/README.md) is a .NET CLI that
imports addon SavedVariables into a local DuckDB history database and owns the
long-running local application through `serve`.

## Getting started

- [Companion overview and quick start](../../src/companion/README.md) — capabilities, building and primary commands.
- [Local HTTP API](api.md) — endpoints, port selection, curl examples and the local security model.
- [Canonical history GraphQL API](graphql.md) — schema, queries, identity, pagination and resource limits.
- [Browser application foundation](web.md) — embedded SPA, Aspire, typed clients, fixture data and single-executable verification.
- [CLI and configuration reference](cli.md) — initialization, database paths, importing, status, discovery and exit codes.

## Technical reference

Implementation-facing contracts remain close to the source:

- [Runtime services](../../src/companion/src/Runtime/README.md)
- [Rx monitoring architecture](rx-monitoring-architecture.md) — event flow, state ownership, durability and lifecycle.
- [C06 architecture comparison](c06-monitoring-comparison.md) — three experimental implementations and the recommendation.
- [Core](../../src/companion/src/Core/README.md)
- [SavedVariables](../../src/companion/src/SavedVariables/README.md)
- [Import service](../../src/companion/src/ImportService/README.md)
- [History store](../../src/companion/src/HistoryStore/README.md)

For build and test commands, see [CONTRIBUTING](../../CONTRIBUTING.md).
