using System.Diagnostics;
using System.Globalization;
using System.Text;

using ArtisanLogbook.History;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

namespace Tests.SavedVariables;

[TestFixture]
public class CompanionRestorationTests
{
    private static readonly GameContext Retail = new(GameProject.Retail);
    private static readonly CharacterIdentity Crafter =
        new("project:1:region:3:realm:1309:guid:Player-Sanitized-Companion-Restore");
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    [Test]
    public void ReaderRejectsCompanionInputMarkerOutsideSchemaFiveOrWithNativeEvidence()
    {
        string legacy = """
                        return { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
                            crafts = { { id = 1, sessionId = 1, timestamp = 1800000000, companionInputsComplete = true,
                                outputItemId = 90, outputQuantity = 1 } },
                            dimensions = {
                                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                                sessions = { { id = 1, key = "session", projectId = 1, characterDimensionId = 1 } }
                            }
                        }
                        """;
        SavedVariablesImportResult legacyResult = SavedVariablesReader.Parse(legacy);
        Assert.That(legacyResult.IsSuccessful, Is.False);
        Assert.That(legacyResult.Diagnostics.Any(d => d.Code == "invalid-companion-input-completeness"), Is.True);

        string nativeConflict = """
                        return { schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
                            crafts = { { id = 1, sessionId = 1, requestId = 7, inputComplete = true,
                                companionInputsComplete = true, recipeId = 123, timestamp = 1800000000,
                                outputItemId = 90, outputQuantity = 1 } },
                            requests = { { id = 7, sessionId = 1, recipeId = 123,
                                allocations = { { itemId = 44, allocatedQuantity = 3 } }, fixedReagents = {} } },
                            reagents = { { craftId = 1, itemId = 44, allocatedQuantity = 3 } },
                            dimensions = {
                                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                                sessions = { { id = 1, key = "session", projectId = 1, characterDimensionId = 1 } }
                            }
                        }
                        """;
        SavedVariablesImportResult nativeResult = SavedVariablesReader.Parse(nativeConflict);
        Assert.That(nativeResult.IsSuccessful, Is.False);
        Assert.That(nativeResult.Diagnostics.Any(d => d.Code == "invalid-companion-input-completeness"), Is.True);

        SavedVariablesImportResult invalidType = SavedVariablesReader.Parse(nativeConflict.Replace(
                "companionInputsComplete = true", "companionInputsComplete = \"true\"", StringComparison.Ordinal)
                .Replace(", requestId = 7, inputComplete = true", ", requestId = 7", StringComparison.Ordinal));
        Assert.That(invalidType.IsSuccessful, Is.False);
        Assert.That(invalidType.Diagnostics.Any(d => d.Code == "invalid-craft-measurement"), Is.True);
    }

