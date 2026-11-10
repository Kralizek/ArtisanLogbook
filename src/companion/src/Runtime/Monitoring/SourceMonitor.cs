using System.Collections.Immutable;
using System.Reactive;
using System.Reactive.Concurrency;
using System.Reactive.Disposables;
using System.Reactive.Linq;
using System.Reactive.Subjects;
using System.Reactive.Threading.Tasks;

using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace ArtisanLogbook.Runtime;

internal enum MonitoringPhase { Disabled, Starting, Reconciling, Active, Degraded, Stopping, Stopped }
internal enum ReconciliationRequestOutcome { Accepted, Disabled, Stopping }

internal sealed record MonitoringStatus(
    CompanionRuntimeConfiguration Configuration, MonitoringPhase Phase, ReconciliationReport? LastReconciliation,
    int PendingSources, bool CheckpointSavePending, IReadOnlyList<MonitoringDiagnostic> Diagnostics);

/// <summary>Hosts event composition; domain operations and durable acknowledgement remain explicit.</summary>
internal sealed class SourceMonitor : IHostedLifecycleService, IDisposable
{
    private sealed record State(
        CompanionRuntimeConfiguration Configuration, MonitoringPhase Phase,
        ReconciliationReport? Report, ImmutableHashSet<string> UnavailableWatchers, MonitoringDiagnostic? Failure = null);
    private sealed record SessionOptions(bool Enabled, int Interval, IReadOnlyList<string> Roots);
    private sealed record Work(SessionOptions Options, CancellationToken Cancellation);

    private readonly object _gate = new();
    private State _state;
    private readonly Subject<Unit> _configurations = new();
    private readonly Subject<Unit> _requests = new();
    private readonly CancellationDisposable _shutdown = new();
    private readonly CancellationDisposable _persistenceDeadline = new();
    private readonly CompanionSettingsStore _settings;
    private readonly SourceChangeFeed _feed;
    private readonly SourceReconciler _reconciler;
    private readonly MonitoringCheckpoints _checkpoints;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly IScheduler _scheduler;
    private readonly ILogger<SourceMonitor> _logger;
    private Task _processing = Task.CompletedTask;

    public SourceMonitor(
        CompanionRuntimeConfiguration configuration, CompanionSettingsStore settings, SourceChangeFeed feed,
        SourceReconciler reconciler, MonitoringCheckpoints checkpoints, IHostApplicationLifetime lifetime,
        IScheduler scheduler, ILogger<SourceMonitor> logger)
    {
        _state = new(configuration, configuration.EffectiveSettings.Monitoring.Enabled
            ? MonitoringPhase.Starting : MonitoringPhase.Disabled, null, ImmutableHashSet<string>.Empty);
        (_settings, _feed, _reconciler, _checkpoints, _lifetime, _scheduler, _logger) =
            (settings, feed, reconciler, checkpoints, lifetime, scheduler, logger);
    }

    public MonitoringStatus Read()
    {
        State state;
        lock (_gate) state = _state;
        CheckpointSnapshot checkpoints = _checkpoints.Read();
        List<MonitoringDiagnostic> diagnostics = [.. state.Report?.Diagnostics ?? []];
        if (state.UnavailableWatchers.Count > 0)
            diagnostics.Add(new("watcher-unavailable",
                $"{state.UnavailableWatchers.Count} filesystem watcher(s) are unavailable; periodic discovery remains active."));
        if (state.Failure is not null) diagnostics.Add(state.Failure);
        if (checkpoints.PersistenceFailure is not null)
            diagnostics.Add(new(checkpoints.PersistenceFailure, "Checkpoint persistence failed; unacknowledged results are retained for retry."));
        diagnostics.AddRange(checkpoints.Document.Sources.Where(pair => pair.Value.NeedsReconciliation &&
                pair.Value.LastAttempt?.Outcome == CheckpointAttemptOutcome.Failed)
            .Select(pair => new MonitoringDiagnostic("source-import-failed", "The latest import failed; see import diagnostics. It remains eligible for retry.", pair.Key)));
        MonitoringPhase phase = state.Phase == MonitoringPhase.Active && diagnostics.Count > 0
            ? MonitoringPhase.Degraded : state.Phase;
        if (_lifetime.ApplicationStopping.IsCancellationRequested && phase != MonitoringPhase.Stopped)
            phase = MonitoringPhase.Stopping;
        return new(state.Configuration, phase, state.Report,
            checkpoints.Document.Sources.Values.Count(source => source.NeedsReconciliation),
            checkpoints.IsDirty, diagnostics.Distinct().ToArray());
    }

