using System.Globalization;
using System.Text.RegularExpressions;

using ArtisanLogbook.Cli;
using ArtisanLogbook.History;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

using Spectre.Console.Testing;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

[TestFixture]
public sealed class ImportReportingTests
{
    private string _directory = null!;
    private string _database = null!;
    private ApplicationPaths _paths = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Reporting.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _database = Path.Combine(_directory, "history.duckdb");
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public async Task FirstImportReplayAndVerboseRetainEvidenceWithoutNormalNoise()
    {
        string source = Path.Combine(_directory, "snapshot.lua");
        string content = Snapshot(2);
        await File.WriteAllTextAsync(source, content);
        byte[] original = await File.ReadAllBytesAsync(source);
        (int firstExit, string first) = await Run(false, source);
        Assert.That(firstExit, Is.Zero, first);
        Assert.That(first, Does.Contain("2 new crafts preserved").And.Contain("2 unknown recipe")
            .And.Contain("1 legacy identity metadata warning")
            .And.Not.Contain("Observed source crafts").And.Not.Contain(_directory));
        (int repeatExit, string repeat) = await Run(false, source);
        Assert.That(repeatExit, Is.EqualTo(firstExit));
        Assert.That(repeat, Does.Contain("no changes").And.Contain("2 existing crafts")
            .And.Not.Contain("Warning").And.Not.Contain("Diagnostics").And.Not.Contain(_directory));
        Assert.That(repeat.Split('\n'), Has.Length.LessThan(9));
        (int verboseExit, string verbose) = await Run(true, source);
        Assert.That(verboseExit, Is.EqualTo(repeatExit));
        Assert.That(verbose, Does.Contain(source).And.Contain(_database).And.Contain("Observed source crafts")
            .And.Contain("Inserted dimensions").And.Contain("unknown-recipe")
            .And.Contain("ArtisanLogbookDB.crafts[id=1].recipeId").And.Contain("legacy-identity-lineage")
            .And.Contain("Recipe identity was not recorded"));
        using Store store = new(_database);
        CompanionImportResult result = await new CompanionImportService(store).ImportSavedVariablesAsync(content);
        Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
        ImportPresentation model = Present(result);
        Assert.That(model.Sources.Single().VisibleDiagnostics, Is.Empty);
        Assert.That(model.Sources.Single().SuppressedDiagnostics, Has.Count.EqualTo(result.SourceDiagnostics.Count));
        Assert.That(result.Observations, Has.Count.EqualTo(2));
        Assert.That(result.SourceDiagnostics.Where(diagnostic => diagnostic.Code == "unknown-recipe")
            .Select(diagnostic => diagnostic.ObservationIdentity),
            Is.EquivalentTo(store.ReadAll().Select(craft => craft.Identity)));
        Assert.That(await File.ReadAllBytesAsync(source), Is.EqualTo(original));
    }

    [Test]
    public async Task MixedSnapshotUsesCanonicalIdentityNotLocalCraftIdOrFormattedLocation()
    {
        using Store store = new(_database);
        CompanionImportService importer = new(store);
        Assert.That((await importer.ImportSavedVariablesAsync(Snapshot(2))).InsertedCrafts, Is.EqualTo(2));
        CompanionImportResult mixed = await importer.ImportSavedVariablesAsync(Snapshot(3));
        ImportPresentation model = Present(mixed);
        Assert.Multiple(() =>
        {
            Assert.That(model.Inserted, Is.EqualTo(1));
            Assert.That(model.Existing, Is.EqualTo(2));
            Assert.That(model.DiagnosticGroups.Single(group => group.Code == "unknown-recipe").Occurrences, Is.EqualTo(1));
            Assert.That(model.Sources.Single().SuppressedDiagnostics.Count(diagnostic => diagnostic.Code == "unknown-recipe"),
                Is.EqualTo(2));
        });
        CompanionImportResult otherOrigin = await importer.ImportSavedVariablesAsync(Snapshot(1, origin: "sanitized-other"));
        Assert.That(otherOrigin.InsertedCrafts, Is.EqualTo(1));
        Assert.That(Present(otherOrigin).DiagnosticGroups.Single(group => group.Code == "unknown-recipe").Occurrences, Is.EqualTo(1));
        Assert.That(store.ReadAll().Count(craft => craft.Identity.Observation == "1"), Is.EqualTo(2));
        Assert.That(otherOrigin.SourceDiagnostics.Single(diagnostic => diagnostic.Code == "unknown-recipe")
            .ObservationIdentity, Is.EqualTo(new CraftIdentity("sanitized-other", "1")));
    }

