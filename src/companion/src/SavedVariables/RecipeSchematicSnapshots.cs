using System.Globalization;

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
                !HasOnlyFields(craft, CraftFields) ||
                value.Get("request") is object requestValue &&
                    (requestValue is not LuaTable request || !HasOnlyFields(request, RequestFields)))
                return false;

            LuaTable? sourceRequest = value.Get("request") as LuaTable;
            if (!ValidCraft(craft) || sourceRequest is not null && !ValidRequest(sourceRequest))
                return false;
            if (sourceRequest is not null &&
                (!SameOptionalInteger(sourceRequest, craft, "sessionId") ||
                 !SameOptionalInteger(sourceRequest, craft, "recipeId") ||
                 !PositiveInteger(craft.Get("requestId")) ||
                 sourceRequest.Get("id") is not null &&
                    !SameInteger(sourceRequest.Get("id"), craft.Get("requestId"))))
                return false;

            snapshot = value;
            return true;
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException or OverflowException)
        {
            return false;
        }
    }

    public static bool MatchesObservation(
        LuaTable snapshot,
        int? recipeId,
        DateTimeOffset recordedAt,
        long? sourceCraftId,
        long? sourceSessionId,
        long? sourceRequestId)
    {
        LuaTable craft = (LuaTable)snapshot.Get("craft")!;
        if (craft.Get("recipeId") is object craftRecipe &&
            (!PositiveInteger(craftRecipe) || recipeId is int expectedRecipe &&
                !SameInteger(craftRecipe, expectedRecipe)))
            return false;
        if (snapshot.Get("request") is LuaTable sourceRequest &&
            sourceRequest.Get("recipeId") is object requestRecipe &&
            (!PositiveInteger(requestRecipe) || recipeId is int expectedRequestRecipe &&
                !SameInteger(requestRecipe, expectedRequestRecipe)))
            return false;
        if (sourceSessionId is long expectedSessionId &&
            !SameInteger(craft.Get("sessionId"), expectedSessionId))
            return false;
        if (!TryTimestamp(craft.Get("timestamp"), out DateTimeOffset craftTimestamp) ||
            craftTimestamp.ToUnixTimeSeconds() != recordedAt.ToUnixTimeSeconds())
            return false;
        if (craft.Get("companionRecordedAt") is string preciseTimestamp &&
            (!DateTimeOffset.TryParseExact(preciseTimestamp, "O", CultureInfo.InvariantCulture,
                 DateTimeStyles.None, out DateTimeOffset parsedPrecise) || parsedPrecise != recordedAt))
            return false;
        if (sourceCraftId is long expectedCraftId &&
            !SameInteger(craft.Get("id"), expectedCraftId))
            return false;
        if (sourceRequestId is long expectedRequestId &&
            !SameInteger(craft.Get("requestId"), expectedRequestId))
            return false;
        if (snapshot.Get("request") is LuaTable request &&
            sourceRequestId is long expectedSnapshotRequestId &&
            !SameInteger(request.Get("id"), expectedSnapshotRequestId))
            return false;
        return true;
    }

    private static bool ValidRequest(LuaTable request) =>
        PositiveInteger(request.Get("id")) &&
        PositiveInteger(request.Get("sessionId")) &&
        HasPositiveIntegerWhenPresent(request, "recipeId") &&
        HasTimestampWhenPresent(request, "timestamp") &&
        HasBooleanWhenPresent(request, "grossRequirementsComplete") &&
        HasBooleanWhenPresent(request, "inputComplete") &&
        ValidRequirementCollection(request, "fixedReagents", ValidateFixedReagent) &&
        ValidRequirementCollection(request, "requirements", ValidateRequirement);

    private static bool ValidCraft(LuaTable craft) =>
        PositiveInteger(craft.Get("id")) &&
        PositiveInteger(craft.Get("sessionId")) &&
        HasPositiveIntegerWhenPresent(craft, "requestId") &&
        HasPositiveIntegerWhenPresent(craft, "recipeId") &&
        HasTimestamp(craft, "timestamp") &&
        HasBooleanWhenPresent(craft, "grossRequirementsComplete") &&
        HasStringWhenPresent(craft, "companionRecordedAt") &&
        HasStringWhenPresent(craft, "requirementObservation") &&
        DenseRowsWhenPresent(craft, "reagentRequirements", ValidateRequirement);

    private static bool ValidRequirementCollection(
        LuaTable parent, string field, Func<LuaTable, bool> validate) =>
        DenseRowsWhenPresent(parent, field, validate);

    private static bool DenseRowsWhenPresent(LuaTable parent, string field, Func<LuaTable, bool> validate)
    {
        if (!parent.ContainsKey(field))
            return true;
        if (parent.Get(field) is not LuaTable rows || !IsDense(rows))
            return false;
        return rows.Values.OfType<LuaTable>().Count() == rows.Count &&
            rows.Values.OfType<LuaTable>().All(validate);
    }

    private static bool ValidateFixedReagent(LuaTable reagent) =>
        HasPositiveIntegerWhenPresent(reagent, "dataSlotIndex") &&
        HasPositiveIntegerWhenPresent(reagent, "itemId") &&
        HasPositiveIntegerWhenPresent(reagent, "requiredQuantity");

    private static bool ValidateRequirement(LuaTable requirement)
    {
        if (requirement.Get("source") is not string source || source is not ("schematic" or "unknown") ||
            !HasPositiveIntegerWhenPresent(requirement, "dataSlotIndex") ||
            !HasPositiveIntegerWhenPresent(requirement, "requiredQuantity") ||
            !HasNonnegativeIntegerWhenPresent(requirement, "slotIndex") ||
            !HasNonnegativeIntegerWhenPresent(requirement, "dataSlotType"))
            return false;

        if (!requirement.ContainsKey("candidateItemIDs"))
            return source != "schematic";
        if (requirement.Get("candidateItemIDs") is not LuaTable candidates || !IsDense(candidates))
            return false;
        int[] itemIds = candidates.Values.Select(ToPositiveInt).ToArray();
        return itemIds.All(itemId => itemId > 0) && itemIds.Distinct().Count() == itemIds.Length &&
            (source != "schematic" || itemIds.Length > 0);
    }

    private static bool HasOnlyFields(LuaTable table, IEnumerable<string> allowed) =>
        table.Keys.All(key => key is string name && allowed.Contains(name, StringComparer.Ordinal));

    private static bool HasPositiveIntegerWhenPresent(LuaTable table, string field) =>
        !table.ContainsKey(field) || PositiveInteger(table.Get(field));

    private static bool HasTimestampWhenPresent(LuaTable table, string field) =>
        !table.ContainsKey(field) || TryTimestamp(table.Get(field), out _);

    private static bool HasTimestamp(LuaTable table, string field) =>
        table.ContainsKey(field) && TryTimestamp(table.Get(field), out _);

    private static bool HasNonnegativeIntegerWhenPresent(LuaTable table, string field) =>
        !table.ContainsKey(field) || PositiveInteger(table.Get(field)) || IsZero(table.Get(field));

    private static bool IsZero(object? value) => value switch
    {
        double number => number == 0,
        int number => number == 0,
        long number => number == 0,
        _ => false
    };

    private static bool HasBooleanWhenPresent(LuaTable table, string field) =>
        !table.ContainsKey(field) || table.Get(field) is bool;

    private static bool HasStringWhenPresent(LuaTable table, string field) =>
        !table.ContainsKey(field) || table.Get(field) is string;

    private static bool SameOptionalInteger(LuaTable first, LuaTable second, string field) =>
        first.Get(field) is null || second.Get(field) is null || SameInteger(first.Get(field), second.Get(field));

    private static bool SameInteger(object? first, object? second) =>
        ToPositiveInt64(first) is long left && ToPositiveInt64(second) is long right && left == right;

    private static bool PositiveInteger(object? value) => ToPositiveInt64(value) is > 0;

    private static long? ToPositiveInt64(object? value)
    {
        double number = value switch
        {
            double actual => actual,
            int actual => actual,
            long actual => actual,
            _ => double.NaN
        };
        return double.IsFinite(number) && number is > 0 and <= 9_007_199_254_740_991d &&
            Math.Truncate(number) == number
                ? (long)number
                : null;
    }

    private static int ToPositiveInt(object? value) =>
        ToPositiveInt64(value) is long integer && integer <= int.MaxValue ? (int)integer : 0;

    private static bool IsDense(LuaTable table)
    {
        for (int index = 1; index <= table.Count; index++)
            if (!table.ContainsKey((double)index))
                return false;
        return table.Keys.All(key => key is double number &&
            double.IsFinite(number) && number >= 1 && Math.Truncate(number) == number);
    }

    private static bool TryTimestamp(object? value, out DateTimeOffset timestamp)
    {
        double seconds = value switch
        {
            double actual => actual,
            int actual => actual,
            long actual => actual,
            _ => double.NaN
        };
        try
        {
            timestamp = DateTimeOffset.FromUnixTimeMilliseconds(checked((long)Math.Round(seconds * 1000)));
            return double.IsFinite(seconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            timestamp = default;
            return false;
        }
        catch (OverflowException)
        {
            timestamp = default;
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