    [Test]
    public void CompleteCompanionInputsOnMultiOutputUnknownCraftRepairOnceAndRoundTrip()
    {
        CraftObservation unknown = Craft("restored", "unknown", null,
            [new(90, 1, 1), new(91, 1, 1)]) with
        {
            InputsComplete = true,
            Reagents = [new(44, 5, 1m)],
            ConcentrationSpent = 4,
            MulticraftBonus = 1,
            HasResourcefulnessProc = true,
            ResourcefulnessComplete = true,
            Provenance = new("restored-source", 1, 10, SourceSessionId: "original-session", ResourcefulnessEvidence: "native"),
            ConfigurationEvidence = [new("restored-source", 197, ConfigurationEvidencePayload())]
        };
        CraftObservation known = Craft("restored", "known", 123,
            [new(90, 1, 1), new(91, 1, 1)]);
        CraftHistory source = History(unknown, known);
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(source, options: new(Now));

        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        string exercise = """
            local unknown
            for _, craft in ipairs(ledger.database.crafts) do
              if craft.companionCraftObservation == 'unknown' then unknown = craft end
            end
            assert(unknown and unknown.companionInputsComplete == true)
            assert(unknown.inputComplete == nil and unknown.requestId == nil)
            assert(unknown.configurationKey == 197 and ledger.database.configurations[197])
            local function totals()
              local result = { craftCount = 0, inputCompleteCount = 0, matchedCraftCount = 0,
                outputQuantity = 0, multicraftBonus = 0, concentrationSpent = 0,
                resourcefulnessProcCount = 0, resourcefulnessCompleteProcCount = 0,
                resourcefulnessAuthoritativeProcCount = 0 }
              for _, row in ipairs(ledger.database.craftSeries) do
                for field in pairs(result) do result[field] = result[field] + (row[field] or 0) end
              end
              local allocated, returned = 0, 0
              for _, row in ipairs(ledger.database.reagentSeries) do
                allocated = allocated + (row.allocatedQuantity or 0)
                returned = returned + (row.returnedQuantity or 0)
              end
              result.allocatedQuantity, result.returnedQuantity = allocated, returned
              local setCount, authoritativeSetCount = 0, 0
              for _, row in ipairs(ledger.database.resourcefulnessSets) do
                setCount = setCount + row.craftCount
                authoritativeSetCount = authoritativeSetCount + (row.authoritativeCraftCount or 0)
              end
              result.resourcefulnessSetCount = setCount
              result.authoritativeSetCount = authoritativeSetCount
              return result
            end
            local before = totals()
            assert(before.craftCount == 2 and before.inputCompleteCount == 1 and before.matchedCraftCount == 0)
            assert(before.outputQuantity == 4 and before.multicraftBonus == 1 and before.concentrationSpent == 4)
            assert(before.resourcefulnessProcCount == 1 and before.resourcefulnessCompleteProcCount == 1)
            assert(before.resourcefulnessAuthoritativeProcCount == 1)
            assert(before.allocatedQuantity == 5 and before.returnedQuantity == 1)
            assert(before.resourcefulnessSetCount == 1 and before.authoritativeSetCount == 1)
            local repaired, reason = ledger:RepairUnknownRecipes()
            assert(repaired, reason)
            assert(repaired.repairedCount == 1)
            unknown = nil
            for _, craft in ipairs(ledger.database.crafts) do
              if craft.companionCraftObservation == 'unknown' then unknown = craft end
            end
            assert(unknown and unknown.recipeId == 123 and #unknown.outputs == 2)
            assert(unknown.companionInputsComplete == true and unknown.inputComplete == nil)
            assert(unknown.requestId == nil and unknown.configurationKey == 197)
            local after = totals()
            for field, value in pairs(before) do assert(after[field] == value, field .. ' changed during repair') end
            assert(ledger:RepairUnknownRecipes().repairedCount == 0)
            ledger = assert(addon.Ledger.New(ledger.database, { wall = function() return 1800000000 end }))
            assert(ledger:RepairUnknownRecipes().repairedCount == 0)
            local reloaded
            for _, craft in ipairs(ledger.database.crafts) do
              if craft.companionCraftObservation == 'unknown' then reloaded = craft end
            end
            assert(reloaded and reloaded.recipeId == 123 and reloaded.companionInputsComplete == true)
            assert(reloaded.inputComplete == nil and reloaded.requestId == nil)
            assert(reloaded.configurationKey == 197 and #reloaded.outputs == 2)
            local final = totals()
            for field, value in pairs(before) do assert(final[field] == value, field .. ' changed after reload') end
            """;

        CraftHistory? repaired = LoadRepairAndReimport(written, exercise,
            [unknown with { RecipeId = 123 }, known]);
        if (OperatingSystem.IsWindows()) return;
        Assert.That(repaired, Is.Not.Null);
        CraftObservation restored = repaired!.Crafts.Single(craft => craft.Identity == unknown.Identity);
        Assert.That(restored.InputsComplete, Is.True);
        Assert.That(restored.Outputs, Is.EquivalentTo(unknown.Outputs!));
        Assert.That(restored.Reagents, Is.EquivalentTo(unknown.Reagents));
        Assert.That(restored.Provenance, Is.EqualTo(unknown.Provenance));
        Assert.That(restored.ConfigurationEvidence, Is.EquivalentTo(unknown.ConfigurationEvidence!));
    }

