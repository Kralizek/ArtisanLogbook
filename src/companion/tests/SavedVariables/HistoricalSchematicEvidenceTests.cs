using ArtisanLogbook.History;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

namespace Tests.SavedVariables;

[TestFixture]
public sealed class HistoricalSchematicEvidenceTests
{
    [Test]
    public void RequestResultAndLaterResultPreserveBothHistoricalSlotVariantsAndTheirSourceTimes()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(Snapshot());
        Assert.That(parsed.IsSuccessful, Is.True, string.Join(Environment.NewLine, parsed.Diagnostics));
        Assert.That(parsed.History!.Crafts, Has.Count.EqualTo(3));
        Assert.That(parsed.History.Dimensions.RecipeReagentSlots, Is.Empty);
        Assert.That(parsed.Diagnostics.Count(d => d.Code == "historical-recipe-schematic-variation"), Is.EqualTo(3));
        LuaTable old = Evidence(parsed.History.Crafts[0]);
        LuaTable changed = Evidence(parsed.History.Crafts[1]);
        LuaTable later = Evidence(parsed.History.Crafts[2]);
        Assert.Multiple(() =>
        {
            Assert.That(((LuaTable)old.Get("request")!).Get("id"), Is.EqualTo(7d));
            Assert.That(((LuaTable)old.Get("request")!).Get("timestamp"), Is.EqualTo(1800000000d));
            Assert.That(Slot(old, "request", "requirements").Get("requiredQuantity"), Is.EqualTo(1d));
            Assert.That(((LuaTable)Slot(old, "request", "requirements").Get("candidateItemIDs")!).Values,
                Is.EqualTo(new[] { 99d }));
            Assert.That(((LuaTable)changed.Get("request")!).Get("timestamp"), Is.EqualTo(1800000010d));
            Assert.That(((LuaTable)changed.Get("craft")!).Get("timestamp"), Is.EqualTo(1800000012d));
            Assert.That(Slot(changed, "request", "requirements").Get("requiredQuantity"), Is.EqualTo(2d));
            Assert.That(Slot(changed, "craft", "reagentRequirements").Get("requiredQuantity"), Is.EqualTo(2d));
            Assert.That(((LuaTable)Slot(later, "craft", "reagentRequirements").Get("candidateItemIDs")!).Values,
                Is.EqualTo(new[] { 100d, 101d }));
            Assert.That(((LuaTable)later.Get("craft")!).Get("timestamp"), Is.EqualTo(1800000020d));
            Assert.That(Slot(later, "craft", "reagentRequirements").ContainsKey("dataSlotType"), Is.False);
        });
        SavedVariablesWriteResult exported = SavedVariablesWriter.Serialize(parsed.History,
            options: new(Now: DateTimeOffset.FromUnixTimeSeconds(1800000021), GameContext: new(GameProject.Retail)));
        Assert.That(exported.IsSuccessful, Is.True, string.Join(Environment.NewLine, exported.Diagnostics));
        SavedVariablesImportResult replay = SavedVariablesReader.Parse(exported.Content!);
        Assert.That(replay.IsSuccessful, Is.True);
        foreach (CraftObservation craft in parsed.History.Crafts)
            Assert.That(replay.History!.Crafts.Single(c => c.Identity == craft.Identity).RecipeSchematicEvidence,
                Is.EqualTo(craft.RecipeSchematicEvidence));
    }

    [Test]
    public void SupplementaryDisagreementWithinOneCraftIsRetainedWithoutChoosingAWinner()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(Snapshot().Replace(
            "requestId = 8, timestamp = 1800000012", "requestId = 7, timestamp = 1800000012"));
        Assert.That(parsed.IsSuccessful, Is.True, string.Join(Environment.NewLine, parsed.Diagnostics));
        LuaTable snapshot = Evidence(parsed.History!.Crafts[1]);
        Assert.That(Slot(snapshot, "request", "requirements").Get("requiredQuantity"), Is.EqualTo(1d));
        Assert.That(Slot(snapshot, "craft", "reagentRequirements").Get("requiredQuantity"), Is.EqualTo(2d));
    }

    [Test]
    public void MalformedRetainedEvidenceRejectsExplicitly()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(Snapshot().Replace(
            "id = 3, sessionId = 1,", "id = 3, sessionId = 1, companionRecipeSchematicEvidence = { { sourceId = \"x\", payload = \"bad\" } },"));
        Assert.That(parsed.IsSuccessful, Is.False);
        Assert.That(parsed.Diagnostics.Any(d => d.Code == "invalid-recipe-schematic-evidence"), Is.True);
    }

    private static LuaTable Evidence(CraftObservation craft) =>
        (LuaTable)LuaDataParser.Parse(craft.RecipeSchematicEvidence!.Single().Payload)
            .Assignments["CraftRecipeSchematicEvidence"]!;

    private static LuaTable Slot(LuaTable snapshot, string source, string field) =>
        ((LuaTable)((LuaTable)snapshot.Get(source)!).Get(field)!).Values.OfType<LuaTable>().Single();

    private static string Snapshot() => """
        ArtisanLogbookDB = {
          schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
          crafts = {
            { id = 1, sessionId = 1, recipeId = 77, requestId = 7, timestamp = 1800000002 },
            { id = 2, sessionId = 1, recipeId = 77, requestId = 8, timestamp = 1800000012,
              reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
                requiredQuantity = 2, candidateItemIDs = { 100, 101 } } } },
            { id = 3, sessionId = 1, recipeId = 77, timestamp = 1800000020,
              reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
                requiredQuantity = 2, candidateItemIDs = { 100, 101 } } } }
          },
          requests = {
            { id = 7, sessionId = 1, recipeId = 77, timestamp = 1800000000,
              requirements = { { source = "schematic", dataSlotIndex = 1,
                requiredQuantity = 1, candidateItemIDs = { 99 } } } },
            { id = 8, sessionId = 1, recipeId = 77, timestamp = 1800000010,
              requirements = { { source = "schematic", dataSlotIndex = 1,
                requiredQuantity = 2, candidateItemIDs = { 100, 101 } } } }
          },
          dimensions = {
            sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
            characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-Sanitized" } }
          }
        }
        """;
}
