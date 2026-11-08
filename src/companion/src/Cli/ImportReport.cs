using System.Globalization;

using ArtisanLogbook.History;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.SavedVariables;

using Spectre.Console;

namespace ArtisanLogbook.Cli;

internal static class ImportReport
{
    public static void Write(IAnsiConsole console, CompanionImportResult result)
    {
        string color = result.Outcome == CompanionImportOutcome.Successful ? "green" : "red";
        console.MarkupLine($"[{color}]Import {result.Outcome.ToString().ToLowerInvariant()}.[/]");
        if (result.Outcome != CompanionImportOutcome.Successful)
            console.WriteLine("No craft or dimension changes were committed.");

        Table table = new Table().AddColumn("Import report").AddColumn("Count");
        Add("Observed source crafts", result.TotalSourceCraftObservations);
        Add("Inserted crafts", result.InsertedCrafts);
        Add("Already-present crafts", result.AlreadyPresentCrafts);
        Add("Enriched crafts", result.EnrichedCrafts);
        Add("Rejected/conflicting crafts", result.RejectedOrConflictingCrafts);
        Add("Inserted dimensions", result.DimensionsInserted);
        Add("Enriched dimensions", result.DimensionsEnriched);
        console.Write(table);

        foreach (SavedVariablesDiagnostic diagnostic in result.SourceDiagnostics)
            Diagnostic(console, diagnostic.Severity.ToString(), diagnostic.Code,
                $"{diagnostic.Location}: {diagnostic.Message}");
        foreach (SavedVariablesDiagnostic diagnostic in result.CoverageWarnings.Except(result.SourceDiagnostics))
            Diagnostic(console, "Warning", diagnostic.Code, diagnostic.Message);
        foreach (CompanionImportDiagnostic diagnostic in result.InputDiagnostics.Concat(result.PersistenceDiagnostics))
            Diagnostic(console, "Error", diagnostic.Code, diagnostic.Message);
        foreach (HistoryValidationError error in result.ValidationErrors)
            Diagnostic(console, "Error", error.Field, error.Message);
        foreach (HistoryConflict conflict in result.CraftConflicts)
            Diagnostic(console, "Conflict", conflict.Field, conflict.Description);
        foreach (DimensionConflict conflict in result.DimensionConflicts)
            Diagnostic(console, "Conflict", conflict.Dimension, conflict.Message);

        if (result.Coverage is { HasPrunedHistory: true } coverage)
            console.MarkupLine("[yellow]Aggregate-only history: " +
                $"{coverage.AggregateOnlyCraftCount.ToString(CultureInfo.InvariantCulture)} attempts lack retained detail. " +
                "These are not canonical crafts and were not recovered.[/]");

        void Add(string label, int count) => table.AddRow(label, count.ToString(CultureInfo.InvariantCulture));
    }

    private static void Diagnostic(IAnsiConsole console, string severity, string code, string message)
    {
        string color = severity switch
        {
            "Error" or "Conflict" => "red",
            "Warning" => "yellow",
            _ => "grey"
        };
        console.MarkupLine($"[{color}]{Markup.Escape(severity)} ({Markup.Escape(code)}):[/] {Markup.Escape(message)}");
    }
}
