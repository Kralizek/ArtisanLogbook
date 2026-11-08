using System.Globalization;

using ArtisanLogbook.History;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.SavedVariables;

using Spectre.Console;

namespace ArtisanLogbook.Cli;

internal static class ImportReport
{
    public static void Write(IAnsiConsole console, ImportPresentation report, string database, bool verbose)
    {
        console.Write(new Rule("Artisan Logbook - Import").LeftJustified());
        DiscoveryReport.Write(console, report.Discovery);
        if (report.InstallationImport)
        {
            Table table = new Table().AddColumn("Source")
                .AddColumn(new TableColumn("New").RightAligned())
                .AddColumn(new TableColumn("Existing").RightAligned())
                .AddColumn(new TableColumn("Enriched").RightAligned()).AddColumn("Result");
            foreach (ImportSourcePresentation source in report.Sources)
                table.AddRow(Markup.Escape(source.Label), Count(source.Result.InsertedCrafts),
                    Count(source.Result.AlreadyPresentCrafts), Count(source.Result.EnrichedCrafts),
                    Outcome(source.Result.Outcome));
            console.Write(table);
        }
        else
            console.MarkupLine($"Source: {Markup.Escape(report.Sources.Single().Label)}");

        if (verbose) console.WriteLine($"Database: {database}");
        foreach (ImportSourcePresentation source in report.Sources)
        {
            CompanionImportResult result = source.Result;
            if (verbose || result.Outcome != CompanionImportOutcome.Successful)
            {
                console.WriteLine($"Source: {source.Path}");
                console.MarkupLine($"Import {Outcome(result.Outcome)}.");
                if (result.Outcome != CompanionImportOutcome.Successful)
                    console.WriteLine("No craft or dimension changes were committed for this file.");
            }
            if (verbose) Details(console, source);
            else
                foreach (SavedVariablesDiagnostic diagnostic in source.VisibleDiagnostics
                    .Where(diagnostic => diagnostic.Severity == SavedVariablesDiagnosticSeverity.Error))
                    SourceDiagnostic(console, diagnostic);
            Failures(console, result);
        }
        if (!verbose && report.DiagnosticGroups.Count > 0)
        {
            console.MarkupLine("[bold]Diagnostics[/]");
            foreach (ImportDiagnosticGroup group in report.DiagnosticGroups)
            {
                string description = group.Code switch
                {
                    "unknown-recipe" => "unknown recipe",
                    "legacy-identity-lineage" => "legacy identity metadata",
                    "legacy-outcome-coverage-corrected" => "historical outcome coverage correction",
                    "historical-recipe-schematic-variation" => "historical schematic variation",
                    "recipe-recovered" => "recovered recipe identity",
                    "partial-output" => "incomplete output evidence",
                    "recipe-reagent-slot-without-recipe" => "schematic evidence without recipe identity",
                    "unknown-recipe-reagent-slot" => "incomplete schematic slot evidence",
                    "aggregate-only-history" => "aggregate-only history; missing attempts were not recovered",
                    "missing-rollups" => "source without historical rollups",
                    _ => group.Code
                };
                string occurrence = group.Severity == SavedVariablesDiagnosticSeverity.Warning ? "warning" : "notice";
                Diagnostic(console, group.Severity.ToString(), group.Code,
                    $"{Count(group.Occurrences)} {description} {occurrence}{(group.Occurrences == 1 ? "" : "s")}" +
                    $" ({string.Join(", ", group.Sources)})");
                if (!KnownCode(group.Code))
                    foreach (ImportSourcePresentation source in report.Sources)
                        foreach (SavedVariablesDiagnostic diagnostic in source.VisibleDiagnostics.Where(diagnostic =>
                            diagnostic.Code == group.Code && diagnostic.Severity == group.Severity))
                            console.WriteLine($"  {source.Label}: {diagnostic.Location}: {diagnostic.Message}");
            }
        }
        if (report.ExitCode != ExitCodes.Success)
            console.MarkupLine("[yellow]Incomplete import" +
                (report.Sources.Any(source => source.Result.Outcome == CompanionImportOutcome.Successful)
                    ? " (partial success)" : "") +
                ".[/] Valid files remain committed; review the affected sources and retry.");
        else
            console.MarkupLine(report.HasChanges ? "[green]Import complete.[/]" : "[green]Import complete - no changes.[/]");
        console.WriteLine(report.Inserted > 0
            ? $"{Count(report.Inserted)} new crafts preserved / {Count(report.Existing)} existing / {Count(report.Enriched)} enriched"
            : $"{Count(report.Existing)} existing crafts / {Count(report.Inserted)} new / {Count(report.Enriched)} enriched");
        if (verbose && report.InstallationImport) Totals(console, report);
    }

