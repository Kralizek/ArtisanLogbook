---
name: addon-companion-contracts
description: Change or validate the SavedVariables interoperability boundary between the WoW addon and Companion, including ledger schemas, migration, identity lineage, historical fixtures and data-only parsing or round trips.
---

# Addon–Companion contracts

Read the [addon ledger](../../../docs/addon/storage.md),
[SavedVariables adapter](../../../src/companion/src/SavedVariables/README.md)
and [ImportService](../../../src/companion/src/ImportService/README.md).
Follow [CONTRIBUTING](../../../CONTRIBUTING.md) for cross-component validation.

- SavedVariables is the interoperability boundary. Preserve supported ledger
  schemas 1–5, their migration/round-trip rules and explicit rejection of
  unsupported or malformed data. Parse data-only Lua; never execute input.
- Ledger-local craft/request/session IDs are source provenance, not global
  canonical identity. Preserve lineage and surface unresolved collisions.
  Keep GameContext and character identity grounded in source evidence.
- Preserve unknowns, incomplete coverage and source-only callback,
  configuration and schematic evidence separately from canonical facts.
  Historical aggregate-only coverage is reported, not manufactured into crafts.
- Reuse the writer's validation and preservation rules for unrelated globals,
  existing settings and supported historical content. Do not silently drop old
  facts or promote historical schematic evidence into immutable dimensions.
- Fixtures are sanitized or synthetic as documented. Follow
  [fixture provenance](references/fixtures-and-migration.md) before updating
  them; do not commit real user data.

Use [wow-addon-development](../wow-addon-development/SKILL.md) for capture and
ledger implementation and [companion-history](../companion-history/SKILL.md)
for canonical reconciliation. Run focused addon and adapter/import tests across
the boundary; use extended fixture validation when provenance/generation changes.