    [Test]
    public async Task EnrichmentPreservesOneCraftAndDoesNotRepeatUnrelatedUnknownRecipeWarning()
    {
        using Store store = new(_database);
        CompanionImportService importer = new(store);
        await importer.ImportSavedVariablesAsync(Snapshot(1));
        CompanionImportResult enriched = await importer.ImportSavedVariablesAsync(Snapshot(1, extra: "concentrationSpent = 5,"));
        Assert.That(enriched.InsertedCrafts, Is.Zero);
        Assert.That(enriched.EnrichedCrafts, Is.EqualTo(1));
        Assert.That(enriched.Observations.Single().PreviousObservation!.ConcentrationSpent, Is.Null);
        Assert.That(enriched.Observations.Single().Observation!.ConcentrationSpent, Is.EqualTo(5));
        Assert.That(Present(enriched).DiagnosticGroups.Any(group => group.Code == "unknown-recipe"), Is.False);
        Assert.That(store.ReadAll(), Has.Count.EqualTo(1));
        CompanionImportResult replay = await importer.ImportSavedVariablesAsync(Snapshot(1, extra: "concentrationSpent = 5,"));
        Assert.That(replay.AlreadyPresentCrafts, Is.EqualTo(1));
        Assert.That(Present(replay).Sources.Single().VisibleDiagnostics, Is.Empty);
    }

