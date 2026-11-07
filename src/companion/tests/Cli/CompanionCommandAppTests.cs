using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;

using ArtisanLogbook.Cli;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

using Spectre.Console.Cli;
using Spectre.Console.Testing;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.Cli;

[TestFixture]
public sealed class CompanionCommandAppTests
{
    private string _directory = null!;
    private string _database = null!;
    private ApplicationPaths _paths = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Cli.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _database = Path.Combine(_directory, "explicit", "history.duckdb");
        _paths = new(CompanionPlatform.Linux, _directory, _directory, null, _directory);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [TestCase]
    [TestCase("--help")]
    public async Task RootHelpIsGeneratedWithoutCreatingDatabase(params string[] args)
    {
        (int exit, string output) = await Run(args);
        Assert.Multiple(() =>
        {
            Assert.That(exit, Is.EqualTo(ExitCodes.Success));
            Assert.That(output, Does.Contain("USAGE:").And.Contain("import").And.Contain("status"));
            Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
        });
    }

    [Test]
    public async Task CommandHelpDescribesArgumentsAndOptions()
    {
        (int exit, string output) = await Run("import", "--help");
        Assert.That(exit, Is.Zero);
        Assert.That(output, Does.Contain("SOURCE-FILE").And.Contain("--database"));
    }

    [Test]
    public async Task VersionUsesExecutablePackageVersion()
    {
        (int exit, string output) = await Run("--version");
        Assert.That(exit, Is.Zero);
        Assert.That(output, Does.Contain("0.1.0"));
    }

    [TestCase("unknown")]
    [TestCase("status", "--flavor", "retail")]
    [TestCase("status", "extra")]
    [TestCase("status", "--database")]
    [TestCase("status", "--database", "")]
    [TestCase("import")]
    [TestCase("import", "")]
    public async Task InvalidUsageIsUsefulAndNonzero(params string[] args)
    {
        (int exit, string output) = await Run(args);
        Assert.That(exit, Is.EqualTo(ExitCodes.Usage), output);
        Assert.That(output, Does.Contain("Error"));
        Assert.That(File.Exists(_database), Is.False);
    }