    [Test]
    public void AmbiguousRecipeCandidatesKeepCompleteCompanionInputsAndAggregatesUnchanged()
    {
        CraftObservation unknown = Craft("ambiguous", "unknown", null, [new(90, 1, 1)]) with
        {
            InputsComplete = true,
            Reagents = [new(44, 3, null)]
        };
        CraftObservation first = Craft("ambiguous", "known-123", 123, [new(90, 1, 1)]);
        CraftObservation second = Craft("ambiguous", "known-456", 456, [new(90, 1, 1)]);
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(History(unknown, first, second), options: new(Now));

        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));
        CraftHistory? imported = LoadRepairAndReimport(written, """
            local unknown
            for _, craft in ipairs(ledger.database.crafts) do
              if craft.companionCraftObservation == 'unknown' then unknown = craft end
            end
            assert(unknown and unknown.companionInputsComplete == true)
            assert(unknown.inputComplete == nil and unknown.requestId == nil)
            local analysis = assert(ledger:AnalyzeUnknownRecipeRepair())
            assert(analysis.ambiguousCount == 1 and analysis.repairableCount == 0)
            local crafts, inputs, matched, allocated = 0, 0, 0, 0
            for _, row in ipairs(ledger.database.craftSeries) do
              crafts = crafts + row.craftCount
              inputs = inputs + (row.inputCompleteCount or 0)
              matched = matched + (row.matchedCraftCount or 0)
            end
            for _, row in ipairs(ledger.database.reagentSeries) do allocated = allocated + (row.allocatedQuantity or 0) end
            assert(crafts == 3 and inputs == 1 and matched == 0 and allocated == 3)
            assert(ledger:RepairUnknownRecipes().repairedCount == 0 and unknown.recipeId == nil)
            ledger = assert(addon.Ledger.New(ledger.database))
            assert(ledger:RepairUnknownRecipes().repairedCount == 0)
            """, [unknown, first, second]);
        if (OperatingSystem.IsWindows()) return;
        Assert.That(imported, Is.Not.Null);
        CraftObservation restored = imported!.Crafts.Single(craft => craft.Identity == unknown.Identity);
        Assert.That(restored.RecipeId, Is.Null);
        Assert.That(restored.InputsComplete, Is.True);
        Assert.That(restored.Reagents, Is.EquivalentTo(unknown.Reagents));
    }

    [Test]
    public void NativeRequestBackedInputsRemainSupportedAndExportWithoutCreatingRequests()
    {
        SavedVariablesImportResult imported = SavedVariablesReader.Parse("""
            return { schemaVersion = 4, schemaIdentity = "ArtisanLogbookLedger",
              crafts = { { id = 1, sessionId = 1, requestId = 7, recipeId = 123,
                timestamp = 1800000000, inputComplete = true, outputItemId = 90, outputQuantity = 1 } },
              requests = { { id = 7, sessionId = 1, recipeId = 123,
                allocations = { { itemId = 44, allocatedQuantity = 3 } }, fixedReagents = {} } },
              dimensions = {
                characters = { { id = 1, key = "project:1:region:3:realm:1309:guid:Player-A" } },
                sessions = { { id = 1, key = "session", projectId = 1, characterDimensionId = 1 } }
              }
            }
            """);
        Assert.That(imported.IsSuccessful, Is.True, string.Join(Environment.NewLine, imported.Diagnostics));
        CraftObservation craft = imported.History!.Crafts.Single();
        Assert.That(craft.InputsComplete, Is.True);
        Assert.That(craft.Provenance!.LocalRequestId, Is.EqualTo(7));
        SavedVariablesWriteResult written = SavedVariablesWriter.Serialize(imported.History, options: new(Now));
        Assert.That(written.IsSuccessful, Is.True, string.Join(Environment.NewLine, written.Diagnostics));

        CraftHistory? restored = LoadRepairAndReimport(written, """
            local craft = ledger.database.crafts[1]
            assert(craft.requestId == nil and craft.inputComplete == nil)
            assert(craft.companionInputsComplete == true and ledger.database.requests[1] == nil)
            assert(ledger.database.craftSeries[1].inputCompleteCount == 1)
            assert(ledger.database.craftSeries[1].matchedCraftCount == 0)
            """, imported.History.Crafts);
        if (OperatingSystem.IsWindows()) return;
        Assert.That(restored, Is.Not.Null);
        CraftObservation reimported = restored!.Crafts.Single();
        Assert.That(reimported.InputsComplete, Is.True);
        Assert.That(reimported.Provenance!.LocalRequestId, Is.EqualTo(7));
        Assert.That(reimported.Reagents, Is.EquivalentTo(new[] { new CraftReagent(44, 3, null) }));
    }

    private static CraftHistory? LoadRepairAndReimport(
        SavedVariablesWriteResult written, string exercise, IReadOnlyList<CraftObservation> expected)
    {
        SavedVariablesImportResult generated = SavedVariablesReader.Parse(written.Content!);
        Assert.That(generated.IsSuccessful, Is.True, string.Join(Environment.NewLine, generated.Diagnostics));
        if (OperatingSystem.IsWindows()) return generated.History;
        Assert.That(CanRunLua(), Is.True, "Lua 5.1 is required for loader validation on Linux.");
        string root = FindRepositoryRoot();
        string ledgerPath = Path.Combine(root, "src", "addon", "src", "ArtisanLogbook_Core", "Storage", "Ledger.lua");
        string temp = Path.Combine(Path.GetTempPath(), $"artisan-logbook-repair-{Guid.NewGuid():N}.lua");
        File.WriteAllText(temp, written.Content!);
        try
        {
            string script =
                $"dofile({LuaQuote(temp)}); local addon={{}}; assert(loadfile({LuaQuote(ledgerPath)}))('ArtisanLogbook_Core', addon); " +
                "local ledger, reason = addon.Ledger.New(ArtisanLogbookDB, { wall=function() return 1800000000 end }); " +
                "assert(ledger, reason); assert(ledger.database.schemaVersion == 5); " + exercise + "; " +
                "local function dump(value) if type(value)=='table' then local rows={} for key,child in pairs(value) do " +
                "rows[#rows+1]='['..dump(key)..']='..dump(child) end return '{'..table.concat(rows,',')..'}' " +
                "elseif type(value)=='string' then return string.format('%q',value) " +
                "elseif type(value)=='number' then return string.format('%.17g',value) else return tostring(value) end end; " +
                "print('ArtisanLogbookDB = '..dump(ledger.database))";
            ProcessStartInfo start = new("lua5.1") { RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("-e");
            start.ArgumentList.Add(script);
            using Process process = Process.Start(start) ?? throw new InvalidOperationException("Lua process could not start.");
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Assert.That(process.ExitCode, Is.Zero, $"{output}{Environment.NewLine}{error}");
            SavedVariablesImportResult reimported = SavedVariablesReader.Parse(output);
            Assert.That(reimported.IsSuccessful, Is.True, string.Join(Environment.NewLine, reimported.Diagnostics));
            Assert.That(reimported.History!.Crafts, Is.EquivalentTo(expected));
            return reimported.History;
        }
        finally
        {
            File.Delete(temp);
        }
    }

    private static string ConfigurationEvidencePayload()
    {
        LuaTable snapshot = new()
        {
            ["conditions"] = new LuaTable { ["useConcentration"] = false },
            ["craftFields"] = new LuaTable { ["configurationScope"] = "request", ["statsCoverage"] = "unavailable" }
        };
        return LuaDataParser.Serialize(new(
            new Dictionary<string, object?> { ["CraftConfigurationEvidence"] = snapshot }, null));
    }

    private static CraftObservation Craft(string origin, string observation, int? recipeId, IReadOnlyList<CraftOutput> outputs) =>
        new(new(origin, observation), Retail, Now, recipeId, Crafter,
            Outputs: outputs,
            Provenance: new(origin, 1, 10, SourceSessionId: "restored-session"),
            OutputsComplete: true);

    private static CraftHistory History(params CraftObservation[] crafts)
    {
        CraftDimensions dimensions = new(
            crafts.Select(c => new CharacterDimension(c.Game, c.Character)).Distinct().ToArray(),
            crafts.Where(c => c.RecipeId is not null)
                .Select(c => new RecipeDimension(c.Game, c.RecipeId!.Value)).Distinct().ToArray(),
            [],
            crafts.SelectMany(c => (c.Reagents ?? []).Select(r => new ItemDimension(c.Game, r.ItemId))
                .Concat((c.Outputs ?? []).Select(o => new ItemDimension(c.Game, o.ItemId)))).Distinct().ToArray(),
            []);
        return new(crafts, dimensions);
    }

    private static string LuaQuote(string value) => "'" + value.Replace("\\", "\\\\", StringComparison.Ordinal)
        .Replace("'", "\\'", StringComparison.Ordinal) + "'";

    private static string FindRepositoryRoot()
    {
        foreach (string start in new[] { Environment.CurrentDirectory, AppContext.BaseDirectory })
        {
            DirectoryInfo? current = new(start);
            while (current is not null)
            {
                if (File.Exists(Path.Combine(current.FullName, "src", "addon", "src", "ArtisanLogbook_Core", "Storage", "Ledger.lua")))
                    return current.FullName;
                current = current.Parent;
            }
        }
        throw new DirectoryNotFoundException("Repository root was not found.");
    }

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
}
