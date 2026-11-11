# Companion History Store

`HistoryStore` is the C03 authoritative local history store. It uses embedded DuckDB and the database-independent C01/C02 contracts in Core. The host supplies a database file path; a writer creates its parent directory and initializes the complete schema v2 directly. Existing files are first inspected read-only and accepted for writing only when they have the complete supported schema; schema creation and its version marker commit atomically only for a new or genuinely empty database. Foreign and unsupported files are rejected without modification. Old C03 development databases are unsupported; select a new database path and reimport SavedVariables. Dispose the store to drain reads and close its connections. Writes on one store instance are serialized, while reads own independent connections; callers should use a single writer per database because separate instances do not coordinate writes.

## Connections, consistency, and shutdown

The store keeps one dedicated writer connection alive for its entire lifetime.
`Write`, `WriteBatch`, and `WriteDimensions` share this connection under a
`System.Threading.Lock`; their reconciliation rules and transaction boundaries
are unchanged. Schema initialization/validation finishes before the constructor
returns. No migration or schema change is required for existing schema-v2 files.

`Read`, `ReadAll`, `ReadDimensions`, `ReadStatus`, and `SchemaVersion` each open
and dispose their own connection. No connection is exposed to callers or shared
between operations. Readers on a writable store use the same ordinary access
mode as the writer, not a separately opened physically read-only database.
Only the existing SELECT-based persistence APIs expose those reader connections.
There is no application-level reader/writer lock and no custom connection pool.

Every read operation uses an explicit DuckDB transaction. The first query fixes
its snapshot: craft headers, reagent/output rows, evidence, identities, dimension
contexts, and status aggregates remain consistent across subsequent statements,
even if an import commits between them. A read sees committed state at its
snapshot, never an uncommitted or partially materialized observation. A later
operation can see a newly committed batch; rollback, cancellation, conflicts,
and database errors do not publish partial batches. Separate public read calls
are separate snapshots, not a combined transaction.

A short lifecycle lock admits/counts reads, including connection opening.
Neither it nor the writer lock is held during reader SQL/materialization.
`Dispose` waits for the current writer using the writer lock, closes admission,
drains already-admitted reads without holding the lifecycle lock, then closes
the writer. Concurrent disposals serialize; subsequent operations throw
`ObjectDisposedException`. Reads can still enter while disposal is waiting for
an active writer. Shutdown does not cancel active work and can wait indefinitely
for it. Connection/command/materialization errors propagate; `using` and `finally`
roll back unfinished transactions, dispose connections, and release admission.
Read APIs remain synchronous and do not acquire new cancellation parameters;
`WriteBatch` retains its existing cooperative cancellation checks.

### Provider investigation (DuckDB.NET.Data.Full 1.5.6.1)