    [Test]
    public async Task Sanitized2732ObservationReplayPreservesHistoryAcrossRetailAndForever()
    {
        using Store store = new(_database);
        CompanionImportService importer = new(store);
        string retail = Snapshot(2702, project: 1, unknownRecipes: 44);
        string forever = Snapshot(30, project: 18, unknownRecipes: 0);
        Assert.That((await importer.ImportSavedVariablesAsync(retail)).InsertedCrafts, Is.EqualTo(2702));
        Assert.That((await importer.ImportSavedVariablesAsync(forever)).InsertedCrafts, Is.EqualTo(30));
        IReadOnlyList<CraftObservation> before = store.ReadAll();
        foreach ((string source, int count) in new[] { (retail, 2702), (forever, 30) })
        {
            CompanionImportResult replay = await importer.ImportSavedVariablesAsync(source);
            Assert.Multiple(() =>
            {
                Assert.That(replay.InsertedCrafts, Is.Zero);
                Assert.That(replay.EnrichedCrafts, Is.Zero);
                Assert.That(replay.RejectedOrConflictingCrafts, Is.Zero);
                Assert.That(replay.AlreadyPresentCrafts, Is.EqualTo(count));
                Assert.That(Present(replay).Sources.Single().VisibleDiagnostics, Is.Empty);
            });
        }
        Assert.That(store.ReadAll(), Is.EqualTo(before));
        Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(2732));
    }

    [Test]
    public async Task HistoricalSchematicOccurrencesAreAttributedAndOnlyNewVariationsRemainVisible()
    {
        using Store store = new(_database);
        CompanionImportService importer = new(store);
        static string SnapshotWithSchematics(int count) => Snapshot(count, unknownRecipes: 0, perCraft: id =>
            "reagentRequirements = { { source = \"schematic\", dataSlotIndex = 1, requiredQuantity = " +
            id.ToString(CultureInfo.InvariantCulture) + ", candidateItemIDs = { 99 } } },");
        CompanionImportResult first = await importer.ImportSavedVariablesAsync(SnapshotWithSchematics(2));
        Assert.That(first.InsertedCrafts, Is.EqualTo(2));
        SavedVariablesDiagnostic variation = first.SourceDiagnostics.Single(diagnostic =>
            diagnostic.Code == "historical-recipe-schematic-variation");
        Assert.That(variation.Scope, Is.EqualTo(SavedVariablesDiagnosticScope.Observation));
        Assert.That(variation.ObservationIdentity, Is.EqualTo(first.Observations[1].Observation!.Identity));
        CompanionImportResult replay = await importer.ImportSavedVariablesAsync(SnapshotWithSchematics(2));
        Assert.That(Present(replay).Sources.Single().VisibleDiagnostics, Is.Empty);
        Assert.That(Regex.Replace(Render(Present(replay), true), @"\s+", " "), Does.Contain(variation.Message));
        CompanionImportResult mixed = await importer.ImportSavedVariablesAsync(SnapshotWithSchematics(3));
        Assert.That(mixed.InsertedCrafts, Is.EqualTo(1));
        Assert.That(mixed.AlreadyPresentCrafts, Is.EqualTo(2));
        Assert.That(Present(mixed).DiagnosticGroups.Single(group =>
            group.Code == "historical-recipe-schematic-variation").Occurrences, Is.EqualTo(1));
        Assert.That(store.ReadAll().All(craft => craft.RecipeSchematicEvidence?.Count == 1), Is.True);
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task MultipleRootsFlavorsAndAccountsHaveCompactDistinctLabelsAndCanonicalSourceContexts(bool verbose)
    {
        string rootA = Path.Combine(_directory, "installation-a");
        string rootB = Path.Combine(_directory, "installation-b");
        string[] sources =
        [
            await Ledger(rootA, "_retail_", "Sanitized-A", Snapshot(1, project: 18)),
            await Ledger(rootA, "_retail_", "Sanitized-B", Snapshot(1, project: 2)),
            await Ledger(rootB, "_retail_", "Sanitized-A", Snapshot(1, project: 1)),
            await Ledger(rootB, "_forever_", "Sanitized-A", Snapshot(1, project: 3))
        ];
        new CompanionSettingsStore(_paths).Save(CompanionSettings.ForRoots(rootB, rootA));
        (int exit, string output) = await Run(verbose);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Contain("Retail / Sanitized-A (installation 1)")
            .And.Contain("Retail / Sanitized-A (installation 2)").And.Contain("Retail / Sanitized-B")
            .And.Contain("Forever").And.Contain("4 new crafts preserved"));
        Assert.That(output.Contains(_directory, StringComparison.Ordinal), Is.EqualTo(verbose));
        Assert.That(output.Contains("Installation import totals", StringComparison.Ordinal), Is.EqualTo(verbose));
        if (verbose)
            Assert.That(output.IndexOf("Installation import totals", StringComparison.Ordinal),
                Is.LessThan(output.LastIndexOf("Import complete", StringComparison.Ordinal)),
                "The final outcome must follow the verbose installation totals.");
        (exit, output) = await Run(verbose);
        Assert.That(exit, Is.Zero, output);
        Assert.That(output, Does.Contain("no changes").And.Contain("4 existing crafts"));
        Assert.That(output.Contains("Warning", StringComparison.Ordinal), Is.EqualTo(verbose));
        if (verbose)
        {
            Assert.That(output.IndexOf("Installation import totals", StringComparison.Ordinal),
                Is.LessThan(output.LastIndexOf("Import complete", StringComparison.Ordinal)));
            Assert.That(output.TrimEnd(), Does.EndWith("4 existing crafts / 0 new / 0 enriched"));
        }
        using Store store = new(_database, readOnly: true);
        Assert.That(store.ReadStatus().Contexts.Select(context => (int)context.Game.Project),
            Is.EquivalentTo(new[] { 1, 18, 2, 3 }));
        Assert.That(sources, Has.Length.EqualTo(4));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task RejectedAndSuccessfulFilesKeepIndependentCommitsAndActionableFailures(bool verbose)
    {
        string root = Path.Combine(_directory, "installation");
        await Ledger(root, "a-valid", "Sanitized", Snapshot(1));
        string rejected = await Ledger(root, "b-invalid", "Sanitized", "ArtisanLogbookDB = {");
        await Ledger(root, "c-valid", "Sanitized", Snapshot(1, project: 18));
        new CompanionSettingsStore(_paths).Save(CompanionSettings.ForRoots(root));
        for (int iteration = 0; iteration < 2; iteration++)
        {
            (int exit, string output) = await Run(verbose);
            Assert.That(exit, Is.EqualTo(ExitCodes.Rejected));
            Assert.That(output, Does.Contain(rejected).And.Contain("malformed-lua").And.Contain("Import rejected")
                .And.Contain("No craft or dimension changes were committed for this file")
                .And.Contain("partial success").And.Contain("Valid files remain committed"));
        }
        using Store store = new(_database, readOnly: true);
        Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(2));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task PersistentSourceValidationAndConflictsAreNeverSuppressed(bool verbose)
    {
        string source = Path.Combine(_directory, "snapshot.lua");
        await File.WriteAllTextAsync(source, Snapshot(1, extra: "concentrationSpent = 5,"));
        Assert.That((await Run(verbose, source)).Exit, Is.Zero);
        foreach ((string content, string code) in new[]
        {
            (Snapshot(1, extra: "concentrationSpent = 6,"), "Conflict (ConcentrationSpent)"),
            (Snapshot(1, extra: "concentrationSpent = -1,"), "invalid-canonical-history")
        })
        {
            await File.WriteAllTextAsync(source, content);
            for (int iteration = 0; iteration < 2; iteration++)
            {
                (int exit, string output) = await Run(verbose, source);
                Assert.That(exit, Is.EqualTo(ExitCodes.Rejected), output);
                Assert.That(output, Does.Contain(code).And.Contain(source).And.Contain("No craft or dimension changes"));
            }
        }
        using Store store = new(_database, readOnly: true);
        Assert.That(store.ReadAll().Single().ConcentrationSpent, Is.EqualTo(5));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task SourceReadAndDatabaseOpenFailuresAlwaysIdentifyFileAndNoCommit(bool verbose)
    {
        string source = Path.Combine(_directory, "snapshot.lua");
        (int exit, string output) = await Run(verbose, source);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed));
        Assert.That(output, Does.Contain(source).And.Contain("source-read-failed").And.Contain("No craft or dimension changes"));
        await File.WriteAllTextAsync(source, Snapshot(1));
        File.Delete(_database);
        await File.WriteAllTextAsync(_database, "not a database");
        (exit, output) = await Run(verbose, source);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed));
        Assert.That(output, Does.Contain(source).And.Contain("history-store-open-failed").And.Contain("No craft or dimension changes"));
        Assert.That(await File.ReadAllTextAsync(_database), Is.EqualTo("not a database"));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task PersistenceFailuresRemainCompleteInBothModes(bool verbose)
    {
        Store store = new(_database);
        CompanionImportService importer = new(store);
        store.Dispose();
        CompanionImportResult result = await importer.ImportSavedVariablesAsync(Snapshot(1));
        ImportPresentation model = Present(result);
        string output = Render(model, verbose);
        Assert.That(model.ExitCode, Is.EqualTo(ExitCodes.Failed));
        Assert.That(output, Does.Contain("history-store-failure").And.Contain("No craft or dimension changes"));
        Assert.That(model.Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(result.SourceDiagnostics.Count));
        Assert.That(result.Observations, Is.Empty);
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task DiscoveryWarningsRemainVisibleOnReplayButOnlyErrorsChangeExit(bool verbose)
    {
        string root = Path.Combine(_directory, "installation");
        await Ledger(root, "_retail_", "Sanitized", Snapshot(1));
        new CompanionSettingsStore(_paths).Save(CompanionSettings.ForRoots(root));
        // Portable incidental layout failure, not an account/source branch error.
        await File.WriteAllTextAsync(Path.Combine(root, "_retail_", "Interface"), "not a directory");
        Assert.That((await Run(verbose)).Exit, Is.Zero);
        (int exit, string output) = await Run(verbose);
        Assert.That(exit, Is.Zero);
        Assert.That(output, Does.Contain("Warning (discovery-failed)").And.Not.Contain("partial success"));
        new CompanionSettingsStore(_paths).Save(CompanionSettings.ForRoots(root, Path.Combine(_directory, "missing")));
        (exit, output) = await Run(verbose);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed));
        Assert.That(output, Does.Contain("Error (discovery-failed)").And.Contain("partial success")
            .And.Contain("1 existing crafts"));
    }

    private async Task<(int Exit, string Output)> Run(bool verbose, string? source = null)
    {
        using TestConsole console = new();
        console.Width(240);
        string[] args = ["import", .. source is null ? Array.Empty<string>() : new[] { source },
            "--database", _database, .. verbose ? new[] { "--verbose" } : Array.Empty<string>()];
        int exit = await CompanionCommandApp.Create(console, _paths).RunAsync(args);
        return (exit, console.Output);
    }

    private static async Task<string> Ledger(string root, string flavor, string account, string content)
    {
        string directory = Path.Combine(root, flavor, "WTF", "Account", account, "SavedVariables");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "ArtisanLogbook_Core.lua");
        await File.WriteAllTextAsync(path, content);
        return path;
    }

    internal static ImportPresentation Present(CompanionImportResult result) =>
        new([("snapshot.lua", result)], new([], []));

    internal static string Render(ImportPresentation model, bool verbose)
    {
        using TestConsole console = new();
        console.Width(240);
        ImportReport.Write(console, model, "history.duckdb", verbose);
        return console.Output;
    }

    internal static string Snapshot(
        int count, int project = 1, string? origin = null, string extra = "", int unknownRecipes = int.MaxValue,
        Func<int, string>? perCraft = null) => $$"""
        ArtisanLogbookDB = {
          schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 5,
          craftSeries = {},
          crafts = {
            {{string.Join(",\n", Enumerable.Range(1, count).Select(id =>
                "{ id = " + id.ToString(CultureInfo.InvariantCulture) + ", sessionId = 1, timestamp = 1800000000, " +
                (id > unknownRecipes ? "recipeId = 77, " : "") +
                (origin is null ? "" : $"companionCraftOrigin = \"{origin}\", companionCraftObservation = \"{id}\", ") +
                extra + perCraft?.Invoke(id) + " }"))}}
          },
          dimensions = {
            sessions = { { id = 1, key = "sanitized-session", projectId = {{project}}, characterDimensionId = 1 } },
            characters = { { id = 1, key = "project:{{project}}:region:3:realm:1309:guid:Player-Sanitized" } }
          }
        }
        """;
}