    public void UpdatePreferences(MonitoringSettings preferences, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            State current = _state;
            if (_lifetime.ApplicationStopping.IsCancellationRequested || current.Phase is MonitoringPhase.Stopping or MonitoringPhase.Stopped)
                throw new InvalidOperationException("The Companion is stopping.");
            SettingsLoadResult loaded = _settings.Load();
            if (!loaded.CanSave) throw new CompanionSettingsException(loaded.Diagnostic!);
            CompanionSettings saved = (loaded.Settings ?? CompanionSettings.ForRoots()) with { Monitoring = preferences };
            _settings.Save(saved, cancellationToken, loaded);
            CompanionSettings runningPreferences = (current.Configuration.PersistedPreferences ?? CompanionSettings.ForRoots())
                with
            { Monitoring = preferences };
            CompanionRuntimeConfiguration resolved = current.Configuration.WithPersistedPreferences(runningPreferences);
            bool changed = !SameOptions(Options(current), Options(current with { Configuration = resolved }));
            _state = current with
            {
                Configuration = resolved,
                Phase = !resolved.EffectiveSettings.Monitoring.Enabled ? MonitoringPhase.Disabled :
                    changed ? MonitoringPhase.Starting : current.Phase,
                UnavailableWatchers = changed ? ImmutableHashSet<string>.Empty : current.UnavailableWatchers,
                Failure = changed ? null : current.Failure
            };
        }
        _configurations.OnNext(Unit.Default);
    }

    public ReconciliationRequestOutcome RequestReconciliation()
    {
        lock (_gate)
        {
            if (_lifetime.ApplicationStopping.IsCancellationRequested || _state.Phase is MonitoringPhase.Stopping or MonitoringPhase.Stopped)
                return ReconciliationRequestOutcome.Stopping;
            if (!_state.Configuration.EffectiveSettings.Monitoring.Enabled)
                return ReconciliationRequestOutcome.Disabled;
        }
        _requests.OnNext(Unit.Default);
        return ReconciliationRequestOutcome.Accepted;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _processing = _lifetime.ApplicationStarted.WhenCancelled()
            .SelectMany(_ => ObserveConfiguration()
                .DistinctUntilChanged(EqualityComparer<SessionOptions>.Create(SameOptions))
                .Select(CreateSession).Switch())
            .TakeUntil(_shutdown.Token.WhenCancelled())
            .Select(work => Observable.FromAsync(() => Task.Run(() => ProcessAsync(work)))
                .Catch<Unit, Exception>(exception =>
                {
                    _logger.LogError("Monitoring operation failed ({ExceptionType}); later invalidations will retry.",
                        exception.GetType().Name);
                    Publish(work, state => state with
                    {
                        Phase = work.Options.Enabled ? MonitoringPhase.Active : state.Phase,
                        Failure = new("reconciliation-failed", "A monitoring operation failed; reconciliation will retry.")
                    });
                    return Observable.Return(Unit.Default);
                }))
            .ConcatLatest()
            .Do(_ => { }, exception =>
            {
                _logger.LogCritical("Monitoring event composition failed ({ExceptionType}); stopping the host.", exception.GetType().Name);
                _lifetime.StopApplication();
            })
            .DefaultIfEmpty(Unit.Default).ToTask();
        return Task.CompletedTask;
    }

    private IObservable<SessionOptions> ObserveConfiguration() => Observable.Create<Unit>(observer =>
    {
        IDisposable subscription = _configurations.Subscribe(observer);
        observer.OnNext(Unit.Default);
        return subscription;
    }).Merge(_lifetime.ApplicationStopping.WhenCancelled()).Synchronize().Select(_ =>
    {
        // Hints carry no snapshot: concurrently published changes always resolve the latest saved state.
        lock (_gate)
        {
            if (_lifetime.ApplicationStopping.IsCancellationRequested && _state.Phase != MonitoringPhase.Stopped)
                _state = _state with { Phase = MonitoringPhase.Stopping };
            return Options(_state);
        }
    });

    private IObservable<Work> CreateSession(SessionOptions options) =>
        Observable.Using(() => new CancellationDisposable(), cancellation =>
        {
            IObservable<SourceInvalidation> source = options.Enabled
                ? _feed.Observe(options.Roots, TimeSpan.FromSeconds(options.Interval), _requests)
                : Observable.Return(new SourceInvalidation(SourceChangeReason.Checkpoint));
            return Observable.Merge(source,
                    Observable.FromEventPattern(h => _checkpoints.CompletionRecorded += h, h => _checkpoints.CompletionRecorded -= h)
                        .Select(_ => new SourceInvalidation(SourceChangeReason.Checkpoint)),
                    Observable.Interval(TimeSpan.FromSeconds(1), _scheduler)
                        .Where(_ => _checkpoints.NeedsMaintenance(_scheduler.Now, options.Enabled))
                        .Select(_ => new SourceInvalidation(SourceChangeReason.Checkpoint)))
                .Do(change =>
                {
                    if (change.Reason is not (SourceChangeReason.WatcherReady or SourceChangeReason.WatcherUnavailable)) return;
                    Publish(new(options, cancellation.Token), state => state with
                    {
                        UnavailableWatchers = change.Reason == SourceChangeReason.WatcherReady
                            ? state.UnavailableWatchers.Remove(change.Key!) : state.UnavailableWatchers.Add(change.Key!)
                    });
                })
                .Select(_ => new Work(options, cancellation.Token));
        });

    private async Task<Unit> ProcessAsync(Work work)
    {
        if (work.Options.Enabled && !work.Cancellation.IsCancellationRequested)
        {
            Publish(work, state => state with { Phase = MonitoringPhase.Reconciling });
            try
            {
                ReconciliationReport report = await _reconciler.ReconcileAsync(_scheduler.Now, work.Cancellation).ConfigureAwait(false);
                Publish(work, state => state with { Phase = MonitoringPhase.Active, Report = report, Failure = null });
            }
            catch (OperationCanceledException) when (work.Cancellation.IsCancellationRequested) { }
        }
        await _checkpoints.FlushAsync(_persistenceDeadline.Token).ConfigureAwait(false);
        return Unit.Default;
    }

    private void Publish(Work work, Func<State, State> update)
    {
        lock (_gate)
        {
            if (work.Cancellation.IsCancellationRequested || _lifetime.ApplicationStopping.IsCancellationRequested ||
                _state.Phase is MonitoringPhase.Stopping or MonitoringPhase.Stopped ||
                !SameOptions(work.Options, Options(_state))) return;
            _state = update(_state);
        }
    }

    private static SessionOptions Options(State state) => new(
        state.Configuration.EffectiveSettings.Monitoring.Enabled &&
            state.Phase is not (MonitoringPhase.Stopping or MonitoringPhase.Stopped),
        state.Configuration.EffectiveSettings.Monitoring.ReconciliationIntervalSeconds,
        state.Configuration.EffectiveSettings.InstallationRoots);

    private static bool SameOptions(SessionOptions? first, SessionOptions? second) =>
        first is not null && second is not null && first.Enabled == second.Enabled && first.Interval == second.Interval &&
        first.Roots.SequenceEqual(second.Roots, InstallationDiscovery.PathComparer);

    public Task StartingAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task StartedAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task StoppingAsync(CancellationToken cancellationToken)
    {
        lock (_gate) _state = _state with { Phase = MonitoringPhase.Stopping };
        _configurations.OnNext(Unit.Default);
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await StoppingAsync(cancellationToken);
        _shutdown.Dispose();
        using CancellationTokenRegistration deadline = cancellationToken.Register(_persistenceDeadline.Dispose);
        await _processing.ConfigureAwait(false);
    }

    public async Task StoppedAsync(CancellationToken cancellationToken)
    {
        try { await _checkpoints.FlushAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            _logger.LogError("Final monitoring checkpoint persistence failed ({ExceptionType}); shutdown cannot acknowledge pending imports.",
                exception.GetType().Name);
            throw;
        }
        finally
        {
            lock (_gate) _state = _state with { Phase = MonitoringPhase.Stopped };
        }
    }

    public void Dispose()
    {
        _shutdown.Dispose();
        _persistenceDeadline.Dispose();
        try { _processing.GetAwaiter().GetResult(); }
        finally
        {
            _requests.Dispose();
            _configurations.Dispose();
        }
    }
}
