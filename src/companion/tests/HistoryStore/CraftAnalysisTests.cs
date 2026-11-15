using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class CraftAnalysisTests
{
    private static readonly GameContext Retail = new(GameProject.Retail);
    private static readonly GameContext Forever = new(GameProject.Forever);
    private string _directory = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(TestContext.CurrentContext.WorkDirectory, "analysis-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public void ActualOutputsGrossAllocationsReturnsAndCoverageAreIndependent()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-02-01T12:00:00Z");
        CraftObservation first = Craft("one", Retail, time) with
        {
            Outputs = [new(50, 2, 4), new(51, null, 2)],
            OutputsComplete = true,
            Reagents = [new(50, 9, 1.25m), new(60, 3, 0m)],
            InputsComplete = true,
            ResourcefulnessComplete = true,
            HasResourcefulnessProc = true,
            HasIngenuityProc = false,
            MulticraftBonus = 2
        };
        CraftObservation incomplete = Craft("two", Retail, time.AddDays(-1)) with
        {
            Outputs = [new(50, 2, null)],
            OutputsComplete = false,
            Reagents = [new(50, null, null)],
            InputsComplete = false
        };
        foreach (CraftObservation craft in new[] { first, incomplete, Craft("other", Forever, time) })
            Assert.That(store.Write(craft).IsSuccessful, Is.True);

        CraftAnalysis result = store.Analyze(new(new(Game: Retail)));
        Assert.Multiple(() =>
        {
            Assert.That(result.Attempts.Attempts, Is.EqualTo("2"));
            Assert.That(result.ConfigurationCoverage.UnknownAttempts, Is.EqualTo("2"));
            Assert.That(result.ConfigurationCoverage.RecordedAttempts, Is.EqualTo("0"));
            Assert.That(result.Outputs.Nodes.Single(x => x.Key == "50").Measure.Quantity, Is.EqualTo("4"));
            Assert.That(result.Outputs.Nodes.Single(x => x.Key == "50").Measure.IncompleteAttempts, Is.EqualTo("1"));
            Assert.That(result.Outputs.Nodes.Single(x => x.Key == "51").Measure.Quantity, Is.EqualTo("2"));
            Assert.That(result.Inputs.Nodes.Single(x => x.Key == "50").Measure.Quantity, Is.EqualTo("9"));
            Assert.That(result.Returns.Nodes.Single(x => x.Key == "50").Measure.Quantity, Is.EqualTo("1.2500000000000000000000000000"));
            Assert.That(result.Recipes.Nodes.Single().Multicraft.Total, Is.EqualTo("2"));
            Assert.That(result.Recipes.Nodes.Single().Ingenuity.ObservedAttempts, Is.EqualTo("1"));
            Assert.That(store.Analyze(new(new(Game: Forever))).Returns.Nodes, Is.Empty);
        });
        Assert.That(store.QueryCrafts(new(Game: Retail, ReturnedItemId: 50)).Crafts.Select(x => x.Facts.Identity.Observation),
            Is.EqualTo(new[] { "one" }));
        Assert.That(store.QueryCrafts(new(Game: Retail, ItemId: 50)).Crafts, Has.Count.EqualTo(2));
        AnalysisItemRelations relations = store.Analyze(new(new(Game: Retail, ItemId: 50))).ItemRelations!;
        Assert.Multiple(() =>
        {
            Assert.That(relations.Outputs.Nodes.Single().Measure.Quantity, Is.EqualTo("4"));
            Assert.That(relations.Inputs.Nodes.Single().Measure.Quantity, Is.EqualTo("9"));
            Assert.That(relations.Returns!.Nodes.Single().Measure.Quantity,
                Is.EqualTo("1.2500000000000000000000000000"));
            Assert.That(relations.Outputs.Nodes.Single().Measure.IncompleteAttempts, Is.EqualTo("1"));
        });
    }

    [Test]
    public void CharacterReturnMeasureUsesTheWholePopulationAndPreservesUnknowns()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-02-01T12:00:00Z");
        CraftObservation[] crafts =
        [
            Craft("positive", Retail, time) with { Reagents = [new(50, 2, 1.25m)],
                ResourcefulnessComplete = true, HasResourcefulnessProc = true },
            Craft("zero", Retail, time) with { Reagents = [new(50, 2, 0m)],
                ResourcefulnessComplete = true, HasResourcefulnessProc = false },
            Craft("absent", Retail, time) with { Reagents = [new(60, 2, 0m)],
                ResourcefulnessComplete = true, HasResourcefulnessProc = false },
            Craft("unknown", Retail, time) with { Reagents = [new(50, 2, null)],
                ResourcefulnessComplete = true, HasResourcefulnessProc = false },
            Craft("incomplete", Retail, time) with { Reagents = [new(50, 2, 0.5m)],
                ResourcefulnessComplete = false, HasResourcefulnessProc = true },
            Craft("unobserved", Retail, time) with { Reagents = null,
                ResourcefulnessComplete = true, HasResourcefulnessProc = false },
            Craft("other-context", Forever, time) with { Reagents = [new(50, 2, 9m)] }
        ];
        foreach (CraftObservation craft in crafts)
            Assert.That(store.Write(craft).IsSuccessful, Is.True, craft.Identity.Observation);
        CraftAnalysis analysis = store.Analyze(new(new(Game: Retail), ReturnItemId: 50));
        Assert.That(analysis.Characters.Nodes.Single().ReturnedItem,
            Is.EqualTo(new AnalysisMeasure("6", "3", "3", "1.2500000000000000000000000000")));
        Assert.That(store.Analyze(new(new(Game: Retail), ReturnItemId: 99)).Characters.Nodes.Single().ReturnedItem,
            Is.EqualTo(new AnalysisMeasure("6", "4", "2", "0.0000000000000000000000000000")));
        Assert.That(() => store.Analyze(new(new(Game: Forever), ReturnItemId: 50)),
            Throws.TypeOf<ArgumentOutOfRangeException>());
        foreach (decimal value in new[] { 0.9999999999999999999999999999m, 0.0000000000000000000000000001m })
            Assert.That(store.Write(Craft(value.ToString(), Retail, time) with
            {
                Character = new("precise"),
                Reagents = [new(50, 2, value)],
                ResourcefulnessComplete = true,
                HasResourcefulnessProc = true
            }).IsSuccessful, Is.True);
        Assert.That(store.Analyze(new(new(Game: Retail, Character: new("precise")), ReturnItemId: 50))
            .Characters.Nodes.Single().ReturnedItem!.Quantity, Is.EqualTo("1.0000000000000000000000000000"));
    }

    [TestCase(GameProject.ClassicEra)]
    [TestCase((GameProject)999)]
    public void NonRetailProjectsPreserveScopedProductionWithoutReturnRankings(GameProject project)
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        GameContext context = new(project, "track");
        DateTimeOffset time = DateTimeOffset.Parse("2026-03-01T00:00:00Z");
        CraftObservation recorded = Craft("selected", context, time) with
        {
            RecipeId = 42,
            Outputs = [new(50, null, 3)],
            OutputsComplete = true,
            Reagents = [new(60, 5, 0.75m)],
            InputsComplete = true,
            HasResourcefulnessProc = true
        };
        Assert.That(store.Write(recorded).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("other-track", new(project, "other"), time) with
        {
            RecipeId = 42,
            Outputs = [new(50, null, 7)]
        }).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("retail", Retail, time) with
        {
            RecipeId = 42,
            Outputs = [new(50, null, 11)],
            Reagents = [new(60, 5, 1m)]
        }).IsSuccessful, Is.True);

        CraftAnalysis result = store.Analyze(new(new(Game: context, ItemId: 60)));
        Assert.Multiple(() =>
        {
            Assert.That(result.Attempts.Attempts, Is.EqualTo("1"));
            Assert.That(result.Recipes.Nodes.Single().RecipeId, Is.EqualTo(42));
            Assert.That(result.Outputs.Nodes.Single().Measure.Quantity, Is.EqualTo("3"));
            Assert.That(result.Inputs.Nodes.Single().Measure.Quantity, Is.EqualTo("5"));
            Assert.That(result.Returns.Nodes, Is.Empty);
            Assert.That(result.Returns.Truncated, Is.False);
            Assert.That(result.ItemRelations!.Inputs.Nodes.Single().Measure.Quantity, Is.EqualTo("5"));
            Assert.That(result.ItemRelations.Returns, Is.Null);
            Assert.That(store.QueryCrafts(new(Game: context, ItemId: 60)).Crafts.Single()
                .Facts.Identity.Observation, Is.EqualTo("selected"));
            Assert.That(store.Analyze(new(new(Game: Retail))).Returns.Nodes.Single()
                .Measure.Quantity, Does.StartWith("1."));
        });
    }

    [Test]
    public void PopulationFiltersAndSignaturesChangeOnlyForRelevantEnrichment()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-02-01T12:00:00Z");
        CraftObservation selected = Craft("selected", Retail, time) with
        {
            RecipeId = 12,
            Character = new("A"),
            Reagents = [new(55, 1, null)],
            ConfigurationEvidence = [new("source", 1, "CraftConfigurationEvidence = { conditions = { useConcentration = false }, craftFields = { configurationScope = \"request\" } }")]
        };
        foreach (CraftObservation craft in new[]
        {
            selected,
            Craft("earlier", Retail, time.AddDays(-30)) with { RecipeId = 12, Character = new("A") },
            Craft("other-recipe", Retail, time) with { RecipeId = 13, Character = new("B") },
            Craft("other-context", Forever, time) with { RecipeId = 12, Character = new("A") }
        })
            Assert.That(store.Write(craft).IsSuccessful, Is.True);

        CraftQuery scope = new(Game: Retail, RecipeId: 12, Character: new("A"),
            From: time.AddDays(-1), To: time.AddDays(1), InputItemId: 55);
        CraftAnalysis result = store.Analyze(new(scope));
        Assert.That(result.Attempts.Attempts, Is.EqualTo("1"));
        Assert.That(result.ConfigurationCoverage.RecordedAttempts, Is.EqualTo("1"));
        Assert.That(result.ConfigurationCoverage.UnknownAttempts, Is.EqualTo("0"));
        Assert.That(result.Configurations.Nodes, Has.Count.EqualTo(1));
        string configuration = result.Configurations.Nodes.Single().Signature;
        Assert.That(store.Analyze(new(scope with { ConfigurationSignature = configuration })).Attempts.Attempts, Is.EqualTo("1"));
        Assert.That(store.QueryCrafts(scope with { ConfigurationSignature = configuration }).Crafts, Has.Count.EqualTo(1));
        string signature = store.AnalysisSignature(scope);
        Assert.That(store.AnalysisSignature(scope with { To = time.AddDays(2) }), Is.Not.EqualTo(signature));
        Assert.That(store.Write(Craft("new-unrelated", Forever, time)).IsSuccessful, Is.True);
        Assert.That(store.AnalysisSignature(scope), Is.EqualTo(signature));
        Assert.That(store.Write(selected with
        {
            HasIngenuityProc = false,
            ConfigurationEvidence = [.. selected.ConfigurationEvidence!, new("source", 2, "CraftConfigurationEvidence = { conditions = { useConcentration = true } }")]
        }).Status,
            Is.EqualTo(CraftWriteStatus.Enriched));
        Assert.That(store.AnalysisSignature(scope), Is.Not.EqualTo(signature));
        string enriched = store.AnalysisSignature(scope);
        Assert.That(store.Write(Craft("another", Retail, time) with
        {
            RecipeId = 12,
            Character = new("A"),
            Reagents = [new(55, 2, null)]
        }).IsSuccessful, Is.True);
        Assert.That(store.AnalysisSignature(scope), Is.Not.EqualTo(enriched));
        string beforeMetadata = store.AnalysisSignature(scope);
        Assert.That(store.WriteDimensions(new([], [new(Retail, 12, "Named recipe")], [], [], []))
            .IsSuccessful, Is.True);
        Assert.That(store.AnalysisSignature(scope), Is.Not.EqualTo(beforeMetadata));
    }

    [Test]
    public void BoundsAndPreCancelledOperationsAreEnforced()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        for (int id = 1; id <= 102; id++)
            Assert.That(store.Write(Craft(id.ToString(), Retail, DateTimeOffset.Parse("2026-01-01T00:00:00Z"))
                with
            { RecipeId = id, Outputs = [new(50, null, 1)], OutputsComplete = true }).IsSuccessful, Is.True);
        CraftAnalysis result = store.Analyze(new(new(Game: Retail)));
        Assert.That(result.Recipes.Nodes, Has.Count.EqualTo(100));
        Assert.That(result.Recipes.Truncated, Is.True);
        AnalysisItemRelations relations = store.Analyze(new(new(Game: Retail, ItemId: 50))).ItemRelations!;
        Assert.That(relations.Outputs.Nodes, Has.Count.EqualTo(100));
        Assert.That(relations.Outputs.Truncated, Is.True);
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => store.Analyze(new(new(Game: Retail)), cancellation.Token));
        Assert.Throws<ArgumentException>(() => store.Analyze(new(new())));
    }

    [Test]
    public void ReturnSumsPreserveAllDecimalPlacesAndLargeWholeQuantities()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-03-01T00:00:00Z");
        Assert.That(store.Write(Craft("fraction", Retail, time) with
        {
            Reagents = [new(50, 1, 0.0000000000000000000000000001m)]
        }).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("large", Retail, time) with
        {
            Reagents = [new(50, 1, 1000000000000000000000000000m)]
        }).IsSuccessful, Is.True);
        Assert.That(store.Analyze(new(new(Game: Retail))).Returns.Nodes.Single().Measure.Quantity,
            Is.EqualTo("1000000000000000000000000000.0000000000000000000000000001"));
    }

    [Test]
    public void ReturnItemRankingCarriesFractionsBeforeSortingWithStableTies()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-03-01T00:00:00Z");
        (string CraftId, int ItemId, decimal? Returned)[] observations =
        [
            ("first", 10, 0.9m),
            ("second", 10, 0.9m),
            ("third", 20, 1.1m),
            ("fourth", 30, 1.8m),
            ("unknown", 40, null)
        ];
        foreach ((string craftId, int itemId, decimal? returned) in observations)
            Assert.That(store.Write(Craft(craftId, Retail, time) with
            {
                Reagents = [new(itemId, 1, returned)]
            }).IsSuccessful, Is.True);

        IReadOnlyList<AnalysisContribution> ranked = store.Analyze(new(new(Game: Retail))).Returns.Nodes;
        Assert.That(ranked.Select(row => row.Key), Is.EqualTo(new[] { "10", "30", "20", "40" }));
        Assert.Multiple(() =>
        {
            Assert.That(ranked[0].Measure.Quantity, Is.EqualTo("1.8000000000000000000000000000"));
            Assert.That(ranked[1].Measure.Quantity, Is.EqualTo(ranked[0].Measure.Quantity));
            Assert.That(ranked[2].Measure.Quantity, Is.EqualTo("1.1000000000000000000000000000"));
            Assert.That(ranked[3].Measure.Quantity, Is.Null);
        });
    }

    [Test]
    public void ReturnRecipeCharacterRankingCarriesFractionsBeforeSortingWithStableTies()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-03-01T00:00:00Z");
        (string CraftId, int RecipeId, string Character, decimal? Returned)[] observations =
        [
            ("first", 10, "A", 0.9m),
            ("second", 10, "A", 0.9m),
            ("third", 20, "B", 1.1m),
            ("fourth", 30, "C", 1.8m),
            ("unknown", 40, "D", null)
        ];
        foreach ((string craftId, int recipeId, string character, decimal? returned) in observations)
            Assert.That(store.Write(Craft(craftId, Retail, time) with
            {
                RecipeId = recipeId,
                Character = new(character),
                Reagents = [new(90, 1, returned)]
            }).IsSuccessful, Is.True);

        IReadOnlyList<AnalysisItemRelation> ranked =
            store.Analyze(new(new(Game: Retail, ItemId: 90))).ItemRelations!.Returns!.Nodes;
        Assert.That(ranked.Select(row => row.RecipeId), Is.EqualTo(new int?[] { 10, 30, 20, 40 }));
        Assert.Multiple(() =>
        {
            Assert.That(ranked[0].Measure.Quantity, Is.EqualTo("1.8000000000000000000000000000"));
            Assert.That(ranked[1].Measure.Quantity, Is.EqualTo(ranked[0].Measure.Quantity));
            Assert.That(ranked[2].Measure.Quantity, Is.EqualTo("1.1000000000000000000000000000"));
            Assert.That(ranked[3].Measure.Quantity, Is.Null);
        });
    }

    [Test]
    public async Task MultiStatementAnalysisRetainsOneReadSnapshotDuringEnrichment()
    {
        using ManualResetEventSlim selected = new();
        using ManualResetEventSlim resume = new();
        using Store store = new(Path.Combine(_directory, "history.duckdb"))
        {
            ReadCheckpoint = checkpoint =>
            {
                if (checkpoint != "AnalysisSignature") return;
                selected.Set();
                if (!resume.Wait(TimeSpan.FromSeconds(20)))
                    throw new TimeoutException("Analysis snapshot did not resume.");
            }
        };
        CraftObservation first = Craft("one", Retail, DateTimeOffset.Parse("2026-01-01T00:00:00Z"));
        Assert.That(store.Write(first).IsSuccessful, Is.True);
        Task<CraftAnalysis> read = Task.Run(() => store.Analyze(new(new(Game: Retail))));
        try
        {
            Assert.That(selected.Wait(TimeSpan.FromSeconds(20)), Is.True);
            Assert.That(store.Write(Craft("two", Retail, first.RecordedAt)).IsSuccessful, Is.True);
        }
        finally
        {
            resume.Set();
        }
        Assert.That((await read.WaitAsync(TimeSpan.FromSeconds(20))).Attempts.Attempts, Is.EqualTo("1"));
    }

    [Test]
    public void BuffAndFinishingFiltersRequirePositiveEvidenceFromTheSameVariant()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-04-01T00:00:00Z");
        string positive = """
            CraftConfigurationEvidence = {conditions = {buffs = {[1] = {spellID = 432306}},
                finishingReagents = {[1] = {itemID = 222, quantity = 2}}},
                craftFields = {buffsCoverage = "supported-list", finishingCoverage = "submitted"}}
            """;
        string other = """
            CraftConfigurationEvidence = {conditions = {buffs = {}, finishingReagents = {}},
                craftFields = {buffsCoverage = "supported-list", finishingCoverage = "submitted"}}
            """;
        Assert.That(store.Write(Craft("positive", Retail, time) with
        {
            ConfigurationEvidence = [new("source", 1, positive)]
        }).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("empty", Retail, time) with
        {
            ConfigurationEvidence = [new("source", 2, other)]
        }).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("unknown", Retail, time)).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("split-variants", Retail, time) with
        {
            ConfigurationEvidence =
            [
                new("source", 3, """
                    CraftConfigurationEvidence = {conditions = {buffs = {[1] = {spellID = 432306}}, finishingReagents = {}},
                        craftFields = {buffsCoverage = "supported-list", finishingCoverage = "submitted"}}
                    """),
                new("source", 4, """
                    CraftConfigurationEvidence = {conditions = {buffs = {}, finishingReagents = {[1] = {itemID = 222}}},
                        craftFields = {buffsCoverage = "supported-list", finishingCoverage = "submitted"}}
                    """)
            ]
        }).IsSuccessful, Is.True);
        CraftQuery matching = new(Game: Retail, BuffSpellId: 432306, FinishingItemId: 222);
        Assert.Multiple(() =>
        {
            Assert.That(store.Analyze(new(matching)).Attempts.Attempts, Is.EqualTo("1"));
            Assert.That(store.QueryCrafts(matching).Crafts.Select(row => row.Facts.Identity.Observation),
                Is.EqualTo(new[] { "positive" }));
            Assert.That(store.Analyze(new(matching with { BuffSpellId = 43230 })).Attempts.Attempts, Is.EqualTo("0"));
            Assert.That(store.Analyze(new(matching with { FinishingItemId = 22 })).Attempts.Attempts, Is.EqualTo("0"));
            Assert.That(store.Analyze(new(new(Game: Retail, AbsentBuffSpellId: 432306,
                AbsentFinishingItemId: 222))).Attempts.Attempts, Is.EqualTo("1"));
            Assert.That(store.QueryCrafts(new(Game: Retail, AbsentBuffSpellId: 432306))
                .Crafts.Select(row => row.Facts.Identity.Observation), Is.EqualTo(new[] { "empty", "split-variants" }));
        });
    }

    [Test]
    public void FinishingAllocationsAreGroupedByCharacterAndPreserveIncompleteEvidence()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-04-01T00:00:00Z");
        const string payload = """
            CraftConfigurationEvidence = {conditions = {finishingReagents = {[1] = {itemID = 222, quantity = 2}}},
                craftFields = {finishingCoverage = "submitted"}}
            """;
        CraftObservation Make(string id, string character, long? quantity, bool? complete, GameContext game) =>
            Craft(id, game, time) with
            {
                Character = new(character),
                Reagents = [new(222, quantity, null)],
                InputsComplete = complete,
                ConfigurationEvidence = [new("source", 1, payload)]
            };
        foreach (CraftObservation craft in new[]
        {
            Make("a1", "a", 2, true, Retail), Make("a2", "a", 3, true, Retail),
            Make("b1", "b", null, null, Retail), Make("b2", "b", 4, false, Retail),
            Make("other-context", "a", 100, true, Forever)
        })
            Assert.That(store.Write(craft).IsSuccessful, Is.True);

        CraftAnalysis result = store.Analyze(new(new(Game: Retail, FinishingItemId: 222)));
        AnalysisMeasure a = result.Characters.Nodes.Single(row => row.Key == "a").FinishingAllocation!;
        AnalysisMeasure b = result.Characters.Nodes.Single(row => row.Key == "b").FinishingAllocation!;
        Assert.Multiple(() =>
        {
            Assert.That(a, Is.EqualTo(new AnalysisMeasure("2", "2", "0", "5")));
            Assert.That(b, Is.EqualTo(new AnalysisMeasure("2", "0", "2", "4")));
            Assert.That(store.Analyze(new(new(Game: Retail))).Characters.Nodes
                .All(row => row.FinishingAllocation is null), Is.True);
        });
    }

    [Test]
    public void AbsentFinishingAllocationRequiresCompleteInputEvidence()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-04-01T00:00:00Z");
        const string payload = """
            CraftConfigurationEvidence = {conditions = {finishingReagents = {}},
                craftFields = {finishingCoverage = "submitted"}}
            """;
        CraftObservation Make(string id, string character, IReadOnlyList<CraftReagent>? reagents, bool? complete) =>
            Craft(id, Retail, time) with
            {
                Character = new(character),
                Reagents = reagents,
                InputsComplete = complete,
                ConfigurationEvidence = [new("source", 1, payload)]
            };
        foreach (CraftObservation craft in new[]
        {
            Make("absent", "a", [], true), Make("other-role", "b", [new(222, 3, null)], true),
            Make("unknown", "c", null, null)
        })
            Assert.That(store.Write(craft).IsSuccessful, Is.True);

        CraftAnalysis result = store.Analyze(new(new(Game: Retail, AbsentFinishingItemId: 222)));
        Assert.Multiple(() =>
        {
            Assert.That(result.Characters.Nodes.Single(row => row.Key == "a").FinishingAllocation,
                Is.EqualTo(new AnalysisMeasure("1", "1", "0", "0")));
            Assert.That(result.Characters.Nodes.Single(row => row.Key == "b").FinishingAllocation,
                Is.EqualTo(new AnalysisMeasure("1", "1", "0", "3")));
            Assert.That(result.Characters.Nodes.Single(row => row.Key == "c").FinishingAllocation,
                Is.EqualTo(new AnalysisMeasure("1", "0", "1", null)));
        });
    }

    [Test]
    public void InputAbsenceAndResourceAllocationsRequireCompleteEvidence()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-04-01T00:00:00Z");
        CraftObservation Make(string id, IReadOnlyList<CraftReagent>? reagents, bool? complete, GameContext game) =>
            Craft(id, game, time) with { Reagents = reagents, InputsComplete = complete };
        foreach (CraftObservation craft in new[]
        {
            Make("absent", [], true, Retail),
            Make("zero", [new(222, 0, null)], true, Retail),
            Make("unknown-item", [new(222, null, null)], false, Retail),
            Make("incomplete", [], false, Retail),
            Make("unobserved", null, null, Retail),
            Make("present", [new(222, 3, null)], true, Retail),
            Make("other-context", [], true, Forever)
        })
            Assert.That(store.Write(craft).IsSuccessful, Is.True, craft.Identity.Observation);

        CraftQuery absent = new(Game: Retail, AbsentInputItemId: 222);
        CraftAnalysis baseline = store.Analyze(new(absent));
        CraftAnalysis allocated = store.Analyze(new(new(Game: Retail, InputItemId: 222)));
        Assert.Multiple(() =>
        {
            Assert.That(store.QueryCrafts(absent).Crafts.Select(row => row.Facts.Identity.Observation),
                Is.EquivalentTo(new[] { "absent", "zero" }));
            Assert.That(baseline.Attempts.Attempts, Is.EqualTo("2"));
            Assert.That(baseline.Characters.Nodes.Single().ResourceAllocation,
                Is.EqualTo(new AnalysisMeasure("2", "2", "0", "0")));
            Assert.That(allocated.Characters.Nodes.Single().ResourceAllocation,
                Is.EqualTo(new AnalysisMeasure("3", "2", "1", "3")));
            Assert.That(baseline.Characters.Nodes.Single().FinishingAllocation, Is.Null);
        });
    }

    [Test]
    public void AbsentSelectionRequiresEveryRecordedEntryToHaveAValidIdentity()
    {
        using Store store = new(Path.Combine(_directory, "history.duckdb"));
        DateTimeOffset time = DateTimeOffset.Parse("2026-04-01T00:00:00Z");
        (string Id, string Buffs, string Finishing)[] observations =
        [
            ("empty", "{}", "{}"),
            ("valid-other", "{[1] = {spellID = 123, applications = 1}}",
                "{[1] = {itemID = 333, quantity = 1}}"),
            ("missing-buff", "{[1] = {applications = 1}}", "{}"),
            ("malformed-buff", "{[1] = {spellID = \"unknown\"}}", "{}"),
            ("missing-finishing", "{}", "{[1] = {quantity = 1}}"),
            ("malformed-finishing", "{}", "{[1] = {itemID = \"unknown\"}}"),
            ("mixed", "{[1] = {spellID = 123}, [2] = {applications = 1}}",
                "{[1] = {itemID = 333}, [2] = {quantity = 1}}")
        ];
        foreach ((string id, string buffs, string finishing) in observations)
        {
            string payload = "CraftConfigurationEvidence = {conditions = {buffs = " + buffs +
                ", finishingReagents = " + finishing +
                "}, craftFields = {buffsCoverage = \"supported-list\", finishingCoverage = \"submitted\"}}";
            Assert.That(store.Write(Craft(id, Retail, time) with
            {
                ConfigurationEvidence = [new("source", 1, payload)]
            }).IsSuccessful, Is.True);
        }

        CraftQuery absent = new(Game: Retail, AbsentBuffSpellId: 432306, AbsentFinishingItemId: 222);
        Assert.Multiple(() =>
        {
            Assert.That(store.QueryCrafts(absent).Crafts.Select(row => row.Facts.Identity.Observation),
                Is.EquivalentTo(new[] { "empty", "valid-other" }));
            Assert.That(store.Analyze(new(absent)).Attempts.Attempts, Is.EqualTo("2"));
            Assert.That(store.QueryCrafts(absent with { AbsentFinishingItemId = null })
                .Crafts.Select(row => row.Facts.Identity.Observation),
                Is.EquivalentTo(new[] { "empty", "valid-other", "missing-finishing", "malformed-finishing" }));
            Assert.That(store.QueryCrafts(absent with { AbsentBuffSpellId = null })
                .Crafts.Select(row => row.Facts.Identity.Observation),
                Is.EquivalentTo(new[] { "empty", "valid-other", "missing-buff", "malformed-buff" }));
        });
    }

    private static CraftObservation Craft(string id, GameContext game, DateTimeOffset recorded) =>
        new(new("origin", id), game, recorded, 10, new("character"));
}
