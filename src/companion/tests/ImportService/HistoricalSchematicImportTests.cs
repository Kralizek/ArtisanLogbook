using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.ImportService;

[TestFixture]
public sealed class HistoricalSchematicImportTests
{
    [Test]
    public async Task MalformedSchematicCollectionRejectsTheWholeImportWithoutPersistingCrafts()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.SchematicImport.Tests", Guid.NewGuid().ToString("N"));
        string database = Path.Combine(directory, "history.duckdb");
        string source = File.ReadAllText(Path.Combine(TestContext.CurrentContext.TestDirectory,
            "Fixtures", "recipe-1236483-history.lua")).Replace(
            """
            reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
                    requiredQuantity = 2, candidateItemIDs = { 243599, 243600 } } }
            """,
            "reagentRequirements = { 5 }");
        try
        {
            using (Store store = new(database))
            {
                CompanionImportResult result = await new CompanionImportService(store)
                    .ImportSavedVariablesAsync(source);
                Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
                Assert.That(result.SourceDiagnostics.Any(d =>
                    d.Severity == SavedVariablesDiagnosticSeverity.Error &&
                    d.Code == "invalid-recipe-schematic-evidence"), Is.True);
                Assert.That(store.ReadStatus().TotalCraftCount, Is.Zero);
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Test]
    public async Task ActualRecipePatternPreservesProvenanceVariantsAndStrictDimensionsAcrossReplayAndReopen()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.SchematicImport.Tests", Guid.NewGuid().ToString("N"));
        string database = Path.Combine(directory, "history.duckdb");
        string source = File.ReadAllText(Path.Combine(TestContext.CurrentContext.TestDirectory,
            "Fixtures", "recipe-1236483-history.lua"));
        CraftHistory expected = SavedVariablesReader.Parse(source).History!;
        RecipeReagentSlot explicitSlot = new(new(GameProject.Retail), 1236483, null, 1,
            RequiredQuantity: 99, CandidateItemIds: [999]);
        try
        {
            using (Store store = new(database))
            {
                Assert.That(store.WriteDimensions(CraftDimensions.Empty with { RecipeReagentSlots = [explicitSlot] }).IsSuccessful, Is.True);
                CompanionImportResult first = await new CompanionImportService(store).ImportSavedVariablesAsync(source);
                Assert.That(first.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
                Assert.That(first.InsertedCrafts, Is.EqualTo(3));
                Assert.That(first.SourceDiagnostics.Count(d => d.Code == "historical-recipe-schematic-variation"), Is.EqualTo(1));
                Assert.That(first.CoverageWarnings.Any(d => d.Code == "historical-recipe-schematic-variation"), Is.False);
                AssertExplicitSlot(store, explicitSlot);
                Assert.That(store.WriteDimensions(CraftDimensions.Empty with
                {
                    RecipeReagentSlots = [explicitSlot with { RequiredQuantity = 100 }]
                }).Status, Is.EqualTo(DimensionWriteStatus.Conflict));
            }
            using (Store store = new(database))
            {
                CompanionImportService importer = new(store);
                CompanionImportResult repeat = await importer.ImportSavedVariablesAsync(source);
                Assert.That(repeat.AlreadyPresentCrafts, Is.EqualTo(3));
                Assert.That(repeat.InsertedCrafts, Is.Zero);
                foreach (CraftObservation craft in expected.Crafts)
                    Assert.That(store.Read(craft.Identity)!.RecipeSchematicEvidence, Is.EqualTo(craft.RecipeSchematicEvidence));

                string variant = source.Replace("requiredQuantity = 1", "requiredQuantity = 3");
                CompanionImportResult enriched = await importer.ImportSavedVariablesAsync(variant);
                Assert.That(enriched.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
                Assert.That(enriched.EnrichedCrafts, Is.EqualTo(1));
                Assert.That(store.Read(expected.Crafts[0].Identity)!.RecipeSchematicEvidence, Has.Count.EqualTo(2));
                Assert.That((await importer.ImportSavedVariablesAsync(variant)).AlreadyPresentCrafts, Is.EqualTo(3));

                SavedVariablesWriteResult exported = SavedVariablesWriter.Serialize(
                    new(store.ReadAll(), CraftDimensions.Empty),
                    options: new(Now: DateTimeOffset.FromUnixTimeSeconds(1792530783), GameContext: new(GameProject.Retail)));
                Assert.That(exported.IsSuccessful, Is.True, string.Join(Environment.NewLine, exported.Diagnostics));
                Assert.That((await importer.ImportSavedVariablesAsync(exported.Content!)).AlreadyPresentCrafts, Is.EqualTo(3));

                CompanionImportResult contradiction = await importer.ImportSavedVariablesAsync(
                    source.Replace("recipeId = 1236483", "recipeId = 1236484"));
                Assert.That(contradiction.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
                Assert.That(contradiction.CraftConflicts, Is.Not.Empty);
                CompanionImportResult malformed = await importer.ImportSavedVariablesAsync(
                    source.Replace("candidateItemIDs = { 236951 }", "candidateItemIDs = { -1 }"));
                Assert.That(malformed.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
            }
            using (Store store = new(database, readOnly: true))
            {
                Assert.That(store.ReadStatus().TotalCraftCount, Is.EqualTo(3));
                CraftObservation old = store.Read(expected.Crafts[0].Identity)!;
                Assert.That(old.RecipeSchematicEvidence, Has.Count.EqualTo(2));
                foreach (CraftRecipeSchematicEvidence evidence in old.RecipeSchematicEvidence!)
                {
                    LuaTable snapshot = (LuaTable)LuaDataParser.Parse(evidence.Payload).Assignments["CraftRecipeSchematicEvidence"]!;
                    Assert.That(((LuaTable)snapshot.Get("request")!).Get("id"), Is.EqualTo(205d));
                    Assert.That(((LuaTable)snapshot.Get("craft")!).Get("requestId"), Is.EqualTo(205d));
                    Assert.That((LuaTable)((LuaTable)snapshot.Get("craft")!).Get("reagentRequirements")!, Is.Empty);
                }
                AssertExplicitSlot(store, explicitSlot);
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    private static void AssertExplicitSlot(Store store, RecipeReagentSlot expected)
    {
        RecipeReagentSlot actual = store.ReadDimensions().RecipeReagentSlots.Single();
        Assert.That(actual, Is.EqualTo(expected with { CandidateItemIds = actual.CandidateItemIds }),
            "Historical evidence must not modify explicitly supplied dimension fields.");
        Assert.That(actual.CandidateItemIds, Is.EqualTo(expected.CandidateItemIds));
    }
}
