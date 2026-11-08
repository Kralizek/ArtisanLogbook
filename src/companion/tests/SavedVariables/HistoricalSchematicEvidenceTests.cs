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
        Assert.That(parsed.Diagnostics.Count(d => d.Code == "historical-recipe-schematic-variation"), Is.EqualTo(1));
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

    [Test]
    public void RetainedEvidenceRejectsInvalidFieldTypesAndEnclosingCraftMismatches()
    {
        SavedVariablesImportResult baseline = SavedVariablesReader.Parse(Snapshot());
        CraftRecipeSchematicEvidence evidence = baseline.History!.Crafts[2].RecipeSchematicEvidence!.Single();

        SavedVariablesImportResult invalidType = SavedVariablesReader.Parse(
            AttachEvidence(Snapshot(), 1478, UpdateSnapshot(evidence, (craft, _) => craft["id"] = "not-an-id")));
        AssertInvalidSchematicEvidence(invalidType);

        SavedVariablesImportResult mismatchedRecipe = SavedVariablesReader.Parse(
            AttachEvidence(Snapshot(), 1478, UpdateSnapshot(evidence, (craft, _) => craft["recipeId"] = 1236484d)));
        AssertInvalidSchematicEvidence(mismatchedRecipe);

        SavedVariablesImportResult mismatchedSession = SavedVariablesReader.Parse(
            AttachEvidence(Snapshot(), 1478, UpdateSnapshot(evidence, (craft, _) => craft["sessionId"] = 2d)));
        AssertInvalidSchematicEvidence(mismatchedSession);

        SavedVariablesImportResult mismatchedTimestamp = SavedVariablesReader.Parse(
            AttachEvidence(Snapshot(), 1478, UpdateSnapshot(evidence, (craft, _) => craft["timestamp"] = 1792530783d)));
        AssertInvalidSchematicEvidence(mismatchedTimestamp);
    }

    [Test]
    public void RetainedEvidenceRejectsRequestIdentityThatDoesNotMatchItsCraftAssociation()
    {
        SavedVariablesImportResult baseline = SavedVariablesReader.Parse(Snapshot());
        CraftRecipeSchematicEvidence evidence = baseline.History!.Crafts[1].RecipeSchematicEvidence!.Single();

        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(
            AttachEvidence(Snapshot(), 1434, UpdateSnapshot(evidence,
                (_, request) => request!["id"] = 527d)));

        AssertInvalidSchematicEvidence(parsed);
    }

    [Test]
    public void RetainedRequestRecipeMustMatchTheEnclosingCraftEvenWhenCraftSnapshotOmitsIt()
    {
        SavedVariablesImportResult baseline = SavedVariablesReader.Parse(Snapshot());
        CraftRecipeSchematicEvidence evidence = baseline.History!.Crafts[0].RecipeSchematicEvidence!.Single();

        CraftRecipeSchematicEvidence mismatched = UpdateSnapshot(evidence, (craft, request) =>
        {
            craft.Remove("recipeId");
            request!["recipeId"] = 1236484d;
        });
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(AttachEvidence(Snapshot(), 858, mismatched));

        AssertInvalidSchematicEvidence(parsed);
    }

    [Test]
    public void MalformedNativeSchematicCollectionEntryIsRejectedInsteadOfDropped()
    {
        string malformed = Snapshot().Replace(
            """
            reagentRequirements = { { source = "schematic", dataSlotIndex = 1,
                    requiredQuantity = 2, candidateItemIDs = { 243599, 243600 } } }
            """,
            "reagentRequirements = { 5 }");

        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(malformed);

        AssertInvalidSchematicEvidence(parsed);
    }

    [Test]
    public void MalformedRetainedSchematicCollectionEntryIsRejectedInsteadOfDropped()
    {
        SavedVariablesImportResult baseline = SavedVariablesReader.Parse(Snapshot());
        CraftRecipeSchematicEvidence evidence = baseline.History!.Crafts[2].RecipeSchematicEvidence!.Single();
        CraftRecipeSchematicEvidence malformed = UpdateSnapshot(evidence, (craft, _) =>
        {
            LuaTable rows = new();
            rows[1d] = 5d;
            craft["reagentRequirements"] = rows;
        });

        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(
            AttachEvidence(Snapshot(), 1478, malformed));

        AssertInvalidSchematicEvidence(parsed);
    }

    [Test]
    public void NativeAndRetainedCopyOfOneSchematicDoesNotDuplicateVariationDiagnostics()
    {
        string source = Snapshot();
        SavedVariablesImportResult baseline = SavedVariablesReader.Parse(source);
        CraftRecipeSchematicEvidence native = baseline.History!.Crafts[1].RecipeSchematicEvidence!.Single();

        SavedVariablesImportResult withRetainedCopy = SavedVariablesReader.Parse(
            AttachEvidence(source, 1434, native));

        Assert.That(withRetainedCopy.IsSuccessful, Is.True, string.Join(Environment.NewLine, withRetainedCopy.Diagnostics));
        Assert.That(withRetainedCopy.Diagnostics.Count(d => d.Code == "historical-recipe-schematic-variation"),
            Is.EqualTo(baseline.Diagnostics.Count(d => d.Code == "historical-recipe-schematic-variation")));
        Assert.That(withRetainedCopy.History!.Crafts[1].RecipeSchematicEvidence, Has.Count.EqualTo(1));
    }

    private static void AssertInvalidSchematicEvidence(SavedVariablesImportResult parsed)
    {
        Assert.That(parsed.IsSuccessful, Is.False);
        Assert.That(parsed.Diagnostics.Any(d =>
            d.Severity == SavedVariablesDiagnosticSeverity.Error &&
            d.Code == "invalid-recipe-schematic-evidence"), Is.True,
            string.Join(Environment.NewLine, parsed.Diagnostics));
    }

    private static string AttachEvidence(
        string source, long craftId, CraftRecipeSchematicEvidence evidence)
    {
        string marker = $"id = {craftId}, sessionId = 1,";
        string evidenceRow = $"companionRecipeSchematicEvidence = {{ {{ sourceId = {QuoteLua(evidence.SourceId)}, payload = {QuoteLua(evidence.Payload)} }} }},";
        return source.Replace(marker, marker + " " + evidenceRow, StringComparison.Ordinal);
    }

    private static CraftRecipeSchematicEvidence UpdateSnapshot(
        CraftRecipeSchematicEvidence evidence, Action<LuaTable, LuaTable?> update)
    {
        LuaDocument document = LuaDataParser.Parse(evidence.Payload);
        LuaTable snapshot = (LuaTable)document.Assignments["CraftRecipeSchematicEvidence"]!;
        LuaTable craft = (LuaTable)snapshot.Get("craft")!;
        update(craft, snapshot.Get("request") as LuaTable);
        return evidence with { Payload = LuaDataParser.Serialize(document) };
    }

    private static string QuoteLua(string value) => "\"" + value
        .Replace("\\", "\\\\", StringComparison.Ordinal)
        .Replace("\"", "\\\"", StringComparison.Ordinal)
        .Replace("\n", "\\n", StringComparison.Ordinal)
        .Replace("\r", "\\r", StringComparison.Ordinal)
        .Replace("\t", "\\t", StringComparison.Ordinal) + "\"";

    private static LuaTable Evidence(CraftObservation craft) =>
        (LuaTable)LuaDataParser.Parse(craft.RecipeSchematicEvidence!.Single().Payload)
            .Assignments["CraftRecipeSchematicEvidence"]!;

    private static LuaTable Slot(LuaTable snapshot, string source, string field) =>
        ((LuaTable)((LuaTable)snapshot.Get(source)!).Get(field)!).Values.OfType<LuaTable>().Single();

    private static string Snapshot() => File.ReadAllText(Path.Combine(
        TestContext.CurrentContext.TestDirectory, "Fixtures", "recipe-1236483-history.lua"));
}
