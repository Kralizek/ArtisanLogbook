using System.Data.Common;
using System.Reflection;

using ArtisanLogbook.Cli.Commands;

using Microsoft.Extensions.DependencyInjection;

using Spectre.Console;
using Spectre.Console.Cli;
using Spectre.Console.Cli.Extensions.DependencyInjection;

namespace ArtisanLogbook.Cli;

public static class CompanionCommandApp
{
    public static CommandApp Create(IAnsiConsole console, ApplicationPaths paths)
    {
        ServiceCollection services = new();
        services.AddSingleton(console);
        services.AddSingleton(paths);
        CommandApp app = new(new DependencyInjectionRegistrar(services));
        app.Configure(config =>
        {
            config.Settings.Console = console;
            config.SetApplicationName("artisanlogbook");
            config.UseStrictParsing();
            config.SetApplicationVersion(typeof(CompanionCommandApp).Assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0]);
            config.ValidateExamples();
            config.AddCommand<ImportCommand>("import")
                .WithDescription("Preserve canonical crafts from a SavedVariables snapshot.")
                .WithExample(["import", "ArtisanLogbook.lua"])
                .WithExample(["import", "ArtisanLogbook.lua", "--database", "history.duckdb"]);
            config.AddCommand<StatusCommand>("status")
                .WithDescription("Show read-only history counts across all game contexts.")
                .WithExample(["status"])
                .WithExample(["status", "--database", "history.duckdb"]);
            config.SetExceptionHandler((exception, _) =>
            {
                console.MarkupLine($"[red]Error:[/] {Markup.Escape(exception.Message)}");
                if (exception is DbException)
                    console.WriteLine("If the database is locked, close other Companion/DuckDB processes using it and retry. " +
                        "Do not delete the database or its WAL file.");
                return exception is CommandRuntimeException ? ExitCodes.Usage : ExitCodes.Failed;
            });
        });
        return app;
    }
}
