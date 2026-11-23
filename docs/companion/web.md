# Companion browser application

The Companion's client-side React application explores recorded crafting history
within one active game context per browser tab. Overview, Logbook, Recipes and
Reagents provide the everyday journal; recipe and item investigations reveal
statistics, materials, contributing crafts and guided setup comparisons. Search starts a new
investigation across the active context; the library holds pins, visibility
preferences and saved investigation definitions. Companion management is
global and independent of the analytical context, under Settings.

Analytics are calculated against canonical history in the backend. The browser
does not download the full craft history to rank or compare populations. Unknown
and incomplete measurements remain distinct from observed zero, and Forever's
fixed schematic inputs are not presented as measured consumption.

## Daily development: VS Code Dev Containers

The repository devcontainer is the primary supported development environment.
Open the checkout with **Dev Containers: Reopen in Container**. After changing
`.devcontainer/devcontainer.json`, stop Aspire and use **Dev Containers: Rebuild
Container**; opening another terminal in an old container does not install tools.

From `src/companion`:

```sh
node tools/development.mjs import-fixture # optional; stop Aspire before importing
aspire run
```

No separate backend/Vite commands, PATH edits, frontend build or environment
variables are needed. The container defaults `CompanionWebDevelopment=true`:
ordinary .NET builds intentionally skip the production frontend. Aspire restores
npm dependencies, checks generated contracts and starts Vite after backend HTTP health
succeeds. Development startup regenerates contracts only when their inputs or
generated files change; unchanged starts reuse them. The first generation can
take tens of seconds on mounted checkouts after `web-installer` completes.
Development uses incremental `npm install --no-save --include=dev`:
unchanged starts reuse `node_modules`, without rewriting the lockfile.
The devcontainer mounts a checkout-specific Docker volume at `web/node_modules`;
the `vscode` user owns it, it survives container rebuilds, and the host's
`node_modules` remains separate. Rebuild the container once to apply this mount.
Dependency changes are installed on the next Aspire start.

For Windows host deployment from this same checkout, stop Aspire, then run
`.\scripts\Deploy-Companion.ps1` in Windows PowerShell at the repository root.
Install the .NET 10 SDK and Node.js 26.13.1 (or a later 26.x release) with npm
11 on Windows; container tooling is not available to the host. The script
publishes production assets to a staging directory before replacing an existing
installation. Return to the container and run `aspire run` again. Do not run
host and container builds simultaneously: generated frontend files and `dist`
remain shared. No separate checkout or manual dependency repair is needed for
sequential switching.
Leave `web` waiting for `web-installer`; do not force Start during installation.
Aspire's dashboard **Start** command overrides dependency waiting. A Running
`web-installer` is still installing packages, not ready for Vite. Wait for its
successful completion and the web log's `Finished waiting for resource
'web-installer'` message; the contract check and Vite then run automatically.
If web was started
prematurely and failed, let the installer finish before starting web again.
The development-only web resource explicitly sets `NODE_ENV=development`;
otherwise a production-mode AppHost makes Vite disable React Fast Refresh.

Open the dashboard URL printed by Aspire, then the `web` endpoint. VS Code's
**Ports** view also exposes the explicitly forwarded, fixed container endpoints:

| Resource | Container and host URL |
| --- | --- |
| Aspire dashboard | `https://localhost:18888` (use the printed login link/token) |
| Web application | `http://localhost:5173` |
| Companion API | `http://localhost:48722` |

The development API uses 48722 so the host's production Companion can use
its default port, 48721. After rebuilding the container, stop any old 48721
forward in the VS Code Ports view. Development uses its own isolated history;
do not point both Companion instances at the same database.

