# Agent guidance

Artisan Logbook is a World of Warcraft crafting-history addon and a separate
local Companion application. Start with [CONTRIBUTING](CONTRIBUTING.md) and
the [documentation index](docs/README.md).

## Route the work

Load the relevant skill and only the references needed for the task:

| Work | Skill |
| --- | --- |
| Companion frontend, API clients, Aspire, embedded assets | [companion-web-development](.agents/skills/companion-web-development/SKILL.md) |
| Canonical history, reconciliation, DuckDB queries | [companion-history](.agents/skills/companion-history/SKILL.md) |
| CLI, monitoring, ingestion and host lifecycle | [companion-runtime](.agents/skills/companion-runtime/SKILL.md) |
| Repository addon capture, UI, diagnostics, packaging | [wow-addon-development](.agents/skills/wow-addon-development/SKILL.md) |
| SavedVariables interoperability and historical schemas | [addon-companion-contracts](.agents/skills/addon-companion-contracts/SKILL.md) |

Use multiple skills when work crosses boundaries. If your harness does not
discover `.agents/skills/`, read the linked `SKILL.md` files explicitly. The
repository addon skill is project-specific even if a general WoW skill has the
same name; read it by path when discovery is ambiguous.

## Repository-wide constraints

- Preserve architectural boundaries and established contracts; prefer existing
  components and abstractions. Avoid speculative frameworks and completionism.
  Preserve the [frozen Companion component catalog](docs/companion/components.md).
- Preserve unknown and incomplete observations, provenance and canonical
  identity; maintain recorded-history and supported-client compatibility.
- Use the supported devcontainer and isolated development data. Never modify
  real user SavedVariables, history or settings during testing.
- Do not run host and devcontainer builds concurrently against one checkout.
- Test application behavior, not third-party framework internals. Avoid
  duplicated validation; choose normal, extended or manual checks in proportion
  to the changed surface, following [CONTRIBUTING](CONTRIBUTING.md).
- Report what actually ran and any limitations. Do not merge pull requests
  unless explicitly requested.
