using System.ComponentModel;
using System.Data.Common;
using System.Security;

using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;

using Spectre.Console;
using Spectre.Console.Cli;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Cli.Commands;

public sealed class ImportCommand(
    ApplicationPaths paths, IAnsiConsole console, CompanionSettingsStore settingsStore, InstallationDiscovery discovery)
    : AsyncCommand<ImportCommand.ImportSettings>
{
    public sealed class ImportSettings : DatabaseSettings
    {
        [CommandArgument(0, "[SOURCE-FILE]")]
        [Description("Explicit snapshot; omit to discover all configured ArtisanLogbook_Core.lua ledgers. Sources are never modified.")]
        public string? SourceFile { get; init; }

        [CommandOption("--verbose")]
        [Description("Show full paths, detailed import counts, and all diagnostics, including unchanged historical warnings.")]
        public bool Verbose { get; init; }

        public override ValidationResult Validate() =>
            SourceFile is not null && string.IsNullOrWhiteSpace(SourceFile)
                ? ValidationResult.Error("An explicit source file path must be nonempty.")
                : base.Validate();
    }

    public override async Task<int> ExecuteAsync(CommandContext context, ImportSettings settings)
    {
        DiscoveryResult discovered = new([], []);
        IReadOnlyList<string>? roots = null;
        IReadOnlyList<string> sources;
        if (settings.SourceFile is not null)
            sources = [paths.ResolveSource(settings.SourceFile)];
        else
        {
            SettingsLoadResult loaded = settingsStore.Load();
            if (loaded.Status != SettingsStatus.Loaded || loaded.Settings!.InstallationRoots.Count == 0)
            {
                console.MarkupLine($"[red]Configuration error:[/] {Markup.Escape(loaded.Diagnostic ??
                    "No installation is configured. Run artisanlogbook init.")}");
                return loaded.Status is SettingsStatus.Missing or SettingsStatus.Loaded ? ExitCodes.Usage : ExitCodes.Failed;
            }
            roots = loaded.Settings.InstallationRoots;
            discovered = discovery.DiscoverSavedVariables(roots);
            sources = discovered.Paths;
            if (sources.Count == 0)
            {
                DiscoveryReport.Write(console, discovered);
                console.MarkupLine("[red]No ArtisanLogbook_Core.lua ledgers found.[/] " +
                    "Check the installation roots and addon installation, then save in WoW by logging out or /reload. " +
                    "Run artisanlogbook init to review the configuration. No import performed.");
                return ExitCodes.Failed;
            }
        }
        string? database = null;
        List<(string Path, CompanionImportResult Result)> results = [];
        Store store;
        try
        {
            database = paths.ResolveDatabase(settings.Database);
            store = new(database);
        }
        catch (Exception exception) when (exception is DbException or IOException or UnauthorizedAccessException
            or SecurityException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            CompanionImportResult failure = new(CompanionImportOutcome.Failed,
                0, 0, 0, 0, 0, 0, 0, null, [], [], [], [], [], [],
                [new("history-store-open-failed", exception.Message)]);
            results.AddRange(sources.Select(source => (source, failure)));
            return Report();
        }
        using (store)
        {
            CompanionImportService importer = new(store);
            foreach (string source in sources)
                results.Add((source, await importer.ImportSavedVariablesFileAsync(source)));
        }
        return Report();

        int Report()
        {
            ImportPresentation presentation = new(results, discovered, roots);
            ImportReport.Write(console, presentation, database ?? settings.Database ?? "<unavailable>", settings.Verbose);
            return presentation.ExitCode;
        }
    }
}
