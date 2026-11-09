# Companion local HTTP API

`artisanlogbook serve` hosts a versioned, loopback-only HTTP API (`/api/v1`) for
operational visibility, source discovery, and asynchronous manual imports. It is
implemented with ASP.NET Core Minimal APIs and **MinimalOpenAPI**: the contract in
`src/companion/src/Runtime/Api/Contracts/openapi.yaml` generates the endpoint
base classes, and the same document is published by the running host.

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
| GET | `/api/v1/imports?limit=N` | Recent import operations (1–100, default 20), newest first |
| GET | `/api/v1/imports/{id}` | One operation, or 404 |
| POST | `/api/v1/imports` | Start an import; returns 202 with `Location` |
| GET | `/openapi/v1.yaml` | OpenAPI 3.0 document |

Enum values are serialized as written in the OpenAPI document (for example `Running`,
`Completed`). Errors use `application/problem+json` with a stable `code` extension
(for example `invalid-request`, `invalid-source-id`, `invalid-limit`, `unknown-source`,
`unknown-operation`, `no-sources`, `source-busy`, `import-capacity-exceeded`,
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
and per-source counts and diagnostics mirror the C07 import result. Re-importing an
unchanged source is idempotent (observations are reported as already present).

## Local access and security

The API is a privileged local interface and defends against browser-driven access:

- Only `Host` values `127.0.0.1`, `localhost` and `[::1]` are accepted (DNS-rebinding defense).
- Requests with a cross-site `Sec-Fetch-Site` or a foreign `Origin` are rejected with 403. CORS is not enabled, so browsers cannot read responses cross-origin.
- `POST` requires the `X-Artisan-Logbook-Client` header (any non-empty value), which cross-site forms cannot send and which forces a CORS preflight that is denied, plus `Content-Type: application/json`, a `Content-Length` and a body of at most 4 KiB. Other methods return 405.
- Clients cannot supply paths; unknown or malformed source ids are rejected.
- Responses carry `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.

Terminal tools and local scripts only need to send the client header on `POST`.

## Operational behavior

- Operation state is process-local, bounded (the most recent 100 operations are retained, at most 8 can be queued or running) and operation ids do not survive restarts. A full queue returns 429; a source that already has an active operation returns 409.
- The single `HistoryStore` writer is shared with the rest of the host; imports go through the C10 admission mechanism, so C01/C02 reconciliation and transactions are unchanged.
- Failures in an import become a `Failed` operation and never stop the server.
- On shutdown the host stops accepting imports (`application-stopping`), lets the running import finish, cancels queued ones, then releases the database. If the host shutdown deadline expires, the running import is cancelled and rolled back.
- `serve` stays operational without any HTTP client.
