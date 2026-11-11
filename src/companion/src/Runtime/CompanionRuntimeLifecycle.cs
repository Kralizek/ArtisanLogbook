using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime;

internal sealed class CompanionRuntimeLifecycle(
    IServiceProvider services, CompanionApplicationStatus status, IHostApplicationLifetime lifetime,
    CompanionRuntimeConfiguration configuration, CompanionWorkAdmission admission,
    InstallationDiscovery discovery,
    ILogger<CompanionRuntimeLifecycle> logger) : IHostedLifecycleService, IDisposable, IAsyncDisposable
{
    private Store? _store;
    private int _cleanupFailed;
    private int _databaseClosed;
    private CancellationTokenRegistration _started;
    private CancellationTokenRegistration _stopping;

    public Task StartingAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        status.Starting();
        _started = lifetime.ApplicationStarted.Register(() =>
        {
            status.Transition(CompanionLifecycleState.Running);
            logger.LogInformation(CompanionEvents.Started, "Artisan Logbook Companion started.");
            logger.LogInformation(CompanionEvents.MonitoringPreference, "SavedVariables monitoring: {MonitoringState}",
                configuration.EffectiveSettings.Monitoring.Enabled
                    ? "on"
                    : "off");
            logger.LogInformation(CompanionEvents.ReconciliationInterval, "Reconciliation interval: {ReconciliationIntervalSeconds} seconds.",
                configuration.EffectiveSettings.Monitoring.ReconciliationIntervalSeconds);
            ReportListeningUrl();
        });
        _stopping = lifetime.ApplicationStopping.Register(BeginStopping);
        return Task.CompletedTask;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            _store = services.GetRequiredService<Store>();
            _store.ReadStatus(cancellationToken);
            status.DatabaseOpened(_store);
            LogInstallationFlavors();
            admission.Open();
            cancellationToken.ThrowIfCancellationRequested();
            return;
        }
        catch (OperationCanceledException exception)
        {
            await CleanupFailedStartupAsync(exception);
            throw;
        }
        catch (Exception exception)
        {
            status.Fail("database-startup-failed", "Cannot initialize the history database.", exception);
            await CleanupFailedStartupAsync(exception);
            throw;
        }
    }

    private void ReportListeningUrl()
    {
        CompanionHttpEndpoint endpoint = services.GetRequiredService<CompanionHttpEndpoint>();
        string? address = services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()?.Addresses.FirstOrDefault();
        if (address is null)
        {
            logger.LogWarning("The HTTP listening address could not be determined.");
            return;
        }
        endpoint.Resolved(address.TrimEnd('/'));
        if (endpoint.FallbackUsed)
            logger.LogWarning("HTTP preferred port {PreferredPort} is unavailable; using an OS-assigned port instead.",
                endpoint.PreferredPort);
        logger.LogInformation(CompanionEvents.Listening, "HTTP API listening on {ListeningUrl} (preferred port {PreferredPort}).",
            endpoint.ListeningUrl, endpoint.PreferredPort);
    }

    private void LogInstallationFlavors()
    {
        IReadOnlyList<string> roots = configuration.EffectiveSettings.InstallationRoots;
        if (roots.Count == 0)
        {
            logger.LogInformation(CompanionEvents.NoInstallations, "Game directory: not configured.");
            return;
        }

        InstallationFlavorDiscoveryResult result = discovery.DiscoverFlavors(roots);
        foreach (string root in roots)
        {
            string[] flavors = result.Flavors
                .Where(flavor => InstallationDiscovery.PathComparer.Equals(flavor.InstallationRoot, root))
                .Select(flavor => flavor.Name)
                .ToArray();
            logger.LogInformation(CompanionEvents.Installation, "Game directory: {GameDirectory}", root);
            logger.LogInformation(CompanionEvents.InstalledFlavors, "ArtisanLogbook Core installed flavors: {InstalledFlavors}",
                flavors.Length == 0 ? "(none detected)" : string.Join(", ", flavors));
        }

        foreach (DiscoveryDiagnostic diagnostic in result.Diagnostics)
            logger.LogWarning("Game directory discovery issue {DiagnosticCode} at {Path}: {Message}",
                diagnostic.Code, diagnostic.Path, diagnostic.Message);
    }

    public Task StartedAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task StoppingAsync(CancellationToken cancellationToken)
    {
        BeginStopping();
        return Task.CompletedTask;
    }
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public async Task StoppedAsync(CancellationToken cancellationToken)
    {
        BeginStopping();
        await DrainAndCloseDatabaseAsync();
        if (Volatile.Read(ref _cleanupFailed) == 0)
        {
            status.Transition(CompanionLifecycleState.Stopped);
            logger.LogInformation(CompanionEvents.Stopped, "Artisan Logbook Companion stopped; database ownership released.");
        }
    }

    private async Task CleanupFailedStartupAsync(Exception startupFailure)
    {
        // Startup can fail after admission opens; C03 still owns any operations that outlive the grace period.
        admission.StopAccepting();
        try
        {
            await DrainAndCloseDatabaseAsync().ConfigureAwait(false);
        }
        catch (Exception cleanupFailure)
        {
            throw new AggregateException("Companion startup and cleanup both failed.", startupFailure, cleanupFailure);
        }
    }

    private void BeginStopping()
    {
        admission.StopAccepting();
        status.Transition(CompanionLifecycleState.Stopping);
    }

    private async Task CloseDatabaseAsync()
    {
        if (_store is not null)
            await _store.DisposeAsync().ConfigureAwait(false);
        if (Interlocked.Exchange(ref _databaseClosed, 1) == 0)
            status.DatabaseClosed();
    }

    private async Task DrainAndCloseDatabaseAsync()
    {
        admission.StopAccepting();
        try
        {
            _store?.RequestShutdown();
            await Task.WhenAll(admission.DrainAsync(_store?.ShutdownGracePeriod),
                CloseDatabaseAsync()).ConfigureAwait(false);
            if (_store?.ShutdownTimedOut == true && Volatile.Read(ref _cleanupFailed) == 0)
                ReportCleanupFailure(new TimeoutException("An earlier HistoryStore shutdown exceeded its grace period."));
        }
        catch (Exception exception)
        {
            ReportCleanupFailure(exception);
            throw;
        }
    }

    private void ReportCleanupFailure(Exception exception)
    {
        Interlocked.Exchange(ref _cleanupFailed, 1);
        bool timedOut = exception is TimeoutException;
        status.Fail(timedOut ? "database-shutdown-timeout" : "database-shutdown-failed",
            timedOut ? "Shutdown grace expired; unfinished database operations retain ownership until they unwind." :
                "Database cleanup failed; ownership release could not be confirmed.", exception);
        logger.LogError(exception, "Companion database cleanup failed; successful shutdown has not been reported.");
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public async ValueTask DisposeAsync()
    {
        admission.StopAccepting();
        await _started.DisposeAsync().ConfigureAwait(false);
        await _stopping.DisposeAsync().ConfigureAwait(false);
        await DrainAndCloseDatabaseAsync().ConfigureAwait(false);
        if (Volatile.Read(ref _cleanupFailed) == 0)
            status.Transition(CompanionLifecycleState.Stopped);
    }
}
