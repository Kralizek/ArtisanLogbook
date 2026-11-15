---
name: companion-runtime
description: Work on the Companion CLI, settings, discovery, monitoring, stable SavedVariables ingestion, operational API, hosting or application lifecycle. Use for C06 monitoring, C07 orchestration, shared HTTP API import coordination and shutdown.
---

# Companion runtime

Read [Runtime ownership](../../../src/companion/src/Runtime/README.md),
[ImportService](../../../src/companion/src/ImportService/README.md), and the
[CLI guide](../../../docs/companion/cli.md) for the affected surface.
[CONTRIBUTING](../../../CONTRIBUTING.md) owns practical validation commands.
Preserve the frozen [component catalog](../../../docs/companion/components.md):
C10 is runtime, C11 HTTP API, C14 CLI. C11 import-worker terminology refers to
shared coordination for the API, not a separate logical component.

- The CLI is the entry point; only `serve` builds the host. Runtime composes
  workers and one singleton HistoryStore writer. Preserve settings precedence,
  explicit errors, and isolated application data paths.
- Discovery inspects bounded layouts; it neither imports nor proves a game save
  is complete. C06 monitoring schedules/retries, C07 imports stable snapshots,
  and C11 coordinates manual/background operations through the same worker.
- Snapshot stability requires byte-identical reads separated by a quiet interval;
  the fingerprint identifies exactly the imported bytes. Changing/inaccessible
  input is not a successful import. C06 owns retry, not an unbounded reader loop.
- Advance successful monitoring checkpoints only for successful C07 outcomes;
  retain durable acknowledgement and pending receipt ownership. Do not treat
  watcher notifications as authoritative successful imports.
- Hold admission through commit/rollback. Stop producers/workers, reject new
  work and respect cancellation, bounded shutdown and disposal failures. Never
  claim database ownership released after a timeout.
- C10 owns `application-state.sqlite3` separately from C03 DuckDB history.
  Keep preferences qualified by complete GameContext; saved investigation JSON
  is authoritative while relational fields are management metadata. Use
  revision-checked explicit mutations, never global navigation state or
  cross-database transactions. Only the serving host initializes the store.
- Map explicit public operational DTOs; preserve loopback security and avoid
  exposing private paths, raw data or internal configuration in HTTP responses.

For detailed state ownership load [monitoring and lifecycle](references/monitoring-and-lifecycle.md).
Use [companion-history](../companion-history/SKILL.md) for SQL/domain work and
[addon-companion-contracts](../addon-companion-contracts/SKILL.md) for format
changes. Run focused monitoring, lifecycle, CLI or API tests; use extended
regressions when development orchestration or deployment is changed.
