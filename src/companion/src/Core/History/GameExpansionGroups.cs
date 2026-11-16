namespace ArtisanLogbook.History;

/// <summary>
/// Known Retail profession skill lines grouped by their game expansion. These are explicit
/// skill-line identities, not numeric ranges or localized expansion-name matches.
/// </summary>
public static class GameExpansionGroups
{
    private static readonly IReadOnlyDictionary<string, string[]> RetailGroups = new Dictionary<string, string[]>
    {
        ["game:midnight"] = Keys(2906, 2907, 2908, 2909, 2910, 2911, 2912, 2913, 2914, 2915, 2916, 2917, 2918),
        ["game:war-within"] = Keys(2871, 2872, 2873, 2874, 2875, 2876, 2877, 2878, 2879, 2880, 2881, 2882, 2883),
        ["game:dragonflight"] = Keys(2823, 2822, 2824, 2825, 2827, 2826, 2832, 2828, 2829, 2830, 2833, 2834, 2831),
        ["game:shadowlands"] = Keys(2750, 2751, 2752, 2753, 2755, 2754, 2760, 2756, 2757, 2758, 2761, 2762, 2759)
    };

    private static readonly IReadOnlyDictionary<string, string> RetailKeyToGroup =
        RetailGroups.SelectMany(group => group.Value.Select(key => (key, group.Key)))
            .ToDictionary(pair => pair.key, pair => pair.Key, StringComparer.Ordinal);

    public static string GroupKey(GameContext game, string professionExpansionKey) =>
        game.Project == GameProject.Retail &&
        RetailKeyToGroup.TryGetValue(professionExpansionKey, out string? group)
            ? group : professionExpansionKey;

    /// <summary>Unknown source keys remain separate singleton groups; unknown group IDs are rejected.</summary>
    public static IReadOnlyList<string>? MemberKeys(GameContext game, string groupKey)
    {
        if (game.Project == GameProject.Retail && RetailGroups.TryGetValue(groupKey, out string[]? keys))
            return keys;
        return string.IsNullOrWhiteSpace(groupKey) || groupKey.StartsWith("game:", StringComparison.Ordinal)
            ? null : [groupKey];
    }

    private static string[] Keys(params int[] ids) => ids.Select(id => $"skillLine:{id}").ToArray();
}

/// <summary>Available, recorded profession-expansion identities in one game-expansion choice.</summary>
public sealed record GameExpansionGroup(GameContext Game, string Key, string? Name,
    IReadOnlyList<string> ProfessionExpansionKeys);
