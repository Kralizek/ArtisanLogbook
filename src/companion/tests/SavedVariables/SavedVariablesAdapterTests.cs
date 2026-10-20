using System.Diagnostics;

using ArtisanLogbook.History;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

namespace Tests.SavedVariables;

[TestFixture]
public class SavedVariablesAdapterTests
{
    private static readonly GameContext Retail = new(GameProject.Retail);
    private static readonly CharacterIdentity Crafter =
        new("project:1:region:3:realm:1309:guid:Player-Sanitized-Adapter");
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    [Test]
    public void ParserReadsLiteralTablesKeysEscapesBooleansAndNilWithoutExecutingCode()
    {
        LuaDocument document = LuaDataParser.Parse(
            "ArtisanLogbookDB = { [12] = { name = \"a\\n\\065\", enabled = true, disabled = false, missing = nil }, items = {} }");
        LuaTable database = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        LuaTable entry = (LuaTable)database.Get(12d)!;

        Assert.Multiple(() =>
        {
            Assert.That(entry.Get("name"), Is.EqualTo("a\nA"));
            Assert.That(entry.Get("enabled"), Is.EqualTo(true));
            Assert.That(entry.Get("disabled"), Is.EqualTo(false));
            Assert.That(entry.ContainsKey("missing"), Is.True);
            Assert.That(entry.Get("missing"), Is.Null);
            Assert.That(((LuaTable)database.Get("items")!).Count, Is.Zero);
        });
    }

