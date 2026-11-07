using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.SavedVariables;

using DuckDB.NET.Data;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.ImportService;

[TestFixture]
public sealed class CompanionImportServiceIntegrationTests
{
    private string _directory = null!;
    private string _databasePath = null!;
    private Store _store = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.ImportService.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _databasePath = Path.Combine(_directory, "history.duckdb");
        _store = new Store(_databasePath);
    }

    [TearDown]
    public void TearDown()
    {
        _store.Dispose();
        if (Directory.Exists(_directory))
            Directory.Delete(_directory, recursive: true);
    }

    [Test]
    public async Task RepositorySnapshotPersistsCraftsDimensionsCoverageAndSurvivesReopen()
    {
        string source = ReadFixture("v1-outcome1.lua");
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(source);
        Assert.That(parsed.IsSuccessful, Is.True, string.Join(Environment.NewLine, parsed.Diagnostics));
        CraftHistory expected = parsed.History!;

        CompanionImportResult imported = await Importer().ImportSavedVariablesAsync(source, "v1-outcome1.lua");

        Assert.Multiple(() =>
        {
            Assert.That(imported.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(imported.TotalSourceCraftObservations, Is.EqualTo(expected.Crafts.Count));
            Assert.That(imported.InsertedCrafts, Is.EqualTo(expected.Crafts.Count));
            Assert.That(imported.AlreadyPresentCrafts, Is.Zero);
            Assert.That(imported.Coverage!.AggregateOnlyCraftCount, Is.GreaterThan(0));
            Assert.That(imported.CoverageWarnings.Any(d => d.Code == "aggregate-only-history"), Is.True);
            Assert.That(_store.ReadAll(), Is.EquivalentTo(expected.Crafts));
            Assert.That(imported.DimensionsInserted, Is.GreaterThan(0));
        });

        _store.Dispose();
        _store = new Store(_databasePath);
        CraftHistory restored = new(_store.ReadAll(), _store.ReadDimensions());
        Assert.That(restored.Crafts, Is.EquivalentTo(expected.Crafts));
        Assert.That(restored.Dimensions.Characters, Is.EquivalentTo(expected.Dimensions.Characters));
        Assert.That(restored.Dimensions.Recipes, Is.EquivalentTo(expected.Dimensions.Recipes));
        Assert.That(restored.Crafts.Any(craft => craft.Reagents is { Count: > 0 }), Is.True);
        Assert.That(restored.Crafts.Any(craft => craft.Outputs is { Count: > 0 }), Is.True);
        Assert.That(restored.Crafts.All(craft => craft.Game is not null), Is.True);
        Assert.That(restored.Crafts.Count, Is.EqualTo(imported.TotalSourceCraftObservations));
    }

    [Test]
    public async Task ReimportingAnIdenticalSnapshotIsIdempotent()
    {
        string source = ReadFixture("v1-outcome1.lua");
        CompanionImportResult first = await Importer().ImportSavedVariablesAsync(source);
        CompanionImportResult second = await Importer().ImportSavedVariablesAsync(source);

        Assert.Multiple(() =>
        {
            Assert.That(first.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(second.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(second.InsertedCrafts, Is.Zero);
            Assert.That(second.AlreadyPresentCrafts, Is.EqualTo(first.TotalSourceCraftObservations));
            Assert.That(second.EnrichedCrafts, Is.Zero);
            Assert.That(_store.ReadAll(), Has.Count.EqualTo(first.TotalSourceCraftObservations));
        });
    }

    [Test]
    public async Task CanonicalValidationErrorsAreReportedWithoutDatabaseChanges()
    {
        string invalid = """
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 0 } },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } }
              }
            }
            """;

        CompanionImportResult rejected = await Importer().ImportSavedVariablesAsync(invalid);

        Assert.Multiple(() =>
        {
            Assert.That(rejected.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
            Assert.That(rejected.ValidationErrors, Is.Not.Empty);
            Assert.That(_store.ReadAll(), Is.Empty);
            Assert.That(_store.ReadDimensions().Characters, Is.Empty);
        });
    }

    [Test]
    public async Task LaterCompatibleSnapshotEnrichesCraftAndDimensionWithoutDuplicates()
    {
        CompanionImportResult first = await Importer().ImportSavedVariablesAsync(Snapshot(
            outputQuantity: null,
            recipeName: null));
        CompanionImportResult second = await Importer().ImportSavedVariablesAsync(Snapshot(
            outputQuantity: 1,
            recipeName: "Recipe 77",
            includeItemName: true));

        Assert.Multiple(() =>
        {
            Assert.That(first.InsertedCrafts, Is.EqualTo(1));
            Assert.That(second.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(second.EnrichedCrafts, Is.EqualTo(1));
            Assert.That(second.InsertedCrafts, Is.Zero);
            Assert.That(second.DimensionsEnriched, Is.GreaterThan(0));
            Assert.That(_store.ReadAll(), Has.Count.EqualTo(1));
            Assert.That(_store.ReadAll().Single().Outputs, Is.EqualTo(new[] { new CraftOutput(99, null, 1) }));
            Assert.That(_store.ReadAll().Single().Reagents, Is.EqualTo(new[] { new CraftReagent(200, 2, 0) }));
            Assert.That(_store.ReadDimensions().Recipes.Single().Name, Is.EqualTo("Recipe 77"));
            Assert.That(_store.ReadDimensions().RecipeReagentSlots, Is.Empty,
                "Observed inputs and outputs are not recipe schematics.");
        });
    }

    [Test]
    public async Task ContradictoryCraftFactsRejectTheWholeSnapshotAndPreserveStoredHistory()
    {
        await Importer().ImportSavedVariablesAsync(Snapshot(
            outputQuantity: 1,
            recipeName: null));
        CraftObservation beforeCraft = _store.ReadAll().Single();
        CraftDimensions beforeDimensions = _store.ReadDimensions();

        CompanionImportResult rejected = await Importer().ImportSavedVariablesAsync(Snapshot(
            outputQuantity: 2,
            recipeName: "Late enrichment",
            includeExtraItem: true));

        Assert.Multiple(() =>
        {
            Assert.That(rejected.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
            Assert.That(rejected.CraftConflicts, Is.Not.Empty);
            Assert.That(rejected.RejectedOrConflictingCrafts, Is.EqualTo(1));
            Assert.That(rejected.InsertedCrafts, Is.Zero);
            Assert.That(_store.ReadAll().Single(), Is.EqualTo(beforeCraft));
            Assert.That(_store.ReadDimensions().Recipes.Single().Name, Is.EqualTo(
                beforeDimensions.Recipes.Single().Name));
            Assert.That(_store.ReadDimensions().Items.Any(item => item.Id == 999), Is.False);
        });
    }

    [Test]
    public async Task ConflictingDimensionFactsRejectTheWholeSnapshot()
    {
        await Importer().ImportSavedVariablesAsync(Snapshot(1, "Recipe 77", professionId: 171));
        CraftObservation beforeCraft = _store.ReadAll().Single();

        CompanionImportResult rejected = await Importer().ImportSavedVariablesAsync(Snapshot(
            1,
            "Recipe 77",
            includeExtraItem: true,
            professionId: 172));

        Assert.Multiple(() =>
        {
            Assert.That(rejected.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
            Assert.That(rejected.DimensionConflicts, Is.Not.Empty);
            Assert.That(rejected.RejectedOrConflictingCrafts, Is.EqualTo(1));
            Assert.That(_store.ReadAll().Single(), Is.EqualTo(beforeCraft));
            Assert.That(_store.ReadDimensions().Recipes.Single().ProfessionId, Is.EqualTo(171));
            Assert.That(_store.ReadDimensions().Items.Any(item => item.Id == 999), Is.False);
        });
    }

    [Test]
    public async Task MalformedAndUnsupportedSnapshotsAreRejectedWithoutDatabaseChanges()
    {
        await Importer().ImportSavedVariablesAsync(Snapshot(1, null));
        CraftObservation before = _store.ReadAll().Single();

        CompanionImportResult malformed = await Importer().ImportSavedVariablesAsync(
            "ArtisanLogbookDB = { schemaVersion = 4,");
        CompanionImportResult unsupported = await Importer().ImportSavedVariablesAsync(
            "ArtisanLogbookDB = { schemaIdentity = \"ArtisanLogbookLedger\", schemaVersion = 6 }");

        Assert.Multiple(() =>
        {
            Assert.That(malformed.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
            Assert.That(malformed.SourceDiagnostics.Any(d => d.Code == "malformed-lua"), Is.True);
            Assert.That(unsupported.Outcome, Is.EqualTo(CompanionImportOutcome.Rejected));
            Assert.That(unsupported.SourceDiagnostics.Any(d => d.Code == "unsupported-schema"), Is.True);
            Assert.That(_store.ReadAll(), Is.EqualTo(new[] { before }));
        });
    }

    [Test]
    public async Task DifferentCharactersAndGameContextsRemainIsolated()
    {
        string source = """
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = {
                { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77, outputItemId = 99, outputQuantity = 1 },
                { id = 2, sessionId = 2, timestamp = 1800000001, recipeId = 77, outputItemId = 99, outputQuantity = 1 }
              },
              dimensions = {
                sessions = {
                  { id = 1, key = "retail-session", projectId = 1, characterDimensionId = 1 },
                  { id = 2, key = "mists-session", projectId = 19, companionProgressionTrack = "mists-progression", characterDimensionId = 2 }
                },
                characters = {
                  { id = 1, key = "project:1:region:3:realm:1309:guid:Player-Retail" },
                  { id = 2, key = "project:19:region:3:realm:1309:guid:Player-Mists" }
                },
                recipes = { [77] = { id = 77 } },
                items = { [99] = { id = 99 } }
              }
            }
            """;

        CompanionImportResult imported = await Importer().ImportSavedVariablesAsync(source);
        IReadOnlyList<CraftObservation> crafts = _store.ReadAll();
        CraftDimensions dimensions = _store.ReadDimensions();

        Assert.Multiple(() =>
        {
            Assert.That(imported.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(crafts, Has.Count.EqualTo(2));
            Assert.That(crafts.Select(craft => craft.Game.Project).Distinct(),
                Is.EquivalentTo(new[] { GameProject.Retail, GameProject.MistsClassic }));
            Assert.That(dimensions.Recipes.Where(recipe => recipe.Id == 77)
                .Select(recipe => recipe.Game).Distinct().Count(), Is.EqualTo(2));
            Assert.That(dimensions.Items.Where(item => item.Id == 99)
                .Select(item => item.Game).Distinct().Count(), Is.EqualTo(2));
            Assert.That(crafts.Single(craft => craft.Game.Project == GameProject.MistsClassic).Game.ProgressionTrack,
                Is.EqualTo("mists-progression"));
        });
    }

    [Test]
    public async Task UnknownResourcefulnessAndObservedZerosRemainDistinct()
    {
        SavedVariablesImportResult parsed = SavedVariablesReader.Parse(ReadFixture("v1-outcome1.lua"));
        CraftObservation unknown = parsed.History!.Crafts.First(craft => craft.HasResourcefulnessProc is null);
        CraftObservation explicitZero = parsed.History.Crafts.First(craft =>
            craft.ConcentrationSpent == 0 && craft.HasIngenuityProc == false);

        CompanionImportResult imported = await Importer().ImportSavedVariablesAsync(
            ReadFixture("v1-outcome1.lua"));

        CraftObservation restoredUnknown = _store.Read(unknown.Identity)!;
        CraftObservation restoredZero = _store.Read(explicitZero.Identity)!;
        Assert.Multiple(() =>
        {
            Assert.That(imported.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(restoredUnknown.HasResourcefulnessProc, Is.Null);
            Assert.That(restoredUnknown.ResourcefulnessComplete, Is.Null);
            Assert.That(restoredZero.ConcentrationSpent, Is.Zero);
            Assert.That(restoredZero.HasIngenuityProc, Is.False);
        });
    }

    [Test]
    public async Task MultipleOutputCallbacksAreStoredAsEvidenceOnOneCraft()
    {
        CompanionImportResult imported = await Importer().ImportSavedVariablesAsync(SchemaFiveSnapshot(2));
        CraftObservation restored = _store.ReadAll().Single();

        Assert.Multiple(() =>
        {
            Assert.That(imported.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(imported.TotalSourceCraftObservations, Is.EqualTo(1));
            Assert.That(imported.InsertedCrafts, Is.EqualTo(1));
            Assert.That(restored.OutputEvidence, Has.Count.EqualTo(1));
            Assert.That(restored.OutputEvidence![0].Callbacks, Has.Count.EqualTo(2));
            Assert.That(restored.Outputs, Has.Count.EqualTo(1));
        });
    }

    [Test]
    public async Task AdditionalOutputEvidenceEnrichesTheSameCraftAndReplaysIdempotently()
    {
        await Importer().ImportSavedVariablesAsync(SchemaFiveSnapshot(1));
        CompanionImportResult enriched = await Importer().ImportSavedVariablesAsync(SchemaFiveSnapshot(2));
        CraftObservation afterEnrichment = _store.ReadAll().Single();
        CompanionImportResult replay = await Importer().ImportSavedVariablesAsync(SchemaFiveSnapshot(2));

        Assert.Multiple(() =>
        {
            Assert.That(enriched.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(enriched.EnrichedCrafts, Is.EqualTo(1));
            Assert.That(afterEnrichment.OutputEvidence, Has.Count.EqualTo(2));
            Assert.That(afterEnrichment.OutputEvidence!.Select(evidence => evidence.Callbacks.Count),
                Is.EquivalentTo(new[] { 1, 2 }));
            Assert.That(replay.AlreadyPresentCrafts, Is.EqualTo(1));
            Assert.That(_store.ReadAll(), Has.Count.EqualTo(1));
        });
    }

    [Test]
    public async Task RecipeSlotsAreImportedOnlyFromSufficientSavedSchematicEvidence()
    {
        string source = MakeImportableSchemaThreeSnapshot();
        CompanionImportResult imported = await Importer().ImportSavedVariablesAsync(source);

        Assert.That(imported.Outcome, Is.EqualTo(CompanionImportOutcome.Successful),
            string.Join(Environment.NewLine, imported.SourceDiagnostics));
        RecipeReagentSlot slot = _store.ReadDimensions().RecipeReagentSlots.Single();
        Assert.Multiple(() =>
        {
            Assert.That(slot.DataSlotIndex, Is.EqualTo(2));
            Assert.That(slot.CandidateItemIds, Is.EquivalentTo(new[] { 9, 10 }));
            Assert.That(slot.RequiredQuantity, Is.EqualTo(5));
            Assert.That(slot.DataSlotType, Is.Null);
            Assert.That(slot.SlotIndex, Is.Null);
        });
    }

    [Test]
    public async Task LateDatabaseFailureRollsBackEarlierCraftsAndDimensionEnrichment()
    {
        _store.Dispose();
        using (DuckDBConnection connection = new($"Data Source={_databasePath}"))
        {
            connection.Open();
            using DuckDBCommand command = connection.CreateCommand();
            command.CommandText = "CREATE UNIQUE INDEX TestUniqueBatchOutputQuantity ON CraftOutput (Quantity)";
            command.ExecuteNonQuery();
        }
        _store = new Store(_databasePath);

        CompanionImportResult result = await Importer().ImportSavedVariablesAsync(TwoCraftSnapshot);

        Assert.Multiple(() =>
        {
            Assert.That(result.Outcome, Is.EqualTo(CompanionImportOutcome.Failed));
            Assert.That(result.PersistenceDiagnostics.Single().Code, Is.EqualTo("history-store-failure"));
            Assert.That(_store.ReadAll(), Is.Empty);
            Assert.That(_store.ReadDimensions().Recipes, Is.Empty);
            Assert.That(_store.ReadDimensions().Items, Is.Empty);
        });
    }

    [Test]
    public async Task FileApiImportsItsCapturedSnapshotAndReportsReadFailures()
    {
        string path = Path.Combine(_directory, "snapshot.lua");
        await File.WriteAllTextAsync(path, Snapshot(1, "Recipe 77"));

        CompanionImportResult imported = await Importer().ImportSavedVariablesFileAsync(path);
        CompanionImportResult missing = await Importer().ImportSavedVariablesFileAsync(
            Path.Combine(_directory, "missing.lua"));

        Assert.Multiple(() =>
        {
            Assert.That(imported.Outcome, Is.EqualTo(CompanionImportOutcome.Successful));
            Assert.That(imported.InsertedCrafts, Is.EqualTo(1));
            Assert.That(missing.Outcome, Is.EqualTo(CompanionImportOutcome.Failed));
            Assert.That(missing.InputDiagnostics.Single().Code, Is.EqualTo("source-read-failed"));
        });
    }

    [Test]
    public void CancellationBeforeImportDoesNotWriteHistory()
    {
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();

        Assert.ThrowsAsync<OperationCanceledException>(async () =>
            await Importer().ImportSavedVariablesAsync(Snapshot(1, null), cancellationToken: cancellation.Token));
        Assert.That(_store.ReadAll(), Is.Empty);
    }

    private CompanionImportService Importer() => new(_store);

    private static string Snapshot(
        int? outputQuantity,
        string? recipeName,
        bool includeItemName = false,
        bool includeExtraItem = false,
        int? professionId = null)
    {
        string output = outputQuantity is null
            ? "outputItemId = 99"
            : $"outputItemId = 99, outputQuantity = {outputQuantity.Value}";
        string recipe = recipeName is null
            ? ""
            : $", recipes = {{ [77] = {{ id = 77, name = \"{recipeName}\"{(professionId is null ? "" : $", professionId = {professionId.Value}")} }} }}";
        string items = includeItemName
            ? ", items = { [99] = { id = 99, name = \"Known item\" } }"
            : includeExtraItem
                ? ", items = { [99] = { id = 99 }, [999] = { id = 999, name = \"Late item\" } }"
                : "";
        return $$"""
            ArtisanLogbookDB = {
              schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
              crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77, {{output}} } },
              reagents = {
                { craftId = 1, dataSlotIndex = 1, itemId = 200, allocatedQuantity = 2, returnedQuantity = 0 }
              },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } }
                {{recipe}}{{items}}
              }
            }
            """;
    }

    private static string SchemaFiveSnapshot(int callbackCount)
    {
        string callbackRows = callbackCount switch
        {
            1 => """
                { itemId = 900001, quantity = 1, timestamp = 1800000001, measurements = {}, returns = {} }
                """,
            2 => """
                { itemId = 900001, quantity = 1, timestamp = 1800000001, measurements = {}, returns = {}, quantityAmbiguous = true },
                { itemId = 900001, quantity = 1, timestamp = 1800000002, measurements = {}, returns = {}, quantityAmbiguous = true }
                """,
            _ => throw new ArgumentOutOfRangeException(nameof(callbackCount))
        };
        string summary = callbackCount == 1
            ? "outputQuantity = 1,"
            : "outputAmbiguous = true,";
        return $$"""
            ArtisanLogbookDB = {
              schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
              crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77,
                gameOperationId = 3533599395, attemptKind = "salvage-operation", {{summary}}
                outcomeSource = "unverified", companionOutputEvidenceComplete = false, outputs = {
                  {{callbackRows}}
                } } },
              dimensions = {
                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                items = { [900001] = { id = 900001 } }
              }
            }
            """;
    }

    private const string TwoCraftSnapshot = """
        ArtisanLogbookDB = {
          schemaIdentity = "ArtisanLogbookLedger", schemaVersion = 4,
          crafts = {
            { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 77, outputItemId = 99, outputQuantity = 1 },
            { id = 2, sessionId = 1, timestamp = 1800000001, recipeId = 78, outputItemId = 100, outputQuantity = 1 }
          },
          dimensions = {
            sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
            characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
            recipes = {
              [77] = { id = 77, name = "Batch recipe one" },
              [78] = { id = 78, name = "Batch recipe two" }
            },
            items = { [99] = { id = 99 }, [100] = { id = 100 } }
          }
        }
        """;

    private static string MakeImportableSchemaThreeSnapshot()
    {
        string source = ReadFixture("ledger-schema3.lua");
        LuaDocument document = LuaDataParser.Parse(source);
        LuaTable ledger = (LuaTable)document.ReturnedValue!;
        LuaTable dimensions = (LuaTable)ledger.Get("dimensions")!;
        LuaTable session = ((LuaTable)dimensions.Get("sessions")!).Values.OfType<LuaTable>().Single();
        LuaTable character = ((LuaTable)dimensions.Get("characters")!).Values.OfType<LuaTable>().Single();
        session["projectId"] = 1d;
        character["key"] = "project:1:region:3:realm:1309:guid:Player-Schema3";
        return LuaDataParser.Serialize(new(
            new Dictionary<string, object?> { ["ArtisanLogbookDB"] = ledger },
            null));
    }

    private static string ReadFixture(string fileName) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", fileName));
}
