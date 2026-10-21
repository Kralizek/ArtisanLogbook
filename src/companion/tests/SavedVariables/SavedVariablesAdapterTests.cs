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
            Assert.That(entry.ContainsKey("missing"), Is.False);
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
            "ArtisanLogbookDB = { schemaIdentity = \"ArtisanLogbookLedger\", schemaVersion = 6 }");

        Assert.That(result.History, Is.Null);
        Assert.That(result.Diagnostics.Single().Code, Is.EqualTo("unsupported-schema"));
    }

    [Test]
    public void SchemaFiveSeparatesCanonicalOutputsFromPartialCallbackEvidence()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
                        ArtisanLogbookDB = {
                            schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
                            crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, recipeId = 1231127,
                                gameOperationId = 3533599395, attemptKind = "salvage-operation", outputQuantity = 2,
                                outcomeSource = "unverified", companionOutputEvidenceComplete = false, outputs = {
                                    { itemId = 900001, quantity = 1, timestamp = 1800000000, measurements = {}, returns = {} },
                                    { itemId = 900002, quantity = 1, timestamp = 1800000000, measurements = {}, returns = {} }
                                } } },
                            dimensions = {
                                sessions = { { id = 1, key = "session-1", projectId = 1, characterDimensionId = 1 } },
                                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                                items = { [900001] = { id = 900001 }, [900002] = { id = 900002 } }
                            }
                        }
                        """);

        Assert.That(result.IsSuccessful, Is.True, string.Join(Environment.NewLine, result.Diagnostics));
        CraftObservation craft = result.History!.Crafts.Single();
        Assert.That(craft.Outputs, Is.EquivalentTo(new[] { new CraftOutput(900001, null, 1), new CraftOutput(900002, null, 1) }));
        Assert.That(craft.Provenance!.GameOperationId, Is.EqualTo(3533599395));
        Assert.That(craft.OutputEvidence, Has.Count.EqualTo(1));
        Assert.That(craft.OutputEvidence![0].Callbacks, Has.Count.EqualTo(2));
        Assert.That(craft.OutputEvidence[0].Complete, Is.False);
        Assert.That(craft.OutputsComplete, Is.Null);
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
    public void CanonicalOnlyMultiOutputExportDoesNotClaimSyntheticCallbacksAsEvidence()
    {
        CraftObservation craft = MakeCraft("canonical", "multi", Retail, 123, 90) with
        {
            Outputs = [new(90, 1, 2), new(91, 1, 3)]
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));

        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        LuaTable ledger = (LuaTable)LuaDataParser.Parse(written.Content!).Assignments["ArtisanLogbookDB"]!;
        LuaTable row = ((LuaTable)ledger.Get("crafts")!).Values.OfType<LuaTable>().Single();
        Assert.That(row.Get("companionOutputObservationsPresent"), Is.False);
        CraftObservation restored = SavedVariablesReader.Parse(written.Content!).History!.Crafts.Single();
        Assert.That(restored.OutputEvidence, Is.Null);
        Assert.That(restored.Outputs, Is.EquivalentTo(craft.Outputs));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void CanonicalAmbiguousOutputWithoutSourceCallbacksCannotBeFabricated()
    {
        CraftObservation craft = MakeCraft("canonical", "ambiguous", Retail, 123, 90) with
        {
            Outputs = [new(90, 1, null)],
            OutputsComplete = false
        };

        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));

        Assert.That(written.IsSuccessful, Is.False);
        Assert.That(written.Content, Is.Null);
        Assert.That(written.Diagnostics.Single().Code, Is.EqualTo("unrepresentable-output-quantity"));
    }

    [Test]
    public void MismatchingCallbackEvidenceIsNotExportedAsCanonicalOutputFacts()
    {
        CraftObservation craft = MakeCraft("canonical", "corrected", Retail, 123, 90) with
        {
            Outputs = [new(90, 1, 2)],
            OutputEvidence = [new("capture-original", [new(
                new(90, 1, 1), Now, new(), [])], Complete: true)]
        };

        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));

        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        Assert.That(written.Diagnostics.Any(d => d.Code == "source-output-evidence-not-exported"), Is.True);
        CraftObservation roundTrip = SavedVariablesReader.Parse(written.Content!).History!.Crafts.Single();
        Assert.That(roundTrip.Outputs, Is.EquivalentTo(new[] { new CraftOutput(90, 1, 2) }));
        Assert.That(roundTrip.OutputEvidence, Is.Null);
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
    public void ZeroUnknownAndPositiveAllocationsRoundTripWithoutInvalidAddonMeasures()
    {
        CraftObservation craft = MakeCraft("allocations", "1") with
        {
            Reagents = [new(44, 0, 1), new(45, null, null), new(46, 2, 0)]
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));
        Assert.That(written.IsSuccessful, Is.True);
        Assert.That(SavedVariablesReader.Parse(written.Content!).History!.Crafts.Single(), Is.EqualTo(craft));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void MultiOutputDetailDoesNotHideAggregateOnlyCraftsInTheSameBucket()
    {
        CraftObservation craft = MakeCraft("coverage", "1") with
        {
            Outputs = [new(90, 1, 1), new(91, 1, 1)]
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));
        LuaDocument document = LuaDataParser.Parse(written.Content!);
        LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        LuaTable bucket = ((LuaTable)ledger.Get("craftSeries")!).Values.OfType<LuaTable>().Single();
        bucket["craftCount"] = 3d;

        SavedVariablesImportResult imported = SavedVariablesReader.Parse(LuaDataParser.Serialize(document));

        Assert.That(imported.IsSuccessful, Is.True);
        Assert.That(imported.History!.Crafts, Has.Count.EqualTo(1));
        Assert.That(imported.Coverage.AggregateOnlyCraftCount, Is.EqualTo(2));
    }

    [Test]
    public void ExistingLedgerRequiresExplicitRegenerationAndReconciledTargetCrafts()
    {
        CraftObservation craft = MakeCraft("target", "1") with { ConcentrationSpent = 0 };
        string target = SavedVariablesWriter.Serialize(History(craft), options: new(Now)).Content!;
        SavedVariablesWriteResult implicitWrite = SavedVariablesWriter.Serialize(History(craft), target, new(Now));
        Assert.That(implicitWrite.IsSuccessful, Is.False);
        Assert.That(implicitWrite.Diagnostics.Single().Code, Is.EqualTo("target-regeneration-policy-required"));

        SavedVariablesWriteOptions regenerate = new(Now, GameContext: Retail,
            ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate);
        SavedVariablesWriteResult missing = SavedVariablesWriter.Serialize(History(), target, regenerate);
        SavedVariablesWriteResult conflicting = SavedVariablesWriter.Serialize(
            History(craft with { ConcentrationSpent = 99 }), target, regenerate);
        SavedVariablesWriteResult unenriched = SavedVariablesWriter.Serialize(
            History(craft with { Outputs = null }), target, regenerate);
        Assert.Multiple(() =>
        {
            Assert.That(missing.IsSuccessful, Is.False);
            Assert.That(conflicting.IsSuccessful, Is.False);
            Assert.That(unenriched.IsSuccessful, Is.False);
            Assert.That(missing.Diagnostics.Any(d => d.Code == "target-history-not-reconciled"), Is.True);
        });
        Assert.That(SavedVariablesWriter.Serialize(History(craft), target, regenerate).IsSuccessful, Is.True);
    }

    [Test]
    public void RegenerationPreservesUnrelatedStateButReportsOperationalLossAndCoverage()
    {
        CraftObservation craft = MakeCraft("target", "1");
        LuaDocument document = LuaDataParser.Parse(
            SavedVariablesWriter.Serialize(History(craft), options: new(Now)).Content!);
        LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        ledger["configurations"] = new LuaTable { [7d] = new LuaTable { ["useConcentration"] = true } };
        ledger["customSetting"] = "keep";
        ledger["requests"] = new LuaTable { [1d] = new LuaTable { ["id"] = 1d } };
        ledger["firstCraftRewards"] = new LuaTable { [1d] = new LuaTable { ["marker"] = "reward" } };
        ledger["reagentRequirementSeries"] = new LuaTable { [1d] = new LuaTable { ["marker"] = "requirement" } };
        ((LuaTable)ledger.Get("craftSeries")!).Values.OfType<LuaTable>().Single()["craftCount"] = 3d;
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft),
            LuaDataParser.Serialize(document), new(Now, ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        LuaTable result = (LuaTable)LuaDataParser.Parse(written.Content!).Assignments["ArtisanLogbookDB"]!;
        Assert.Multiple(() =>
        {
            Assert.That(result.Get("customSetting"), Is.EqualTo("keep"));
            Assert.That(((LuaTable)result.Get("configurations")!).Get(7d), Is.Not.Null);
            Assert.That(result.Get("nextConfigurationKey"), Is.EqualTo(8d));
            foreach (string field in new[] { "requests", "firstCraftRewards", "reagentRequirementSeries" })
                Assert.That(((LuaTable)result.Get(field)!).Count, Is.Zero, field);
            Assert.That(written.Diagnostics.Any(d => d.Code == "target-operational-state-regenerated"), Is.True);
            Assert.That(written.Diagnostics.Any(d => d.Code == "source-history-incomplete"), Is.True);
        });
        AssertLoaderAccepts(written);
    }

    [Test]
    public void SyntheticSessionDoesNotClaimHistoricalBuildAndRetainsOriginalCraftProvenance()
    {
        CraftObservation first = MakeCraft("session-source", "1") with
        {
            Provenance = new("session-source", 1, 10, 11, "session-old", "native"),
            RecordedAt = Now.AddDays(-1)
        };
        CraftObservation second = MakeCraft("session-source", "2") with
        {
            Provenance = new("session-source", 2, 10, 12, "session-new", "partial")
        };
        LuaDocument document = LuaDataParser.Parse(
            SavedVariablesWriter.Serialize(History(first, second), options: new(Now)).Content!);
        LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        LuaTable session = ((LuaTable)((LuaTable)ledger.Get("dimensions")!).Get("sessions")!)
            .Values.OfType<LuaTable>().Single();
        session["wowBuild"] = "historical-build";
        session["addonVersion"] = "historical-version";
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(first, second),
            LuaDataParser.Serialize(document), new(Now, ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate));
        Assert.That(written.IsSuccessful, Is.True);
        LuaTable resultLedger = (LuaTable)LuaDataParser.Parse(written.Content!).Assignments["ArtisanLogbookDB"]!;
        LuaTable resultSession = ((LuaTable)((LuaTable)resultLedger.Get("dimensions")!).Get("sessions")!)
            .Values.OfType<LuaTable>().Single();
        Assert.Multiple(() =>
        {
            Assert.That(resultSession.Get("wowBuild"), Is.Null);
            Assert.That(resultSession.Get("addonVersion"), Is.Null);
            Assert.That(resultSession.Get("companionSynthetic"), Is.True);
            Assert.That(resultSession.Get("startedAt"), Is.EqualTo((double)Now.ToUnixTimeSeconds()));
            Assert.That(SavedVariablesReader.Parse(written.Content!).History!.Crafts,
                Is.EquivalentTo(new[] { first, second }));
        });
        AssertLoaderAccepts(written);
    }

    [TestCase(true)]
    [TestCase(false)]
    public void CompleteResourcefulnessDoesNotInventNativeAuthority(bool proc)
    {
        CraftObservation craft = MakeCraft("legacy", "1") with
        {
            HasResourcefulnessProc = proc,
            ResourcefulnessComplete = true,
            Reagents = proc ? [new(44, 2, 1)] : [],
            Provenance = new("legacy", 1, ResourcefulnessEvidence: null)
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        Assert.That(written.Content, Does.Not.Contain("[\"outcomeSource\"]=\"native\""));
        Assert.That(SavedVariablesReader.Parse(written.Content!).History!.Crafts.Single(), Is.EqualTo(craft));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void EmptyReagentsAndIndependentCraftClassificationAndTimestampRoundTrip()
    {
        CraftObservation craft = MakeCraft("roundtrip", "1") with
        {
            RecordedAt = Now.AddTicks(1234567),
            Reagents = [],
            ProfessionId = null,
            ProfessionExpansionKey = "custom:expansion",
            Provenance = new("roundtrip", 1, long.MaxValue)
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft), options: new(Now));
        Assert.That(written.IsSuccessful, Is.True);
        Assert.That(SavedVariablesReader.Parse(written.Content!).History!.Crafts.Single(), Is.EqualTo(craft));
        AssertLoaderAccepts(written);
    }

    [TestCase("ArtisanLogbookDB = -")]
    [TestCase("ArtisanLogbookDB = 1e+")]
    [TestCase("--")]
    [TestCase("ArtisanLogbookDB = { --")]
    public void TruncatedLuaProducesDiagnosticsRatherThanThrowing(string source)
    {
        SavedVariablesImportResult? result = null;
        Assert.DoesNotThrow(() => result = SavedVariablesReader.Parse(source));
        Assert.That(result!.IsSuccessful, Is.False);
    }

    [Test]
    public void LuaStringEscapesAndNilFollowLua51Semantics()
    {
        LuaDocument document = LuaDataParser.Parse(
            "ArtisanLogbookDB = { name = \"\\195\\169\", line = \"first\\\nsecond\", removed = 1, removed = nil }");
        LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        Assert.That(ledger.Get("name"), Is.EqualTo("\u00e9"));
        Assert.That(ledger.Get("line"), Is.EqualTo("first\nsecond"));
        Assert.That(ledger.ContainsKey("removed"), Is.False);
        Assert.That(LuaDataParser.Serialize(document), Does.Contain("\u00e9"));
    }

    [TestCase("ArtisanLogbookDB = { end = 1 }")]
    [TestCase("end = {}")]
    [TestCase("ArtisanLogbookDB = { x = +1 }")]
    [TestCase("ArtisanLogbookDB = { x = \"\\255\" }")]
    [TestCase("ArtisanLogbookDB = { x = \"\\z text\" }")]
    public void UnsupportedLuaSyntaxAndNonUtf8ByteStringsFailExplicitly(string source)
    {
        Assert.Throws<LuaSyntaxException>(() => LuaDataParser.Parse(source));
    }

    [Test]
    public void EveryTruncatedPrefixProducesDiagnosticsWithoutThrowing()
    {
        string seed = """
            ArtisanLogbookDB = {
              schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
              crafts = {}, list = { true, false, 1.25e+4, "\195\169" } -- comment
            }
            """;
        for (int length = 0; length < seed.Length; length++)
            Assert.DoesNotThrow(() => SavedVariablesReader.Parse(seed[..length]), $"Prefix length {length}");
    }

    [Test]
    public void ConflictingGroupedCraftFactsAreRejectedRatherThanTakingTheFirstRow()
    {
        CraftObservation craft = MakeCraft("group", "1") with
        {
            Outputs = [new(90, 1, 1), new(91, 1, 1)]
        };
        LuaDocument document = LuaDataParser.Parse(
            SavedVariablesWriter.Serialize(History(craft), options: new(Now)).Content!);
        LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        LuaTable rows = (LuaTable)ledger.Get("crafts")!;
        LuaTable duplicate = new();
        foreach ((object key, object? value) in rows.Values.OfType<LuaTable>().Single()) duplicate[key] = value;
        duplicate["id"] = 2d;
        duplicate["concentrationSpent"] = 50d;
        rows[2d] = duplicate;

        SavedVariablesImportResult result = SavedVariablesReader.Parse(LuaDataParser.Serialize(document));
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Diagnostics.Any(d => d.Code == "conflicting-output-group"), Is.True);
    }

    [Test]
    public void CoverageSumsOperationalGrainsBeforeSubtractingLogicalDetail()
    {
        CraftObservation craft = MakeCraft("coverage", "1");
        LuaDocument document = LuaDataParser.Parse(
            SavedVariablesWriter.Serialize(History(craft), options: new(Now)).Content!);
        LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
        LuaTable series = (LuaTable)ledger.Get("craftSeries")!;
        LuaTable first = series.Values.OfType<LuaTable>().Single();
        LuaTable second = new();
        foreach ((object key, object? value) in first) second[key] = value;
        first["configurationScope"] = "result";
        second["configurationScope"] = "submission";
        series[2d] = second;

        SavedVariablesImportResult result = SavedVariablesReader.Parse(LuaDataParser.Serialize(document));
        Assert.That(result.IsSuccessful, Is.True);
        Assert.That(result.Coverage.AggregateOnlyCraftCount, Is.EqualTo(1));
    }

    [Test]
    public void OversizedCanonicalQuantitiesFailWithAnActionableDiagnostic()
    {
        CraftObservation craft = MakeCraft("large", "1") with { Outputs = [new(90, 1, long.MaxValue)] };
        SavedVariablesWriteResult? result = null;
        Assert.DoesNotThrow(() => result = SavedVariablesWriter.Serialize(History(craft), options: new(Now)));
        Assert.That(result!.IsSuccessful, Is.False);
        Assert.That(result.Diagnostics.Single().Code, Is.EqualTo("lua-integer-precision"));

        CraftObservation bounded = craft with { Outputs = [new(90, 1, 9_007_199_254_740_991)] };
        result = SavedVariablesWriter.Serialize(History(bounded,
            bounded with { Identity = new("large", "2") }), options: new(Now));
        Assert.That(result.IsSuccessful, Is.False, "Rollup sums must also stay within Lua integer precision.");
    }

    [Test]
    public void MalformedCollectionMembersAndOverflowDoNotSilentlyLoseFactsOrThrow()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse("""
            return { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger", crafts = { 123 } }
            """);
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Diagnostics.Any(d => d.Code == "invalid-collection-row"), Is.True);
    }

    [TestCase(1)]
    [TestCase(2)]
    [TestCase(3)]
    public void SupportedLegacySchemaSnapshotsExportThroughTheActualLoader(int schema)
    {
        string source = ReadFixture(schema == 3 ? "ledger-schema3.lua" : "v1-outcome2.lua");
        SavedVariablesImportResult original = SavedVariablesReader.Parse(source);
        if (schema == 3)
        {
            Assert.That(original.IsSuccessful, Is.False);
            Assert.That(original.Diagnostics.Any(d => d.Code == "unknown-game-context"), Is.True,
                "The raw schema-3 fixture deliberately has unresolved source identity.");
            LuaTable ledger = (LuaTable)LuaDataParser.Parse(source).ReturnedValue!;
            LuaTable dimensions = (LuaTable)ledger.Get("dimensions")!;
            ((LuaTable)dimensions.Get("sessions")!).Values.OfType<LuaTable>().Single()["projectId"] = 1d;
            ((LuaTable)dimensions.Get("characters")!).Values.OfType<LuaTable>().Single()["key"] = Crafter.Key;
            original = SavedVariablesReader.Parse(LuaDataParser.Serialize(new(
                new Dictionary<string, object?> { ["ArtisanLogbookDB"] = ledger }, null)));
        }
        Assert.That(original.IsSuccessful, Is.True, string.Join(Environment.NewLine, original.Diagnostics));
        if (schema == 2)
        {
            SavedVariablesWriteResult seed = SavedVariablesWriter.Serialize(original.History!,
                options: new(Now, RetentionDays: 10000));
            LuaDocument document = LuaDataParser.Parse(seed.Content!);
            LuaTable ledger = (LuaTable)document.Assignments["ArtisanLogbookDB"]!;
            ledger["schemaVersion"] = 2d;
            ledger.Remove("configurations");
            ledger.Remove("nextConfigurationKey");
            ledger.Remove("reagentRequirementSeries");
            foreach (LuaTable row in ((LuaTable)ledger.Get("craftSeries")!).Values.OfType<LuaTable>())
                row.Remove("grossRequirementsCompleteCount");
            original = SavedVariablesReader.Parse(LuaDataParser.Serialize(document));
        }
        Assert.That(original.IsSuccessful, Is.True);
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(original.History!,
            options: new(Now, RetentionDays: 10000, SourceCoverage: original.Coverage));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        Assert.That(SavedVariablesReader.Parse(written.Content!).History!.Crafts,
            Is.EquivalentTo(original.History!.Crafts));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void LegacySeparateAllocationSlotsAndItemLevelReturnRowsKeepIndependentMeasures()
    {
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(ReadFixture("v1-outcome2.lua"));
        Assert.That(imported.IsSuccessful, Is.True, string.Join(Environment.NewLine, imported.Diagnostics));
        CraftObservation craft = imported.History!.Crafts.Single(c => c.Provenance!.LocalCraftId == 7);
        CraftReagent reagent = craft.Reagents!.Single(r => r.ItemId == 236761);
        Assert.That(reagent.AllocatedQuantity, Is.EqualTo(12));
        Assert.That(reagent.ReturnedQuantity, Is.EqualTo(2));
        Assert.That(craft.ResourcefulnessComplete, Is.True);
    }

    [Test]
    public void OldSchemaOneOutcomeCoverageIsCorrectedLikeTheAddonMigration()
    {
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(ReadFixture("v1-outcome1.lua"));
        Assert.That(imported.IsSuccessful, Is.True);
        Assert.That(imported.History!.Crafts.All(c => c.ResourcefulnessComplete is null), Is.True);
        Assert.That(imported.History.Crafts.All(c => c.HasResourcefulnessProc != false), Is.True);
        Assert.That(imported.Diagnostics.Any(d => d.Code == "legacy-outcome-coverage-corrected"), Is.True);
        Assert.That(imported.History.Crafts.Any(c => c.Reagents?.Any(r => r.ReturnedQuantity > 0) == true), Is.True);
    }

    [Test]
    public void UnrepresentableFractionalPrecisionCannotSilentlyChangeCanonicalObservations()
    {
        CraftObservation craft = MakeCraft("precision", "1") with
        {
            Reagents = [new(44, null, 0.1234567890123456789012345678m)]
        };
        SavedVariablesWriteResult result = SavedVariablesWriter.Serialize(History(craft), options: new(Now));
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Diagnostics.Single().Code, Is.EqualTo("unrepresentable-craft-observations"));
    }

    [Test]
    public void TargetFromAnotherGameContextIsRejectedBeforeRegeneration()
    {
        CraftObservation craft = MakeCraft("retail", "1");
        string target = SavedVariablesWriter.Serialize(History(craft), options: new(Now)).Content!;
        CraftObservation other = MakeCraft("forever", "1", new(GameProject.Forever));
        SavedVariablesWriteResult result = SavedVariablesWriter.Serialize(History(craft, other), target,
            new(Now, GameContext: other.Game, ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate));
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Diagnostics.Single().Code, Is.EqualTo("target-game-context-mismatch"));
    }

    [TestCase("hasResourcefulnessProc", "\"false\"")]
    [TestCase("concentrationSpent", "\"0\"")]
    [TestCase("recipeId", "1.5")]
    public void InvalidKnownCraftFieldsAreNotSilentlyImportedAsUnknown(string field, string value)
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse(
            $$"""
            return { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
              crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, {{field}} = {{value}} } },
              dimensions = {
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                sessions = { { id = 1, key = "session", projectId = 1, characterDimensionId = 1 } }
              }
            }
            """);
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(result.Diagnostics.Any(d => d.Code == "invalid-craft-measurement"), Is.True);
    }

    [Test]
    public void MissingOrCrossSessionRequestReferencesCannotSupplyCraftInputs()
    {
        string source = """
            return { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
              crafts = { { id = 1, sessionId = 1, requestId = 7, recipeId = 123, timestamp = 1800000000 } },
              requests = { { id = 7, sessionId = 2, recipeId = 123,
                allocations = { { itemId = 44, allocatedQuantity = 99 } } } },
              reagents = { { craftId = 999, itemId = 45, returnedQuantity = 1 } },
              dimensions = {
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                sessions = { { id = 1, key = "session", projectId = 1, characterDimensionId = 1 } }
              }
            }
            """;
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(source);
        Assert.That(imported.IsSuccessful, Is.False);
        Assert.That(imported.Diagnostics.Any(d => d.Code == "invalid-craft-request-reference"), Is.True);
        Assert.That(imported.Diagnostics.Any(d => d.Code == "orphan-reagent-reference"), Is.True);
    }

    [Test]
    public void RequestOnlyFallbackIncludesFixedReagentsWithoutInventingReturns()
    {
        SavedVariablesImportResult imported = SavedVariablesReader.Parse("""
            return { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
              crafts = { { id = 1, sessionId = 1, requestId = 7, recipeId = 123, timestamp = 1800000000 } },
              requests = { { id = 7, sessionId = 1, recipeId = 123, allocations = {},
                fixedReagents = { { itemId = 44, requiredQuantity = 3 } } } },
              dimensions = {
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                sessions = { { id = 1, key = "session", projectId = 1, characterDimensionId = 1 } }
              }
            }
            """);
        Assert.That(imported.IsSuccessful, Is.True);
        Assert.That(imported.History!.Crafts.Single().Reagents, Is.EqualTo(new[] { new CraftReagent(44, 3, null) }));
    }

    [Test]
    public void ActualDistinctSourceSessionsKeepCraftLineageWithoutInventingHistoricalBuilds()
    {
        string source = """
            ArtisanLogbookDB = { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
              crafts = {
                { id = 1, sessionId = 1, gameOperationId = 10, timestamp = 1800000000 },
                { id = 2, sessionId = 2, gameOperationId = 10, timestamp = 1800000000 }
              },
              dimensions = {
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                sessions = {
                  { id = 1, key = "original-one", projectId = 1, characterDimensionId = 1,
                    wowBuild = "100", addonVersion = "old", startedAt = 1799999000 },
                  { id = 2, key = "original-two", projectId = 1, characterDimensionId = 1,
                    wowBuild = "200", addonVersion = "new", startedAt = 1800000000 }
                }
              }
            }
            """;
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(source);
        Assert.That(imported.IsSuccessful, Is.True);
        Assert.That(imported.History!.Crafts.Select(c => c.Provenance!.SourceSessionId),
            Is.EquivalentTo(new[] { "original-one", "original-two" }));
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(imported.History, source,
            new(Now, ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate));
        Assert.That(written.IsSuccessful, Is.True);
        Assert.That(written.Content, Does.Not.Contain("wowBuild"));
        Assert.That(SavedVariablesReader.Parse(written.Content!).History!.Crafts, Is.EquivalentTo(imported.History.Crafts));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void RecipeDimensionMetadataAndProfessionParentsAreNotReplacedByCraftClassification()
    {
        CraftObservation craft = MakeCraft("dimensions", "1") with { ProfessionId = null };
        RecipeDimension recipe = new(Retail, 123, "Recipe", 2915, "skillLine:2915", 3);
        CraftHistory history = History(craft) with
        {
            Dimensions = History(craft).Dimensions with
            {
                Recipes = [recipe],
                Professions = [new(Retail, 2915, "Child", 171), new(Retail, 171, "Alchemy")],
                Expansions = [new(Retail, "skillLine:2915", "Expansion")]
            }
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(history, options: new(Now));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(written.Content!);
        Assert.That(imported.History!.Crafts.Single(), Is.EqualTo(craft));
        Assert.That(imported.History.Dimensions.Recipes, Is.EqualTo(new[] { recipe }));
        Assert.That(imported.History.Dimensions.Professions, Is.EquivalentTo(history.Dimensions.Professions));
        Assert.That(imported.History.Dimensions.Expansions, Is.EqualTo(history.Dimensions.Expansions));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void RegeneratingARealSchemaOneTargetRemovesObsoleteSchemaFields()
    {
        LuaTable sourceLedger = (LuaTable)LuaDataParser.Parse(ReadFixture("v1-outcome2.lua")).ReturnedValue!;
        string target = LuaDataParser.Serialize(new(
            new Dictionary<string, object?> { ["ArtisanLogbookDB"] = sourceLedger }, null));
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(target);
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(imported.History!, target,
            new(Now, RetentionDays: 10000, ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        AssertLoaderAccepts(written);
    }

    [Test]
    public void UnknownMultiOutputRestorationRepairsOneLogicalContribution()
    {
        CraftObservation unknown = MakeCraft("recovery", "unknown") with
        {
            RecipeId = null,
            Outputs = [new(90, 1, 1), new(91, 1, 1)]
        };
        CraftObservation known = MakeCraft("recovery", "known") with
        {
            Outputs = [new(90, 1, 1), new(91, 1, 1)]
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(unknown, known), options: new(Now));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        AssertLoaderAccepts(written,
            "local repaired, reason=ledger:RepairUnknownRecipes(); assert(repaired, reason); assert(repaired.repairedCount==1)",
            [unknown with { RecipeId = 123 }, known]);
    }

    [TestCase(true, false)]
    [TestCase(false, true)]
    [TestCase(false, false)]
    public void UnknownSingleOutputRecoveryUsesRepresentableContributions(bool inputsComplete, bool native)
    {
        CraftObservation unknown = MakeCraft("recovery", "unknown") with
        {
            RecipeId = null,
            InputsComplete = inputsComplete ? true : null,
            Reagents = [new(44, 2, 1)],
            HasResourcefulnessProc = true,
            ResourcefulnessComplete = native ? true : null,
            Provenance = new("recovery", 1, ResourcefulnessEvidence: native ? "native" : null)
        };
        CraftObservation known = MakeCraft("recovery", "known");
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(unknown, known), options: new(Now));
        if (inputsComplete)
        {
            Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
            AssertLoaderAccepts(written,
                "local repaired, reason=ledger:RepairUnknownRecipes(); assert(repaired, reason); assert(repaired.repairedCount==1)",
                [unknown with { RecipeId = 123 }, known]);
            return;
        }
        Assert.That(written.IsSuccessful, Is.True);
        AssertLoaderAccepts(written,
            "local repaired, reason=ledger:RepairUnknownRecipes(); assert(repaired, reason); assert(repaired.repairedCount==1)",
            [unknown with { RecipeId = 123 }, known]);
    }

    [Test]
    public void RandomizedSemanticRoundTripsAndReplayRemainDeterministic()
    {
        Random random = new(39);
        for (int iteration = 0; iteration < 100; iteration++)
        {
            bool? proc = random.Next(3) switch { 0 => null, 1 => false, _ => true };
            bool? complete = proc is null ? null : random.Next(3) switch { 0 => null, 1 => false, _ => true };
            long? allocation = random.Next(3) switch { 0 => null, 1 => 0, _ => 5 };
            CraftObservation craft = MakeCraft("random", iteration.ToString()) with
            {
                RecordedAt = Now.AddTicks(-random.Next(10000000)),
                RecipeId = random.Next(2) == 0 ? null : 123,
                ProfessionId = random.Next(2) == 0 ? null : 171,
                ProfessionExpansionKey = random.Next(2) == 0 ? null : "skillLine:2915",
                HasResourcefulnessProc = proc,
                ResourcefulnessComplete = complete,
                Reagents = proc == true ? [new(44, allocation, 1)] :
                    random.Next(3) switch { 0 => null, 1 => [], _ => [new(44, allocation, 0)] },
                Outputs = random.Next(3) switch { 0 => null, 1 => [], _ => [new(90, 1, 2), new(91, null, 3)] },
                Provenance = random.Next(2) == 0 ? null : new("random", iteration + 1, iteration + 1,
                    SourceSessionId: $"session-{iteration % 2}")
            };
            if (craft.RecipeId is null && craft.Outputs is { Count: > 1 })
                craft = craft with { Outputs = [craft.Outputs[0]] };
            CraftHistory history = History(craft);
            SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(history, options: new(Now));
            Assert.That(written.IsSuccessful, Is.True, $"Iteration {iteration}: {string.Join(Environment.NewLine, written.Diagnostics)}");
            SavedVariablesImportResult imported = SavedVariablesReader.Parse(written.Content!);
            Assert.That(imported.IsSuccessful, Is.True, string.Join(Environment.NewLine, imported.Diagnostics));
            Assert.That(imported.History!.Crafts.Single(), Is.EqualTo(craft), $"Iteration {iteration}");
            Assert.That(CraftHistoryReconciler.Merge(history, imported.History).IsSuccessful, Is.True);
            Assert.That(SavedVariablesWriter.Serialize(history, options: new(Now)).Content, Is.EqualTo(written.Content));
            AssertLoaderAccepts(written);
        }
    }

    [Test]
    public void GeneratedSavedVariablesAreAcceptedByTheRealAddonLedgerLoaderOnLinux()
    {
        CraftObservation craft = MakeCraft("loader", "1", Retail) with
        {
            Reagents = [new(44, 3, 1)],
            ResourcefulnessComplete = true,
            HasResourcefulnessProc = true
        };
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(craft),
            options: new(Now, GameContext: Retail));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        AssertLoaderAccepts(written);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ProspectingSixAttemptFixtureRoundTripsThroughCompanionAndActualAddon(bool repeatedDelivery)
    {
        if (OperatingSystem.IsWindows()) return;
        string source = CaptureProspecting(repeatedDelivery);
        SavedVariablesImportResult imported = SavedVariablesReader.Parse(source);
        Assert.That(imported.IsSuccessful, Is.True, string.Join(Environment.NewLine, imported.Diagnostics));
        Assert.That(imported.History!.Crafts, Has.Count.EqualTo(6));
        Assert.That(imported.History.Crafts.Sum(craft => craft.OutputEvidence!.Sum(evidence => evidence.Callbacks.Count)), Is.EqualTo(repeatedDelivery ? 9 : 8));
        Assert.That(imported.History.Crafts.Sum(craft => craft.Reagents!.Sum(reagent => reagent.AllocatedQuantity)), Is.EqualTo(30));
        Assert.That(imported.History.Crafts.All(craft => craft.ConfigurationEvidence?.Single().LocalKey == 197), Is.True);
        Assert.That(imported.History.Crafts.All(craft => craft.OutputEvidence?.Single().Complete == true), Is.True);
        Assert.That(imported.History.Crafts.SelectMany(craft => craft.Outputs ?? [])
            .Any(output => output.Quantity is null), Is.EqualTo(repeatedDelivery));
        if (repeatedDelivery)
            Assert.That(imported.History.Crafts.Single(craft => craft.Outputs?.Any(output => output.Quantity is null) == true)
                .OutputsComplete, Is.False);
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(imported.History, options: new(Now));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        Assert.That(written.DetailedCraftCount, Is.EqualTo(6));
        SavedVariablesImportResult roundTrip = SavedVariablesReader.Parse(written.Content!);
        Assert.That(roundTrip.History!.Crafts, Is.EquivalentTo(imported.History.Crafts));
        foreach (CraftObservation craft in imported.History.Crafts)
        {
            Assert.That(roundTrip.History.Crafts.Single(result => result.Identity == craft.Identity).OutputEvidence,
                Is.EquivalentTo(craft.OutputEvidence!));
            Assert.That(roundTrip.History.Crafts.Single(result => result.Identity == craft.Identity).ConfigurationEvidence,
                Is.EquivalentTo(craft.ConfigurationEvidence!));
        }
        string coverage = repeatedDelivery ? "5" : "6";
        AssertLoaderAccepts(written, "assert(#ledger.database.crafts==6); " +
            "local row=ledger.database.craftSeries[1]; assert(row.craftCount==6); " +
            $"assert(row.outputQuantityObservedCount=={coverage}); assert(ledger.database.reagentSeries[1].allocatedQuantity==30); " +
            "assert(ledger.database.crafts[1].configurationKey==197 and ledger.database.configurations[197])",
            imported.History.Crafts);
    }

    private static string CaptureProspecting(bool repeatedDelivery)
    {
        string root = FindRepositoryRoot();
        string ledger = Path.Combine(root, "src/addon/src/ArtisanLogbook_Core/Storage/Ledger.lua");
        string fixture = Path.Combine(root, "src/addon/tests/fixtures/retail-prospecting-70448.lua");
        string script = $"local addon={{}}; assert(loadfile({LuaQuote(ledger)}))('Core',addon); " +
            $"local ledger=assert(addon.Ledger.New(nil,{{wall=function() return {Now.ToUnixTimeSeconds()} end}})); " +
            "assert(ledger:CreateSession({projectId=1,regionId=3,gameRealmId=1309,characterGUID='Player-Sanitized',realmName='Test'})); " +
            $"local fixture=dofile({LuaQuote(fixture)}); ledger.database.nextConfigurationKey=197; " +
            "for _,submission in ipairs(fixture.submissions) do assert(ledger:SubmitSalvage(fixture.recipeId,submission.count,fixture.capture)); " +
            "for _,result in ipairs(submission.results) do assert(ledger:RecordResult(result)) end end; " +
            (repeatedDelivery ? "assert(ledger:RecordResult(fixture.submissions[2].results[1])); " : "") +
            "local function dump(value) if type(value)=='table' then local rows={} for key,child in pairs(value) do " +
            "rows[#rows+1]='['..dump(key)..']='..dump(child) end return '{'..table.concat(rows,',')..'}' " +
            "elseif type(value)=='string' then return string.format('%q',value) " +
            "elseif type(value)=='number' then return string.format('%.17g',value) else return tostring(value) end end; " +
            "print('ArtisanLogbookDB = '..dump(ledger.database))";
        ProcessStartInfo start = new("lua5.1") { RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("-e"); start.ArgumentList.Add(script);
        using Process process = Process.Start(start)!;
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.That(process.ExitCode, Is.Zero, error);
        return output;
    }

    private static void AssertLoaderAccepts(SavedVariablesWriteResult written, string? exercise = null,
        IReadOnlyList<CraftObservation>? expected = null)
    {
        if (OperatingSystem.IsWindows())
            return;
        Assert.That(CanRunLua(), Is.True, "Lua 5.1 is required for loader validation on Linux.");
        string root = FindRepositoryRoot();
        string ledgerPath = Path.Combine(root, "src", "addon", "src", "ArtisanLogbook_Core", "Storage", "Ledger.lua");
        string temp = Path.Combine(Path.GetTempPath(), $"artisan-logbook-{Guid.NewGuid():N}.lua");
        File.WriteAllText(temp, written.Content!);
        try
        {
            string script =
                $"dofile({LuaQuote(temp)}); local addon={{}}; assert(loadfile({LuaQuote(ledgerPath)}))('ArtisanLogbook_Core', addon); " +
                $"local ledger, reason=addon.Ledger.New(ArtisanLogbookDB, {{wall=function() return {Now.ToUnixTimeSeconds()} end}}); " +
                "assert(ledger, reason); assert(ledger.database.schemaVersion == 5); " +
                "assert(_VERSION == 'Lua 5.1'); " +
                (exercise is null ? "" : exercise + "; ") +
                "local function dump(v) if type(v)=='table' then local rows={} " +
                "for k,x in pairs(v) do rows[#rows+1]='['..dump(k)..']='..dump(x) end " +
                "return '{'..table.concat(rows, ',')..'}' " +
                "elseif type(v)=='string' then return string.format('%q',v) " +
                "elseif type(v)=='number' then return string.format('%.17g',v) " +
                "else return tostring(v) end end; print('ArtisanLogbookDB = '..dump(ledger.database))";
            ProcessStartInfo start = new("lua5.1") { RedirectStandardError = true, RedirectStandardOutput = true };
            start.ArgumentList.Add("-e");
            start.ArgumentList.Add(script);
            using Process process = Process.Start(start) ?? throw new InvalidOperationException("Lua process could not start.");
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Assert.That(process.ExitCode, Is.Zero, $"{output}{Environment.NewLine}{error}");
            SavedVariablesImportResult loaded = SavedVariablesReader.Parse(output);
            Assert.That(loaded.IsSuccessful, Is.True, string.Join(Environment.NewLine, loaded.Diagnostics));
            Assert.That(loaded.History!.Crafts,
                Is.EquivalentTo(expected ?? SavedVariablesReader.Parse(written.Content!).History!.Crafts));
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
            using Process process = Process.Start(new ProcessStartInfo("lua5.1")
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
