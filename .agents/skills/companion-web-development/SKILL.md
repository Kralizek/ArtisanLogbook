---
name: companion-web-development
description: Work on Artisan Logbook's Companion web stack, including React/Mantine clients, offline GraphQL/OpenAPI contracts, canonical DuckDB history, Aspire/devcontainer startup and HMR, and embedded single-executable publication. Use when changing Companion frontend, API/history queries, development orchestration, or validating browser and production workflows.
---

# Companion Web Development

Use this skill for the Companion, not the WoW addon or the vendored WoW API
tooling. Follow [CONTRIBUTING](../../../CONTRIBUTING.md); load only the linked
references relevant to the change. Commands below assume `src/companion` as the
working directory unless stated otherwise. Recheck the current implementation
when changing a documented contract; do not turn development workarounds into
production architecture.

## Architecture And Ownership

- Production is `Cli -> Runtime -> WebAssets`: one self-contained executable
  serves embedded HTML/JS/CSS, operational REST at `/api/v1`, and canonical
  history at `/graphql`. Do not introduce a production Node/Vite process,
  Aspire deployment, database container, or separate `wwwroot` distribution.
- [web](../../../src/companion/web) owns React pages/components/styles and
  generated clients. [Runtime](../../../src/companion/src/Runtime) owns hosting,
  local API security, REST/OpenAPI, GraphQL resolvers and history repositories.
  [HistoryStore](../../../src/companion/src/HistoryStore) owns DuckDB persistence,
  connections, transactions and SQL; keep SQL out of resolvers and UI code.
- [WebAssets](../../../src/companion/src/WebAssets/WebAssets.csproj) owns frontend
  build/embed targets. [AppHost](../../../src/companion/tools/AppHost/AppHost.cs)
  orchestrates CLI plus Vite only for development and is outside the production
  reference graph. Existing CLI import/monitoring owns ingestion; GraphQL reads
  history, not ingestion or monitoring control.
