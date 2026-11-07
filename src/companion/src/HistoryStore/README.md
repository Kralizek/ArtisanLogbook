# Companion History Store

`HistoryStore` is the C03 authoritative local history store. It uses embedded DuckDB and depends on the database-independent C01/C02 contracts in Core. There is no implicit default database location: the host configures storage by passing a database file path to `HistoryStore` (also exposed as `DatabasePath`). The project creates its parent directory and initializes or migrates that file when opened; dispose the store to close its connection. Calls on one store instance are serialized. Tests use a unique temporary `.duckdb` file, dispose the store, and reopen it before asserting reconstructed observations.

## Physical schema (version 1)

The seven history tables are:

| Table | Owns |
|---|---|
| `GameContext` | Blizzard project ID and nullable progression track; the internal key preserves both parts of the C01 identity. |
| `Character` | Context-scoped stable character key and optional display name/class metadata. Rows created from a `CraftObservation` contain only the known key. |
| `Recipe` | Context-scoped recipe ID and optional catalog metadata. Observation-only writes create the smallest ID row with catalog metadata left null. |
| `RecipeReagent` | Optional recipe requirement rows. This table is intentionally empty for observation-only writes. |
| `Craft` | Canonical craft identity, context/character/recipe references, craft attributes, recorded timestamp, tri-state outcomes/completeness, and versioned provenance/evidence JSON. |
| `CraftReagent` | Craft × item allocations and returned quantities. Returned decimals are stored as invariant text to preserve the full .NET `decimal` range and scale. |
| `CraftOutput` | Craft × item × quality output facts, including nullable quality and quantity. An internal quality key distinguishes unknown quality from known nonnegative quality values. |

Craft identity is the primary key `(IdentityOrigin, IdentityObservation)`, matching C01/C02 rather than addon-local numeric IDs. Dimension keys are context-scoped. The child fact tables are committed with their parent craft in one transaction. DuckDB does not permit updates to a parent row while another table has a foreign key to it, so child-to-craft references are validated and maintained by the store transaction rather than physical foreign-key constraints; context, character, and recipe relationships are database-constrained. Explicit `ReagentsObserved` and `OutputsObserved` flags distinguish unknown (`null`) collections from observed-empty collections; nullable scalar columns retain unknown separately from zero and false.

`__HistoryStoreMigration` is a small internal schema-version ledger, separate from the seven history tables. Migrations run transactionally and are applied in ascending version order. Per-craft provenance, output callback evidence, and configuration evidence are versioned JSON on `Craft`; callback order and optional fields are retained by the C01 record types.

## Contract gaps kept explicit

C01 currently has no canonical recipe-reagent requirement type. Consequently `RecipeReagent` is present in the physical schema but no required quantities are inferred from observed craft inputs and no rows are fabricated. The observation API also does not accept a sidecar `CraftDimensions` catalog; recipe names, profession/expansion catalog metadata, and other dimensions remain null/unpopulated until a canonical store contract exposes them. The craft's own known recipe, profession, and profession-expansion attributes are persisted directly.

`Write` first applies C01 validation. A repeated identity is reconciled with `HistoryReconciler`: compatible unknown-to-known enrichment and independent evidence are stored atomically, exact replay is idempotent, and contradictory known facts return a typed conflict without replacing the stored observation.

## Persistence test

`tests/HistoryStore/HistoryStoreIntegrationTests.cs` writes representative observations, disposes the first store, opens the same file again, and checks canonical values, provenance, both evidence collections, null/empty distinctions, false/zero values, multiple contexts, callback evidence, and high-precision decimal returns. Separate tests exercise replay, enrichment, and rejected conflicts.
