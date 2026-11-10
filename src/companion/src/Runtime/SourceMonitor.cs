using System.Reactive;
using System.Reactive.Concurrency;
using System.Reactive.Disposables;
using System.Reactive.Linq;
using System.Reactive.Subjects;
using System.Security;
using System.Text.Json;

using ArtisanLogbook.ImportService;

using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

public enum SourceMonitoringState { Disabled, Active, Degraded, Unavailable }

public sealed record SourceMonitoringDiagnostic(string Code, string Message, string? SourceId);
public sealed record SourceMonitoringSnapshot(
    bool Enabled,
    int ReconciliationIntervalSeconds,
    SourceMonitoringState State,
    int DiscoveredSources,
    int WatchedDirectories,
    DateTimeOffset? LastReconciliationAttempt,
    DateTimeOffset? LastSuccessfulReconciliation,
    bool ReconciliationInProgress,
    IReadOnlyList<SourceMonitoringDiagnostic> Diagnostics);

public enum ReconciliationRequestStatus { Accepted, Coalesced, Disabled, Unavailable }

internal enum MonitoringEventKind
{
    Initial,
    FileSystem,
    Periodic,
    ExplicitRequest,
    ConfigurationChanged,
    ImportCompleted,
    StabilizationElapsed,
    WorkerRetry,
    WatcherRecovered
}

internal sealed record MonitoringEvent(MonitoringEventKind Kind, string? SourceId = null);

