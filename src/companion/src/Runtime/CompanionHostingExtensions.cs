using ArtisanLogbook.ImportService;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Runtime;

public static class CompanionHostingExtensions
{
    /// <summary>Configure the embedded loopback host: the preferred port, or an OS-assigned loopback port when it is owned elsewhere.</summary>
    public static WebApplicationBuilder ConfigureCompanionHost(
        this WebApplicationBuilder builder, CompanionRuntimeConfiguration configuration)
    {
        CompanionHttpEndpoint endpoint = CompanionHttpEndpoint.Select(configuration.EffectiveSettings.Http.PreferredPort);
        builder.Services.AddSingleton(endpoint);
        builder.WebHost.UseKestrel(options => options.Limits.MaxRequestBodySize = LocalApiSecurityMiddleware.MaxRequestBodyBytes)
            .UseUrls(endpoint.RequestedUrl);
        builder.Host.UseConsoleLifetime();
        builder.Logging.AddSimpleConsole(options => options.SingleLine = true);
        builder.Logging.AddFilter("Microsoft.Hosting.Lifetime", LogLevel.Warning);
        return builder;
    }

    public static async Task RunCompanionAsync(this WebApplication app, CancellationToken cancellationToken = default)
    {
        try
        {
            await app.StartAsync(cancellationToken);
            await app.WaitForShutdownAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            app.Services.GetRequiredService<CompanionApplicationStatus>()
                .Fail("host-failed", "The Companion host could not start or continue running.", exception);
            throw;
        }
        finally
        {
            CompanionWorkAdmission admission = app.Services.GetRequiredService<CompanionWorkAdmission>();
            admission.StopAccepting();
            await admission.DrainAsync();
        }
    }

    public static IServiceCollection AddArtisanLogbookCompanion(
        this IServiceCollection services, ApplicationPaths paths, CompanionRuntimeConfiguration configuration)
    {
        CompanionSettingsStore.Validate(configuration.EffectiveSettings);
        if (services.Any(service => service.ServiceType == typeof(Store)))
            throw new InvalidOperationException("Companion history ownership has already been registered for this host.");
        if (!Path.IsPathFullyQualified(configuration.DatabasePath))
            throw new ArgumentException("The runtime database path must be absolute.", nameof(configuration));
        services.TryAddSingleton(new CompanionHttpEndpoint(configuration.EffectiveSettings.Http.PreferredPort, false));
        services.AddSingleton(paths);
        services.AddSingleton(configuration);
        services.AddSingleton<CompanionSettingsStore>();
        services.AddSingleton<InstallationDiscovery>();
        services.AddSingleton<Store>(_ => new Store(configuration.DatabasePath));
        services.AddSingleton<CompanionImportService>();
        services.AddSingleton<CompanionApplicationStatus>();
        services.AddSingleton<CompanionWorkAdmission>();
        services.AddSingleton<CompanionRuntimeImports>();
        services.AddCompanionApi();
        services.AddHostedService<CompanionRuntimeLifecycle>();
        return services;
    }
}
