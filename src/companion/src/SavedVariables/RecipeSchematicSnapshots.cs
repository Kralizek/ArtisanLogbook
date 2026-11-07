using ArtisanLogbook.History;

namespace ArtisanLogbook.SavedVariables;

internal static class RecipeSchematicSnapshots
{
    private static readonly string[] RequestFields =
    [
        "id", "sessionId", "recipeId", "timestamp", "fixedReagents", "requirements",
        "grossRequirementsComplete", "inputComplete"
    ];
    private static readonly string[] CraftFields =
    [
        "id", "sessionId", "requestId", "recipeId", "timestamp", "companionRecordedAt",
        "reagentRequirements", "requirementObservation", "grossRequirementsComplete"
    ];

    public static CraftRecipeSchematicEvidence? Capture(
        LuaTable craft, LuaTable? request, string sourceId)
    {
        LuaTable snapshot = new();
        if (request is not null &&
            (request.ContainsKey("fixedReagents") || request.ContainsKey("requirements")))
            snapshot["request"] = Select(request, RequestFields);
        if (craft.ContainsKey("reagentRequirements") || snapshot.Count > 0)
            snapshot["craft"] = Select(craft, CraftFields);
        return snapshot.Count == 0 ? null : new(sourceId, LuaDataParser.Serialize(new(
            new Dictionary<string, object?> { ["CraftRecipeSchematicEvidence"] = snapshot }, null)));
    }

    public static bool TryRead(string payload, out LuaTable snapshot)
    {
        snapshot = new();
        try
        {
            LuaDocument document = LuaDataParser.Parse(payload);
            if (document.Assignments.Count != 1 || document.ReturnedValue is not null ||
                document.Assignments.GetValueOrDefault("CraftRecipeSchematicEvidence") is not LuaTable value ||
                value.Get("craft") is not LuaTable craft ||
                value.Keys.Any(key => key is not string name || name is not ("request" or "craft")) ||
                craft.Keys.Any(key => key is not string name || !CraftFields.Contains(name)) ||
                value.Get("request") is object requestValue && (requestValue is not LuaTable request ||
                    request.Keys.Any(key => key is not string name || !RequestFields.Contains(name))))
                return false;
            if (!craft.ContainsKey("reagentRequirements") &&
                (value.Get("request") is not LuaTable sourceRequest ||
                    !sourceRequest.ContainsKey("requirements") && !sourceRequest.ContainsKey("fixedReagents")))
                return false;
            snapshot = value;
            return true;
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            return false;
        }
    }

    private static LuaTable Select(LuaTable source, string[] fields)
    {
        LuaTable result = new();
        foreach (string field in fields)
            if (source.ContainsKey(field)) result[field] = source.Get(field);
        return result;
    }
}
