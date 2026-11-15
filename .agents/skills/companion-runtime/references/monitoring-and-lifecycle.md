# Monitoring and lifecycle

See the [frozen component catalog](../../../../docs/companion/components.md).
C11 is HTTP API; its import worker and receipts are shared coordination for
API, monitoring and CLI callers, not a replacement for C07 ingestion.

Read [Runtime monitoring ownership](../../../../src/companion/src/Runtime/README.md#monitoring-ownership),
[C06 state and acknowledgement](../../../../docs/companion/rx-monitoring-architecture.md)
and [C07 failure behavior](../../../../src/companion/src/ImportService/README.md#atomicity-and-failure-behavior).

`SourceChangeFeed` owns watcher hints; `SourceReconciler` discovers and admits
work; `MonitoringCheckpoints` owns source transitions and durable acknowledgement;
`SourceMonitor` serializes reconciliation. C11 terminal receipts reach checkpoints
directly. Dirty metadata and actionable source work are different. Do not replace
an active reconciliation before it unwinds or advance on a pending/failed receipt.

C07 imports the captured bytes and reports their SHA-256, including BOM; a stable
read is not proof WoW has finished saving. A read performs one bounded stability
check; C06 controls retries. Warnings can accompany success, while rejected or
failed imports do not advance a successful checkpoint.

The host shuts admission, stops workers and coordinates C03 disposal with
application lease draining. Propagate cancellation and retain leases through
completion. A bounded database timeout, cancelled lease drain or cleanup failure
is explicit; later successful disposal does not erase the earlier failure.
See [operational API](../../../../docs/companion/api.md) for public control and
security behavior.
