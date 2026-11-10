# Companion local HTTP API

`artisanlogbook serve` hosts a versioned, loopback-only HTTP API (`/api/v1`) for
operational visibility, source discovery, and asynchronous manual imports. It is
implemented with ASP.NET Core Minimal APIs and **MinimalOpenAPI**: the contract in
`src/companion/src/Runtime/Api/Contracts/openapi.yaml` generates the endpoint
base classes, and the same document is published by the running host. Opt-in
SavedVariables monitoring is hosted by the same `serve` process and uses the
same bounded import worker and History Store as manual imports.

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
| GET | `/api/v1/monitoring` | Effective configuration, monitor state, counts, timestamps and safe diagnostics |
| PUT | `/api/v1/monitoring` | Persist and apply monitoring enabled state and interval |
| POST | `/api/v1/monitoring/reconcile` | Request an immediate reconciliation (acknowledgement only) |
| GET | `/api/v1/imports?limit=N` | Recent import operations (1–100, default 20), newest first |
| GET | `/api/v1/imports/{id}` | One operation, or 404 |
| POST | `/api/v1/imports` | Start an import; returns 202 with `Location` |
| GET | `/openapi/v1.yaml` | OpenAPI 3.0 document |

Enum values are serialized as written in the OpenAPI document (for example `Running`,
`Completed`). Errors use `application/problem+json` with a stable `code` extension
(for example `invalid-request`, `invalid-source-id`, `invalid-limit`, `unknown-source`,
`unknown-operation`, `no-sources`, `source-busy`, `import-capacity-exceeded`,
`monitoring-disabled`, `application-stopping`, `host-not-allowed`, `origin-not-allowed`,
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
curl -s $BASE/api/v1/monitoring

# Enable monitoring and reconcile at least every 60 seconds
curl -si -X PUT $BASE/api/v1/monitoring \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{"enabled":true,"reconciliationIntervalSeconds":60}'

# Trigger an immediate scan. This does not wait for imports to finish.
curl -si -X POST $BASE/api/v1/monitoring/reconcile \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{}'

# Disable automatic imports without stopping the Companion
curl -si -X PUT $BASE/api/v1/monitoring \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{"enabled":false,"reconciliationIntervalSeconds":60}'

# Import every discovered source (or pass {"sourceId":"src_…"} for one)
curl -si -X POST $BASE/api/v1/imports \
  -H 'X-Artisan-Logbook-Client: curl' \
  -H 'Content-Type: application/json' \
  -d '{}'

# Poll the operation named in the Location header until status is Completed/Failed/Cancelled
curl -s $BASE/api/v1/imports/<id>
```

PowerShell uses the same contract:

```powershell
$base = 'http://127.0.0.1:48721'
$headers = @{ 'X-Artisan-Logbook-Client' = 'powershell' }
$json = @{ enabled = $true; reconciliationIntervalSeconds = 60 } | ConvertTo-Json
Invoke-RestMethod "$base/api/v1/monitoring" -Method Put -Headers $headers `
  -ContentType 'application/json' -Body $json
Invoke-RestMethod "$base/api/v1/monitoring/reconcile" -Method Post -Headers $headers `
  -ContentType 'application/json' -Body '{}'
```

An import is accepted immediately (202) and runs on a bounded background worker,
independent of the request. Operations move through `Queued`, `Running`, then
`Completed`, `Failed` or `Cancelled`; `outcome` (`Successful`, `Partial`, `Failed`)
and per-source counts and diagnostics mirror the C07 import result. The `origin`
field distinguishes `Manual` from `Automatic`. Re-importing an unchanged source is
idempotent (observations are reported as already present).

## SavedVariables monitoring

Monitoring is **disabled by default**. Enable it with the `PUT /api/v1/monitoring`
request above or run `al serve --monitoring true`. The persisted preference is
used at the next start unless an invocation option overrides it. The interval is
validated from 1 to 86400 seconds and controls the correctness-oriented
reconciliation scan; a shorter interval is more responsive but reads source
files more often. A runtime `PUT` applies immediately and atomically persists
only the monitoring preference, retaining installation roots and all other
settings. If `--monitoring` or `--reconciliation-interval` was supplied, that
invocation override remains effective for the running process.

When enabled, the Companion scans configured installation roots at startup,
then periodically at the configured interval. Filesystem watchers observe
relevant installation, account and SavedVariables directories as a prompt
optimization. Events are only hints: they are coalesced into scans and never
parse files or write history directly. Watcher errors and overflow cause a
rebuild/scan; periodic reconciliation still recovers missed events and
temporarily unavailable directories.

The monitor hashes a source's content and waits for a bounded quiet period
before scheduling its import. World of Warcraft normally writes SavedVariables
on logout or `/reload`, not after every craft. While WoW is writing or replacing
a file, the monitor defers it; C07 then performs its existing stable-byte read,
validation and transactional reconciliation. A file that keeps changing or
temporarily disappears remains eligible for retry; its absence never deletes
canonical history. Atomic replacements at the same path retain the same opaque
source id. Monitoring checkpoints live separately from settings and craft
history, and only a successful C07 file import advances the ingested-content
fingerprint. Completed-import checkpoint effects remain pending until atomically
saved, and transient persistence failures are retried without another import.
Unexpected monitor worker failures are logged and retried with bounded backoff;
watchers are rebuilt on recovery.

Manual imports remain available while monitoring is disabled. Manual and
automatic imports use the same bounded worker, source-busy suppression,
admission lease and C03 writer. A successful manual file import also seeds the
monitor checkpoint from the exact bytes C07 read, avoiding an unnecessary
automatic repeat. Repeated notifications and full scheduling capacity do not
lose work: one pending need per source is retained and retried.

`POST /api/v1/monitoring/reconcile` returns `202` with `accepted` and
`coalesced`; this acknowledges only that a scan was accepted or merged with one
already pending. It does not mean imports have completed. If monitoring is
disabled, it returns `409` (`monitoring-disabled`) and does not enable monitoring.

`GET /api/v1/monitoring` reports the effective enabled state, interval,
`Disabled`/`Active`/`Degraded`/`Unavailable` state, discovered and watched
counts, last attempted and last successful reconciliation times, in-progress
state and actionable diagnostics. Diagnostics use opaque `sourceId` values and
never include file paths, account names, SavedVariables content or exceptions.
`Disabled` is distinct from an unhealthy monitor; `Degraded` diagnostics identify
discovery, watcher, unstable-source, import, worker-recovery or checkpoint retry
conditions.

## Local access and security

The API is a privileged local interface and defends against browser-driven access:

- Only `Host` values `127.0.0.1`, `localhost` and `[::1]` are accepted (DNS-rebinding defense).
- Requests with a cross-site `Sec-Fetch-Site` or a foreign `Origin` are rejected with 403. CORS is not enabled, so browsers cannot read responses cross-origin.
- `POST` and `PUT` require the `X-Artisan-Logbook-Client` header (any non-empty value), which cross-site forms cannot send and which forces a CORS preflight that is denied, plus `Content-Type: application/json`, a `Content-Length` and a body of at most 4 KiB. Other methods return 405.
- Clients cannot supply paths; unknown or malformed source ids are rejected.
- Responses carry `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.

Terminal tools and local scripts only need to send the client header on `POST` and `PUT`.

## Operational behavior

- Operation state is process-local, bounded (the most recent 100 operations are retained, at most 8 can be queued or running) and operation ids do not survive restarts. A full queue returns 429; a source that already has an active operation returns 409.
- Monitoring checkpoints persist source observations and successful content fingerprints, not operation ids or craft data. On restart, files are scanned and compared with successful checkpoints; unchanged snapshots are skipped.
- The single `HistoryStore` writer is shared with the rest of the host; imports go through the C10 admission mechanism, so C01/C02 reconciliation and transactions are unchanged.
- Failures in an import become a `Failed` operation and never stop the server.
- On shutdown the host stops accepting imports (`application-stopping`), lets the running import finish, cancels queued ones, then releases the database. If the host shutdown deadline expires, the running import is cancelled and rolled back.
- `serve` stays operational without any HTTP client.