    [TestCase("ArtisanLogbookDB = os.execute('bad')")]
    [TestCase("ArtisanLogbookDB = { schemaVersion = 4,")]
    [TestCase("ArtisanLogbookDB = function() return {} end")]
    public void ParserRejectsMalformedOrExecutableLua(string source)
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse(source);
        Assert.That(result.History, Is.Null);
        Assert.That(result.Diagnostics, Is.Not.Empty);
        Assert.That(result.Diagnostics[0].Severity, Is.EqualTo(SavedVariablesDiagnosticSeverity.Error));
    }

    [Test]
    public void UnsupportedSchemasFailWithExplicitDiagnostic()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse(
            "ArtisanLogbookDB = { schemaIdentity = \"ArtisanLogbookLedger\", schemaVersion = 5 }");

        Assert.That(result.History, Is.Null);
        Assert.That(result.Diagnostics.Single().Code, Is.EqualTo("unsupported-schema"));
    }

    [Test]
    public void SanitizedLegacyFixtureImportsCraftsAndRecognizesPrunedAggregateHistory()
    {
        string source = ReadFixture("v1-outcome1.lua");
        SavedVariablesImportResult result = SavedVariablesReader.Parse(source, "v1-outcome1.lua");

        Assert.Multiple(() =>
        {
            Assert.That(result.IsSuccessful, Is.True, string.Join(Environment.NewLine, result.Diagnostics));
            Assert.That(result.SchemaVersion, Is.EqualTo(1));
            Assert.That(result.History!.Crafts, Is.Not.Empty);
            Assert.That(result.History.Crafts.All(c => c.Game.Project == GameProject.Retail), Is.True);
            Assert.That(result.Coverage.AggregateOnlyCraftCount, Is.GreaterThan(0));
            Assert.That(result.Diagnostics.Any(d => d.Code == "aggregate-only-history"), Is.True);
            Assert.That(result.Diagnostics.Any(d => d.Code == "legacy-identity-lineage"), Is.True);
        });
    }

    [Test]
    public void ReplayingARealLegacyFixtureProducesStableIdentityAndIsIdempotent()
    {
        SavedVariablesImportResult first = SavedVariablesReader.Parse(ReadFixture("v1-outcome1.lua"));
        SavedVariablesImportResult second = SavedVariablesReader.Parse(ReadFixture("v1-outcome1.lua"));
        CraftHistoryMergeResult merge = CraftHistoryReconciler.Merge(first.History!, second.History!);

        Assert.That(merge.IsSuccessful, Is.True);
        Assert.That(merge.History!.Crafts, Has.Count.EqualTo(first.History!.Crafts.Count));
        Assert.That(merge.History.Crafts, Is.EquivalentTo(first.History.Crafts));
    }

    [Test]
    public void DivergentClonedLedgerLocalIdIsSurfacedByCoreReconciliation()
    {
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(ReadFixture("v1-outcome1.lua"));
        CraftObservation original = imported.History!.Crafts[0];
        CraftObservation shared = original with { RecipeId = 1230868 };
        CraftObservation divergent = original with { RecipeId = 1237557 };

        CraftHistoryMergeResult merge = CraftHistoryReconciler.Merge(
            History(shared), History(divergent));

        Assert.That(merge.IsSuccessful, Is.False);
        Assert.That(merge.CraftConflicts, Is.Not.Empty);
    }

    [Test]
    public void AmbiguousLegacyGameContextIsNotDefaultedToRetail()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = { { id = 1, sessionId = 1, timestamp = 1800000000 } },
              dimensions = {
                sessions = { { id = 1, key = "session-1", characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } }
              }
            }
            """);

        Assert.That(result.History, Is.Not.Null);
        Assert.That(result.History!.Crafts, Is.Empty);
        Assert.That(result.Diagnostics.Any(d => d.Code == "unknown-game-context"), Is.True);
    }

    [Test]
    public void MultipleProjectsAndReusedRecipeAndItemIdsRemainContextScoped()
    {
        GameContext forever = new(GameProject.Forever);
        CraftObservation retailCraft = MakeCraft("retail", "1", Retail, recipeId: 77, itemId: 99);
        CraftObservation foreverCraft = MakeCraft("forever", "1", forever, recipeId: 77, itemId: 99);
        CraftHistory history = new([retailCraft, foreverCraft], new(
            [new(Retail, Crafter), new(forever, Crafter)],
            [new(Retail, 77), new(forever, 77)],
            [new(Retail, 171), new(forever, 171)],
            [new(Retail, 99), new(forever, 99)],
            []));

        Assert.That(CraftHistoryValidator.Validate(history), Is.Empty);
        SavedVariablesWriteResult retailResult = SavedVariablesWriter.Serialize(history,
            options: new(Now, GameContext: Retail));
        SavedVariablesWriteResult foreverResult = SavedVariablesWriter.Serialize(history,
            options: new(Now, GameContext: forever));

        Assert.That(retailResult.IsSuccessful, Is.True, string.Join(Environment.NewLine, retailResult.Diagnostics));
        Assert.That(foreverResult.IsSuccessful, Is.True, string.Join(Environment.NewLine, foreverResult.Diagnostics));
        Assert.That(SavedVariablesReader.Parse(retailResult.Content!).History!.Crafts.Single().Game, Is.EqualTo(Retail));
        Assert.That(SavedVariablesReader.Parse(foreverResult.Content!).History!.Crafts.Single().Game, Is.EqualTo(forever));
    }

    [Test]
    public void ImportedProjectsTracksAndReusedDimensionsRemainDistinct()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = {
                { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77, outputItemId = 99, outputQuantity = 1 },
                { id = 2, sessionId = 2, timestamp = 1800000001, recipeId = 77, outputItemId = 99, outputQuantity = 1 }
              },
              dimensions = {
                sessions = {
                  { id = 1, key = "retail-session", projectId = 1, characterDimensionId = 1 },
                  { id = 2, key = "classic-session", projectId = 19, companionProgressionTrack = "mists-progression", characterDimensionId = 2 }
                },
                characters = {
                  { id = 1, key = "project:1:region:3:realm:1309:guid:Player-Retail" },
                  { id = 2, key = "project:19:region:3:realm:1309:guid:Player-Mists" }
                },
                recipes = { [77] = { id = 77 } },
                items = { [99] = { id = 99 } }
              }
            }
            """);

        Assert.That(result.IsSuccessful, Is.True, string.Join(Environment.NewLine, result.Diagnostics));
        Assert.That(result.History!.Crafts.Select(c => c.Game.Project).ToArray(),
            Is.EquivalentTo([GameProject.Retail, GameProject.MistsClassic]));
        Assert.That(result.History.Crafts.Single(c => c.Game.Project == GameProject.MistsClassic)
            .Game.ProgressionTrack, Is.EqualTo("mists-progression"));
        Assert.That(result.History.Dimensions.Recipes.Select(r => r.Game).Distinct().ToArray(), Has.Length.EqualTo(2));
        Assert.That(result.History.Dimensions.Items.Select(i => i.Game).Distinct().ToArray(), Has.Length.EqualTo(2));
    }

    [Test]
    public void RecoveredRecipeAndSkillLineExpansionAreMappedFromSavedDimensions()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = {
                { id = 1, sessionId = 1, timestamp = 1800000000, companionOutputGroup = "group-A", outputItemId = 90, outputQuantity = 1 },
                { id = 2, sessionId = 1, timestamp = 1800000000, companionOutputGroup = "group-A", recipeId = 88, outputItemId = 91, outputQuantity = 2 }
              },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                recipes = { [88] = { id = 88, professionId = 171, expansionDimensionId = 1 } },
                professions = { [171] = { id = 171, name = "Alchemy" } },
                expansions = { { id = 1, key = "skillLine:2915", name = "Midnight" } },
                items = { [90] = { id = 90 }, [91] = { id = 91 } }
              }
            }
            """);

        Assert.That(result.IsSuccessful, Is.True, string.Join(Environment.NewLine, result.Diagnostics));
        CraftObservation craft = result.History!.Crafts.Single();
        Assert.Multiple(() =>
        {
            Assert.That(craft.RecipeId, Is.EqualTo(88));
            Assert.That(craft.Outputs, Has.Count.EqualTo(2));
            Assert.That(craft.ProfessionId, Is.EqualTo(171));
            Assert.That(craft.ProfessionExpansionKey, Is.EqualTo("skillLine:2915"));
            Assert.That(result.Diagnostics.Any(d => d.Code == "recipe-recovered"), Is.True);
        });
    }

    [Test]
    public void UnknownProfessionExpansionRemainsUnknown()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 88, outputItemId = 90, outputQuantity = 1 } },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                recipes = { [88] = { id = 88, professionId = 171 } },
                professions = { [171] = { id = 171 } },
                items = { [90] = { id = 90 } }
              }
            }
            """);

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.History!.Crafts.Single().ProfessionExpansionKey, Is.Null);
    }

    [Test]
    public void UnknownAndKnownZeroReagentReturnsRemainDistinct()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = {
                { id = 1, sessionId = 1, timestamp = 1800000000 },
                { id = 2, sessionId = 1, timestamp = 1800000001 }
              },
              reagents = {
                { craftId = 1, itemId = 44, allocatedQuantity = 3 },
                { craftId = 2, itemId = 44, allocatedQuantity = 3, returnedQuantity = 0 }
              },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                items = { [44] = { id = 44 } }
              }
            }
            """);

        Assert.That(result.IsSuccessful, Is.True, string.Join(Environment.NewLine, result.Diagnostics));
        Assert.That(result.History!.Crafts[0].Reagents!.Single().ReturnedQuantity, Is.Null);
        Assert.That(result.History.Crafts[1].Reagents!.Single().ReturnedQuantity, Is.Zero);
    }

    [Test]
    public void PartialAndEmptyCollectionsAreNotManufactured()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            return {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = {}, dimensions = { sessions = {}, characters = {}, recipes = {}, professions = {}, items = {}, expansions = {}, realms = {} }
            }
            """);

        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.History!.Crafts, Is.Empty);
        Assert.That(result.Diagnostics.Any(d => d.Code == "missing-rollups"), Is.True);
    }

    [Test]
    public void WriterRoundTripsMultiOutputCraftAndPreservesTargetTraceState()
    {
        CraftObservation craft = MakeCraft("source", "craft-A", Retail, 123, 90) with
        {
            Outputs = [new(90, 2, 3), new(91, 1, 2)],
            Reagents = [new(44, 4, 0.5m), new(45, 1, null)],
            HasResourcefulnessProc = true,
            ResourcefulnessComplete = true,
            InputsComplete = true,
            ConcentrationSpent = 0,
            HasIngenuityProc = false,
            IngenuityRefund = 0,
            MulticraftBonus = 0
        };
        CraftHistory history = History(craft);
        string target = "ArtisanLogbookTraceDB = { traceSchemaVersion = 2, records = {} }\n";
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(history, target,
            new(Now, GameContext: Retail));

        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        Assert.That(written.Content, Does.Contain("ArtisanLogbookTraceDB"));
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(written.Content!);
        Assert.That(imported.IsSuccessful, Is.True, string.Join(Environment.NewLine, imported.Diagnostics));
        CraftObservation result = imported.History!.Crafts.Single();
        Assert.Multiple(() =>
        {
            Assert.That(result.Outputs, Is.EquivalentTo(craft.Outputs));
            Assert.That(result.Reagents, Is.EquivalentTo(craft.Reagents));
            Assert.That(result.Identity, Is.EqualTo(craft.Identity));
            Assert.That(result.Provenance, Is.EqualTo(craft.Provenance));
            Assert.That(result.ResourcefulnessComplete, Is.True);
            Assert.That(result.InputsComplete, Is.True);
            Assert.That(result.ConcentrationSpent, Is.Zero);
            Assert.That(result.HasIngenuityProc, Is.False);
        });
    }

    [Test]
    public void WriterRetainsLongHistoryOnlyInRecomputedRollups()
    {
        CraftObservation old = MakeCraft("source", "old", Retail, 123, 90) with
        {
            RecordedAt = Now.AddDays(-120)
        };
        CraftObservation recent = MakeCraft("source", "recent", Retail, 123, 90) with
        {
            RecordedAt = Now.AddDays(-2)
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(old, recent),
            options: new(Now, GameContext: Retail));
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(written.Content!);
        LuaTable ledger = (LuaTable)LuaDataParser.Parse(written.Content!).Assignments["ArtisanLogbookDB"]!;
        LuaTable series = (LuaTable)ledger.Get("craftSeries")!;
        long rollupCount = series.Values.OfType<LuaTable>().Sum(row => (long)Convert.ToDouble(row.Get("craftCount")));

        Assert.Multiple(() =>
        {
            Assert.That(written.DetailedCraftCount, Is.EqualTo(1));
            Assert.That(written.RollupCraftCount, Is.EqualTo(2));
            Assert.That(imported.Coverage.AggregateOnlyCraftCount, Is.EqualTo(1));
            Assert.That(rollupCount, Is.EqualTo(2));
            Assert.That(written.Diagnostics.Any(d => d.Code == "retention-window"), Is.True);
        });
    }

    [Test]
    public void WriterRejectsUnselectedMultiProjectHistory()
    {
        GameContext forever = new(GameProject.Forever);
        SavedVariablesWriteResult result = SavedVariablesWriter.Serialize(
            History(MakeCraft("retail", "1", Retail), MakeCraft("forever", "1", forever)));
        Assert.That(result.Content, Is.Null);
        Assert.That(result.Diagnostics.Single().Code, Is.EqualTo("game-context-required"));
    }

    [Test]
    public void GeneratedSavedVariablesAreAcceptedByTheRealAddonLedgerLoaderOnLinux()
    {
        if (OperatingSystem.IsWindows())
            Assert.Ignore("Lua loader integration runs on Linux; the cross-platform .NET tests still run on Windows.");
        if (!CanRunLua())
            Assert.Ignore("Lua 5.1 is not installed in this environment.");

        CraftObservation craft = MakeCraft("loader", "1", Retail) with
        {
            Reagents = [new(44, 3, 1)],
            ResourcefulnessComplete = true,
            HasResourcefulnessProc = true
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft),
            options: new(Now, GameContext: Retail));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));

        string root = FindRepositoryRoot();
        string ledgerPath = Path.Combine(root, "src", "addon", "src", "ArtisanLogbook_Core", "Storage", "Ledger.lua");
        string temp = Path.Combine(Path.GetTempPath(), $"artisan-logbook-{Guid.NewGuid():N}.lua");
        File.WriteAllText(temp, written.Content!);
        try
        {
            string script =
                $"dofile({LuaQuote(temp)}); local addon={{}}; assert(loadfile({LuaQuote(ledgerPath)}))('ArtisanLogbook_Core', addon); " +
                $"local ledger, reason=addon.Ledger.New(ArtisanLogbookDB, {{wall=function() return {Now.ToUnixTimeSeconds()} end}}); " +
                "assert(ledger, reason); assert(ledger.database.schemaVersion == 4)";
            ProcessStartInfo start = new("lua") { RedirectStandardError = true, RedirectStandardOutput = true };
            start.ArgumentList.Add("-e");
            start.ArgumentList.Add(script);
            using Process process = Process.Start(start) ?? throw new InvalidOperationException("Lua process could not start.");
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Assert.That(process.ExitCode, Is.Zero, $"{output}{Environment.NewLine}{error}");
        }
        finally
        {
            File.Delete(temp);
        }
    }

    private static CraftObservation MakeCraft(
        string origin,
        string id,
        GameContext? game = null,
        int recipeId = 123,
        int itemId = 90) =>
        new(new(origin, id), game ?? Retail, Now, recipeId,
            game is null || game == Retail
                ? Crafter
                : new CharacterIdentity($"project:{(int)game.Project}:region:3:realm:1309:guid:Player-Sanitized-Adapter"),
            ProfessionId: 171,
            Outputs: [new(itemId, 2, 1)],
            Provenance: new CraftProvenance(origin, 1, 123456));

    private static CraftHistory History(params CraftObservation[] crafts)
    {
        CraftDimensions dimensions = new(
            crafts.Select(c => new CharacterDimension(c.Game, c.Character)).Distinct().ToArray(),
            crafts.Where(c => c.RecipeId is not null)
                .Select(c => new RecipeDimension(c.Game, c.RecipeId!.Value, ProfessionId: c.ProfessionId,
                    ProfessionExpansionKey: c.ProfessionExpansionKey)).Distinct().ToArray(),
            crafts.Where(c => c.ProfessionId is not null)
                .Select(c => new ProfessionDimension(c.Game, c.ProfessionId!.Value)).Distinct().ToArray(),
            crafts.SelectMany(c => (c.Reagents ?? []).Select(r => new ItemDimension(c.Game, r.ItemId))
                .Concat((c.Outputs ?? []).Select(o => new ItemDimension(c.Game, o.ItemId)))).Distinct().ToArray(),
            crafts.Where(c => c.ProfessionExpansionKey is not null)
                .Select(c => new ExpansionDimension(c.Game, c.ProfessionExpansionKey!)).Distinct().ToArray());
        return new(crafts, dimensions);
    }

    private static string ReadFixture(string fileName) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fileName));

    private static bool CanRunLua()
    {
        try
        {
            using Process process = Process.Start(new ProcessStartInfo("lua")
            {
                ArgumentList = { "-v" },
                RedirectStandardOutput = true,
                RedirectStandardError = true
            }) ?? throw new InvalidOperationException();
            process.WaitForExit();
            return process.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static string FindRepositoryRoot()
    {
        foreach (string start in new[] { Environment.CurrentDirectory, AppContext.BaseDirectory })
        {
            DirectoryInfo? directory = new(start);
            while (directory is not null)
            {
                string ledger = Path.Combine(directory.FullName, "src", "addon", "src",
                    "ArtisanLogbook_Core", "Storage", "Ledger.lua");
                if (File.Exists(ledger)) return directory.FullName;
                directory = directory.Parent;
            }
        }
        throw new DirectoryNotFoundException("Could not locate the ArtisanLogbook repository root.");
    }

    private static string LuaQuote(string value) =>
        "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}
