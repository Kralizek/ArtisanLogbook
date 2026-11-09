using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime;

internal sealed class CompanionRuntimeLifecycle(
    IServiceProvider services, CompanionApplicationStatus status, IHostApplicationLifetime lifetime,
    CompanionRuntimeConfiguration configuration, CompanionWorkAdmission admission,
    ILogger<CompanionRuntimeLifecycle> logger) : IHostedLifecycleService, IDisposable
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
                "Source monitoring and the HTTP API are not implemented in this release.", configuration.EffectiveSettings.Monitoring.Enabled);
        });
        _stopping = lifetime.ApplicationStopping.Register(BeginStopping);
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
            admission.Open();
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
    public Task StoppingAsync(CancellationToken cancellationToken)
    {
        BeginStopping();
        return Task.CompletedTask;
    }
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public async Task StoppedAsync(CancellationToken cancellationToken)
    {
        BeginStopping();
        // Shutdown cancellation must not close C03 beneath admitted work still unwinding.
        await admission.DrainAsync();
        CloseDatabase();
        status.Transition(CompanionLifecycleState.Stopped);
        logger.LogInformation("Artisan Logbook Companion stopped; database ownership released.");
    }

    private void BeginStopping()
    {
        admission.StopAccepting();
        status.Transition(CompanionLifecycleState.Stopping);
    }

    private void CloseDatabase()
    {
        admission.StopAccepting();
        status.DatabaseClosed();
        _store?.Dispose();
        _store = null;
    }

    public void Dispose()
    {
        admission.StopAccepting();
        _started.Dispose();
        _stopping.Dispose();
        CloseDatabase();
    }
}
