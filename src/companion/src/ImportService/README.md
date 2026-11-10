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

Historical request/result schematics are supplemental craft-attached evidence,
not immutable recipe catalog dimensions. Well-formed historical variants are
retained and C04 reports variation warnings. Malformed evidence and canonical
craft contradictions still reject atomically. Replays union schematic evidence
idempotently; evidence-only additions can enrich a craft without adding another
canonical observation.

The report includes the outcome, source craft-observation count, inserted/already-present/enriched/rejected craft counts, C03 dimension insert/enrichment counts, C04 diagnostics and coverage, C01 validation errors, C02 craft/dimension conflicts, file-input diagnostics, and persistence-failure diagnostics. Warnings do not change a successful outcome. `Coverage.AggregateOnlyCraftCount` and `CoverageWarnings` disclose craft history represented only by retained rollups; those totals are not imported as individual crafts. Dimension counts cover canonical dimensions returned by C04; they do not include minimal identities the store creates only to satisfy craft references.

`Observations` forwards C03's committed per-observation outcomes, including
previous and reconciled observations for enrichment. It is empty for rejected
or failed imports. C04 diagnostics preserve their structured scope and canonical
observation association when available; local IDs are not global identities.
C07 returns all current diagnostics on every import without filtering or
acknowledgment history. CLI/other hosts own visibility and grouping policy;
`CoverageWarnings` overlaps `SourceDiagnostics` and must not be counted as a
second set of occurrences.

## Atomicity and failure behavior

C03 `WriteBatch` validates the complete history and applies dimension reconciliation and all craft writes in one DuckDB transaction. Invalid input or any known-fact conflict rejects the entire import; no craft or dimension enrichment from that batch is committed. DuckDB failures return a failed result with persistence diagnostics, and cancellation propagates to the caller while the transaction is disposed and rolled back. Identical observations are idempotent; compatible unknown-to-known corrections and independent evidence use the existing C02 reconciliation rules.

The file API uses `SavedVariablesSnapshotReader`, shared with C06 inspection.
It checks length and modification time during each bounded read, then requires
two byte-identical reads separated by a 250 ms quiet interval. Equal timestamps
alone never establish stability. Only that captured content is imported;
`SourceFingerprint` reports SHA-256 of those exact bytes, including any BOM,
even if the path is replaced while ingestion executes. In-memory imports and
failed file reads have no fingerprint. Only a successful C07 outcome permits
advancing a successful monitoring checkpoint.

A stable read is not proof that WoW has finished saving. A changing file,
inaccessible/missing path, oversized file, or invalid UTF-8 is reported separately
from C04 parse diagnostics; malformed or unsupported SavedVariables are rejected
before the store is called. Snapshots remain capped at 64 MiB. The reader performs
one stability check, not an indefinite retry; C06 owns retry eligibility.
DuckDB writes are serialized by a `HistoryStore` instance; callers should use
one writer per database, as separate instances do not coordinate writes.

## Source limitations

C04 currently supports ledger schemas 1 through 5 and only its documented data-only Lua subset. Older SavedVariables may have pruned craft detail; aggregate-only coverage is reported, not reconstructed. Stable identities depend on the source lineage information available in each schema; old ledgers without durable lineage may not distinguish independently diverged clones. Recipe schematic fields remain unknown unless retained by the addon. Optional/finishing/modifying and currency slot definitions, variable quantities, a complete recipe catalog, and live-client capture guarantees remain outside this import.
