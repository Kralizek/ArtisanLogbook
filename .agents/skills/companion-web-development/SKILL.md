---
name: companion-web-development
description: Work on Artisan Logbook's Companion React frontend, browser APIs, Aspire development environment, local proxy security, or embedded production assets. Use when changing or validating the web stack and its development or distribution workflow.
---

# Companion web development

Follow [CONTRIBUTING](../../../CONTRIBUTING.md) for environments and validation.
Read the relevant references below, not every reference for every task.

## Boundaries

- Production is `Cli -> Runtime -> WebAssets`: one executable serves embedded
  HTML/JS/CSS, REST and canonical GraphQL. Aspire and Vite are development
  tools, not production services. Do not add a Node server or separate `wwwroot`.
- The web project owns React pages and generated clients; Runtime owns hosting,
  API security, resolvers and repositories; HistoryStore owns SQL. GraphQL
  reads history and does not control ingestion.
- Reuse React, Mantine, React Router, Apollo and openapi-fetch conventions and
  existing components. Avoid speculative frontend frameworks and remote assets.
- Contracts and operations are authored offline; generated GraphQL and REST
  clients are ignored outputs, never hand-edited or committed.
- Preserve opaque canonical IDs/cursors, unknown values and precision limits,
  cancellation, freshness and redacted error/retry behavior.
- Use isolated development data, the devcontainer dependency volume, and
  production asset mode for publication. Never build on host and container
  concurrently against one checkout.

## Load by task

- [Development environment](references/development-environment.md): Aspire
  installation, startup, rebuild/restart, HMR, contract regeneration and
  host/container switching.
- [Frontend contracts](references/frontend-contracts.md): clients, canonical
  browser identity, pagination, precision, freshness and error behavior.
- [Local security](references/local-security.md): loopback forwarding, dashboard
  certificates, proxy validation and the narrow navigation exception.
- [Production packaging](references/production-packaging.md): MSBuild restoration,
  embedding, asset modes and distribution validation.
- For deeper domain/SQL work use [companion-history](../companion-history/SKILL.md);
  for ingestion, monitoring or lifecycle use
  [companion-runtime](../companion-runtime/SKILL.md).

Select targeted frontend/backend checks from CONTRIBUTING. Use extended
regressions for build, orchestration or deployment changes; verify HMR or
real forwarding manually when affected. Do not report those as automated if
they were not exercised.
