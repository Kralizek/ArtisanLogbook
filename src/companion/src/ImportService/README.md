# Companion Import Service

`ArtisanLogbook.Companion.ImportService` is the C07 orchestration boundary for SavedVariables-to-history imports. It depends only on Core, SavedVariables (C04), and HistoryStore (C03); it does not depend on a host, CLI, HTTP service, UI, or file watcher.

## Public API

Create a `CompanionImportService` with an open `HistoryStore` and call either API:

```csharp
using ArtisanLogbook.ImportService;

CompanionImportService importer = new(historyStore);
CompanionImportResult result = await importer.ImportSavedVariablesAsync(
    savedVariablesText, "manual-snapshot.lua", cancellationToken);

CompanionImportResult fileResult = await importer.ImportSavedVariablesFileAsync(
    savedVariablesPath, cancellationToken);
```

Both entry points parse once with `SavedVariablesReader`, use C01 validation and C02 reconciliation through C03, and persist the canonical craft observations and explicit dimensions. They never promote rollups to crafts or infer recipe requirements from consumed reagents. The caller owns and disposes the `HistoryStore`.

The report includes the outcome, source craft-observation count, inserted/already-present/enriched/rejected craft counts, C03 dimension insert/enrichment counts, C04 diagnostics and coverage, C01 validation errors, C02 craft/dimension conflicts, file-input diagnostics, and persistence-failure diagnostics. Warnings do not change a successful outcome. `Coverage.AggregateOnlyCraftCount` and `CoverageWarnings` disclose craft history represented only by retained rollups; those totals are not imported as individual crafts. Dimension counts cover canonical dimensions returned by C04; they do not include minimal identities the store creates only to satisfy craft references.

## Atomicity and failure behavior

C03 `WriteBatch` validates the complete history and applies dimension reconciliation and all craft writes in one DuckDB transaction. Invalid input or any known-fact conflict rejects the entire import; no craft or dimension enrichment from that batch is committed. DuckDB failures return a failed result with persistence diagnostics, and cancellation propagates to the caller while the transaction is disposed and rolled back. Identical observations are idempotent; compatible unknown-to-known corrections and independent evidence use the existing C02 reconciliation rules.

The file API reads an explicit path into an in-memory byte snapshot, checks file length and modification time for changes during the read, and imports only that snapshot. It does not interpret a successful read as proof that WoW has finished writing. A changing file, inaccessible/missing path, oversized file, or invalid UTF-8 is reported separately from C04 parse diagnostics; malformed or unsupported SavedVariables are rejected before the store is called. The file API caps snapshots at 64 MiB and does not retry or wait for file stability. DuckDB writes are serialized by a `HistoryStore` instance; callers should use one writer per database, as separate instances do not coordinate writes.

## Source limitations

C04 currently supports ledger schemas 1 through 5 and only its documented data-only Lua subset. Older SavedVariables may have pruned craft detail; aggregate-only coverage is reported, not reconstructed. Stable identities depend on the source lineage information available in each schema; old ledgers without durable lineage may not distinguish independently diverged clones. Recipe schematic fields remain unknown unless retained by the addon. Optional/finishing/modifying and currency slot definitions, variable quantities, a complete recipe catalog, and live-client capture guarantees remain outside this import.
