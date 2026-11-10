# C06 experiment: decomposed, Rx-native monitoring

## Architecture checkpoint

This design starts at master `9bd6443` and the C03/C07/C10/C11 contracts.
Neither comparison PR was inspected during design. The comparison and final
assessment will be added only after the implementation has been tested.

### Responsibilities and ownership

| Component | Owns | Does not own |
| --- | --- | --- |
| `SourceChangeFeed` | Cold root-watcher streams, periodic discovery, per-source burst coalescing, watcher recovery | Source bytes, ingestion, checkpoints |
| `SourceReconciler` | One explicit discovery/inspection/admission operation, fair source ordering, diagnostic results | Subscriptions, timers, HTTP, canonical writes |
| `MonitoringCheckpoints` | Observed content, latest successful ingestion, latest attempt, retry eligibility, durable acknowledgement | Watchers, discovery, import execution |
| `SourceMonitor` | Hosted lifetime, preference changes, connecting streams, operational status | Parsing, transactions, reconciliation rules |
| Shared snapshot reader (C07) | Bounded, stable byte reads and byte-exact SHA-256 identity | Discovery, ingestion decisions |
| Checkpoint file adapter | Validated versioned metadata and flushed atomic replacement | Domain transitions |

These are not six interchangeable services with six interfaces. The reader and
file adapter are concrete I/O boundaries that can be replaced in tests.
Reconciliation can be called without Rx; checkpoint transitions can be tested
without either reconciliation or the filesystem.

We deliberately reject a worker per source/flavor. The C11 coordinator already
owns a bounded queue, duplicate-source admission and a single ingestion worker.
Duplicating any of those in C06 would add responsibility, not decompose it.

### Event flow

```text
configuration -- DistinctUntilChanged -- Select(cold session) -- Switch
                                              |
                    root watchers -- Merge -- per-source debounce
                    periodic ticks ---------- Merge
                    activation / explicit --- Merge
                                              |
completed import hints / checkpoint retries -- Merge
                                              |
                                bounded latest-pending concat
                                              |
                       explicit reconciliation / checkpoint save
                                              |
                         C11 admission -> C10 lease -> C07 -> C03
                                                         |
                                      exact-byte completion receipt
                                                         |
                                      MonitoringCheckpoints
```

Filesystem events are invalidations, not content or craft events. Every pass
rediscovers the configured layout. A source is identified by the existing opaque
location ID. Flavor labels are never interpreted as GameContext.

Root watchers cover newly created accounts and atomic replacement. Grouping by
source location allows Retail and Classic bursts to settle independently.
`GroupByUntil` expires inactive groups; there is no permanent subject dictionary
per source. Missing roots and failed watchers emit safe diagnostics and retry
on the injected scheduler. Periodic discovery remains independent of watchers.

`Switch` replaces *event producers*, not active reconciliation operations.
Disposing an activation also cancels its source inspection. A later activation
must still wait for the previous inspection to unwind.

### Serialization and the one unavoidable scheduling state

Plain `Select(FromAsync).Concat()` queues every hint without a bound.
`Switch()` unsubscribes but cannot prove an asynchronous operation has stopped.
`Throttle()` alone can starve a busy source and cannot retain an event arriving
during an import. None provides the required combination of guarantees.

A small, reusable bounded-concat operator therefore owns one coherent state:
idle, running with an optional latest pending observable, or completing/disposed.
One local lock protects concurrent notifications. It retains at most one pending
pass; replacing that pass is safe because each pass rediscovers all sources.
Completion starts the retained pass, never overlaps it. There is no channel,
manual worker queue, polling loop, or semaphore for event scheduling.
Source callbacks never execute filesystem inspection inline.

The operator is tested with virtual time and actual competing threads, including
the completion/notification boundary. It is the only custom Rx coordination
mechanism; failures are handled inside each work observable so one failed pass
cannot terminate the monitoring subscription.

### Checkpoint state and acknowledgement

Each source has one immutable checkpoint, not a list of completion events:

- Latest observed fingerprint.
- Latest successful `(attempt sequence, fingerprint)` receipt.
- Latest attempted import and its outcome.
- Retry deadline / last inspection failure.

The successful receipt and latest attempt are separate: a failure after success
must not erase the success awaiting persistence. Older successes cannot replace
newer successes; older attempts cannot replace newer attempts. A successful
receipt never changes the observed fingerprint, so an observation made during
an active import remains pending when the imported bytes differ.

