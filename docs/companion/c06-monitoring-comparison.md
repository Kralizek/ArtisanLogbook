# C06: three-way architecture comparison

## Recommendation

**Take the decomposed Rx-native implementation forward**, subject to normal PR
review and the Linux/Windows delivery checks. Keep this PR a draft experiment;
this is not a request to merge or close either reference PR or epic #38.

The deciding advantage is not the smaller hosting class. Event composition,
source eligibility and durable acknowledgement now have independently testable
boundaries, and the completion model addresses cases that event notification
coalescing alone cannot make safe. There is also a modest reduction in total
production C#, despite adding explicit boundaries and a fuller monitoring DTO.

## Scope and independence

All three candidates share master `9bd64434139dd9783c8ac03bf3c8e5fc8164dcca`.

| Candidate | Inspected implementation |
| --- | --- |
| Imperative [#72](https://github.com/Kralizek/ArtisanLogbook/pull/72) | `b9b94260dfc8ccd02f1df266eff2e7b7e5890172` |
| Monolithic Rx [#73](https://github.com/Kralizek/ArtisanLogbook/pull/73) | `daa7dced466daf6ca40bb759ece25567aa9b164b` |
| Decomposed Rx, this branch | `50efb7d`, following the independent assessment at `550da4a` |

The [initial design and independent assessment](rx-monitoring-architecture.md)
were committed before either reference was inspected. Reference code was read
from pinned Git objects; none was cherry-picked, copied into this implementation,
or modified. One subsequent local contract fix prevents monitoring PUT from
partially hot-reloading non-monitoring preferences.

The reference findings below are **code-inspection traces**, not claims that
their test suites were rerun or failed. Both references have successful Linux
and Windows checks at their inspected heads:
[72 CI](https://github.com/Kralizek/ArtisanLogbook/actions/runs/42733736823),
[73 CI](https://github.com/Kralizek/ArtisanLogbook/actions/runs/42803470316).
Green checks establish their tested behavior, not all the stronger interleavings
in this experiment's brief.

## Comparison

| Concern | #72: imperative | #73: monolithic Rx | This experiment |
| --- | --- | --- | --- |
| Responsibility boundary | Discovery, hashing, watcher rebuilding, eligibility, completion retention, persistence retry and lifecycle in one monitor | Native operators added, but the same domain responsibilities remain in one monitor | Cold feed, callable reconciler, checkpoint transitions/acknowledgement, small hosting/control root |
| Detection | Non-recursive watchers for roots, account and SavedVariables directories; global bounded signal channel | Recursive root streams, typed invalidations, per-source `GroupByUntil`/`Throttle` | Recursive root streams including layout changes; expiring per-source groups; independent periodic discovery |
| Serialization/backpressure | Channel capacity one plus pass semaphore | `Concat`, with `_pending`, `_scheduled`, `_inProgress` and an idle completion source | One isolated bounded-concat policy: running observable plus latest pending observable |
| Timing/recovery | Explicit signal/timer race, due-time calculation, exponential worker/checkpoint retry | Rx timers and `RetryWhen`, plus separate stability/retry/restart timer slots | Scheduler-injected feed/recovery/maintenance composition; eligibility deadlines in checkpoint state |
| Domain operations | Host-owned reconciliation method | Host-owned async pass | 63-line reconciler callable without subscribing to monitoring |
| Stable snapshots | C06 hashing separate from C07 reader; two-second observation window | Shared single-read snapshot helper; two-second observation window in monitor | Shared byte-identical double read with 250 ms quiet interval for both inspection and ingestion |
| Success knowledge | Durable checkpoint map plus pending completion map; preserves a pending success across later failure | Durable checkpoint map plus latest completion map; later failure can replace unpersisted success | Successful receipt and latest attempt are separate fields; durable revision acknowledgement is explicit |
| Completion delivery | Whole-operation event into monitor | Whole-operation event into monitor | Direct per-source transition before C11 releases that source; notifications only wake processing |
| Capacity | Bounded pending completion map; overflow requests rediscovery | Bounded pending completion map; overflow requests rediscovery | Capacity reserved before import admission; no accepted completion needs to be dropped |
| Fairness | Catalog order, retry deadlines | Catalog order, retry deadlines | Least-recently-admitted ordering, with a capacity-one busy-source regression |
| Checkpoint I/O | Synchronous save and acknowledgement in monitor | Synchronous save under completion lock in monitor | Snapshot outside state lock; async replacement serialized separately; only captured revision acknowledged |
| Shutdown | Monitor StopAsync precedes import worker StopAsync | Monitor StopAsync precedes import worker StopAsync; waits for monitor idle | Producer cancellation first; import worker drain; final metadata flush after all workers' StopAsync |
| Public status | Effective monitoring values, watcher counts, operation origin labels | Similar effective-value projection and origin labels | Saved/effective preferences and override flags, pending source/save state, bounded safe diagnostics |
| Test boundaries | Primarily hosted API tests and a monitor test hook | Primarily hosted API tests, with virtual scheduling | Pure transition tests, independent event tests, standalone reconciliation, and real-host/real-watcher integration |

### Size is supporting evidence, not the verdict

Same baseline, all production `.cs` under `src/companion/src`, including changes
to C07/C11 and handlers; generated code, tests, YAML and docs excluded. These are
physical lines including blanks/comments, not the differently defined
"code lines" quoted in #73's original PR description.

| Measure | #72 | #73 | This experiment |
| --- | ---: | ---: | ---: |
| Changed production C# files | 10 | 11 | 18 |
| Added/deleted production C# lines | +1250/-24 | +1249/-71 | +1174/-98 |
| **Net production C# addition** | **1226** | **1178** | **1076** |
| Hosting monitor file | 954 | 899 | 271 |
| New explicit lock objects / semaphores | 4 / 1 | 2 / 0 | 3 / 1 |
| Additional application signal channel | 1 | 0 | 0 |

This is 150 net production lines fewer than #72 and 102 fewer than #73, not a
claim that a 271-line orchestrator is the entire implementation.

The two reference monitors contain respectively **19 and 21 non-readonly
scalar/handle fields**, plus **3 and 4 mutable collections**. The new host has
two direct mutable fields, but its immutable state record contains five facts:
counting that as "only two states" would be dishonest. Across the new components,
the independent assessment accounts for about **16 global state/lifetime slots,
five per-source facts, and Rx-owned subscription state**. The important change
is their ownership and coupling, not hiding fields in records.

In particular, this design uses *more* explicit synchronization objects than
#73. The persistence semaphore serves a durable file-ordering invariant while
allowing completions during I/O; the local operator lock serves event
conflation; the host and checkpoint state locks protect unrelated domains.
Their smaller scopes are easier to audit than shared locks surrounding mixed
scheduling and persistence responsibilities.

## Correctness differences under this brief

### 1. Latest notification is not the latest successful ingestion

In #73, a success stores its fingerprint in the pending entry; a later failure
stores a null fingerprint at the same key. `RetainCompletion` replaces the
entry. When persistence finally runs, a null pending fingerprint falls back to
the *previously durable* fingerprint, not the success that was overwritten.
Thus `success A -> failure B -> persistence` can lose A's unacknowledged
checkpoint effect. See
[completion retention](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/SourceMonitor.cs#L608)
and [application](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/SourceMonitor.cs#L390).

#72 deliberately retains the pending successful fingerprint across later failure:
[its transition](https://github.com/Kralizek/ArtisanLogbook/blob/b9b94260dfc8ccd02f1df266eff2e7b7e5890172/src/companion/src/Runtime/SourceMonitor.cs#L604)
is stronger on this case. Both references version notification arrival; neither
encodes the source attempt's age in the receipt. Ordinary C11 delivery is serial,
but out-of-order redelivery is therefore an assumption, not a guarded invariant.
The new pure transitions guard successful and latest-attempt sequences
independently, including older success arriving after newer failure.

### 2. Bounded retention needs admission, not post-commit overflow recovery

Both references can discard a completion when their 4096-entry pending map is
full and recover by rediscovering/reimporting:
[72](https://github.com/Kralizek/ArtisanLogbook/blob/b9b94260dfc8ccd02f1df266eff2e7b7e5890172/src/companion/src/Runtime/SourceMonitor.cs#L616),
[73](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/SourceMonitor.cs#L634).
That can be safe for canonical history, but does not meet the stronger requirement
to retain completed-import information until its checkpoint effect is durable.

This branch reserves a checkpoint slot before accepting the import, compacts
multiple completions into successful/latest-attempt state, and returns an
explicit capacity rejection instead of dropping a receipt.

### 3. Monitor idle is not import-worker drain

Both references register the monitor **after** the import hosted service
([72 registration](https://github.com/Kralizek/ArtisanLogbook/blob/b9b94260dfc8ccd02f1df266eff2e7b7e5890172/src/companion/src/Runtime/Api/ApiHosting.cs#L24),
[73 registration](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/Api/ApiHosting.cs#L26)).
Reverse-order StopAsync stops/unsubscribes the monitor before C11 drains its
active import. A completion reported by that draining import then has no monitor
subscriber. There is no final post-worker checkpoint flush in either reference:
[72 stop](https://github.com/Kralizek/ArtisanLogbook/blob/b9b94260dfc8ccd02f1df266eff2e7b7e5890172/src/companion/src/Runtime/SourceMonitor.cs#L107),
[73 stop](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/SourceMonitor.cs#L800).

Additionally, #73's idle completion depends on an empty pending-completion map.
Its stop awaits that idle task; cancelling a pass at the shutdown deadline does
not itself empty the map or complete idle. Persistent save failure therefore
needs a stronger shutdown proof than subscription disposal.

This branch records receipts independently of subscriptions and performs the
final flush in StoppedAsync, after **all** import-worker StopAsync calls. Tests
hold an import across shutdown and separately make final persistence fail.
Canonical history is never discarded in these comparisons; the difference is
whether successful checkpoint acknowledgement is completed or visibly fails.

### 4. Checkpoints must be scoped to the selected history database

Both references use the same per-user
`monitoring-checkpoints.json` regardless of `--database`:
[72 store](https://github.com/Kralizek/ArtisanLogbook/blob/b9b94260dfc8ccd02f1df266eff2e7b7e5890172/src/companion/src/Runtime/MonitoringCheckpointStore.cs#L36),
[73 store](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/MonitoringCheckpointStore.cs#L35).
Source IDs identify locations, not destination databases. Reusing these
checkpoints with a different empty database can suppress its initial imports.

This branch uses `<database>.monitoring.json`. This prevents cross-path
destination confusion; it is **not** a generation identifier for manual database
replacement at the same path. Such restoration still requires resetting the
sidecar, as explicitly documented.

### 5. Rx helps timing, but does not make domain orchestration disappear

#72's worker retry sleeps inside its loop, separately from its signal/timer race
([worker](https://github.com/Kralizek/ArtisanLogbook/blob/b9b94260dfc8ccd02f1df266eff2e7b7e5890172/src/companion/src/Runtime/SourceMonitor.cs#L209)).
Re-enabling during that sleep cannot bypass it merely by adding a signal.

#73 genuinely improves producer composition and scheduler-based testing.
However, its hosted class still owns pending/scheduled/in-progress flags,
three timer slots, worker/event subscriptions, watcher sets, checkpoint maps and
completion acknowledgement:
[state](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/SourceMonitor.cs#L58),
[coordination](https://github.com/Kralizek/ArtisanLogbook/blob/daa7dced466daf6ca40bb759ece25567aa9b164b/src/companion/src/Runtime/SourceMonitor.cs#L309).
Changing checkpoint retry still requires understanding worker idle and timer
disposal.

The new design eliminates the separate completion inbox, overflow recovery flags,
watcher registry, stabilization timer/state and manual retry sleeper. It
**separates rather than eliminates** necessary durable receipt ordering and
persistence acknowledgement. Rx handles *when* to invoke explicit operations;
it never pretends that observing an event is a transaction acknowledgement.

## Tradeoffs and adoption conditions

- #72 requires no Rx dependency and uses familiar imperative control flow.
  Its success-plus-failure retention is stronger than #73's.
- #73 already expresses independent debounce groups and cold root recovery well.
  It also has fewer explicit lock objects than this experiment. Neither fact
  by itself proves lower overall lifecycle complexity.
- Both references have exponential backoff and explicit watcher limits. This
  experiment uses simple fixed retry cadences and one watcher per configured
  root. A large-scale deployment may need measured resource/backoff refinement.
- The new double-read quiet interval is 250 ms rather than the references'
  two-second cross-pass window. This is an intentional behavior choice, not
  implementation parity. Serial inspection of many sources costs real I/O and
  quiet time; no throughput improvement is claimed.
- Existing accepted imports continue after disabling in all candidates. This
  experiment preserves C11's public import contract rather than adding the
  reference branches' manual/automatic origin field. Its monitoring response
  instead explicitly separates saved preferences, effective values and overrides.
- Invalid checkpoint metadata fails startup here instead of proceeding with an
  empty map. This preserves unsupported/corrupt metadata but reduces availability;
  operators must follow the documented backup/reset procedure.
- The 85-line bounded-concat utility is real custom scheduling policy. Its
  concurrency tests and the rule against invoking observers under application
  state locks are part of the design, not optional polish.
- Keep the Linux and Windows CI checks as adoption gates. Local Linux validation
  does not stand in for Windows watcher, file-sharing, formatting or deployment
  behavior.

**Why this is more than moving a monolith:** a debounce change is confined to
[SourceChangeFeed](../../src/companion/src/Runtime/Monitoring/SourceChangeFeed.cs)
and its scheduler tests; neither C07 nor DuckDB appears in that component.
A checkpoint retry/acknowledgement change is confined to
[MonitoringCheckpoints](../../src/companion/src/Runtime/Monitoring/MonitoringCheckpoints.cs),
[pure source transitions](../../src/companion/src/Runtime/Monitoring/SourceCheckpoint.cs),
and their tests; none owns an Rx subscription. The
[reconciler](../../src/companion/src/Runtime/Monitoring/SourceReconciler.cs)
can change eligibility/admission order without knowing watcher disposal.
Those are enforceable dependency boundaries, backed by failure-interleaving
tests, rather than a favorable line count for one file.
