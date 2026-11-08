using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;
using ArtisanLogbook.SavedVariables;

namespace ArtisanLogbook.Cli;

internal sealed record ImportSourcePresentation(
    string Path, string Label, CompanionImportResult Result,
    IReadOnlyList<SavedVariablesDiagnostic> Diagnostics,
    IReadOnlyList<SavedVariablesDiagnostic> VisibleDiagnostics,
    IReadOnlyList<SavedVariablesDiagnostic> SuppressedDiagnostics);

internal sealed record ImportDiagnosticGroup(
    SavedVariablesDiagnosticSeverity Severity, string Code, int Occurrences, IReadOnlyList<string> Sources);

/// <summary>Presentation policy over committed facts; independent of terminal rendering.</summary>
internal sealed class ImportPresentation
{
    public IReadOnlyList<ImportSourcePresentation> Sources { get; }
    public DiscoveryResult Discovery { get; }
    public bool InstallationImport { get; }
    public long Inserted => Sources.Sum(source => (long)source.Result.InsertedCrafts);
    public long Existing => Sources.Sum(source => (long)source.Result.AlreadyPresentCrafts);
    public long Enriched => Sources.Sum(source => (long)source.Result.EnrichedCrafts);
    public bool HasChanges => Inserted > 0 || Enriched > 0 ||
        Sources.Any(source => source.Result.DimensionsInserted > 0 || source.Result.DimensionsEnriched > 0);
    public int ExitCode => Discovery.HasErrors || Sources.Any(source => source.Result.Outcome == CompanionImportOutcome.Failed)
        ? ExitCodes.Failed
        : Sources.Any(source => source.Result.Outcome == CompanionImportOutcome.Rejected)
            ? ExitCodes.Rejected : ExitCodes.Success;
    public IReadOnlyList<ImportDiagnosticGroup> DiagnosticGroups { get; }

    public ImportPresentation(
        IReadOnlyList<(string Path, CompanionImportResult Result)> results,
        DiscoveryResult discovery, IReadOnlyList<string>? installationRoots = null)
    {
        Discovery = discovery;
        InstallationImport = installationRoots is not null;
        string[] labels = Labels(results.Select(result => result.Path).ToArray(), installationRoots);
        Sources = results.Select((entry, index) =>
        {
            SavedVariablesDiagnostic[] diagnostics = AllDiagnostics(entry.Result);
            Dictionary<CraftIdentity, CraftWriteResult> observations = entry.Result.Observations
                .Where(result => result.Observation is not null)
                .ToDictionary(result => result.Observation!.Identity);
            SavedVariablesDiagnostic[] visible = diagnostics.Where(diagnostic =>
                IsVisible(diagnostic, entry.Result, observations)).ToArray();
            return new ImportSourcePresentation(entry.Path, labels[index], entry.Result, diagnostics,
                visible, diagnostics.Where(diagnostic => !IsVisible(diagnostic, entry.Result, observations)).ToArray());
        }).ToArray();
        DiagnosticGroups = Sources.SelectMany(source => source.VisibleDiagnostics
                .Where(diagnostic => diagnostic.Severity != SavedVariablesDiagnosticSeverity.Error)
                .Select(diagnostic => (source.Label, Diagnostic: diagnostic)))
            .GroupBy(entry => (entry.Diagnostic.Severity, entry.Diagnostic.Code))
            .OrderByDescending(group => group.Key.Severity).ThenBy(group => group.Key.Code, StringComparer.Ordinal)
            .Select(group => new ImportDiagnosticGroup(group.Key.Severity, group.Key.Code, group.Count(),
                group.Select(entry => entry.Label).Distinct(StringComparer.Ordinal).ToArray())).ToArray();
    }

    private static SavedVariablesDiagnostic[] AllDiagnostics(CompanionImportResult result)
    {
        // CoverageWarnings is a second view of source occurrences, not an additional occurrence.
        Dictionary<SavedVariablesDiagnostic, int> remaining = result.SourceDiagnostics
            .GroupBy(diagnostic => diagnostic).ToDictionary(group => group.Key, group => group.Count());
        List<SavedVariablesDiagnostic> diagnostics = [.. result.SourceDiagnostics];
        foreach (SavedVariablesDiagnostic diagnostic in result.CoverageWarnings)
        {
            if (remaining.TryGetValue(diagnostic, out int count) && count > 0)
                remaining[diagnostic] = count - 1;
            else
                diagnostics.Add(diagnostic);
        }
        return diagnostics.ToArray();
    }

