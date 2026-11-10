using System.Reactive.Concurrency;

using ArtisanLogbook.CompanionApi.Endpoints;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;

using MinimalOpenAPI;

namespace ArtisanLogbook.Runtime;

internal static class CompanionApiHosting
{
    public static IServiceCollection AddCompanionApi(this IServiceCollection services)
    {
        services.AddRouting();
        services.AddMinimalOpenApi();
        services.ConfigureHttpJsonOptions(options =>
            options.SerializerOptions.UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow);
        services.AddSingleton<SourceCatalog>();
        services.AddSingleton<ImportOperationLimits>();
        services.AddSingleton<ImportOperations>();
        services.AddHostedService(provider => provider.GetRequiredService<ImportOperations>());
        services.AddSingleton<MonitoringCheckpointStore>();
        services.AddSingleton<IMonitoringCheckpointPersistence>(provider =>
            provider.GetRequiredService<MonitoringCheckpointStore>());
        services.TryAddSingleton<IScheduler>(_ => Scheduler.Default);
        services.AddSingleton<SourceMonitor>();
        services.AddHostedService(provider => provider.GetRequiredService<SourceMonitor>());
        services.AddTransient<IStartupFilter, CompanionApiStartupFilter>();
        return services;
    }

    private sealed class CompanionApiStartupFilter : IStartupFilter
    {
        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
        {
            app.UseMiddleware<LocalApiSecurityMiddleware>();
            app.UseExceptionHandler(error => error.Run(async context =>
            {
                Exception? exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
                if (exception is BadHttpRequestException bad)
                {
                    await ProblemResponses.Write(context, bad.StatusCode, "invalid-request", "The request is malformed.");
                    return;
                }
                context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("ArtisanLogbook.Api")
                    .LogError(exception, "Unhandled API failure on {Method} {Path}.", context.Request.Method, context.Request.Path);
                await ProblemResponses.Write(context, 500, "internal-error", "An unexpected error occurred.");
            }));
            app.UseStatusCodePages(context => ProblemResponses.Write(
                context.HttpContext, context.HttpContext.Response.StatusCode,
                context.HttpContext.Response.StatusCode switch
                {
                    400 => "invalid-request",
                    404 => "not-found",
                    405 => "method-not-allowed",
                    _ => "http-error"
                },
                "The request could not be processed."));
            app.UseRouting();
            app.UseEndpoints(endpoints =>
            {
                endpoints.MapMinimalOpenApiEndpoints();
                endpoints.MapOpenApiSchemas();
            });
            next(app);
        };
    }
}
