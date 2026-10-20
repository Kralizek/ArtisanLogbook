using System.Globalization;
using System.Text;

using ArtisanLogbook.History;

namespace ArtisanLogbook.SavedVariables;

public enum SavedVariablesTargetPolicy
{
    Reject,
    Regenerate
}

public sealed record SavedVariablesWriteOptions(
    DateTimeOffset? Now = null,
    int RetentionDays = 60,
    GameContext? GameContext = null,
    SavedVariablesCoverage? SourceCoverage = null,
    SavedVariablesTargetPolicy ExistingTargetPolicy = SavedVariablesTargetPolicy.Reject);

public sealed record SavedVariablesWriteResult(
    string? Content,
    IReadOnlyList<SavedVariablesDiagnostic> Diagnostics,
    int DetailedCraftCount,
    int RollupCraftCount)
{
    public bool IsSuccessful => Content is not null &&
        Diagnostics.All(d => d.Severity != SavedVariablesDiagnosticSeverity.Error);
}

/// <summary>Produces a data-only SavedVariables file; it never writes to disk.</summary>
public static class SavedVariablesWriter
{
    private const long MaximumLuaInteger = 9_007_199_254_740_991;
    private static readonly string[] GeneratedLedgerFields =
    [
        "schemaVersion", "schemaIdentity", "nextCraftId", "nextRequestId", "nextConfigurationKey",
        "crafts", "craftSeries", "resourcefulnessSets", "reagentSeries", "reagentRequirementSeries",
        "firstCraftRewards", "recipeOutputs", "requests", "reagents", "dimensions",
        "nextDimensionId", "retentionDays", "outcomeVersion", "returnedReagents"
    ];

    public static SavedVariablesWriteResult Serialize(
        CraftHistory history,
        string? existingTargetState = null,
        SavedVariablesWriteOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(history);
        try
        {
            return SerializeCore(history, existingTargetState, options ?? new());
        }
        catch (OverflowException)
        {
            return Failure("measurement-overflow", "history",
                "Summed observations exceed the supported numeric range. No content was generated.");
        }
        catch (ArgumentOutOfRangeException)
        {
            return Failure("invalid-retention-range", "options.RetentionDays",
                "The retention cutoff is outside the supported timestamp range.");
        }
    }