Keep forwards private and browser URLs on `localhost` or `127.0.0.1`. The dashboard uses HTTPS;
Vite and Companion use HTTP. Container certificate trust does **not** trust the
certificate on the host: follow [.NET's certificate guidance](https://aka.ms/dev-certs-trust)
for the host browser before opening the HTTPS dashboard. Do not disable browser
certificate validation. Opening the forwarded HTTP web endpoint directly avoids
this dashboard-only certificate requirement.

| Edit | Development loop |
| --- | --- |
| React / CSS | Save; Vite Fast Refresh / CSS HMR updates the browser without restarting Companion. Aspire enables 300 ms polling for mounted filesystems. |
| Authored `.graphql` operation | Save, then run `npm run codegen` from `web`. Vite reloads the generated document; types and browser queries stay synchronized. |
| Backend SDL / OpenAPI | Update the committed `src/Runtime/GraphQL/schema.graphql` / `src/Runtime/Api/Contracts/openapi.yaml` with the backend change, run contract tests, then `npm run codegen` and `npm run typecheck` from `web`. Rebuild the backend too. |
| C# | Save, then use Companion's **Rebuild** dashboard command, or `aspire resource companion rebuild` in another terminal. **Restart** alone does not compile source. |
| AppHost / orchestration | Stop with Ctrl+C, then `aspire run` again. |

Contract generation is deliberately explicit after startup, not a background
watcher. Editing an operation alone does not regenerate imported documents.
One `npm run codegen` regenerates both offline contracts reliably on mounts that
do not deliver native change events. GraphQL Code Generator's optional watch
mode requires an additional native watcher; it is not part of this workflow.
There is no custom backend watcher or promise of C# hot reload.

Ctrl+C stops Aspire and its resources and releases the development database.
Re-run `aspire run` to retain history. Stop Aspire before offline imports or
`node tools/development.mjs reset --confirm`; reset deletes only isolated
development data. See [isolated fixtures](#isolated-history-and-fixtures) and
[production publishing](#publish-and-verify-one-executable).

## Production architecture

```text
AppHost (development only) -> Companion CLI + Vite
Cli -> Runtime -> WebAssets (embedded HTML, JS, CSS)
Browser -> /api/v1 (operations) and /graphql (canonical history)
```

Source lives in `src/companion/web`: `src/app`, `src/api`, `src/graphql`,
`src/components`, `src/pages` and `src/styles`. `tools/AppHost` is separate from
the production reference graph. There is no ServiceDefaults project, database
container, production Node process or Aspire deployment.

The WebAssets MSBuild targets run **npm ci -> offline codegen -> strict
TypeScript check -> Vite build**. The lockfile is committed; generated TypeScript
and Vite `dist` are ignored and regenerated during the build. An npm restore
stamp records a successful MSBuild-owned `npm ci`, the manifests, installed
lockfile, platform, architecture, Node and npm versions. MSBuild also checks
the dependency tree, required executables and Rolldown's native binding.
An incompatible or incomplete tree is restored again. Aspire's development
installer invalidates the production stamp *before* starting npm, and ordinary
npm lifecycle hooks invalidate it too; an incremental development install is not
a production `npm ci`. Consequently the first production build after development
in the same dependency tree restores once. Unchanged production builds reuse
the successful restore.
The frontend target uses source and
contract timestamps plus a file-list stamp (so source deletions are detected).
A successful build also records the generated output paths as MSBuild outputs;
deleting a JS/CSS asset with `dist/index.html` retained triggers regeneration.
An unchanged build skips restore and bundling.
After the usual .NET restore, run `node tools/smoke-incremental.mjs` from
`src/companion` when changing the build targets to verify restoration, JS/CSS
recovery and unchanged-build skipping. It is not part of ordinary CI.

Resource inclusion happens in a target **before the embedded-provider manifest
input calculation and AssignTargetPaths**, after Vite has finished. The glob is
not evaluated before a clean checkout's first build. The package generates the
embedded manifest, and Runtime serves streams through
`ManifestEmbeddedFileProvider` and ASP.NET Core static-file middleware. Assets
are not extracted and the entire bundle is not loaded into memory.
Resource Link metadata uses native path separators so the manifest's `wwwroot`
directory is generated correctly on both Windows and Linux.

The authored OpenAPI YAML is also embedded in Runtime and streamed at its
existing `/openapi/v1.yaml` route with the existing `text/yaml` type.
MinimalOpenAPI 1.1.0's schema publisher reads a sidecar from AppContext.BaseDirectory;
the executable-only smoke exposed a 500 when that file was absent. Only document
publication is adapted; generated endpoints, DTOs and the OpenAPI contract are
unchanged. No extraction/extra distributed file is needed.

Normal builds and publishes include production assets. For Vite-only development,
set the MSBuild property/environment variable `CompanionWebDevelopment=true`.
That builds a deliberately empty development provider and skips npm/bundling.
**Publishing with that property is rejected**. `dotnet publish --no-build` is
also rejected, even with the property unset, because it could reuse a development
assembly or stale frontend resources. Publish normally to validate/rebuild/include
the production provider. The .NET `bin` and `obj` paths are partitioned by
Windows versus Unix and by development versus production asset mode, including
NuGet project assets. Restore with the same `CompanionWebDevelopment` value as
the subsequent `--no-restore` build. Do not run separate MSBuild/npm builds
concurrently against the same checkout; generated sources and `dist` are shared.
Parallel project builds in one solution graph share WebAssets normally.

The existing `dotnet pack --no-build` tool-package workflow remains supported
after a normal production build. The pinned .NET SDK also routes tool packing
through publish targets; the publish guard distinguishes that SDK packing mode
from an executable publish rather than breaking the existing package pipeline.

Only GET/HEAD requests for the defined browser routes fall back to the document:
`/`, `/history`, `/companion`, `/saved/:id`, and valid context-qualified
activity, library, recipe, item and craft routes. The API, GraphQL, OpenAPI,
unknown routes and missing assets do not fall back. Add known routes explicitly
when adding browser pages. HTML and hashed assets currently
retain the host's `Cache-Control: no-store`; we deliberately do not weaken API
caching/security or add a caching subsystem. Content types and `nosniff` come
from the existing host/static-file infrastructure.

All production dependencies are bundled locally. Mantine uses system fonts.
There are no CDNs, remote fonts, icons, analytics, cookies or authentication
services. A stricter CSP is deferred: Mantine's runtime style properties require
a considered policy, not a blanket CSP that breaks components.

## C12 context-qualified browser routing

Analytical destinations begin with the backend-provided stable route alias
(for example `/retail/activity` or `/forever/recipes/<opaque-id>`). Resolve the
explicit route through shared context metadata at `GET /api/v1/games/{context}`,
and use the returned canonical string ID for analytical scope and cache
identity. The only current friendly aliases are the base Retail and Forever
contexts; other contexts use their canonical ID as the alias (for example
`/18-Hardcore/activity`). Do not construct canonical IDs, decode opaque
GraphQL entity IDs, or derive aliases in frontend code.

An explicit route identity takes precedence over the browser-local remembered
startup context; the latter is only a default when a destination contains no
context. Each tab owns its own context and URL-based investigation state, with
no server-side active context. Companion management is global; the library is
scoped to the current context. Saved definitions and their validation are
described in [saved investigations](saved-investigations.md).

The Vite development proxy and embedded host use narrow browser-route
allowlists. Neither makes `/api`, `/graphql`, `/openapi`, missing assets or
arbitrary unknown paths fall back to HTML. Browser routes do not relax API
forwarding, Host/Origin checks or CORS. See the
[C12 requirements](https://github.com/Kralizek/ArtisanLogbook/issues/81).

## Tooling and local development

The declarative features provision .NET **10.0**, Node **26.13.1** with bundled
npm **11** (no npm override), stable Aspire CLI, OS Python, PowerShell, GitHub CLI,
Lua 5.1, LuaRocks, Ubuntu `lua-check`, PyYAML and jq. `postCreateCommand` only
initializes volume ownership and certificate trust, installs frontend development
dependencies, and provisions Playwright's Chromium headless shell and Linux
dependencies. No manual global npm/LuaRocks installation is required. The .NET
SDK must satisfy `global.json` (**10.0.401**, allowing patch
roll-forward within that feature band).

AppHost SDK and hosting integrations are pinned to **13.6.5**. The official
Aspire feature **3.1.0** supports `installCli` and `useDailyBuilds`, but **no CLI
version option**. Its stable installer currently supplies compatible 13.6.5;
the feature lock pins feature code, not that external download. Check
`aspire --version` after rebuilding when updating tools. Do not add an unsupported
`version` property or a second installer to `postCreateCommand`. No Docker or
external database is required to run this AppHost.

Outside the container, provision the same prerequisites and use
`CompanionWebDevelopment=true aspire run` (PowerShell:
`$env:CompanionWebDevelopment='true'; aspire run`). The explicit
`--apphost tools/AppHost/AppHost.csproj` option is optional; the committed
`aspire.config.json` already selects it.

The CLI prints the dashboard URL and access token. Open the `web` resource's
HTTP endpoint from that dashboard. Aspire allocates **unproxied** endpoints for
both processes, so no Aspire HTTP proxy changes browser Host/Origin semantics.
The Companion receives its allocated port through existing `--port` plus
`--require-port` (fail on a conflict, never silently use an undiscovered port).
It remains bound to 127.0.0.1. Vite uses its integration's existing endpoint
and PORT/port argument; no second endpoint is added. The committed
`aspire.config.json` selects `tools/AppHost/AppHost.csproj`; the explicit
`aspire run --apphost tools/AppHost/AppHost.csproj` form works too. `WaitFor` uses the actual
`/api/v1/health` HTTP health check before starting Vite. Vite supplies HMR.
Aspire enables Vite's supported 300 ms polling watcher for this small source tree,
so hot updates also work in devcontainers and mounted/network workspaces where
native file events can be absent. Direct Vite users can set `VITE_USE_POLLING=true`
in those environments.

`COMPANION_URL` is supplied to Vite from the Companion endpoint. Frontend code
always uses `/graphql` and `/api/v1`; the hostname/port are not compiled into JS.
Vite binds to 127.0.0.1, validates incoming loopback Host, exact Origin and
Sec-Fetch-Site before proxying, then rewrites **only validated** API Origins to
the upstream Companion origin. `changeOrigin` sets the upstream Host. Client
headers and bodies remain intact. Untrusted origins are rejected, not stripped.
CORS is disabled; backend security is never disabled.
User-initiated top-level GET navigation to a supported browser route may
come from a dashboard on another origin. This exception serves only the SPA
document, not API calls, assets or background fetches; Host and Origin checks
still apply. Subsequent API requests must originate from the web application's
own origin.

The devcontainer pins and explicitly forwards the three browser-facing ports
above, so dashboard links remain stable across restarts. VS Code requires the
matching local port rather than silently forwarding to another number; resolve
host port conflicts when prompted. Internal Aspire service/OTLP ports remain
dynamic. Outside the devcontainer the browser-facing ports remain dynamic too.
No public tunnels, wildcard binds or permissive origins are necessary.
Different local forwarded ports are allowed as long as browser Host and Origin
agree. Vite's WebSocket uses the browser endpoint for HMR.

### Troubleshooting

- **Missing node/npm:** rebuild the container, then restart Aspire. Check
  `command -v node npm npx aspire dotnet` from a new terminal. Node's feature
  supplies `/usr/local/share/nvm/current/bin` in the container PATH; Aspire's
  feature supplies `/usr/local/bin/aspire`. They do not rely on interactive nvm
  shell initialization. `aspire logs web-installer` and `aspire logs web` show
  the executable DCP actually launches.
- **Missing graphql-codegen:** wait for `web-installer` to exit successfully.
  If the web log shows `Executing command 'start'` without first showing
  `Finished waiting for resource 'web-installer'`, Start bypassed the install
  dependency. Do not stop the whole AppHost while npm is still installing; allow
  the installer to finish, then start the failed web resource again.
  If installation was interrupted, stop and restart Aspire; its installer runs
  again. Do not install codegen globally. For detailed diagnostics, run
  `npm run install:development` and `npm run dev` from `src/companion/web`.
  On Windows, check `Get-Command dotnet,node,npm.cmd`, then from
  `src/companion/web` run `npm ci --include=dev` and `npm run build` to see the
  full codegen/Vite error. Fix the reported problem before retrying deployment;
  failed publication does not replace the existing installation. Avoid
  concurrent host/container builds.
- **Certificate errors:** `aspire certs trust --non-interactive` and
  `dotnet dev-certs https --check --trust` check container initialization.
  `SSL_CERT_DIR` includes the user's dev-cert trust directory. Host browser
  trust is separate; an HTTPS port forward alone does not establish it.
- **Unreachable browser / HMR:** check the Ports view's actual forwarded address
  and scheme, and use a private loopback HTTP address for Vite. Verify the HMR
  WebSocket in browser developer tools. A public forwarding domain is
  intentionally rejected. Do not disable Host/Origin checks, CORS or the client
  header. A busy required Companion port fails explicitly instead of falling back.

The direct AppHost alternative after installing/initializing the Aspire CLI
bundle is:

```sh
dotnet run --project tools/AppHost/AppHost.csproj -p:CompanionWebDevelopment=true
```

For separate backend/frontend development:

```sh
ARTISAN_LOGBOOK_DATA_DIRECTORY="$(pwd)/.artifacts/development" \
dotnet run --project src/Cli/Cli.csproj -p:CompanionWebDevelopment=true -- \
  serve --monitoring false --port 48722 --require-port
# In another terminal, from src/companion/web:
COMPANION_URL=http://127.0.0.1:48722 npm run dev
```

Outside the devcontainer Aspire normally uses random available ports. Optional `Development__CompanionPort`,
`Development__WebPort` and `Development__DataDirectory` settings are available
for reproducible smoke tests or explicit developer overrides.
`Development__InstallFrontend=false` skips Aspire's npm installer when dependencies
have already been restored. The smoke harness uses this after the production
build/npm restoration; ordinary AppHost startup runs the incremental installer.

### Isolated history and fixtures

Aspire defaults to `src/companion/.artifacts/development`. All default history,
settings and monitoring checkpoints live there. Logs go to process output and
the Aspire dashboard, not production log files. Monitoring is forcibly disabled
for this invocation; no real game installation is configured. The new
`ARTISAN_LOGBOOK_DATA_DIRECTORY` absolute-path override applies to **all CLI
commands**; a database-only override still has its original semantics.

Stop Aspire before offline import/reset because the existing writer owns the
database. Import through the existing canonical ingestion pipeline:

```sh
node tools/development.mjs import-fixture
aspire run --apphost tools/AppHost/AppHost.csproj
```

This imports the committed, generated `v1-outcome1.lua` SavedVariables fixture; repeated
imports are idempotent. It does not overwrite a populated database or seed through
repositories. For a larger history, stop Aspire and copy an existing database
to the development directory explicitly (never use the original path as the
development writer). Keep the matching monitoring sidecar if copying one.

Explicit reset, **after stopping Aspire**:

```sh
node tools/development.mjs reset --confirm
```

Only that one repository-owned development directory is removed. Reset first
probes the existing database using the CLI and refuses a busy/unopenable database.

### Frontend checks

From `src/companion/web` (not concurrently with an MSBuild frontend restore),
run the relevant checks:

```sh
npm ci
npm run codegen
npm run typecheck
npm run lint
npm run format:check
npm run test
npm run build
```

Normal CI builds production assets through MSBuild, then runs lint, formatting,
frontend tests and npm audit on Linux. For changes to Aspire or the Vite proxy, run
`npm run test:development` from `web`: it imports a fixture into temporary data,
starts the actual AppHost and checks backend health, Vite, REST and GraphQL.
GraphQL reads canonical crafts from the imported fixture. The smoke runs the
normal development dependency installer and stops its processes.
It does not exercise HMR; verify React Fast Refresh and CSS HMR manually when
changing that workflow. Neither this smoke nor the incremental-build smoke runs
on every PR. The locally runnable extended suite and manual GitHub workflow are
described in [CONTRIBUTING](../../CONTRIBUTING.md#extended-regression-validation).

### .NET tests and asset modes

Ordinary container builds use development assets. Tests that serve the embedded
application need production resources; explicitly select that mode for their
build (do not reuse a development build with `--no-build`):

```sh
dotnet test ArtisanLogbook.Companion.slnx -c Release -p:CompanionWebDevelopment=false
```

Other targeted backend tests may use the container default. GitHub Actions does
not load devcontainer `remoteEnv`; its ordinary builds retain production assets.
Stop Aspire before changing asset modes in shared build directories.

## Generated API contracts

Apollo Client 4 centralizes `/graphql`, POST-only transport, no credentials,
and `X-Artisan-Logbook-Client: web` in `src/api/clients.ts`. The complete REST
contract is generated with openapi-typescript and consumed by openapi-fetch;
it uses relative paths and the same header. Browser AbortSignals propagate to
REST. Problem responses preserve HTTP status/code, but the UI does not display
raw server exception details.

GraphQL Code Generator's client preset reads the committed
`src/Runtime/GraphQL/schema.graphql`, not live introspection. Operations are
`.graphql` source files; generated operation types/documents are the only
TypeScript representation. `npm run codegen` needs no running server. CI builds
against both committed contracts, while the existing backend SDL/OpenAPI
contract tests ensure they match the host.

Apollo's default `__typename:id` identity uses stable opaque canonical IDs.
Dimension IDs already include GameContext and entity kind; craft IDs encode the
canonical craft identity. No decoder or parallel cache identity is introduced.
Pagination uses `nodes`, `pageInfo.endCursor` and `hasNextPage` explicitly;
connections are not assumed to be full Relay connections. A page is replaced
when advancing, with a Newest action to reset; no generic pagination merger.
Analytical operations carry the complete active context and current scope.
Detailed investigations retain results until the user refreshes; relevant
history changes are indicated rather than silently replacing the evidence.
Missing character names render as "Unknown character", not an opaque cache
identifier.

Operational status and craft counts refresh 30 seconds after each completed
request while the document is visible, and immediately when it becomes visible
again. Hidden documents do not start refresh requests; a pending request may
finish. Requests are serialized, failures retain retry/error presentation and
recover on the next refresh, and unmount/retry cancels superseded requests.
No subscriptions or general cache-invalidation mechanism is involved.

**Numeric policy:** standard JSON parsing is used. Generated Long/Decimal scalars
are `number` and are **not exact arbitrary-precision representations**.
Analytical aggregate quantities use decimal strings where exactness is required;
do not perform precision-sensitive arithmetic on the ordinary numeric scalar
mappings. REST counts outside the browser's safe integer range require an
explicit precision warning. Network/unavailable, HTTP rejection, GraphQL
validation and execution failures have redacted retry states.

TypeScript stays on **5.9.3** because current openapi-typescript and
typescript-eslint peer ranges do not support TypeScript 7. The lockfile's
minimatch override uses patched 11.0.1 for current build tools' transitive glob
dependency; codegen/lint/tests verify compatibility.

## Publish and verify one executable

Supported distribution smoke targets are **linux-x64** and **win-x64**. From
`src/companion`, stop Aspire and explicitly override the container's development
default for this invocation:

```sh
dotnet publish src/Cli/Cli.csproj -c Release -r linux-x64 \
  --self-contained true -p:CompanionWebDevelopment=false -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false \
  -warnaserror -o .artifacts/publish/linux-x64
node tools/smoke-publish.mjs .artifacts/publish/linux-x64/artisanlogbook \
  ../addon/tests/fixtures/legacy/v1-outcome1.lua
```

PowerShell:

```powershell
dotnet publish src/Cli/Cli.csproj -c Release -r win-x64 --self-contained true `
  -p:CompanionWebDevelopment=false `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:PublishTrimmed=false -warnaserror -o .artifacts/publish/win-x64
node tools/smoke-publish.mjs .artifacts/publish/win-x64/artisanlogbook.exe `
  ../addon/tests/fixtures/legacy/v1-outcome1.lua --skip-browser
```

`-p:CompanionWebDevelopment=false` works on either OS without unsetting the
environment variable. Publishing rebuilds the production provider even after
development-only builds in the same directories. Do not use `--no-build`; both
that shortcut and publishing with development assets remain rejected.

The smoke harness copies **only the executable** into a new empty temporary
directory, removes Node/npm/Aspire from the child's PATH, uses isolated writable
data, imports the fixture with the copied executable, retrieves HTML and every
referenced JS/CSS bundle with content-type checks, and checks representative
REST/OpenAPI/POST GraphQL responses. On Linux it also uses Chromium to check
that the application renders and makes real REST and GraphQL requests. The
devcontainer provisions Chromium; on other Linux environments install the
browser and system dependencies with `npx playwright install --with-deps
--only-shell chromium` from `web`. Windows can use `--skip-browser`.
Linux shutdown must exit successfully; Node's Windows process signal
terminates the child rather than delivering console Ctrl+C, so this smoke does
not claim a Windows graceful-shutdown test. Existing backend lifecycle tests
remain authoritative there.

The browser harness is developer/CI tooling, not part of the distribution.
The application needs no Node, npm, Aspire, Docker, network, `wwwroot` or
separate frontend files. DuckDB native-library extraction and external writable
history/settings/checkpoints remain the existing single-file behavior.
The Windows local deployment script still publishes the CLI, not AppHost.
Normal CI runs the full .NET suite and one executable-only smoke on each OS,
plus Linux frontend checks, browser smoke, NuGet tool packaging and independent
publish guards. Windows uses the deployment script and checks its `al.cmd`
alias. Component tests cover pagination, freshness, cancellation and errors;
backend tests cover persistence, contracts, security and lifecycle.

When changing Windows deployment failure handling, run
`.\scripts\tests\Deploy-Companion.Tests.ps1` from the repository root on Windows.
It uses a temporary installation and verifies missing tools and failed frontend
build/restore leave that installation unchanged. It temporarily modifies
`web/codegen.ts` and invalidates the npm restore, so do not run it concurrently
with development or another build.

## Release

The **Release companion** GitHub Actions workflow runs from `master` and
accepts the version bump and release channel (`alpha`, `beta` or `stable`). It
calculates a `companion-v<version>` tag independently of addon tags, stamps
that version into the builds, publishes the single executable for each
supported target, and checks that the executable and packed NuGet tool report
the release version. It does not rerun tests; normal CI already validates the
commit being released. It then creates or reuses the GitHub release and attaches
`artisanlogbook-companion-<version>-linux-x64.tar.gz`,
`artisanlogbook-companion-<version>-win-x64.zip` and
`ArtisanLogbook.Companion.<version>.nupkg`. Reruns preserve assets already
attached to the release. The tool package is then pushed to nuget.org with
trusted publishing (`NuGet/login`, owner `Kralizek`); the nuget.org policy is
bound to this workflow file, so keep the `release-companion.yml` name. Reruns
skip a version that is already on nuget.org.
