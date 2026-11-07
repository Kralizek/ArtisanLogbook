using System.ComponentModel;

using ArtisanLogbook.ImportService;

using Spectre.Console;
using Spectre.Console.Cli;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Cli.Commands;

public sealed class ImportCommand(ApplicationPaths paths, IAnsiConsole console)
    : AsyncCommand<ImportCommand.ImportSettings>
{
    public sealed class ImportSettings : DatabaseSettings
    {
        [CommandArgument(0, "<SOURCE-FILE>")]
        [Description("SavedVariables snapshot to import; the source is never modified.")]
        public string SourceFile { get; init; } = null!;

        public override ValidationResult Validate() =>
            string.IsNullOrWhiteSpace(SourceFile)
                ? ValidationResult.Error("A nonempty source file path is required.")
                : base.Validate();
    }

    public override async Task<int> ExecuteAsync(
        CommandContext context, ImportSettings settings)
    {
        string source = paths.ResolveSource(settings.SourceFile);
        string database = paths.ResolveDatabase(settings.Database);
        console.WriteLine($"Source: {source}");
        console.WriteLine($"Database: {database}");
        using Store store = new(database);
        CompanionImportResult result = await new CompanionImportService(store)
            .ImportSavedVariablesFileAsync(source);
        ImportReport.Write(console, result);
        return result.Outcome switch
        {
            CompanionImportOutcome.Successful => ExitCodes.Success,
            CompanionImportOutcome.Rejected => ExitCodes.Rejected,
            CompanionImportOutcome.Failed => ExitCodes.Failed,
            _ => throw new InvalidOperationException($"Unexpected import outcome: {result.Outcome}.")
        };
    }
}
