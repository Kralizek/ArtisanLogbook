using ArtisanLogbook.History;

namespace ArtisanLogbook.SavedVariables;

/// <summary>Assigns each craft reagent the slot role its own craft's recorded evidence identifies.</summary>
internal static class CraftReagentRoles
{
    private static readonly Dictionary<string, RecipeReagentType> Names = new(StringComparer.Ordinal)
    {
        ["basic"] = RecipeReagentType.Basic,
        ["modifying"] = RecipeReagentType.Modifying,
        ["finishing"] = RecipeReagentType.Finishing,
        ["automatic"] = RecipeReagentType.Automatic,
    };

    public static string Name(RecipeReagentType role) => Names.Single(entry => entry.Value == role).Key;

    public static RecipeReagentType? Parse(object? value) =>
        value is string name && Names.TryGetValue(name, out RecipeReagentType role) ? role : null;

    /// <summary>
    /// Explicitly recorded roles win. Otherwise schematic requirement candidates and fixed reagents are basic,
    /// and submitted finishing selections are finishing. An item identified as both stays unknown.
    /// </summary>
    public static CraftObservation Assign(CraftObservation craft, IReadOnlyDictionary<int, RecipeReagentType?> recorded)
    {
        if (craft.Reagents is not { Count: > 0 } reagents) return craft;
        HashSet<int> basic = [];
        HashSet<int> finishing = [];
        foreach (CraftRecipeSchematicEvidence evidence in craft.RecipeSchematicEvidence ?? [])
            if (RecipeSchematicSnapshots.TryRead(evidence.Payload, out LuaTable snapshot))
                CollectSchematic(snapshot, basic);
        foreach (CraftConfigurationEvidence evidence in craft.ConfigurationEvidence ?? [])
            CollectFinishing(evidence.Payload, finishing);
        return craft with
        {
            Reagents = reagents.Select(reagent => reagent.Role is not null ? reagent : reagent with
            {
                Role = recorded.TryGetValue(reagent.ItemId, out RecipeReagentType? explicitRole)
                    ? explicitRole
                    : (basic.Contains(reagent.ItemId), finishing.Contains(reagent.ItemId)) switch
                    {
                        (true, false) => RecipeReagentType.Basic,
                        (false, true) => RecipeReagentType.Finishing,
                        _ => null
                    }
            }).ToArray()
        };
    }

    private static void CollectSchematic(LuaTable snapshot, ISet<int> basic)
    {
        if (snapshot.Get("craft") is LuaTable craft)
            CollectCandidates(craft.Get("reagentRequirements"), basic);
        if (snapshot.Get("request") is not LuaTable request) return;
        CollectCandidates(request.Get("requirements"), basic);
        foreach (LuaTable fixedReagent in Rows(request.Get("fixedReagents")))
            if (Id(fixedReagent.Get("itemId")) is int itemId) basic.Add(itemId);
    }

    private static void CollectCandidates(object? requirements, ISet<int> basic)
    {
        foreach (LuaTable requirement in Rows(requirements))
        {
            if (requirement.Get("source") is string source && source != "schematic") continue;
            if (requirement.Get("candidateItemIDs") is not LuaTable candidates) continue;
            foreach (object? value in candidates.Values)
                if (Id(value) is int itemId) basic.Add(itemId);
        }
    }

    private static void CollectFinishing(string payload, ISet<int> finishing)
    {
        try
        {
            if (!LuaDataParser.Parse(payload).Assignments.TryGetValue("CraftConfigurationEvidence", out object? root) ||
                root is not LuaTable snapshot || snapshot.Get("conditions") is not LuaTable conditions)
                return;
            foreach (LuaTable reagent in Rows(conditions.Get("finishingReagents")))
                if (Id(reagent.Get("itemID")) is int itemId) finishing.Add(itemId);
        }
        catch (FormatException)
        {
            // Malformed evidence identifies no role.
        }
    }

    private static IEnumerable<LuaTable> Rows(object? value) =>
        value is LuaTable table ? table.Values.OfType<LuaTable>() : [];

    private static int? Id(object? value) =>
        value is double number && number > 0 && number <= int.MaxValue && number % 1 == 0 ? (int)number : null;
}