C11 reserves checkpoint capacity before accepting work and delivers completions
directly to the checkpoint owner before releasing the source. Event notifications
only wake persistence; they are not the record of completion and can be coalesced.
The operation list's normal eviction cannot lose an unacknowledged receipt.
State is bounded by an explicit source limit and constant space per source.
Absent, inactive, durably acknowledged sources can be pruned; pruning monitoring
metadata never removes canonical history.

One short state lock protects immutable transitions and snapshot capture.
A separate persistence serializer is justified by a different invariant:
an older file replacement must never overtake a newer one. File I/O is outside
the state lock, so completions can arrive during a save. Only the captured
revision is acknowledged after a successful flushed atomic replacement;
later transitions remain dirty. Save failure retains the entire pending effect
and retries without reimporting successful bytes.

Checkpoint files are sidecars scoped to the selected history database, not
canonical craft storage. Invalid/unsupported metadata fails explicitly, never
manufactures success. A restart uses only durable successful receipts; imports
interrupted before acknowledgement are safely repeated through C07.

### Stable snapshots and fair reconciliation

C06 and C07 share a reader: bounded reads, metadata checks, two byte-identical
reads separated by a quiet interval, strict UTF-8, and a hash of the actual
bytes (including any BOM). No finite read can prove WoW has finished saving;
parse failures and later changes still require retry.

C06 inspects and admits *paths*, not retained 64 MiB buffers. C07 re-reads through
the same abstraction and returns its actual fingerprint. This extra inspection
is intentional: a file may change while waiting in C11's queue. The checkpoint
must describe what C07 committed, never what C06 previously inspected.

Each unstable or failed source yields a diagnostic and retry deadline without
blocking inspection of other sources. Least-recently-admitted sources are
considered first so frequently changing sources cannot monopolize queue capacity.
No canonical operation runs outside C11/C10/C07.

### Preferences, status and shutdown

Disabled remains the default. PUT saves through the existing settings store,
preserves invocation overrides and reports both saved and effective preferences.
Only effective changes replace an activation. There is no implicit settings
file hot reload. Enabling triggers immediate discovery.

Operational status is an immutable snapshot. Results are associated with their
activation; obsolete results cannot publish Active after disable or re-enable.
Checkpoint maintenance remains available while source monitoring is disabled,
including completions of manually submitted imports.

Stopping disposes source subscriptions and cancels inspection, awaits the
serialized pass, and preserves C11's existing drain/deadline cancellation.
Final checkpoint persistence happens after all import workers have stopped.
Persistence failure is visible and fails graceful shutdown rather than
acknowledging data that was not saved. A permanently unwritable disk plus forced
process termination cannot be made transactional with DuckDB by Rx: the previous
complete sidecar remains valid and restart conservatively reimports.

### Critical assessment before implementation

- The four conceptual responsibilities are useful, but a separate scheduler,
  per-source worker, or interface for each would add avoidable machinery.
- State that can be derived (pending ingestion, unchanged content, disabled
  status) must not become a second independently mutable flag.
- The bounded-concat slot and persistence serializer solve distinct invariants;
  neither may migrate into reconciliation logic.
- Completion delivery must be an explicit C11-to-checkpoint call, not a lossy Rx
  subscription to a bounded operation-history list.
- Watcher recovery and checkpoint retry must not sleep inside a reconciliation
  pass or delay preference changes.
- Changing debounce policy must require no knowledge of DuckDB. Changing
  checkpoint persistence/retry rules must require no knowledge of subscriptions.
  Implementation and tests will be evaluated against these boundaries.

## Implementation findings

- Status is a plain immutable snapshot behind the monitor's one lock.
  Configuration invalidations use a non-replaying subject; a synchronized Rx
  stream resolves current settings, rather than replaying potentially reordered
  configuration snapshots. No observer is invoked while the state lock is held.
  Using a
  `BehaviorSubject` as both status storage and input introduced a reproducible
  startup lock inversion between its subscription lock and the status lock.
  Removing that feedback path fixed the cause without adding a scheduler thread
  or another synchronization primitive. Hosted startup and competing
  watcher/request regression tests cover both directions of the lock boundary.
- C11 rechecks an automatic request's inspected fingerprint under its existing
  admission lock. Otherwise a manual import completing between inspection and
  admission could cause a redundant automatic import from a stale decision.
- Full-queue rejection happens before reserving an attempt sequence. Fairness
  orders sources by actual admission, not by unsuccessful attempts to enqueue.
- Restart converts persisted pending attempts to cancelled/retryable metadata,
  never success. This also allows absent interrupted sources to be pruned once
  the recovery transition is durable.
