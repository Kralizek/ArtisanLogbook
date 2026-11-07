# Companion History Store

`HistoryStore` is the C03 authoritative local history store. It uses embedded DuckDB and the database-independent C01/C02 contracts in Core. The host supplies a database file path; a writer creates its parent directory and initializes schema v2 (migrating v1 in place). Dispose the store to close its connection. Calls on one store instance are serialized; callers should use a single writer per database because separate instances do not coordinate writes.

## Physical schema (version 1)

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

`WriteBatch` validates one complete `CraftHistory`, reconciles its dimensions and every craft, then commits the whole batch in one transaction. Validation failures and C02 conflicts return typed results without committing any writes; database failures and cancellation roll back through transaction disposal. Calls on one store instance remain serialized, and the store does not add import checkpoints or source records.

The internal `__HistoryStoreMigration` table tracks schema versions separately. Schema v1 is corrected before initial merge; no migration is supplied for the unshipped PR schema. Provenance, callback evidence, and configuration evidence retain their C01 typed payloads and versioned JSON representation.

Schema v2 adds nullable `Craft.RecipeSchematicEvidenceJson` in one additive
migration. Existing v1 crafts/dimensions remain intact; their missing schematic
sidecar remains unknown. All supplementary schematic variants are persisted,
reconciled idempotently, and survive reopening without changing canonical fact
equality. `RecipeReagent` remains available for explicitly supplied dimensions;
historical SavedVariables schematics are now craft evidence, not catalog rows.
Status can read both v1 and v2 without migration.

## Operational status

`new HistoryStore(path, readOnly: true)` opens only an existing file using
DuckDB's `READ_ONLY` access mode. It creates no parent directories or schema
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