    private static bool KnownCode(string code) => code is
        "unknown-recipe" or "legacy-identity-lineage" or "legacy-outcome-coverage-corrected" or
        "historical-recipe-schematic-variation" or "recipe-recovered" or "partial-output" or
        "recipe-reagent-slot-without-recipe" or "unknown-recipe-reagent-slot" or "aggregate-only-history" or "missing-rollups";

    private static string Count(long count) => count.ToString("N0", CultureInfo.InvariantCulture);

    private static string Outcome(CompanionImportOutcome outcome) => outcome switch
    {
        CompanionImportOutcome.Successful => "[green]successful[/]",
        CompanionImportOutcome.Rejected => "[red]rejected[/]",
        CompanionImportOutcome.Failed => "[red]failed[/]",
        _ => throw new InvalidOperationException($"Unexpected import outcome: {outcome}.")
    };

    private static void Details(IAnsiConsole console, ImportSourcePresentation source)
    {
        CompanionImportResult result = source.Result;
        Table table = new Table().AddColumn("Import report").AddColumn("Count");
        Add("Observed source crafts", result.TotalSourceCraftObservations);
        Add("Inserted crafts", result.InsertedCrafts);
        Add("Already-present crafts", result.AlreadyPresentCrafts);
        Add("Enriched crafts", result.EnrichedCrafts);
        Add("Rejected/conflicting crafts", result.RejectedOrConflictingCrafts);
        Add("Inserted dimensions", result.DimensionsInserted);
        Add("Enriched dimensions", result.DimensionsEnriched);
        Add("Diagnostics suppressed in normal output", source.SuppressedDiagnostics.Count);
        console.Write(table);
        foreach (SavedVariablesDiagnostic diagnostic in source.Diagnostics) SourceDiagnostic(console, diagnostic);
        if (result.Coverage is { HasPrunedHistory: true } coverage)
            console.WriteLine($"Aggregate-only history: {Count(coverage.AggregateOnlyCraftCount)} attempts lack retained detail. " +
                "These are not canonical crafts and were not recovered.");
        void Add(string label, long count) => table.AddRow(label, Count(count));
    }

    private static void Totals(IAnsiConsole console, ImportPresentation report)
    {
        Table table = new Table().AddColumn("Installation import totals").AddColumn("Count");
        Add("Discovered files", report.Sources.Count);
        Add("Successful files", report.Sources.Count(source => source.Result.Outcome == CompanionImportOutcome.Successful));
        Add("Rejected files", report.Sources.Count(source => source.Result.Outcome == CompanionImportOutcome.Rejected));
        Add("Failed files", report.Sources.Count(source => source.Result.Outcome == CompanionImportOutcome.Failed));
        Add("Discovery errors", report.Discovery.Diagnostics.Count(diagnostic => diagnostic.Severity == Runtime.DiscoverySeverity.Error));
        Add("Discovery warnings", report.Discovery.Diagnostics.Count(diagnostic => diagnostic.Severity == Runtime.DiscoverySeverity.Warning));
        Add("Committed inserted crafts", report.Inserted);
        Add("Committed already-present crafts", report.Existing);
        Add("Committed enriched crafts", report.Enriched);
        console.Write(table);
        void Add(string label, long count) => table.AddRow(label, Count(count));
    }

    private static void Failures(IAnsiConsole console, CompanionImportResult result)
    {
        foreach (CompanionImportDiagnostic diagnostic in result.InputDiagnostics.Concat(result.PersistenceDiagnostics))
            Diagnostic(console, "Error", diagnostic.Code, diagnostic.Message);
        foreach (HistoryValidationError error in result.ValidationErrors)
            Diagnostic(console, "Error", error.Field, $"{Identity(error.Identity)}{error.Message}");
        foreach (HistoryConflict conflict in result.CraftConflicts)
            Diagnostic(console, "Conflict", conflict.Field, $"{Identity(conflict.Identity)}{conflict.Description}");
        foreach (DimensionConflict conflict in result.DimensionConflicts)
            Diagnostic(console, "Conflict", conflict.Dimension, $"{conflict.Key}: {conflict.Message}");
        if (result.PersistenceDiagnostics.Count > 0)
            console.WriteLine("If the database is locked, close other Companion/DuckDB processes using it and retry. " +
                "Do not delete the database or its WAL file.");
    }

    private static string Identity(CraftIdentity? identity) => identity is null ? "" :
        $"Observation ({identity.Origin}, {identity.Observation}): ";

    private static void SourceDiagnostic(IAnsiConsole console, SavedVariablesDiagnostic diagnostic) =>
        Diagnostic(console, diagnostic.Severity.ToString(), diagnostic.Code,
            $"{diagnostic.Location}: {diagnostic.Message}");

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