    private static SavedVariablesWriteResult SerializeCore(
        CraftHistory history, string? existingTargetState, SavedVariablesWriteOptions options)
    {
        List<SavedVariablesDiagnostic> diagnostics = [];
        if (options.RetentionDays <= 0)
            return Failure("invalid-retention", "options.RetentionDays", "Retention must be a positive number of days.");
        if (!Enum.IsDefined(options.ExistingTargetPolicy))
            return Failure("invalid-target-policy", "options.ExistingTargetPolicy", "Select a supported target regeneration policy.");

        foreach (HistoryValidationError error in CraftHistoryValidator.Validate(history))
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-canonical-history",
                error.Identity is null ? error.Field : $"craft[{error.Identity.Observation}].{error.Field}",
                error.Message));
        if (diagnostics.Count > 0) return new(null, diagnostics, 0, 0);

        LuaDocument? target = null;
        LuaTable? existingLedger = null;
        if (existingTargetState is not null)
        {
            try
            {
                target = LuaDataParser.Parse(existingTargetState);
            }
            catch (LuaSyntaxException exception)
            {
                return Failure("malformed-target-state", "existingTargetState", exception.Message);
            }
            catch (ArgumentException exception)
            {
                return Failure("invalid-target-state", "existingTargetState", exception.Message);
            }
            if (target.Assignments.TryGetValue("ArtisanLogbookDB", out object? value))
            {
                existingLedger = value as LuaTable;
                if (existingLedger is null)
                    return Failure("invalid-target-ledger", "ArtisanLogbookDB", "The existing target ledger is not a table.");
            }
            else if (target.ReturnedValue is not null)
            {
                return Failure("invalid-target-ledger", "existingTargetState",
                    "Target state must use SavedVariables assignments, not a returned table.");
            }
        }

        GameContext? selectedGame = options.GameContext;
        GameContext[] games = history.Crafts.Select(c => c.Game).Distinct().ToArray();
        if (selectedGame is null)
        {
            if (games.Length != 1)
                return Failure("game-context-required", "options.GameContext",
                    games.Length == 0
                        ? "Select a game context when exporting an empty history."
                        : "A SavedVariables target represents one game context; select it explicitly.");
            selectedGame = games[0];
        }
        CraftObservation[] crafts = history.Crafts
            .Where(c => c.Game == selectedGame)
            .OrderBy(c => c.RecordedAt)
            .ThenBy(c => c.Identity.Origin, StringComparer.Ordinal)
            .ThenBy(c => c.Identity.Observation, StringComparer.Ordinal)
            .ToArray();

        if (existingLedger is not null)
        {
            if (options.ExistingTargetPolicy != SavedVariablesTargetPolicy.Regenerate)
                return Failure("target-regeneration-policy-required", "options.ExistingTargetPolicy",
                    "An existing ledger requires explicit Regenerate consent. Requests, sessions, detail and rollups are replaced; addon-only facts cannot all be preserved. C09 must back up the target before replacement.");
            SavedVariablesImportResult imported = SavedVariablesReader.Parse(existingTargetState!);
            if (!imported.IsSuccessful)
                return new(null, imported.Diagnostics.Concat(new[]
                {
                    new SavedVariablesDiagnostic(SavedVariablesDiagnosticSeverity.Error,
                        "invalid-target-history", "existingTargetState",
                        "The target could not be imported safely. Resolve its diagnostics before regeneration.")
                }).ToArray(), 0, 0);
            if (imported.History!.Crafts.Any(c => c.Game != selectedGame) ||
                GetDimensionRows(existingLedger, "sessions").Any(s =>
                    Long(s.Get("projectId")) != (int)selectedGame.Project ||
                    !string.Equals(s.Get("companionProgressionTrack") as string,
                        selectedGame.ProgressionTrack, StringComparison.Ordinal)))
                return Failure("target-game-context-mismatch", "existingTargetState",
                    "Every existing target session and craft must belong to the selected game context.");
            CraftHistoryMergeResult merged = CraftHistoryReconciler.Merge(history, imported.History);
            Dictionary<CraftIdentity, CraftObservation> supplied = history.Crafts.ToDictionary(c => c.Identity);
            if (!merged.IsSuccessful || merged.History!.Crafts.Any(c =>
                !supplied.TryGetValue(c.Identity, out CraftObservation? provided) || provided != c))
                return Failure("target-history-not-reconciled", "existingTargetState",
                    "Import and reconcile every target craft into canonical history before regeneration. Missing, conflicting or unenriched observations would otherwise be lost.");
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "target-operational-state-regenerated",
                "ArtisanLogbookDB",
                $"Explicit regeneration replaces {Rows(existingLedger.Get("crafts")).Count} detail rows and {GetDimensionRows(existingLedger, "sessions").Count} sessions; discards {Rows(existingLedger.Get("requests")).Count} requests, {Rows(existingLedger.Get("firstCraftRewards")).Count} first-craft reward rows and {Rows(existingLedger.Get("reagentRequirementSeries")).Count} reagent requirement rollups. All supported rollups are recomputed, not merged. Configuration rows and unrelated assignments/settings are retained; craft-linked configuration/requirement/request evidence is not restored. C09 must retain a verified backup."));
            if (imported.Coverage.AggregateOnlyCraftCount > 0)
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "source-history-incomplete",
                    "ArtisanLogbookDB.craftSeries",
                    $"{imported.Coverage.AggregateOnlyCraftCount} target craft(s) have only aggregate coverage. Those totals are not copied or fabricated; regeneration uses available canonical observations only."));
        }

        if (crafts.Any(c => !SavedVariablesReader.HasStableCharacterKey(c.Character.Key, (int)c.Game.Project)))
            return Failure("unrepresentable-character-identity", "crafts.Character",
                "The addon requires a stable project/region/realm/GUID character key matching the selected context.");
        if (crafts.Any(c => (c.Reagents ?? []).Any(r => r.AllocatedQuantity > MaximumLuaInteger) ||
            (c.Outputs ?? []).Any(o => o.Quantity > MaximumLuaInteger)))
            return Failure("lua-integer-precision", "crafts",
                "A quantity exceeds Lua 5.1's exact integer range.");
        if (crafts.Any(c => c.RecipeId is null && c.InputsComplete == true))
            return Failure("unsupported-unknown-recipe-restoration", "crafts.RecipeId",
                "Unknown-recipe crafts with complete companion-only inputs cannot yet be safely repaired by the addon. Reconcile a verified recipe first.");

        DateTimeOffset now = options.Now ?? DateTimeOffset.UtcNow;
        DateTimeOffset cutoff = now.AddDays(-options.RetentionDays);
        CraftObservation[] detailedCrafts = crafts.Where(c => c.RecordedAt >= cutoff).ToArray();
        int omittedDetails = crafts.Length - detailedCrafts.Length;
        if (omittedDetails > 0)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "retention-window",
                "ArtisanLogbookDB.crafts",
                $"{omittedDetails} available craft(s) older than {options.RetentionDays} days were omitted from detail; their supported rollups were regenerated."));
        if (options.SourceCoverage is { AggregateOnlyCraftCount: > 0 } coverage)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "source-history-incomplete",
                "ArtisanLogbookDB.craftSeries",
                $"{coverage.AggregateOnlyCraftCount} source craft(s) existed only as rollups and were not fabricated or included in canonical history."));

        Dictionary<string, LuaTable> oldCharacters = IndexByStringKey(
            GetDimensionRows(existingLedger, "characters"), "key");

        string[] characterKeys = crafts.Select(c => c.Character.Key).Distinct(StringComparer.Ordinal)
            .OrderBy(x => x, StringComparer.Ordinal).ToArray();
        Dictionary<string, long> characterIds = characterKeys.Select((key, index) => (key, id: (long)index + 1))
            .ToDictionary(x => x.key, x => x.id, StringComparer.Ordinal);
        Dictionary<string, long> sessionIds = characterKeys.Select((key, index) => (key, id: (long)index + 1))
            .ToDictionary(x => x.key, x => x.id, StringComparer.Ordinal);

        Dictionary<string, ExpansionDimension> expansionsByKey = history.Dimensions.Expansions
            .Where(e => e.Game == selectedGame)
            .GroupBy(e => e.Key, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
        foreach (string key in history.Dimensions.Recipes.Where(r => r.Game == selectedGame)
            .Select(r => r.ProfessionExpansionKey).Where(k => k is not null).Cast<string>()
            .Concat(crafts.Select(c => c.ProfessionExpansionKey).Where(k => k is not null).Cast<string>())
            .Distinct(StringComparer.Ordinal))
            expansionsByKey.TryAdd(key, new(selectedGame, key));
        Dictionary<string, long> expansionIds = expansionsByKey.Keys.Order(StringComparer.Ordinal)
            .Select((key, index) => (key, id: (long)index + 1))
            .ToDictionary(x => x.key, x => x.id, StringComparer.Ordinal);

        LuaTable characters = Sequence(characterKeys.Select((key, index) =>
        {
            LuaTable row = ExistingDimension(oldCharacters, key);
            long id = index + 1L;
            Put(row, "id", id);
            Put(row, "key", key);
            Put(row, "guid", GuidFromCharacterKey(key) ?? row.Get("guid"));
            Put(row, "name", FindCharacter(history, selectedGame, key)?.Name ?? row.Get("name"));
            Put(row, "classFile", FindCharacter(history, selectedGame, key)?.ClassFile ?? row.Get("classFile"));
            Put(row, "realmDimensionId", null);
            return row;
        }));

        LuaTable realms = Sequence(Array.Empty<LuaTable>());
        LuaTable sessions = Sequence(characterKeys.Select((key, index) =>
        {
            LuaTable row = new();
            long sessionId = index + 1L;
            Put(row, "id", sessionId);
            Put(row, "key", $"companion-session-{selectedGame.Project}-{sessionId}");
            Put(row, "startedAt", now.ToUnixTimeSeconds());
            Put(row, "companionSynthetic", true);
            Put(row, "projectId", (int)selectedGame.Project);
            Put(row, "characterDimensionId", characterIds[key]);
            Put(row, "capabilities", new LuaTable());
            if (selectedGame.ProgressionTrack is not null)
                Put(row, "companionProgressionTrack", selectedGame.ProgressionTrack);
            return row;
        }));
        LuaTable recipes = NaturalDimensions(history.Dimensions.Recipes
            .Where(r => r.Game == selectedGame).Select(r => (r.Id, r.Name, r.ProfessionId,
                ExpansionKey: r.ProfessionExpansionKey, MaxQuality: r.MaxQuality)),
            expansionIds);
        LuaTable professions = NaturalDimensions(history.Dimensions.Professions
            .Where(p => p.Game == selectedGame)
            .Select(p => (p.Id, p.Name, ProfessionId: (int?)null, ExpansionKey: (string?)null, MaxQuality: (int?)null)),
            expansionIds);
        foreach (ProfessionDimension profession in history.Dimensions.Professions.Where(p => p.Game == selectedGame))
            if (profession.ParentId is int parentId && professions.Get(profession.Id) is LuaTable row)
                Put(row, "companionParent", parentId);
        LuaTable items = NaturalDimensions(history.Dimensions.Items
            .Where(i => i.Game == selectedGame)
            .Select(i => (i.Id, i.Name, ProfessionId: (int?)null,
                ExpansionKey: (string?)null, MaxQuality: (int?)null)),
            expansionIds);
        EnsureUsedDimensions(crafts, recipes, professions, items, expansionIds);
        foreach (LuaTable recipe in recipes.Values.OfType<LuaTable>())
            if (Long(recipe.Get("professionId")) is long professionId &&
                !professions.ContainsKey((double)professionId))
                Put(professions, professionId, Table(("id", professionId)));
        LuaTable expansionRows = Sequence(expansionsByKey.OrderBy(x => expansionIds[x.Key])
            .Select(x => Table(("id", (object?)expansionIds[x.Key]), ("key", x.Key),
                ("name", x.Value.Name))));
        LuaTable dimensions = Table(
            ("characters", characters),
            ("realms", realms),
            ("sessions", sessions),
            ("expansions", expansionRows),
            ("professions", professions),
            ("recipes", recipes),
            ("items", items));

        Dictionary<CraftIdentity, long> craftIds = new();
        long nextCraftId = 1;
        foreach (CraftObservation craft in detailedCrafts)
        {
            craftIds.Add(craft.Identity, nextCraftId);
            nextCraftId++;
        }
        LuaTable detailRows = Sequence(detailedCrafts.SelectMany(craft =>
            MakeCraftRows(craft, craftIds[craft.Identity], sessionIds[craft.Character.Key])));
        LuaTable reagentRows = Sequence(detailedCrafts.SelectMany(craft =>
            MakeReagentRows(craft, craftIds[craft.Identity])));
        LuaTable craftSeries = RebuildCraftSeries(crafts, characterIds);
        LuaTable reagentSeries = RebuildReagentSeries(crafts, characterIds);
        LuaTable resourcefulnessSets = RebuildResourcefulnessSets(crafts, characterIds);
        LuaTable recipeOutputs = RebuildRecipeOutputs(crafts);

        LuaTable database = new();
        if (existingLedger is not null)
        {
            foreach ((object key, object? value) in existingLedger)
            {
                if (key is string field && GeneratedLedgerFields.Contains(field, StringComparer.Ordinal))
                    continue;
                database[key] = Clone(value);
            }
        }
        Put(database, "schemaVersion", 5);
        Put(database, "schemaIdentity", "ArtisanLogbookLedger");
        Put(database, "nextCraftId", nextCraftId);
        Put(database, "nextRequestId", 1);
        Put(database, "nextConfigurationKey", NextConfigurationKey(database.Get("configurations")));
        Put(database, "crafts", detailRows);
        Put(database, "craftSeries", craftSeries);
        Put(database, "resourcefulnessSets", resourcefulnessSets);
        Put(database, "reagentSeries", reagentSeries);
        Put(database, "reagentRequirementSeries", Sequence(Array.Empty<LuaTable>()));
        Put(database, "firstCraftRewards", Sequence(Array.Empty<LuaTable>()));
        Put(database, "configurations", database.Get("configurations") as LuaTable ?? new());
        Put(database, "recipeOutputs", recipeOutputs);
        Put(database, "requests", Sequence(Array.Empty<LuaTable>()));
        Put(database, "reagents", reagentRows);
        Put(database, "dimensions", dimensions);
        Put(database, "nextDimensionId", Table(
            ("character", (object?)(characterKeys.Length + 1L)),
            ("expansion", expansionIds.Count + 1L),
            ("realm", 1L),
            ("session", characterKeys.Length + 1L)));
        Put(database, "retentionDays", options.RetentionDays);

        if (existingLedger is not null && Rows(existingLedger.Get("firstCraftRewards")).Count > 0)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "first-craft-rewards-not-rebuilt",
                "ArtisanLogbookDB.firstCraftRewards",
                "First-craft reward rollups have no craft-level counterpart in the canonical model and were not carried into the regenerated ledger."));
        Dictionary<string, object?> assignments = target is null
            ? new(StringComparer.Ordinal)
            : target.Assignments.Where(x => x.Key != "ArtisanLogbookDB")
                .ToDictionary(x => x.Key, x => Clone(x.Value), StringComparer.Ordinal);
        assignments["ArtisanLogbookDB"] = database;
        if (!HasSafeLuaNumbers(database))
            return Failure("lua-integer-precision", "ArtisanLogbookDB",
                "A measurement or regenerated rollup exceeds Lua 5.1's exact numeric range.");
        string content = LuaDataParser.Serialize(new(assignments, null));
        SavedVariablesImportResult roundTrip = SavedVariablesReader.Parse(content);
        if (!roundTrip.IsSuccessful ||
            !detailedCrafts.ToHashSet().SetEquals(roundTrip.History!.Crafts))
            return Failure("unrepresentable-craft-observations", "history",
                "Generated content cannot retain the supplied detailed observations exactly within the supported Lua representation. No content was returned. " +
                string.Join(" ", roundTrip.Diagnostics.Where(d => d.Severity == SavedVariablesDiagnosticSeverity.Error)
                    .Select(d => $"{d.Location}: {d.Message}")));
        return new(content, diagnostics, detailRows.Count, crafts.Length);
    }

    private static IEnumerable<LuaTable> MakeCraftRows(CraftObservation craft, long id, long sessionId)
    {
        IReadOnlyList<CraftOutput>? outputs = craft.Outputs;
        string outputGroup = Convert.ToBase64String(Encoding.UTF8.GetBytes(
            $"{craft.Identity.Origin.Length}:{craft.Identity.Origin}{craft.Identity.Observation}"));
        for (int index = 0; index < 1; index++)
        {
            LuaTable row = Table(
                ("id", id + index),
                ("sessionId", sessionId),
                ("timestamp", craft.RecordedAt.ToUnixTimeSeconds()),
                ("companionRecordedAt", craft.RecordedAt.ToString("O", CultureInfo.InvariantCulture)),
                ("companionOutputGroup", outputGroup),
                ("companionCraftOrigin", craft.Identity.Origin),
                ("companionCraftObservation", craft.Identity.Observation),
                ("companionClassificationPresent", true),
                ("companionProfession", craft.ProfessionId),
                ("companionProfessionExpansionKey", craft.ProfessionExpansionKey),
                ("companionReagentsObserved", craft.Reagents is not null));
            if (craft.Provenance?.SourceId is string sourceId)
            {
                Put(row, "companionProvenanceSource", sourceId);
                Put(row, "companionProvenancePresent", true);
                Put(row, "companionSourceCraftSpecified", craft.Provenance.LocalCraftId is not null);
                Put(row, "companionSourceSessionSpecified", craft.Provenance.SourceSessionId is not null);
                Put(row, "companionResourcefulnessEvidenceSpecified",
                    craft.Provenance.ResourcefulnessEvidence is not null);
            }
            else
            {
                Put(row, "companionProvenancePresent", false);
            }
            if (craft.Provenance?.LocalCraftId is long localCraftId)
                Put(row, "companionSourceCraft", localCraftId.ToString(CultureInfo.InvariantCulture));
            if (craft.RecipeId is int recipeId) Put(row, "recipeId", recipeId);
            if (craft.Provenance?.GameOperationId is long operationId && operationId is > 0 and <= MaximumLuaInteger)
                Put(row, "gameOperationId", operationId);
            if (craft.Provenance?.GameOperationId is long sourceOperationId)
                Put(row, "companionSourceOperation", sourceOperationId.ToString(CultureInfo.InvariantCulture));
            if (craft.Provenance?.LocalRequestId is long requestId)
                Put(row, "companionSourceRequest", requestId.ToString(CultureInfo.InvariantCulture));
            if (craft.Provenance?.SourceSessionId is string sourceSessionId)
                Put(row, "companionSourceSession", sourceSessionId);
            if (craft.Provenance?.ResourcefulnessEvidence is string sourceEvidence)
                Put(row, "companionResourcefulnessEvidence", sourceEvidence);
            if (craft.ConcentrationSpent is int concentrationSpent) Put(row, "concentrationSpent", concentrationSpent);
            if (craft.ConcentrationCurrencyId is int currencyId) Put(row, "concentrationCurrencyId", currencyId);
            if (craft.IngenuityRefund is int ingenuityRefund) Put(row, "ingenuityRefund", ingenuityRefund);
            if (craft.HasIngenuityProc is bool ingenuityProc) Put(row, "hasIngenuityProc", ingenuityProc);
            if (craft.HasResourcefulnessProc is bool resourcefulnessProc)
                Put(row, "hasResourcefulnessProc", resourcefulnessProc);
            if (craft.ResourcefulnessComplete is true)
            {
                Put(row, "resourcefulnessComplete", true);
                if (craft.Provenance?.ResourcefulnessEvidence == "native")
                {
                    Put(row, "outcomeSource", "native");
                    Put(row, "materialsSavingsEligible", false);
                }
            }
            else if (craft.ResourcefulnessComplete is false && craft.HasResourcefulnessProc == true)
            {
                Put(row, "outcomeSource", "partial");
            }
            else if (craft.HasResourcefulnessProc == true)
            {
                Put(row, "outcomeSource", "unverified");
            }
            if (craft.Provenance?.ResourcefulnessEvidence is string evidence)
                Put(row, "companionResourcefulnessEvidence", evidence);
            if (craft.Provenance is not null)
                Put(row, "companionResourcefulnessEvidenceSpecified",
                    craft.Provenance.ResourcefulnessEvidence is not null);
            if (craft.ResourcefulnessComplete is bool complete)
                Put(row, "companionResourcefulnessComplete", complete);
            Put(row, "companionCompletenessPresent", true);
            if (craft.InputsComplete is bool inputsComplete)
                Put(row, "companionInputsComplete", inputsComplete);
            if (craft.OutputObservations is not null || outputs is { Count: > 1 })
            {
                IReadOnlyList<CraftOutputObservation> observations = craft.OutputObservations ?? outputs!.Select(output =>
                    new CraftOutputObservation(output, craft.RecordedAt, new(), [])).ToArray();
                Put(row, "attemptKind", "restored-operation");
                Put(row, "companionOutputObservationsPresent", craft.OutputObservations is not null);
                Put(row, "outputs", Sequence(observations.Select(observation => Table(
                    ("itemId", observation.Output.ItemId), ("quantity", observation.Output.Quantity),
                    ("quality", observation.Output.Quality), ("itemLevel", observation.ItemLevel),
                    ("timestamp", observation.ObservedAt.ToUnixTimeSeconds()),
                    ("companionObservedAt", observation.ObservedAt.ToString("O", CultureInfo.InvariantCulture)),
                    ("companionLegacyCraftId", observation.LegacyCraftId?.ToString(CultureInfo.InvariantCulture)),
                    ("quantityAmbiguous", observation.QuantityAmbiguous ? true : null),
                    ("measurements", Table(("multicraftBonus", observation.Measurements.MulticraftBonus),
                        ("concentrationSpent", observation.Measurements.ConcentrationSpent),
                        ("concentrationCurrencyId", observation.Measurements.ConcentrationCurrencyId),
                        ("hasIngenuityProc", observation.Measurements.HasIngenuityProc),
                        ("ingenuityRefund", observation.Measurements.IngenuityRefund))),
                    ("returns", Sequence(observation.Returns.OrderBy(returned => returned.ItemId).Select(returned =>
                        Table(("itemId", returned.ItemId), ("returnedQuantity", returned.ReturnedQuantity)))))))));
                bool ambiguous = observations.Any(observation => observation.QuantityAmbiguous);
                Put(row, "outputAmbiguous", ambiguous ? true : null);
                Put(row, "outputQuantity", ambiguous ? null : observations.Sum(observation => observation.Output.Quantity));
                if (observations.Count == 1)
                {
                    Put(row, "outputItemId", observations[0].Output.ItemId);
                    Put(row, "outputQuality", observations[0].Output.Quality);
                    Put(row, "outputItemLevel", observations[0].ItemLevel);
                }
                DateTimeOffset lastObservedAt = observations.Max(observation => observation.ObservedAt);
                if (lastObservedAt > craft.RecordedAt) Put(row, "lastObservedAt", lastObservedAt.ToUnixTimeSeconds());
            }
            else if (outputs is { Count: 0 })
            {
                Put(row, "companionOutputsObserved", true);
            }
            else if (outputs is not null)
            {
                CraftOutput output = outputs[index];
                Put(row, "outputItemId", output.ItemId);
                Put(row, "outputQuantity", output.Quantity);
                if (output.Quality is int quality) Put(row, "outputQuality", quality);
            }
            if (craft.MulticraftBonus is int multicraftBonus)
                Put(row, "multicraftBonus", multicraftBonus);
            yield return row;
        }
    }

    private static IEnumerable<LuaTable> MakeReagentRows(CraftObservation craft, long craftId)
    {
        foreach (CraftReagent reagent in craft.Reagents ?? [])
        {
            LuaTable row = Table(("craftId", craftId), ("itemId", reagent.ItemId));
            if (reagent.AllocatedQuantity is long allocation)
            {
                if (allocation == 0)
                    Put(row, "companionAllocatedQuantity", 0L);
                else
                    Put(row, "allocatedQuantity", allocation);
            }
            if (reagent.ReturnedQuantity is decimal returned)
                Put(row, "returnedQuantity", returned);
            yield return row;
        }
    }

    private static LuaTable RebuildCraftSeries(
        IEnumerable<CraftObservation> crafts,
        IReadOnlyDictionary<string, long> characterIds)
    {
        Dictionary<(long Day, long CharacterId, int? RecipeId), LuaTable> groups = [];
        string[] metrics =
        [
            "outputQuantity", "multicraftBonus", "concentrationSpent", "ingenuityProcCount",
            "ingenuityRefund", "multicraftProcCount", "resourcefulnessProcCount",
            "resourcefulnessCompleteProcCount", "resourcefulnessAuthoritativeProcCount"
        ];
        foreach (CraftObservation craft in crafts)
        {
            long day = Math.DivRem(craft.RecordedAt.ToUnixTimeSeconds(), 86400, out long remainder);
            if (remainder < 0) day--;
            day *= 86400;
            var key = (day, characterIds[craft.Character.Key], craft.RecipeId);
            if (!groups.TryGetValue(key, out LuaTable? row))
            {
                row = Table(("bucketStart", day), ("characterDimensionId", key.Item2),
                    ("recipeId", craft.RecipeId), ("craftCount", 0L),
                    ("quoteObservedCount", 0L), ("inputCompleteCount", 0L),
                    ("matchedCraftCount", 0L), ("grossRequirementsCompleteCount", 0L));
                foreach (string metric in metrics)
                {
                    Put(row, metric + "ObservedCount", 0L);
                    Put(row, metric, null);
                }
                groups.Add(key, row);
            }
            AddCount(row, "craftCount", 1);
            if (craft.InputsComplete == true) AddCount(row, "inputCompleteCount", 1);
            AddMetric(row, "outputQuantity",
                craft.OutputObservations?.Any(observation => observation.QuantityAmbiguous) == true
                    ? null : craft.Outputs?.Sum(output => (double)output.Quantity));
            AddMetric(row, "multicraftBonus", craft.MulticraftBonus);
            AddMetric(row, "concentrationSpent", craft.ConcentrationSpent);
            AddMetric(row, "ingenuityProcCount", craft.HasIngenuityProc is bool ingenuity ? ingenuity ? 1 : 0 : null);
            AddMetric(row, "ingenuityRefund",
                craft.HasIngenuityProc == false ? 0 : craft.HasIngenuityProc == true ? craft.IngenuityRefund : null);
            AddMetric(row, "multicraftProcCount",
                craft.MulticraftBonus is int bonus ? bonus > 0 ? 1 : 0 : null);
            AddMetric(row, "resourcefulnessProcCount",
                craft.HasResourcefulnessProc is bool proc ? proc ? 1 : 0 : null);
            AddMetric(row, "resourcefulnessCompleteProcCount",
                craft.ResourcefulnessComplete == true ? craft.HasResourcefulnessProc == true ? 1 : 0 : null);
            AddMetric(row, "resourcefulnessAuthoritativeProcCount",
                craft.ResourcefulnessComplete == true && craft.Provenance?.ResourcefulnessEvidence == "native"
                    ? craft.HasResourcefulnessProc == true ? 1 : 0 : null);
        }
        return Sequence(groups.OrderBy(g => g.Key.Day).ThenBy(g => g.Key.CharacterId)
            .ThenBy(g => g.Key.RecipeId).Select(g => g.Value));
    }

    private static LuaTable RebuildReagentSeries(
        IEnumerable<CraftObservation> crafts,
        IReadOnlyDictionary<string, long> characterIds)
    {
        Dictionary<(long Day, long CharacterId, int? RecipeId, int ItemId), LuaTable> groups = [];
        foreach (CraftObservation craft in crafts)
        {
            long timestamp = craft.RecordedAt.ToUnixTimeSeconds();
            long day = Math.DivRem(timestamp, 86400, out long remainder) * 86400;
            if (remainder < 0) day -= 86400;
            foreach (CraftReagent reagent in craft.Reagents ?? [])
            {
                if (reagent.AllocatedQuantity is not > 0 && reagent.ReturnedQuantity is not > 0)
                    continue;
                var key = (day, characterIds[craft.Character.Key], craft.RecipeId, reagent.ItemId);
                if (!groups.TryGetValue(key, out LuaTable? row))
                {
                    row = Table(("bucketStart", day), ("characterDimensionId", key.Item2),
                        ("recipeId", craft.RecipeId), ("itemId", reagent.ItemId));
                    groups.Add(key, row);
                }
                if (reagent.AllocatedQuantity is > 0 and long allocation)
                {
                    AddCount(row, "allocationCount", 1);
                    AddCount(row, "allocatedQuantity", allocation);
                }
                if (reagent.ReturnedQuantity is decimal returned && returned > 0)
                    AddDecimal(row, "returnedQuantity", returned);
            }
        }
        return Sequence(groups.OrderBy(g => g.Key.Day).ThenBy(g => g.Key.CharacterId)
            .ThenBy(g => g.Key.RecipeId).ThenBy(g => g.Key.ItemId).Select(g => g.Value));
    }

    private static LuaTable RebuildResourcefulnessSets(
        IEnumerable<CraftObservation> crafts,
        IReadOnlyDictionary<string, long> characterIds)
    {
        Dictionary<(long Day, long CharacterId, int? RecipeId, string Items), LuaTable> groups = [];
        foreach (CraftObservation craft in crafts.Where(c => c.ResourcefulnessComplete == true &&
            c.HasResourcefulnessProc == true))
        {
            long timestamp = craft.RecordedAt.ToUnixTimeSeconds();
            long day = Math.DivRem(timestamp, 86400, out long remainder) * 86400;
            if (remainder < 0) day -= 86400;
            string items = string.Join(',', craft.Reagents!.Where(r => r.ReturnedQuantity is > 0)
                .Select(r => r.ItemId).Order());
            var key = (day, characterIds[craft.Character.Key], craft.RecipeId, items);
            if (!groups.TryGetValue(key, out LuaTable? row))
            {
                row = Table(("bucketStart", day), ("characterDimensionId", key.Item2),
                    ("recipeId", craft.RecipeId), ("returnedItemSet", items),
                    ("craftCount", 0L));
                groups.Add(key, row);
            }
            AddCount(row, "craftCount", 1);
            if (craft.Provenance?.ResourcefulnessEvidence == "native")
                AddCount(row, "authoritativeCraftCount", 1);
        }
        return Sequence(groups.OrderBy(g => g.Key.Day).ThenBy(g => g.Key.CharacterId)
            .ThenBy(g => g.Key.RecipeId).ThenBy(g => g.Key.Items, StringComparer.Ordinal)
            .Select(g => g.Value));
    }

    private static LuaTable RebuildRecipeOutputs(IEnumerable<CraftObservation> crafts)
    {
        LuaTable outputs = new();
        foreach (IGrouping<int, CraftObservation> recipeGroup in crafts
            .Where(c => c.RecipeId is > 0 && c.Outputs is not null)
            .GroupBy(c => c.RecipeId!.Value))
        {
            LuaTable items = new();
            foreach (int itemId in recipeGroup.SelectMany(c => c.Outputs!)
                .Select(o => o.ItemId).Distinct().Order())
                Put(items, itemId, true);
            Put(outputs, recipeGroup.Key, items);
        }
        return outputs;
    }

    private static void EnsureUsedDimensions(
        IEnumerable<CraftObservation> crafts,
        LuaTable recipes,
        LuaTable professions,
        LuaTable items,
        IReadOnlyDictionary<string, long> expansionIds)
    {
        foreach (CraftObservation craft in crafts)
        {
            if (craft.RecipeId is int recipeId && !recipes.ContainsKey((double)recipeId))
                Put(recipes, recipeId, Table(("id", recipeId)));
            if (craft.ProfessionId is int professionId && !professions.ContainsKey((double)professionId))
                Put(professions, professionId, Table(("id", professionId)));
            foreach (CraftReagent reagent in craft.Reagents ?? [])
                if (!items.ContainsKey((double)reagent.ItemId))
                    Put(items, reagent.ItemId, Table(("id", reagent.ItemId)));
            foreach (CraftOutput output in craft.Outputs ?? [])
                if (!items.ContainsKey((double)output.ItemId))
                    Put(items, output.ItemId, Table(("id", output.ItemId)));
            foreach (CraftOutputObservation observation in craft.OutputObservations ?? [])
            {
                if (!items.ContainsKey((double)observation.Output.ItemId))
                    Put(items, observation.Output.ItemId, Table(("id", observation.Output.ItemId)));
                foreach (CraftReagent returned in observation.Returns)
                    if (!items.ContainsKey((double)returned.ItemId))
                        Put(items, returned.ItemId, Table(("id", returned.ItemId)));
            }
            if (craft.RecipeId is int usedRecipeId && craft.ProfessionExpansionKey is string key &&
                recipes.TryGetValue((double)usedRecipeId, out object? recipeValue) &&
                recipeValue is LuaTable recipe && !recipe.ContainsKey("expansionDimensionId") &&
                expansionIds.TryGetValue(key, out long expansionId))
            {
                Put(recipe, "expansionDimensionId", expansionId);
                Put(recipe, "companionExpansionKey", key);
            }
            if (craft.RecipeId is int professionRecipeId && craft.ProfessionId is int usedProfession &&
                recipes.TryGetValue((double)professionRecipeId, out object? recipeWithProfessionValue) &&
                recipeWithProfessionValue is LuaTable recipeWithProfession &&
                !recipeWithProfession.ContainsKey("professionId"))
                Put(recipeWithProfession, "professionId", usedProfession);
        }
    }

    private static LuaTable NaturalDimensions(
        IEnumerable<(int Id, string? Name, int? ProfessionId, string? ExpansionKey, int? MaxQuality)> rows,
        IReadOnlyDictionary<string, long> expansionIds)
    {
        LuaTable result = new();
        foreach (var item in rows.GroupBy(x => x.Id).Select(g => g.First()).OrderBy(x => x.Id))
        {
            LuaTable row = Table(("id", item.Id), ("name", item.Name));
            if (item.ProfessionId is int professionId) Put(row, "professionId", professionId);
            if (item.ExpansionKey is string key && expansionIds.TryGetValue(key, out long expansionId))
            {
                Put(row, "expansionDimensionId", expansionId);
                Put(row, "companionExpansionKey", key);
            }
            if (item.MaxQuality is int maxQuality) Put(row, "maxQuality", maxQuality);
            Put(result, item.Id, row);
        }
        return result;
    }

    private static CharacterDimension? FindCharacter(CraftHistory history, GameContext game, string key) =>
        history.Dimensions.Characters.FirstOrDefault(c => c.Game == game && c.Identity.Key == key);

    private static Dictionary<string, LuaTable> IndexByStringKey(
        IEnumerable<LuaTable> rows,
        string keyField) =>
        rows.Where(row => row.Get(keyField) is string)
            .GroupBy(row => (string)row.Get(keyField)!, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);

    private static LuaTable ExistingDimension(IReadOnlyDictionary<string, LuaTable> oldRows, string key) =>
        oldRows.TryGetValue(key, out LuaTable? row) ? CloneTable(row) : new();

    private static string? GuidFromCharacterKey(string key)
    {
        string marker = ":guid:";
        int index = key.IndexOf(marker, StringComparison.Ordinal);
        return index >= 0 && index + marker.Length < key.Length ? key[(index + marker.Length)..] : null;
    }

    private static IReadOnlyList<LuaTable> GetDimensionRows(LuaTable? ledger, string name) =>
        ledger?.Get("dimensions") is LuaTable dimensions
            ? Rows(dimensions.Get(name))
            : [];

    private static IReadOnlyList<LuaTable> Rows(object? value) =>
        value is LuaTable table
            ? table.Values.OfType<LuaTable>().ToArray()
            : [];

    private static LuaTable Sequence(IEnumerable<LuaTable> rows)
    {
        LuaTable result = new();
        long index = 1;
        foreach (LuaTable row in rows) Put(result, index++, row);
        return result;
    }

    private static LuaTable Table(params (string Key, object? Value)[] entries)
    {
        LuaTable result = new();
        foreach ((string key, object? value) in entries) Put(result, key, value);
        return result;
    }

    private static void Put(LuaTable table, object key, object? value)
    {
        if (value is not null) table[key] = value;
        else table.Remove(key);
    }

    private static LuaTable CloneTable(LuaTable source) => (LuaTable)Clone(source)!;

    private static object? Clone(object? value)
    {
        if (value is not LuaTable source) return value;
        LuaTable result = new();
        foreach ((object key, object? child) in source)
            result[key] = Clone(child);
        return result;
    }

    private static bool HasSafeLuaNumbers(object? value) => value switch
    {
        LuaTable table => table.Values.All(HasSafeLuaNumbers),
        long integer => integer is >= -MaximumLuaInteger and <= MaximumLuaInteger,
        double number => double.IsFinite(number) && Math.Abs(number) <= MaximumLuaInteger,
        decimal number => Math.Abs(number) <= MaximumLuaInteger,
        _ => true
    };

    private static long? Long(object? value) => value switch
    {
        double number when double.IsFinite(number) && Math.Truncate(number) == number &&
            number >= long.MinValue && number <= long.MaxValue => (long)number,
        long integer => integer,
        int integer => integer,
        _ => null
    };

    private static double? Number(object? value) => value switch
    {
        double number when double.IsFinite(number) => number,
        long integer => integer,
        int integer => integer,
        _ => null
    };

    private static void AddMetric(LuaTable row, string metric, double? value)
    {
        if (value is null) return;
        AddCount(row, metric + "ObservedCount", 1);
        Put(row, metric, (Number(row.Get(metric)) ?? 0) + value.Value);
    }

    private static void AddMetric(LuaTable row, string metric, int? value) =>
        AddMetric(row, metric, value is null ? null : (double)value.Value);

    private static void AddCount(LuaTable row, string field, long amount) =>
        Put(row, field, (Long(row.Get(field)) ?? 0) + amount);

    private static void AddDecimal(LuaTable row, string field, decimal amount)
    {
        decimal previous = row.Get(field) is decimal value ? value :
            Number(row.Get(field)) is double number ? (decimal)number : 0;
        Put(row, field, previous + amount);
    }

    private static long NextConfigurationKey(object? value)
    {
        if (value is not LuaTable table) return 1;
        long maximum = table.Keys.Select(Long).Where(x => x is not null).Select(x => x!.Value)
            .DefaultIfEmpty(0).Max();
        return checked(maximum + 1);
    }

    private static SavedVariablesWriteResult Failure(string code, string location, string message) =>
        new(null, [new(SavedVariablesDiagnosticSeverity.Error, code, location, message)], 0, 0);
}
