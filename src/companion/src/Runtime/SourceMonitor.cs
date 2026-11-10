using System.Security;
using System.Security.Cryptography;
using System.Threading.Channels;

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

/// <summary>Coordinates discovery, stable snapshot checks, watcher hints and C11's shared import worker.</summary>
public sealed class SourceMonitor(
    CompanionRuntimeConfiguration configuration,
    CompanionSettingsStore settingsStore,
    IMonitoringCheckpointPersistence checkpointStore,
    SourceCatalog catalog,
    InstallationDiscovery discovery,
    ImportOperations imports,
    IHostApplicationLifetime lifetime,
    TimeProvider timeProvider,
    ILogger<SourceMonitor> logger) : IHostedService, IDisposable
{
    private static readonly TimeSpan StableQuietPeriod = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan InitialWorkerRetryDelay = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan MaximumWorkerRetryDelay = TimeSpan.FromSeconds(30);
    private const long MaximumSnapshotBytes = 64L * 1024 * 1024;
    private const int MaximumWatchDirectories = 128;
    private const int MaximumPendingCompletionSources = 4096;
    private readonly object _statusGate = new();
    private readonly object _preferenceGate = new();
    private readonly object _watcherGate = new();
    private readonly object _completedImportsGate = new();
    private readonly Channel<byte> _signals = Channel.CreateBounded<byte>(new BoundedChannelOptions(1)
    {
        FullMode = BoundedChannelFullMode.Wait,
        SingleReader = true,
        SingleWriter = false
    });
    private readonly Dictionary<string, PendingImportCheckpoint> _completedImports = new(StringComparer.Ordinal);
    private readonly Dictionary<string, MonitoringCheckpoint> _checkpoints = new(StringComparer.Ordinal);
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly SemaphoreSlim _passGate = new(1, 1);
    private readonly CancellationTokenSource _stop = new();
    private long _completionVersion;
    private bool _completionOverflow;
    private TimeSpan _checkpointRetryDelay = InitialWorkerRetryDelay;
    private DateTimeOffset? _checkpointRetryAfter;
    private int _workerFailureCount;
    private CompanionRuntimeConfiguration _configuration = configuration;
    private MonitoringSettings _effectiveSettings = configuration.EffectiveSettings.Monitoring;
    private SourceMonitoringState _state = configuration.EffectiveSettings.Monitoring.Enabled
        ? SourceMonitoringState.Unavailable : SourceMonitoringState.Disabled;
    private SourceMonitoringDiagnostic[] _diagnostics = [];
    private DateTimeOffset? _lastAttempt;
    private DateTimeOffset? _lastSuccess;
    private int _discoveredSources;
    private bool _inProgress;
    private volatile bool _started;
    private volatile bool _stopping;
    private volatile bool _watcherFailed;
    private int _stopRequested;
    private int _disposed;
    private Task _worker = Task.CompletedTask;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            foreach (MonitoringCheckpoint checkpoint in checkpointStore.Load())
                _checkpoints[checkpoint.SourceId] = checkpoint;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException
            or InvalidDataException or System.Text.Json.JsonException)
        {
            logger.LogWarning("SavedVariables monitoring checkpoints could not be loaded; safe re-imports may occur.");
            SetDiagnostics([new("checkpoint-load-failed",
                "Monitoring checkpoints could not be loaded; current files will be safely reconciled again.", null)]);
        }

        imports.OperationCompleted += ImportCompleted;
        _started = true;
        imports.SetAutomaticEnabled(_effectiveSettings.Enabled);
        _worker = Task.Run(() => RunAsync(_stop.Token), CancellationToken.None);
        if (_effectiveSettings.Enabled)
            Signal();
        else
            SetState(SourceMonitoringState.Disabled);
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (Volatile.Read(ref _disposed) != 0)
            return;
        lock (_preferenceGate)
        {
            _stopping = true;
            imports.SetAutomaticEnabled(false);
        }
        DisposeWatchers();
        RequestStop();
        await _worker.ConfigureAwait(false);
        imports.OperationCompleted -= ImportCompleted;
    }

    public SourceMonitoringSnapshot GetSnapshot()
    {
        int watchedDirectories = WatcherCount;
        lock (_statusGate)
            return new(_effectiveSettings.Enabled, _effectiveSettings.ReconciliationIntervalSeconds, _state,
                _discoveredSources, watchedDirectories, _lastAttempt, _lastSuccess, _inProgress, _diagnostics.ToArray());
    }

    public SourceMonitoringSnapshot UpdatePreferences(MonitoringSettings preferences, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        lock (_preferenceGate)
        {
            if (_stopping || lifetime.ApplicationStopping.IsCancellationRequested)
                throw new CompanionSettingsException("The Companion is stopping and cannot update monitoring preferences.");
            CompanionRuntimeConfiguration currentConfiguration;
            lock (_statusGate) currentConfiguration = _configuration;
            CompanionSettingsStore.Validate(currentConfiguration.EffectiveSettings with { Monitoring = preferences });

            SettingsLoadResult loaded = settingsStore.Load();
            if (!loaded.CanSave)
                throw new CompanionSettingsException(loaded.Diagnostic ?? "The monitoring preferences cannot be saved.");
            CompanionSettings saved = (loaded.Settings ??
                CompanionSettings.ForRoots(currentConfiguration.EffectiveSettings.InstallationRoots.ToArray())) with
            {
                Monitoring = preferences
            };
            settingsStore.Save(saved, cancellationToken, loaded);

            bool enabled;
            lock (_statusGate)
            {
                _configuration = _configuration.WithPersistedPreferences(saved);
                _effectiveSettings = _configuration.EffectiveSettings.Monitoring;
                enabled = _effectiveSettings.Enabled;
                _state = enabled ? SourceMonitoringState.Unavailable : SourceMonitoringState.Disabled;
            }
            imports.SetAutomaticEnabled(enabled);
            if (!enabled)
                DisposeWatchers();
            Signal();
            return GetSnapshot();
        }
    }

    private void RecordWorkerFailure(SourceMonitoringDiagnostic diagnostic)
    {
        lock (_statusGate)
        {
            _diagnostics = [diagnostic];
            _state = _effectiveSettings.Enabled
                ? SourceMonitoringState.Unavailable
                : SourceMonitoringState.Disabled;
        }
    }

    private void ClearDiagnostic(string code)
    {
        lock (_statusGate)
            _diagnostics = _diagnostics.Where(diagnostic => diagnostic.Code != code).ToArray();
    }

    public ReconciliationRequestStatus RequestReconciliation()
    {
        lock (_statusGate)
        {
            if (_stopping || !_started || lifetime.ApplicationStopping.IsCancellationRequested)
                return ReconciliationRequestStatus.Unavailable;
            if (!_effectiveSettings.Enabled)
                return ReconciliationRequestStatus.Disabled;
        }
        return Signal() ? ReconciliationRequestStatus.Accepted : ReconciliationRequestStatus.Coalesced;
    }

    internal async Task ReconcileOnceAsync(bool forceStable = false, CancellationToken cancellationToken = default)
    {
        await _passGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await ReconcilePassAsync(forceStable, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _passGate.Release();
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    if (!GetSnapshot().Enabled)
                    {
                        DisposeWatchers();
                        SetStateWhenDisabled(SourceMonitoringState.Disabled);
                        await ProcessCompletedImportsAsync(cancellationToken).ConfigureAwait(false);
                        await WaitForSignalAsync(NextCheckpointRetryDelay(), cancellationToken).ConfigureAwait(false);
                        continue;
                    }

                    DrainSignals();
                    await ReconcileOnceAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                    if (cancellationToken.IsCancellationRequested)
                        break;
                    await WaitForSignalAsync(NextReconciliationDelay(), cancellationToken).ConfigureAwait(false);
                    _workerFailureCount = 0;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception exception)
                {
                    TimeSpan retryDelay = NextWorkerRetryDelay();
                    DisposeWatchers();
                    logger.LogError("SavedVariables monitoring worker failed ({FailureType}); retrying in {RetrySeconds} seconds.",
                        exception.GetType().Name, retryDelay.TotalSeconds);
                    RecordWorkerFailure(new("monitor-worker-retrying",
                        $"Monitoring encountered an unexpected failure and will retry in {retryDelay.TotalSeconds:0} seconds.",
                        null));
                    await Task.Delay(retryDelay, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            DisposeWatchers();
        }
    }

    private async Task WaitForSignalAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        using CancellationTokenSource waitCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<bool> signal = _signals.Reader.WaitToReadAsync(waitCancellation.Token).AsTask();
        if (delay == Timeout.InfiniteTimeSpan)
        {
            if (await signal.ConfigureAwait(false))
                DrainSignals();
            return;
        }

        Task timer = Task.Delay(delay, timeProvider, waitCancellation.Token);
        Task completed = await Task.WhenAny(signal, timer).ConfigureAwait(false);
        if (completed == signal && await signal.ConfigureAwait(false))
            DrainSignals();
        else
            waitCancellation.Cancel();
    }

    private void DrainSignals()
    {
        while (_signals.Reader.TryRead(out _)) { }
    }

    private TimeSpan NextReconciliationDelay()
    {
        DateTimeOffset now = timeProvider.GetUtcNow();
        TimeSpan interval = TimeSpan.FromSeconds(GetSnapshot().ReconciliationIntervalSeconds);
        TimeSpan delay = interval;
        foreach (MonitoringCheckpoint checkpoint in _checkpoints.Values.Where(state => state.ReconciliationPending))
        {
            DateTimeOffset due = checkpoint.RetryAfter ??
                (checkpoint.ObservedAt is { } observed ? observed + StableQuietPeriod : now);
            TimeSpan untilDue = due - now;
            if (untilDue < delay)
                delay = untilDue;
        }
        TimeSpan checkpointDelay = NextCheckpointRetryDelay();
        if (checkpointDelay != Timeout.InfiniteTimeSpan && checkpointDelay < delay)
            delay = checkpointDelay;
        return delay <= TimeSpan.Zero ? TimeSpan.FromMilliseconds(100) : delay;
    }

    private TimeSpan NextCheckpointRetryDelay()
    {
        lock (_completedImportsGate)
        {
            if (_completedImports.Count == 0)
                return Timeout.InfiniteTimeSpan;
            if (_checkpointRetryAfter is not { } retryAfter)
                return TimeSpan.Zero;
            TimeSpan delay = retryAfter - timeProvider.GetUtcNow();
            return delay > TimeSpan.Zero ? delay : TimeSpan.Zero;
        }
    }

    private TimeSpan NextWorkerRetryDelay() =>
        TimeSpan.FromSeconds(Math.Min(MaximumWorkerRetryDelay.TotalSeconds,
            InitialWorkerRetryDelay.TotalSeconds * Math.Pow(2, Math.Min(_workerFailureCount++, 5))));

    private async Task ReconcilePassAsync(bool forceStable, CancellationToken cancellationToken)
    {
        if (!GetSnapshot().Enabled)
            return;

        DateTimeOffset now = timeProvider.GetUtcNow();
        lock (_statusGate)
        {
            if (!_effectiveSettings.Enabled)
                return;
            _inProgress = true;
            _lastAttempt = now;
        }

        Dictionary<string, MonitoringCheckpoint> working = new(_checkpoints, StringComparer.Ordinal);
        List<SourceMonitoringDiagnostic> diagnostics = [];
        bool hasFailure = false;
        PendingImportCheckpoint[] completedImports = [];
        try
        {
            completedImports = CaptureCompletedImports();
            ApplyCompletedImports(completedImports, working, diagnostics);
            SourceCatalogSnapshot snapshot = catalog.Discover();
            lock (_statusGate) _discoveredSources = snapshot.Sources.Count;
            foreach (SourceCatalogDiagnostic diagnostic in snapshot.Diagnostics)
            {
                diagnostics.Add(new(diagnostic.Code, diagnostic.Message, null));
                hasFailure |= diagnostic.Severity == DiscoverySeverity.Error;
            }

            RebuildWatchers(snapshot.Sources, diagnostics);
            hasFailure |= diagnostics.Any(item => item.Code.StartsWith("watcher", StringComparison.Ordinal));
            HashSet<string> discoveredIds = snapshot.Sources.Select(source => source.Id).ToHashSet(StringComparer.Ordinal);
            bool missingSources = false;
            foreach (MonitoringCheckpoint known in working.Values.Where(item => !discoveredIds.Contains(item.SourceId)).ToArray())
            {
                working[known.SourceId] = known with { Available = false, ReconciliationPending = false, RetryAfter = null };
                diagnostics.Add(new("source-unavailable",
                    "A previously discovered source is no longer available; canonical history is retained.", known.SourceId));
                missingSources = true;
            }
            hasFailure |= missingSources;

            foreach (DiscoveredSource source in snapshot.Sources)
            {
                cancellationToken.ThrowIfCancellationRequested();
                MonitoringCheckpoint state = working.GetValueOrDefault(source.Id) ??
                    new(source.Id, null, null, null, null, false, false);
                try
                {
                    string fingerprint = await GetStableFingerprintAsync(source.Path, cancellationToken).ConfigureAwait(false);
                    bool changed = !StringComparer.Ordinal.Equals(state.ObservedFingerprint, fingerprint);
                    DateTimeOffset observedAt = changed ? now : state.ObservedAt ?? now;
                    bool pending = !StringComparer.Ordinal.Equals(state.IngestedFingerprint, fingerprint);
                    state = state with
                    {
                        ObservedFingerprint = fingerprint,
                        ObservedAt = observedAt,
                        Available = true,
                        ReconciliationPending = pending,
                        RetryAfter = changed ? null : state.RetryAfter
                    };
                    working[source.Id] = state;
                    if (!pending)
                        continue;

                    DateTimeOffset stableAt = observedAt + StableQuietPeriod;
                    if (!forceStable && now < stableAt || state.RetryAfter is { } retry && now < retry)
                        continue;

                    ImportSubmission? submission = SubmitAutomaticUnlessCompletionPending(source.Id);
                    if (submission is null)
                    {
                        diagnostics.Add(new("checkpoint-save-pending",
                            "A completed import checkpoint is pending persistence; automatic re-import is deferred.", source.Id));
                        hasFailure = true;
                        continue;
                    }
                    if (submission.Rejection is null)
                    {
                        diagnostics.Add(new("import-queued", "The source import is queued; completion is reported separately.", source.Id));
                    }
                    else
                    {
                        if (submission.Rejection is ImportRejection.SourceBusy or ImportRejection.CapacityExceeded)
                        {
                            state = state with
                            {
                                RetryAfter = now + TimeSpan.FromSeconds(GetSnapshot().ReconciliationIntervalSeconds)
                            };
                            working[source.Id] = state;
                        }
                        string code = submission.Rejection switch
                        {
                            ImportRejection.SourceBusy => "import-running",
                            ImportRejection.CapacityExceeded => "import-capacity-exhausted",
                            ImportRejection.MonitoringDisabled => "monitoring-disabled",
                            ImportRejection.Stopping => "application-stopping",
                            _ => "import-not-queued"
                        };
                        string message = submission.Rejection switch
                        {
                            ImportRejection.SourceBusy => "An import for this source is already queued or running; it will be checked again.",
                            ImportRejection.CapacityExceeded => "Import capacity is temporarily full; this source remains pending for retry.",
                            ImportRejection.MonitoringDisabled => "Monitoring was disabled before this source could be queued.",
                            ImportRejection.Stopping => "The Companion is stopping; this source remains pending for the next run.",
                            _ => "The source could not be queued and remains eligible for retry."
                        };
                        diagnostics.Add(new(code, message, source.Id));
                        hasFailure |= submission.Rejection is not
                            (ImportRejection.SourceBusy or ImportRejection.MonitoringDisabled);
                    }
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                    or SecurityException or ArgumentException or NotSupportedException)
                {
                    MonitoringCheckpoint unavailable = state with
                    {
                        Available = false,
                        ReconciliationPending = true,
                        RetryAfter = now + TimeSpan.FromSeconds(GetSnapshot().ReconciliationIntervalSeconds)
                    };
                    working[source.Id] = unavailable;
                    diagnostics.Add(new("source-unavailable",
                        "The SavedVariables file is temporarily unavailable or changing; it will be checked again.", source.Id));
                    hasFailure = true;
                    logger.LogDebug("SavedVariables source {SourceId} could not be inspected ({FailureType}).",
                        source.Id, exception.GetType().Name);
                }
            }

            bool allSourcesReconciled = !missingSources &&
                !snapshot.Diagnostics.Any(item => item.Severity == DiscoverySeverity.Error) &&
                snapshot.Sources.All(source =>
                working.TryGetValue(source.Id, out MonitoringCheckpoint? state) &&
                state.Available && !state.ReconciliationPending);

            if (_watcherFailed)
            {
                diagnostics.Add(new("watcher-unavailable",
                    "Filesystem notifications are unavailable; periodic reconciliation remains active.", null));
                hasFailure = true;
            }

            bool checkpointsPersisted = false;
            try
            {
                if (IsCheckpointRetryDeferred())
                {
                    diagnostics.Add(new("checkpoint-save-pending",
                        "Completed import checkpoints are retained until their persistence retry is due.", null));
                    hasFailure = true;
                }
                else
                {
                    if (!CheckpointsEqual(_checkpoints, working))
                        checkpointStore.Save(working.Values, cancellationToken);
                    ReplaceCheckpoints(working);
                    checkpointsPersisted = true;
                    CompleteCompletedImports(completedImports);
                    if (allSourcesReconciled)
                        lock (_statusGate) _lastSuccess = now;
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                or SecurityException or ArgumentException)
            {
                diagnostics.Add(new("checkpoint-save-failed",
                    "Monitoring state could not be saved; completed import checkpoints will be retried automatically.", null));
                hasFailure = true;
                logger.LogWarning("SavedVariables monitoring checkpoints could not be saved ({FailureType}).",
                    exception.GetType().Name);
                ScheduleCheckpointRetry();
            }

            if (IsCompletionOverflowed())
                diagnostics.Add(new("checkpoint-update-overflow",
                    "Checkpoint updates exceeded the in-memory limit; current files are being reconciled to recover safely.", null));
            else if (HasPendingCompletedImports() &&
                !diagnostics.Any(diagnostic => diagnostic.Code == "checkpoint-save-failed"))
                diagnostics.Add(new("checkpoint-save-pending",
                    "Completed import checkpoints are retained and awaiting a persistence retry.", null));

            SetDiagnostics(diagnostics);
            if (checkpointsPersisted && !HasPendingCompletedImports())
            {
                ResetCheckpointRetry();
                ClearCompletionOverflow();
            }
            SetStateWhenEnabled(hasFailure ? SourceMonitoringState.Degraded : SourceMonitoringState.Active);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            logger.LogError("SavedVariables reconciliation failed ({FailureType}); it will be retried.",
                exception.GetType().Name);
            SetDiagnostics([new("reconciliation-failed",
                "Source reconciliation failed; monitoring will retry on the next trigger or interval.", null)]);
            SetStateWhenEnabled(SourceMonitoringState.Degraded);
        }
        finally
        {
            lock (_statusGate) _inProgress = false;
        }
    }

    private Task ProcessCompletedImportsAsync(CancellationToken cancellationToken)
    {
        Dictionary<string, MonitoringCheckpoint> working = new(_checkpoints, StringComparer.Ordinal);
        List<SourceMonitoringDiagnostic> diagnostics = [];
        PendingImportCheckpoint[] completedImports = CaptureCompletedImports();
        ApplyCompletedImports(completedImports, working, diagnostics);
        bool unchanged = CheckpointsEqual(_checkpoints, working);
        if (completedImports.Length > 0 && !unchanged && !IsCheckpointRetryDeferred())
        {
            try
            {
                checkpointStore.Save(working.Values, cancellationToken);
                ReplaceCheckpoints(working);
                CompleteCompletedImports(completedImports);
                ClearDiagnostic("checkpoint-save-failed");
                if (!HasPendingCompletedImports())
                    ResetCheckpointRetry();
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                or SecurityException or ArgumentException)
            {
                logger.LogWarning("SavedVariables monitoring checkpoints could not be saved ({FailureType}).",
                    exception.GetType().Name);
                SetDiagnostics([new("checkpoint-save-failed",
                    "Monitoring state could not be saved; completed import checkpoints will be retried automatically.", null)]);
                ScheduleCheckpointRetry();
            }
        }
        else if (completedImports.Length > 0)
        {
            if (unchanged)
            {
                CompleteCompletedImports(completedImports);
                ClearDiagnostic("checkpoint-save-failed");
                if (!HasPendingCompletedImports())
                    ResetCheckpointRetry();
            }
        }
        return Task.CompletedTask;
    }

    private void ApplyCompletedImports(
        IReadOnlyList<PendingImportCheckpoint> completedImports,
        Dictionary<string, MonitoringCheckpoint> working,
        List<SourceMonitoringDiagnostic> diagnostics)
    {
        foreach (PendingImportCheckpoint completion in completedImports)
        {
            MonitoringCheckpoint state = working.GetValueOrDefault(completion.SourceId) ??
                new(completion.SourceId, null, null, null, null, false, true);
            if (completion.IngestedFingerprint is { } fingerprint)
            {
                bool pending = state.ObservedFingerprint is not null &&
                    !StringComparer.Ordinal.Equals(state.ObservedFingerprint, fingerprint);
                DateTimeOffset? retry = completion.FailedAfterLatestSuccess
                    ? timeProvider.GetUtcNow() + TimeSpan.FromSeconds(GetSnapshot().ReconciliationIntervalSeconds)
                    : null;
                working[completion.SourceId] = state with
                {
                    IngestedFingerprint = fingerprint,
                    ReconciliationPending = pending || completion.FailedAfterLatestSuccess,
                    RetryAfter = retry
                };
            }
            else if (completion.FailedAfterLatestSuccess)
            {
                DateTimeOffset retry = timeProvider.GetUtcNow() +
                    TimeSpan.FromSeconds(GetSnapshot().ReconciliationIntervalSeconds);
                working[completion.SourceId] = state with { ReconciliationPending = true, RetryAfter = retry };
            }
            if (completion.FailedAfterLatestSuccess)
                diagnostics.Add(new("import-failed",
                    "The last import did not complete successfully; the source remains eligible for retry.", completion.SourceId));
        }
    }

    internal void ImportCompleted(ImportOperationSnapshot operation)
    {
        bool overflowed = false;
        lock (_completedImportsGate)
        {
            foreach (ImportSourceSnapshot source in operation.Sources)
            {
                bool successful = source.Outcome == ImportService.CompanionImportOutcome.Successful &&
                    source.SourceFingerprint is not null;
                bool failed = source.Status is ImportOperationStatus.Failed or ImportOperationStatus.Cancelled;
                if (!successful && !failed)
                    continue;
                if (!_completedImports.TryGetValue(source.SourceId, out PendingImportCheckpoint? pending) &&
                    _completedImports.Count >= MaximumPendingCompletionSources)
                {
                    _completionOverflow = true;
                    overflowed = true;
                    continue;
                }

                _completedImports[source.SourceId] = new(
                    source.SourceId,
                    ++_completionVersion,
                    successful ? source.SourceFingerprint : pending?.IngestedFingerprint,
                    !successful && (failed || pending?.FailedAfterLatestSuccess == true));
            }
        }
        if (overflowed)
        {
            logger.LogWarning("SavedVariables completion checkpoints exceeded the in-memory limit; a source scan will recover safely.");
            SetDiagnostics([new("checkpoint-update-overflow",
                "Checkpoint updates exceeded the in-memory limit; current files will be reconciled to recover safely.", null)]);
        }
        Signal();
    }

    private PendingImportCheckpoint[] CaptureCompletedImports()
    {
        lock (_completedImportsGate)
            return _completedImports.Values.ToArray();
    }

    private ImportSubmission? SubmitAutomaticUnlessCompletionPending(string sourceId)
    {
        lock (_completedImportsGate)
        {
            if (_completedImports.ContainsKey(sourceId))
                return null;
            return imports.SubmitAutomatic(sourceId);
        }
    }

    private bool IsCheckpointRetryDeferred()
    {
        lock (_completedImportsGate)
            return _completedImports.Count > 0 &&
                _checkpointRetryAfter is { } retryAfter && timeProvider.GetUtcNow() < retryAfter;
    }

    private void CompleteCompletedImports(IEnumerable<PendingImportCheckpoint> completedImports)
    {
        lock (_completedImportsGate)
        {
            foreach (PendingImportCheckpoint completion in completedImports)
            {
                if (_completedImports.TryGetValue(completion.SourceId, out PendingImportCheckpoint? current) &&
                    current.Version == completion.Version)
                    _completedImports.Remove(completion.SourceId);
            }
        }
    }

    private bool HasPendingCompletedImports()
    {
        lock (_completedImportsGate)
            return _completedImports.Count > 0;
    }

    private bool IsCompletionOverflowed()
    {
        lock (_completedImportsGate)
            return _completionOverflow;
    }

    private void ClearCompletionOverflow()
    {
        lock (_completedImportsGate)
            _completionOverflow = false;
    }

    private void ScheduleCheckpointRetry()
    {
        lock (_completedImportsGate)
        {
            _checkpointRetryAfter = timeProvider.GetUtcNow() + _checkpointRetryDelay;
            _checkpointRetryDelay = TimeSpan.FromSeconds(Math.Min(
                MaximumWorkerRetryDelay.TotalSeconds, _checkpointRetryDelay.TotalSeconds * 2));
        }
    }

    private void ResetCheckpointRetry()
    {
        lock (_completedImportsGate)
        {
            _checkpointRetryAfter = null;
            _checkpointRetryDelay = InitialWorkerRetryDelay;
        }
    }

    private void RebuildWatchers(
        IReadOnlyList<DiscoveredSource> sources,
        List<SourceMonitoringDiagnostic> diagnostics)
    {
        List<string> targets = [];
        string[] roots = _configuration.EffectiveSettings.InstallationRoots.ToArray();
        foreach (string root in roots)
            targets.Add(root);

        InstallationFlavorDiscoveryResult flavors = discovery.DiscoverFlavors(roots);
        foreach (InstallationFlavor flavor in flavors.Flavors)
        {
            string client = Path.Combine(flavor.InstallationRoot, flavor.Name);
            targets.Add(Path.Combine(client, "WTF", "Account"));
        }
        foreach (DiscoveredSource source in sources)
            targets.Add(Path.GetDirectoryName(source.Path)!);

        HashSet<string> desired = new(InstallationDiscovery.PathComparer);
        foreach (string path in targets)
        {
            string? existing = NearestExistingDirectory(path);
            if (existing is not null)
                desired.Add(existing);
        }

        string[] watchPaths = desired.OrderBy(path => path, InstallationDiscovery.PathComparer).ToArray();
        if (watchPaths.Length > MaximumWatchDirectories)
        {
            watchPaths = watchPaths.Take(MaximumWatchDirectories).ToArray();
            diagnostics.Add(new("watcher-limit-reached",
                "The number of source directories exceeds the watcher limit; periodic reconciliation covers remaining directories.",
                null));
        }

        string[] current;
        lock (_watcherGate) current = _watchers.Select(watcher => watcher.Path).ToArray();
        if (!_watcherFailed && watchPaths.ToHashSet(InstallationDiscovery.PathComparer).SetEquals(current))
            return;

        DisposeWatchers();
        _watcherFailed = false;
        foreach (string path in watchPaths)
        {
            try
            {
                FileSystemWatcher watcher = new(path)
                {
                    IncludeSubdirectories = false,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName |
                        NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
                    Filter = "*",
                    InternalBufferSize = 16 * 1024
                };
                watcher.Created += WatcherChanged;
                watcher.Changed += WatcherChanged;
                watcher.Deleted += WatcherChanged;
                watcher.Renamed += WatcherRenamed;
                watcher.Error += WatcherError;
                watcher.EnableRaisingEvents = true;
                lock (_watcherGate)
                {
                    bool enabled;
                    lock (_statusGate) enabled = _effectiveSettings.Enabled;
                    if (!enabled || _stopping)
                    {
                        watcher.Dispose();
                        continue;
                    }
                    _watchers.Add(watcher);
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                or ArgumentException or NotSupportedException)
            {
                _watcherFailed = true;
                diagnostics.Add(new("watcher-unavailable",
                    "A filesystem notification could not be established; periodic reconciliation remains active.", null));
                logger.LogWarning("A SavedVariables filesystem watcher could not be established ({FailureType}).",
                    exception.GetType().Name);
            }
        }
    }

    private void WatcherChanged(object sender, FileSystemEventArgs args) => Signal();
    private void WatcherRenamed(object sender, RenamedEventArgs args) => Signal();

    private void WatcherError(object sender, ErrorEventArgs args)
    {
        _watcherFailed = true;
        logger.LogWarning("A SavedVariables filesystem watcher failed; reconciliation will recover from a scan.");
        Signal();
    }

    private int WatcherCount
    {
        get { lock (_watcherGate) return _watchers.Count; }
    }

    private void DisposeWatchers()
    {
        FileSystemWatcher[] dispose;
        lock (_watcherGate)
        {
            dispose = _watchers.ToArray();
            _watchers.Clear();
        }
        foreach (FileSystemWatcher watcher in dispose)
        {
            watcher.EnableRaisingEvents = false;
            watcher.Dispose();
        }
    }

    private static string? NearestExistingDirectory(string path)
    {
        DirectoryInfo? directory = new(Path.GetFullPath(path));
        while (directory is not null)
        {
            if (Directory.Exists(directory.FullName))
                return directory.FullName;
            directory = directory.Parent;
        }
        return null;
    }

    private static async Task<string> GetStableFingerprintAsync(string path, CancellationToken cancellationToken)
    {
        FileInfo before = new(path);
        before.Refresh();
        if (!before.Exists || before.Length > MaximumSnapshotBytes)
            throw new IOException("The source is unavailable or too large.");

        long length = before.Length;
        DateTime modified = before.LastWriteTimeUtc;
        byte[] first = await HashFileAsync(path, cancellationToken).ConfigureAwait(false);
        FileInfo middle = new(path);
        middle.Refresh();
        byte[] second = await HashFileAsync(path, cancellationToken).ConfigureAwait(false);
        FileInfo after = new(path);
        after.Refresh();
        if (!after.Exists || middle.Length != length || after.Length != length ||
            middle.LastWriteTimeUtc != modified || after.LastWriteTimeUtc != modified ||
            !CryptographicOperations.FixedTimeEquals(first, second))
            throw new IOException("The source changed while its content was inspected.");
        return Convert.ToHexString(second).ToLowerInvariant();
    }

    private static async Task<byte[]> HashFileAsync(string path, CancellationToken cancellationToken)
    {
        await using FileStream stream = new(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 81920,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (stream.Length > MaximumSnapshotBytes)
            throw new IOException("The source exceeds the import size limit.");
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[81920];
        long bytesRead = 0;
        while (true)
        {
            int count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
                return hash.GetHashAndReset();
            bytesRead += count;
            if (bytesRead > MaximumSnapshotBytes)
                throw new IOException("The source exceeds the import size limit.");
            hash.AppendData(buffer, 0, count);
        }
    }

    private bool Signal() => _signals.Writer.TryWrite(0);

    private void RequestStop()
    {
        if (Interlocked.Exchange(ref _stopRequested, 1) == 0)
            _stop.Cancel();
    }

    private void SetDiagnostics(IEnumerable<SourceMonitoringDiagnostic> diagnostics)
    {
        SourceMonitoringDiagnostic[] updated = diagnostics.Distinct().ToArray();
        lock (_statusGate) _diagnostics = updated;
    }

    private void SetState(SourceMonitoringState state)
    {
        lock (_statusGate) _state = state;
    }

    private void SetStateWhenEnabled(SourceMonitoringState state)
    {
        lock (_statusGate)
        {
            if (_effectiveSettings.Enabled)
                _state = state;
        }
    }

    private void SetStateWhenDisabled(SourceMonitoringState state)
    {
        lock (_statusGate)
        {
            if (!_effectiveSettings.Enabled)
                _state = state;
        }
    }

    private void ReplaceCheckpoints(Dictionary<string, MonitoringCheckpoint> working)
    {
        _checkpoints.Clear();
        foreach ((string id, MonitoringCheckpoint checkpoint) in working)
            _checkpoints[id] = checkpoint;
    }

    private static bool CheckpointsEqual(
        IReadOnlyDictionary<string, MonitoringCheckpoint> first,
        IReadOnlyDictionary<string, MonitoringCheckpoint> second) =>
        first.Count == second.Count && first.All(pair =>
            second.TryGetValue(pair.Key, out MonitoringCheckpoint? value) && value == pair.Value);

    private sealed record PendingImportCheckpoint(
        string SourceId,
        long Version,
        string? IngestedFingerprint,
        bool FailedAfterLatestSuccess);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;
        lock (_preferenceGate)
        {
            _stopping = true;
            imports.SetAutomaticEnabled(false);
        }
        imports.OperationCompleted -= ImportCompleted;
        DisposeWatchers();
        RequestStop();
        _stop.Dispose();
        _passGate.Dispose();
    }
}
