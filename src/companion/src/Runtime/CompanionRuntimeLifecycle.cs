using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime;

internal sealed class CompanionRuntimeLifecycle(
    IServiceProvider services, CompanionApplicationStatus status, IHostApplicationLifetime lifetime,
    CompanionRuntimeConfiguration configuration, ILogger<CompanionRuntimeLifecycle> logger) : IHostedLifecycleService, IDisposable
{
    private Store? _store;
    private CancellationTokenRegistration _started;
    private CancellationTokenRegistration _stopping;

    public Task StartingAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        status.Starting();
        _started = lifetime.ApplicationStarted.Register(() =>
        {
            status.Transition(CompanionLifecycleState.Running);
            logger.LogInformation("Artisan Logbook Companion started. Monitoring preference: {MonitoringEnabled}. " +
                "Source monitoring and the HTTP API are not implemented in this release.", configuration.Settings.Monitoring.Enabled);
        });
        _stopping = lifetime.ApplicationStopping.Register(() => status.Transition(CompanionLifecycleState.Stopping));
        return Task.CompletedTask;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            _store = services.GetRequiredService<Store>();
            _store.ReadStatus();
            status.DatabaseOpened(_store);
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }
        catch (OperationCanceledException)
        {
            CloseDatabase();
            throw;
        }
        catch (Exception exception)
        {
            status.Fail("database-startup-failed", "Cannot initialize the history database.", exception);
            CloseDatabase();
            throw;
        }
    }

    public Task StartedAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task StoppingAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task StoppedAsync(CancellationToken cancellationToken)
    {
        CloseDatabase();
        status.Transition(CompanionLifecycleState.Stopped);
        logger.LogInformation("Artisan Logbook Companion stopped; database ownership released.");
        return Task.CompletedTask;
    }

    private void CloseDatabase()
    {
        status.DatabaseClosed();
        _store?.Dispose();
        _store = null;
    }

    public void Dispose()
    {
        _started.Dispose();
        _stopping.Dispose();
        CloseDatabase();
    }
}