Confirmed against provider release commit
[`7ac3220`](https://github.com/Giorgi/DuckDB.NET/tree/7ac3220f8fe5eaba150ac8172c1f3bdbabf7a5c5):

- [`ConnectionManager`](https://github.com/Giorgi/DuckDB.NET/blob/7ac3220f8fe5eaba150ac8172c1f3bdbabf7a5c5/DuckDB.NET.Data/Connection/ConnectionManager.cs)
  automatically caches a reference-counted **database handle** per data-source
  string, but does **not** implement ADO.NET connection pooling. Every `Open`
  calls `duckdb_connect`; every close disconnects that native connection.
  The last close also disposes the database and removes its cache entry. There
  is no pooling switch to enable. Keeping the writer open avoids reopening the
  database/catalog for each reader; native connection setup still has a cost.
- Configuration, including `access_mode`, is applied only when that cached
  database is first opened. Tests with both opening orders confirm a subsequent
  `READ_ONLY` connection actually shares an existing writable database; conversely,
  an ordinary connection cannot write when the first opener was read-only.
  Do not treat different connection strings as independent access-mode enforcement.
  Use the same normalized full path and configuration for same-process reads.
- [`DuckDBConnection`](https://github.com/Giorgi/DuckDB.NET/blob/7ac3220f8fe5eaba150ac8172c1f3bdbabf7a5c5/DuckDB.NET.Data/DuckDBConnection.cs)
  owns mutable transaction state.
  [`DuckDBCommand`](https://github.com/Giorgi/DuckDB.NET/blob/7ac3220f8fe5eaba150ac8172c1f3bdbabf7a5c5/DuckDB.NET.Data/DuckDBCommand.cs)
  executes against that native connection and does not provide an independent
  transaction/session for concurrent commands. DuckDB's
  [C API documentation](https://duckdb.org/docs/1.5/clients/c/connect)
  says individual connections lock while querying and recommends one connection
  per thread for parallelism. Native thread safety is not a guarantee of
  independent simultaneous ADO.NET commands/transactions on one managed connection.
- [`DuckDBTransaction`](https://github.com/Giorgi/DuckDB.NET/blob/7ac3220f8fe5eaba150ac8172c1f3bdbabf7a5c5/DuckDB.NET.Data/DuckDBTransaction.cs)
  uses `BEGIN`/`COMMIT`/`ROLLBACK`, supports snapshot/unspecified isolation,
  and rolls back unfinished transactions on disposal.
  [DuckDB transactions](https://duckdb.org/docs/1.5/sql/statements/transactions)
  guarantee snapshot isolation/repeatable reads; the
  [concurrency documentation](https://duckdb.org/docs/1.5/connect/concurrency)
  supports concurrent connections in one read-write process using MVCC.
  Deterministic tests verify readers alongside a held writer transaction.
- Ordinary ADO.NET open/execute methods are synchronous here; the provider does
  not override them with asynchronous native execution. `Cancel` interrupts the
  connection, not an isolated operation sharing that connection. No cosmetic
  async APIs or new cancellation model are introduced.

`readOnly: true` remains suitable for offline status/inspection: if first to open
the file, it selects physical `READ_ONLY` mode without creating/migrating schema.
All three write APIs now explicitly reject that flag with
`InvalidOperationException`, even when the provider shares an already-writable
handle (previously rejection depended on the provider and normally surfaced a
`DbException`). This intentional exception-type change closes that access-mode
loophole. These connections are still subject to
DuckDB's process-level file locks; this design does not enable another writer
process or an external read-only process alongside the Companion writer.

### Concurrency tests and performance

The HistoryStore tests coordinate readers and imports with events, countdowns,
and barriers, not sleeps. Coverage includes simultaneous same/different-craft
reads; reads during a paused batch before commit, conflict rollback, cancellation,
and injected I/O/database failure; commits between the SQL statements of each
multi-statement read; bounded overlapping readers/writers; read failures;
disposal during reads/writes; failed connection opening and recovery; both
provider access-mode opening orders; and release of the final cached database
handle after shutdown. Internal read checkpoints expose no mutable connections.

Run the opt-in real-DuckDB workload from `src/companion`:

```sh
dotnet test tests/HistoryStore/Tests.HistoryStore.csproj -c Release \
  --filter FullyQualifiedName~HistoryStorePerformanceTests --logger 'console;verbosity=normal'
```

One before/after sample on Linux x64, .NET SDK 10.0.401, against baseline
`dba2961`, using the same benchmark source, native provider, temporary local file,
and 1,000 observations (two reagents, two outputs, provenance each):

| Workload | Shared connection baseline | Independent readers |
|---|---:|---:|
| Seed/import 1,000 crafts | 17,610 ms (56.8 crafts/s) | 18,942 ms (52.8 crafts/s) |
| 100 sequential single-craft reads | 440 ms (4.40 ms/read) | 558 ms (5.58 ms/read) |
| Four workers, 100 reads each, total wall time | 1,575 ms (254 reads/s) | 471 ms (849 reads/s) |
| ReadAll, 1,000 crafts | 3,915 ms | 4,060 ms |
| 500 open/count/dispose cycles, writer kept open | 241 ms | 246 ms |
| 500 counts on one reused connection | 216 ms | 236 ms |
| Additional batch of 100 crafts | 2,509 ms (39.9 crafts/s) | 2,791 ms (35.8 crafts/s) |
| Read during import, writer held up to 250 ms | 338 ms | 5.4 ms |

These are elapsed workload timings, not CPU profiles or statistical performance
guarantees. The held-import measurement includes scheduling and, on baseline,
writer-gate waiting plus remaining import work; synchronization waiting is not
separately instrumented. Concurrent throughput is measured from completed real
queries, not thread count. Per-operation connection/transaction overhead worsens
single-reader latency; unchanged ingestion also varied in this shared environment.
The small opening/reuse difference does not justify a bounded pool's shutdown,
contention, and exhaustion complexity. The intended gain is independent reads
and removal of writer-gate waiting, not universally faster SQL.
This synthetic history is not a production-scale database, does not model
large evidence payloads, and is not a Windows performance result. Long snapshots
can retain MVCC versions and consume memory; unrestricted caller concurrency
still consumes DuckDB/OS resources. No unmeasured resource-exhaustion or absolute
latency guarantee is claimed.

## Physical schema (version 2)

The initial schema persists every current `CraftDimensions` collection, canonical observations, and slot-level recipe requirements:

| Table | Owns |
|---|---|
| `GameContext` | Blizzard project ID and nullable progression track. |
| `Character` | Context-scoped stable character key and optional display name/class metadata. Observation-only writes create the known identity without inventing names. |
| `Recipe` | Context-scoped recipe ID and optional name, profession, expansion, and quality metadata. |
| `Profession` | Context-scoped skill-line ID, optional name, and optional parent skill line. |
| `Item` | Context-scoped item ID and optional name. |
| `Expansion` | Context-scoped expansion/skill-line key and optional name. |
| `RecipeReagent` | A recipe schematic slot identified by context, recipe, data-slot type, and data-slot index. Slot type, UI slot index, reagent type, requiredness, quantity, and candidate item IDs retain unknown values independently. Candidate IDs are stored as a deterministic JSON array. |
| `CraftIdentity` | Canonical `(IdentityOrigin, IdentityObservation)` identity and an internal immutable `CraftKey`. |
| `Craft` | Mutable craft attributes, context, character/recipe IDs, recorded timestamp, tri-state outcomes/completeness, and versioned provenance/evidence JSON. |
| `CraftReagent` | Craft × item allocations and returned quantities. Returned decimals are invariant text to preserve .NET decimal precision and scale. |
| `CraftOutput` | Craft × item × quality output facts, including nullable quality and quantity. |

`CraftIdentity` keeps C01/C02 identity separate from the database surrogate. `Craft` holds the mutable payload and references the immutable identity key; reagent and output rows have physical foreign keys to that key. This avoids DuckDB's limitation that a referenced parent row cannot be updated: the store can transactionally replace child facts and enrich `Craft` without changing the referenced identity. Insert and enrichment failures roll back the parent, dimensions, and all child facts. Tests verify FK rejection of orphan children and rollback after child insertion failures.

All dimension keys are scoped to `GameContext`. Dimension-to-context constraints are database-enforced. Craft-to-character/recipe, recipe-to-profession/expansion, profession-parent, and recipe-slot-to-recipe associations are ensured by the store transaction; candidate item IDs are checked by C01 and materialized as item dimensions, but remain in the slot's JSON array rather than separate FK rows. This avoids extra join tables and does not infer a recipe definition from observed `CraftReagent` rows.

`WriteDimensions` and `ReadDimensions` accept/return the canonical C01 sidecar independently of craft observations, so metadata can arrive before or after a craft. Writes use C02 reconciliation: unknown values do not erase known metadata, names enrich deterministically, identical re-imports are idempotent, and contradictory known recipe/profession/slot facts return a typed conflict without persisting any part of the conflicting write. Craft observations also create minimal context-scoped identity rows for their known character, recipe, profession, expansion, and observed item IDs; richer dimension writes later enrich them.

`WriteBatch` validates one complete `CraftHistory`, reconciles its dimensions and every craft, then commits the whole batch in one transaction. Validation failures and C02 conflicts return typed results without committing any writes; database failures and cancellation roll back through transaction disposal. Writes on one store instance remain serialized without blocking independent reads, and the store does not add import checkpoints or source records.

Successful batch results expose `Observations`, the per-observation
`CraftWriteResult` facts keyed by each returned observation's canonical identity.
Enriched results also expose `PreviousObservation`, allowing callers to compare
which evidence changed. Failed/rejected batches expose no committed observations.
These transient reporting facts do not add database records, reads, schema
changes, or new reconciliation/identity rules.

The internal `__HistoryStoreMigration` table records the initialized schema
version. No compatibility migrations are provided for old development databases.
Unsupported schemas are rejected, not deleted or overwritten. Provenance,
callback evidence, and configuration evidence retain their C01 typed payloads
and versioned JSON representation.

Schema v2 includes nullable `Craft.RecipeSchematicEvidenceJson` in its initial
table definition. All supplementary schematic variants are persisted,
reconciled idempotently, and survive reopening without changing canonical fact
equality. `RecipeReagent` remains available for explicitly supplied dimensions;
historical SavedVariables schematics are now craft evidence, not catalog rows.
Status supports only the current schema; no old-schema read fallback is provided.

## Operational status

`new HistoryStore(path, readOnly: true)` opens only an existing file, requesting
DuckDB's `READ_ONLY` access mode (subject to the first-opener behavior above).
It creates no parent directories or schema
objects and runs no migrations. `ReadStatus()` returns schema version, canonical
craft count, oldest/newest timestamps, and craft counts by project/progression
track through aggregate SQL, without loading observation payloads or counting
rollups. Timestamps are compared as instants, not lexicographically as stored
offset strings. Unsupported or unavailable history schemas fail explicitly.
This cross-context operational inventory does not replace context-scoped
analytics. Dispose readers as well as writers; process-level locks can prevent
opening a database owned by another writer.

## Recipe reagent evidence and limits

`RecipeReagentSlot` models schematic slots rather than fixed recipe-to-item links. Multiple slots may contain the same item, and one slot may contain multiple candidate alternatives. `RequiredQuantity`, `IsRequired`, slot type, reagent type, and UI index remain nullable when the source did not preserve them. Historical craft inputs are stored separately and are never promoted to recipe requirements.

Retail's pinned `CraftingReagentSlotSchematic` declaration (client build `12.1.5.70688`, source commit `d07eb00237d8891f153215db98a5df880a26cfe5`) includes `reagents`, `reagentType`, `variableQuantities`, `quantityRequired`, `dataSlotType`, `dataSlotIndex`, `slotIndex`, `required`, and `hiddenInCraftingForm`. `CraftingReagentType` distinguishes Basic, Modifying, Finishing, and Automatic slots; `TradeskillSlotDataType` distinguishes Reagent, ModifiedReagent, and Currency. The addon accesses `C_TradeSkillUI.GetRecipeSchematic` behind availability/readability checks in [Retail Adapter.lua](../../../addon/src/ArtisanLogbook_Core/Flavors/Retail/Adapter.lua).

The SavedVariables adapter retains schematic observations as source snapshots,
not as immutable `RecipeReagent` dimension rows:

- `fixedReagents` retain observed basic item and quantity metadata.
- Schema-3 `requirements` and independent result `reagentRequirements` preserve candidate item IDs, slot index, and required quantity for schematic observations. Those rows do not preserve data-slot type or UI slot index, so the canonical values remain unknown rather than being inferred.
- Optional/finishing/modifying slots, hidden-state, currency slots, and `variableQuantities` are not preserved as standalone recipe definitions by current SavedVariables. The adapter does not invent them. Nonempty variable-quantity schematics are marked unsupported by the addon capture path.

The API declaration describes available fields, not guaranteed runtime availability for every recipe. The addon guards schematic reads, and this repository has no live-client fixture establishing that every API slot is observable. Full recipe-catalog collection remains out of scope.

## Reconciliation and persistence tests

`Write` applies C01 validation and C02 craft reconciliation. Exact replay is idempotent, compatible unknown-to-known enrichment and independent evidence are stored atomically, and contradictory known facts return a typed conflict without replacing the stored observation.

`tests/HistoryStore/HistoryStoreIntegrationTests.cs` covers close/reopen reconstruction, dimensions written before and after crafts, all five C01 dimension kinds, slot alternatives/optional state/repeated item IDs, context isolation, metadata enrichment and conflicts, decimal precision, physical foreign keys, and transactional rollback. `tests/SavedVariables/SavedVariablesAdapterTests.cs` covers the recipe requirement fields the current addon actually persists.
