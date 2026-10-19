namespace ArtisanLogbook.History;

public sealed record DimensionConflict(string Dimension, string Key, string Message);

public sealed record CraftHistoryMergeResult(
    CraftHistory? History,
    IReadOnlyList<HistoryConflict> CraftConflicts,
    IReadOnlyList<DimensionConflict> DimensionConflicts)
{
    public bool IsSuccessful => History is not null && CraftConflicts.Count == 0 && DimensionConflicts.Count == 0;
}

/// <summary>Reconciles craft-level history and optional dimension metadata, never addon aggregate rows.</summary>
public static class CraftHistoryReconciler
{
    public static CraftHistoryMergeResult Merge(CraftHistory left, CraftHistory right)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);
        HistoryMergeResult crafts = HistoryReconciler.Merge(left.Crafts, right.Crafts);
        List<DimensionConflict> errors = [];

        static string? Name(string? leftName, string? rightName) =>
            new[] { leftName, rightName }.Where(s => !string.IsNullOrWhiteSpace(s))
                .OrderBy(s => s, StringComparer.Ordinal).FirstOrDefault();

        IReadOnlyList<T> Join<T, TKey>(
            string category, IEnumerable<T> leftSet, IEnumerable<T> rightSet,
            Func<T, TKey> key, Func<T, T, T> combine)
            where TKey : notnull
        {
            Dictionary<TKey, T> entries = [];
            foreach (T entry in leftSet.Concat(rightSet))
            {
                TKey id = key(entry);
                if (entries.TryGetValue(id, out T? previous))
                    entries[id] = combine(previous, entry);
                else
                    entries.Add(id, entry);
            }
            return entries.OrderBy(e => e.Key.ToString(), StringComparer.Ordinal)
                .Select(e => e.Value).ToArray();
        }

        void Conflict(string type, string key, string field) =>
            errors.Add(new(type, key, $"Conflicting known {field} for the same dimension identity."));

        IReadOnlyList<CharacterDimension> characters = Join(
            "Character", left.Dimensions.Characters, right.Dimensions.Characters,
            c => c.Identity.Key,
            (a, b) => a with
            {
                Name = Name(a.Name, b.Name),
                ClassFile = Name(a.ClassFile, b.ClassFile)
            });

        IReadOnlyList<ItemDimension> items = Join(
            "Item", left.Dimensions.Items, right.Dimensions.Items,
            i => i.Id, (a, b) => a with { Name = Name(a.Name, b.Name) });

        IReadOnlyList<RecipeDimension> recipes = Join(
            "Recipe", left.Dimensions.Recipes, right.Dimensions.Recipes,
            r => r.Id, (a, b) =>
            {
                if (a.ProfessionId is not null && b.ProfessionId is not null && a.ProfessionId != b.ProfessionId)
                    Conflict("Recipe", a.Id.ToString(), nameof(RecipeDimension.ProfessionId));
                return a with
                {
                    Name = Name(a.Name, b.Name),
                    ProfessionId = a.ProfessionId ?? b.ProfessionId
                };
            });

        IReadOnlyList<ProfessionDimension> professions = Join(
            "Profession", left.Dimensions.Professions, right.Dimensions.Professions,
            p => p.Id, (a, b) =>
            {
                if (a.ParentId is not null && b.ParentId is not null && a.ParentId != b.ParentId)
                    Conflict("Profession", a.Id.ToString(), nameof(ProfessionDimension.ParentId));
                return a with
                {
                    Name = Name(a.Name, b.Name),
                    ParentId = a.ParentId ?? b.ParentId
                };
            });

        IReadOnlyList<ExpansionDimension> expansions = Join(
            "Expansion", left.Dimensions.Expansions, right.Dimensions.Expansions,
            e => e.Id, (a, b) => a with { Name = Name(a.Name, b.Name) });

        if (!crafts.IsSuccessful || errors.Count > 0)
            return new(null, crafts.Conflicts, errors);

        CraftHistory merged = new(crafts.Observations,
            new(characters, recipes, professions, items, expansions));
        return new(merged, [], []);
    }
}
