# Companion local HTTP API

`artisanlogbook serve` hosts a versioned, loopback-only HTTP API (`/api/v1`) for
operational visibility, source discovery, monitoring, and asynchronous imports. It is
implemented with ASP.NET Core Minimal APIs and **MinimalOpenAPI**: the contract in
`src/companion/src/Runtime/Api/Contracts/openapi.yaml` generates the endpoint
base classes, and the same document is published by the running host.

The same host exposes canonical crafting history through the separate read-only
[GraphQL API](graphql.md); it does not replace these operational endpoints.

## Starting the API and port selection

```bash
artisanlogbook serve            # preferred port from settings (default 48721)
artisanlogbook serve --port 5050
```

On startup the Companion tries `127.0.0.1:<preferred port>`. If another process
owns that port, it asks the operating system for a free loopback port instead.
Any other startup failure is not masked. The port setting is only a preference:
fallback never rewrites persisted settings. The actual URL is printed and logged:

```text
Artisan Logbook API: http://127.0.0.1:48721/api/v1 (OpenAPI: http://127.0.0.1:48721/openapi/v1.yaml)
```

The server binds IPv4 loopback only and never a wildcard or LAN address.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/health` | 200 when running, 503 while starting, stopping or failed |
| GET | `/api/v1/status` | Version, lifecycle state, start time, database availability and schema version, canonical craft count and per-GameContext counts, safe failure info |
| GET | `/api/v1/sources` | Discovered SavedVariables sources with stable ids (`src_…`) and discovery diagnostics |
| GET | `/api/v1/monitoring` | Saved/effective preferences, override indicators, monitoring state and diagnostics |
| PUT | `/api/v1/monitoring` | Persist monitoring preferences and apply their effective values |
| POST | `/api/v1/monitoring/reconcile` | Request reconciliation while enabled; returns 202 with status `Location` |
| GET | `/api/v1/imports?limit=N` | Recent import operations (1–100, default 20), newest first |
| GET | `/api/v1/imports/{id}` | One operation, or 404 |
| POST | `/api/v1/imports` | Start an import; returns 202 with `Location` |
| GET | `/api/v1/entity-preferences?project=N[&progressionTrack=…]` | List recipe and item preferences for one context |
| PUT | `/api/v1/entity-preferences/{Recipe|Item}/{id}/pin` | Set one entity's pinned state |
| PUT | `/api/v1/entity-preferences/{Recipe|Item}/{id}/hidden` | Set one entity's hidden state |
| GET, PUT | `/api/v1/preferences/last-selected-context` | Read or set the startup fallback context |
| GET, POST | `/api/v1/saved-investigations` | List or create named JSON investigation definitions |
| GET, DELETE | `/api/v1/saved-investigations/{id}` | Retrieve or revision-check and delete a saved investigation |
| PUT | `/api/v1/saved-investigations/{id}/name` | Rename using the expected revision |
| PUT | `/api/v1/saved-investigations/{id}/definition` | Replace the versioned JSON definition using the expected revision |
| GET | `/openapi/v1.yaml` | OpenAPI 3.0 document |

Enum values are serialized as written in the OpenAPI document (for example `Running`,
`Completed`). Errors use `application/problem+json` with a stable `code` extension
(for example `invalid-request`, `invalid-source-id`, `invalid-limit`, `unknown-source`,
`unknown-operation`, `no-sources`, `source-busy`, `import-capacity-exceeded`,
`checkpoint-capacity-exceeded`,
`application-stopping`, `host-not-allowed`, `origin-not-allowed`,
`client-header-required`, `unsupported-content-type`, `request-too-large`,
`internal-error`).

Source ids identify a discovered `SavedVariables` file; they are not GameContext
identities and no project or progression track is inferred from the installation
directory. Responses never include filesystem paths, account names, raw
SavedVariables, or stack traces.

## Examples

```bash
BASE=http://127.0.0.1:48721

curl -s $BASE/api/v1/health
curl -s $BASE/api/v1/status
curl -s $BASE/api/v1/sources

