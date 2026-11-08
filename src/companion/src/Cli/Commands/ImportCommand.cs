using System.ComponentModel;
using System.Globalization;

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

        public override ValidationResult Validate() =>
            SourceFile is not null && string.IsNullOrWhiteSpace(SourceFile)
                ? ValidationResult.Error("An explicit source file path must be nonempty.")
                : base.Validate();
    }

    public override async Task<int> ExecuteAsync(
        CommandContext context, ImportSettings settings)
    {
        if (settings.SourceFile is null)
            return await ImportInstallations(settings);
        string source = paths.ResolveSource(settings.SourceFile);
        string database = paths.ResolveDatabase(settings.Database);
        console.WriteLine($"Source: {source}");
        console.WriteLine($"Database: {database}");
        using Store store = new(database);
        CompanionImportResult result = await new CompanionImportService(store)
            .ImportSavedVariablesFileAsync(source);
        ImportReport.Write(console, result);
        return OutcomeExit(result.Outcome);
    }

    private async Task<int> ImportInstallations(ImportSettings settings)
    {
        SettingsLoadResult loaded = settingsStore.Load();
        if (loaded.Status != SettingsStatus.Loaded || loaded.Settings!.InstallationRoots.Count == 0)
        {
            console.MarkupLine($"[red]Configuration error:[/] {Markup.Escape(loaded.Diagnostic ??
                "No installation is configured. Run artisanlogbook init.")}");
            return loaded.Status is SettingsStatus.Missing or SettingsStatus.Loaded ? ExitCodes.Usage : ExitCodes.Failed;
        }
        DiscoveryResult discovered = discovery.DiscoverSavedVariables(loaded.Settings.InstallationRoots);
        DiscoveryReport.Write(console, discovered);
        if (discovered.Paths.Count == 0)
        {
            console.MarkupLine("[red]No ArtisanLogbook_Core.lua ledgers found.[/] " +
                "Check the installation roots and addon installation, then save in WoW by logging out or /reload. " +
                "Run artisanlogbook init to review the configuration. No import performed.");
            return ExitCodes.Failed;
        }
        Table sources = new Table().AddColumn("Discovered sources");
        foreach (string path in discovered.Paths) sources.AddRow(Markup.Escape(path));
        console.Write(sources);
        string database = paths.ResolveDatabase(settings.Database);
        console.WriteLine($"Database: {database}");
        using Store store = new(database);
        CompanionImportService importer = new(store);
        List<CompanionImportResult> results = [];
        foreach (string source in discovered.Paths)
        {
            console.WriteLine($"Source: {source}");
            CompanionImportResult result = await importer.ImportSavedVariablesFileAsync(source);
            ImportReport.Write(console, result);
            results.Add(result);
        }
        int successful = results.Count(result => result.Outcome == CompanionImportOutcome.Successful);
        int rejected = results.Count(result => result.Outcome == CompanionImportOutcome.Rejected);
        int failed = results.Count(result => result.Outcome == CompanionImportOutcome.Failed);
        Table totals = new Table().AddColumn("Installation import totals").AddColumn("Count");
        Add("Discovered files", results.Count);
        Add("Successful files", successful);
        Add("Rejected files", rejected);
        Add("Failed files", failed);
        Add("Discovery errors", discovered.Diagnostics.Count(diagnostic => diagnostic.Severity == DiscoverySeverity.Error));
        Add("Discovery warnings", discovered.Diagnostics.Count(diagnostic => diagnostic.Severity == DiscoverySeverity.Warning));
        Add("Committed inserted crafts", results.Sum(result => (long)result.InsertedCrafts));
        Add("Committed already-present crafts", results.Sum(result => (long)result.AlreadyPresentCrafts));
        Add("Committed enriched crafts", results.Sum(result => (long)result.EnrichedCrafts));
        console.Write(totals);
        bool partial = rejected > 0 || failed > 0 || discovered.Diagnostics.Count > 0;
        console.MarkupLine(partial
            ? "[yellow]Incomplete installation import" + (successful > 0 ? " (partial success)" : "") +
                ".[/] Valid files remain committed; review individual diagnostics and retry."
            : "[green]Installation import complete.[/]");
        return failed > 0 || discovered.Diagnostics.Count > 0 ? ExitCodes.Failed :
            rejected > 0 ? ExitCodes.Rejected : ExitCodes.Success;

        void Add(string label, long count) => totals.AddRow(label, count.ToString(CultureInfo.InvariantCulture));
    }

    private static int OutcomeExit(CompanionImportOutcome outcome) => outcome switch
    {
        CompanionImportOutcome.Successful => ExitCodes.Success,
        CompanionImportOutcome.Rejected => ExitCodes.Rejected,
        CompanionImportOutcome.Failed => ExitCodes.Failed,
        _ => throw new InvalidOperationException($"Unexpected import outcome: {outcome}.")
    };
}
