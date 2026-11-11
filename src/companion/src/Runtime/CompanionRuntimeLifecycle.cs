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
    ILogger<CompanionRuntimeLifecycle> logger) : IHostedLifecycleService, IDisposable
{
    private Store? _store;
    private CancellationTokenRegistration _stopping;

    public Task StartingAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        status.Starting();
        _stopping = lifetime.ApplicationStopping.Register(BeginStopping);
        return Task.CompletedTask;
    }

    public Task StartAsync(CancellationToken cancellationToken)
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
            return Task.CompletedTask;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            status.Fail("database-startup-failed", "Cannot initialize the history database.", exception);
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

    public Task StartedAsync(CancellationToken cancellationToken)
    {
        status.Transition(CompanionLifecycleState.Running);
        logger.LogInformation(CompanionEvents.Started, "Artisan Logbook Companion started.");
        logger.LogInformation(CompanionEvents.MonitoringPreference, "SavedVariables monitoring: {MonitoringState}",
            configuration.EffectiveSettings.Monitoring.Enabled ? "on" : "off");
        logger.LogInformation(CompanionEvents.ReconciliationInterval, "Reconciliation interval: {ReconciliationIntervalSeconds} seconds.",
            configuration.EffectiveSettings.Monitoring.ReconciliationIntervalSeconds);
        ReportListeningUrl();
        return Task.CompletedTask;
    }
    public Task StoppingAsync(CancellationToken cancellationToken)
    {
        BeginStopping();
        return Task.CompletedTask;
    }
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public async Task StoppedAsync(CancellationToken cancellationToken)
    {
        BeginStopping();
        try
        {
            Task disposal = _store?.DisposeAsync().AsTask() ?? Task.CompletedTask;
            await Task.WhenAll(disposal, admission.DrainAsync(cancellationToken)).ConfigureAwait(false);
            status.DatabaseClosed();
            if (status.Transition(CompanionLifecycleState.Stopped))
                logger.LogInformation(CompanionEvents.Stopped, "Artisan Logbook Companion stopped; database ownership released.");
        }
        catch (Exception exception)
        {
            string code = exception is TimeoutException ? "database-shutdown-timeout" :
                exception is OperationCanceledException ? "shutdown-drain-cancelled" : "database-shutdown-failed";
            status.Fail(code, "Shutdown did not complete successfully; unfinished operations retain their resources.", exception);
            logger.LogError(exception, "Companion shutdown failed; successful database release has not been reported.");
            throw;
        }
    }

    private void BeginStopping()
    {
        admission.StopAccepting();
        status.Transition(CompanionLifecycleState.Stopping);
    }

    public void Dispose()
    {
        admission.StopAccepting();
        _stopping.Dispose();
    }
}