# Import every discovered source (or pass {"sourceId":"src_…"} for one)
curl -si -X POST $BASE/api/v1/imports \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{}'

# Poll the operation named in the Location header until status is Completed/Failed/Cancelled
curl -s $BASE/api/v1/imports/<id>
```

An import is accepted immediately (202) and runs on a bounded background worker,
independent of the request. Operations move through `Queued`, `Running`, then
`Completed`, `Failed` or `Cancelled`; `outcome` (`Successful`, `Partial`, `Failed`)
and per-source counts and diagnostics mirror the C07 import result. The `origin`
field is `Manual` for explicit HTTP imports and `Automatic` for imports admitted by
monitoring. Re-importing an unchanged source is idempotent (observations are
reported as already present).

## Monitoring

Monitoring is **enabled by default**. An explicit saved or invocation-level
disable remains authoritative; omitted preferences in older version-1 settings
use the new default without rewriting the file. The GET response reports `preferences`,
`effective`, and `overrides` separately. Invocation options retain precedence:
for example, `serve --monitoring false` allows saving an enabled preference but
does not enable the current host. Interval overrides are reported independently.

```bash
curl -s $BASE/api/v1/monitoring

curl -si -X PUT $BASE/api/v1/monitoring \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{"enabled":true,"reconciliationIntervalSeconds":60}'

curl -si -X POST $BASE/api/v1/monitoring/reconcile \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

PUT requires both properties, with an interval of 1–86400 seconds. It saves
through the existing settings store before changing the effective configuration.
Invalid requests return 400; invalid/unsupported/concurrently changed settings
return 409 `settings-conflict`; persistence failure returns 503
`settings-save-failed`. A failed save does not change the running configuration.
Only monitoring preferences are applied at runtime. Other externally changed
settings are preserved in the saved file, but installation roots and HTTP binding
remain invocation-scoped until restart; there is no partial settings-file hot reload.

Enabling starts discovery immediately. Source-specific filesystem bursts are
coalesced for 250 ms, and the configured periodic interval recovers missed
notifications and unavailable installations. Stable content is identified by its
bytes, not just timestamps. Automatic and manual imports share C11's bounded
single-worker queue, C10 admission, and C07 transactional ingestion.

POST accepts an **invalidation**, not a new import operation. Repeated requests
may become one pass. Its `Location` is `/api/v1/monitoring`; inspect `/api/v1/imports`
for accepted imports. Disabled monitoring returns 409 `monitoring-disabled`;
explicit manual imports remain available. Disabling disposes producers and
cancels inspection, but does not revoke already accepted imports.

States are `Disabled`, `Starting`, `Reconciling`, `Active`, `Degraded`, `Stopping`,
and `Stopped`. The last reconciliation time/counts are null before a completed
pass. `pendingSources` describes unresolved observed content or inspection
failures, not a second import queue. `checkpointSavePending` distinguishes a
successful import whose monitoring metadata has not yet been acknowledged.
Diagnostics are bounded to 50 entries with `diagnosticsTruncated`; they never
contain source paths or account names.

Successful file-import fingerprints are persisted only after C07 reports success.
Checkpoint save failure retains receipts and retries without another import.
Watchers and transient failures retry on a two-second cadence; persistence
maintenance checks run every second, including when monitoring is disabled.
Monitoring metadata is bounded to 4096 sources, with constant state per source.
Durably acknowledged, absent, inactive sources can be pruned without removing
canonical history. Reappearance after pruning may cause an idempotent reimport.

The database-scoped `<database>.monitoring.json` sidecar is an ingestion
optimization, not authoritative history. Keep it with the matching database.
After manually replacing/restoring a database, remove its sidecar while the host
is stopped to force reconciliation rather than reuse checkpoints from a different
history. Invalid sidecars fail startup explicitly; back them up before repair.
Atomic replacement follows the settings persistence convention, not a portable
cross-file or power-loss transaction. Failed final persistence fails graceful
shutdown; a later restart conservatively repeats any unacknowledged ingestion.

See [event flow and component ownership](rx-monitoring-architecture.md) for the
implementation invariants, and [monitoring.http](../../src/companion/src/Runtime/monitoring.http)
for executable request examples.