/// <summary>Rx coordinates invalidations; checkpoint and pending-completion state stays explicit.</summary>
public sealed class SourceMonitor(
    CompanionRuntimeConfiguration configuration,
    CompanionSettingsStore settingsStore,
    IMonitoringCheckpointPersistence checkpointStore,
    SourceCatalog catalog,
    ImportOperations imports,
    IHostApplicationLifetime lifetime,
    IScheduler scheduler,
    ILogger<SourceMonitor> logger) : IHostedService, IDisposable
{
    private static readonly TimeSpan StableQuietPeriod = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan FilesystemDebounce = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan GroupInactivityPeriod = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan InitialRetryDelay = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan MaximumRetryDelay = TimeSpan.FromSeconds(30);
    private const int MaximumPendingCompletionSources = 4096;
    private const int MaximumWatchRoots = 128;
    private readonly object _completionGate = new();
    private readonly object _gate = new();
    private readonly Subject<MonitoringEvent> _events = new();
    private readonly Subject<Unit> _reconciliationRequests = new();
    private readonly BehaviorSubject<MonitoringSettings> _preferences =
        new(configuration.EffectiveSettings.Monitoring);
    private readonly SerialDisposable _retryTimer = new();
    private readonly SerialDisposable _stabilityTimer = new();
    private readonly SerialDisposable _workerRestartTimer = new();
    private readonly SerialDisposable _eventSubscription = new();
    private readonly SerialDisposable _workerSubscription = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly Dictionary<string, MonitoringCheckpoint> _checkpoints = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PendingImport> _pendingImports = new(StringComparer.Ordinal);
    private readonly HashSet<string> _activeWatchRoots = new(InstallationDiscovery.PathComparer);
    private readonly HashSet<string> _failedWatchRoots = new(InstallationDiscovery.PathComparer);
    private CompanionRuntimeConfiguration _configuration = configuration;
    private MonitoringSettings _effectiveSettings = configuration.EffectiveSettings.Monitoring;
    private SourceMonitoringState _state = configuration.EffectiveSettings.Monitoring.Enabled
        ? SourceMonitoringState.Unavailable : SourceMonitoringState.Disabled;
    private SourceMonitoringDiagnostic[] _diagnostics = [];
    private DateTimeOffset? _lastAttempt;
    private DateTimeOffset? _lastSuccess;
    private int _discoveredSources;
    private bool _inProgress;
    private bool _pending;
    private bool _scheduled;
    private bool _stabilizationScheduled;
    private bool _applicationStopping;
    private bool _stopping;
    private bool _started;
    private bool _completionOverflow;
    private bool _watcherLimitExceeded;
    private long _completionVersion;
    private int _retryAttempt;
    private CancellationTokenRegistration _startedRegistration;
    private CancellationTokenRegistration _stoppingRegistration;
    private TaskCompletionSource _idle = Completed();

    public Task StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            foreach (MonitoringCheckpoint checkpoint in checkpointStore.Load())
                _checkpoints[checkpoint.SourceId] = checkpoint;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException
            or InvalidDataException or JsonException)
        {
            logger.LogWarning("SavedVariables monitoring checkpoints could not be loaded ({FailureType}); " +
                "current sources will be reconciled safely.", exception.GetType().Name);
            SetDiagnostic(new("checkpoint-load-failed",
                "Monitoring checkpoints could not be loaded; current files will be reconciled again.", null));
        }

        imports.OperationCompleted += ImportCompleted;
        StartWorker();
        _startedRegistration = lifetime.ApplicationStarted.Register(Activate);
        _stoppingRegistration = lifetime.ApplicationStopping.Register(BeginApplicationStopping);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => StopAndDrainAsync(cancellationToken);

    public SourceMonitoringSnapshot GetSnapshot()
    {
        lock (_gate)
            return new(_effectiveSettings.Enabled, _effectiveSettings.ReconciliationIntervalSeconds, _state,
                _discoveredSources, _activeWatchRoots.Count, _lastAttempt, _lastSuccess, _inProgress,
                _diagnostics.ToArray());
    }

    public SourceMonitoringSnapshot UpdatePreferences(MonitoringSettings preferences, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        MonitoringSettings effectiveSettings;
        lock (_gate)
        {
            if (_stopping || _applicationStopping || lifetime.ApplicationStopping.IsCancellationRequested)
                throw new CompanionSettingsException("The Companion is stopping and cannot update monitoring preferences.");
            CompanionSettingsStore.Validate(_configuration.EffectiveSettings with { Monitoring = preferences });

            SettingsLoadResult loaded = settingsStore.Load();
            if (!loaded.CanSave)
                throw new CompanionSettingsException(loaded.Diagnostic ?? "The monitoring preferences cannot be saved.");
            CompanionSettings saved = (loaded.Settings ??
                CompanionSettings.ForRoots(_configuration.EffectiveSettings.InstallationRoots.ToArray())) with
            {
                Monitoring = preferences
            };
            settingsStore.Save(saved, cancellationToken, loaded);

            _configuration = _configuration.WithPersistedPreferences(saved);
            _effectiveSettings = _configuration.EffectiveSettings.Monitoring;
            effectiveSettings = _effectiveSettings;
            _state = _effectiveSettings.Enabled ? SourceMonitoringState.Unavailable : SourceMonitoringState.Disabled;
        }

        imports.SetAutomaticEnabled(effectiveSettings.Enabled);
        _preferences.OnNext(effectiveSettings);
        if (effectiveSettings.Enabled)
            Signal(new(MonitoringEventKind.ConfigurationChanged));
        else
            CancelTimers();
        return GetSnapshot();
    }

    public ReconciliationRequestStatus RequestReconciliation()
    {
        lock (_gate)
        {
            if (_stopping || _applicationStopping || !_started ||
                lifetime.ApplicationStopping.IsCancellationRequested)
                return ReconciliationRequestStatus.Unavailable;
            if (!_effectiveSettings.Enabled)
                return ReconciliationRequestStatus.Disabled;
        }
        return Signal(new(MonitoringEventKind.ExplicitRequest))
            ? ReconciliationRequestStatus.Accepted
            : ReconciliationRequestStatus.Coalesced;
    }

    private void Activate()
    {
        lock (_gate)
        {
            if (_stopping || _started) return;
            _started = true;
        }

        StartEventStream();
        imports.SetAutomaticEnabled(_effectiveSettings.Enabled);
    }

    private void StartEventStream()
    {
        _eventSubscription.Disposable = Observable.Defer(() => _preferences
            .DistinctUntilChanged()
            .Select(settings => settings.Enabled
                ? EnabledEvents(settings)
                : _events.AsObservable())
            .Switch())
            .RetryWhen(errors => errors.SelectMany((exception, attempt) =>
            {
                EventStreamFailed(exception);
                return Observable.Timer(RetryDelay(attempt + 1), scheduler).Select(_ => Unit.Default);
            }))
            .Subscribe(HandleEvent, EventStreamFailed);
    }

    private void StartWorker()
    {
        _workerSubscription.Disposable = _reconciliationRequests
            .ObserveOn(scheduler)
            .Select(_ => Observable.Defer(RunQueuedPass))
            .Concat()
            .Subscribe(_ => { }, WorkerFailed);
    }

    private IObservable<MonitoringEvent> EnabledEvents(MonitoringSettings settings)
    {
        CompanionRuntimeConfiguration currentConfiguration;
        lock (_gate) currentConfiguration = _configuration;
        TimeSpan interval = TimeSpan.FromSeconds(settings.ReconciliationIntervalSeconds);
        IObservable<MonitoringEvent> periodic = Observable.Timer(interval, interval, scheduler)
            .Select(_ => new MonitoringEvent(MonitoringEventKind.Periodic));
        string[] roots = currentConfiguration.EffectiveSettings.InstallationRoots.ToArray();
        lock (_gate) _watcherLimitExceeded = roots.Length > MaximumWatchRoots;
        if (roots.Length > MaximumWatchRoots)
            SetDiagnostic(new("watcher-limit-exceeded",
                "Some installation roots are not watched; periodic reconciliation remains active.", null));
        IObservable<MonitoringEvent> watchers = Observable.Merge(
            roots.Take(MaximumWatchRoots).Select(WatchRoot));
        return Observable.Merge(
            Observable.Return(new MonitoringEvent(MonitoringEventKind.Initial)),
            periodic,
            watchers,
            _events.AsObservable());
    }

    private IObservable<MonitoringEvent> WatchRoot(string root) =>
        Observable.Defer(() => CreateWatcherEvents(root))
            .RetryWhen(errors => errors.SelectMany((exception, attempt) =>
            {
                WatcherFailed(root, exception);
                return Observable.Timer(RetryDelay(attempt + 1), scheduler).Select(_ => Unit.Default);
            }));

    private IObservable<MonitoringEvent> CreateWatcherEvents(string root) =>
        Observable.Create<MonitoringEvent>(observer =>
        {
            if (!Directory.Exists(root))
                throw new DirectoryNotFoundException("The configured installation root is unavailable.");

            FileSystemWatcher watcher = new(root, "ArtisanLogbook_Core.lua")
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite |
                    NotifyFilters.Size | NotifyFilters.CreationTime
            };
            IObservable<string> paths = Observable.Merge(
                Observable.FromEventPattern<FileSystemEventHandler, FileSystemEventArgs>(
                        handler => watcher.Created += handler, handler => watcher.Created -= handler)
                    .Select(change => change.EventArgs.FullPath),
                Observable.FromEventPattern<FileSystemEventHandler, FileSystemEventArgs>(
                        handler => watcher.Changed += handler, handler => watcher.Changed -= handler)
                    .Select(change => change.EventArgs.FullPath),
                Observable.FromEventPattern<FileSystemEventHandler, FileSystemEventArgs>(
                        handler => watcher.Deleted += handler, handler => watcher.Deleted -= handler)
                    .Select(change => change.EventArgs.FullPath),
                Observable.FromEventPattern<RenamedEventHandler, RenamedEventArgs>(
                        handler => watcher.Renamed += handler, handler => watcher.Renamed -= handler)
                    .SelectMany(change => new[] { change.EventArgs.FullPath, change.EventArgs.OldFullPath }))
                .Where(path => string.Equals(Path.GetFileName(path), "ArtisanLogbook_Core.lua",
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal));
            IObservable<MonitoringEvent> changed = paths.Select(path => new MonitoringEvent(
                MonitoringEventKind.FileSystem, SourceCatalog.IdFor(Path.GetFullPath(path))));

            IObservable<MonitoringEvent> errors = Observable
                .FromEventPattern<ErrorEventHandler, ErrorEventArgs>(
                    handler => watcher.Error += handler, handler => watcher.Error -= handler)
                .SelectMany(_ => Observable.Throw<MonitoringEvent>(
                    new IOException("The filesystem watcher reported an error.")));

            IObservable<MonitoringEvent> source = Observable.Merge(changed, errors)
                .GroupByUntil(
                    change => change.SourceId!,
                    change => change,
                    group => group.Throttle(GroupInactivityPeriod, scheduler))
                .SelectMany(group => group.Throttle(FilesystemDebounce, scheduler));
            IDisposable subscription = source.Subscribe(observer);
            watcher.EnableRaisingEvents = true;
            WatcherRecovered(root);
            observer.OnNext(new(MonitoringEventKind.WatcherRecovered));

            return Disposable.Create(() =>
            {
                subscription.Dispose();
                watcher.Dispose();
                WatcherStopped(root);
            });
        });

    private void HandleEvent(MonitoringEvent signal)
    {
        if (signal.Kind == MonitoringEventKind.StabilizationElapsed)
        {
            lock (_gate) _stabilizationScheduled = false;
        }
        Signal(signal);
    }

    private bool Signal(MonitoringEvent signal)
    {
        _retryTimer.Disposable = Disposable.Empty;
        bool notify;
        lock (_gate)
        {
            if (_stopping) return false;
            _pending = true;
            notify = !_scheduled;
            if (notify)
            {
                _scheduled = true;
                if (_idle.Task.IsCompleted)
                    _idle = new(TaskCreationOptions.RunContinuationsAsynchronously);
            }
        }
        if (notify)
            _reconciliationRequests.OnNext(Unit.Default);
        return notify;
    }

    private IObservable<Unit> RunQueuedPass()
    {
        lock (_gate)
        {
            _pending = false;
            _inProgress = true;
            _lastAttempt = scheduler.Now;
            if (_effectiveSettings.Enabled && _state == SourceMonitoringState.Disabled)
                _state = SourceMonitoringState.Unavailable;
        }

        return Observable.FromAsync(RunPassAsync)
            .Catch<Unit, Exception>(exception =>
            {
                if (_stop.IsCancellationRequested)
                    return Observable.Empty<Unit>();
                logger.LogError(exception, "SavedVariables reconciliation failed; it will be retried.");
                SetDiagnostic(new("reconciliation-failed",
                    "Source reconciliation failed; monitoring will retry automatically.", null));
                SetStateWhenEnabled(SourceMonitoringState.Degraded);
                ScheduleRetry();
                return Observable.Return(Unit.Default);
            })
            .Finally(FinishPass);
    }

    private async Task<Unit> RunPassAsync(CancellationToken cancellationToken)
    {
        using CancellationTokenSource linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _stop.Token);
        CancellationToken token = linked.Token;
        DateTimeOffset now = scheduler.Now;
        bool enabled;
        MonitoringSettings effectiveSettings;
        lock (_gate)
        {
            enabled = _effectiveSettings.Enabled && !_applicationStopping;
            effectiveSettings = _effectiveSettings;
        }

        Dictionary<string, MonitoringCheckpoint> working;
        KeyValuePair<string, PendingImport>[] completed;
        bool completionOverflow;
        long completionVersion;
        lock (_completionGate)
        {
            completed = _pendingImports.ToArray();
            completionOverflow = _completionOverflow;
            completionVersion = _completionVersion;
            lock (_gate) working = new(_checkpoints, StringComparer.Ordinal);
        }
        foreach (KeyValuePair<string, PendingImport> completion in completed)
        {
            MonitoringCheckpoint current = GetCheckpoint(working, completion.Key);
            working[completion.Key] = current with
            {
                IngestedFingerprint = completion.Value.Fingerprint ?? current.IngestedFingerprint,
                ReconciliationPending = completion.Value.Fingerprint is null ||
                    !string.Equals(current.ObservedFingerprint, completion.Value.Fingerprint, StringComparison.Ordinal),
                RetryAfter = completion.Value.RetryAfter
            };
        }

        List<SourceMonitoringDiagnostic> diagnostics = [];
        if (completionOverflow)
            diagnostics.Add(new("checkpoint-update-overflow",
                "Some completion notifications exceeded the in-memory limit; current files are being reconciled safely.", null));
        bool failed = false;
        bool needsStabilization = false;
        if (enabled)
        {
            SourceCatalogSnapshot snapshot = catalog.Discover();
            diagnostics.AddRange(snapshot.Diagnostics.Select(diagnostic =>
                new SourceMonitoringDiagnostic(diagnostic.Code, diagnostic.Message, null)));
            failed = snapshot.Diagnostics.Any(diagnostic => diagnostic.Severity == DiscoverySeverity.Error);
            lock (_gate) _discoveredSources = snapshot.Sources.Count;

            HashSet<string> currentIds = snapshot.Sources.Select(source => source.Id).ToHashSet(StringComparer.Ordinal);
            foreach (MonitoringCheckpoint missing in working.Values.Where(item => !currentIds.Contains(item.SourceId)).ToArray())
            {
                working[missing.SourceId] = missing with
                {
                    Available = false,
                    ReconciliationPending = snapshot.Diagnostics.Any(diagnostic => diagnostic.Severity == DiscoverySeverity.Error),
                    RetryAfter = null
                };
            }

            foreach (DiscoveredSource source in snapshot.Sources)
            {
                token.ThrowIfCancellationRequested();
                MonitoringCheckpoint checkpoint = GetCheckpoint(working, source.Id);
                try
                {
                    SavedVariablesFileSnapshot file = await SavedVariablesSnapshotReader.ReadAsync(source.Path, token)
                        .ConfigureAwait(false);
                    if (!string.Equals(checkpoint.ObservedFingerprint, file.Fingerprint, StringComparison.Ordinal) ||
                        checkpoint.ObservedAt is null)
                    {
                        working[source.Id] = checkpoint with
                        {
                            ObservedFingerprint = file.Fingerprint,
                            ObservedAt = now,
                            Available = true,
                            ReconciliationPending = !string.Equals(
                                checkpoint.IngestedFingerprint, file.Fingerprint, StringComparison.Ordinal),
                            RetryAfter = null
                        };
                        if (!string.Equals(checkpoint.IngestedFingerprint, file.Fingerprint, StringComparison.Ordinal))
                            needsStabilization = true;
                        continue;
                    }

                    checkpoint = checkpoint with { Available = true };
                    if (now - checkpoint.ObservedAt.Value < StableQuietPeriod)
                    {
                        working[source.Id] = checkpoint with { ReconciliationPending = true };
                        needsStabilization = true;
                        continue;
                    }
                    if (string.Equals(checkpoint.IngestedFingerprint, file.Fingerprint, StringComparison.Ordinal))
                    {
                        working[source.Id] = checkpoint with { ReconciliationPending = false, RetryAfter = null };
                        continue;
                    }
                    if (checkpoint.RetryAfter is DateTimeOffset retryAfter && retryAfter > now)
                    {
                        working[source.Id] = checkpoint with { ReconciliationPending = true };
                        failed = true;
                        ScheduleRetry(retryAfter - now);
                        ScheduleRetry(retryAfter - now);
                        continue;
                    }

                    ImportSubmission submission = imports.SubmitAutomatic(source.Id);
                    if (submission.Rejection is null)
                    {
                        working[source.Id] = checkpoint with
                        {
                            ReconciliationPending = true,
                            RetryAfter = null
                        };
                    }
                    else
                    {
                        working[source.Id] = checkpoint with
                        {
                            ReconciliationPending = true,
                            RetryAfter = submission.Rejection is ImportRejection.Stopping or ImportRejection.MonitoringDisabled
                                ? null : now + InitialRetryDelay
                        };
                        if (submission.Rejection is not (ImportRejection.Stopping or ImportRejection.MonitoringDisabled))
                        {
                            failed = true;
                            diagnostics.Add(new("import-not-scheduled",
                                "The source remains pending because import capacity is temporarily unavailable.", source.Id));
                            ScheduleRetry();
                        }
                    }
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                    SecurityException or ArgumentException or NotSupportedException)
                {
                    working[source.Id] = checkpoint with
                    {
                        Available = false,
                        ReconciliationPending = true,
                        RetryAfter = now + InitialRetryDelay
                    };
                    diagnostics.Add(new("source-unavailable",
                        exception is SavedVariablesSnapshotTooLargeException
                            ? "The SavedVariables file exceeds the supported snapshot size."
                            : "The SavedVariables file is temporarily unavailable or changing; it will be checked again.",
                        source.Id));
                    logger.LogDebug("SavedVariables source {SourceId} could not be inspected ({FailureType}).",
                        source.Id, exception.GetType().Name);
                    failed = true;
                    ScheduleRetry();
                }
            }

            bool incompleteDiscovery = snapshot.Diagnostics.Any(diagnostic => diagnostic.Severity == DiscoverySeverity.Error);
            if (incompleteDiscovery)
                failed = true;
            if (WatcherUnavailable)
            {
                diagnostics.Add(new("watcher-unavailable",
                    "Filesystem notifications are unavailable; periodic reconciliation remains active.", null));
                failed = true;
            }
            if (WatcherLimitExceeded)
            {
                diagnostics.Add(new("watcher-limit-exceeded",
                    "Some installation roots are not watched; periodic reconciliation remains active.", null));
                failed = true;
            }

            if (needsStabilization)
                ScheduleStabilization();
            else
                CancelStabilization();
        }

        try
        {
            PersistIfChanged(working, completed, token);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            diagnostics.Add(new("checkpoint-save-failed",
                "Monitoring state could not be saved; completed import checkpoints will be retried.", null));
            logger.LogWarning("SavedVariables monitoring checkpoints could not be saved ({FailureType}).",
                exception.GetType().Name);
            failed = true;
            ScheduleRetry();
        }

        if (enabled)
        {
            SetDiagnostics(diagnostics);
            if (!failed)
            {
                lock (_gate) _lastSuccess = now;
                ResetRetry();
                lock (_completionGate)
                    if (_completionVersion == completionVersion)
                        _completionOverflow = false;
            }
            SetStateWhenEnabled(failed ? SourceMonitoringState.Degraded : SourceMonitoringState.Active);
        }
        else
        {
            SetDiagnostics(diagnostics);
            SetStateWhenDisabled();
        }
        return Unit.Default;
    }

    private void PersistIfChanged(
        Dictionary<string, MonitoringCheckpoint> working,
        IReadOnlyList<KeyValuePair<string, PendingImport>> completed,
        CancellationToken cancellationToken)
    {
        lock (_completionGate)
        {
            bool changed;
            lock (_gate) changed = !CheckpointsEqual(_checkpoints, working);
            if (changed)
                checkpointStore.Save(working.Values, cancellationToken);

            lock (_gate)
            {
                _checkpoints.Clear();
                foreach (KeyValuePair<string, MonitoringCheckpoint> item in working)
                    _checkpoints[item.Key] = item.Value;
                foreach (KeyValuePair<string, PendingImport> completion in completed)
                {
                    if (_pendingImports.TryGetValue(completion.Key, out PendingImport? latest) &&
                        latest.Version == completion.Value.Version)
                        _pendingImports.Remove(completion.Key);
                }
            }
        }
    }

    private void ImportCompleted(ImportOperationSnapshot operation)
    {
        DateTimeOffset now = scheduler.Now;
        lock (_completionGate)
        {
            foreach (ImportSourceSnapshot source in operation.Sources)
            {
                if (source.Status == ImportOperationStatus.Completed &&
                    source.Outcome == CompanionImportOutcome.Successful &&
                    source.SourceFingerprint is { } fingerprint)
                {
                    RetainCompletion(source.SourceId, new(fingerprint, null, ++_completionVersion));
                }
                else if (source.Status is ImportOperationStatus.Failed or ImportOperationStatus.Cancelled)
                {
                    _retryAttempt = Math.Min(_retryAttempt + 1, 6);
                    int attempt = _retryAttempt;
                    RetainCompletion(source.SourceId, new(null,
                        lifetime.ApplicationStopping.IsCancellationRequested ? null : now + RetryDelay(attempt),
                        ++_completionVersion));
                }
            }
        }
        Signal(new(MonitoringEventKind.ImportCompleted));
    }

    private void RetainCompletion(string sourceId, PendingImport completion)
    {
        if (_pendingImports.ContainsKey(sourceId) || _pendingImports.Count < MaximumPendingCompletionSources)
            _pendingImports[sourceId] = completion;
        else
            _completionOverflow = true;
    }

    private void ScheduleStabilization()
    {
        lock (_gate)
        {
            if (_stabilizationScheduled || !_effectiveSettings.Enabled || _stopping)
                return;
            _stabilizationScheduled = true;
        }
        _stabilityTimer.Disposable = Observable.Timer(StableQuietPeriod, scheduler)
            .Subscribe(_ => _events.OnNext(new(MonitoringEventKind.StabilizationElapsed)));
    }

    private void CancelStabilization()
    {
        lock (_gate) _stabilizationScheduled = false;
        _stabilityTimer.Disposable = Disposable.Empty;
    }

    private void ScheduleRetry(TimeSpan? delay = null)
    {
        int attempt;
        lock (_gate)
        {
            if (_stopping) return;
            _retryAttempt = Math.Min(_retryAttempt + 1, 6);
            attempt = _retryAttempt;
        }
        _retryTimer.Disposable = Observable.Timer(delay ?? RetryDelay(attempt), scheduler)
            .Subscribe(_ => _events.OnNext(new(MonitoringEventKind.WorkerRetry)));
    }

    private static TimeSpan RetryDelay(int attempt)
    {
        int exponent = Math.Clamp(attempt, 1, 6) - 1;
        return TimeSpan.FromMilliseconds(Math.Min(
            MaximumRetryDelay.TotalMilliseconds,
            InitialRetryDelay.TotalMilliseconds * (1 << exponent)));
    }

    private void ResetRetry()
    {
        lock (_gate) _retryAttempt = 0;
        _retryTimer.Disposable = Disposable.Empty;
    }

    private void WatcherFailed(string root, Exception exception)
    {
        lock (_gate)
        {
            _failedWatchRoots.Add(root);
            _activeWatchRoots.Remove(root);
            SetDiagnosticUnderLock(new("watcher-unavailable",
                "Filesystem notifications are unavailable; periodic reconciliation remains active.", null));
            if (_effectiveSettings.Enabled && !_applicationStopping)
                _state = SourceMonitoringState.Degraded;
        }
        logger.LogWarning("SavedVariables filesystem watcher failed ({FailureType}); retrying with bounded backoff.",
            exception.GetType().Name);
    }

    private void WatcherRecovered(string root)
    {
        lock (_gate)
        {
            _failedWatchRoots.Remove(root);
            _activeWatchRoots.Add(root);
            if (_failedWatchRoots.Count == 0)
                _diagnostics = _diagnostics.Where(item => item.Code != "watcher-unavailable").ToArray();
        }
    }

    private void WatcherStopped(string root)
    {
        lock (_gate) _activeWatchRoots.Remove(root);
    }

    private bool WatcherUnavailable
    {
        get { lock (_gate) return _failedWatchRoots.Count > 0; }
    }

    private bool WatcherLimitExceeded
    {
        get { lock (_gate) return _watcherLimitExceeded; }
    }

    private void EventStreamFailed(Exception exception)
    {
        if (_stop.IsCancellationRequested) return;
        logger.LogError(exception, "SavedVariables monitoring event stream failed.");
        SetDiagnostic(new("event-stream-failed",
            "Monitoring events could not be observed; reconciliation will retry.", null));
        SetStateWhenEnabled(SourceMonitoringState.Degraded);
    }

    private void WorkerFailed(Exception exception)
    {
        if (_stop.IsCancellationRequested) return;
        logger.LogError(exception, "SavedVariables monitoring worker stopped unexpectedly.");
        SetDiagnostic(new("worker-failed",
            "The monitoring worker stopped unexpectedly; it will be restarted.", null));
        SetStateWhenEnabled(SourceMonitoringState.Degraded);
        _workerRestartTimer.Disposable = Observable.Timer(RetryDelay(1), scheduler)
            .Subscribe(_ =>
            {
                lock (_gate)
                {
                    _pending = false;
                    _scheduled = false;
                    _inProgress = false;
                }
                StartWorker();
                Signal(new(MonitoringEventKind.WorkerRetry));
            });
    }

    private void SetDiagnostic(SourceMonitoringDiagnostic diagnostic)
    {
        lock (_gate) SetDiagnosticUnderLock(diagnostic);
    }

    private void SetDiagnosticUnderLock(SourceMonitoringDiagnostic diagnostic)
    {
        _diagnostics = _diagnostics
            .Where(item => item.Code != diagnostic.Code || item.SourceId != diagnostic.SourceId)
            .Append(diagnostic)
            .TakeLast(50)
            .ToArray();
    }

    private void SetDiagnostics(IEnumerable<SourceMonitoringDiagnostic> diagnostics)
    {
        lock (_gate) _diagnostics = diagnostics.TakeLast(50).ToArray();
    }

    private void SetStateWhenEnabled(SourceMonitoringState state)
    {
        lock (_gate)
            _state = _effectiveSettings.Enabled && !_applicationStopping ? state :
                _applicationStopping ? SourceMonitoringState.Unavailable : SourceMonitoringState.Disabled;
    }

    private void SetStateWhenDisabled()
    {
        lock (_gate)
            if (!_effectiveSettings.Enabled || _applicationStopping)
                _state = _applicationStopping ? SourceMonitoringState.Unavailable : SourceMonitoringState.Disabled;
    }

    private void BeginApplicationStopping()
    {
        lock (_gate) _applicationStopping = true;
        imports.SetAutomaticEnabled(false);
        CancelStabilization();
        _retryTimer.Disposable = Disposable.Empty;
        _preferences.OnNext(_effectiveSettings with { Enabled = false });
    }

    private async Task StopAndDrainAsync(CancellationToken cancellationToken)
    {
        lock (_gate)
            if (_stopping) return;
        lock (_gate) _applicationStopping = true;
        imports.SetAutomaticEnabled(false);
        CancelStabilization();
        _retryTimer.Disposable = Disposable.Empty;
        _preferences.OnNext(_effectiveSettings with { Enabled = false });
        Signal(new(MonitoringEventKind.ConfigurationChanged));
        using CancellationTokenRegistration deadline = cancellationToken.Register(_stop.Cancel);
        Task idle;
        lock (_gate) idle = _idle.Task;
        try
        {
            await idle.ConfigureAwait(false);
        }
        finally
        {
            lock (_gate) _stopping = true;
            _stop.Cancel();
            _eventSubscription.Dispose();
            _workerSubscription.Dispose();
            _workerRestartTimer.Dispose();
            _startedRegistration.Dispose();
            _stoppingRegistration.Dispose();
            imports.OperationCompleted -= ImportCompleted;
            _retryTimer.Dispose();
            _stabilityTimer.Dispose();
            _preferences.Dispose();
            _events.Dispose();
            _reconciliationRequests.Dispose();
        }
    }

    private void FinishPass()
    {
        bool again;
        bool hasPendingCompletions;
        lock (_completionGate) hasPendingCompletions = _pendingImports.Count > 0;
        lock (_gate)
        {
            _inProgress = false;
            again = _pending && !_stopping;
            if (!again)
            {
                _scheduled = false;
                if (!hasPendingCompletions)
                    _idle.TrySetResult();
            }
        }
        if (again)
            _reconciliationRequests.OnNext(Unit.Default);
    }

    private static MonitoringCheckpoint GetCheckpoint(
        IReadOnlyDictionary<string, MonitoringCheckpoint> checkpoints, string sourceId) =>
        checkpoints.TryGetValue(sourceId, out MonitoringCheckpoint? checkpoint)
            ? checkpoint
            : new(sourceId, null, null, null, null, false, false);

    private static bool CheckpointsEqual(
        IReadOnlyDictionary<string, MonitoringCheckpoint> first,
        IReadOnlyDictionary<string, MonitoringCheckpoint> second) =>
        first.Count == second.Count && first.All(pair =>
            second.TryGetValue(pair.Key, out MonitoringCheckpoint? value) && value == pair.Value);

    private void CancelTimers()
    {
        CancelStabilization();
        _retryTimer.Disposable = Disposable.Empty;
    }

    private static TaskCompletionSource Completed()
    {
        TaskCompletionSource result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        result.SetResult();
        return result;
    }

    public void Dispose()
    {
        if (!_stop.IsCancellationRequested)
            _stop.Cancel();
        _eventSubscription.Dispose();
        _workerSubscription.Dispose();
        _workerRestartTimer.Dispose();
        _retryTimer.Dispose();
        _stabilityTimer.Dispose();
        _preferences.Dispose();
        _events.Dispose();
        _reconciliationRequests.Dispose();
        imports.OperationCompleted -= ImportCompleted;
        _startedRegistration.Dispose();
        _stoppingRegistration.Dispose();
        _stop.Dispose();
    }

    private sealed record PendingImport(string? Fingerprint, DateTimeOffset? RetryAfter, long Version);
}