    private static bool IsVisible(
        SavedVariablesDiagnostic diagnostic, CompanionImportResult result,
        IReadOnlyDictionary<CraftIdentity, CraftWriteResult> observations)
    {
        if (result.Outcome != CompanionImportOutcome.Successful ||
            diagnostic.Severity == SavedVariablesDiagnosticSeverity.Error)
            return true;
        if (diagnostic.Scope == SavedVariablesDiagnosticScope.Ledger)
            return result.InsertedCrafts > 0 || result.EnrichedCrafts > 0 ||
                result.DimensionsInserted > 0 || result.DimensionsEnriched > 0 ||
                result.TotalSourceCraftObservations == 0;
        if (diagnostic.Scope != SavedVariablesDiagnosticScope.Observation ||
            diagnostic.ObservationIdentity is null ||
            !observations.TryGetValue(diagnostic.ObservationIdentity, out CraftWriteResult? observation))
            return true;
        return observation.Status switch
        {
            CraftWriteStatus.Inserted => true,
            CraftWriteStatus.AlreadyPresent => false,
            CraftWriteStatus.Enriched => RelevantToEnrichment(diagnostic.Code, observation),
            _ => true
        };
    }

    private static bool RelevantToEnrichment(string code, CraftWriteResult result)
    {
        if (result.PreviousObservation is not { } before || result.Observation is not { } after)
            return true;
        return code switch
        {
            "unknown-recipe" or "recipe-recovered" => before.RecipeId != after.RecipeId,
            "partial-output" => before.OutputsComplete != after.OutputsComplete ||
                !SameRows(before.Outputs, after.Outputs, output => (output.ItemId, output.Quality, output.Quantity)) ||
                !SameEvidence(before.OutputEvidence, after.OutputEvidence),
            "invalid-reagent-item" or "invalid-reagent-allocation" or "invalid-reagent-return" =>
                before.InputsComplete != after.InputsComplete ||
                before.ResourcefulnessComplete != after.ResourcefulnessComplete ||
                !SameRows(before.Reagents, after.Reagents,
                    reagent => (reagent.ItemId, reagent.AllocatedQuantity, reagent.ReturnedQuantity)),
            "historical-recipe-schematic-variation" or "unknown-recipe-reagent-slot" or
                "recipe-reagent-slot-without-recipe" =>
                before.RecipeId != after.RecipeId || !SameEvidence(before.RecipeSchematicEvidence, after.RecipeSchematicEvidence),
            _ => true
        };
    }

    // Match C01's order-independent canonical row equality without discarding occurrences.
    private static bool SameRows<T, TKey>(
        IReadOnlyList<T>? before, IReadOnlyList<T>? after, Func<T, TKey> key)
        where TKey : IComparable<TKey> =>
        before is null || after is null ? before is null && after is null :
            before.Select(key).Order().SequenceEqual(after.Select(key).Order());

    // C03 compares persisted evidence sequences, including C01's ordered callback equality.
    private static bool SameEvidence<T>(IReadOnlyList<T>? before, IReadOnlyList<T>? after) =>
        before is null || after is null ? before is null && after is null : before.SequenceEqual(after);

    private static string[] Labels(IReadOnlyList<string> paths, IReadOnlyList<string>? roots)
    {
        if (roots is null) return paths.Select(path => Path.GetFileName(path)).ToArray();
        string[] orderedRoots = roots.Select(root => Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)))
            .Distinct(InstallationDiscovery.PathComparer).Order(InstallationDiscovery.PathComparer).ToArray();
        var contexts = paths.Select(path =>
        {
            int rootIndex = orderedRoots.Select((root, index) => (Root: root, Index: index))
                .Where(entry => path.StartsWith(Path.EndsInDirectorySeparator(entry.Root)
                    ? entry.Root : entry.Root + Path.DirectorySeparatorChar,
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                .OrderByDescending(entry => entry.Root.Length).Select(entry => entry.Index).DefaultIfEmpty(-1).First();
            string[] parts = rootIndex < 0 ? [] :
                Path.GetRelativePath(orderedRoots[rootIndex], path).Split(Path.DirectorySeparatorChar);
            string flavor = parts.Length > 0 ? parts[0] : path;
            string label = flavor switch
            {
                "_retail_" => "Retail",
                "_forever_" => "Forever",
                _ => flavor
            };
            return (Label: label, Account: parts.Length > 3 ? parts[3] : "", Root: rootIndex + 1);
        }).ToArray();
        return contexts.Select(context =>
        {
            bool sharedFlavor = contexts.Count(other => other.Label == context.Label) > 1;
            string label = sharedFlavor ? $"{context.Label} / {context.Account}" : context.Label;
            return sharedFlavor && contexts.Count(other =>
                other.Label == context.Label && other.Account == context.Account) > 1
                ? $"{label} (installation {context.Root})" : label;
        }).ToArray();
    }
}
