namespace ArtisanLogbook.History;

/// <summary>
/// Structural validation of the canonical history. Dimension metadata may be
/// partial, so the absence of a display-name entry is not a missing craft fact.
/// </summary>
public static class CraftHistoryValidator
{
    public static IReadOnlyList<HistoryValidationError> Validate(CraftHistory history)
    {
        ArgumentNullException.ThrowIfNull(history);
        List<HistoryValidationError> errors = [.. HistoryValidator.Validate(history.Crafts)];
        CraftDimensions dimensions = history.Dimensions;

        void CheckUnique<TKey>(IEnumerable<TKey> keys, string category) where TKey : notnull
        {
            HashSet<TKey> seen = [];
            foreach (TKey key in keys)
                if (!seen.Add(key))
                    errors.Add(new(null, category, $"Duplicate {category} identity: {key}."));
        }

        CheckUnique(dimensions.Characters.Select(x => x.Identity), "CharacterDimension");
        CheckUnique(dimensions.Recipes.Select(x => x.Id), "RecipeDimension");
        CheckUnique(dimensions.Items.Select(x => x.Id), "ItemDimension");
        CheckUnique(dimensions.Professions.Select(x => x.Id), "ProfessionDimension");
        CheckUnique(dimensions.Expansions.Select(x => x.Id), "ExpansionDimension");

        foreach (RecipeDimension recipe in dimensions.Recipes)
        {
            if (recipe.Id <= 0 || recipe.ProfessionId is <= 0)
                errors.Add(new(null, "RecipeDimension", "Known recipe and profession IDs must be positive."));
        }
        foreach (ItemDimension item in dimensions.Items)
            if (item.Id <= 0)
                errors.Add(new(null, "ItemDimension", "Item ID must be positive."));
        foreach (ProfessionDimension profession in dimensions.Professions)
            if (profession.Id <= 0 || profession.ParentId is <= 0)
                errors.Add(new(null, "ProfessionDimension", "Known skill-line IDs must be positive."));
        foreach (ExpansionDimension expansion in dimensions.Expansions)
            if (expansion.Id < 0)
                errors.Add(new(null, "ExpansionDimension", "Expansion ID cannot be negative."));

        return errors;
    }
}
