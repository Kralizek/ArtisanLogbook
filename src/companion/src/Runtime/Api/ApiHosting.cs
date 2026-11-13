using ArtisanLogbook.CompanionApi.Endpoints;
using ArtisanLogbook.Runtime.GraphQL;

using HotChocolate.AspNetCore;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
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
        services.AddDataLoader<CharacterLoader>();
        services.AddDataLoader<CharacterCraftPageLoader>();
        services.AddDataLoader<RecipeLoader>();
        services.AddDataLoader<ProfessionLoader>();
        services.AddDataLoader<ExpansionLoader>();
        services.AddDataLoader<ItemLoader>();
        services.AddDataLoader<RecipeSlotLoader>();
        services.AddGraphQLServer(maxAllowedRequestSize: LocalApiSecurityMiddleware.MaxGraphQLBodyBytes)
            .AddQueryType<HistoryQuery>()
            .AddErrorFilter<HistoryErrorFilter>(provider => new(
                provider.GetRootServiceProvider().GetRequiredService<ILogger<HistoryErrorFilter>>()))
            .DisableIntrospection(false)
            .AddMaxExecutionDepthRule(12)
            .ModifyParserOptions(options => options.MaxAllowedFields = 100)
            .ModifyRequestOptions(options =>
            {
                options.ExecutionTimeout = TimeSpan.FromSeconds(30);
                options.IncludeExceptionDetails = false;
            })
            .ModifyCostOptions(options =>
            {
                options.EnforceCostLimits = true;
                options.ApplySlicingArgumentDefaultValue = true;
                options.DefaultListSize = 20;
                options.MaxFieldCost = 1_000_000;
                options.MaxTypeCost = 1_000_000;
            })
            .ModifyServerOptions(options =>
            {
                options.EnableGetRequests = false;
                options.EnableSchemaRequests = false;
                options.EnableMultipartRequests = false;
                options.Batching = AllowedBatching.None;
                options.MaxBatchSize = 1;
                options.MaxConcurrentExecutions = 8;
            });
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
                endpoints.MapGraphQLHttp("/graphql");
            });
            next(app);
        };
    }
}