    [Test]
    public async Task MissingSourceFailsWithC07Diagnostic()
    {
        (int exit, string output) = await Run("import", "missing.lua", "--database", _database);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed));
        Assert.That(output, Does.Contain("Import failed").And.Contain("source-read-failed")
            .And.Contain("No craft or dimension changes were committed"));
    }

    [Test]
    public async Task MalformedSourceIsRejectedAndMarkupIsNotInterpreted()
    {
        string source = Path.Combine(_directory, "[red]malformed[/].lua".Replace('/', '_'));
        await File.WriteAllTextAsync(source, "ArtisanLogbookDB = {");
        (int exit, string output) = await Run("import", source, "--database", _database);
        Assert.That(exit, Is.EqualTo(ExitCodes.Rejected));
        Assert.That(output, Does.Contain("Import rejected").And.Contain("No craft or dimension changes were committed"));
        using Store reader = new(_database, readOnly: true);
        Assert.That(reader.ReadStatus().TotalCraftCount, Is.Zero);
    }

    [TestCase("v1-outcome1.lua", 15)]
    public async Task FixtureImportReplayAndStatusPersistAfterReopening(string fixtureName, int expectedCount)
    {
        string fixture = Fixture(fixtureName);
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(await File.ReadAllTextAsync(fixture));
        Assert.That(parsed.History!.Crafts, Has.Count.EqualTo(expectedCount));
        byte[] original = await File.ReadAllBytesAsync(fixture);
        (int firstExit, string first) = await Run("import", fixture, "--database", _database);
        Assert.That(firstExit, Is.Zero, first);
        Assert.That(first, Does.Contain("Import successful").And.Contain("Observed source crafts")
            .And.Contain("Inserted dimensions").And.Contain(_database));
        if (parsed.Coverage.HasPrunedHistory)
            Assert.That(first, Does.Contain("aggregate-only-history").And.Contain("were not recovered"));
        Assert.That(first, Does.Contain(expectedCount.ToString(CultureInfo.InvariantCulture)));
        AssertReportCount(first, "Observed source crafts", expectedCount);
        AssertReportCount(first, "Inserted crafts", expectedCount);
        AssertReportCount(first, "Already-present crafts", 0);
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False, "Explicit override must replace the default.");
        Assert.That(await File.ReadAllBytesAsync(fixture), Is.EqualTo(original));

        using (Store reopened = new(_database, readOnly: true))
            Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(expectedCount));
        (int repeatExit, string repeat) = await Run("import", fixture, "--database", _database);
        Assert.That(repeatExit, Is.Zero, repeat);
        Assert.That(repeat, Does.Contain("Already-present crafts").And.Contain("Inserted crafts"));
        AssertReportCount(repeat, "Inserted crafts", 0);
        AssertReportCount(repeat, "Already-present crafts", expectedCount);
        AssertReportCount(repeat, "Enriched crafts", 0);
        using (Store reopened = new(_database, readOnly: true))
            Assert.That(reopened.ReadStatus().TotalCraftCount, Is.EqualTo(expectedCount));

        byte[] beforeStatus = await File.ReadAllBytesAsync(_database);
        (int statusExit, string status) = await Run("status", "--database", _database);
        Assert.That(statusExit, Is.Zero, status);
        Assert.That(status, Does.Contain("Canonical crafts").And.Contain("Schema version")
            .And.Contain("Oldest craft").And.Contain("Newest craft")
            .And.Contain("Project ID").And.Contain("Progression track"));
        if (expectedCount > 0)
            Assert.That(status, Does.Contain("Retail"));
        AssertReportCount(status, "Canonical crafts", expectedCount);
        Assert.That(await File.ReadAllBytesAsync(_database), Is.EqualTo(beforeStatus));
    }

    [Test]
    public async Task DefaultImportCreatesApplicationDataDirectory()
    {
        (int exit, string output) = await Run("import", Fixture("v1-outcome1.lua"));
        Assert.That(exit, Is.Zero, output);
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.True);
        Assert.That(File.Exists(_database), Is.False);
    }

    [Test]
    public async Task FixtureWithoutTrustworthyGameContextIsRejectedWithoutPromotingRollups()
    {
        (int exit, string output) = await Run("import", Fixture("ledger-schema3.lua"), "--database", _database);
        Assert.That(exit, Is.EqualTo(ExitCodes.Rejected));
        Assert.That(output, Does.Contain("unknown-game-context").And.Contain("aggregate-only-history")
            .And.Contain("were not recovered").And.Contain("No craft or dimension changes were committed"));
        using Store store = new(_database, readOnly: true);
        Assert.That(store.ReadStatus().TotalCraftCount, Is.Zero);
    }

    [Test]
    public async Task HistoricalSchematicVariationPreservesCraftsAndInformsWithoutCatalogPromotion()
    {
        string source = Path.Combine(_directory, "schematic-conflict.lua");
        await File.WriteAllTextAsync(source, """
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 5,
              crafts = {
                { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77,
                  reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
                    requiredQuantity = 1, candidateItemIDs = { 99 } } } },
                { id = 2, sessionId = 1, timestamp = 1800000001, recipeId = 77,
                  reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
                    requiredQuantity = 2, candidateItemIDs = { 100, 101 } } } }
              },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-Sanitized" } }
              }
            }
            """);
        (int exit, string output) = await Run("import", source, "--database", _database);
        Assert.That(exit, Is.EqualTo(ExitCodes.Success));
        Assert.That(output, Does.Contain("historical-recipe-schematic-variation")
            .And.Not.Contain("No craft or dimension changes were committed"));
        AssertReportCount(output, "Observed source crafts", 2);
        AssertReportCount(output, "Inserted crafts", 2);
        using Store store = new(_database, readOnly: true);
        Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(2));
        Assert.That(store.ReadDimensions().RecipeReagentSlots, Is.Empty);
        Assert.That(store.ReadAll().All(craft => craft.RecipeSchematicEvidence?.Count == 1), Is.True);
    }

    [Test]
    public async Task StatusOfAnEmptyDatabaseDoesNotInventDates()
    {
        using (Store store = new(_database)) { }
        (int exit, string output) = await Run("status", "--database", _database);
        Assert.That(exit, Is.Zero);
        AssertReportCount(output, "Canonical crafts", 0);
        Assert.That(output, Does.Contain("(none)"));
    }

    [Test]
    public async Task DirectoryOverrideIsAnExplicitFailureNotAMissingDatabase()
    {
        (int exit, string output) = await Run("status", "--database", _directory);
        Assert.That(exit, Is.EqualTo(ExitCodes.Failed));
        Assert.That(output, Does.Contain("path is a directory").And.Not.Contain("does not exist"));
    }

    [Test]
    public async Task OneDatabaseRetainsMultipleSourceGameContexts()
    {
        foreach ((int project, string? track) in new[] { (1, (string?)null), (2, "hardcore"), (18, "progression-A") })
        {
            string source = Path.Combine(_directory, $"project-{project}.lua");
            await File.WriteAllTextAsync(source, Snapshot(project, track, quantity: 1));
            (int exit, string output) = await Run("import", source, "--database", _database);
            Assert.That(exit, Is.Zero, output);
        }
        using (Store store = new(_database, readOnly: true))
        {
            Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(3));
            Assert.That(store.ReadStatus().Contexts.Select(count => count.CraftCount), Is.EqualTo(new long[] { 1, 1, 1 }));
        }
        (int statusExit, string status) = await Run("status", "--database", _database);
        Assert.That(statusExit, Is.Zero);
        Assert.That(status, Does.Contain("Retail").And.Contain("ClassicEra").And.Contain("hardcore")
            .And.Contain("Forever").And.Contain("progression-A"));
    }

    [Test]
    public async Task ConflictingImportReportsRollbackAndRetainsOriginalCount()
    {
        string source = Path.Combine(_directory, "snapshot.lua");
        await File.WriteAllTextAsync(source, Snapshot(1, null, 1));
        Assert.That((await Run("import", source, "--database", _database)).Exit, Is.Zero);
        await File.WriteAllTextAsync(source, Snapshot(1, null, 2));
        (int exit, string output) = await Run("import", source, "--database", _database);
        Assert.That(exit, Is.EqualTo(ExitCodes.Rejected));
        Assert.That(output, Does.Contain("Import rejected").And.Contain("Conflict")
            .And.Contain("No craft or dimension changes were committed"));
        using Store store = new(_database, readOnly: true);
        Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(1));
        Assert.That(store.ReadAll().Single().Outputs!.Single().Quantity, Is.EqualTo(1));
    }

    [Test]
    public async Task MissingDatabaseStatusDoesNotCreateFileOrDirectory()
    {
        (int exit, string output) = await Run("status", "--database", _database);
        Assert.That(exit, Is.Zero);
        Assert.That(output, Does.Contain(_database).And.Contain("does not exist"));
        Assert.That(Directory.Exists(Path.GetDirectoryName(_database)), Is.False);
        Assert.That(File.Exists(_paths.ResolveDatabase(null)), Is.False);
    }

    [TestCase("status")]
    [TestCase("import")]
    public async Task WriterLockInAnotherProcessProducesActionableFailure(string command)
    {
        using Store writer = new(_database);
        ProcessStartInfo start = new("dotnet")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };
        start.ArgumentList.Add(typeof(CompanionCommandApp).Assembly.Location);
        start.ArgumentList.Add(command);
        if (command == "import")
            start.ArgumentList.Add(Fixture("v1-outcome1.lua"));
        start.ArgumentList.Add("--database");
        start.ArgumentList.Add(_database);
        using Process process = Process.Start(start)!;
        Task<string> stdout = process.StandardOutput.ReadToEndAsync();
        Task<string> stderr = process.StandardError.ReadToEndAsync();
        using CancellationTokenSource timeout = new(TimeSpan.FromSeconds(30));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw;
        }
        string output = await stdout + await stderr;
        Assert.That(process.ExitCode, Is.EqualTo(ExitCodes.Failed), output);
        Assert.That(output, Does.Contain("locked").And.Contain("close other").And.Contain("retry"));
        Assert.That(writer.ReadStatus().TotalCraftCount, Is.Zero);
    }

    private async Task<(int Exit, string Output)> Run(params string[] args)
    {
        using TestConsole console = new();
        console.Width(240);
        CommandApp app = CompanionCommandApp.Create(console, _paths);
        return (await app.RunAsync(args), console.Output);
    }

    private static string Fixture(string name) => Path.Combine(TestContext.CurrentContext.TestDirectory, "Fixtures", name);

    private static void AssertReportCount(string output, string label, int count) =>
        Assert.That(output, Does.Match(Regex.Escape(label) + @"\s*[|\u2502]\s*" +
            count.ToString(CultureInfo.InvariantCulture) + @"\s*[|\u2502]"));

    private static string Snapshot(int project, string? track, int quantity) => $$"""
        ArtisanLogbookDB = {
          schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
          crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77,
            outputItemId = 99, outputQuantity = {{quantity}} } },
          dimensions = {
            sessions = { { id = 1, key = "session-1", projectId = {{project}},
              {{(track is null ? "" : $"companionProgressionTrack = \"{track}\",")}} characterDimensionId = 1 } },
            characters = { { id = 1, key = "project:{{project}}:region:3:realm:1309:guid:Player-Sanitized" } }
          }
        }
        """;
}
