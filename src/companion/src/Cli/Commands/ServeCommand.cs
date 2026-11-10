using System.ComponentModel;

using ArtisanLogbook.Runtime;

using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;

using Spectre.Console;
using Spectre.Console.Cli;

namespace ArtisanLogbook.Cli.Commands;

public sealed class ServeSettings : DatabaseSettings
{
    [CommandOption("--monitoring <BOOL>")]
    [Description("Override automatic SavedVariables monitoring for this invocation.")]
    public bool? Monitoring { get; init; }

    [CommandOption("--reconciliation-interval <SECONDS>")]
    [Description("Override the reconciliation interval (1-86400 seconds; default 60).")]
    public int? ReconciliationIntervalSeconds { get; init; }

    [CommandOption("--port <PORT>")]
    [Description("Preferred loopback API port (1-65535; default 48721); an OS-assigned port is used if it is taken.")]
    public int? Port { get; init; }

    public override ValidationResult Validate()
    {
        if (ReconciliationIntervalSeconds is < 1 or > 86400)
            return ValidationResult.Error("--reconciliation-interval must be between 1 and 86400.");
        if (Port is < 1 or > 65535)
            return ValidationResult.Error("--port must be between 1 and 65535.");
        return base.Validate();
    }
}

public sealed class ServeCommand(ApplicationPaths paths, CompanionSettingsStore settingsStore, IAnsiConsole console) : AsyncCommand<ServeSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, ServeSettings settings)
    {
        CompanionRuntimeConfiguration configuration = CompanionRuntimeConfiguration.Resolve(
            paths, settingsStore, settings.Database, settings.Monitoring, settings.ReconciliationIntervalSeconds, settings.Port);
        WebApplicationBuilder builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions
        {
            Args = [],
            ApplicationName = typeof(ServeCommand).Assembly.GetName().Name
        });
        builder.ConfigureCompanionHost(configuration);
        builder.Services.AddArtisanLogbookCompanion(paths, configuration);
        await using WebApplication app = builder.Build();
        app.Lifetime.ApplicationStarted.Register(() =>
        {
            string? url = app.Services.GetRequiredService<CompanionHttpEndpoint>().ListeningUrl;
            if (url is not null)
                console.WriteLine($"Artisan Logbook API: {url}/api/v1 (OpenAPI: {url}/openapi/v1.yaml)");
        });
        await app.RunCompanionAsync();
        return ExitCodes.Success;
    }
}
