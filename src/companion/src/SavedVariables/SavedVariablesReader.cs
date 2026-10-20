using System.Globalization;

using ArtisanLogbook.History;

namespace ArtisanLogbook.SavedVariables;

public enum SavedVariablesDiagnosticSeverity
{
    Information,
    Warning,
    Error
}

public sealed record SavedVariablesDiagnostic(
    SavedVariablesDiagnosticSeverity Severity,
    string Code,
    string Location,
    string Message);

public sealed record SavedVariablesCoverage(long AggregateOnlyCraftCount, bool HasPrunedHistory);

public sealed record SavedVariablesImportResult(
    int? SchemaVersion,
    CraftHistory? History,
    IReadOnlyList<SavedVariablesDiagnostic> Diagnostics,
    SavedVariablesCoverage Coverage)
{
    public bool HasErrors => Diagnostics.Any(d => d.Severity == SavedVariablesDiagnosticSeverity.Error);
    public bool IsSuccessful => History is not null && !HasErrors;
}

/// <summary>Maps supported ArtisanLogbook Core ledgers to canonical craft observations.</summary>
public static class SavedVariablesReader
{
    private static readonly HashSet<int> SupportedSchemas = [1, 2, 3, 4];

    public static SavedVariablesImportResult Parse(string source, string sourceName = "<memory>")
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceName);
        List<SavedVariablesDiagnostic> diagnostics = [];
        LuaDocument document;
        try
        {
            document = LuaDataParser.Parse(source);
        }
        catch (LuaSyntaxException exception)
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "malformed-lua", sourceName,
                exception.Message));
            return Failure(diagnostics);
        }
        catch (ArgumentException exception)
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-lua-input", sourceName,
                exception.Message));
            return Failure(diagnostics);
        }

        object? rootValue = document.ReturnedValue;
        if (rootValue is null && !document.Assignments.TryGetValue("ArtisanLogbookDB", out rootValue))
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "missing-ledger",
                "ArtisanLogbookDB", "No ArtisanLogbookDB assignment or returned ledger table was found."));
            return Failure(diagnostics);
        }
        if (rootValue is not LuaTable ledger)
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-ledger",
                "ArtisanLogbookDB", "The ledger value must be a table."));
            return Failure(diagnostics);
        }

        int? schemaVersion = Integer(ledger.Get("schemaVersion"));
        if (schemaVersion is null || !SupportedSchemas.Contains(schemaVersion.Value))
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "unsupported-schema",
                "ArtisanLogbookDB.schemaVersion", schemaVersion is null
                    ? "Ledger schemaVersion is missing or invalid."
                    : $"Ledger schema version {schemaVersion.Value} is not supported; supported versions are 1 through 4."));
            return new(schemaVersion, null, diagnostics, new(0, false));
        }
        if (!string.Equals(ledger.Get("schemaIdentity") as string, "ArtisanLogbookLedger", StringComparison.Ordinal))
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "unsupported-schema-identity",
                "ArtisanLogbookDB.schemaIdentity", "The table is not an ArtisanLogbook Core ledger."));
            return new(schemaVersion, null, diagnostics, new(0, false));
        }

        if (ledger.Get("dimensions") is not LuaTable && ledger.ContainsKey("dimensions"))
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-dimensions",
                "ArtisanLogbookDB.dimensions", "The dimension collection must be a table."));
            return new(schemaVersion, null, diagnostics, new(0, false));
        }
        LuaTable dimensions = ledger.Get("dimensions") as LuaTable ?? new();
        CheckCollection(ledger, "crafts", diagnostics);
        CheckCollection(ledger, "requests", diagnostics);
        CheckCollection(ledger, "reagents", diagnostics);
        CheckCollection(ledger, "craftSeries", diagnostics);
        foreach (string collection in new[]
        {
            "sessions", "characters", "realms", "recipes", "professions", "expansions", "items"
        })
            CheckCollection(dimensions, collection, diagnostics, "ArtisanLogbookDB.dimensions");
        IReadOnlyList<LuaTable> craftRows = Rows(ledger.Get("crafts"));
        IReadOnlyList<LuaTable> sessionRows = Rows(dimensions.Get("sessions"));
        IReadOnlyList<LuaTable> characterRows = Rows(dimensions.Get("characters"));
        IReadOnlyList<LuaTable> realmRows = Rows(dimensions.Get("realms"));
        IReadOnlyList<LuaTable> recipeRows = Rows(dimensions.Get("recipes"));
        IReadOnlyList<LuaTable> professionRows = Rows(dimensions.Get("professions"));
        IReadOnlyList<LuaTable> expansionRows = Rows(dimensions.Get("expansions"));
        IReadOnlyList<LuaTable> itemRows = Rows(dimensions.Get("items"));
        IReadOnlyList<LuaTable> requestRows = Rows(ledger.Get("requests"));
        IReadOnlyList<LuaTable> reagentRows = Rows(ledger.Get("reagents"));
        HashSet<long> craftIds = [];
        foreach (LuaTable craft in craftRows)
        {
            long? id = Long(craft.Get("id"));
            if (id is not null && !craftIds.Add(id.Value))
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "duplicate-craft-id",
                    $"ArtisanLogbookDB.crafts[id={id.Value}]",
                    "The local craft ID is duplicated; references cannot be mapped safely."));
        }

        if (!ledger.ContainsKey("crafts"))
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "missing-crafts",
                "ArtisanLogbookDB.crafts", "The detailed craft collection is absent; no individual crafts can be imported."));
        if (!ledger.ContainsKey("craftSeries"))
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "missing-rollups",
                "ArtisanLogbookDB.craftSeries", "The historical rollup collection is absent."));
        if (dimensions.Count == 0)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "missing-dimensions",
                "ArtisanLogbookDB.dimensions", "Dimension metadata is absent."));

        Dictionary<long, LuaTable> sessions = Index(sessionRows, "dimensions.sessions", diagnostics);
        Dictionary<long, LuaTable> characters = Index(characterRows, "dimensions.characters", diagnostics);
        Dictionary<long, LuaTable> realms = Index(realmRows, "dimensions.realms", diagnostics);
        Dictionary<long, LuaTable> recipes = Index(recipeRows, "dimensions.recipes", diagnostics);
        Dictionary<long, LuaTable> professions = Index(professionRows, "dimensions.professions", diagnostics);
        Dictionary<long, LuaTable> expansions = Index(expansionRows, "dimensions.expansions", diagnostics);
        Dictionary<long, LuaTable> requests = Index(requestRows, "requests", diagnostics);
        Dictionary<long, List<LuaTable>> reagentsByCraft = Group(reagentRows, "craftId");
        Dictionary<long, IReadOnlyList<LuaTable>> allocationsByRequest = [];
        foreach (LuaTable request in requestRows)
        {
            long? requestId = Long(request.Get("id"));
            if (requestId is null) continue;
            allocationsByRequest[requestId.Value] = Rows(request.Get("allocations"));
        }

        List<CraftObservation> crafts = [];
        List<CharacterDimension> characterDimensions = [];
        List<RecipeDimension> recipeDimensions = [];
        List<ProfessionDimension> professionDimensions = [];
        List<ItemDimension> itemDimensions = [];
        List<ExpansionDimension> canonicalExpansions = [];
        HashSet<(GameContext, string)> seenCharacters = [];
        HashSet<(GameContext, int)> seenRecipes = [];
        HashSet<(GameContext, int)> seenProfessions = [];
        HashSet<(GameContext, int)> seenItems = [];
        HashSet<(GameContext, string)> seenExpansions = [];

        foreach (IGrouping<string, LuaTable> group in GroupCraftRows(craftRows))
        {
            LuaTable row = group.OrderBy(c => Long(c.Get("id")) ?? long.MaxValue).First();
            long? localCraftId = Long(row.Get("id"));
            string location = localCraftId is null
                ? "ArtisanLogbookDB.crafts[?]"
                : $"ArtisanLogbookDB.crafts[id={localCraftId.Value}]";
            if (localCraftId is null or <= 0)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-craft-id", location,
                    "A craft has no positive local ID."));
                continue;
            }

            long? sessionId = Long(row.Get("sessionId"));
            if (sessionId is null || !sessions.TryGetValue(sessionId.Value, out LuaTable? session))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "missing-craft-session", location,
                    "The craft's session reference cannot be resolved; its game context is unknown."));
                continue;
            }

            int? projectId = Integer(session.Get("projectId"));
            if (projectId is null or <= 0)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "unknown-game-context",
                    location + ".session.projectId",
                    "The source session has no authoritative positive Blizzard projectId; the craft was not classified."));
                continue;
            }
            string? progressionTrack = session.Get("companionProgressionTrack") as string;
            if (session.ContainsKey("companionProgressionTrack") &&
                session.Get("companionProgressionTrack") is not string)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-progression-track",
                    location + ".session.companionProgressionTrack",
                    "Progression metadata must be a string when present."));
                continue;
            }
            if (progressionTrack is not null && string.IsNullOrWhiteSpace(progressionTrack))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-progression-track",
                    location + ".session.companionProgressionTrack",
                    "Progression metadata cannot be blank."));
                continue;
            }
            LuaTable? realmCandidate = Long(session.Get("realmDimensionId")) is long realmKey &&
                realms.TryGetValue(realmKey, out LuaTable? foundRealmCandidate)
                    ? foundRealmCandidate
                    : null;
            if (Integer(realmCandidate?.Get("projectId")) is int realmProjectId &&
                realmProjectId != projectId.Value)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "conflicting-game-context",
                    location + ".session.projectId",
                    "The session and its realm identify different Blizzard projects."));
                continue;
            }
            GameContext game = new((GameProject)projectId.Value, progressionTrack);

            long? characterId = Long(session.Get("characterDimensionId"));
            LuaTable? character = characterId is not null && characters.TryGetValue(characterId.Value, out LuaTable? foundCharacter)
                ? foundCharacter
                : null;
            long? realmId = Long(session.Get("realmDimensionId"));
            LuaTable? realm = realmId is not null && realms.TryGetValue(realmId.Value, out LuaTable? foundRealm)
                ? foundRealm
                : null;
            string? characterKey = character?.Get("key") as string;
            string? guid = character?.Get("guid") as string;
            if (!HasStableCharacterKey(characterKey, projectId.Value))
                characterKey = !string.IsNullOrWhiteSpace(guid)
                    ? CharacterKey(projectId.Value, realm, guid)
                    : null;
            if (!HasStableCharacterKey(characterKey, projectId.Value))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "unknown-character-identity",
                    location + ".session.characterDimensionId",
                    "A stable character key or GUID plus project/region/realm identity is required."));
                continue;
            }

            CharacterIdentity identity;
            try
            {
                identity = new CharacterIdentity(characterKey!);
            }
            catch (ArgumentException exception)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-character-identity",
                    location + ".character.key", exception.Message));
                continue;
            }

            int? recipeId = Integer(row.Get("recipeId"));
            if (recipeId is null && group.Select(c => Integer(c.Get("recipeId"))).FirstOrDefault(x => x is not null) is int recovered)
            {
                recipeId = recovered;
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Information, "recipe-recovered",
                    location + ".recipeId", $"Recovered recipe ID {recovered} from a related output record."));
            }
            if (recipeId is null)
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "unknown-recipe",
                    location + ".recipeId", "Recipe identity was not recorded and could not be recovered from a related output record."));
            LuaTable? recipe = recipeId is not null && recipes.TryGetValue(recipeId.Value, out LuaTable? foundRecipe)
                ? foundRecipe
                : null;
            int? professionId = Integer(row.Get("professionId")) ?? Integer(recipe?.Get("professionId"));
            string? expansionKey = null;
            long? expansionId = Long(recipe?.Get("expansionDimensionId"));
            LuaTable? expansion = expansionId is not null && expansions.TryGetValue(expansionId.Value, out LuaTable? foundExpansion)
                ? foundExpansion
                : null;
            if (expansion?.Get("key") is string key && key.StartsWith("skillLine:", StringComparison.Ordinal))
                expansionKey = key;

            List<CraftOutput> outputs = [];
            foreach (LuaTable outputRow in group)
            {
                int? itemId = Integer(outputRow.Get("outputItemId"));
                long? quantity = Long(outputRow.Get("outputQuantity"));
                if (itemId is null && quantity is null) continue;
                if (itemId is null or <= 0 || quantity is null or <= 0)
                {
                    diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "partial-output",
                        location + ".output", "Output item and positive quantity were not both observed; the incomplete output was not promoted."));
                    continue;
                }
                outputs.Add(new(itemId.Value, Integer(outputRow.Get("outputQuality")), quantity.Value));
            }
            IReadOnlyList<CraftOutput>? observedOutputs = outputs.Count > 0
                ? FoldOutputs(outputs)
                : group.Any(c => Boolean(c.Get("companionOutputsObserved")) == true)
                    ? []
                    : null;

            Dictionary<int, (long? Allocated, decimal? Returned, bool AllocatedSeen, bool ReturnedSeen)> reagentFacts = [];
            foreach (LuaTable groupCraft in group)
            {
                long? sourceCraftId = Long(groupCraft.Get("id"));
                if (sourceCraftId is not null && reagentsByCraft.TryGetValue(sourceCraftId.Value, out List<LuaTable>? sourceReagents))
                {
                    foreach (LuaTable reagent in sourceReagents)
                        AddReagent(reagentFacts, reagent, "allocatedQuantity", "returnedQuantity", diagnostics, location);
                }
                else if (Long(groupCraft.Get("requestId")) is long linkedRequestId &&
                    requests.TryGetValue(linkedRequestId, out LuaTable? linkedRequest) &&
                    allocationsByRequest.TryGetValue(linkedRequestId, out IReadOnlyList<LuaTable>? allocations))
                {
                    foreach (LuaTable allocation in allocations)
                    {
                        LuaTable synthetic = new()
                        {
                            ["itemId"] = allocation.Get("itemId"),
                            ["allocatedQuantity"] = allocation.Get("allocatedQuantity")
                        };
                        AddReagent(reagentFacts, synthetic, "allocatedQuantity", "returnedQuantity", diagnostics, location);
                    }
                    _ = linkedRequest;
                }
            }
            bool? inputsComplete = Boolean(row.Get("inputComplete")) ??
                Boolean(row.Get("companionInputsComplete"));
            bool? companionEvidenceSpecified = Boolean(row.Get("companionResourcefulnessEvidenceSpecified"));
            string? resourcefulnessEvidence = companionEvidenceSpecified is bool evidenceSpecified
                ? evidenceSpecified ? row.Get("companionResourcefulnessEvidence") as string : null
                : row.Get("companionResourcefulnessEvidence") as string ?? row.Get("outcomeSource") as string;
            bool? resourcefulnessComplete = Boolean(row.Get("resourcefulnessComplete")) ??
                Boolean(row.Get("companionResourcefulnessComplete")) ??
                (resourcefulnessEvidence == "partial" ? false : null);
            bool hasObservedEmptyAllocations = group.Any(groupCraft =>
                Long(groupCraft.Get("requestId")) is long linkedRequestId &&
                requests.TryGetValue(linkedRequestId, out LuaTable? linkedRequest) &&
                linkedRequest.Get("allocations") is LuaTable allocationTable &&
                allocationTable.Count == 0);
            IReadOnlyList<CraftReagent>? observedReagents = reagentFacts.Count > 0
                ? reagentFacts.OrderBy(x => x.Key).Select(x => new CraftReagent(
                    x.Key,
                    x.Value.AllocatedSeen ? x.Value.Allocated : null,
                    x.Value.ReturnedSeen ? x.Value.Returned : null)).ToArray()
                : inputsComplete == true ||
                  resourcefulnessComplete == true &&
                  Boolean(row.Get("hasResourcefulnessProc")) == false ||
                  hasObservedEmptyAllocations
                    ? []
                    : null;

            string sourceId = row.Get("companionProvenanceSource") as string ??
                SourceId(projectId.Value, identity.Key, sessionId.Value, session);
            if (crafts.Count == 0)
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "legacy-identity-lineage",
                    "ArtisanLogbookDB", "This ledger has no durable source-lineage identifier. Local craft IDs provide replay stability only; independently diverged cloned ledgers may collide."));

            DateTimeOffset recordedAt;
            double? timestamp = Number(row.Get("timestamp"));
            if (timestamp is null || !TryTimestamp(timestamp.Value, out recordedAt))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-craft-timestamp",
                    location + ".timestamp", "A finite Unix timestamp in the supported DateTimeOffset range is required."));
                continue;
            }

            List<CraftReagent> normalizedReagents = observedReagents?.ToList() ?? [];
            foreach (CraftReagent reagent in normalizedReagents)
                AddItemDimension(game, reagent.ItemId, itemRows, itemDimensions, seenItems);
            foreach (CraftOutput output in observedOutputs ?? [])
                AddItemDimension(game, output.ItemId, itemRows, itemDimensions, seenItems);
            if (recipeId is > 0)
                AddRecipeDimension(game, recipeId.Value, recipe, professionId, expansionKey,
                    recipeDimensions, seenRecipes);
            if (professionId is > 0)
                AddProfessionDimension(game, professionId.Value, professionRows,
                    professionDimensions, seenProfessions);
            if (expansionKey is not null && seenExpansions.Add((game, expansionKey)))
                canonicalExpansions.Add(new(game, expansionKey, expansion?.Get("name") as string));
            if (seenCharacters.Add((game, identity.Key)))
                characterDimensions.Add(new(game, identity, character?.Get("name") as string,
                    character?.Get("classFile") as string));

            int? concentrationSpent = Integer(row.Get("concentrationSpent"));
            int? concentrationCurrencyId = Integer(row.Get("concentrationCurrencyId"));
            int? ingenuityRefund = Integer(row.Get("ingenuityRefund"));
            int? multicraftBonus = Integer(row.Get("multicraftBonus"));
            bool? resourcefulnessProc = Boolean(row.Get("hasResourcefulnessProc"));
            string? companionOrigin = row.Get("companionCraftOrigin") as string;
            string? companionObservation = row.Get("companionCraftObservation") as string;
            if (row.ContainsKey("companionCraftOrigin") && row.Get("companionCraftOrigin") is not string ||
                row.ContainsKey("companionCraftObservation") && row.Get("companionCraftObservation") is not string)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-companion-identity",
                    location, "Companion craft identity metadata must use strings."));
                continue;
            }
            if ((companionOrigin is null) != (companionObservation is null) ||
                companionOrigin is not null && string.IsNullOrWhiteSpace(companionOrigin) ||
                companionObservation is not null && string.IsNullOrWhiteSpace(companionObservation))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-companion-identity",
                    location, "Companion craft identity metadata must contain both nonblank origin and observation values."));
                continue;
            }
            CraftIdentity craftIdentity = companionOrigin is not null
                ? new(companionOrigin, companionObservation!)
                : new(sourceId, localCraftId.Value.ToString(CultureInfo.InvariantCulture));
            if (row.ContainsKey("companionProvenanceSource") &&
                (row.Get("companionProvenanceSource") is not string companionSourceId ||
                 string.IsNullOrWhiteSpace(companionSourceId)))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-source-provenance",
                    location + ".companionProvenanceSource", "Source ID metadata must be a nonblank string."));
                continue;
            }
            if (row.ContainsKey("companionSourceCraft") &&
                LongString(row.Get("companionSourceCraft")) is null)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-source-provenance",
                    location + ".companionSourceCraft", "Original local craft ID metadata must be a safe integer string."));
                continue;
            }
            long? operationId = Long(row.Get("gameOperationId"));
            long? requestId = Long(row.Get("requestId")) ??
                LongString(row.Get("companionSourceRequest"));
            if (row.Get("outcomeSource") is string outcomeSource &&
                outcomeSource is not ("native" or "partial" or "unverified"))
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-resourcefulness-evidence",
                    location + ".outcomeSource", $"Unsupported outcomeSource value '{outcomeSource}'."));
                continue;
            }
            long? provenanceCraftId = Boolean(row.Get("companionSourceCraftSpecified")) is bool craftIdSpecified
                ? craftIdSpecified ? LongString(row.Get("companionSourceCraft")) : null
                : LongString(row.Get("companionSourceCraft")) ?? localCraftId;
            if (row.ContainsKey("companionSourceSession") &&
                row.Get("companionSourceSession") is not string)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-source-provenance",
                    location + ".companionSourceSession", "Original session metadata must be a string."));
                continue;
            }
            string? sourceSessionId = Boolean(row.Get("companionSourceSessionSpecified")) is bool sessionSpecified
                ? sessionSpecified ? row.Get("companionSourceSession") as string : null
                : row.Get("companionSourceSession") as string ??
                  session.Get("key") as string ??
                  sessionId.Value.ToString(CultureInfo.InvariantCulture);
            CraftProvenance? provenance = Boolean(row.Get("companionProvenancePresent")) == false
                ? null
                : new CraftProvenance(sourceId, provenanceCraftId, operationId, requestId, sourceSessionId,
                    resourcefulnessEvidence);
            crafts.Add(new CraftObservation(
                craftIdentity,
                game,
                recordedAt,
                recipeId,
                identity,
                professionId,
                expansionKey,
                concentrationSpent,
                ingenuityRefund,
                concentrationCurrencyId,
                Boolean(row.Get("hasIngenuityProc")),
                resourcefulnessProc,
                multicraftBonus,
                observedReagents,
                observedOutputs,
                provenance,
                inputsComplete,
                resourcefulnessComplete));
        }

        long aggregateOnlyCount = CountAggregateOnly(ledger, sessions, crafts);
        if (aggregateOnlyCount > 0)
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "aggregate-only-history",
                "ArtisanLogbookDB.craftSeries",
                $"{aggregateOnlyCount} craft(s) are represented by historical rollups without individual detail. No craft observations were reconstructed from those totals."));
        }
        CraftDimensions canonicalDimensions = new(
            characterDimensions, recipeDimensions, professionDimensions, itemDimensions, canonicalExpansions);
        CraftHistory history = new(crafts, canonicalDimensions);
        foreach (HistoryValidationError error in CraftHistoryValidator.Validate(history))
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-canonical-history",
                error.Identity is null ? error.Field : $"craft[{error.Identity.Observation}].{error.Field}",
                error.Message));
        return new(schemaVersion, history, diagnostics,
            new(aggregateOnlyCount, aggregateOnlyCount > 0));
    }

    private static IReadOnlyList<CraftOutput> FoldOutputs(IEnumerable<CraftOutput> outputs) =>
        outputs.GroupBy(x => (x.ItemId, x.Quality))
            .Select(g => new CraftOutput(g.Key.ItemId, g.Key.Quality, g.Sum(x => x.Quantity)))
            .OrderBy(x => x.ItemId).ThenBy(x => x.Quality).ToArray();

    private static void AddReagent(
        IDictionary<int, (long? Allocated, decimal? Returned, bool AllocatedSeen, bool ReturnedSeen)> facts,
        LuaTable row,
        string allocationField,
        string returnField,
        ICollection<SavedVariablesDiagnostic> diagnostics,
        string location)
    {
        int? itemId = Integer(row.Get("itemId"));
        if (itemId is null or <= 0)
        {
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "invalid-reagent-item",
                location + ".reagents", "A reagent fact with no positive item ID was omitted."));
            return;
        }
        bool existed = facts.TryGetValue(itemId.Value, out var current);
        if (!existed) current = (null, null, true, true);
        long? allocation = Long(row.Get(allocationField));
        decimal? returned = Decimal(row.Get(returnField));
        if (row.ContainsKey(allocationField) && allocation is null)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "invalid-reagent-allocation",
                location + ".reagents.allocatedQuantity", "An invalid allocation value was left unknown."));
        if (row.ContainsKey(returnField) && returned is null)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Warning, "invalid-reagent-return",
                location + ".reagents.returnedQuantity", "An invalid returned quantity was left unknown."));
        bool allocationObserved = row.ContainsKey(allocationField) && allocation is not null;
        bool returnObserved = row.ContainsKey(returnField) && returned is not null;
        current.AllocatedSeen &= allocationObserved;
        current.ReturnedSeen &= returnObserved;
        current.Allocated = current.AllocatedSeen
            ? checked((current.Allocated ?? 0) + allocation!.Value)
            : null;
        current.Returned = current.ReturnedSeen
            ? checked((current.Returned ?? 0) + returned!.Value)
            : null;
        facts[itemId.Value] = current;
    }

    private static void AddItemDimension(
        GameContext game,
        int itemId,
        IReadOnlyList<LuaTable> source,
        ICollection<ItemDimension> result,
        ISet<(GameContext, int)> seen)
    {
        if (seen.Add((game, itemId)))
            result.Add(new(game, itemId, FindNatural(source, itemId)?.Get("name") as string));
    }

    private static void AddRecipeDimension(
        GameContext game,
        int recipeId,
        LuaTable? recipe,
        int? professionId,
        string? expansionKey,
        ICollection<RecipeDimension> result,
        ISet<(GameContext, int)> seen)
    {
        if (seen.Add((game, recipeId)))
            result.Add(new(game, recipeId, recipe?.Get("name") as string, professionId,
                expansionKey, Integer(recipe?.Get("maxQuality"))));
    }

    private static void AddProfessionDimension(
        GameContext game,
        int professionId,
        IReadOnlyList<LuaTable> source,
        ICollection<ProfessionDimension> result,
        ISet<(GameContext, int)> seen)
    {
        if (seen.Add((game, professionId)))
        {
            LuaTable? row = FindNatural(source, professionId);
            result.Add(new(game, professionId, row?.Get("name") as string, Integer(row?.Get("parentId"))));
        }
    }

    private static long CountAggregateOnly(
        LuaTable ledger,
        IReadOnlyDictionary<long, LuaTable> sessions,
        IReadOnlyList<CraftObservation> crafts)
    {
        long detailOnly = 0;
        Dictionary<(double Day, long CharacterId, int? RecipeId), long> detailCounts = [];
        foreach (LuaTable craft in Rows(ledger.Get("crafts")))
        {
            long? sessionId = Long(craft.Get("sessionId"));
            long? characterId = sessionId is not null && sessions.TryGetValue(sessionId.Value, out LuaTable? session)
                ? Long(session.Get("characterDimensionId"))
                : null;
            double? timestamp = Number(craft.Get("timestamp"));
            if (timestamp is null) continue;
            double day = Math.Floor(timestamp.Value / 86400) * 86400;
            var key = (day, characterId ?? 0, Integer(craft.Get("recipeId")));
            detailCounts[key] = detailCounts.GetValueOrDefault(key) + 1;
        }
        foreach (LuaTable row in Rows(ledger.Get("craftSeries")))
        {
            double? day = Number(row.Get("bucketStart"));
            long? characterId = Long(row.Get("characterDimensionId"));
            int? recipeId = Integer(row.Get("recipeId"));
            long? count = Long(row.Get("craftCount"));
            if (day is null || count is null) continue;
            var key = (day.Value, characterId ?? 0, recipeId);
            long observed = detailCounts.GetValueOrDefault(key);
            detailOnly += Math.Max(0, count.Value - observed);
        }
        _ = crafts;
        return detailOnly;
    }

    private static IEnumerable<IGrouping<string, LuaTable>> GroupCraftRows(IEnumerable<LuaTable> rows) =>
        rows.GroupBy(row =>
        {
            string? group = row.Get("companionOutputGroup") as string;
            return string.IsNullOrWhiteSpace(group) ? $"craft:{Long(row.Get("id"))}" :
                $"session:{Long(row.Get("sessionId"))}:group:{group}";
        }, StringComparer.Ordinal);

    private static string SourceId(int projectId, string characterKey, long sessionId, LuaTable session)
    {
        string sessionKey = session.Get("key") as string ?? sessionId.ToString(CultureInfo.InvariantCulture);
        return $"legacy-ledger:{projectId}:{characterKey}:{sessionKey}";
    }

    private static string? CharacterKey(int projectId, LuaTable? realm, string guid)
    {
        int? regionId = Integer(realm?.Get("regionId"));
        int? gameRealmId = Integer(realm?.Get("gameRealmId"));
        if (regionId is null or <= 0 || gameRealmId is null or <= 0) return null;
        return $"project:{projectId}:region:{regionId}:realm:{gameRealmId}:guid:{guid}";
    }

    private static bool HasStableCharacterKey(string? key, int projectId)
    {
        if (key is null) return false;
        string prefix = $"project:{projectId}:region:";
        if (!key.StartsWith(prefix, StringComparison.Ordinal)) return false;
        string[] parts = key[prefix.Length..].Split(':');
        return parts.Length >= 4 &&
            int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out int region) && region > 0 &&
            parts[1] == "realm" &&
            int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out int realm) && realm > 0 &&
            parts[3] == "guid" && parts.Length >= 5 &&
            !string.IsNullOrWhiteSpace(string.Join(':', parts.Skip(4)));
    }

    private static bool TryTimestamp(double timestamp, out DateTimeOffset result)
    {
        try
        {
            result = DateTimeOffset.FromUnixTimeMilliseconds(checked((long)Math.Round(timestamp * 1000)));
            return true;
        }
        catch (ArgumentOutOfRangeException)
        {
            result = default;
            return false;
        }
        catch (OverflowException)
        {
            result = default;
            return false;
        }
    }

    private static LuaTable? FindNatural(IEnumerable<LuaTable> rows, int id) =>
        rows.FirstOrDefault(row => Integer(row.Get("id")) == id);

    private static Dictionary<long, LuaTable> Index(
        IEnumerable<LuaTable> rows,
        string collection,
        ICollection<SavedVariablesDiagnostic> diagnostics)
    {
        Dictionary<long, LuaTable> result = [];
        HashSet<long> duplicates = [];
        foreach (LuaTable row in rows)
        {
            long? id = Long(row.Get("id"));
            if (id is null)
            {
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-dimension-id",
                    $"ArtisanLogbookDB.{collection}", "A dimension row is missing a safe integer ID."));
                continue;
            }
            if (duplicates.Contains(id.Value)) continue;
            if (!result.TryAdd(id.Value, row))
            {
                result.Remove(id.Value);
                duplicates.Add(id.Value);
                diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "duplicate-dimension-id",
                    $"ArtisanLogbookDB.{collection}[id={id.Value}]",
                    "The local ID is duplicated; references to it are ambiguous."));
            }
        }
        return result;
    }

    private static Dictionary<long, List<LuaTable>> Group(IEnumerable<LuaTable> rows, string key) =>
        rows.Where(row => Long(row.Get(key)) is not null)
            .GroupBy(row => Long(row.Get(key))!.Value)
            .ToDictionary(group => group.Key, group => group.ToList());

    private static IReadOnlyList<LuaTable> Rows(object? value) =>
        value is LuaTable table
            ? table.OrderBy(entry => entry.Key, LuaKeyComparer.Instance)
                .Where(entry => entry.Value is LuaTable)
                .Select(entry => (LuaTable)entry.Value!).ToArray()
            : [];

    private static void CheckCollection(
        LuaTable parent,
        string name,
        ICollection<SavedVariablesDiagnostic> diagnostics,
        string prefix = "ArtisanLogbookDB")
    {
        if (parent.ContainsKey(name) && parent.Get(name) is not LuaTable)
            diagnostics.Add(new(SavedVariablesDiagnosticSeverity.Error, "invalid-collection",
                $"{prefix}.{name}", "A saved collection must be a table when present."));
    }

    private static long? Long(object? value)
    {
        double? number = Number(value);
        return number is >= -9_007_199_254_740_991d and <= 9_007_199_254_740_991d &&
            Math.Truncate(number.Value) == number.Value
            ? (long)number.Value
            : null;
    }

    private static long? LongString(object? value) =>
        value is string text && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out long result)
            ? result
            : null;

    private static int? Integer(object? value)
    {
        long? number = Long(value);
        return number is >= int.MinValue and <= int.MaxValue ? (int)number.Value : null;
    }

    private static decimal? Decimal(object? value)
    {
        double? number = Number(value);
        return number is not null && decimal.TryParse(number.Value.ToString("R", CultureInfo.InvariantCulture),
            NumberStyles.Float, CultureInfo.InvariantCulture, out decimal result)
            ? result
            : null;
    }

    private static double? Number(object? value) => value switch
    {
        double number when double.IsFinite(number) => number,
        int integer => integer,
        long integer => integer,
        _ => null
    };

    private static bool? Boolean(object? value) => value is bool boolean ? boolean : null;

    private static SavedVariablesImportResult Failure(IReadOnlyList<SavedVariablesDiagnostic> diagnostics) =>
        new(null, null, diagnostics, new(0, false));
}