## Local access and security

The API is a privileged local interface and defends against browser-driven access:

- Only `Host` values `127.0.0.1`, `localhost` and `[::1]` are accepted (DNS-rebinding defense).
- Requests with a cross-site `Sec-Fetch-Site` or a foreign `Origin` are rejected with 403. CORS is not enabled, so browsers cannot read responses cross-origin.
- `POST` and `PUT` require the `X-Artisan-Logbook-Client` header (any non-empty value), which cross-site forms cannot send and which forces a CORS preflight that is denied, plus `Content-Type: application/json` and a `Content-Length`. The REST body limit is 4 KiB; `/graphql` has a 16 KiB limit. Only the protected bodyless `DELETE` operations are additionally enabled; other mutation methods return 405.
- Saved-investigation `POST` and `PUT` bodies may be up to 300 KiB at the HTTP boundary; individual JSON definitions are additionally limited to 256 KiB and depth 32. Protected `DELETE` requires the client header and must be bodyless.
- Clients cannot supply paths; unknown or malformed source ids are rejected.
- Responses carry `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.

Terminal tools and local scripts send the client header on `POST` and `PUT`.

## Application state

The mutable state API is a separate capability from canonical history queries.
It is persisted by `application-state.sqlite3` in the per-user application data
directory, independently of the selected DuckDB history path. Recipe and item
preferences are qualified by the complete `(project, progressionTrack)` context
and entity ID. Pin and hide are independent desired-state values; repeating a
mutation is harmless, and changing one never overwrites the other. Preferences
do not alter capture, canonical history, or analytical totals.

The last-selected context is a nullable startup fallback: the GET returns
`{"context":null}` until a preference is set. It is not shared server-side
navigation state and does not scope GraphQL or REST history queries. Tabs can
continue using independent explicit contexts.

Saved investigations persist a named, versioned JSON object—not query results.
The JSON document is authoritative for the analytical definition; its context,
name, stable ID, timestamps and revision are relational management fields. The
Companion preserves nested and unknown definition fields, but only checks that
the document is an object, has no duplicate property names, stays within 256 KiB
and depth 32, and has a positive document version. It does not claim that a
definition is a valid or executable C12 investigation. Relative and fixed date
periods remain unchanged JSON; storage does not resolve them.

Create with `POST /api/v1/saved-investigations`, then retain the returned `id`
and `revision`. Rename and definition replacement send the revision last read:

```bash
curl -s -X PUT "$BASE/api/v1/saved-investigations/<id>/definition" \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{"definitionVersion":1,"definition":{"period":{"kind":"relative","days":90}},"revision":1}'
```

Successful updates increment the revision. A stale revision returns 409
`investigation-revision-conflict`; a missing ID returns 404
`unknown-investigation`. Deletion uses `?revision=N` and no request body.
Application-state persistence failures return a redacted 503
`application-state-unavailable`, not a database path or raw exception.

The runtime uses `Microsoft.Data.Sqlite` and Dapper. The native SQLite library
is part of the self-contained distribution, so users need no database service
or SQLite installation. Schema version 1 is recorded in SQLite metadata;
unrecognized application IDs, unsupported versions and invalid databases fail
explicitly and are never silently replaced. See [Runtime ownership and
lifecycle](../../src/companion/src/Runtime/README.md#host-composition-and-ownership)
for the C10/C11 boundary and DuckDB independence.

## Operational behavior

- Operation state is process-local and bounded (the most recent 100 operations are retained, with 8 waiting slots and one active worker). Operation ids do not survive restarts. A full queue returns 429; a source that already has an active operation returns 409.
- The single `HistoryStore` writer is shared with the rest of the host; imports go through the C10 admission mechanism, so C01/C02 reconciliation and transactions are unchanged.
- Failures in an import become a `Failed` operation and never stop the server.
- On shutdown the host stops accepting imports (`application-stopping`), lets the running import finish, cancels queued ones, then releases the database. If the host shutdown deadline expires, the running import is cancelled and rolled back.
- `serve` stays operational without any HTTP client.
