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
        Assert.That(parsed.Diagnostics.Where(d => d.Code == "historical-recipe-schematic-variation")
            .All(d => d.Severity == SavedVariablesDiagnosticSeverity.Information), Is.True);
        LuaTable old = Evidence(parsed.History.Crafts[0]);
        LuaTable changed = Evidence(parsed.History.Crafts[1]);
        LuaTable later = Evidence(parsed.History.Crafts[2]);
        Assert.Multiple(() =>
        {
            Assert.That(parsed.History.Crafts.All(c => c.RecipeId == 1236483 && c.Game == new GameContext(GameProject.Retail)), Is.True);
            Assert.That(((LuaTable)old.Get("request")!).Get("id"), Is.EqualTo(205d));
            Assert.That(((LuaTable)old.Get("request")!).Get("timestamp"), Is.EqualTo(1791829214d));
            Assert.That(((LuaTable)old.Get("craft")!).Get("requestId"), Is.EqualTo(205d));
            Assert.That(((LuaTable)old.Get("craft")!).Get("id"), Is.EqualTo(858d));
            Assert.That((LuaTable)((LuaTable)old.Get("craft")!).Get("reagentRequirements")!, Is.Empty,
                "An explicitly empty direct list must stay empty; request requirements are not copied into it.");
            Assert.That(Slot(old, "request", "requirements").Get("requiredQuantity"), Is.EqualTo(1d));
            Assert.That(((LuaTable)Slot(old, "request", "requirements").Get("candidateItemIDs")!).Values,
                Is.EqualTo(new[] { 236951d }));
            Assert.That(((LuaTable)changed.Get("request")!).Get("id"), Is.EqualTo(526d));
            Assert.That(((LuaTable)changed.Get("craft")!).Get("requestId"), Is.EqualTo(526d));
            Assert.That(((LuaTable)changed.Get("request")!).Get("timestamp"), Is.EqualTo(1792433712d));
            Assert.That(((LuaTable)changed.Get("craft")!).Get("timestamp"), Is.EqualTo(1792433714d));
            Assert.That(Slot(changed, "request", "requirements").Get("requiredQuantity"), Is.EqualTo(2d));
            Assert.That(Slot(changed, "craft", "reagentRequirements").Get("requiredQuantity"), Is.EqualTo(2d));
            Assert.That(((LuaTable)Slot(later, "craft", "reagentRequirements").Get("candidateItemIDs")!).Values,
                Is.EqualTo(new[] { 243599d, 243600d }));
            Assert.That(((LuaTable)later.Get("craft")!).Get("timestamp"), Is.EqualTo(1792530782d));
            Assert.That(later.ContainsKey("request"), Is.False);
            Assert.That(((LuaTable)later.Get("craft")!).ContainsKey("requestId"), Is.False);
            Assert.That(Slot(later, "craft", "reagentRequirements").ContainsKey("dataSlotType"), Is.False);
        });
        SavedVariablesWriteResult exported = SavedVariablesWriter.Serialize(parsed.History,
            options: new(Now: DateTimeOffset.FromUnixTimeSeconds(1792530783), GameContext: new(GameProject.Retail)));
        Assert.That(exported.IsSuccessful, Is.True, string.Join(Environment.NewLine, exported.Diagnostics));
        SavedVariablesImportResult replay = SavedVariablesReader.Parse(exported.Content!);
        Assert.That(replay.IsSuccessful, Is.True);
        foreach (CraftObservation craft in parsed.History.Crafts)
            Assert.That(replay.History!.Crafts.Single(c => c.Identity == craft.Identity).RecipeSchematicEvidence,
                Is.EqualTo(craft.RecipeSchematicEvidence));
    }

    [Test]
    public void AbsentDirectRequirementsStayAbsentWhenRequirementsOriginateFromRequest()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(Snapshot().Replace("reagentRequirements = {}", ""));
        Assert.That(parsed.IsSuccessful, Is.True);
        LuaTable snapshot = Evidence(parsed.History!.Crafts[0]);
        Assert.That(snapshot.ContainsKey("request"), Is.True);
        Assert.That(((LuaTable)snapshot.Get("craft")!).ContainsKey("reagentRequirements"), Is.False);
    }

    [Test]
    public void SupplementaryDisagreementWithinOneCraftIsRetainedWithoutChoosingAWinner()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(Snapshot().Replace(
            "requestId = 526, timestamp = 1792433714", "requestId = 205, timestamp = 1792433714"));
        Assert.That(parsed.IsSuccessful, Is.True, string.Join(Environment.NewLine, parsed.Diagnostics));
        LuaTable snapshot = Evidence(parsed.History!.Crafts[1]);
        Assert.That(Slot(snapshot, "request", "requirements").Get("requiredQuantity"), Is.EqualTo(1d));
        Assert.That(Slot(snapshot, "craft", "reagentRequirements").Get("requiredQuantity"), Is.EqualTo(2d));
    }

    [Test]
    public void MalformedRetainedEvidenceRejectsExplicitly()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(Snapshot().Replace(
            "id = 1478, sessionId = 1,", "id = 1478, sessionId = 1, companionRecipeSchematicEvidence = { { sourceId = \"x\", payload = \"bad\" } },"));
        Assert.That(parsed.IsSuccessful, Is.False);
        Assert.That(parsed.Diagnostics.Any(d => d.Code == "invalid-recipe-schematic-evidence"), Is.True);
    }

    private static LuaTable Evidence(CraftObservation craft) =>
        (LuaTable)LuaDataParser.Parse(craft.RecipeSchematicEvidence!.Single().Payload)
            .Assignments["CraftRecipeSchematicEvidence"]!;

    private static LuaTable Slot(LuaTable snapshot, string source, string field) =>
        ((LuaTable)((LuaTable)snapshot.Get(source)!).Get(field)!).Values.OfType<LuaTable>().Single();

    private static string Snapshot() => File.ReadAllText(Path.Combine(
        TestContext.CurrentContext.TestDirectory, "Fixtures", "recipe-1236483-history.lua"));
}
