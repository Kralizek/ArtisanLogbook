---
name: wow-addon-development
description: Develop Artisan Logbook's WoW addon capture, Core ledger, public Lua API, UI, Tracer, compatibility or release packaging. Use for repository-specific Retail and Forever addon work and live-client validation boundaries.
---

# Artisan Logbook addon development

This is repository-specific guidance, complementary to general WoW API
research. If another skill has the same name, read this file by path. Consult
the [addon index](../../../docs/addon/README.md) and
[CONTRIBUTING](../../../CONTRIBUTING.md) for documentation and commands.

- Core owns capture, storage and public read-only projections; UI consumes Core;
  Tracer independently records diagnostics. Maintain Lua 5.1 and existing
  namespaces, TOC load order, packaging and flavor conventions.
- Retail is the primary target. Forever has a narrow ordinary personal-craft
  boundary. Its UI has documented initial live acceptance, not full visual or
  compatibility certification. Never extrapolate Retail behavior or claim broad
  client support from a shared API name.
- Inspect the vendored [WoW API reference submodule](../../../tools/wow-api/),
  its source-pinned declaration catalogs, and the selected client/version,
  TOCs and compatibility code. Initialize the submodule if needed. Separate
  declarations, runtime availability and observed behavior.
- Requests, cast events, result callbacks and completed observations are not
  interchangeable. Admit only supported, evidenced operations and quarantine
  ambiguous correlation or duplicates rather than guessing. Preserve unknown
  and incomplete measurements, provenance and prior ledger history.
- Forever's observed `operationID = 0` is retained; matched cast tokens support
  correlation, and `UPDATE_TRADESKILL_CAST_STOPPED(false)` alone is not
  cancellation. Do not generalize observed ordering to unverified deliveries.
- Reuse existing in-game UI and diagnostic patterns. Automated Lua fixtures and
  packaging checks do not prove live Blizzard behavior or visual acceptance.

Load [capture and compatibility](references/capture-and-compatibility.md) for
event changes; [UI, diagnostics and packaging](references/ui-and-packaging.md)
for those areas. For SavedVariables interoperability use
[addon-companion-contracts](../addon-companion-contracts/SKILL.md). Choose
focused automated checks, extended checks when warranted, and report real WoW
acceptance separately.
