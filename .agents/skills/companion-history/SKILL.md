---
name: companion-history
description: Work on Artisan Logbook's canonical craft history, reconciliation, dimensions, DuckDB persistence or analytical history queries. Use for domain semantics, data consistency, precision, batching and HistoryStore lifecycle.
---

# Companion history

Read [Core's canonical contract](../../../src/companion/src/Core/README.md) and
[HistoryStore](../../../src/companion/src/HistoryStore/README.md) before changing
model or persistence behavior. Follow [CONTRIBUTING](../../../CONTRIBUTING.md)
for practical tests.

- A craft is one completed attempt; reagents are craft × item, outputs craft ×
  item × quality. Unknown/null, absent, known incomplete, empty, zero and false
  are distinct. Never manufacture measurements or individual crafts from rollups.
- `CraftIdentity` is origin plus observation; addon local IDs, operation IDs,
  timestamps and computers are not globally unique. Preserve source lineage,
  provenance and explicit conflicts rather than guessing identity.
- GameContext is required and dimensions are context-qualified. Profession
  expansion is separate and optional; do not infer it from timestamp or name.
  Scope analytical aggregations to one selected context.
- Compatible unknown-to-known facts enrich idempotently; contradictory known
  facts reject the merge atomically. Callback, configuration and historical
  schematic evidence are attached source evidence, not canonical equality or
  immutable recipe dimensions.
- C03 serializes writes within its writer instance; use one writer per database.
  It owns transactions and independent read connections. Use parameterized
  DuckDB/Dapper SQL and typed mappings; preserve decimal and timestamp precision,
  cancellation and bounded disposal.
- Bound queries and pages, batch children in the existing snapshot, and retain
  unknowns when calculating statistics. Separate read operations are separate
  snapshots. Do not invent a pool, analytics framework or last-write-wins policy.

For detailed query, lifecycle and evidence pitfalls load
[persistence and queries](references/persistence-and-queries.md). For
SavedVariables schemas and round trips also use
[addon-companion-contracts](../addon-companion-contracts/SKILL.md); for host
ownership use [companion-runtime](../companion-runtime/SKILL.md).
Select domain/persistence tests for the changed behavior; extended validation is
appropriate when build or integration infrastructure is affected, not for every
small model change.