- Read [web architecture](../../../docs/companion/web.md#production-architecture),
  [REST contracts](../../../docs/companion/api.md), or
  [GraphQL contracts](../../../docs/companion/graphql.md) before crossing these
  boundaries. Preserve the existing local security and cancellation behavior.

## Supported Environment And Startup

- Use the repository [VS Code devcontainer](../../../.devcontainer/devcontainer.json).
  It provisions .NET 10, Node 26.13.1/bundled npm 11 and Aspire; check the actual
  SDK requirement in [global.json](../../../src/companion/global.json).
  Rebuild the container after feature changes; opening a new terminal in an old
  container does not provision tools. Do not add global frontend tool installs.
- The container sets `CompanionWebDevelopment=true`: ordinary .NET builds skip
  production frontend resources. Outside it, use
  `CompanionWebDevelopment=true aspire run` in a POSIX shell or set
  `$env:CompanionWebDevelopment='true'` before `aspire run` in PowerShell.
- Start with `aspire run`; [aspire.config.json](../../../src/companion/aspire.config.json)
  selects AppHost. The explicit equivalent is
  `aspire run --apphost tools/AppHost/AppHost.csproj`. Ctrl+C stops resources and
  releases the development database.
- Leave `web` waiting: it depends on successful `web-installer` completion and
  Companion's `/api/v1/health`. Dashboard **Start** bypasses dependency waiting.
  A Running installer is not a ready frontend. If web was started prematurely,
  allow installation to finish before starting the failed web resource again.
- Inspect `aspire logs web-installer`, `aspire logs web`, and
  `aspire logs companion`. Look for successful install and
  `Finished waiting for resource 'web-installer'`, then the contract-generation
  output and Vite readiness. Codegen can take tens of seconds on mounted
  checkouts even after installation; unchanged starts now skip regeneration.
- Development uses incremental
  `npm install --no-save --include=dev --no-audit --no-fund`; production/CI use
  `npm ci`. `Development__InstallFrontend=false` is for already-restored
  dependencies, not a fix for missing executables.
- Check `command -v node npm npx aspire dotnet` in the container when executable
  discovery fails. npm scripts resolve local `node_modules/.bin` executables;
  `graphql-codegen` need not exist on the interactive shell's global PATH.
  Check installation and DCP's launched executable in logs before changing PATH.
  For interrupted installation, stop Aspire, run `npm ci --include=dev` from
  `web`, then restart. Do not install codegen globally.
- Rebuild the devcontainer to mount its checkout-specific `node_modules` volume.
  Windows host dependencies stay in the checkout; .NET outputs are partitioned
  by OS and asset mode. Stop Aspire before deploying from the same checkout,
  then restart it. Never run host/container builds concurrently: generated
  sources and `dist` remain shared. Restore .NET with the same asset mode used
  by any `--no-restore` build.

See [daily workflow and troubleshooting](../../../docs/companion/web.md#daily-development-vs-code-dev-containers)
for recovery and the supported separate-process alternative.

## Ports, Certificates And Proxy Security

- Both app endpoints are unproxied and loopback-only. AppHost passes the actual
  Companion endpoint into `--port`/`--require-port` and Vite's `COMPANION_URL`;
  a required busy backend port fails rather than silently falling back.
  Frontend code uses relative `/graphql` and `/api/v1`, never compiled-in ports.
- The container explicitly forwards dashboard HTTPS `18888`, web HTTP `5173`
  and API HTTP `48721` with matching required local ports. Outside this setup,
  Aspire allocates dynamic app ports; internal service/OTLP ports remain dynamic.
  Use the printed resource endpoint and VS Code Ports view's actual local
  forward, not guessed port numbers. `Development__CompanionPort` and
  `Development__WebPort` are optional overrides. Resolve host port conflicts;
  keep forwards private and on `localhost`/`127.0.0.1`.
- Container certificate initialization (`aspire certs trust --non-interactive`)
  does not trust the dashboard certificate in the host browser. Follow the
  [certificate guidance](../../../docs/companion/web.md#tooling-and-local-development)
  for host trust; do not disable verification. Opening the forwarded HTTP web
  endpoint avoids the dashboard-only certificate requirement.
- [dev-proxy.ts](../../../src/companion/web/dev-proxy.ts) validates loopback
  Host, exact Origin and Fetch Metadata before proxying, then rewrites only
  validated API Origins; `changeOrigin` supplies the upstream Host. Preserve
  client headers/bodies, disabled CORS and backend security. Do not strip
  untrusted Origins or permit wildcard binds/public forwarding domains.
- Dashboard-link navigation is deliberately narrow: user-initiated top-level
  GET navigation to `/`, `/history` or `/history/` can originate elsewhere.
  This is a document-only exception, not permission for cross-origin API,
  assets or background fetches. Host/Origin checks still apply; subsequent API
  requests must be same-origin. Differently numbered local forwards are valid
  when browser Host and Origin agree. Verify HMR's browser-endpoint WebSocket.

## Frontend Contracts And Edit Loops

- Reuse React 19, Mantine 9, React Router, existing components/styles, and the
  strict TypeScript configuration. Keep TypeScript 5.9.3 unless build-tool peer
  compatibility is deliberately revisited. Do not introduce a second UI system,
  generic state/cache framework, CDN or remote font dependency.
- [clients.ts](../../../src/companion/web/src/api/clients.ts) centralizes Apollo
  Client 4 and typed openapi-fetch: relative paths, POST GraphQL, omitted
  credentials and `X-Artisan-Logbook-Client: web`. Reuse it, propagate REST
  AbortSignals, and preserve redacted retry/error states instead of exposing
  raw exceptions. Apollo React hooks follow the existing `@apollo/client/react`
  imports. Use generated operation documents/types, not handwritten duplicates.
- Offline sources are committed
  [schema.graphql](../../../src/companion/src/Runtime/GraphQL/schema.graphql),
  [openapi.yaml](../../../src/companion/src/Runtime/Api/Contracts/openapi.yaml),
  and authored `web/src/graphql/*.graphql` operations. No live introspection or
  running server is needed. Generated GraphQL files under
  `web/src/graphql/generated/` and REST `web/src/api/generated.ts` are ignored;
  never hand-edit or commit them.
- At startup, `npm run dev` runs
  [scripts/codegen.mjs](../../../src/companion/web/scripts/codegen.mjs) before
  Vite. It fingerprints contracts, operations, config/package manifests and
  generated outputs; unchanged inputs/outputs reuse a node_modules stamp.
  Changed/deleted inputs or outputs trigger generation. Production `npm run
  build` still runs full codegen, typecheck and Vite bundling.
- After startup, operation edits do **not** regenerate automatically. From
  `web`, run `npm run codegen`, then `npm run typecheck`. For backend contract
  changes, update the committed SDL/OpenAPI, run corresponding backend contract
  tests, regenerate clients and rebuild Companion. There is no supported
  contract watcher; do not assume GraphQL Code Generator watch works on mounts.
- React/CSS edits refresh without restarting Companion. AppHost sets
  `NODE_ENV=development` for React Fast Refresh and `VITE_USE_POLLING=true`;
  [vite.config.ts](../../../src/companion/web/vite.config.ts) uses 300 ms polling
  for mounted filesystems. Check the browser WebSocket and resource environment
  when HMR fails before adding a custom watcher.
- C# edits require Companion dashboard **Rebuild** or
  `aspire resource companion rebuild`. **Restart** alone does not compile.
  AppHost edits require stopping and rerunning Aspire. Do not promise backend
  hot reload or introduce a parallel backend watch process.

## Canonical History And Query Constraints

- Read [GraphQL semantics](../../../docs/companion/graphql.md) before extending
  history queries. Craft identity is canonical origin plus observation;
  dimensions include GameContext and canonical keys. IDs/cursors are opaque
  strings, not DuckDB surrogates, numeric IDs, secrets or client-decodable keys.
  Keep Apollo's existing `__typename:id` identity rather than a parallel decoder.
- Connections are forward-only `nodes` plus `pageInfo`, not full Relay edges.
  Pages default to 20 and are bounded to 1-100. Pass IDs/cursors as variables;
  preserve timestamp precision and deterministic canonical tie-breaks. Cursors
  are not frozen snapshots across imports. Replace pages on Next, reset with
  Newest, and refresh the current page; do not add a generic pagination merger.
- Request-local DataLoaders batch dimension lookups (up to 500 keys) and
  character craft pages (up to 50 parents). HTTP request batching is disabled;
  other nested reverse collections still perform bounded per-parent queries.
  Reuse existing loaders/repository methods and test query counts rather than
  claiming all nested history is N+1-free.
- The server's Long/Decimal contract preserves more precision than standard
  JavaScript JSON numbers. Current generated scalars map both to `number`, not
  lossless arbitrary precision. Do not perform precision-sensitive calculations
  with them. The initial recent-crafts operation avoids those observations;
  REST craft counts use `Number.isSafeInteger` and warn otherwise. Unknown
  concentration/metadata is not zero; preserve explicit unknown fallbacks.
- Recent crafts uses `network-only` for visits/cursor changes and explicit
  Refresh, without a merge policy. This still writes Apollo's cache. Operational
  status refreshes 30 seconds after completed requests while visible and
  immediately on return to visibility; requests are serialized/cancellable.
  Host `Cache-Control: no-store` is not Apollo cache invalidation. Do not invent
  subscriptions or assume imports update an open page automatically.
- HistoryStore writes use its serialized shared writer connection and explicit
  transactions; imports atomically reconcile dimensions/crafts. Reads open an
  independent DuckDB connection/transaction per repository operation, not one
  GraphQL-wide snapshot. Keep multi-query craft materialization in that read
  snapshot and batch children rather than opening one connection per row.
- Follow existing Dapper parameterized `$Name`/`DynamicParameters` and collection
  bindings; pass transactions explicitly. Preserve streamed `buffered: false`
  reads and cancellation checks where used. Quantities use BIGINT; returned
  decimal quantity uses invariant-culture text and decimal parsing. Do not
  replace these with EF, a new connection pool or interpolated SQL. Consult
  [craft queries](../../../src/companion/src/HistoryStore/HistoryStore.CraftQuery.cs)
  and [Dapper tests](../../../src/companion/tests/HistoryStore/DapperCompatibilityTests.cs).

## Isolated Data And Publication

- Aspire uses `src/companion/.artifacts/development` for history/settings and
  checkpoints, process/dashboard logs, and `serve --monitoring false`; it does
  not configure a real game installation. `ARTISAN_LOGBOOK_DATA_DIRECTORY`
  overrides all CLI data, not only the database.
- Stop Aspire, then run `node tools/development.mjs import-fixture` to import the
  real committed `../addon/tests/fixtures/legacy/v1-outcome1.lua` through canonical
  ingestion. Repeated imports are idempotent, not repository seeding or database
  replacement. `node tools/development.mjs reset --confirm` removes only the
  isolated directory after a busy-database probe. Never point the development
  writer at production history; explicitly copy data when needed.
- MSBuild owns npm restore, offline generation, bundling and embedding. Its
  production restore stamp identifies the current platform, runtime, manifests
  and installed tree; development installation invalidates it before npm runs.
  Incremental targets track inputs, file lists and outputs, including deleted
  assets. Enumerate embedded resources after bundling and before manifest/target
  path calculation; preserve native-separator resource Link paths for Windows.
- Publication must rebuild production assets: use
  `-p:CompanionWebDevelopment=false`, never `dotnet publish --no-build` or
  development asset mode. Both shortcuts are rejected. The frontend streams
  from `ManifestEmbeddedFileProvider`, not extraction; DuckDB native extraction
  and writable external history/settings remain existing single-file behavior.
  Add SPA routes explicitly; unknown/API/missing-asset routes must not receive
  the document fallback.

## Validation By Changed Surface

- From `web`, use existing `npm run codegen`, `npm run typecheck`, `npm run lint`,
  `npm run format:check`, `npm run test` and `npm run build` as appropriate.
  Reuse Vitest/Testing Library tests; avoid a second test framework. Stop
  competing restores first; `npm ci` is the clean dependency restore.
- Backend/history changes use existing `tests/Cli/Tests.Cli.csproj` API/hosting
  tests and `tests/HistoryStore/Tests.HistoryStore.csproj` query, batching,
  concurrency, cancellation and Dapper tests. For production hosting validation,
  run `dotnet test ArtisanLogbook.Companion.slnx -c Release
  -p:CompanionWebDevelopment=false`; do not reuse development assets via
  `--no-build`. Contract tests compare the committed SDL/OpenAPI with the host.
- `npm run test:development` from `web` launches real Aspire with temporary
  history, imports a fixture and checks health, Vite, REST and GraphQL. It uses
  the normal development installer, not a stub. Run it for relevant tooling
  changes; manually verify React/CSS HMR when needed. It is not ordinary CI.
- After normal .NET restore, `node tools/smoke-incremental.mjs` checks production
  output recovery and unchanged-build skipping; run it for build-target changes,
  not every PR. For publication changes, follow
  the exact linux-x64/win-x64 publish commands in
  [executable-only validation](../../../docs/companion/web.md#publish-and-verify-one-executable)
  and run `node tools/smoke-publish.mjs .artifacts/publish/linux-x64/artisanlogbook
  ../addon/tests/fixtures/legacy/v1-outcome1.lua` (use the Windows executable path
  there on Windows). It copies only the executable to an empty directory,
  removes Node/npm/Aspire from the child PATH, imports a fixture and tests
  embedded assets and representative APIs. Linux CI additionally runs a minimal
  Chromium smoke; Windows CI tests the deployment script and alias without a
  browser. Browser validation needs `npx playwright install --with-deps
  --only-shell chromium`. A successful Vite build alone does not validate
  a single-executable distribution.
- Normal CI runs the full .NET suite on both OSes and frontend lint, formatting,
  unit tests and npm audit on Linux. Existing backend tests cover security and contracts;
  frontend component tests cover pagination, freshness, cancellation and errors.
  For Windows deployment failure changes, run
  `scripts/tests/Deploy-Companion.Tests.ps1` on Windows with no concurrent build:
  it temporarily modifies codegen and invalidates the npm restore.

## Skill Discovery

This is the sole canonical skill at `.agents/skills/companion-web-development/`;
its content uses only the [open Agent Skills specification](https://agentskills.io/specification).
Directory discovery is host-specific, not guaranteed by valid frontmatter.
[Codex](https://developers.openai.com/codex/skills/) supports `.agents/skills/`.
[VS Code](https://code.visualstudio.com/docs/copilot/customization/agent-skills)
documents `.agents/skills/` for Codex and Local sessions; verify the current
harness in a fresh session's skill list/menu rather than assuming every Copilot
experience shares discovery. [Claude Code](https://code.claude.com/docs/en/skills)
documents `.claude/skills/`, not native `.agents/skills/` discovery. If a host
does not discover this location, explicitly load this file; do not create
provider-specific copies, symlinks or duplicate skills to compensate.