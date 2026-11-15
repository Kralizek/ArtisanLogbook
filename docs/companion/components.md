# Companion component and capability catalog

This is the durable repository reference for the frozen 27 capabilities and 15 logical components approved in [epic #38](https://github.com/Kralizek/ArtisanLogbook/issues/38). IDs identify logical responsibilities, not projects, assemblies, versions or delivery milestones. The inventory below preserves the approved baseline; implementation status belongs in the epic and linked issues.

## Frozen capability inventory (27)

| ID | Capability | Primary logical component |
|---|---|---|
| CAP-01 | Read SavedVariables | C04 |
| CAP-02 | Write SavedVariables | C04 |
| CAP-03 | Local persistence | C03 |
| CAP-04 | Remote persistence | C05 |
| CAP-05 | Remote retrieval | C05 |
| CAP-06 | History merging | C02 |
| CAP-07 | Identity reconciliation | C02 |
| CAP-08 | Data validation | C01 |
| CAP-09 | Incremental synchronization | C08 |
| CAP-10 | Installation discovery | C06 |
| CAP-11 | File monitoring | C06 |
| CAP-12 | Import orchestration | C07 |
| CAP-13 | Safe restoration | C09 |
| CAP-14 | Analytical queries | C03 |
| CAP-15 | HTTP API | C11 |
| CAP-16 | Web interface | C12 |
| CAP-17 | Desktop integration | C13 |
| CAP-18 | CLI | C14 |
| CAP-19 | Headless execution | C10 |
| CAP-20 | Configuration management | C10 |
| CAP-21 | Application lifecycle | C10 |
| CAP-22 | Health and diagnostics | C10 |
| CAP-23 | Schema evolution | C03 |
| CAP-24 | Backup and recovery | C09 |
| CAP-25 | Data export and import | C15 |
| CAP-26 | Synchronization security | C08 |
| CAP-27 | Data lifecycle management | C10 |

CAP-01–CAP-24 are the original frozen capabilities. CAP-25–CAP-27 are the subsequently approved additions. The owner column is **primary responsibility only**; multiple components collaborate across boundaries.

## Frozen logical component inventory (15)

| ID | Component | Responsibility |
|---|---|---|
| C01 | **Craft History Model** | Canonical craft observations, dimensions, stable identities, provenance and domain validation |
| C02 | **History Reconciliation** | Deduplicate independent histories, reconcile identities and compatible corrections, surface conflicts |
| C03 | **History Store** | Authoritative OLAP persistence of craft facts/dimensions and analytical queries |
| C04 | **SavedVariables Adapter** | Read addon Lua observations; reconstruct addon-compatible recent detail, dimensions and calculated rollups |
| C05 | **Remote Storage Adapter** | Remote read/write transport for versioned history payloads; provider-specific transport/security |
| C06 | **Source Monitor** | Installation discovery, file location and reliable change monitoring |
| C07 | **Import Service** | Coordinate parse, validate, reconcile and transactional ingestion |
| C08 | **Synchronization Service** | Incremental push/pull, checkpoints, conflict reporting and sync security orchestration |
| C09 | **Restoration Service** | Guarded restoration, validation, backup and recovery while WoW is closed |
| C10 | **Application Runtime** | Headless lifetime, configuration, workers, diagnostics and housekeeping |
| C11 | **HTTP API** | Versioned local endpoints, OpenAPI and HTTP hosting |
| C12 | **Web Interface** | Analytics and operational web UI |
| C13 | **Desktop Shell** | Windows tray/macOS menu bar and access to settings/dashboard |
| C14 | **CLI** | Cross-platform commands, diagnostics, settings, imports, sync and headless control |
| C15 | **History Exchange Format** | Versioned provider-neutral serialization for remote sync and manual import/export |

### Component boundaries

- **C01/C02** describe craft semantics, validation, identity and reconciliation independently of Lua, remote providers and database technology.
- **C03** is the *only authoritative* persistence boundary for crafting history and also serves analytical queries.
- **C04** owns both directions of the addon format, including recomputing rollups; it does not merge the addon's rollup snapshots.
- **C05** owns remote transport; **C15** owns portable encoding. Neither defines merge rules.
- **C06** detects and locates sources; **C07** ingests. Remote retrieval can invoke the same ingestion/reconciliation rules.
- **C08** orchestrates cross-device synchronization using C02; **C09** orchestrates guarded reconstruction/restoration using C03/C04.
- **C10** hosts background functions and operational concerns; **C11–C14** expose shared functionality rather than reimplementing domain operations.
- Cross-cutting CAP-23 (schema evolution), CAP-24 (backup/recovery), CAP-26 (security), and CAP-27 (lifecycle management) require contributions from several components; primary ownership above is not exclusive.

## Implementation terminology

C11 is the HTTP API, not a new import-service component. The existing C11 import worker/admission/receipt terminology denotes coordination implemented for the HTTP API and shared with monitoring and CLI. C07 owns parse/validate/reconcile/transactional ingestion; C06 owns discovery, monitoring and retry eligibility; C10 owns host lifecycle and admission; C14 owns CLI commands. Preserve existing shared coordination rather than moving logic merely to match component labels.

GraphQL is part of C11; the embedded browser foundation and eventual dashboard are C12. Aspire is development orchestration, not a new logical component. See [Runtime ownership](../../src/companion/src/Runtime/README.md), [ImportService](../../src/companion/src/ImportService/README.md) and [monitoring architecture](rx-monitoring-architecture.md) for actual implementation contracts.
